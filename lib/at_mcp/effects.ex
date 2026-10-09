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
  `AtMcp.WriteQuota`, shared by every client and alias of that DID. The quota
  bounds what the account publishes, so only the verbs in `publishing/0` —
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
    `{:write_outcome_unknown, :call_deadline_exceeded}`, anything else is
    `:call_deadline_exceeded`.

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
    quota = state(effects).write_quota
    AtMcp.WriteQuota.status(quota, session_did(effects))
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

  def list_notifications(effects, opts \\ []) do
    with {:ok, opts} <- page_options(opts) do
      with_session(effects, fn backend, session ->
        backend.list_notifications(session, opts)
      end)
    end
  end

  def get_notifications(effects, opts \\ []), do: list_notifications(effects, opts)

  def get_unread_count(effects) do
    with_session(effects, fn backend, session ->
      backend.get_unread_count(session)
    end)
  end

  def get_thread(effects, uri) when is_binary(uri) do
    with_session(effects, fn backend, session ->
      backend.get_thread(session, uri)
    end)
  end

  def get_thread_chain(effects, uri, opts \\ []) when is_binary(uri) and is_list(opts) do
    with :ok <- validate_before(Keyword.get(opts, :before)) do
      with_session(effects, fn backend, session ->
        backend.get_thread_chain(session, uri, opts)
      end)
    end
  end

  # A cursor is whatever the caller sends back, and a caller that sends a
  # number or an object is answered, not crashed. Checked here, with the other
  # input checks, so a malformed one costs no session and no read.
  defp validate_before(before) when is_nil(before) or is_binary(before), do: :ok
  defp validate_before(_before), do: {:error, :invalid_before}

  def get_timeline(effects, opts \\ []) do
    with {:ok, opts} <- page_options(opts) do
      with_session(effects, fn backend, session ->
        backend.get_timeline(session, opts)
      end)
    end
  end

  def get_author_feed(effects, actor, opts \\ []) when is_binary(actor) do
    with {:ok, opts} <- page_options(opts) do
      with_session(effects, fn backend, session ->
        backend.get_author_feed(session, actor, opts)
      end)
    end
  end

  def get_profile(effects, actor) when is_binary(actor) do
    with_session(effects, fn backend, session ->
      backend.get_profile(session, actor)
    end)
  end

  def get_profiles(effects, actors) when is_list(actors) do
    with :ok <- validate_batch(actors) do
      with_session(effects, fn backend, session ->
        backend.get_profiles(session, actors)
      end)
    end
  end

  def get_posts(effects, uris) when is_list(uris) do
    with :ok <- validate_batch(uris) do
      with_session(effects, fn backend, session ->
        backend.get_posts(session, uris)
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

  def search_posts(effects, query, opts \\ []) when is_binary(query) do
    with {:ok, opts} <- page_options(opts) do
      with_session(effects, fn backend, session ->
        backend.search_posts(session, query, opts)
      end)
    end
  end

  def search_actors(effects, query, opts \\ []) when is_binary(query) do
    with {:ok, opts} <- page_options(opts) do
      with_session(effects, fn backend, session ->
        backend.search_actors(session, query, opts)
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

  def get_suggested_follows(effects, actor) when is_binary(actor) do
    with_session(effects, fn backend, session ->
      backend.get_suggested_follows(session, actor)
    end)
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
    paged(effects, opts, fn backend, session, opts -> backend.get_quotes(session, uri, opts) end)
  end

  def get_actor_likes(effects, actor, opts \\ []) when is_binary(actor) do
    paged(effects, opts, fn backend, session, opts ->
      backend.get_actor_likes(session, actor, opts)
    end)
  end

  # --- feeds other than the home timeline ---

  def get_feed(effects, feed, opts \\ []) when is_binary(feed) do
    paged(effects, opts, fn backend, session, opts -> backend.get_feed(session, feed, opts) end)
  end

  def get_suggested_feeds(effects, opts \\ []) do
    paged(effects, opts, fn backend, session, opts ->
      backend.get_suggested_feeds(session, opts)
    end)
  end

  def get_list_feed(effects, list, opts \\ []) when is_binary(list) do
    paged(effects, opts, fn backend, session, opts ->
      backend.get_list_feed(session, list, opts)
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
  # Each MCP tool's description and its `kite/publicWrite` annotation derive
  # from this list (`AtMcp.MCP.DSL`), so a host reads the same classification.
  @publishing [:post, :reply, :repost]

  @doc "The write verbs that count against the account's write quota."
  def publishing, do: @publishing

  @doc "Whether a write verb counts against the account's write quota."
  def counts_against_quota?(verb) when is_atom(verb), do: verb in @publishing

  def post(effects, text, opts \\ []) when is_binary(text) and is_list(opts),
    do: publish(effects, :post, text, opts)

  @doc """
  Reply to a post. A reply is a post with a parent, so it is the same write
  with the same options; only the tool surface names it separately.
  """
  def reply(effects, uri, text, opts \\ []) when is_binary(uri) and is_binary(text),
    do: publish(effects, :reply, text, Keyword.put(opts, :reply, uri))

  defp publish(effects, verb, text, opts) do
    with :ok <- validate_post_text(text) do
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

  def like(effects, uri, cid) when is_binary(uri) and is_binary(cid) do
    take_and_write(effects, :like, fn backend, session -> backend.like(session, uri, cid) end)
  end

  def unlike(effects, like_uri) when is_binary(like_uri) do
    take_and_write(effects, :unlike, fn backend, session -> backend.unlike(session, like_uri) end)
  end

  def repost(effects, uri, cid) when is_binary(uri) and is_binary(cid) do
    take_and_write(effects, :repost, fn backend, session -> backend.repost(session, uri, cid) end)
  end

  def unrepost(effects, repost_uri) when is_binary(repost_uri) do
    take_and_write(effects, :unrepost, fn backend, session ->
      backend.unrepost(session, repost_uri)
    end)
  end

  # A follow, block or mute names its subject by DID, so a handle is resolved
  # first, with a session, like a reply's parent. A handle that names no
  # account is an ordinary answer, and nothing was sent.
  def follow(effects, actor) when is_binary(actor) do
    take_and_write(
      effects,
      :follow,
      fn backend, session -> backend.resolve_actor(session, actor) end,
      fn did -> fn backend, session -> backend.follow(session, did) end end
    )
  end

  def unfollow(effects, follow_uri) when is_binary(follow_uri) do
    take_and_write(effects, :unfollow, fn backend, session ->
      backend.unfollow(session, follow_uri)
    end)
  end

  def block(effects, actor) when is_binary(actor) do
    take_and_write(
      effects,
      :block,
      fn backend, session -> backend.resolve_actor(session, actor) end,
      fn did -> fn backend, session -> backend.block(session, did) end end
    )
  end

  def unblock(effects, block_uri) when is_binary(block_uri) do
    take_and_write(effects, :unblock, fn backend, session ->
      backend.unblock(session, block_uri)
    end)
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

  def update_profile(effects, updates) when is_list(updates) do
    take_and_write(effects, :update_profile, fn backend, session ->
      backend.update_profile(session, updates)
    end)
  end

  @doc "Mark notifications seen."
  def update_seen(effects, seen_at \\ nil) do
    seen =
      case seen_at do
        %DateTime{} = dt ->
          dt

        nil ->
          DateTime.utc_now() |> DateTime.truncate(:second)

        iso when is_binary(iso) ->
          case DateTime.from_iso8601(iso) do
            {:ok, dt, _} -> dt
            {:error, _} -> DateTime.utc_now() |> DateTime.truncate(:second)
          end
      end

    take_and_write(effects, :update_seen, fn backend, session ->
      backend.update_seen(session, seen)
    end)
  end

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
           {:ok, prepared} <- prepare(prepare, backend, session),
           # A failed/ambiguous write still consumes its slot. Retrying unknown
           # remote outcomes must not bypass the write quota.
           {:ok, backend, session} <- reserve(counted, backend, session) do
        invoke_write(backend, session, build.(prepared), counted)
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
        invoke_with_recovery(backend, session, fun)
      end
    end)
  end

  # Every dispatch that reaches a backend takes its own slot, including the one
  # after session recovery: two dispatches are two attempted writes, and an
  # quota counting them as one lets a recovering account exceed it.
  defp reserve_retry(:counted), do: reserve_write()
  defp reserve_retry(:uncounted), do: {:ok, :uncounted, :uncounted}

  defp reserve_write do
    state = GenServer.call(owner(), :state, :infinity)

    with :ok <- AtMcp.WriteQuota.reserve(state.write_quota, did_of(state.backend_state)) do
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
      dispatched: false
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
        :write_quota
      ])

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
