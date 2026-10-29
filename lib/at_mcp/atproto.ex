defmodule AtMcp.ATProto do
  @moduledoc """
  Every endpoint AtMcp calls on the application namespace, declared once.

  AtMcp's application namespace is a value (`AtMcp.Network`), so each function
  here names its suffix within that namespace and its parameters, and resolves
  the NSID when it is called. proto_rune's `defquery` compiles the NSID into the
  function it generates, so it cannot serve both networks from one release.
  `com.atproto.*` methods are literals, because they are the same NSIDs on every
  network.

  Every declaration is authenticated. An unauthenticated read returns records
  with no `viewer` object, and `viewer` is the account's own relationship to a
  record — what `AtMcp.Summary` reads and an agent decides on.

  Three rules apply to a new declaration.

  - **A parameter's declared name goes on the wire verbatim.**
    `ProtoRune.XRPC.Query` runs validated parameters through
    `URI.encode_query/1` with no camelization, so a parameter takes the name the
    lexicon uses: `:parentHeight`, not `:parent_height`.

  - **A `nil` parameter is sent as an empty value.** Peri drops an absent key and
    keeps a key that is present and `nil`, so `params/1` drops the keys a caller
    did not supply.

  - **A list parameter cannot go through `read/4`.** `URI.encode_query/1` raises
    on a list value, while AT Protocol repeats the key once per element. Those
    endpoints are declared as ordinary functions over `repeated_query/3`.

  ## The records

  A write is `com.atproto.repo.createRecord` with a collection and a record
  whose `$type` equals that collection. Both come from `AtMcp.Network`, so a
  record builder here is the only thing that decides which network a write lands
  on. `ProtoRune.Bsky` is not used to build records: it compiles `app.bsky.*`
  into them and validates them through Peri schemas that drop undeclared keys —
  an `embed` handed to `Bsky.post/3` returns `{:ok, ...}` with the embed gone.
  """

  alias AtMcp.ATProto.ServiceAuth
  alias AtMcp.Network
  alias ProtoRune.Session
  alias ProtoRune.XRPC.Client
  alias ProtoRune.XRPC.Procedure
  alias ProtoRune.XRPC.Query

  # The paging parameters most list endpoints share.
  @page [limit: :integer, cursor: :string]

  def get_membership(session, params),
    do: read(session, "membership.getMembership", params)

  def identity_state(session), do: read(session, "identity.getState", %{})

  # --- feed reads ---

  # `ProtoRune.Bsky.get_post_thread/2` sends `parent_height`, which the lexicon
  # does not define; the AppView answers with no parents at all.
  def get_post_thread(session, params),
    do:
      read(session, "feed.getPostThread", params,
        uri: {:required, :string},
        depth: :integer,
        parentHeight: :integer
      )

  # The replies a thread read leaves out: those its author hid, and those the
  # viewer's own settings push down. Below `anchor`, one level at a time.
  def get_post_thread_other(session, params),
    do: read(session, "unspecced.getPostThreadOtherV2", params, anchor: {:required, :string})

  # proto_rune declares `getAuthorFeed` public-only, so its generated function
  # takes no session, reaches bsky.social rather than the account's own service,
  # and 401s there.
  def get_author_feed(session, params),
    do: read(session, "feed.getAuthorFeed", params, [actor: {:required, :string}] ++ @page)

  # A custom feed: the generator's AT URI selects the slice of the network.
  def get_feed(session, params),
    do: read(session, "feed.getFeed", params, [feed: {:required, :string}] ++ @page)

  # Feeds the service currently suggests. The URI on each item is what
  # `get_feed` takes; without this, a caller can read a custom feed only when
  # it already has that URI.
  def get_suggested_feeds(session, params),
    do: read(session, "feed.getSuggestedFeeds", params, @page)

  # The newer suggestion service's feeds. It takes no cursor.
  def get_unspecced_suggested_feeds(session, params),
    do: read(session, "unspecced.getSuggestedFeeds", params, limit: :integer)

  @doc """
  The account's preferences exactly as stored: a list of preference objects,
  every key as the service sent it. Preferences are one document that a
  change replaces whole (`put_preferences_as_stored/2`), so the ones a change
  does not touch must go back byte for byte; proto_rune's XRPC client would
  rename their keys to snake_case and back. Read from the raw body.
  """
  def preferences_as_stored(session) do
    query =
      Query.new(Network.nsid("actor.getPreferences"),
        base_url: base_url(session),
        response: :binary
      )

    with {:ok, %{body: body}} <- execute(session, query, "GET") do
      case Jason.decode(body) do
        {:ok, %{"preferences" => preferences}} when is_list(preferences) ->
          AtMcp.AcceptLabelers.remember(session, preferences)
          {:ok, preferences}

        _ ->
          {:error, :unreadable_preferences}
      end
    end
  end

  @doc """
  Replace the account's preferences with `preferences`, sent as given: the
  body is encoded here rather than by proto_rune, which camelizes every key it
  sends. `actor.putPreferences` has no compare-and-swap.
  """
  def put_preferences_as_stored(session, preferences) when is_list(preferences) do
    proc =
      Network.nsid("actor.putPreferences")
      |> Procedure.new(base_url: base_url(session))
      |> Procedure.put_raw_body(Jason.encode!(%{"preferences" => preferences}))
      |> Procedure.put_header("content-type", "application/json")

    case execute(session, proc, "POST") do
      {:error, _} = error ->
        error

      written ->
        AtMcp.AcceptLabelers.remember(session, preferences)
        written
    end
  end

  @doc """
  The account's notification settings (`notification.getPreferences`), every
  key as the service sent it: the reasons are camelCase keys
  (`likeViaRepost`), which proto_rune's key renaming would not give back.
  """
  def notification_preferences(session) do
    query =
      Query.new(Network.nsid("notification.getPreferences"),
        base_url: base_url(session),
        response: :binary
      )

    with {:ok, %{body: body}} <- execute(session, query, "GET"),
         do: decode_raw(body)
  end

  @doc """
  Change the notification settings of the reasons `settings` names
  (`notification.putPreferencesV2`); a reason not named is left as it is.
  Sent as given, keys and all, and answered with every setting as it now is.
  """
  def put_notification_preferences(session, settings) when is_map(settings),
    do: raw_procedure(session, "notification.putPreferencesV2", settings)

  @doc """
  Subscribe to, or with both `post` and `reply` false unsubscribe from, an
  account's posts (`notification.putActivitySubscription`). `subject` is a DID.
  """
  def put_activity_subscription(session, subject, %{"post" => _, "reply" => _} = subscription),
    do:
      raw_procedure(session, "notification.putActivitySubscription", %{
        "subject" => subject,
        "activitySubscription" => subscription
      })

  @doc """
  The account's notifications grouped as the app's Notifications screen
  shows them (`notification.getGroupedNotifications`): `feed` is the screen's
  tab. Read from the raw body: a group's kind is a union told apart by its
  `$type`, and its related views are too.
  """
  def grouped_notifications(session, params) do
    query =
      Query.new(Network.nsid("notification.getGroupedNotifications"),
        from: %{feed: :string, limit: :integer, cursor: :string},
        base_url: base_url(session),
        response: :binary
      )

    with {:ok, query} <- Query.add_params(query, params),
         {:ok, %{body: body}} <- execute(session, query, "GET"),
         do: decode_raw(body)
  end

  @doc "The accounts this account is subscribed to, a page at a time."
  def list_activity_subscriptions(session, params),
    do: read(session, "notification.listActivitySubscriptions", params, @page)

  defp raw_procedure(session, suffix, body) do
    proc =
      Network.nsid(suffix)
      |> Procedure.new(base_url: base_url(session), response: :binary)
      |> Procedure.put_raw_body(Jason.encode!(body))
      |> Procedure.put_header("content-type", "application/json")

    with {:ok, %{body: answer}} <- execute(session, proc, "POST"), do: decode_raw(answer)
  end

  # A raw answer: the decoded body, or `:unreadable` when it is not a JSON
  # object (an empty body included).
  defp decode_raw(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{} = decoded} -> {:ok, decoded}
      _ -> {:ok, :unreadable}
    end
  end

  defp decode_raw(_body), do: {:ok, :unreadable}

  @doc """
  Tell a feed generator how its feed's items landed (`feed.sendInteractions`).
  The interactions go to the feed generator's own service, `service_did`,
  through the account's PDS (`atproto-proxy: <did>#bsky_fg`), as the app
  sends them; the AppView does not take them.
  """
  def send_interactions(session, service_did, params) when is_binary(service_did) do
    proc =
      Procedure.new(Network.nsid("feed.sendInteractions"),
        from: %{feed: :string, interactions: {:required, :any}},
        base_url: base_url(session)
      )

    with {:ok, proc} <- Procedure.put_body(proc, params),
         do: execute(session, proc, "POST", %{"atproto-proxy" => service_did <> "#bsky_fg"})
  end

  # One feed generator, with whether its service is online and valid.
  def get_feed_generator(session, params),
    do: read(session, "feed.getFeedGenerator", params, feed: {:required, :string})

  # The feed generators an account declared.
  def get_actor_feeds(session, params),
    do: read(session, "feed.getActorFeeds", params, [actor: {:required, :string}] ++ @page)

  # Popular feeds, or those whose name or description matches `query`. This is
  # what the app's feed search calls.
  def get_popular_feed_generators(session, params),
    do: read(session, "unspecced.getPopularFeedGenerators", params, [query: :string] ++ @page)

  # Accounts suggested without a subject: `actor.getSuggestions` pages with a
  # cursor; the `unspecced.getSuggested*` methods take `suffix` and a category.
  def get_suggestions(session, params),
    do: read(session, "actor.getSuggestions", params, @page)

  def get_suggested_users(session, suffix, params),
    do: read(session, suffix, params, category: :string, limit: :integer)

  # Suggested starter packs: `unspecced.getSuggestedStarterPacks` or the
  # onboarding one, named by `suffix`.
  def get_suggested_starter_packs(session, suffix, params),
    do: read(session, suffix, params, limit: :integer)

  def get_trends(session, params),
    do: read(session, "unspecced.getTrends", params, limit: :integer)

  def get_trending_topics(session, params),
    do: read(session, "unspecced.getTrendingTopics", params, limit: :integer)

  # The town's invitation codes for this account. Only delve.town has them.
  def get_invite_codes(session, params),
    do:
      read(session, "invitation.getCodes", params,
        includeUsed: :boolean,
        createAvailable: :boolean
      )

  # The posts of the accounts on one list.
  def get_list_feed(session, params),
    do: read(session, "feed.getListFeed", params, [list: {:required, :string}] ++ @page)

  # Who liked a post.
  def get_likes(session, params),
    do: read(session, "feed.getLikes", params, [uri: {:required, :string}, cid: :string] ++ @page)

  # Who quoted a post.
  def get_quotes(session, params),
    do:
      read(session, "feed.getQuotes", params, [uri: {:required, :string}, cid: :string] ++ @page)

  # Who reposted a post.
  def get_reposted_by(session, params),
    do:
      read(
        session,
        "feed.getRepostedBy",
        params,
        [uri: {:required, :string}, cid: :string] ++ @page
      )

  # What an account has liked.
  def get_actor_likes(session, params),
    do: read(session, "feed.getActorLikes", params, [actor: {:required, :string}] ++ @page)

  # The home timeline.
  def get_timeline(session, params),
    do: read(session, "feed.getTimeline", params, @page)

  @doc """
  Search posts with `feed.searchPostsV2`, the version the app calls. Its
  filters are mostly lists (`authors`, `hashtags`, `excludeDomains`, …), so
  every list-valued parameter is repeated once per entry. Parameter names are
  the lexicon's.
  """
  def search_posts(session, params) when is_map(params),
    do: repeated_query(session, AtMcp.Network.nsid("feed.searchPostsV2"), params)

  @doc "Several feed generators by AT URI. `feeds` is repeated once per entry."
  def get_feed_generators(session, feeds) when is_list(feeds),
    do: repeated_query(session, AtMcp.Network.nsid("feed.getFeedGenerators"), %{feeds: feeds})

  @doc """
  Labelers by DID, detailed, each with the viewer's like of it. `dids` is
  repeated once per entry.
  """
  def get_services(session, dids) when is_list(dids),
    do:
      repeated_query(session, AtMcp.Network.nsid("labeler.getServices"), %{
        dids: dids,
        detailed: true
      })

  # --- actor reads ---

  def get_profile(session, params),
    do: read(session, "actor.getProfile", params, actor: {:required, :string})

  def search_actors(session, params),
    do: read(session, "actor.searchActors", params, [q: {:required, :string}] ++ @page)

  # --- notifications ---

  @doc """
  List account notifications, optionally filtering by repeated `reasons` keys.

  The notification reasons array shares the list-encoding defect documented for
  the other repeated-query endpoints below.
  """
  def list_notifications(session, params),
    do: repeated_query(session, AtMcp.Network.nsid("notification.listNotifications"), params)

  def get_unread_count(session, params),
    do: read(session, "notification.getUnreadCount", params, priority: :boolean)

  # The one write declared here. `ProtoRune.Bsky.update_seen/2` stringifies the
  # DateTime before a schema that requires a DateTime, and the XRPC client then
  # camelizes the body by recursing into every map — which a DateTime is. This
  # declares the wire type the endpoint actually takes. 0.6.0 still does both.
  # An upstream fix deletes nothing here: the runtime namespace already keeps
  # this off `ProtoRune.Bsky`.
  def update_seen(session, params),
    do: write(session, "notification.updateSeen", params, seen_at: {:required, :string})

  # --- graph writes that are methods rather than records ---

  # A mute is not a record in the repository: it is server-side state on the
  # AppView, set by an application-namespace method. So it moves with the
  # namespace like a read does, and unlike a block, which is a record.
  def mute_actor(session, params),
    do: write(session, "graph.muteActor", params, actor: {:required, :string})

  def unmute_actor(session, params),
    do: write(session, "graph.unmuteActor", params, actor: {:required, :string})

  # A thread mute is AppView state, like an account mute: a method named by the
  # thread's root post, not a record.
  def mute_thread(session, params),
    do: write(session, "graph.muteThread", params, root: {:required, :string})

  def unmute_thread(session, params),
    do: write(session, "graph.unmuteThread", params, root: {:required, :string})

  # A list mute is AppView state too, keyed by the list's AT URI as given: a
  # handle-form URI mutes nothing the AppView ever matches, so callers pass
  # the DID form.
  def mute_actor_list(session, params),
    do: write(session, "graph.muteActorList", params, list: {:required, :string})

  def unmute_actor_list(session, params),
    do: write(session, "graph.unmuteActorList", params, list: {:required, :string})

  # The moderation lists this account mutes, and those it blocks.
  def get_list_mutes(session, params), do: read(session, "graph.getListMutes", params, @page)
  def get_list_blocks(session, params), do: read(session, "graph.getListBlocks", params, @page)

  @doc """
  Labelers by DID, detailed (`labeler.getServices`), every key as the service
  sent it: a labeler's policies and report settings hold lexicon tokens and
  label identifiers that are read as they are.
  """
  def labeler_services(session, dids) when is_list(dids) do
    method = Network.nsid("labeler.getServices")

    query =
      method
      |> Query.new(base_url: base_url(session), response: :binary)
      |> Map.put(:params, flatten_query(%{dids: dids, detailed: true}))

    answer =
      if Network.direct_read?(method, session),
        do: ServiceAuth.execute(session, query),
        else: execute(session, query, "GET")

    with {:ok, %{body: body}} <- answer, do: decode_raw(body)
  end

  @doc """
  Send a report to a moderation service (`com.atproto.moderation.createReport`).
  The account's PDS forwards it to `service_did`'s labeler endpoint
  (`atproto-proxy: <did>#atproto_labeler`), as the app sends it. `input` is
  sent as given and the service's answer read as it sent it.
  """
  def create_report(session, service_did, input) when is_binary(service_did) and is_map(input) do
    proc =
      "com.atproto.moderation.createReport"
      |> Procedure.new(base_url: base_url(session), response: :binary)
      |> Procedure.put_raw_body(Jason.encode!(input))
      |> Procedure.put_header("content-type", "application/json")

    with {:ok, %{body: answer}} <-
           execute(session, proc, "POST", %{"atproto-proxy" => service_did <> "#atproto_labeler"}),
         do: decode_raw(answer)
  end

  # --- bookmarks ---

  # Bookmarks are private, kept by the AppView rather than in the repository,
  # so they move with the namespace like a read does.
  def create_bookmark(session, params),
    do:
      write(session, "bookmark.createBookmark", params,
        uri: {:required, :string},
        cid: {:required, :string}
      )

  def delete_bookmark(session, params),
    do: write(session, "bookmark.deleteBookmark", params, uri: {:required, :string})

  def get_bookmarks(session, params),
    do: read(session, "bookmark.getBookmarks", params, @page)

  # --- drafts ---

  # Drafts are private, kept by the AppView like bookmarks, not records in the
  # repository.
  def get_drafts(session, params), do: read(session, "draft.getDrafts", params, @page)

  def create_draft(session, params),
    do: write(session, "draft.createDraft", params, draft: {:required, :any})

  def update_draft(session, params),
    do: write(session, "draft.updateDraft", params, draft: {:required, :any})

  def delete_draft(session, params),
    do: write(session, "draft.deleteDraft", params, id: {:required, :string})

  # --- graph reads ---

  def get_followers(session, params),
    do: read(session, "graph.getFollowers", params, [actor: {:required, :string}] ++ @page)

  def get_follows(session, params),
    do: read(session, "graph.getFollows", params, [actor: {:required, :string}] ++ @page)

  # Followers of one account that this account also follows.
  def get_known_followers(session, params),
    do: read(session, "graph.getKnownFollowers", params, [actor: {:required, :string}] ++ @page)

  def get_suggested_follows_by_actor(session, params),
    do: read(session, "graph.getSuggestedFollowsByActor", params, actor: {:required, :string})

  # The requesting account's own blocks and mutes. Neither takes an actor: the
  # subject is whoever the session belongs to.
  def get_blocks(session, params),
    do: read(session, "graph.getBlocks", params, @page)

  def get_mutes(session, params),
    do: read(session, "graph.getMutes", params, @page)

  # --- lists and starter packs ---

  # One list and a page of its members.
  def get_list(session, params),
    do: read(session, "graph.getList", params, [list: {:required, :string}] ++ @page)

  def get_starter_pack(session, params),
    do: read(session, "graph.getStarterPack", params, starterPack: {:required, :string})

  # The starter packs one account made.
  def get_actor_starter_packs(session, params),
    do:
      read(session, "graph.getActorStarterPacks", params, [actor: {:required, :string}] ++ @page)

  # `searchStarterPacks` is the first version of this method; the app calls V2.
  def search_starter_packs(session, params),
    do: read(session, "graph.searchStarterPacksV2", params, [q: {:required, :string}] ++ @page)

  # This account's starter packs, each with the list item that puts `actor` in
  # it, if one does.
  def get_starter_packs_with_membership(session, params),
    do:
      read(
        session,
        "graph.getStarterPacksWithMembership",
        params,
        [actor: {:required, :string}] ++ @page
      )

  # --- endpoints whose parameters include a list ---

  @doc """
  The lists one account made. `purposes` (`modlist`, `curatelist`) is repeated
  once per entry; the service returns both when it is absent.
  """
  def get_lists(session, params) when is_map(params),
    do: repeated_query(session, AtMcp.Network.nsid("graph.getLists"), params)

  @doc """
  This account's lists, each with the list item that puts `actor` on it, if
  one does. `purposes` is repeated as in `get_lists/2`.
  """
  def get_lists_with_membership(session, params) when is_map(params),
    do: repeated_query(session, AtMcp.Network.nsid("graph.getListsWithMembership"), params)

  @doc """
  Fetch several profiles. `actors` is repeated once per entry.

  `ProtoRune.Bsky.get_profiles/2` passes the list straight into
  `URI.encode_query/1`, which raises "values cannot be lists".
  """
  def get_profiles(session, actors) when is_list(actors),
    do: repeated_query(session, AtMcp.Network.nsid("actor.getProfiles"), %{actors: actors})

  @doc """
  Fetch several posts by AT URI. `uris` is repeated once per entry.

  `ProtoRune.Bsky.get_posts/2` both discards its session argument and raises on
  the list, so neither half of it can be used.
  """
  def get_posts(session, uris) when is_list(uris),
    do: repeated_query(session, AtMcp.Network.nsid("feed.getPosts"), %{uris: uris})

  @doc """
  Read how one account stands to each of several others.

  `others` is repeated once per entry. Declared under the real NSID: proto_rune
  spells this `getRelationShips`.
  """
  def get_relationships(session, actor, others)
      when is_binary(actor) and is_list(others),
      do:
        repeated_query(session, AtMcp.Network.nsid("graph.getRelationships"), %{
          actor: actor,
          others: others
        })

  @doc """
  Drop the parameters a caller does not have.

  Peri keeps a key whose value is `nil`, and `URI.encode_query/1` then sends it
  as an empty value — `cursor=` asks a service to continue from nowhere.
  Delete when proto_rune's `Query` leaves `nil` parameters out of the URL
  (0.6.0 still sends them).
  """
  def params(params) when is_map(params),
    do: Map.reject(params, fn {_key, value} -> is_nil(value) end)

  def params(params) when is_list(params), do: params |> Map.new() |> params()

  @doc """
  Encode a parameter map as a query list, repeating a list-valued key.

  ATProto's array parameters are repeated keys (`uris=a&uris=b`), which
  `URI.encode_query/1` expresses as repeated tuples and cannot express as a list
  value.
  """
  def flatten_query(params) when is_map(params) do
    params
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Enum.flat_map(fn
      {key, list} when is_list(list) -> Enum.map(list, &{key, &1})
      {key, value} -> [{key, value}]
    end)
  end

  def flatten_query(params) when is_list(params), do: params |> Map.new() |> flatten_query()

  # An authenticated GET with the parameters encoded rather than validated: a
  # declared parameter list cannot describe a repeated key, so these endpoints
  # skip Peri and build the query directly. Delete when proto_rune's `Query`
  # encodes a list value as repeated keys (0.6.0 still hands it to
  # `URI.encode_query/1`, which raises).
  defp repeated_query(session, method, params) do
    query =
      method
      |> Query.new(base_url: base_url(session))
      |> Map.put(:params, flatten_query(params))

    if Network.direct_read?(method, session),
      do: ServiceAuth.execute(session, query),
      else: execute(session, query, "GET")
  end

  # An authenticated read or write on the application namespace, named by its
  # suffix and declared with proto_rune's Peri parameter types.
  defp read(session, suffix, params, schema \\ []),
    do: query(session, Network.nsid(suffix), Map.new(schema), params)

  defp write(session, suffix, params, schema),
    do: procedure(session, Network.nsid(suffix), Map.new(schema), params)

  # The authenticated query and procedure every call here goes through.
  #
  # These are `ProtoRune.XRPC.query/5` and `procedure/5` with one addition that
  # proto_rune 0.6 has no option for: per-request headers. An
  # application-namespace call carries `atproto-proxy` naming this network's
  # AppView (`AtMcp.Network.request_headers/2`), which tells the account's PDS
  # where to forward it. Reads may instead go straight to the AppView with a service token
  # (`AtMcp.ATProto.ServiceAuth`); writes never do. Delete `execute/3` and call
  # `ProtoRune.XRPC.query/5` and `procedure/5` once they accept a `:headers`
  # option.
  defp query(session, method, schema, params) do
    if Network.direct_read?(method, session) do
      ServiceAuth.query(session, method, schema, params)
    else
      query = Query.new(method, from: schema, base_url: base_url(session))
      with {:ok, query} <- Query.add_params(query, params), do: execute(session, query, "GET")
    end
  end

  defp procedure(session, method, schema, params) do
    proc = Procedure.new(method, from: schema, base_url: base_url(session))

    with {:ok, proc} <- Procedure.put_body(proc, params),
         do: execute(session, proc, "POST")
  end

  # `route` replaces where the PDS forwards the call, for the one method whose
  # service is not the AppView (`send_interactions/3`). A read names the
  # labelers whose labels it asks for (`accept_labelers/3`).
  defp execute(session, request, http_method, route \\ %{}) do
    url = Path.join(request.base_url, request.method)

    with {:ok, headers, session} <- Session.authorization_headers(session, http_method, url) do
      headers =
        request.headers
        |> Map.merge(headers)
        |> Map.merge(Network.request_headers(request.method, session))
        |> Map.merge(accept_labelers(session, request.method, http_method))
        |> Map.merge(route)

      Client.execute(%{request | headers: headers}, session: session)
    end
  end

  @doc false
  # `atproto-accept-labelers` on an application-namespace read, as the app
  # sends it (`AtMcp.AcceptLabelers`). Reading the preferences is not given
  # one: it is what the header is made from. A direct read (`ServiceAuth`)
  # passes `read_first?` false: the preferences are read through the PDS's
  # proxy, which a direct route exists to do without, so it names what is
  # already known.
  def accept_labelers(session, method, http_method, read_first? \\ true)

  def accept_labelers(session, method, "GET", read_first?) do
    if String.starts_with?(method, Network.namespace() <> ".") and
         method != Network.nsid("actor.getPreferences") do
      AtMcp.AcceptLabelers.header(session, fn ->
        if read_first?, do: preferences_as_stored(session), else: :unknown
      end)
    else
      %{}
    end
  end

  def accept_labelers(_session, _method, _http_method, _read_first?), do: %{}

  @doc false
  # The account's own service, or the library's default. A session always
  # carries one in AtMcp, because every configured account names a service.
  def base_url(session),
    do: Session.service_url(session) || ProtoRune.Config.default_base_url()

  # --- com.atproto.repo: the methods AtMcp writes through ---
  #
  # These four NSIDs are literals, and correctly so: the rename between
  # namespaces does not touch `com.atproto.*`. What varies between networks is
  # the collection they are given and the `$type` inside the record, and both
  # come from `AtMcp.Network` through the builders below.

  @repo_write %{
    repo: {:required, :string},
    collection: {:required, :string},
    rkey: :string,
    validate: :boolean,
    record: {:required, :any}
  }

  # `swapRecord` is the CID the record must still have for the write to apply,
  # or null when there must be none (`put_record/2`).
  @repo_put @repo_write |> Map.put(:rkey, {:required, :string}) |> Map.put(:swap_record, :string)

  # `swapRecord` is the CID the record must still have for it to be deleted.
  @repo_delete %{
    repo: {:required, :string},
    collection: {:required, :string},
    rkey: {:required, :string},
    swap_record: :string
  }

  @repo_get %{
    repo: {:required, :string},
    collection: {:required, :string},
    rkey: {:required, :string}
  }

  @doc """
  Write a new record, preserving its fields without local record-schema validation.

  This validates the request envelope, not the contents of `record`. Callers
  make selected checks, such as the network's post text limits; those are not
  full lexicon validation. We bypass `ProtoRune.Atproto.Repo.create_record/3`
  because its `app.bsky` Peri schemas discard fields they do not declare.

  The optional `validate` flag is forwarded only when supplied. Our normal
  write calls omit it. A PDS that does not know the record's lexicon, such as an
  external PDS receiving `town.delve` records, may accept the record without
  checking that schema. A successful write does not prove schema validity.
  """
  def create_record(session, params),
    do: procedure(session, "com.atproto.repo.createRecord", @repo_write, params)

  @doc """
  Write a record at a known rkey, creating or replacing it. `swap_record` is
  the CID the record must still have; given as nil, it is sent as null, which
  the PDS reads as "there must be no record yet" (`swapCid === null` for a
  create in the reference PDS's actor-store/repo/transactor.ts), so a record
  created meanwhile is not written over. Left out, nothing is checked.
  """
  def put_record(session, params),
    do: procedure(session, "com.atproto.repo.putRecord", @repo_put, params)

  @doc """
  Create a record of another application's (`op: :create`, the service picks
  the key), or put one at `rkey` over the version `swap` (`op: :put`; a nil
  swap is sent as null: there must be no record yet). The record is sent
  byte-for-byte: `procedure/4` passes a body through proto_rune's camelizer,
  which would rename any snake_case key the record's own lexicon declares.
  """
  def write_record_as_given(session, %{op: op, collection: collection, record: record} = write) do
    {method, body} =
      case op do
        :create ->
          {"com.atproto.repo.createRecord",
           %{repo: session.did, collection: collection, record: record}}

        :put ->
          {"com.atproto.repo.putRecord",
           %{
             repo: session.did,
             collection: collection,
             rkey: write.rkey,
             record: record,
             swapRecord: write.swap
           }}
      end

    proc =
      Procedure.new(method, base_url: base_url(session))
      |> Procedure.put_raw_body(Jason.encode!(body))
      |> Procedure.put_header("content-type", "application/json")

    execute(session, proc, "POST")
  end

  @doc """
  Create, update and delete several records in one commit: all of them land,
  or none does. `writes` are `{:create | :update, collection, rkey, record}`
  and `{:delete, collection, rkey}`.
  """
  def apply_writes(session, repo, writes, opts \\ []) when is_list(writes) do
    params = %{repo: repo, writes: Enum.map(writes, &repo_write/1)}

    # `swapCommit`: the repository commit the writes were built over. The
    # service applies none of them if the repository has moved on since.
    params =
      case Keyword.get(opts, :swap_commit) do
        nil -> params
        commit -> Map.put(params, :swap_commit, commit)
      end

    if Keyword.get(opts, :preserve_record_keys, false) do
      # Shared profiles belong to other clients too. Keep their unknown keys
      # byte-for-byte instead of passing records through ProtoRune's camelizer.
      body = %{repo: repo, writes: params.writes, swapCommit: Keyword.fetch!(opts, :swap_commit)}

      proc =
        Procedure.new("com.atproto.repo.applyWrites", base_url: base_url(session))
        |> Procedure.put_raw_body(Jason.encode!(body))
        |> Procedure.put_header("content-type", "application/json")

      execute(session, proc, "POST")
    else
      procedure(
        session,
        "com.atproto.repo.applyWrites",
        %{repo: {:required, :string}, writes: {:required, :any}, swap_commit: :string},
        params
      )
    end
  end

  @doc "The repository's current commit: `%{cid, rev}`."
  def get_latest_commit(session, did),
    do:
      query(session, "com.atproto.sync.getLatestCommit", %{did: {:required, :string}}, %{did: did})

  defp repo_write({op, collection, rkey, record}) when op in [:create, :update],
    do: %{
      "$type" => "com.atproto.repo.applyWrites##{op}",
      "collection" => collection,
      "rkey" => rkey,
      "value" => record
    }

  defp repo_write({:delete, collection, rkey}),
    do: %{
      "$type" => "com.atproto.repo.applyWrites#delete",
      "collection" => collection,
      "rkey" => rkey
    }

  @tid_alphabet ~c"234567abcdefghijklmnopqrstuvwxyz"

  @doc """
  A record key in the TID form the protocol uses: microseconds since the
  epoch and a random clock id, as 13 sortable base32 characters.

  A post written with its gates needs its key before it is written, because
  each gate's key must be the post's.
  """
  def tid(now_us \\ System.os_time(:microsecond), clock \\ :rand.uniform(1024) - 1) do
    import Bitwise
    n = (now_us <<< 10 ||| clock) &&& 0x7FFF_FFFF_FFFF_FFFF

    for i <- 12..0//-1, into: "", do: <<Enum.at(@tid_alphabet, n >>> (5 * i) &&& 31)>>
  end

  @doc """
  Whether `key` has the TID form: 13 characters of sortable base32, the first
  of them 2-7 or a-j because a TID's top bit is zero. A post's record key is
  one (the post lexicon's `"key": "tid"`).
  """
  def tid?(key) when is_binary(key), do: key =~ ~r/\A[234567a-j][234567a-z]{12}\z/

  @doc "Delete one record from a repository."
  def delete_record(session, params),
    do: procedure(session, "com.atproto.repo.deleteRecord", @repo_delete, params)

  @doc "Read one record out of a repository."
  def get_record(session, params),
    do: query(session, "com.atproto.repo.getRecord", @repo_get, params)

  @doc """
  One record exactly as its repository holds it: `%{"uri", "cid", "value"}`,
  every key as the service sent it. `get_record/2` reads through proto_rune's
  XRPC client, which renames every key to snake_case; a record of another
  application may have keys that do not survive the rename and back, so this
  reads the body itself.
  """
  def get_record_as_stored(session, params) do
    query =
      Query.new("com.atproto.repo.getRecord",
        from: @repo_get,
        base_url: base_url(session),
        response: :binary
      )

    with {:ok, query} <- Query.add_params(query, params),
         {:ok, %{body: body}} <- execute(session, query, "GET") do
      case Jason.decode(body) do
        {:ok, %{} = decoded} -> {:ok, decoded}
        _ -> {:error, :unreadable_record}
      end
    end
  end

  @repo_list %{
    repo: {:required, :string},
    collection: {:required, :string},
    limit: :integer,
    cursor: :string
  }

  @doc """
  Read a page of one collection's records out of a repository, as its PDS
  holds them. A list's members are `graph.listitem` records in the account's
  own repository, each naming its list; this is how every one of them is
  found, including any the AppView has not indexed yet.
  """
  def list_records(session, params),
    do: query(session, "com.atproto.repo.listRecords", @repo_list, params)

  # The most writes one `applyWrites` takes. The lexicon declares no bound;
  # the reference PDS refuses more than 200 ("Too many writes. Max: 200", in
  # packages/pds/src/api/com/atproto/repo/applyWrites.ts), and a PDS is what
  # every network's accounts write through.
  @max_writes 200

  @doc "The most writes one `apply_writes/4` call carries."
  def max_writes, do: @max_writes

  @tid_alphabet "234567abcdefghijklmnopqrstuvwxyz"

  @doc """
  `n` new record keys in the protocol's TID form, in increasing order: 13
  characters of sortable base32 over the time in microseconds and a random
  clock identifier. A write that names a record before it exists, such as a
  starter pack naming its list in the same commit, chooses the keys itself.
  """
  def tids(n) when is_integer(n) and n >= 0 do
    import Bitwise
    now = System.os_time(:microsecond)
    clock = :rand.uniform(1024) - 1

    for i <- 0..(n - 1)//1 do
      value = (now + i) <<< 10 ||| clock

      for shift <- 60..0//-5, into: "" do
        <<:binary.at(@tid_alphabet, value >>> shift &&& 31)>>
      end
    end
  end

  @doc """
  Upload a blob and return `{:ok, %{blob: blob_ref}}`.

  The blob reference is what goes in a record's `image` field. The library's
  implementation already takes the session's own service and posts a raw body
  to `com.atproto.repo.uploadBlob`, so there is nothing network-specific in it.
  """
  def upload_blob(session, data, content_type)
      when is_binary(data) and is_binary(content_type),
      do: ProtoRune.Atproto.Repo.upload_blob(session, data, content_type)

  @doc """
  Split an AT URI into `{repo, collection, rkey}`.

  A delete names its collection in the URI it was given, so nothing about it
  depends on the configured network — the record was written on whatever
  network the URI came from.
  """
  def parse_uri("at://" <> rest) when is_binary(rest) do
    case String.split(rest, "/", parts: 3) do
      [repo, collection, rkey] when repo != "" and collection != "" and rkey != "" ->
        {:ok, {repo, collection, rkey}}

      _ ->
        {:error, :malformed_at_uri}
    end
  end

  def parse_uri(_uri), do: {:error, :invalid_at_uri_format}

  # --- the records themselves ---

  @doc """
  Build a `feed.post` record.

  Takes `:text`, and optionally `:facets` (as `AtMcp.RichText` builds them),
  `:langs`, `:reply` (`%{root: strong_ref, parent: strong_ref}`), `:images`
  (`[%{blob: blob_ref, alt: String.t()}]`), `:link` (a card,
  `%{url, title, description, thumb_blob}`), `:quote` (a strong ref),
  `:labels` (self-label values) and `:created_at`.

  Three things this does that `ProtoRune.Bsky.post/3` cannot:

  - `$type` and the collection are `AtMcp.Network`'s, so the record lands on the
    configured network.
  - An embed survives. `images` and `quote` together become a
    `recordWithMedia`, which is the lexicon's own way of saying both.
  - `langs` is absent unless a caller gave one. The library stamps `["en"]`
    unconditionally, which made every post any agent wrote claim to be English.
    A record that says nothing about its language is correct when nobody said
    what the language is; one that names the wrong language is not.

  Keys are the wire's: string, camelCase, `$type` where the lexicon has it. The
  record this returns is the record that is sent, so a test can assert on either.
  """
  def post_record(fields) do
    %{
      "$type" => AtMcp.Network.collection(:post),
      "text" => Keyword.fetch!(fields, :text),
      "createdAt" => timestamp(Keyword.get(fields, :created_at))
    }
    |> put_present("facets", wire_facets(Keyword.get(fields, :facets)))
    |> put_present("langs", Keyword.get(fields, :langs))
    |> put_present("reply", reply_refs(Keyword.get(fields, :reply)))
    |> put_present("embed", post_embed(fields))
    |> put_present("labels", self_labels(Keyword.get(fields, :labels)))
  end

  @doc """
  A record's labels about itself: a post's content warnings, or what an account
  says it is. The union's type is `com.atproto`'s, the same on every network.
  """
  def self_labels(nil), do: nil
  def self_labels([]), do: nil

  def self_labels(values) when is_list(values),
    do: %{
      "$type" => "com.atproto.label.defs#selfLabels",
      "values" => Enum.map(values, &%{"val" => &1})
    }

  @doc """
  A `feed.threadgate` for the post at `post_uri`: who may reply (`allow`: nil or `:everyone`
  for everyone, or the rules `AtMcp.Interactions` reads) and which replies are
  hidden. `allow` may also be `:keep`, which leaves the record's rule as it is.
  `current` is the record the repository holds, or nil; every field
  this does not set is kept, and so is its `createdAt`.

  Returns nil when the gate would say nothing, everyone may reply and nothing
  is hidden, so the caller deletes the record rather than writing an empty one.
  """
  def threadgate_record(post_uri, allow, hidden, current \\ nil) do
    record =
      gate(:threadgate, post_uri, current)
      |> set_rule("allow", allow, fn
        :everyone -> nil
        rules -> rules && reply_rules(rules)
      end)
      |> Map.delete("hiddenReplies")
      |> put_present("hiddenReplies", if(hidden != [], do: hidden))

    if Map.has_key?(record, "allow") or Map.has_key?(record, "hiddenReplies"), do: record
  end

  @doc """
  A `feed.postgate` for the post at `post_uri`: whether it may be quoted
  (`:allowed`, `:disabled`, or `:keep` to leave the record's rule) and which
  quotes of it are detached. Like
  `threadgate_record/4`, it keeps what it does not set and is nil when it
  would say nothing.
  """
  def postgate_record(post_uri, quotes, detached, current \\ nil) do
    record =
      gate(:postgate, post_uri, current)
      |> set_rule("embeddingRules", quotes, fn quotes ->
        if quotes == :disabled, do: [%{"$type" => AtMcp.Network.type(:disable_rule)}]
      end)
      |> Map.delete("detachedEmbeddingUris")
      |> put_present("detachedEmbeddingUris", if(detached != [], do: detached))

    if Map.has_key?(record, "embeddingRules") or Map.has_key?(record, "detachedEmbeddingUris"),
      do: record
  end

  # `:keep` leaves a rule as the record has it: hiding a reply does not touch
  # who may reply.
  defp set_rule(record, _key, :keep, _wire), do: record

  defp set_rule(record, key, rule, wire),
    do: record |> Map.delete(key) |> put_present(key, wire.(rule))

  defp gate(kind, post_uri, current) do
    current = wire_record(current || %{})

    current
    |> Map.put("$type", AtMcp.Network.collection(kind))
    |> Map.put("post", post_uri)
    |> Map.put("createdAt", Map.get(current, "createdAt") || timestamp(nil))
  end

  @doc """
  What a threadgate's `allow` holds for rules `AtMcp.Interactions` reads,
  each once and in order. The account's default reply rule
  (`postInteractionSettingsPref.threadgateAllowRules`) holds the same.
  """
  def reply_rules(rules) when is_list(rules), do: rules |> Enum.map(&reply_rule/1) |> Enum.uniq()

  defp reply_rule(:mention), do: %{"$type" => AtMcp.Network.type(:mention_rule)}
  defp reply_rule(:followers), do: %{"$type" => AtMcp.Network.type(:follower_rule)}
  defp reply_rule(:following), do: %{"$type" => AtMcp.Network.type(:following_rule)}

  defp reply_rule({:list, uri}),
    do: %{"$type" => AtMcp.Network.type(:list_rule), "list" => uri}

  @doc "Build a `feed.like` record over a strong reference."
  def like_record(fields), do: subject_record(:like, fields)

  @doc "Build a `feed.repost` record over a strong reference."
  def repost_record(fields), do: subject_record(:repost, fields)

  @doc "Build a `graph.follow` record. The subject of a follow is a bare DID."
  def follow_record(fields, activated \\ false),
    do: did_subject_record(:follow, fields, activated)

  @doc """
  Build an `actor.status` record saying the account is live at `:url` for
  `:minutes`, with the link card's `:title` and `:description` (empty when not
  given, as a post's link card).
  """
  def status_record(fields) do
    %{
      "$type" => AtMcp.Network.collection(:status),
      "status" => AtMcp.Network.type(:status_live),
      "embed" => external_embed(Map.take(fields, [:url, :title, :description])),
      "durationMinutes" => Map.fetch!(fields, :minutes),
      "createdAt" => timestamp(Map.get(fields, :created_at))
    }
  end

  @doc "Build an `actor.link` record: a link the profile shows, `:url` with an optional `:title`."
  def link_record(fields) do
    %{
      "$type" => AtMcp.Network.collection(:link),
      "url" => Map.fetch!(fields, :url),
      "createdAt" => timestamp(Map.get(fields, :created_at))
    }
    |> put_present("title", Map.get(fields, :title))
  end

  @doc "Build a `graph.block` record. The subject of a block is a bare DID."
  def block_record(fields, activated \\ false), do: did_subject_record(:block, fields, activated)

  @doc """
  Stamp an existing `actor.profile` record with this network's `$type`, and
  set any new `:avatar` or `:banner` blob reference in `blobs`.

  A profile update reads the record it is about to replace, so the fields it
  does not mention survive; only the type is AtMcp's to say.
  """
  def profile_record(current, blobs \\ %{}, activated \\ false) when is_map(current) do
    Enum.reduce(blobs, current, fn {key, blob}, record ->
      record
      |> Map.drop([key, Atom.to_string(key)])
      |> Map.put(Atom.to_string(key), wire_blob(blob))
    end)
    |> Map.drop(["$type", :"$type"])
    |> Map.put("$type", AtMcp.Network.identity_collection(:profile, activated))
  end

  @doc """
  Build a `graph.list` record. Takes `:name`, `:purpose` (`:curatelist`,
  `:modlist` or `:referencelist`, which become this network's tokens), and
  optionally `:description` and `:avatar` (a blob reference).
  """
  def list_record(fields) do
    %{
      "$type" => AtMcp.Network.collection(:list),
      "purpose" => AtMcp.Network.type(Keyword.fetch!(fields, :purpose)),
      "name" => Keyword.fetch!(fields, :name),
      "createdAt" => timestamp(Keyword.get(fields, :created_at))
    }
    |> put_present("description", Keyword.get(fields, :description))
    |> put_present("avatar", Keyword.get(fields, :avatar) && wire_blob(fields[:avatar]))
  end

  @doc "Build a `graph.listitem` record: the account `:subject` (a DID) on the list at `:list`."
  def list_item_record(fields) do
    %{
      "$type" => AtMcp.Network.collection(:list_item),
      "subject" => Keyword.fetch!(fields, :subject),
      "list" => Keyword.fetch!(fields, :list),
      "createdAt" => timestamp(Keyword.get(fields, :created_at))
    }
  end

  @doc """
  Build a `graph.starterpack` record: `:name`, the AT URI of its `:list`, and
  optionally `:description` and `:feeds` (feed generator AT URIs).
  """
  def starter_pack_record(fields) do
    %{
      "$type" => AtMcp.Network.collection(:starter_pack),
      "name" => Keyword.fetch!(fields, :name),
      "list" => Keyword.fetch!(fields, :list),
      "createdAt" => timestamp(Keyword.get(fields, :created_at))
    }
    |> put_present("description", Keyword.get(fields, :description))
    |> put_present("feeds", pack_feeds(Keyword.get(fields, :feeds)))
  end

  @doc """
  Build a `graph.referencelistoptout` record: this account asks to be left
  out of the reference list at `:subject` (a DID-based AT URI).
  """
  def list_opt_out_record(fields) do
    %{
      "$type" => AtMcp.Network.collection(:list_opt_out),
      "subject" => Keyword.fetch!(fields, :subject),
      "createdAt" => timestamp(Keyword.get(fields, :created_at))
    }
  end

  @doc """
  A block of every account on a moderation list (`graph.listblock`): its
  `:subject` is the list's AT URI in DID form, which is how the AppView
  matches it to the list.
  """
  def list_block_record(fields) do
    %{
      "$type" => AtMcp.Network.collection(:list_block),
      "subject" => Keyword.fetch!(fields, :subject),
      "createdAt" => timestamp(Keyword.get(fields, :created_at))
    }
  end

  @doc """
  A record read back from the service with `changes` applied: each is a wire
  key and its new value, or `nil` to remove the key. Every other field is
  kept, and `$type` is the collection it is written back to. A new `description` removes
  `descriptionFacets`, whose byte ranges index the old text.
  """
  def edit_record(current, collection, changes)
      when is_map(current) and is_binary(collection) and is_map(changes) do
    changes =
      if Map.has_key?(changes, "description"),
        do: Map.put_new(changes, "descriptionFacets", nil),
        else: changes

    Enum.reduce(changes, wire_record(current), fn
      {key, nil}, record -> Map.delete(record, key)
      {key, value}, record -> Map.put(record, key, value)
    end)
    |> Map.put("$type", collection)
  end

  @doc "A starter pack's `feeds`: one object per feed generator AT URI."
  def pack_feeds(nil), do: nil
  def pack_feeds(uris) when is_list(uris), do: Enum.map(uris, &%{"uri" => &1})

  @doc """
  The account's `actor.profile` record with `pinnedPost` set to a strong
  reference, or removed when `pinned` is nil. Every other field of `current`
  is kept.
  """
  def pinned_profile_record(current, pinned) when is_map(current) do
    current
    |> wire_record()
    |> Map.delete("pinnedPost")
    |> put_present("pinnedPost", pinned && strong_ref(pinned))
    |> profile_record()
  end

  @doc """
  A `draft.defs#draft` whose first post's text is `text`.

  `current` is the draft as the service holds it, or nil for a new one. Every
  other part of it is kept: later posts in a thread draft, the first post's
  attachments and labels, its languages and its reply and quote settings.
  """
  def draft(text, current \\ nil) when is_binary(text) do
    current = wire_record(current || %{})

    posts =
      case Map.get(current, "posts") do
        [first | rest] when is_map(first) -> [Map.put(first, "text", text) | rest]
        _ -> [%{"text" => text}]
      end

    Map.put(current, "posts", posts)
  end

  @doc """
  A record read back from the service, in the keys it is written with.

  Responses arrive through proto_rune's XRPC client, which snakelizes every
  key and turns the known ones into atoms. A record edited and written back
  goes out with the lexicon's own keys, all strings, so a field this module
  sets cannot sit beside a stale copy of itself under another spelling. Every
  lexicon key is camelCase, so camelizing is the inverse. Delete the rename
  when proto_rune returns response keys as the server sent them.
  """
  def wire_record(map) when is_map(map),
    do:
      Map.new(map, fn {key, value} ->
        {key |> to_string() |> ProtoRune.Case.camelize(), wire_record(value)}
      end)

  def wire_record(list) when is_list(list), do: Enum.map(list, &wire_record/1)
  def wire_record(other), do: other

  defp subject_record(kind, fields) do
    %{
      "$type" => AtMcp.Network.collection(kind),
      "subject" => strong_ref(Keyword.fetch!(fields, :subject)),
      "createdAt" => timestamp(Keyword.get(fields, :created_at))
    }
  end

  defp did_subject_record(kind, fields, activated) do
    %{
      "$type" => AtMcp.Network.identity_collection(kind, activated),
      "subject" => Keyword.fetch!(fields, :subject),
      "createdAt" => timestamp(Keyword.get(fields, :created_at))
    }
  end

  defp timestamp(nil), do: DateTime.to_iso8601(DateTime.utc_now())
  defp timestamp(%DateTime{} = at), do: DateTime.to_iso8601(at)
  defp timestamp(at) when is_binary(at), do: at

  defp strong_ref(%{uri: uri, cid: cid}), do: %{"uri" => uri, "cid" => cid}
  defp strong_ref(%{"uri" => uri, "cid" => cid}), do: %{"uri" => uri, "cid" => cid}

  defp reply_refs(nil), do: nil

  defp reply_refs(%{root: root, parent: parent}),
    do: %{"root" => strong_ref(root), "parent" => strong_ref(parent)}

  # An embed is one field, and the lexicon's answer to "both" is a third type
  # rather than two keys. Building it here is what keeps that a fact about the
  # record instead of a rule each caller has to remember.
  defp post_embed(fields) do
    media =
      images_embed(Keyword.get(fields, :images)) || external_embed(Keyword.get(fields, :link))

    case {media, quote_embed(Keyword.get(fields, :quote))} do
      {nil, nil} ->
        nil

      {media, nil} ->
        media

      {nil, quoted} ->
        quoted

      {media, quoted} ->
        %{
          "$type" => AtMcp.Network.type(:embed_record_with_media),
          "record" => quoted,
          "media" => media
        }
    end
  end

  # A link card: the caller's title and description, and an image blob for its
  # thumbnail when one was uploaded.
  defp external_embed(nil), do: nil

  defp external_embed(%{url: url} = link) do
    %{
      "$type" => AtMcp.Network.type(:embed_external),
      "external" =>
        %{
          "uri" => url,
          "title" => Map.get(link, :title) || "",
          "description" => Map.get(link, :description) || ""
        }
        |> put_present("thumb", link |> Map.get(:thumb_blob) |> wire_blob_or_nil())
    }
  end

  defp wire_blob_or_nil(nil), do: nil
  defp wire_blob_or_nil(blob), do: wire_blob(blob)

  defp images_embed(nil), do: nil
  defp images_embed([]), do: nil

  defp images_embed(images) when is_list(images) do
    %{
      "$type" => AtMcp.Network.type(:embed_images),
      "images" => Enum.map(images, &image/1)
    }
  end

  # Alt text defaults to empty rather than absent: the lexicon requires the
  # field, and an image with no description is a fact about the post worth
  # recording as such.
  defp image(%{blob: blob} = image) do
    %{"image" => wire_blob(blob), "alt" => Map.get(image, :alt) || ""}
    |> put_present("aspectRatio", aspect_ratio(Map.get(image, :aspect_ratio)))
  end

  # `uploadBlob` answers through the XRPC client, which snakelizes every key in
  # every response — so the reference comes back as `mime_type` and has to go
  # out as `mimeType`. `$type`, `size` and `ref.$link` have no case to lose.
  # Delete the rename when proto_rune returns response keys as the server sent
  # them (0.6.0 still snakelizes).
  @doc false
  def wire_blob(blob) when is_map(blob) do
    blob
    |> deep_stringify_keys()
    |> then(fn blob ->
      case Map.pop(blob, "mime_type") do
        {nil, blob} -> blob
        {mime, blob} -> Map.put(blob, "mimeType", mime)
      end
    end)
    |> Map.put_new("$type", "blob")
  end

  def wire_blob(blob), do: blob

  defp aspect_ratio(%{width: width, height: height}),
    do: %{"width" => width, "height" => height}

  defp aspect_ratio(_), do: nil

  defp quote_embed(nil), do: nil

  defp quote_embed(ref),
    do: %{"$type" => AtMcp.Network.type(:embed_record), "record" => strong_ref(ref)}

  # `AtMcp.RichText` builds facets in proto_rune's internal shape — snake_case
  # atoms — because the library's builder does. The wire wants `byteStart`, so
  # the translation happens here, once: a record that is only correct after
  # something downstream rewrites its keys is not a record AtMcp built.
  defp wire_facets(nil), do: nil
  defp wire_facets([]), do: nil

  defp wire_facets(facets) when is_list(facets), do: Enum.map(facets, &wire_facet/1)

  defp wire_facet(%{index: %{byte_start: start, byte_end: stop}, features: features}) do
    %{
      "index" => %{"byteStart" => start, "byteEnd" => stop},
      "features" => Enum.map(features, &stringify_keys/1)
    }
  end

  defp stringify_keys(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp deep_stringify_keys(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), deep_stringify_keys(value)} end)

  defp deep_stringify_keys(list) when is_list(list), do: Enum.map(list, &deep_stringify_keys/1)
  defp deep_stringify_keys(other), do: other

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
