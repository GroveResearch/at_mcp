defmodule AtMcp.Effects do
  @moduledoc """
  The owner of one account: its session, its write policy and the work done
  as it.

  Each configured account is one process. (Two configured accounts that log in
  to the same DID are two owners today, so their writes are not ordered with
  each other; `decisions.md` records the limit.) It holds the backend session (ProtoRune or a
  test double), the credentials, the login count and the write quota server,
  and it runs every call on the account in a task of its own. The tasks are
  linked to the owner, so the work stops when the owner stops. The owner itself
  never waits on a service; it starts tasks, keeps their deadlines and answers
  callers.

  ## What runs when

  - **Writes** run one at a time, in the order they reached the owner. Order is
    what the account's readers see (a reply before the reply to it, a like
    before its undo), and a write's quota reservation belongs with its dispatch.
    A write that does not count against the quota still takes this lane.
  - **Reads** start as soon as they arrive and do not wait behind a write. A
    read changes nothing on the account, so it neither needs the write order nor
    can disturb it. A notification sweep is one read per page, so it never holds
    the account between pages either.
  - **The session** has one lane of its own: at most one login or refresh at a
    time, and every call that needs it waits for that one and shares its result.
    On a refused credential (`AtMcp.Effects.Failure` kind `:auth_refused`) the
    call asks the owner to recover the session — refresh, or log in again with
    the app password — and retries once, so a long session does not end when
    its access token expires.

  ## Write quota

  Every embedding and configured identity uses the durable account-wide
  `AtMcp.WriteQuota`, shared by every client and alias of that DID, under
  this account's own limit (`:write_limit`, `:write_window_seconds`) or, where
  it sets none, the quota server's. The quota bounds what the account
  publishes, so only the verbs in `publishing/0` —
  post, reply and repost — reserve before dispatch; every other write goes out
  without spending one. Failed and ambiguous backend attempts consume their
  reservation. Hosts own activity limits.

  ## Deadline

  Every account call answers within `call_deadline/0`, counted from the moment
  the caller asks. A service that stops answering holds its request for as long
  as the HTTP client allows, and a caller that gives up first — the MCP endpoint
  abandons a tool call after a fixed time — learns nothing about a write it
  abandoned. So the owner answers at the deadline with what it knows:

  - a call still waiting for the account changed nothing:
    `:call_deadline_exceeded`;
  - a running call is stopped; a write that reached the backend is
    `{:write_outcome_unknown, :call_deadline_exceeded}`, a read whose request
    went to the service is `{:call_deadline_exceeded, :sent}`, and anything
    else is `:call_deadline_exceeded`.

  The caller waits `@answer_grace_ms` past the deadline for that answer, which
  covers the owner's own scheduling and nothing else; the longest any caller
  waits is `answered_within/0`. If the owner stops before answering, a write
  its task had sent, or whose task is not seen to stop, is unknown, and any
  other call changed nothing (`:account_runtime_unavailable`). A task marks a
  write as sent before its last deadline check and never sends after the
  deadline, so a caller that stopped waiting without a mark cannot be followed
  by a late write; a write stopped at that check reads as unknown.
  """

  use GenServer

  @type t :: pid() | atom() | {:via, module(), term()} | {atom(), node()}

  # The scheduling delay a caller allows the owner, and bounds two waits: past
  # the deadline for the owner's answer, and, if the owner stops instead, for
  # the call's task to be seen to stop. A caller is therefore answered within
  # the deadline plus twice this (`answered_within/0`), which the MCP endpoint's
  # limit is derived from.
  @answer_grace_ms 1_000

  # Messages between a caller, the owner and the owner's tasks.
  @call :at_mcp_effects_call

  @doc """
  Start the owner of one account.

  Options:
  - `:backend` — module implementing `AtMcp.Effects.Backend` (default ProtoRune)
  - `:backend_state` — preloaded session/state (skips needing login for mocks)
  - `:write_quota` — durable account quota server (default AtMcp.WriteQuota); nil is refused
  - `:write_limit` / `:write_window_seconds` — this account's own write limit
    and window, positive integers; either left out is the quota server's
  - `:expected_did` — require this account DID on every session it accepts
  - `:name` — process name
  - `:logged_in` — mark already connected when `backend_state` is set
  - `:handle` / `:password` — optional identity credentials; without them
    the account logs in only when a caller supplies them
  """
  def start_link(opts \\ []) do
    backend = Keyword.get(opts, :backend, AtMcp.Effects.ProtoRune)

    quota = Keyword.get(opts, :write_quota, AtMcp.WriteQuota)

    if is_nil(quota),
      do: raise(ArgumentError, "write_quota must name a durable account quota server")

    write_limits = write_limits!(opts)

    if Enum.any?(
         [:max_writes_per_turn, :max_posts_per_turn, :require_turn],
         &Keyword.has_key?(opts, &1)
       ),
       do:
         raise(
           ArgumentError,
           "turn options were removed; configure AtMcp.WriteQuota and host activity limits"
         )

    backend_state = Keyword.get(opts, :backend_state)
    logged_in? = Keyword.get(opts, :logged_in, not is_nil(backend_state))

    credentials =
      case {Keyword.get(opts, :handle), Keyword.get(opts, :password)} do
        {h, p} when is_binary(h) and h != "" and is_binary(p) and p != "" ->
          %{handle: h, password: p}

        _ ->
          nil
      end

    credentials = retain_service(credentials, opts)

    state = %{
      identity_id: Keyword.get(opts, :identity_id),
      expected_did: Keyword.get(opts, :expected_did),
      identity_error: nil,
      backend: backend,
      backend_state: backend_state,
      login_count: if(logged_in?, do: 1, else: 0),
      logged_in?: logged_in?,
      credentials: credentials,
      write_quota: quota,
      write_limits: write_limits,
      # Calls by id: %{from, caller, lane, fun, deadline_at, timer, task, dispatched}.
      calls: %{},
      # Task monitor ref => call id, for every running call.
      tasks: %{},
      # Caller monitor ref => call id, for every call not yet answered.
      callers: %{},
      # Write calls waiting for the one running write, oldest first.
      writes: :queue.new(),
      write: nil,
      # The one login or refresh in progress, with everyone waiting for it.
      session_task: nil
    }

    state =
      if not is_nil(backend_state) and not identity_matches?(state, backend_state),
        do: reject_identity(state),
        else: state

    name_opts =
      case Keyword.get(opts, :name) do
        nil -> []
        name -> [name: name]
      end

    GenServer.start_link(__MODULE__, state, name_opts)
  end

  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent
    }
  end

  @doc "Login once. Subsequent calls reuse the session and do not bump login_count."
  def login(effects, opts \\ []),
    do: run(effects, :read, fn -> GenServer.call(owner(), {:login, opts}, :infinity) end)

  @doc false
  # Authentication prepares a runtime that is not yet ready. Only Accounts can
  # subsequently bind it and make it ready; this entry point cannot read or write account records.
  def authenticate(effects),
    do:
      run(effects, :read, fn -> GenServer.call(owner(), {:login, []}, :infinity) end,
        ready_check: false
      )

  def quota_status(effects) do
    state = state(effects)
    AtMcp.WriteQuota.status(state.write_quota, did_of(state.backend_state), state.write_limits)
  end

  @doc false
  # The account's own limits, as `AtMcp.WriteQuota.reserve/3` takes them.
  # An option left out is the quota server's. An explicit nil is refused, as
  # `AtMcp.Identities.start_identity/1` says, not read as left out.
  def write_limits!(opts) do
    limits =
      for {option, key} <- [write_limit: :limit, write_window_seconds: :window_seconds],
          Keyword.has_key?(opts, option),
          do: {key, Keyword.get(opts, option)}

    if AtMcp.WriteQuota.valid_limits?(limits),
      do: limits,
      else: raise(ArgumentError, "write_limit and write_window_seconds must be positive integers")
  end

  def login_count(effects), do: state(effects).login_count

  @doc "DID of the logged-in session, or nil."
  def session_did(effects), do: did_of(state(effects).backend_state)

  @doc "The immutable account binding required by named shared connections."
  def expected_did(effects), do: state(effects).expected_did

  @doc "Whether Effects currently holds a live backend session."
  def logged_in?(effects), do: state(effects).logged_in?

  @doc "Whether Effects has identity credentials for eager login."
  def credentials?(effects), do: has_credentials?(state(effects))

  @doc "The durable write quota server this account reserves from."
  def write_quota(effects), do: state(effects).write_quota

  def session_handle(effects) do
    state = state(effects)
    session = state.backend_state || %{}

    Map.get(session, :handle) || Map.get(session, "handle") ||
      (state.credentials && state.credentials.handle)
  end

  # --- reads ---

  def get_membership(effects) do
    with_session(effects, fn backend, session ->
      if function_exported?(backend, :get_membership, 1),
        do: backend.get_membership(session),
        else:
          {:error,
           AtMcp.Effects.Failure.new(:refused,
             detail: :membership_not_supported
           )}
    end)
  end

  @doc """
  Recent notifications. With `grouped: true`, grouped as the app's
  Notifications screen shows them (`notification.getGroupedNotifications`),
  from one of its tabs (`feed`, `"all"` when nil); `reasons` is the ungrouped
  read's alone, and `feed` the grouped one's.
  """
  def list_notifications(effects, opts \\ []) do
    {grouped, opts} = Keyword.pop(opts, :grouped)
    {feed, opts} = Keyword.pop(opts, :feed)

    if grouped == true do
      with :ok <- served("notification.getGroupedNotifications"),
           :ok <-
             only_with(
               opts[:reasons],
               false,
               "reasons",
               "the grouped notifications filter by feed, not by reason"
             ),
           :ok <- grouped_feed(feed),
           {:ok, opts} <- page_options(Keyword.delete(opts, :reasons)) do
        with_session(effects, fn backend, session ->
          backend.get_grouped_notifications(session, Keyword.put(opts, :feed, feed || "all"))
        end)
      end
    else
      with :ok <-
             only_with(
               feed,
               false,
               "feed",
               "feed reads the grouped notifications; give grouped true"
             ),
           {:ok, opts} <- page_options(opts) do
        with_session(effects, fn backend, session ->
          backend.list_notifications(session, opts)
        end)
      end
    end
  end

  # The tabs of the app's Notifications screen (`getGroupedNotifications`'
  # known feeds, each a tab in social-app's src/screens/Notifications at
  # 485405a).
  @notification_feeds ["all", "people-i-follow", "followers", "conversations", "activity"]

  @doc "The feeds the grouped notifications read: the tabs of the app's Notifications screen."
  def notification_feeds, do: @notification_feeds

  defp grouped_feed(nil), do: :ok
  defp grouped_feed(feed) when feed in @notification_feeds, do: :ok

  defp grouped_feed(_feed),
    do: invalid("feed", "must be #{Enum.join(@notification_feeds, ", ")}")

  def get_notifications(effects, opts \\ []), do: list_notifications(effects, opts)

  def get_unread_count(effects) do
    with_session(effects, fn backend, session ->
      backend.get_unread_count(session)
    end)
  end

  @doc """
  What surrounds a post. With `include_hidden: true`, the replies the app
  leaves out of the thread, which the thread's author hid or the account's own
  settings push down, are read too. The thread read already returns most of
  them, unmarked: each of those is marked where it stands (`left_out`, with
  `hidden_by_threadgate` or `muted_by_viewer` when the service says which),
  and `hidden_replies` lists only the ones the thread read did not return. A
  failed read of them leaves the thread as read and says why in
  `hidden_replies_unread`.
  """
  def get_thread(effects, uri, opts \\ []) when is_binary(uri) do
    with_session(effects, fn backend, session ->
      with {:ok, thread} <- backend.get_thread(session, uri) do
        if(Keyword.get(opts, :include_hidden) == true,
          do: with_hidden(thread, backend.get_hidden_replies(session, uri)),
          else: {:ok, thread}
        )
        |> moderated(backend, session, :thread)
      end
    end)
  end

  defp with_hidden(thread, {:ok, hidden}) when is_list(hidden) do
    by_uri = for reply <- hidden, uri = summary_uri(reply), into: %{}, do: {uri, reply}
    {thread, shown} = mark_left_out(thread, by_uri, MapSet.new())

    {:ok,
     Map.put(
       thread,
       :hidden_replies,
       Enum.reject(hidden, &MapSet.member?(shown, summary_uri(&1)))
     )}
  end

  # A refused credential is recovered and the read made again, as for any read.
  # Anything else keeps the thread already read, with one line saying the
  # left-out replies could not be read and why.
  defp with_hidden(thread, {:error, reason} = error) do
    if AtMcp.Effects.Failure.kind(reason) == :auth_refused,
      do: error,
      else: {:ok, Map.put(thread, :hidden_replies_unread, hidden_unread(reason))}
  end

  defp hidden_unread(%AtMcp.Effects.Failure{status: 501}),
    do:
      "The replies this thread leaves out could not be read: the account's service does not serve them (it answered 501)."

  defp hidden_unread(%AtMcp.Effects.Failure{status: status, message: message})
       when is_integer(status) do
    said = if is_binary(message) and message != "", do: ": #{message}", else: ""

    "The replies this thread leaves out could not be read: the account's service answered #{status}#{said}."
  end

  defp hidden_unread(_reason),
    do: "The replies this thread leaves out could not be read: the request did not complete."

  defp summary_uri(%{uri: uri}) when is_binary(uri), do: uri
  defp summary_uri(%{"uri" => uri}) when is_binary(uri), do: uri
  defp summary_uri(_), do: nil

  # The replies under the post read, at every depth it returned.
  defp mark_left_out(node, by_uri, shown) when is_map(node) do
    {replies, shown} =
      Enum.map_reduce(Map.get(node, :replies) || [], shown, fn reply, shown ->
        {reply, shown} =
          case Map.fetch(by_uri, summary_uri(reply)) do
            {:ok, hidden} -> {left_out(reply, hidden), MapSet.put(shown, summary_uri(reply))}
            :error -> {reply, shown}
          end

        mark_left_out(reply, by_uri, shown)
      end)

    {if(Map.has_key?(node, :replies), do: Map.put(node, :replies, replies), else: node), shown}
  end

  defp mark_left_out(node, _by_uri, shown), do: {node, shown}

  # `depth` is where the left-out read found it: a reply at depth 1 is left
  # out itself, one deeper may be there only because a reply above it is.
  defp left_out(reply, hidden) do
    Map.merge(reply, %{
      left_out: true,
      depth: Map.get(hidden, :depth),
      hidden_by_threadgate:
        Map.get(reply, :hidden_by_threadgate) == true or
          Map.get(hidden, :hidden_by_threadgate) == true,
      muted_by_viewer: Map.get(hidden, :muted_by_viewer) == true
    })
  end

  def get_thread_chain(effects, uri, opts \\ []) when is_binary(uri) and is_list(opts) do
    with :ok <- validate_before(Keyword.get(opts, :before)),
         :ok <- validate_include_replies(Keyword.get(opts, :include_replies, true)) do
      with_session(effects, fn backend, session ->
        session |> backend.get_thread_chain(uri, opts) |> moderated(backend, session, :chain)
      end)
    end
  end

  # A cursor is whatever the caller sends back, and a caller that sends a
  # number or an object is answered, not crashed. Checked here, with the other
  # input checks, so a malformed one costs no session and no read.
  defp validate_before(before) when is_nil(before) or is_binary(before), do: :ok
  defp validate_before(_before), do: {:error, :invalid_before}

  defp validate_include_replies(value) when is_boolean(value), do: :ok
  defp validate_include_replies(_value), do: {:error, :invalid_include_replies}

  def get_timeline(effects, opts \\ []) do
    with {:ok, opts} <- page_options(opts) do
      with_session(effects, fn backend, session ->
        session |> backend.get_timeline(opts) |> moderated(backend, session, :posts)
      end)
    end
  end

  def get_author_feed(effects, actor, opts \\ []) when is_binary(actor) do
    with {:ok, opts} <- page_options(opts) do
      with_session(effects, fn backend, session ->
        session
        |> backend.get_author_feed(actor, opts)
        |> moderated(backend, session, {:author_feed, actor})
      end)
    end
  end

  def get_profile(effects, actor) when is_binary(actor) do
    with_session(effects, fn backend, session ->
      session |> backend.get_profile(actor) |> moderated(backend, session, :profile)
    end)
  end

  @doc """
  Read this account's complete current profile presentation as `%{value: record}`.
  `record` keeps the native record's string keys and blob references, suitable
  for an embedded client's comparison before `update_profile/2`. Town metadata
  stays local; cosmetic fallback never changes shared public labels.
  """
  def get_own_profile(effects) do
    with_session(effects, fn backend, session ->
      if function_exported?(backend, :get_own_profile, 1),
        do: backend.get_own_profile(session),
        else: {:error, AtMcp.Effects.Failure.new(:refused, detail: :own_profile_not_supported)}
    end)
  end

  def get_profiles(effects, actors) when is_list(actors) do
    with :ok <- validate_batch(actors) do
      with_session(effects, fn backend, session ->
        session |> backend.get_profiles(actors) |> moderated(backend, session, :profiles)
      end)
    end
  end

  def get_posts(effects, uris) when is_list(uris) do
    with :ok <- validate_batch(uris) do
      with_session(effects, fn backend, session ->
        session |> backend.get_posts(uris) |> moderated(backend, session, :posts)
      end)
    end
  end

  # `feed.getPosts` and `actor.getProfiles` declare `maxLength: 25` on both
  # networks, so unlike the post text limits this number does not vary with
  # `AtMcp.Network` and is not read from a vendored lexicon. The list is checked
  # here so an oversized batch fails with a stable code before a request leaves
  # the machine, the way page limits do.
  @max_batch 25

  @doc "The most entries one batch read takes: `get_posts`, `get_profiles`, `get_relationships`."
  def max_batch, do: @max_batch

  defp validate_batch(entries) do
    cond do
      entries == [] -> {:error, :empty_batch}
      length(entries) > @max_batch -> {:error, :batch_too_large}
      true -> :ok
    end
  end

  @doc """
  Search posts (`feed.searchPostsV2`). `query` may be nil when a filter
  narrows the search instead; `search_filters/0` names the filters. A post
  named by a handle-form AT URI in `:reply_to`, `:thread_root`, `:embeds` or
  `:exclude_embeds` is searched for by its DID form, which is how the service
  indexes it.
  """
  def search_posts(effects, query, opts \\ []) when is_binary(query) or is_nil(query) do
    query = present(query)

    with {:ok, opts} <- search_post_options(opts),
         :ok <- query_or_filter(query, opts) do
      with_session(effects, fn backend, session ->
        with {:ok, opts} <- search_uris(backend, session, opts),
             do:
               session
               |> backend.search_posts(query, opts)
               |> moderated(backend, session, :posts)
      end)
    end
  end

  defp query_or_filter(nil, opts) do
    if Enum.any?(opts, fn {key, _} -> key not in [:limit, :cursor, :sort, :all_time] end),
      do: :ok,
      else: invalid("query", "give a query, or at least one filter to search by")
  end

  defp query_or_filter(_query, _opts), do: :ok

  defp search_uris(backend, session, opts) do
    Enum.reduce_while(opts, {:ok, []}, fn
      {key, uri}, {:ok, acc} when key in [:reply_to, :thread_root] ->
        case did_uri(backend, session, uri) do
          {:ok, uri} -> {:cont, {:ok, acc ++ [{key, uri}]}}
          error -> {:halt, error}
        end

      {key, uris}, {:ok, acc} when key in [:embeds, :exclude_embeds] ->
        case did_uris(backend, session, uris) do
          {:ok, uris} -> {:cont, {:ok, acc ++ [{key, uris}]}}
          error -> {:halt, error}
        end

      pair, {:ok, acc} ->
        {:cont, {:ok, acc ++ [pair]}}
    end)
  end

  def search_actors(effects, query, opts \\ []) when is_binary(query) do
    with {:ok, opts} <- page_options(opts) do
      with_session(effects, fn backend, session ->
        session |> backend.search_actors(query, opts) |> moderated(backend, session, :profiles)
      end)
    end
  end

  # --- graph reads ---

  def get_followers(effects, actor, opts \\ []) when is_binary(actor) do
    paged(effects, opts, fn backend, session, opts ->
      backend.get_followers(session, actor, opts)
    end)
  end

  def get_follows(effects, actor, opts \\ []) when is_binary(actor) do
    paged(effects, opts, fn backend, session, opts ->
      backend.get_follows(session, actor, opts)
    end)
  end

  def get_known_followers(effects, actor, opts \\ []) when is_binary(actor) do
    paged(effects, opts, fn backend, session, opts ->
      backend.get_known_followers(session, actor, opts)
    end)
  end

  # Where the app suggests accounts without a subject, and the method each
  # place calls: `{suffix, what else it takes}`. The app's Explore page is the
  # default. `browse` is `actor.getSuggestions`, the one that pages.
  @suggestion_contexts %{
    "explore" => {"unspecced.getSuggestedUsersForExplore", :category},
    "discover" => {"unspecced.getSuggestedUsersForDiscover", nil},
    "see_more" => {"unspecced.getSuggestedUsersForSeeMore", :category},
    "onboarding" => {"unspecced.getSuggestedOnboardingUsers", :category},
    "general" => {"unspecced.getSuggestedUsers", :category},
    "browse" => {"actor.getSuggestions", :cursor}
  }

  @doc "The contexts `get_suggested_follows/3` takes without an actor."
  def suggestion_contexts, do: @suggestion_contexts |> Map.keys() |> Enum.sort()

  @doc """
  Accounts the service suggests. With `actor`, accounts like that one
  (`graph.getSuggestedFollowsByActor`). Without, the suggestions of one place
  in the app, `:context` (`suggestion_contexts/0`, `explore` when absent),
  with `:category` where that place takes one and `:limit`; `browse` pages
  with `:cursor`.
  """
  def get_suggested_follows(effects, actor, opts \\ [])

  def get_suggested_follows(effects, actor, opts) when is_binary(actor) do
    # `limit` is not among them: the tool fills in its default, and the
    # service decides how many accounts like this one it returns.
    case for(key <- [:context, :category, :cursor], present?(opts[key]), do: key) do
      [] ->
        with_session(effects, fn backend, session ->
          backend.get_suggested_follows(session, actor)
        end)

      [key | _] ->
        invalid(
          Atom.to_string(key),
          "with actor, the suggestions are the service's accounts like that one, and it takes no #{key}; leave it out, or leave actor out"
        )
    end
  end

  def get_suggested_follows(effects, nil, opts) do
    context = present(opts[:context]) || "explore"
    category = present(opts[:category])

    with {:ok, {suffix, takes}} <- suggestion_context(context),
         :ok <- served(suffix),
         :ok <-
           only_with(category, takes == :category, "category", "#{context} takes no category"),
         :ok <-
           only_with(opts[:cursor], takes == :cursor, "cursor", "only browse is read in pages") do
      paged(effects, Keyword.take(opts, [:limit, :cursor]), fn backend, session, page ->
        backend.get_suggested_accounts(session, suffix, Keyword.put(page, :category, category))
      end)
    end
  end

  defp suggestion_context(context) do
    case Map.fetch(@suggestion_contexts, context) do
      {:ok, found} -> {:ok, found}
      :error -> invalid("context", "must be one of #{Enum.join(suggestion_contexts(), ", ")}")
    end
  end

  defp only_with(value, allowed?, field, why) do
    if present?(value) and not allowed?, do: invalid(field, why), else: :ok
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value), do: not is_nil(value)

  @doc """
  Whether this network's deployment serves the method `suffix` names, before
  anything is sent: `:ok`, or `{:error, {:not_served, nsid, evidence}}` with
  `AtMcp.Endpoints.deployments/0`'s evidence.
  """
  def served(suffix) do
    case AtMcp.Endpoints.not_served(AtMcp.Network.name(), "app.bsky." <> suffix) do
      nil -> :ok
      evidence -> {:error, {:not_served, AtMcp.Network.nsid(suffix), evidence}}
    end
  end

  def get_blocks(effects, opts \\ []) do
    paged(effects, opts, fn backend, session, opts -> backend.get_blocks(session, opts) end)
  end

  def get_mutes(effects, opts \\ []) do
    paged(effects, opts, fn backend, session, opts -> backend.get_mutes(session, opts) end)
  end

  # `others` is the same kind of list as a getPosts batch, and the lexicon caps
  # it too, so it is checked before a request leaves the machine.
  def get_relationships(effects, actor, others) when is_binary(actor) and is_list(others) do
    with :ok <- validate_batch(others) do
      with_session(effects, fn backend, session ->
        backend.get_relationships(session, actor, others)
      end)
    end
  end

  # --- engagement reads ---

  def get_likes(effects, uri, opts \\ []) when is_binary(uri) do
    paged(effects, opts, fn backend, session, opts -> backend.get_likes(session, uri, opts) end)
  end

  def get_reposted_by(effects, uri, opts \\ []) when is_binary(uri) do
    paged(effects, opts, fn backend, session, opts ->
      backend.get_reposted_by(session, uri, opts)
    end)
  end

  def get_quotes(effects, uri, opts \\ []) when is_binary(uri) do
    paged(effects, opts, fn backend, session, opts ->
      session |> backend.get_quotes(uri, opts) |> moderated(backend, session, :posts)
    end)
  end

  def get_actor_likes(effects, actor, opts \\ []) when is_binary(actor) do
    paged(effects, opts, fn backend, session, opts ->
      session |> backend.get_actor_likes(actor, opts) |> moderated(backend, session, :posts)
    end)
  end

  # --- feeds other than the home timeline ---

  def get_feed(effects, feed, opts \\ []) when is_binary(feed) do
    paged(effects, opts, fn backend, session, opts ->
      with {:ok, feed} <- did_uri(backend, session, feed),
           do: session |> backend.get_feed(feed, opts) |> moderated(backend, session, :posts)
    end)
  end

  @doc """
  Feeds the service suggests. `:source` `"default"` (or absent) reads
  `feed.getSuggestedFeeds`, which pages; `"unspecced"` reads the newer
  suggestion service, `unspecced.getSuggestedFeeds`, which takes at most 25
  and no cursor.

  A first page also carries `app_pinned_feeds`, the views of the feeds the
  network's app pins for every account (`AtMcp.Network.app_pinned_feeds/0`),
  when it pins any. The service's suggestions stay in `items` alone.
  """
  def get_suggested_feeds(effects, opts \\ []) do
    case present(opts[:source]) || "default" do
      "default" ->
        paged(effects, Keyword.take(opts, [:limit, :cursor]), fn backend, session, page ->
          with {:ok, result} <- backend.get_suggested_feeds(session, page),
               do: with_app_pinned_feeds(backend, session, result, page[:cursor])
        end)

      "unspecced" ->
        with :ok <- served("unspecced.getSuggestedFeeds"),
             :ok <- only_with(opts[:cursor], false, "cursor", "the unspecced source is one page"),
             :ok <- at_most(opts[:limit]) do
          paged(effects, Keyword.take(opts, [:limit]), fn backend, session, page ->
            with {:ok, result} <-
                   backend.get_suggested_feeds(session, Keyword.put(page, :source, :unspecced)),
                 do: with_app_pinned_feeds(backend, session, result, nil)
          end)
        end

      _other ->
        invalid("source", "must be default or unspecced")
    end
  end

  defp with_app_pinned_feeds(backend, session, result, cursor) do
    case AtMcp.Network.app_pinned_feeds() do
      pinned when pinned == [] or is_binary(cursor) ->
        {:ok, result}

      pinned ->
        with {:ok, %{items: items}} <- backend.get_feed_info(session, pinned),
             do: {:ok, Map.put(result, :app_pinned_feeds, items)}
    end
  end

  # The unspecced suggestion and trend methods take at most 25 (their
  # lexicons' `maximum`), fewer than AtMcp's own page limit.
  @short_page_max 25

  @doc "The most one page of the unspecced suggestion and trend reads holds."
  def short_page_max, do: @short_page_max

  defp at_most(limit), do: at_most(limit, @short_page_max)

  defp at_most(nil, _max), do: :ok
  defp at_most(limit, max) when is_integer(limit) and limit <= max, do: :ok

  defp at_most(limit, max) when is_integer(limit),
    do: invalid("limit", "this read takes at most #{max}; this is #{limit}")

  defp at_most(_limit, _max), do: :ok

  @doc """
  What the service knows about one or more feeds, by AT URI. One feed is read
  with `feed.getFeedGenerator`, which also says whether its service is online
  and valid; several are read together with `feed.getFeedGenerators`, which
  does not say. A feed named with a handle is asked for in its DID form.
  """
  def get_feed_info(effects, uris) when is_list(uris) do
    with :ok <- validate_batch(uris),
         :ok <- each_record(uris, "uris", [:generator], "a feed generator") do
      with_session(effects, fn backend, session ->
        with {:ok, uris} <- did_uris(backend, session, uris),
             do: backend.get_feed_info(session, Enum.uniq(uris))
      end)
    end
  end

  @doc "The feeds an account made."
  def get_actor_feeds(effects, actor, opts \\ []) when is_binary(actor) do
    paged(effects, opts, fn backend, session, page ->
      backend.get_actor_feeds(session, actor, page)
    end)
  end

  @doc """
  Feeds whose name or description matches `query`, most popular first, or the
  most popular feeds when `query` is nil, as the app's feed search shows them.
  """
  def search_feeds(effects, query, opts \\ []) do
    paged(effects, opts, fn backend, session, page ->
      backend.search_feeds(session, present(query), page)
    end)
  end

  @starter_pack_contexts %{
    "default" => "unspecced.getSuggestedStarterPacks",
    "onboarding" => "unspecced.getOnboardingSuggestedStarterPacks"
  }

  @doc """
  Starter packs the service suggests: `:context` `"default"` (or absent), or
  `"onboarding"`, those it suggests to a new account. At most 25.
  """
  def get_suggested_starter_packs(effects, opts \\ []) do
    case Map.fetch(@starter_pack_contexts, present(opts[:context]) || "default") do
      {:ok, suffix} ->
        with :ok <- served(suffix), :ok <- at_most(opts[:limit]) do
          paged(effects, Keyword.take(opts, [:limit]), fn backend, session, page ->
            backend.get_suggested_starter_packs(session, suffix, page)
          end)
        end

      :error ->
        invalid("context", "must be default or onboarding")
    end
  end

  @trend_kinds %{"trends" => "unspecced.getTrends", "topics" => "unspecced.getTrendingTopics"}

  @doc """
  What is trending: `kind` `"trends"` (`unspecced.getTrends`: each trend with
  when it started, how many posts and some of the accounts posting), or
  `"topics"` (`unspecced.getTrendingTopics`: topics, and topics suggested
  beside them). At most 25.
  """
  def get_trends(effects, kind, opts \\ []) do
    case Map.fetch(@trend_kinds, kind || "trends") do
      {:ok, suffix} ->
        with :ok <- served(suffix), :ok <- at_most(opts[:limit]) do
          paged(effects, Keyword.take(opts, [:limit]), fn backend, session, page ->
            backend.get_trends(session, suffix, page)
          end)
        end

      :error ->
        invalid("kind", "must be trends or topics")
    end
  end

  @doc """
  One record, exactly as its repository holds it: `%{uri, cid, value}`. Any
  collection, any account.
  """
  def get_record(effects, uri) when is_binary(uri) do
    case AtMcp.ATProto.parse_uri(uri) do
      {:ok, {_repo, _collection, rkey}} when rkey not in [nil, ""] ->
        with_session(effects, fn backend, session -> backend.get_record(session, uri) end)

      _ ->
        invalid("uri", "must be an AT URI of the form at://<handle or DID>/<collection>/<rkey>")
    end
  end

  @doc """
  This account's invitation codes on delve.town, as the town's app lists them:
  used ones too, and, as the app does when it opens the list, any codes the
  account has earned since are issued first.
  """
  def get_invite_codes(effects) do
    with_session(effects, fn backend, session -> backend.get_invite_codes(session) end)
  end

  @doc "One of the network's published policy pages (`AtMcp.Network.policy_url/1`)."
  def get_policy(effects, page) when is_binary(page) do
    with_session(effects, fn backend, session -> backend.get_policy(session, page) end)
  end

  defp each_record(uris, field, kinds, what) do
    Enum.reduce_while(uris, :ok, fn uri, :ok ->
      case record_argument(uri, field, kinds, what) do
        {:ok, _} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp did_uris(backend, session, uris) do
    Enum.reduce_while(uris, {:ok, []}, fn uri, {:ok, acc} ->
      case did_uri(backend, session, uri) do
        {:ok, uri} -> {:cont, {:ok, acc ++ [uri]}}
        error -> {:halt, error}
      end
    end)
  end

  def get_list_feed(effects, list, opts \\ []) when is_binary(list) do
    paged(effects, opts, fn backend, session, opts ->
      with {:ok, list} <- did_uri(backend, session, list),
           do: session |> backend.get_list_feed(list, opts) |> moderated(backend, session, :posts)
    end)
  end

  # One page check for every paged read. An invalid limit or cursor fails here,
  # before a session is taken and before anything is sent.
  defp paged(effects, opts, call) do
    with {:ok, opts} <- page_options(opts) do
      with_session(effects, fn backend, session -> call.(backend, session, opts) end)
    end
  end

  # --- writes ---

  # The write quota bounds what an account publishes: its own words, and another
  # account's words put in front of its followers. A like, a follow, a block,
  # a deletion or a profile edit is an ordinary gesture and does not spend it.
  # Each MCP tool's description and its `at_mcp/publicWrite` annotation derive
  # from this list (`AtMcp.MCP.DSL`), so a host reads the same classification.
  @publishing [:post, :reply, :repost]

  @doc "The write verbs that count against the account's write quota."
  def publishing, do: @publishing

  @doc "Whether a write verb counts against the account's write quota."
  def counts_against_quota?(verb) when is_atom(verb), do: verb in @publishing

  @doc """
  Publish a post. `opts` are `AtMcp.Effects.ProtoRune.prepare_post/3`'s and
  `AtMcp.Interactions.post_options/2`'s. `facets: :none` publishes `text`
  exactly as given, with no mention, link or tag facets, for a caller that
  quotes text it did not write; the MCP tools do not offer it (decisions.md).
  """
  def post(effects, text, opts \\ []) when is_binary(text) and is_list(opts),
    do: publish(effects, :post, text, opts)

  @doc """
  Reply to a post. A reply is a post with a parent, so it is the same write
  with the same options, `facets: :none` included; only the tool surface names
  it separately.
  """
  def reply(effects, uri, text, opts \\ []) when is_binary(uri) and is_binary(text),
    do: publish(effects, :reply, text, Keyword.put(opts, :reply, uri))

  defp publish(effects, verb, text, opts) do
    with :ok <- validate_post_text(text),
         :ok <- reference(opts[:reply], &post_uri(&1, "uri")),
         :ok <- reference(opts[:quote], &quotable(&1)),
         {:ok, opts} <- AtMcp.Interactions.post_options(verb, opts) do
      # Resolve references and build the complete record before taking a slot
      # or marking dispatch. A deleted parent or a local rich-text/record
      # error must not claim a post may have landed or consume publishing
      # capacity. Sent writes are never refunded — see `take_and_write/4`.
      take_and_write(
        effects,
        verb,
        fn backend, session -> backend.prepare_post(session, text, opts) end,
        fn opts -> fn backend, session -> backend.post(session, text, opts) end end
      )
    end
  end

  # A reply's parent is a post, and a quote is a post or a record the app
  # shows as a quoted card (`embed.record`): a feed, a list, a starter pack or
  # a labeler. The URI's collection says which before anything is read, so
  # another record is refused as such here rather than as a record the service
  # would not hand over.
  defp reference(nil, _check), do: :ok

  defp reference(uri, check) do
    with {:ok, _parts} <- check.(uri), do: :ok
  end

  defp quotable(uri),
    do:
      record_argument(
        uri,
        "quote",
        [:post, :generator, :list, :starter_pack, :labeler],
        "a post, a feed generator, a list, a starter pack or a labeler"
      )

  @doc """
  Check text against the configured network's post record limits.

  Runs before quota reservation and before the backend resolves rich-text
  mentions or performs any network request, so a refusal costs nothing. The
  limits come from the lexicon through `AtMcp.Network`: the two networks differ
  by more than two orders of magnitude here, and holding the Bluesky pair as
  literals is what made AtMcp refuse a 5,000-character post on a network that
  accepts 100,000. The lexicon specifies no minimum length; retain empty-text
  behavior.
  """
  def validate_post_text(text) do
    %{graphemes: graphemes, bytes: bytes} = AtMcp.Network.post_limits()

    cond do
      not String.valid?(text) -> {:error, :invalid_post_text}
      byte_size(text) > bytes or String.length(text) > graphemes -> {:error, :post_text_too_long}
      true -> :ok
    end
  end

  @doc """
  Like a post, a custom feed or a labeler: what the app shows a like count on.
  Any other record is refused before anything is sent, since nothing would
  count the like. A record named by a handle-form AT URI is liked by its DID
  form, which is how the AppView counts likes. One this account has liked
  already is not liked again: the like it has comes back, `unchanged: true`.

  `cid` may be nil: the subject's current CID is then taken from the same
  AppView read that finds an existing like. See `subject_cid/3`.
  """
  def like(effects, uri, cid \\ nil) when is_binary(uri) and (is_binary(cid) or is_nil(cid)) do
    with {:ok, _} <-
           record_argument(
             uri,
             "uri",
             [:post, :generator, :labeler],
             "a post, a feed generator or a labeler"
           ) do
      take_and_write(
        effects,
        :like,
        fn backend, session -> once_with_cid(backend, session, :like, uri, cid) end,
        fn {uri, cid} -> fn backend, session -> backend.like(session, uri, cid) end end
      )
    end
  end

  def unlike(effects, like_uri) when is_binary(like_uri), do: undo(effects, :unlike, like_uri)

  # A repost, like a like, names its subject by DID: the AppView counts a
  # repost whose subject is a handle-form AT URI nowhere.
  def repost(effects, uri, cid \\ nil)
      when is_binary(uri) and (is_binary(cid) or is_nil(cid)) do
    with {:ok, _} <- at_uri_argument(uri, "uri") do
      take_and_write(
        effects,
        :repost,
        fn backend, session -> once_with_cid(backend, session, :repost, uri, cid) end,
        fn {uri, cid} -> fn backend, session -> backend.repost(session, uri, cid) end end
      )
    end
  end

  # A like or repost reads the subject's view once, before anything is sent:
  # it names a record this account already has (see `once/5`) and carries the
  # subject's current CID.
  defp once_with_cid(backend, session, action, uri, cid) do
    cid = present(cid)

    with {:ok, uri} <- did_uri(backend, session, uri),
         {:ok, view} <- backend.subject_view(session, action, uri) do
      case view do
        %{record: existing} when is_binary(existing) ->
          {:ok,
           {:unchanged,
            %{
              subject_uri: uri,
              subject_cid: cid || view.cid,
              uri: existing,
              action: action,
              unchanged: true
            }}}

        _ ->
          with {:ok, cid} <- subject_cid(backend, session, uri, cid, view.cid),
               do: {:ok, {uri, cid}}
      end
    end
  end

  # The CID a like or repost records. A caller that leaves it out gets the
  # AppView's CID for the subject: a CID is a 59-character string that models
  # copy wrongly, and the URI already says which record is meant. One given is
  # checked against the AppView's, and when they differ, against the record
  # itself (`getRecord`), since the AppView can lag an update of a feed
  # generator or a labeler. A given CID the record still has is used; one it
  # does not have is refused, naming the record's. It is not replaced: a given
  # CID says which version the caller read, and AtMcp cannot tell a miscopy
  # from a record changed since it was read, so attaching the like to another
  # version without being asked would be a surprise. A subject the AppView has
  # no view of cannot be checked: a given CID is used as given, and an omitted
  # one cannot be filled in.
  defp subject_cid(_backend, _session, _uri, cid, cid) when is_binary(cid), do: {:ok, cid}

  defp subject_cid(_backend, _session, _uri, nil, current) when is_binary(current),
    do: {:ok, current}

  defp subject_cid(_backend, _session, _uri, cid, nil) when is_binary(cid), do: {:ok, cid}
  defp subject_cid(_backend, _session, uri, nil, nil), do: {:error, {:subject_cid_unknown, uri}}

  defp subject_cid(backend, session, uri, cid, _appview) do
    case backend.get_record(session, uri) do
      {:ok, %{cid: ^cid}} ->
        {:ok, cid}

      {:ok, %{cid: record}} when is_binary(record) ->
        {:error, {:subject_cid_mismatch, uri, cid, record}}

      {:ok, _no_cid} ->
        {:error,
         AtMcp.Effects.Failure.new(:refused,
           message:
             "#{cid} is not the AppView's CID for #{uri}, and the record read back carried no CID to check it against. Nothing was sent."
         )}

      error ->
        error
    end
  end

  def unrepost(effects, repost_uri) when is_binary(repost_uri),
    do: undo(effects, :unrepost, repost_uri)

  # A follow, block or mute names its subject by DID, so a handle is resolved
  # first, with a session, like a reply's parent. A handle that names no
  # account is an ordinary answer, and nothing was sent.
  def follow(effects, actor) when is_binary(actor) do
    take_and_write(
      effects,
      :follow,
      fn backend, session ->
        with {:ok, did} <- backend.resolve_actor(session, actor),
             do: once(backend, session, :follow, did, %{actor: did})
      end,
      fn did -> fn backend, session -> backend.follow(session, did) end end
    )
  end

  def unfollow(effects, follow_uri) when is_binary(follow_uri),
    do: undo(effects, :unfollow, follow_uri)

  def block(effects, actor) when is_binary(actor) do
    take_and_write(
      effects,
      :block,
      fn backend, session ->
        with {:ok, did} <- backend.resolve_actor(session, actor),
             do: once(backend, session, :block, did, %{actor: did})
      end,
      fn did -> fn backend, session -> backend.block(session, did) end end
    )
  end

  def unblock(effects, block_uri) when is_binary(block_uri),
    do: undo(effects, :unblock, block_uri)

  # The app makes one like, repost, follow or block of a subject: it reads the
  # account's own record from the AppView (`viewer.like`, `viewer.repost`,
  # `viewer.following`, `viewer.blocking`) and offers the undo instead. A
  # second one goes wrong either way: the reference PDS's createRecord deletes
  # the first, so the uri the first call returned names nothing and an undo of
  # it changes nothing; a service that keeps both has the AppView count one,
  # and an undo of either leaves the other. So the record the AppView names,
  # once the PDS confirms it still holds it with this subject, is returned as
  # `unchanged: true`, and nothing is sent or counted. A record written
  # moments ago that the AppView has not indexed yet is not seen.
  defp once(backend, session, action, subject, summary) do
    case backend.viewer_record(session, action, subject) do
      {:ok, nil} ->
        {:ok, subject}

      {:ok, existing} ->
        {:ok, {:unchanged, Map.merge(summary, %{uri: existing, action: action, unchanged: true})}}

      error ->
        error
    end
  end

  # Relationship removal inventories every shared and old Town record of the
  # named subject and keeps its repository root through execution. Likes and
  # reposts also remove the second record named by the AppView. The backend
  # prepares each removal before anything is sent.
  defp undo(effects, action, uri) do
    take_and_write(
      effects,
      action,
      fn backend, session -> backend.prepare_undo(session, action, uri) end,
      fn prepared -> fn backend, session -> backend.undo(session, prepared) end end
    )
  end

  def mute(effects, actor) when is_binary(actor) do
    take_and_write(
      effects,
      :mute,
      fn backend, session -> backend.resolve_actor(session, actor) end,
      fn did -> fn backend, session -> backend.mute(session, did) end end
    )
  end

  def unmute(effects, actor) when is_binary(actor) do
    take_and_write(
      effects,
      :unmute,
      fn backend, session -> backend.resolve_actor(session, actor) end,
      fn did -> fn backend, session -> backend.unmute(session, did) end end
    )
  end

  def delete_post(effects, post_uri) when is_binary(post_uri) do
    take_and_write(effects, :delete_post, fn backend, session ->
      backend.delete_post(session, post_uri)
    end)
  end

  @doc """
  Change this account's profile. `updates` holds only what changes:
  `:display_name`, `:description`, `:avatar`, `:banner`, `:pronouns` and
  `:website` (`""` removes either), and `:links`, the links the profile shows,
  in order, as `%{url, title}` (`[]` removes them all). The profile record is
  read first and every other field kept.
  """
  def update_profile(effects, updates) when is_list(updates) do
    with :ok <- validate_profile(updates) do
      take_and_write(effects, :update_profile, fn backend, session ->
        backend.update_profile(session, updates)
      end)
    end
  end

  # What `actor.profile` and `actor.link` allow, and what the AppView shows: a
  # profile view carries a website only when it starts with https:// and a
  # link only when it is https and not a URL shortener (`profileWebsite` in
  # packages/bsky/src/views/index.ts, and views/profile-link-rules.ts).
  @profile_limits %{
    pronouns: %{graphemes: 20, bytes: 200},
    link_title: %{graphemes: 40, bytes: 320},
    links: 10
  }

  # `SHORTENER_DOMAINS` in the AppView's views/profile-link-rules.ts at
  # 9f66a7e: a profile link to one of these is never shown.
  @shortener_domains ~w(adf.ly bit.ly bitly.com bl.ink buff.ly clck.ru cutt.ly goo.gl is.gd
    lnkd.in ow.ly rb.gy rebrand.ly s.id short.gy shorturl.at t.co t.ly tiny.cc tinyurl.com v.gd
    x.gd)

  @doc "What `update_profile` refuses beyond: pronouns, a link's title, how many links."
  def profile_limits, do: @profile_limits

  @doc false
  def shortener_domains, do: @shortener_domains

  defp validate_profile(updates) do
    with :ok <- bounded(updates[:pronouns], "pronouns", @profile_limits.pronouns),
         :ok <- website(updates[:website]),
         :ok <- profile_links(Keyword.fetch(updates, :links)),
         :ok <- profile_labels(Keyword.fetch(updates, :labels)) do
      :ok
    end
  end

  # `com.atproto.label.defs#selfLabels`: at most 10 values, each at most 128
  # bytes.
  defp profile_labels(:error), do: :ok

  defp profile_labels({:ok, labels}) when is_list(labels) and length(labels) > 10,
    do: invalid("labels", "a record carries at most 10 self-labels; this is #{length(labels)}")

  defp profile_labels({:ok, labels}) when is_list(labels) do
    labels
    |> Enum.with_index()
    |> Enum.find_value(:ok, fn {label, i} ->
      cond do
        not is_binary(label) or label == "" or not String.valid?(label) ->
          invalid("labels[#{i}]", "must be a non-empty string")

        byte_size(label) > 128 ->
          invalid("labels[#{i}]", "may be at most 128 bytes")

        label in Enum.take(labels, i) ->
          invalid("labels[#{i}]", "#{label} is already in labels")

        true ->
          nil
      end
    end)
  end

  defp profile_labels({:ok, _other}), do: invalid("labels", "must be a list of strings")

  defp bounded(nil, _field, _limits), do: :ok

  defp bounded(text, field, %{graphemes: graphemes, bytes: bytes}) when is_binary(text) do
    cond do
      not String.valid?(text) -> invalid(field, "must be valid UTF-8")
      String.length(text) > graphemes -> invalid(field, "may be at most #{graphemes} characters")
      byte_size(text) > bytes -> invalid(field, "may be at most #{bytes} bytes")
      true -> :ok
    end
  end

  defp bounded(_text, field, _limits), do: invalid(field, "must be a string")

  defp website(nil), do: :ok
  defp website(""), do: :ok

  defp website(url) do
    if https?(url),
      do: :ok,
      else: invalid("website", "must be an https:// URL; the app shows no other")
  end

  defp https?(url) when is_binary(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: "https", host: host}} when is_binary(host) and host != "" -> true
      _ -> false
    end
  end

  defp https?(_url), do: false

  defp profile_links(:error), do: :ok

  defp profile_links({:ok, links}) when is_list(links) do
    max = @profile_limits.links

    with :ok <- served("actor.link"),
         :ok <-
           if(length(links) > max,
             do:
               invalid("links", "a profile shows at most #{max} links; this is #{length(links)}"),
             else: :ok
           ) do
      links
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, MapSet.new()}, fn {link, i}, {:ok, seen} ->
        case profile_link(link, "links[#{i}]", seen) do
          {:ok, seen} -> {:cont, {:ok, seen}}
          error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, _seen} -> :ok
        error -> error
      end
    end
  end

  defp profile_links({:ok, _other}), do: invalid("links", "must be a list of {url, title}")

  defp profile_link(%{url: url} = link, field, seen) do
    host =
      with {:ok, %URI{host: host}} when is_binary(host) <- URI.new(url), do: String.downcase(host)

    cond do
      not https?(url) ->
        invalid(field, "url must be an https:// URL; the app shows no other")

      Enum.any?(@shortener_domains, &(host == &1 or String.ends_with?(host, "." <> &1))) ->
        invalid(field, "#{host} is a URL shortener, and the app does not show a link to one")

      MapSet.member?(seen, url) ->
        invalid(field, "#{url} is already in links; the app shows each once")

      true ->
        with :ok <- bounded(Map.get(link, :title), field <> ".title", @profile_limits.link_title),
             do: {:ok, MapSet.put(seen, url)}
    end
  end

  defp profile_link(_link, field, _seen), do: invalid(field, "must be {url, title}")

  @doc """
  Mark notifications seen up to `seen_at`, now when it is nil. A `seen_at`
  that is not an ISO 8601 date-time is refused before anything is sent.

  A `seen_at` after now is sent as given, as the service accepts it and a
  caller may mean it, and the result's `note` says how far ahead it is:
  notifications that arrive before then will read as seen though nobody saw
  them.
  """
  def update_seen(effects, seen_at \\ nil) do
    # Now is kept to the millisecond: the AppView counts a notification unread
    # when it was indexed after the seen time, so a time cut to the second
    # would leave unread whatever arrived earlier in that second.
    seen =
      case seen_at do
        %DateTime{} = dt ->
          {:ok, dt}

        nil ->
          {:ok, DateTime.utc_now() |> DateTime.truncate(:millisecond)}

        iso when is_binary(iso) ->
          case DateTime.from_iso8601(iso) do
            {:ok, dt, _} ->
              {:ok, dt}

            {:error, _} ->
              invalid(
                "seen_at",
                "must be an ISO 8601 date-time with a time zone, e.g. 2026-01-01T12:00:00Z; got #{inspect(iso)}"
              )
          end
      end

    with {:ok, seen} <- seen,
         {:ok, result} <-
           take_and_write(effects, :update_seen, fn backend, session ->
             backend.update_seen(session, seen)
           end) do
      {:ok, seen_ahead(result, seen, DateTime.utc_now())}
    end
  end

  defp seen_ahead(result, seen, now) do
    case DateTime.diff(seen, now, :second) do
      ahead when ahead > 0 ->
        Map.put(
          result,
          :note,
          "seen_at is #{span(ahead)} after now (#{DateTime.to_iso8601(DateTime.truncate(now, :second))}): " <>
            "notifications that arrive before then will read as seen"
        )

      _ ->
        result
    end
  end

  # A span of seconds in its two largest units: `1 min 50 s`, `3 d 4 h`.
  defp span(seconds) do
    [{86_400, "d"}, {3_600, "h"}, {60, "min"}, {1, "s"}]
    |> Enum.map_reduce(seconds, fn {size, unit}, left ->
      {{div(left, size), unit}, rem(left, size)}
    end)
    |> elem(0)
    |> Enum.drop_while(fn {n, _} -> n == 0 end)
    |> Enum.take(2)
    |> Enum.reject(fn {n, _} -> n == 0 end)
    |> Enum.map_join(" ", fn {n, unit} -> "#{n} #{unit}" end)
  end

  # --- saved feeds, live status, feed feedback ---

  @doc """
  Save a custom feed or a list to this account's feeds, pinned (shown as a tab
  on the home screen) or not. A feed already saved is pinned or unpinned as
  asked, and one already as asked, or saved with `pinned` nil, is left alone;
  a new one saved with `pinned` nil is not pinned. Saved feeds are a preference
  (`savedFeedsPrefV2`); the preferences are read and written back whole, and
  `actor.putPreferences` has no compare-and-swap, so a change another client
  makes between the read and the write is lost.
  """
  def save_feed(effects, uri, pinned) when is_binary(uri),
    do: saved_feed(effects, :save_feed, uri, pinned)

  @doc "Remove a custom feed or a list from this account's saved feeds."
  def unsave_feed(effects, uri) when is_binary(uri),
    do: saved_feed(effects, :unsave_feed, uri, nil)

  defp saved_feed(effects, verb, uri, pinned) do
    with {:ok, _} <-
           record_argument(uri, "uri", [:generator, :list], "a feed generator or a list"),
         :ok <-
           if(verb == :unsave_feed or is_nil(pinned) or is_boolean(pinned),
             do: :ok,
             else: invalid("pinned", "must be true or false")
           ) do
      take_and_write(
        effects,
        verb,
        fn backend, session ->
          with {:ok, uri} <- did_uri(backend, session, uri),
               do: backend.prepare_saved_feed(session, {verb, uri, pinned})
        end,
        fn prepared -> fn backend, session -> backend.write_preferences(session, prepared) end end
      )
    end
  end

  # --- settings: preferences, notification settings, activity subscriptions ---

  @doc """
  The account's settings as the app shows them (`AtMcp.Preferences`): each
  preference kind, the saved feeds, whether to hide the account's posts from
  recommendations, and who may subscribe to its posts.
  """
  def get_preferences(effects),
    do: with_session(effects, fn backend, session -> backend.get_preferences(session) end)

  @doc """
  Change one kind of setting (`AtMcp.Preferences.kinds/0`): the fields given
  in `fields` (a map, `nil` for one not given) and nothing else. The request
  is read before a session is taken. The preferences, or the declaration
  record, are read first, so a setting already as asked is left alone
  (`unchanged`) and the result names the fields that changed with their
  values before and after. A list in `reply_rule` named by a handle is
  written in its DID form.
  """
  def set_preference(effects, kind, fields) when is_map(fields) do
    with {:ok, kind, changes} <- AtMcp.Preferences.request(kind, fields) do
      take_and_write(
        effects,
        :set_preference,
        fn backend, session -> backend.prepare_preference(session, {kind, changes}) end,
        fn prepared -> fn backend, session -> backend.write_preference(session, prepared) end end
      )
    end
  end

  @doc "The account's notification settings, one per reason (`AtMcp.Preferences`)."
  def get_notification_settings(effects),
    do:
      with_session(effects, fn backend, session -> backend.get_notification_settings(session) end)

  @doc """
  Change the notification setting of one reason: `include` (`all` or
  `follows`, for the reasons that take it), `list` and `push`, each left as it
  is when nil. The settings are read first, so one already as asked is left
  alone.
  """
  def set_notification_setting(effects, reason, opts) when is_list(opts) do
    with {:ok, reason, changes} <- AtMcp.Preferences.notification_request(reason, opts) do
      take_and_write(
        effects,
        :set_notification_setting,
        fn backend, session ->
          backend.prepare_notification_setting(session, {reason, changes})
        end,
        fn prepared ->
          fn backend, session -> backend.write_notification_setting(session, prepared) end
        end
      )
    end
  end

  @doc """
  Subscribe to an account's posts (`posts`), and to its replies too
  (`replies`), as the app's bell on a profile does; both false unsubscribes.
  The account is read first: one whose own setting does not let this account
  subscribe is refused, as the app offers no bell for it, and a subscription
  already as asked is left alone.
  """
  def subscribe_to_activity(effects, actor, posts, replies) when is_binary(actor) do
    with :ok <- boolean_argument(posts, "posts"),
         :ok <- boolean_argument(replies, "replies"),
         :ok <-
           if(replies and not posts,
             do:
               invalid(
                 "replies",
                 "the app subscribes to replies only with posts; give posts true as well"
               ),
             else: :ok
           ) do
      take_and_write(
        effects,
        :subscribe_to_activity,
        fn backend, session ->
          with :ok <-
                 if(own_actor?(session, actor),
                   do: invalid("actor", "an account cannot subscribe to its own posts"),
                   else: :ok
                 ),
               {:ok, did} <- backend.resolve_actor(session, actor),
               # A handle in another case, or another handle of this account,
               # resolves to its own DID.
               :ok <-
                 if(did == did_of(session),
                   do: invalid("actor", "an account cannot subscribe to its own posts"),
                   else: :ok
                 ),
               do:
                 backend.prepare_activity_subscription(session, did, %{
                   posts: posts,
                   replies: replies
                 })
        end,
        fn prepared ->
          fn backend, session -> backend.put_activity_subscription(session, prepared) end
        end
      )
    end
  end

  defp boolean_argument(value, _field) when is_boolean(value), do: :ok
  defp boolean_argument(_value, field), do: invalid(field, "must be true or false")

  @doc "The accounts this account is subscribed to, with what it gets of each."
  def get_activity_subscriptions(effects, opts \\ []) do
    paged(effects, opts, fn backend, session, page ->
      backend.get_activity_subscriptions(session, page)
    end)
  end

  # --- moderation: reports, muted words, moderation lists, labelers ---

  @doc """
  Report a post, list, feed, starter pack or account to a moderation service.
  `subject` is an AT URI, or a handle or DID for an account; `reason` one of
  `AtMcp.Moderation.reasons/0`; `opts` takes `:details` and `:labeler` (a
  handle or DID; the network's own moderation service when nil). Everything
  the report names is read before it is sent: the service must be one this
  account subscribes to, or the network's own, and must take reports on this
  kind of subject and for this reason, as the app's report dialog checks. A
  report reaches the people who moderate that service; it cannot be
  withdrawn.
  """
  def report(effects, subject, reason, opts \\ []) when is_binary(subject) do
    details = present(opts[:details])
    labeler = present(opts[:labeler])

    with :ok <- served_nsid("com.atproto.moderation.createReport"),
         {:ok, reason} <- AtMcp.Moderation.reason(reason),
         :ok <- report_details(details),
         {:ok, named} <- report_subject(subject) do
      take_and_write(
        effects,
        :report,
        fn backend, session ->
          with {:ok, subject} <- resolve_report_subject(backend, session, named),
               {:ok, service} <- report_service(backend, session, labeler) do
            backend.prepare_report(session, %{
              subject: subject,
              reason: reason,
              details: details,
              labeler: service
            })
          end
        end,
        fn prepared -> fn backend, session -> backend.send_report(session, prepared) end end
      )
    end
  end

  # `createReport.reason`: at most 20,000 bytes and 2,000 graphemes.
  defp report_details(nil), do: :ok

  defp report_details(details) when is_binary(details) do
    cond do
      not String.valid?(details) -> invalid("details", "must be valid UTF-8")
      byte_size(details) > 20_000 -> invalid("details", "may be at most 20000 bytes")
      String.length(details) > 2_000 -> invalid("details", "may be at most 2000 characters")
      true -> :ok
    end
  end

  defp report_details(_details), do: invalid("details", "must be a string")

  # What the app's report dialog reports (`parseReportSubject` in social-app's
  # ReportDialog/utils at 485405a): a post, list, feed or starter pack, or an
  # account. A live status and a profile link go only to Bluesky's own
  # service in the app, and are not offered here.
  defp report_subject("at://" <> _ = uri) do
    with {:ok, parts} <-
           record_argument(
             uri,
             "subject",
             [:post, :list, :generator, :starter_pack],
             "a post, list, feed or starter pack, or a handle or DID for an account"
           ),
         do: {:ok, {:record, parts}}
  end

  defp report_subject(actor) do
    case present(actor) do
      nil -> invalid("subject", "must be an AT URI, or a handle or DID for an account")
      actor -> {:ok, {:account, actor}}
    end
  end

  # The app offers no report of the account's own posts, lists or itself.
  defp resolve_report_subject(backend, session, {:record, {repo, collection, rkey}}) do
    with :ok <- not_own_report(session, repo),
         {:ok, did} <- backend.resolve_actor(session, repo),
         :ok <- not_own_report(session, did),
         do: {:ok, {:record, "at://#{did}/#{collection}/#{rkey}", collection}}
  end

  defp resolve_report_subject(backend, session, {:account, actor}) do
    with :ok <- not_own_report(session, actor),
         {:ok, did} <- backend.resolve_actor(session, actor),
         :ok <- not_own_report(session, did),
         do: {:ok, {:account, did}}
  end

  defp not_own_report(session, actor) do
    if own_actor?(session, actor),
      do:
        invalid(
          "subject",
          "this is this account or its own record; the app offers no report of either"
        ),
      else: :ok
  end

  defp report_service(_backend, _session, nil) do
    case AtMcp.Network.moderation_service() do
      nil ->
        invalid(
          "labeler",
          "#{AtMcp.Network.label()} names no moderation service of its own, so give the labeler to send the report to"
        )

      did ->
        {:ok, did}
    end
  end

  defp report_service(backend, session, labeler), do: backend.resolve_actor(session, labeler)

  defp served_nsid(nsid) do
    case AtMcp.Endpoints.not_served(AtMcp.Network.name(), nsid) do
      nil -> :ok
      evidence -> {:error, {:not_served, nsid, evidence}}
    end
  end

  @doc """
  Mute a word, tag or phrase (`AtMcp.Moderation.word_request/2`): `opts` takes
  `:tags_only`, `:duration` and `:only_non_followed`. A word muted already is
  changed to what is asked rather than muted twice; one already muted exactly
  so is left alone.
  """
  def mute_word(effects, value, opts \\ []) do
    with {:ok, word} <- AtMcp.Moderation.word_request(value, opts),
         do: moderation_preference(effects, :mute_word, {:mute_word, word})
  end

  @doc "Unmute every muted word with this value, ignoring case."
  def unmute_word(effects, value) do
    with {:ok, value} <- AtMcp.Moderation.unmute_request(value),
         do: moderation_preference(effects, :unmute_word, {:unmute_word, value})
  end

  @doc """
  Subscribe to a labeler (`subscribe?` true) or unsubscribe from one. The
  account is read first: one that runs no labeler is refused, and so is the
  network's own moderation service, which every account has.
  """
  def subscribe_labeler(effects, actor, subscribe?) when is_binary(actor) do
    verb = if subscribe?, do: :subscribe_labeler, else: :unsubscribe_labeler

    take_and_write(
      effects,
      verb,
      fn backend, session ->
        with {:ok, did} <- backend.resolve_actor(session, actor),
             do: backend.prepare_moderation_preference(session, {verb, did})
      end,
      fn prepared -> fn backend, session -> backend.write_preferences(session, prepared) end end
    )
  end

  @doc """
  What the app does with a label: `show`, `warn` or `hide`. Without
  `labeler`, one of the four labels of the app's moderation screen
  (`AtMcp.Moderation.global_labels/0`), whichever labeler applies it; with
  one, a label that labeler defines.
  """
  def set_label_visibility(effects, label, visibility, labeler \\ nil) do
    labeler = present(labeler)

    with {:ok, stored} <- label_visibility(visibility),
         :ok <- label_argument(label, labeler) do
      take_and_write(
        effects,
        :set_label_visibility,
        fn backend, session ->
          with {:ok, did} <-
                 if(labeler, do: backend.resolve_actor(session, labeler), else: {:ok, nil}),
               do:
                 backend.prepare_moderation_preference(
                   session,
                   {:set_label_visibility, label, stored, did}
                 )
        end,
        fn prepared -> fn backend, session -> backend.write_preferences(session, prepared) end end
      )
    end
  end

  defp label_visibility(visibility) do
    case AtMcp.Moderation.stored_visibility(visibility) do
      {:ok, stored} -> {:ok, stored}
      :error -> invalid("visibility", "must be show, warn or hide")
    end
  end

  defp label_argument(label, nil) do
    if label in AtMcp.Moderation.global_labels(),
      do: :ok,
      else:
        invalid(
          "label",
          "without labeler, must be one of the labels of the app's moderation screen: #{Enum.join(AtMcp.Moderation.global_labels(), ", ")}; a label a labeler defines takes that labeler"
        )
  end

  defp label_argument(label, _labeler) when is_binary(label) and label != "", do: :ok
  defp label_argument(_label, _labeler), do: invalid("label", "must be a label's identifier")

  defp moderation_preference(effects, verb, request) do
    take_and_write(
      effects,
      verb,
      fn backend, session -> backend.prepare_moderation_preference(session, request) end,
      fn prepared -> fn backend, session -> backend.write_preferences(session, prepared) end end
    )
  end

  @doc """
  Mute every account on a moderation list (`graph.muteActorList`), or unmute
  them. The list is read first, so a list that is gone, or one that is not a
  moderation list, is refused before anything is sent; the app offers muting
  for moderation lists alone. The service keeps the mute by the list's AT URI
  in DID form.
  """
  def mute_list(effects, uri) when is_binary(uri), do: list_mute(effects, :mute_list, uri)
  def unmute_list(effects, uri) when is_binary(uri), do: list_mute(effects, :unmute_list, uri)

  defp list_mute(effects, verb, uri) do
    with {:ok, _parts} <- record_argument(uri, "uri", [:list], "a list") do
      take_and_write(
        effects,
        verb,
        fn backend, session ->
          with {:ok, uri} <- did_uri(backend, session, uri),
               do: backend.prepare_list_mute(session, {verb, uri})
        end,
        fn prepared -> fn backend, session -> backend.mute_list(session, prepared) end end
      )
    end
  end

  @doc """
  Block every account on a moderation list: a `graph.listblock` record naming
  the list in DID form. The list is read first; the app offers blocking for
  moderation lists alone. A list this account blocks already is left as it
  is, and the result names that block.
  """
  def block_list(effects, uri) when is_binary(uri) do
    with {:ok, _parts} <- record_argument(uri, "uri", [:list], "a list") do
      list_write(effects, :block_list, fn backend, session ->
        with {:ok, uri} <- did_uri(backend, session, uri), do: {:ok, {:block_list, uri}}
      end)
    end
  end

  @doc """
  Stop blocking the accounts on a list: every `graph.listblock` record of
  this account's that names it is deleted. `uri` is the list, or one of those
  records.
  """
  def unblock_list(effects, uri) when is_binary(uri) do
    with {:ok, {_repo, collection, _rkey} = parts} <-
           record_argument(uri, "uri", [:list, :list_block], "a list or a list block") do
      list_write(effects, :unblock_list, fn backend, session ->
        if AtMcp.Network.collection?(collection, :list_block) do
          with {:ok, uri} <-
                 own_record(
                   session,
                   parts,
                   "uri",
                   "unblock_list deletes a list block this account made"
                 ),
               do: {:ok, {:unblock_list, uri}}
        else
          with {:ok, uri} <- did_uri(backend, session, uri), do: {:ok, {:unblock_list, uri}}
        end
      end)
    end
  end

  @doc "The moderation lists this account mutes (`muted`) or blocks (`blocked`), a page at a time."
  def get_moderation_lists(effects, kind, opts \\ []) do
    if kind in ["muted", "blocked"] do
      paged(effects, opts, fn backend, session, page ->
        backend.get_moderation_lists(session, kind, page)
      end)
    else
      invalid("kind", "must be muted or blocked")
    end
  end

  @doc """
  Labelers in detail: the labels each defines and its policies, what reports
  it takes, and this account's settings for it. `actors` are handles or DIDs;
  none reads the labelers this account takes labels from.
  """
  def get_labelers(effects, actors) when is_list(actors) do
    with :ok <- if(actors == [], do: :ok, else: validate_batch(actors)) do
      with_session(effects, fn backend, session ->
        with {:ok, dids} <- resolve_actors(backend, session, Enum.uniq(actors)),
             do: backend.get_labelers(session, if(dids == [], do: nil, else: Enum.uniq(dids)))
      end)
    end
  end

  # The AppView counts a live status as lasting at least 5 minutes and at
  # most 4 hours, whatever the record says (`status` in
  # packages/bsky/src/views/index.ts), so a duration outside that is refused
  # rather than written as one thing and shown as another.
  @status_minutes 5..240

  @doc "How long a live status may last, in minutes, as the AppView shows one."
  def status_minutes, do: @status_minutes

  @doc """
  Say this account is live: `kind` `"live"` with `:url` (where to watch),
  `:duration_minutes` and optionally the link card's `:title` and
  `:description`; or `"clear"` to end it. The status record is read first, so
  the result names what it replaced.
  """
  def set_status(effects, kind, opts \\ []) do
    with {:ok, request} <- status_request(kind, opts) do
      take_and_write(
        effects,
        :set_status,
        fn backend, session -> backend.prepare_status(session, request) end,
        fn prepared -> fn backend, session -> backend.write_status(session, prepared) end end
      )
    end
  end

  defp status_request("clear", _opts), do: {:ok, :clear}

  defp status_request("live", opts) do
    minutes = opts[:duration_minutes]
    first..last//_ = @status_minutes

    cond do
      not https_or_http?(opts[:url]) ->
        invalid("url", "must be an http or https URL: where to watch")

      not is_integer(minutes) or minutes not in @status_minutes ->
        invalid(
          "duration_minutes",
          "must be #{first} to #{last}: the AppView shows a live status for no less than #{first} minutes and no more than #{last}"
        )

      true ->
        with :ok <- optional_text(opts[:title], "title"),
             :ok <- optional_text(opts[:description], "description") do
          {:ok,
           {:live,
            %{
              url: opts[:url],
              minutes: minutes,
              title: opts[:title],
              description: opts[:description]
            }}}
        end
    end
  end

  defp status_request(_kind, _opts), do: invalid("kind", "must be live or clear")

  defp https_or_http?(url) when is_binary(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host}}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        true

      _ ->
        false
    end
  end

  defp https_or_http?(_url), do: false

  defp optional_text(nil, _field), do: :ok
  defp optional_text(text, _field) when is_binary(text), do: :ok
  defp optional_text(_text, field), do: invalid(field, "must be a string")

  @feedback_events %{"show_more" => :request_more, "show_less" => :request_less}

  # The feeds the app always offers feedback on, whatever their generator
  # says: Bluesky's own Discover and video feeds, in production and staging
  # (`FEEDBACK_FEEDS` = `PROD_FEEDS` ++ `STAGING_FEEDS` in social-app's
  # src/lib/constants.ts, read by `isDiscoverFeed` in
  # src/state/feed-feedback.tsx at 485405a). Its rule is
  # `isDiscover || feed.acceptsInteractions` (lines 72-76). Feeds of the
  # trending account (`TRENDING_DID`) need `acceptsInteractions` like any
  # other: `isTrendingFeed` only widens which events those feeds get, and
  # show more and show less are allowed for every feed
  # (`THIRD_PARTY_ALLOWED_INTERACTIONS`).
  @feedback_feeds [
    "at://did:plc:z72i7hdynmk6r22z27h6tvur/app.bsky.feed.generator/whats-hot",
    "at://did:plc:z72i7hdynmk6r22z27h6tvur/app.bsky.feed.generator/thevids",
    "at://did:plc:yofh3kx63drvfljkibw5zuxo/app.bsky.feed.generator/whats-hot",
    "at://did:plc:yofh3kx63drvfljkibw5zuxo/app.bsky.feed.generator/thevids"
  ]

  @doc "The feeds the app offers feedback on whatever their generator says."
  def feedback_feeds, do: @feedback_feeds

  @doc """
  Whether the app offers feedback on the feed at `uri` (in DID form) whose
  generator says `accepts_interactions`: one of `feedback_feeds/0`, or one
  that accepts interactions.
  """
  def takes_feedback?(uri, accepts_interactions),
    do: uri in @feedback_feeds or accepts_interactions == true

  # `feed.defs#interaction` bounds what a feed generator gave its item.
  @feedback_limits %{feed_context: 2000, req_id: 100}

  @doc false
  def feedback_limits, do: @feedback_limits

  @doc """
  Tell a custom feed to show more, or less, like one of its posts, as the
  app's menu on a feed item does. The feed is read first: one whose generator
  does not take feedback is refused before anything is sent. `:feed_context`
  and `:req_id` are what the feed gave the item when it served it.
  """
  def feed_feedback(effects, feed, uri, kind, opts \\ [])
      when is_binary(feed) and is_binary(uri) do
    with :ok <- served("feed.sendInteractions"),
         {:ok, _} <- record_argument(feed, "feed", [:generator], "a feed generator"),
         {:ok, _} <- post_uri(uri, "uri"),
         {:ok, event} <- feedback_event(kind),
         :ok <- feedback_text(opts[:feed_context], "feed_context"),
         :ok <- feedback_text(opts[:req_id], "req_id") do
      take_and_write(
        effects,
        :feed_feedback,
        fn backend, session ->
          with {:ok, feed} <- did_uri(backend, session, feed),
               {:ok, uri} <- did_uri(backend, session, uri) do
            backend.prepare_feed_feedback(session, %{
              feed: feed,
              item: uri,
              event: event,
              kind: kind,
              feed_context: opts[:feed_context],
              req_id: opts[:req_id]
            })
          end
        end,
        fn prepared ->
          fn backend, session -> backend.send_feed_feedback(session, prepared) end
        end
      )
    end
  end

  defp feedback_event(kind) do
    case Map.fetch(@feedback_events, kind) do
      {:ok, event} -> {:ok, event}
      :error -> invalid("kind", "must be show_more or show_less")
    end
  end

  defp feedback_text(nil, _field), do: :ok

  defp feedback_text(text, field) when is_binary(text) do
    max = Map.fetch!(@feedback_limits, String.to_existing_atom(field))

    if byte_size(text) <= max,
      do: :ok,
      else: invalid(field, "may be at most #{max} bytes, as the feed gave it")
  end

  defp feedback_text(_text, field), do: invalid(field, "must be a string")

  # --- lists and starter packs ---

  # The words the list tools use for a list's purpose, and the tokens the
  # service takes. A starter pack's list (`reference`) is made with its pack,
  # and `graph.getLists` does not return one.
  @list_purposes %{"curate" => :curatelist, "moderation" => :modlist}

  @doc "The purposes `create_list` and `get_lists` take, and the record token each names."
  def list_purposes, do: @list_purposes

  def get_list(effects, uri, opts \\ []) when is_binary(uri) do
    paged(effects, opts, fn backend, session, opts ->
      with {:ok, uri} <- did_uri(backend, session, uri), do: backend.get_list(session, uri, opts)
    end)
  end

  @doc """
  The lists an account made (`:actor`, this account when it is absent), or,
  with `:contains`, this account's lists, each with the list item that puts
  that account on it. `:purpose` keeps one kind.
  """
  def get_lists(effects, opts \\ []) do
    actor = present(opts[:actor])
    contains = present(opts[:contains])

    with {:ok, purposes} <- list_purpose_filter(opts[:purpose]) do
      paged(effects, Keyword.take(opts, [:limit, :cursor]), fn backend, session, page ->
        page = Keyword.put(page, :purposes, purposes)

        cond do
          is_nil(contains) ->
            backend.get_lists(session, actor || did_of(session), page)

          is_nil(actor) or AtMcp.Interactions.own_repo?(session, actor) ->
            backend.get_lists_with_membership(session, contains, page)

          true ->
            invalid(
              "actor",
              "with contains, the lists read are this account's own, so leave actor out"
            )
        end
      end)
    end
  end

  def get_starter_pack(effects, uri) when is_binary(uri) do
    with_session(effects, fn backend, session ->
      with {:ok, uri} <- did_uri(backend, session, uri),
           do: backend.get_starter_pack(session, uri)
    end)
  end

  @doc """
  The DID of the account a handle or DID names: a DID as given, this
  account's own handle without a read, any other handle resolved. One that
  does not resolve is `{:handle_not_resolved, handle}`.
  """
  def actor_did(_effects, "did:" <> _ = did), do: {:ok, did}

  def actor_did(effects, handle) when is_binary(handle) do
    with_session(effects, fn backend, session ->
      if AtMcp.Interactions.own_repo?(session, handle),
        do: {:ok, did_of(session)},
        else: backend.resolve_actor(session, handle)
    end)
  end

  # A list or starter pack named by an AT URI whose repository is a handle, in
  # the DID form records and the AppView name it by. The AppView looks a list
  # up by the URI string it is given, so a handle-form URI of a real list is
  # "List not found". This account's handle is its DID without a read; any
  # other handle is resolved, and one that does not resolve is
  # `{:handle_not_resolved, handle}`. A string that is not an AT URI is left
  # for the service to refuse.
  @doc false
  def did_uri(backend, session, uri) do
    case AtMcp.ATProto.parse_uri(uri) do
      {:ok, {"did:" <> _, _collection, _rkey}} ->
        {:ok, uri}

      {:ok, {repo, collection, rkey}} ->
        did =
          if AtMcp.Interactions.own_repo?(session, repo),
            do: {:ok, did_of(session)},
            else: backend.resolve_actor(session, repo)

        with {:ok, did} <- did, do: {:ok, "at://#{did}/#{collection}/#{rkey}"}

      {:error, _} ->
        {:ok, uri}
    end
  end

  @doc """
  Starter packs by exactly one of `:actor` (the packs that account made),
  `:query` (a search) or `:contains` (this account's packs, each with the list
  item that puts that account in it).
  """
  def get_starter_packs(effects, opts \\ []) do
    given = for key <- [:actor, :query, :contains], value = present(opts[key]), do: {key, value}

    case given do
      [{key, value}] ->
        paged(effects, Keyword.take(opts, [:limit, :cursor]), fn backend, session, page ->
          case key do
            :actor -> backend.get_actor_starter_packs(session, value, page)
            :query -> backend.search_starter_packs(session, value, page)
            :contains -> backend.get_starter_packs_with_membership(session, value, page)
          end
        end)

      _ ->
        invalid(
          "query",
          "give exactly one of actor, query or contains; this call gave #{given_names(given)}"
        )
    end
  end

  defp given_names([]), do: "none"
  defp given_names(given), do: Enum.map_join(given, " and ", fn {key, _} -> key end)

  @doc """
  Make a list. `fields`: `:name`, `:purpose` (`"curate"` or `"moderation"`),
  and optionally `:description` and `:avatar` (`%{data, mime_type}`).
  """
  def create_list(effects, fields) when is_map(fields) do
    with {:ok, purpose} <- list_purpose(fields[:purpose]),
         :ok <- text_argument(fields[:name] || "", "name", :list_name),
         :ok <- text_argument(fields[:description], "description", :description),
         :ok <- list_avatar(fields[:avatar]) do
      request =
        {:create_list,
         Map.merge(Map.take(fields, [:name, :description, :avatar]), %{purpose: purpose})}

      list_write(effects, :create_list, fn _backend, _session -> {:ok, request} end)
    end
  end

  @doc """
  Change a list of this account's. `changes` holds only what changes: `:name`,
  `:description` (`""` removes it) and `:avatar`. The list record is read
  first and every other field kept.
  """
  def update_list(effects, uri, changes) when is_binary(uri) and is_map(changes) do
    with {:ok, parts} <- record_argument(uri, "uri", [:list], "a list"),
         :ok <- some_change(changes, "name, description or avatar"),
         :ok <- text_argument(changes[:name], "name", :list_name),
         :ok <- text_argument(changes[:description], "description", :description),
         :ok <- list_avatar(changes[:avatar]) do
      list_write(effects, :update_list, fn _backend, session ->
        with {:ok, uri} <-
               own_record(session, parts, "uri", "update_list changes a list this account made") do
          {:ok, {:update_list, uri, changes}}
        end
      end)
    end
  end

  @doc "Delete a list of this account's and every list item on it, in one commit."
  def delete_list(effects, uri) when is_binary(uri) do
    with {:ok, parts} <- record_argument(uri, "uri", [:list], "a list") do
      list_write(effects, :delete_list, fn _backend, session ->
        with {:ok, uri} <-
               own_record(session, parts, "uri", "delete_list deletes a list this account made") do
          {:ok, {:delete_list, uri}}
        end
      end)
    end
  end

  @doc """
  Put an account on a list of this account's. `list` is the list's AT URI or
  a starter pack's, whose list it then is. A handle is resolved first.
  """
  def add_to_list(effects, list, actor) when is_binary(list) and is_binary(actor),
    do: membership(effects, :add_to_list, list, actor)

  @doc """
  Take an account off a list of this account's: every list item that puts it
  there is deleted, found by reading the account's list items.
  """
  def remove_from_list(effects, list, actor) when is_binary(list) and is_binary(actor),
    do: membership(effects, :remove_from_list, list, actor)

  defp membership(effects, verb, list, actor) do
    with {:ok, parts} <-
           record_argument(list, "list", [:list, :starter_pack], "a list or a starter pack") do
      list_write(effects, verb, fn backend, session ->
        with {:ok, list} <-
               own_record(
                 session,
                 parts,
                 "list",
                 "#{verb} changes a list or starter pack this account made"
               ),
             {:ok, did} <- backend.resolve_actor(session, actor) do
          {:ok, {verb, list, did}}
        end
      end)
    end
  end

  @doc """
  Make a starter pack: its list of `:actors` (handles or DIDs, resolved
  first), the pack naming it and up to three `:feeds`, all in one commit.
  `fields` also takes `:name` and `:description`.
  """
  def create_starter_pack(effects, fields) when is_map(fields) do
    actors = Enum.uniq(List.wrap(fields[:actors]))
    max = max_pack_actors()

    with :ok <- text_argument(fields[:name] || "", "name", :pack_name),
         :ok <- text_argument(fields[:description], "description", :description),
         :ok <- pack_feeds(fields[:feeds]),
         :ok <-
           if(length(actors) > max,
             do:
               invalid(
                 "actors",
                 "a starter pack is made in one commit, which holds at most #{max} accounts; this call gave #{length(actors)}"
               ),
             else: :ok
           ) do
      list_write(effects, :create_starter_pack, fn backend, session ->
        with {:ok, dids} <- resolve_actors(backend, session, actors) do
          {:ok,
           {:create_starter_pack,
            fields |> Map.take([:name, :description, :feeds]) |> Map.put(:actors, Enum.uniq(dids))}}
        end
      end)
    end
  end

  @doc """
  Change a starter pack of this account's: `:name`, `:description` (`""`
  removes it) or `:feeds` (`[]` removes them). Its accounts change with
  `add_to_list` and `remove_from_list`.
  """
  def update_starter_pack(effects, uri, changes) when is_binary(uri) and is_map(changes) do
    with {:ok, parts} <- record_argument(uri, "uri", [:starter_pack], "a starter pack"),
         :ok <- some_change(changes, "name, description or feeds"),
         :ok <- text_argument(changes[:name], "name", :pack_name),
         :ok <- text_argument(changes[:description], "description", :description),
         :ok <- pack_feeds(changes[:feeds]) do
      list_write(effects, :update_starter_pack, fn _backend, session ->
        with {:ok, uri} <-
               own_record(
                 session,
                 parts,
                 "uri",
                 "update_starter_pack changes a starter pack this account made"
               ) do
          {:ok, {:update_starter_pack, uri, changes}}
        end
      end)
    end
  end

  @doc "Delete a starter pack of this account's, its list and the list's items."
  def delete_starter_pack(effects, uri) when is_binary(uri) do
    with {:ok, parts} <- record_argument(uri, "uri", [:starter_pack], "a starter pack") do
      list_write(effects, :delete_starter_pack, fn _backend, session ->
        with {:ok, uri} <-
               own_record(
                 session,
                 parts,
                 "uri",
                 "delete_starter_pack deletes a starter pack this account made"
               ) do
          {:ok, {:delete_starter_pack, uri}}
        end
      end)
    end
  end

  @doc """
  Ask to be left out of a starter pack's list, anyone's (`opted_out` true), or
  take that back (false). `list` is the pack's AT URI or its list's.
  """
  def set_list_opt_out(effects, list, opted_out) when is_binary(list) do
    with {:ok, _parts} <-
           record_argument(list, "list", [:list, :starter_pack], "a starter pack or its list"),
         :ok <-
           if(is_boolean(opted_out),
             do: :ok,
             else: invalid("opted_out", "must be true or false")
           ) do
      list_write(effects, :set_list_opt_out, fn backend, session ->
        with {:ok, list} <- did_uri(backend, session, list),
             do: {:ok, {:set_list_opt_out, list, opted_out}}
      end)
    end
  end

  # Every list and starter pack write. Its arguments were checked before this,
  # without a session. `request` then runs with one: a record in another
  # account's repository is refused and a handle is resolved, still before
  # anything is sent. The backend reads what the write keeps or removes and
  # builds every record, and one dispatch writes them.
  defp list_write(effects, verb, request) do
    take_and_write(
      effects,
      verb,
      fn backend, session ->
        with {:ok, request} <- request.(backend, session),
             do: backend.prepare_list_write(session, request)
      end,
      fn prepared -> fn backend, session -> backend.write_list(session, prepared) end end
    )
  end

  defp resolve_actors(backend, session, actors) do
    Enum.reduce_while(actors, {:ok, []}, fn actor, {:ok, dids} ->
      case backend.resolve_actor(session, actor) do
        {:ok, did} -> {:cont, {:ok, dids ++ [did]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  @doc """
  The most accounts `create_starter_pack` takes. A starter pack, its list and
  the list's items are made in one `applyWrites`, so this is that commit's
  writes less the two records that are not items.
  """
  def max_pack_actors, do: AtMcp.ATProto.max_writes() - 2

  defp list_purpose(purpose) do
    case Map.fetch(@list_purposes, purpose) do
      {:ok, token} -> {:ok, token}
      :error -> invalid("purpose", "must be curate or moderation")
    end
  end

  # `graph.getLists` takes the token's own name, which is the same on every
  # network.
  defp list_purpose_filter(nil), do: {:ok, []}

  defp list_purpose_filter(purpose) do
    with {:ok, token} <- list_purpose(purpose), do: {:ok, [Atom.to_string(token)]}
  end

  # What `graph.list` and `graph.starterpack` allow in their free text, as
  # `{fewest bytes, most bytes, most graphemes}`. The two networks' lexicons
  # declare the same numbers, so they are not read from vendored copies;
  # `test/at_mcp/lists_test.exs` checks them against the lexicon.
  @text_limits %{
    list_name: {1, 64, nil},
    pack_name: {1, 500, 50},
    description: {0, 3000, 300}
  }

  @doc false
  def text_limits, do: @text_limits

  defp text_argument(nil, _field, _kind), do: :ok

  defp text_argument(text, field, kind) when is_binary(text) do
    {min, bytes, graphemes} = Map.fetch!(@text_limits, kind)

    cond do
      not String.valid?(text) ->
        invalid(field, "must be valid UTF-8")

      byte_size(text) < min ->
        invalid(field, "must not be empty")

      byte_size(text) > bytes ->
        invalid(field, "may be at most #{bytes} bytes; this is #{byte_size(text)}")

      graphemes && String.length(text) > graphemes ->
        invalid(
          field,
          "may be at most #{graphemes} characters; this is #{String.length(text)}"
        )

      true ->
        :ok
    end
  end

  defp text_argument(_other, field, _kind), do: invalid(field, "must be a string")

  # `graph.list` takes a PNG or JPEG avatar of at most 1,000,000 bytes.
  @avatar_types ["image/png", "image/jpeg"]
  @avatar_bytes 1_000_000

  defp list_avatar(nil), do: :ok

  defp list_avatar(%{data: data, mime_type: type}) do
    cond do
      type not in @avatar_types ->
        invalid("avatar", "must be image/png or image/jpeg; this is #{type}")

      byte_size(data) > @avatar_bytes ->
        invalid(
          "avatar",
          "may be at most #{@avatar_bytes} bytes; this is #{byte_size(data)}"
        )

      true ->
        :ok
    end
  end

  # `graph.starterpack` recommends at most three feeds, each a feed generator.
  defp pack_feeds(nil), do: :ok

  defp pack_feeds(feeds) when is_list(feeds) do
    cond do
      length(feeds) > 3 ->
        invalid("feeds", "a starter pack recommends at most 3 feeds")

      true ->
        Enum.reduce_while(feeds, :ok, fn feed, :ok ->
          case record_argument(feed, "feeds", [:generator], "a feed generator") do
            {:ok, _} -> {:cont, :ok}
            error -> {:halt, error}
          end
        end)
    end
  end

  defp some_change(changes, names) do
    if Enum.any?(changes, fn {_key, value} -> not is_nil(value) end),
      do: :ok,
      else: invalid("name", "give #{names} to change")
  end

  # A tool argument that names a record: an AT URI whose collection is one of
  # `kinds` on either network. Checked before a session is taken; what is wrong
  # is said about the argument by name, so a caller can fix the call.
  defp record_argument(uri, field, kinds, what) when is_binary(uri) do
    with {:ok, {_repo, collection, rkey} = parts} <- at_uri_argument(uri, field) do
      if Enum.any?(kinds, &AtMcp.Network.collection?(collection, &1)),
        do: with(:ok <- post_key(field, collection, rkey), do: {:ok, parts}),
        else:
          invalid(
            field,
            "must be the AT URI of #{what}; #{uri} is a #{collection} record"
          )
    end
  end

  defp record_argument(_uri, field, _kinds, what),
    do: invalid(field, "must be the AT URI of #{what}")

  # A post's record key is a TID, as the post lexicon declares. A URI whose key
  # is not one was most likely copied wrong, and a read of it comes back as the
  # service's RecordNotFound, which reads as a deleted post. So it is refused
  # here, before anything is read, naming the key. Any other collection's key is
  # left to the service. A service that skips lexicon checks can hold a post
  # under some other key; AtMcp refuses to name that record as a post.
  defp post_key(field, collection, rkey) do
    cond do
      AtMcp.Network.post_key(collection) != "tid" or AtMcp.ATProto.tid?(rkey) ->
        :ok

      String.length(rkey) != 13 ->
        invalid(
          field,
          "must be the AT URI of a post; its record key #{rkey} is #{String.length(rkey)} characters, and a post's record key is a TID of 13 characters"
        )

      true ->
        invalid(
          field,
          "must be the AT URI of a post; its record key #{rkey} is not a TID, and a post's record key is a TID: 13 characters of 2-7 and a-z, the first one 2-7 or a-j"
        )
    end
  end

  # A URI that names one record, checked before anything is sent or counted.
  defp at_uri_argument(uri, field) do
    case AtMcp.ATProto.parse_uri(uri) do
      {:ok, parts} ->
        {:ok, parts}

      {:error, _} ->
        invalid(
          field,
          "must be an AT URI of the form at://<handle or DID>/<collection>/<rkey>"
        )
    end
  end

  # A record this account edits: in its own repository, named by its DID or the
  # handle the session holds. Answered as the URI in DID form, which is how
  # other records name it. Checked with the session, before anything is sent.
  defp own_record(session, {repo, collection, rkey}, field, what) do
    if own_actor?(session, repo),
      do: {:ok, "at://#{did_of(session)}/#{collection}/#{rkey}"},
      else: invalid(field, "#{what}; #{repo} is another account")
  end

  defp own_actor?(session, actor) do
    handle = Map.get(session, :handle) || Map.get(session, "handle")
    actor == did_of(session) or (is_binary(handle) and actor == handle)
  end

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      _ -> value
    end
  end

  defp present(_value), do: nil

  # --- pins, thread mutes and bookmarks ---

  @doc """
  Pin one of this account's posts to its profile, replacing any pin it had.
  The post is read for its CID and the profile for the fields the pin keeps,
  before anything is sent; a post in another account's repository is refused
  then too.
  """
  def pin_post(effects, uri) when is_binary(uri) do
    with {:ok, {repo, _rkey}} <- post_uri(uri, "uri") do
      take_and_write(
        effects,
        :pin_post,
        fn backend, session ->
          with :ok <- own_repo(session, repo, "uri", "pin_post pins a post this account wrote") do
            backend.prepare_pin(session, uri)
          end
        end,
        fn prepared -> fn backend, session -> backend.pin(session, prepared) end end
      )
    end
  end

  @doc "Remove the pin from this account's profile. A profile with no pin is left unwritten."
  def unpin_post(effects) do
    take_and_write(
      effects,
      :unpin_post,
      fn backend, session -> backend.prepare_pin(session, nil) end,
      fn prepared -> fn backend, session -> backend.pin(session, prepared) end end
    )
  end

  @doc """
  Mute the thread a post is in. Any post of the thread names it: the post is
  read for its thread's root before anything is sent, because the service
  mutes threads by their root.
  """
  def mute_thread(effects, uri) when is_binary(uri), do: thread_mute(effects, :mute_thread, uri)

  def unmute_thread(effects, uri) when is_binary(uri),
    do: thread_mute(effects, :unmute_thread, uri)

  defp thread_mute(effects, verb, uri) do
    with {:ok, _} <- post_uri(uri, "uri") do
      take_and_write(
        effects,
        verb,
        fn backend, session -> thread_root(backend, session, uri) end,
        fn %{root: root} -> fn backend, session -> apply(backend, verb, [session, root]) end end
      )
    end
  end

  # The root a thread is muted by, in the DID form the service files threads
  # under. The post names its root as its writer spelled it, and a client may
  # have spelled it with a handle; muting that string mutes nothing.
  defp thread_root(backend, session, uri) do
    with {:ok, %{root: root} = post} <- backend.resolve_post(session, uri),
         {:ok, root} <- did_uri(backend, session, root),
         do: {:ok, %{post | root: root}}
  end

  @doc "Bookmark a post, privately. The post is read for its CID first."
  def bookmark(effects, uri) when is_binary(uri) do
    with {:ok, _} <- post_uri(uri, "uri") do
      take_and_write(
        effects,
        :bookmark,
        fn backend, session -> backend.resolve_post(session, uri) end,
        fn ref -> fn backend, session -> backend.bookmark(session, ref) end end
      )
    end
  end

  @doc """
  Remove a bookmark. The service keeps a bookmark under the DID-form address
  of its post and deletes nothing for any other string, while answering as if
  it had, so a handle-form address is resolved to its DID first. The post
  itself is not read: a bookmark of a deleted post must still be removable.
  """
  def unbookmark(effects, uri) when is_binary(uri) do
    with {:ok, {repo, rkey}} <- post_uri(uri, "uri") do
      {:ok, {_, collection, _}} = AtMcp.ATProto.parse_uri(uri)

      take_and_write(
        effects,
        :unbookmark,
        fn backend, session ->
          with {:ok, did} <- backend.resolve_actor(session, repo),
               do: {:ok, "at://#{did}/#{collection}/#{rkey}"}
        end,
        fn uri -> fn backend, session -> backend.unbookmark(session, uri) end end
      )
    end
  end

  def get_bookmarks(effects, opts \\ []) do
    paged(effects, opts, fn backend, session, opts ->
      session |> backend.get_bookmarks(opts) |> moderated(backend, session, :posts)
    end)
  end

  # --- a post's gates ---

  @doc """
  Set who may reply to one of this account's posts and whether it may be
  quoted. The app's dialog starts from the post's current settings, so a rule
  not given (nil) is kept as it is. `reply_rule` `["everyone"]` is everyone,
  `[]` nobody, or a list of rules (`AtMcp.Interactions.reply_rule/1`);
  `quotes` `"allowed"` lets anyone quote it, `"disabled"` nobody. Replies
  hidden and quotes detached stay as they are.
  """
  def set_post_interactions(effects, uri, reply_rule, quotes) when is_binary(uri) do
    with {:ok, {repo, _rkey}} <- post_uri(uri, "uri"),
         {:ok, allow} <- keep_or(reply_rule, &AtMcp.Interactions.reply_rule/1),
         {:ok, quotes} <- keep_or(quotes, &AtMcp.Interactions.quotes/1) do
      edit_gates(effects, :set_post_interactions, {:interactions, uri, allow, quotes},
        own: {repo, "set_post_interactions sets the rules of a post this account wrote"}
      )
    end
  end

  @doc """
  Hide (`hide? = true`) or unhide a reply in a thread this account started.
  The reply is read for its thread's root, which must be this account's post.
  """
  def hide_reply(effects, uri, hide?) when is_binary(uri) and is_boolean(hide?) do
    with {:ok, _} <- post_uri(uri, "uri") do
      edit_gates(
        effects,
        if(hide?, do: :hide_reply, else: :unhide_reply),
        {:hide_reply, uri, hide?}
      )
    end
  end

  @doc """
  Detach (`detach? = true`) or reattach a post that quotes one of this
  account's posts. The quoting post is read for what it quotes.
  """
  def detach_quote(effects, uri, detach?) when is_binary(uri) and is_boolean(detach?) do
    with {:ok, _} <- post_uri(uri, "uri") do
      edit_gates(
        effects,
        if(detach?, do: :detach_quote, else: :reattach_quote),
        {:detach_quote, uri, detach?}
      )
    end
  end

  defp edit_gates(effects, verb, edit, opts \\ []) do
    take_and_write(
      effects,
      verb,
      fn backend, session ->
        with :ok <- own_post(session, Keyword.get(opts, :own)),
             do: backend.prepare_gates(session, edit)
      end,
      fn prepared -> fn backend, session -> backend.write_gates(session, prepared) end end
    )
  end

  defp keep_or(nil, _read), do: {:ok, :keep}
  defp keep_or(given, read), do: read.(given)

  defp own_post(_session, nil), do: :ok
  defp own_post(session, {repo, what}), do: own_repo(session, repo, "uri", what)

  # --- drafts ---

  # `app.bsky.draft.defs#draftPost` allows a draft's text more room than a
  # post's, so a long text can be drafted and later split into posts.
  @draft_text %{graphemes: 1_000, bytes: 10_000}

  @doc "What a draft's text may be: `app.bsky.draft.defs#draftPost`."
  def draft_text_limits, do: @draft_text

  def get_drafts(effects, opts \\ []) do
    paged(effects, opts, fn backend, session, opts -> backend.get_drafts(session, opts) end)
  end

  @doc """
  Save `text` as a new draft, or, given the id of one this account has, as the
  text of its first post, keeping the rest of it. The draft is read first, so
  an id the account does not have is refused rather than silently ignored.
  """
  def save_draft(effects, text, id \\ nil) when is_binary(text) do
    with :ok <- validate_draft_text(text) do
      case id do
        nil ->
          take_and_write(effects, :save_draft, fn backend, session ->
            backend.save_draft(session, nil, AtMcp.ATProto.draft(text))
          end)

        id ->
          take_and_write(
            effects,
            :save_draft,
            fn backend, session -> backend.find_draft(session, id) end,
            fn current ->
              fn backend, session ->
                backend.save_draft(session, id, AtMcp.ATProto.draft(text, current))
              end
            end
          )
      end
    end
  end

  @doc "Delete a draft. It is read first, so the result carries what was deleted."
  def delete_draft(effects, id) when is_binary(id) do
    take_and_write(
      effects,
      :delete_draft,
      fn backend, session -> backend.find_draft(session, id) end,
      fn current -> fn backend, session -> backend.delete_draft(session, id, current) end end
    )
  end

  defp validate_draft_text(text) do
    %{graphemes: graphemes, bytes: bytes} = @draft_text

    cond do
      not String.valid?(text) ->
        invalid("text", "must be valid UTF-8")

      byte_size(text) > bytes or String.length(text) > graphemes ->
        invalid("text", "a draft holds at most #{graphemes} graphemes and #{bytes} UTF-8 bytes")

      true ->
        :ok
    end
  end

  # A tool argument that names a post, checked before a session is taken: an
  # AT URI whose collection is a post on either network. What is wrong is said
  # about the argument by name, so a caller can fix the call.
  defp post_uri(uri, field) do
    case AtMcp.ATProto.parse_uri(uri) do
      {:ok, {repo, collection, rkey}} ->
        if AtMcp.Network.collection?(collection, :post),
          do: with(:ok <- post_key(field, collection, rkey), do: {:ok, {repo, rkey}}),
          else: invalid(field, "must be the AT URI of a post; #{uri} is a #{collection} record")

      {:error, _} ->
        invalid(field, "must be an AT URI of the form at://<handle or DID>/<collection>/<rkey>")
    end
  end

  # Whether a record's repository is this account's, by DID or by the handle
  # the session holds. Checked with the session, before anything is sent.
  defp own_repo(session, repo, field, what) do
    if AtMcp.Interactions.own_repo?(session, repo),
      do: :ok,
      else: invalid(field, "#{what}; #{repo} is another account")
  end

  defp invalid(field, message), do: {:error, {:invalid_argument, field, message}}

  @doc """
  How long one account call may take, in milliseconds, from the moment it asks
  for the account until it answers. `:call_deadline_ms` in the `:at_mcp`
  application environment; 20 seconds by default, which is longer than one
  slow request and shorter than the MCP endpoint's own limit
  (`AtMcp.MCP.HTTP.handler_call_timeout/0`).
  """
  def call_deadline, do: Application.get_env(:at_mcp, :call_deadline_ms, 20_000)

  @doc """
  The longest a caller waits for an account call's answer, in milliseconds:
  the deadline, then the owner's grace for its answer, then, if the owner
  stopped, the same grace for the call's task to be seen to stop. Anything that
  waits on an account call waits longer than this, or it gives up before AtMcp
  has said what happened.
  """
  def answered_within, do: call_deadline() + 2 * @answer_grace_ms

  # --- the work, run in the owner's tasks ---

  defp take_and_write(effects, verb, fun),
    do: take_and_write(effects, verb, nil, fn nil -> fun end)

  # `prepare` runs on the session before any slot is reserved, and what it
  # returns builds the write. A write with nothing to read first passes no
  # prepare. Only a publishing verb reserves a slot.
  defp take_and_write(effects, verb, prepare, build) do
    counted = if counts_against_quota?(verb), do: :counted, else: :uncounted

    run(effects, :write, fn ->
      with {:ok, backend, session} <- ready_session(),
           {:ok, prepared} <- prepare(prepare, backend, session) do
        case prepared do
          # Already as asked: nothing is sent and no slot is taken.
          {:unchanged, summary} ->
            {:ok, summary}

          prepared ->
            # A failed/ambiguous write still consumes its slot. Retrying unknown
            # remote outcomes must not bypass the write quota.
            with {:ok, backend, session} <- reserve(counted, backend, session),
                 do: invoke_write(backend, session, build.(prepared), counted)
        end
      end
    end)
  end

  defp reserve(:counted, _backend, _session), do: reserve_write()
  defp reserve(:uncounted, backend, session), do: {:ok, backend, session}

  defp prepare(nil, _backend, _session), do: {:ok, nil}
  # Preparation may use authenticated reads or upload image blobs. An explicit
  # credential refusal is safe to recover before any post is submitted, and
  # neither the preparation nor its retry reserves publishing quota.
  defp prepare(prepare, backend, session),
    do: invoke_with_recovery(backend, session, prepare)

  defp with_session(effects, fun) do
    run(effects, :read, fn ->
      with {:ok, backend, session} <- ready_session() do
        mark_sent()
        invoke_with_recovery(backend, session, fun)
      end
    end)
  end

  # A read tells the owner when it has a session and goes to the service, so
  # a read stopped at the deadline can say whether the service was asked
  # (`{:call_deadline_exceeded, :sent}`) or the read was still waiting for the
  # account's session (`:call_deadline_exceeded`). An agent retries the first
  # knowing the service is slow, and the second knowing it never asked.
  defp mark_sent do
    case Process.get(@call) do
      %{owner: owner, id: id} -> send(owner, {@call, :sent, id})
      _ -> :ok
    end
  end

  # Every dispatch that reaches a backend takes its own slot, including the one
  # after session recovery: two dispatches are two attempted writes, and an
  # quota counting them as one lets a recovering account exceed it.
  defp reserve_retry(:counted), do: reserve_write()
  defp reserve_retry(:uncounted), do: {:ok, :uncounted, :uncounted}

  defp reserve_write do
    state = GenServer.call(owner(), :state, :infinity)

    with :ok <-
           AtMcp.WriteQuota.reserve(
             state.write_quota,
             did_of(state.backend_state),
             state.write_limits
           ) do
      {:ok, state.backend, state.backend_state}
    end
  end

  # The session, and the account's own permission to use it.
  defp ready_session do
    with {:ok, backend, session} <- GenServer.call(owner(), :session, :infinity),
         :ok <- authorize_session(session) do
      {:ok, backend, session}
    end
  end

  defp authorize_session(session) do
    case GenServer.call(owner(), :state, :infinity).identity_id do
      nil ->
        :ok

      id ->
        with :ok <- AtMcp.Inbound.Store.account({:bind, id, did_of(session)}),
             do: AtMcp.Inbound.Store.ready(id)
    end
  end

  # Once a write reaches a backend, a missing result is not evidence of refusal.
  # No uncertain write retries.
  defp invoke_write(backend, session, fun, counted) do
    with :ok <- mark_dispatched() do
      attempt_write(backend, session, fun, counted)
    end
  end

  defp attempt_write(backend, session, fun, counted) do
    case write_once(backend, session, fun, counted) do
      {:error, reason} = error ->
        if write_refused?(reason), do: error, else: {:error, {:write_outcome_unknown, reason}}

      result ->
        result
    end
  rescue
    error -> {:error, {:write_outcome_unknown, error}}
  catch
    kind, reason -> {:error, {:write_outcome_unknown, {kind, reason}}}
  end

  # A credential the service refused means the request was not applied, so one
  # retry after recovery is safe. A counted write reserves again for that second
  # dispatch; if the quota is exhausted it is reported as refused, which it is.
  defp write_once(backend, session, fun, counted) do
    case fun.(backend, session) do
      {:error, reason} = err ->
        if auth_refused?(reason),
          do: retry_after_recovery(session, fun, counted),
          else: err

      other ->
        other
    end
  end

  # A write that does not count against the write quota takes no slot on its
  # recovery retry either — otherwise a like would spend an account's writes
  # and be refused once they ran out.
  defp retry_after_recovery(stale, fun, counted) do
    with {:ok, backend, session} <- recover_session(stale),
         {:ok, _backend, _session} <- reserve_retry(counted),
         :ok <- before_deadline() do
      fun.(backend, session)
    else
      {:error, :account_identity_changed} = mismatch ->
        mismatch

      {:error, {:write_quota_exhausted, _}} = exhausted ->
        exhausted

      # Recovery did not finish in time. The refused attempt changed nothing,
      # and nothing else was sent.
      {:error, :call_deadline_exceeded} = late ->
        late

      # Recovery failed, so the credential is refused and the account is now
      # logged out. Reporting the service's original complaint would send an
      # agent to edit its request when the request was never the problem.
      {:error, _} ->
        {:error, :account_authentication_failed}
    end
  end

  # Only a backend's own declaration that the action did not happen, or AtMcp's
  # own refusal of an account that is not ready, makes a write safe to report as refused. Everything
  # else stays uncertain.
  defp write_refused?(:account_identity_changed), do: true
  defp write_refused?(:account_authentication_failed), do: true

  # AtMcp declined to dispatch, so nothing was attempted at the service.
  defp write_refused?({:write_quota_exhausted, _}), do: true

  defp write_refused?(reason),
    do: AtMcp.Effects.Failure.kind(reason) in [:refused, :auth_refused]

  defp invoke_with_recovery(backend, session, fun) do
    case fun.(backend, session) do
      {:error, reason} = err ->
        if auth_refused?(reason) do
          case recover_session(session) do
            {:ok, backend, session} -> fun.(backend, session)
            {:error, :account_identity_changed} = mismatch -> mismatch
            {:error, _} -> err
          end
        else
          err
        end

      other ->
        other
    end
  end

  # The backend says whether its service refused the credential; a reason it did
  # not classify is not one to guess about from a status code or error text.
  defp auth_refused?(reason), do: AtMcp.Effects.Failure.kind(reason) == :auth_refused

  defp recover_session(stale), do: GenServer.call(owner(), {:recover, stale}, :infinity)

  # --- calls: the caller's side ---

  # Run `fun` as a call on the account. It runs in a task the owner starts and
  # owns, under the caller's deadline. A call made from inside such a task on
  # the same account runs inline: it is already under the outer call's
  # deadline, and a second call would queue behind the one making it.
  defp run(effects, lane, fun, opts \\ []) do
    ready_check? = Keyword.get(opts, :ready_check, true)
    fun = if ready_check?, do: fn -> with :ok <- account_ready(), do: fun.() end, else: fun

    case Process.get(@call) do
      %{owner: owner} when is_pid(owner) ->
        if GenServer.whereis(effects) == owner, do: fun.(), else: call(effects, lane, fun)

      _ ->
        call(effects, lane, fun)
    end
  end

  defp call(effects, lane, fun) do
    id = make_ref()
    deadline = call_deadline()
    deadline_at = System.monotonic_time(:millisecond) + deadline
    wait = deadline + @answer_grace_ms

    try do
      GenServer.call(effects, {:run, lane, fun, id, deadline_at}, wait)
    catch
      :exit, {:timeout, _} -> unanswered(id, :call_deadline_exceeded)
      :exit, _ -> owner_lost(id, lane)
    else
      {@call, :exit, reason} ->
        forget(id)
        exit(reason)

      result ->
        forget(id)
        result
    end
  end

  # The owner is alive but did not answer in time. A task never dispatches after
  # the deadline, so without a dispatch mark nothing was sent and nothing will be.
  defp unanswered(id, reason) do
    dispatched? = dispatched?(id)
    forget(id)
    if dispatched?, do: {:error, {:write_outcome_unknown, reason}}, else: {:error, reason}
  end

  # The owner stopped. The owner said which task runs the call before it could
  # stop, so that message is here ahead of the owner's DOWN; without it no task
  # ran. The task stops with the owner, and once its DOWN is here its dispatch
  # mark, if it sent one, is too. A write whose task is not seen to stop within
  # the grace may still be sent, so its outcome is unknown.
  defp owner_lost(id, lane) do
    receive do
      {@call, :started, ^id, task} ->
        ref = Process.monitor(task)

        stopped? =
          receive do
            {:DOWN, ^ref, :process, _, _} -> true
          after
            @answer_grace_ms ->
              Process.demonitor(ref, [:flush])
              false
          end

        cond do
          dispatched?(id) or (lane == :write and not stopped?) ->
            forget(id)
            {:error, {:write_outcome_unknown, :account_runtime_stopped}}

          true ->
            {:error, :account_runtime_unavailable}
        end
    after
      0 -> {:error, :account_runtime_unavailable}
    end
  end

  defp dispatched?(id) do
    receive do
      {@call, :dispatched, ^id} -> true
    after
      0 -> false
    end
  end

  defp forget(id) do
    receive do
      {@call, :started, ^id, _} -> :ok
    after
      0 -> :ok
    end

    _ = dispatched?(id)
    :ok
  end

  # --- calls: the task's side ---

  defp owner, do: Process.get(@call).owner

  defp account_ready do
    case GenServer.call(owner(), :state, :infinity).identity_id do
      nil -> :ok
      id -> AtMcp.Inbound.Store.ready(id)
    end
  end

  # The task says so before a write reaches the backend, to the owner and to the
  # caller, so either can tell a write that may have happened from one that did
  # not. The mark goes first and the deadline check after it: whatever happens
  # between the check and the send, a caller that has given up has already been
  # told a write may be on its way. Past the deadline it does not dispatch, so a
  # write refused right at the deadline reads as unknown, which is the safe
  # side.
  defp mark_dispatched do
    case Process.get(@call) do
      %{owner: owner, id: id, caller: caller} ->
        send(owner, {@call, :dispatched, id})
        send(caller, {@call, :dispatched, id})

      _ ->
        :ok
    end

    case before_deadline() do
      :ok -> paused_before_dispatch()
      {:error, reason} -> {:error, {:write_outcome_unknown, reason}}
    end
  end

  # Every dispatch checks the deadline itself, the retry after session recovery
  # included: the owner stops the task at the deadline only when it is on time,
  # and a write sent after the caller was answered could duplicate one the
  # agent sends again after inspecting the account.
  defp before_deadline do
    case Process.get(@call) do
      %{deadline_at: deadline_at} ->
        if System.monotonic_time(:millisecond) < deadline_at,
          do: :ok,
          else: {:error, :call_deadline_exceeded}

      _ ->
        :ok
    end
  end

  # A test holds a task here, between its last deadline check and the write,
  # to stand for the scheduler descheduling it there. Unset, it does nothing.
  defp paused_before_dispatch do
    case Application.get_env(:at_mcp, :effects_pause_before_dispatch) do
      pause when is_function(pause, 0) -> pause.()
      _ -> :ok
    end
  end

  # --- the owner ---

  # The owner does not trap exits. Its tasks are linked to it, so any exit of
  # the owner — killed, shut down by its supervisor, crashed — stops them, and
  # the owner itself goes as soon as the signal arrives: its name is free for
  # the replacement its supervisor starts. A task never exits abnormally on its
  # own (`guarded/1`), and the owner unlinks a task before stopping it.
  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call(:state, _from, state), do: {:reply, public_state(state), state}

  def handle_call({:run, lane, fun, id, deadline_at}, {caller, _} = from, state) do
    timer = Process.send_after(self(), {@call, :deadline, id}, deadline_at, abs: true)
    watch = Process.monitor(caller)

    call = %{
      from: from,
      caller: caller,
      watch: watch,
      lane: lane,
      fun: fun,
      deadline_at: deadline_at,
      timer: timer,
      task: nil,
      dispatched: false,
      sent: false
    }

    state = %{
      state
      | calls: Map.put(state.calls, id, call),
        callers: Map.put(state.callers, watch, id)
    }

    state =
      cond do
        lane == :read -> start_call(state, id)
        is_nil(state.write) -> start_call(%{state | write: id}, id)
        true -> %{state | writes: :queue.in(id, state.writes)}
      end

    {:noreply, state}
  end

  def handle_call(:session, from, state) do
    case state do
      %{identity_error: :account_identity_changed} ->
        {:reply, {:error, :account_identity_changed}, state}

      %{logged_in?: true, backend_state: session, backend: backend} when not is_nil(session) ->
        if identity_matches?(state, session),
          do: {:reply, {:ok, backend, session}, state},
          else: {:reply, {:error, :account_identity_changed}, reject_identity(state)}

      state ->
        if has_credentials?(state),
          do: {:noreply, session_work(state, {:login, []}, {from, :session})},
          else: {:reply, {:error, :not_connected}, state}
    end
  end

  def handle_call({:login, opts}, from, state) do
    cond do
      state.logged_in? and not is_nil(state.backend_state) ->
        if identity_matches?(state, state.backend_state),
          do:
            {:reply, {:ok, %{status: :already_connected, login_count: state.login_count}}, state},
          else: {:reply, {:error, :account_identity_changed}, reject_identity(state)}

      requires_credentials?(state.backend) and is_nil(state.credentials) and
          not (Keyword.has_key?(opts, :handle) and Keyword.has_key?(opts, :password)) ->
        {:reply, {:error, :not_connected}, state}

      true ->
        {:noreply, session_work(state, {:login, opts}, {from, :login})}
    end
  end

  # Another call may already have renewed the session this caller holds.
  # A session that was already given up is not refreshed again: the account
  # logs in anew.
  def handle_call({:recover, stale}, from, state) do
    cond do
      state.logged_in? and not is_nil(state.backend_state) and state.backend_state != stale ->
        {:reply, {:ok, state.backend, state.backend_state}, state}

      is_nil(state.backend_state) ->
        {:noreply, session_work(state, {:recover, nil}, {from, :session})}

      true ->
        {:noreply, session_work(state, {:recover, stale}, {from, :session})}
    end
  end

  @impl true
  def handle_info({ref, result}, %{tasks: tasks} = state) when is_map_key(tasks, ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, finish_call(state, ref, result)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{tasks: tasks} = state)
      when is_map_key(tasks, ref) do
    {:noreply, finish_call(state, ref, {@call, :exit, reason})}
  end

  def handle_info({:DOWN, watch, :process, _pid, _reason}, %{callers: callers} = state)
      when is_map_key(callers, watch) do
    {:noreply, abandoned(state, Map.fetch!(callers, watch))}
  end

  def handle_info({@call, :dispatched, id}, %{calls: calls} = state) when is_map_key(calls, id),
    do: {:noreply, put_in(state.calls[id].dispatched, true)}

  def handle_info({@call, :sent, id}, %{calls: calls} = state) when is_map_key(calls, id),
    do: {:noreply, put_in(state.calls[id].sent, true)}

  def handle_info({@call, :deadline, id}, state) do
    {:noreply, deadline(state, id, Map.get(state.calls, id))}
  end

  def handle_info({ref, result}, %{session_task: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, finish_session(state, result)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{session_task: %{ref: ref}} = state) do
    {:noreply, finish_session(state, {:error, {:login_failed, {:exit, reason}}})}
  end

  def handle_info({@call, :session_deadline, ref}, %{session_task: %{ref: ref} = task} = state) do
    stop_task(task.pid)

    receive do
      {:DOWN, ^ref, :process, _, _} -> :ok
    end

    result =
      receive do
        {^ref, result} -> result
      after
        0 -> {:error, :call_deadline_exceeded}
      end

    {:noreply, finish_session(state, result)}
  end

  # Dispatch marks of finished calls, and timers that outlived their call.
  def handle_info(_message, state), do: {:noreply, state}

  # A task does not stop on a normal exit signal, so an owner that stops
  # normally stops its tasks here.
  @impl true
  def terminate(_reason, state) do
    for {_ref, id} <- state.tasks, do: Process.exit(state.calls[id].task, :kill)
    if state.session_task, do: Process.exit(state.session_task.pid, :kill)
    :ok
  end

  # A task's failure is its answer, not the owner's exit.
  defp guarded(fun) do
    fun.()
  catch
    :exit, reason ->
      {@call, :exit, reason}

    kind, reason ->
      {@call, :exit, {Exception.normalize(kind, reason, __STACKTRACE__), __STACKTRACE__}}
  end

  defp stop_task(pid) do
    Process.unlink(pid)
    Process.exit(pid, :kill)
  end

  defp start_call(state, id) do
    owner = self()
    call = state.calls[id]

    %Task{pid: pid, ref: ref} =
      Task.async(fn ->
        Process.put(@call, %{
          owner: owner,
          id: id,
          caller: call.caller,
          deadline_at: call.deadline_at
        })

        guarded(call.fun)
      end)

    # Sent by the owner, so a caller that sees the owner's DOWN has seen this first.
    send(call.caller, {@call, :started, id, pid})

    %{
      state
      | calls: Map.put(state.calls, id, %{call | task: pid}),
        tasks: Map.put(state.tasks, ref, id)
    }
  end

  defp finish_call(state, ref, result) do
    id = Map.fetch!(state.tasks, ref)
    call = state.calls[id]
    GenServer.reply(call.from, answer(result, call.dispatched or dispatched?(id)))
    forget_call(state, id)
  end

  defp deadline(state, _id, nil), do: state

  # Still waiting for the account: nothing was attempted.
  defp deadline(state, id, %{task: nil} = call) do
    GenServer.reply(call.from, {:error, :call_deadline_exceeded})
    forget_call(state, id)
  end

  # Running: stop the task, then answer with what it did.
  defp deadline(state, id, call) do
    {result, dispatched?} = stop_call(state, id)

    result =
      cond do
        result -> answer(result, dispatched?)
        dispatched? -> {:error, {:write_outcome_unknown, :call_deadline_exceeded}}
        call.sent -> {:error, {:call_deadline_exceeded, :sent}}
        true -> {:error, :call_deadline_exceeded}
      end

    GenServer.reply(call.from, result)
    forget_call(state, id)
  end

  # The caller is gone, so nobody reads the answer. A call still waiting for
  # the account is dropped, and a running call that has sent nothing is
  # stopped. A write already sent runs to its end, because stopping it would not
  # unsend it; its answer goes nowhere.
  defp abandoned(state, id) do
    call = Map.fetch!(state.calls, id)

    cond do
      is_nil(call.task) ->
        forget_call(state, id)

      call.dispatched or dispatched?(id) ->
        put_in(state.calls[id].dispatched, true)

      true ->
        _ = stop_call(state, id)
        forget_call(state, id)
    end
  end

  # Stop a running call's task and say what it did before it stopped: its
  # result, if it had one, and whether it sent a write. Both are already in the
  # mailbox once its DOWN is.
  defp stop_call(state, id) do
    call = state.calls[id]
    {ref, ^id} = Enum.find(state.tasks, fn {_ref, task_id} -> task_id == id end)
    stop_task(call.task)

    receive do
      {:DOWN, ^ref, :process, _, _} -> :ok
    end

    result =
      receive do
        {^ref, result} -> result
      after
        0 -> nil
      end

    {result, call.dispatched or dispatched?(id)}
  end

  # A task that ended without an answer after sending a write leaves its
  # outcome unknown; one that ended before sending changed nothing.
  defp answer({@call, :exit, reason}, true),
    do: {:error, {:write_outcome_unknown, {:exit, reason}}}

  defp answer(result, _dispatched?), do: result

  defp forget_call(state, id) do
    call = Map.fetch!(state.calls, id)
    Process.cancel_timer(call.timer)
    Process.demonitor(call.watch, [:flush])
    _ = dispatched?(id)

    tasks =
      case Enum.find(state.tasks, fn {_ref, task_id} -> task_id == id end) do
        {ref, _} ->
          Process.demonitor(ref, [:flush])
          Map.delete(state.tasks, ref)

        nil ->
          state.tasks
      end

    release(
      %{
        state
        | calls: Map.delete(state.calls, id),
          callers: Map.delete(state.callers, call.watch),
          tasks: tasks,
          writes: :queue.delete(id, state.writes)
      },
      id
    )
  end

  # When the running write ends, the oldest waiting write starts.
  defp release(%{write: id} = state, id) do
    case :queue.out(state.writes) do
      {{:value, next}, writes} -> start_call(%{state | write: next, writes: writes}, next)
      {:empty, _} -> %{state | write: nil}
    end
  end

  defp release(state, _id), do: state

  # --- the session lane ---

  # One login or refresh at a time. A caller that arrives while one runs waits
  # for it and gets its result.
  defp session_work(%{session_task: %{} = task} = state, _work, waiter),
    do: %{state | session_task: %{task | waiters: [waiter | task.waiters]}}

  defp session_work(state, work, waiter) do
    backend = state.backend
    credentials = state.credentials
    can_login? = can_login?(state)

    %Task{pid: pid, ref: ref} =
      Task.async(fn ->
        guarded(fn -> session_result(work, backend, credentials, can_login?) end)
      end)

    Process.send_after(self(), {@call, :session_deadline, ref}, call_deadline())
    %{state | session_task: %{pid: pid, ref: ref, work: work, waiters: [waiter]}}
  end

  defp session_result({:login, opts}, backend, credentials, _can_login?),
    do: {:login, login(backend, credentials, opts)}

  defp session_result({:recover, nil}, backend, credentials, can_login?),
    do: {:relogin, relogin(backend, credentials, can_login?)}

  defp session_result({:recover, stale}, backend, credentials, can_login?) do
    case backend.refresh(stale) do
      {:ok, fresh} -> {:refreshed, fresh}
      {:error, _} -> {:relogin, relogin(backend, credentials, can_login?)}
    end
  end

  defp relogin(_backend, _credentials, false), do: {:error, :not_connected}
  defp relogin(backend, credentials, true), do: login(backend, credentials, [])

  defp login(backend, credentials, opts) do
    ensure_http_apps!()
    login_opts = merge_credentials(opts, credentials)

    with {:ok, session} <- backend.login(login_opts) do
      credentials =
        case {Keyword.get(login_opts, :handle), Keyword.get(login_opts, :password)} do
          {h, p} when is_binary(h) and h != "" and is_binary(p) and p != "" ->
            %{handle: h, password: p}

          _ ->
            credentials
        end

      {:ok, session, retain_service(credentials, login_opts)}
    end
  rescue
    error -> {:error, {:login_failed, error.__struct__}}
  catch
    kind, reason -> {:error, {:login_failed, {kind, reason}}}
  end

  defp finish_session(state, result) do
    %{work: work, waiters: waiters} = state.session_task
    state = %{state | session_task: nil}

    {state, answer} =
      case result do
        {:refreshed, fresh} ->
          accept_session(state, fresh, state.credentials, false)

        {_, {:ok, session, credentials}} ->
          accept_session(state, session, credentials, true)

        {:relogin, {:error, reason}} ->
          {%{state | logged_in?: false, backend_state: nil}, {:error, reason}}

        {:login, {:error, reason}} ->
          {state, {:error, reason}}

        {:error, reason} ->
          {forget_session_on_recover(state, work), {:error, reason}}

        {@call, :exit, reason} ->
          {forget_session_on_recover(state, work), {:error, {:login_failed, {:exit, reason}}}}
      end

    for {from, style} <- waiters, do: GenServer.reply(from, session_answer(state, answer, style))
    state
  end

  # A recovery that ended without a session has already given up the old one.
  defp forget_session_on_recover(state, {:recover, _}),
    do: %{state | logged_in?: false, backend_state: nil}

  defp forget_session_on_recover(state, _work), do: state

  defp accept_session(state, session, credentials, new_login?) do
    if identity_matches?(state, session) do
      state = %{
        state
        | backend_state: session,
          credentials: credentials,
          logged_in?: true,
          identity_error: nil,
          login_count: if(new_login?, do: state.login_count + 1, else: state.login_count)
      }

      {state, {:ok, if(new_login?, do: :connected, else: :refreshed)}}
    else
      {reject_identity(state), {:error, :account_identity_changed}}
    end
  end

  defp session_answer(_state, {:error, _} = error, _style), do: error

  defp session_answer(state, {:ok, _}, :session), do: {:ok, state.backend, state.backend_state}

  defp session_answer(state, {:ok, status}, :login),
    do: {:ok, %{status: login_status(status), login_count: state.login_count}}

  defp login_status(:refreshed), do: :already_connected
  defp login_status(status), do: status

  # --- state ---

  defp state(effects), do: GenServer.call(effects, :state)

  defp public_state(state),
    do:
      Map.take(state, [
        :identity_id,
        :expected_did,
        :backend,
        :backend_state,
        :login_count,
        :logged_in?,
        :credentials,
        :write_quota,
        :write_limits
      ])

  # What the app would hide, cover or flag in what a read returns, marked on
  # it (`AtMcp.ModerationMarks`).
  defp moderated(result, backend, session, kind),
    do: AtMcp.ModerationMarks.mark(backend, session, did_of(session), result, kind)

  defp did_of(%{did: did}) when is_binary(did), do: did
  defp did_of(%{"did" => did}) when is_binary(did), do: did
  defp did_of(_session), do: nil

  defp can_login?(state),
    do: not (requires_credentials?(state.backend) and is_nil(state.credentials))

  # A backend that does not declare the answer is assumed not to need them: a
  # test double with a preloaded session is the common case.
  defp requires_credentials?(backend) do
    # function_exported?/3 answers for loaded modules only, and a release may
    # not have loaded the backend yet the first time an account logs in.
    Code.ensure_loaded?(backend) and
      function_exported?(backend, :requires_credentials?, 0) and
      backend.requires_credentials?()
  end

  defp ensure_http_apps! do
    Enum.each([:inets, :ssl, :finch, :req, :proto_rune], fn app ->
      _ = Application.ensure_all_started(app)
    end)

    :ok
  end

  # Every paged read takes the same page size, so each tool's schema can state
  # it. These are AtMcp's bounds, not the service's: the services accept larger
  # pages. They set how much an agent reads per call, and they are the one
  # place to change that.
  @page_limits %{min: 1, max: 50, default: 20}

  @doc "The page size every paged read accepts, and the one it uses when none is given."
  def page_limits, do: @page_limits

  defp page_options(opts) do
    %{min: min, max: max, default: default} = @page_limits
    limit = Keyword.get(opts, :limit) || default
    cursor = Keyword.get(opts, :cursor)

    cond do
      not is_integer(limit) or limit < min or limit > max ->
        {:error, "limit must be an integer between #{min} and #{max}"}

      not is_nil(cursor) and not is_binary(cursor) ->
        {:error, "cursor must be a string returned by the previous page"}

      true ->
        {:ok,
         opts
         |> Keyword.put(:limit, limit)
         |> Enum.reject(fn {key, value} -> key == :cursor and is_nil(value) end)}
    end
  end

  # Optional search_posts filters. `sort` is latest or top, and the other
  # strings are what the service takes. Empty strings and lists are treated as
  # omitted, so a model that sends `author: ""` does not send `authors=` on
  # the wire, and a boolean filter that is false is one not asked for. Checked
  # here, so a bad filter costs no session.
  @search_sorts ["latest", "top"]
  @search_filters [:author, :mentions, :sort, :since, :until, :lang]
  @search_strings [:reply_to, :thread_root, :query_language]
  @search_lists [
    :exclude_authors,
    :exclude_mentions,
    :domains,
    :exclude_domains,
    :urls,
    :exclude_urls,
    :embeds,
    :exclude_embeds,
    :hashtags,
    :exclude_hashtags,
    :exclude_langs
  ]
  @search_booleans [:all_time, :has_media, :has_video, :following]

  # A hashtag filter entry, as `feed.searchPostsV2` bounds it.
  @hashtag_limits %{graphemes: 64, bytes: 640}

  @doc "Every search_posts filter `search_posts/3` takes, beside `query`, `limit` and `cursor`."
  def search_filters,
    do: @search_filters ++ @search_strings ++ @search_lists ++ @search_booleans ++ [:replies]

  @doc false
  def hashtag_limits, do: @hashtag_limits

  # `all_time: false` is kept: unlike the other booleans, false asks for
  # something, the service's recent window instead of every post, which is
  # what a call that leaves it out gets (see `AtMcp.Effects.ProtoRune`).
  defp search_post_options(opts) do
    opts =
      opts
      |> Keyword.take([:limit, :cursor | search_filters()])
      |> Enum.map(fn
        {key, tags} when key in [:hashtags, :exclude_hashtags] and is_list(tags) ->
          # The `#` is not part of the tag, so it is gone before the tag's
          # length is counted.
          {key,
           tags
           |> Enum.reject(&blank_search?/1)
           |> Enum.map(fn
             tag when is_binary(tag) -> String.replace_prefix(String.trim(tag), "#", "")
             other -> other
           end)
           |> Enum.reject(&blank_search?/1)}

        {key, list} when key in @search_lists and is_list(list) ->
          {key, Enum.reject(list, &blank_search?/1)}

        pair ->
          pair
      end)
      |> Enum.reject(fn {key, value} ->
        key in search_filters() and
          (blank_search?(value) or value == [] or (value == false and key != :all_time))
      end)

    with :ok <- validate_search_sort(Keyword.get(opts, :sort)),
         :ok <- validate_search_strings(opts),
         :ok <- validate_search_lists(opts),
         :ok <- validate_search_booleans(opts),
         :ok <- validate_replies(Keyword.get(opts, :replies)) do
      page_options(opts)
    end
  end

  defp blank_search?(nil), do: true
  defp blank_search?(""), do: true
  defp blank_search?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank_search?(_), do: false

  defp validate_search_sort(nil), do: :ok
  defp validate_search_sort(sort) when sort in @search_sorts, do: :ok
  defp validate_search_sort(_), do: {:error, :invalid_search_sort}

  defp validate_search_strings(opts) do
    with :ok <- strings(opts, @search_filters -- [:sort], {:error, :invalid_search_filter}) do
      Enum.reduce_while(@search_strings, :ok, fn key, :ok ->
        case Keyword.get(opts, key) do
          nil -> {:cont, :ok}
          value when is_binary(value) -> {:cont, :ok}
          _ -> {:halt, invalid(Atom.to_string(key), "must be a string")}
        end
      end)
    end
  end

  defp strings(opts, keys, error) do
    if Enum.all?(keys, &(is_nil(Keyword.get(opts, &1)) or is_binary(Keyword.get(opts, &1)))),
      do: :ok,
      else: error
  end

  defp validate_search_lists(opts) do
    Enum.reduce_while(@search_lists, :ok, fn key, :ok ->
      case Keyword.get(opts, key) do
        nil ->
          {:cont, :ok}

        list when is_list(list) ->
          cond do
            not Enum.all?(list, &is_binary/1) ->
              {:halt, invalid(Atom.to_string(key), "must be a list of strings")}

            key in [:hashtags, :exclude_hashtags] ->
              case validate_hashtags(Atom.to_string(key), list) do
                :ok -> {:cont, :ok}
                error -> {:halt, error}
              end

            true ->
              {:cont, :ok}
          end

        _ ->
          {:halt, invalid(Atom.to_string(key), "must be a list of strings")}
      end
    end)
  end

  defp validate_hashtags(field, tags) do
    %{graphemes: graphemes, bytes: bytes} = @hashtag_limits

    case Enum.find(tags, &(String.length(&1) > graphemes or byte_size(&1) > bytes)) do
      nil -> :ok
      tag -> invalid(field, "a hashtag may be at most #{graphemes} characters; #{tag} is longer")
    end
  end

  defp validate_search_booleans(opts) do
    case Enum.find(@search_booleans, &(Keyword.get(opts, &1) not in [nil, true, false])) do
      nil -> :ok
      key -> invalid(Atom.to_string(key), "must be true or false")
    end
  end

  defp validate_replies(nil), do: :ok
  defp validate_replies(replies) when replies in ["exclude", "only"], do: :ok
  defp validate_replies(_), do: invalid("replies", "must be exclude or only")

  defp identity_matches?(%{expected_did: nil}, _session), do: true

  defp identity_matches?(%{expected_did: expected}, session), do: did_of(session) == expected

  defp reject_identity(state) do
    %{state | backend_state: nil, logged_in?: false, identity_error: :account_identity_changed}
  end

  defp has_credentials?(%{credentials: %{handle: h, password: p}})
       when is_binary(h) and h != "" and is_binary(p) and p != "",
       do: true

  defp has_credentials?(_state), do: false

  defp merge_credentials(opts, nil), do: opts

  defp merge_credentials(opts, credentials), do: Keyword.merge(Map.to_list(credentials), opts)

  defp retain_service(nil, _opts), do: nil

  defp retain_service(credentials, opts) do
    case Keyword.get(opts, :service) do
      nil -> credentials
      service -> Map.put(credentials, :service, service)
    end
  end
end
