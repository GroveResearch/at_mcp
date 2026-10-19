defmodule AtMcp.Effects.ProtoRune do
  @moduledoc """
  The real network backend: one `ProtoRune.login/2`, then reuse that session.
  Returns structured summary maps — never session inspect dumps.

  Reads and writes both go through `AtMcp.ATProto`, so every method name, and
  every record's collection and `$type`, derive from `AtMcp.Network`.
  `ProtoRune.Bsky` is not called: it compiles `app.bsky.*` into method names and
  records, and validates records through Peri schemas that drop keys they do not
  declare.

  What this module owns about a write is the part that is not the record:
  resolving an actor to a DID, reading a parent post to build a reply's strong
  references, and turning a result into a summary or one of AtMcp's failure
  kinds.
  """

  @behaviour AtMcp.Effects.Backend

  @impl true
  def requires_credentials?, do: true

  @impl true
  def login(opts) do
    handle = Keyword.fetch!(opts, :handle)
    password = Keyword.fetch!(opts, :password)

    case ProtoRune.login(handle, password, Keyword.take(opts, [:service])) do
      {:ok, session} -> {:ok, session}
      {:error, reason} -> {:error, failure(reason)}
    end
  end

  @impl true
  def refresh(session) do
    # proto_rune (0.5.3 and 0.6.0) POSTs `json: %{}` for refreshSession; Bluesky
    # replies 400 "A request body was provided when none was expected".
    # Empty-body POST with the refresh JWT, then parse like login.
    # Delete and call `ProtoRune.Atproto.Server.refresh_session/1` when it
    # sends no body.
    refresh_jwt = Map.get(session, :refresh_jwt)

    if not is_binary(refresh_jwt) or refresh_jwt == "" do
      {:error, AtMcp.Effects.Failure.new(:auth_refused, detail: :missing_refresh_jwt)}
    else
      base_url =
        Map.get(session, :service_url) || ProtoRune.Config.default_base_url()

      url = Path.join(base_url, "com.atproto.server.refreshSession")

      case ProtoRune.HTTPClient.request(:post, url,
             headers: [{"authorization", "Bearer #{refresh_jwt}"}]
           ) do
        {:ok, %{status: status, body: body}} when status in [200, 201] ->
          data = body |> decode_json_body() |> ProtoRune.Case.snakelize_enum()

          {:ok, fresh} = ProtoRune.Atproto.Session.parse(data)
          service_url = Map.get(fresh, :service_url) || Map.get(session, :service_url)
          {:ok, Map.put(fresh, :service_url, service_url)}

        {:ok, %{status: status, body: body} = resp} when status >= 400 ->
          decoded = decode_json_body(body)

          {:error, failure(ProtoRune.XRPC.Error.from(%{resp | body: decoded}))}

        {:error, reason} ->
          {:error, failure(reason)}
      end
    end
  end

  @impl true
  def get_membership(session) do
    if AtMcp.Network.name() == :delve do
      case AtMcp.ATProto.get_membership(session, %{}) do
        {:ok, response} when is_map(response) ->
          summary = AtMcp.Summary.extract(:membership, response)
          member = summary.membership

          valid_member =
            is_nil(member) or
              (Enum.all?(Map.values(member), &(not is_nil(&1))) and
                 member.status in ["active", "withdrawn"] and member.did == session.did)

          if is_boolean(summary.enabled) and valid_member and
               (is_nil(AtMcp.Response.dig(response, ["membership"])) or is_map(member)),
             do: {:ok, summary},
             else: {:error, unreadable("membership status", response)}

        {:ok, response} ->
          {:error, unreadable("membership status", response)}

        {:error, reason} ->
          {:error, failure(reason)}
      end
    else
      {:error,
       AtMcp.Effects.Failure.new(:refused,
         detail: :membership_not_supported
       )}
    end
  end

  @impl true
  def list_notifications(session, opts) do
    pr_opts =
      opts
      |> Keyword.take([:limit, :cursor, :reasons])
      |> Keyword.put_new(:limit, 20)

    case AtMcp.ATProto.list_notifications(session, AtMcp.ATProto.params(Map.new(pr_opts))) do
      {:ok, notifs} -> page(notifs, :notifications, &notif_item/1)
      {:error, reason} -> {:error, failure(reason)}
    end
  end

  @impl true
  def get_unread_count(session) do
    case AtMcp.ATProto.get_unread_count(session, %{}) do
      {:ok, response} when is_map(response) ->
        case AtMcp.Response.fetch(response, :count) do
          {:ok, count} when is_integer(count) -> {:ok, %{count: count}}
          _ -> {:error, unreadable("an unread count", response)}
        end

      {:error, reason} ->
        {:error, failure(reason)}
    end
  end

  # What `get_thread/2` returns per node, and what its `context` says it
  # returns per node: one number, because a reader acts on the second and gets
  # the first. This is not @chain_max_replies — that one bounds a different
  # read, and the two are free to differ.
  @thread_max_replies 20

  # How far `get_thread/2` reads around a post: two levels of parents, two of
  # replies. The tool's description states these through `thread_shape/0`.
  @thread_parent_height 2
  @thread_depth 2

  @doc "What `get_thread/2` reads around a post, for the tool that describes it."
  def thread_shape,
    do: %{
      parent_height: @thread_parent_height,
      depth: @thread_depth,
      replies: @thread_max_replies
    }

  @impl true
  def get_thread(session, uri) when is_binary(uri) do
    case AtMcp.ATProto.get_post_thread(session, %{
           uri: uri,
           depth: @thread_depth,
           parentHeight: @thread_parent_height
         }) do
      {:ok, thread} -> {:ok, summarize_thread(thread)}
      {:error, reason} -> {:error, failure(reason)}
    end
  end

  # The chain becomes a woken agent's context for one turn, so its length is
  # the input size that matters. 100 elements of ordinary posts is on the order
  # of 50 KB of JSON; a conversation taller than that is cut to its last 100
  # elements — the ones nearest the post being answered — and the number
  # dropped is reported in `chain_omitted`. Nothing downstream bounds this
  # read: `AtMcp.Effects.page_options/1` caps feeds, not threads.
  @chain_max_elements 100

  # `town.delve.feed.getPostThread` and `app.bsky.feed.getPostThread` both
  # declare `parentHeight` minimum 0, maximum 1000. Neither lexicon is vendored
  # here — priv/lexicons/README.md keeps only each network's `feed/post.json`,
  # deliberately — so that range is read from the upstream town lexicon
  # `town/delve/feed/getPostThread.json`. Asking for more
  # ancestors than the chain can carry only moves bytes that are then dropped,
  # so the request asks for exactly the cap.
  @chain_parent_height @chain_max_elements

  # One level of replies: the posts directly under the requested one. An
  # agent answering a notification is placed in the conversation it was
  # named in, not handed the subtree below it.
  @chain_depth 1
  @chain_max_replies 20

  # A response cannot be followed upward forever: a parent link chain longer
  # than this is not a conversation, and reading stops there. The chain then
  # does not start at the root, which `chain_truncated` reports.
  @chain_read_limit 5_000

  # A service that caps `parentHeight` below what it was asked for answers with
  # a partial chain, so the walk asks again from the top of what it got. Each
  # further call climbs another @chain_parent_height ancestors. The chain
  # reports where it stopped rather than climbing without a bound.
  @chain_walk_limit 4

  @doc """
  The conversation leading to one post, root first, as a flat list.

  `get_thread/2` answers "what is around this post": two levels up, two levels
  down, nested. This answers the other question — "what was said before this
  was said to me" — and the shapes differ because the uses do. A chain element
  carries what a reader of a conversation needs and a feed item does not: when
  it was written, what it replied to, whether this account wrote it, and the
  destinations its facets point at.

  The chain always ends at the post it was asked for. It begins at the thread
  root whenever the read can reach it; when it cannot, the first element names
  the uri where reading stopped and `chain_truncated` is true, rather than a
  shorter chain that silently does not start where the conversation did. It
  carries at most #{@chain_max_elements} elements: a taller conversation keeps
  the ones nearest the requested post, `chain_omitted` counts the rest, and
  `chain_truncated` is true.

  A cut chain says where to carry on. `chain_before` is the parent of the
  element the cut left at the head. Passing it back as `:before` reads the page
  above: the chain then ends at that uri instead of at the requested post, so a
  conversation of any height is readable in pages that neither repeat a post
  nor skip one. A page read this way carries no replies; the replies belong to
  the post the caller asked about, and returning an ancestor's would put a post
  in two pages.

  `chain_before` is `nil` whenever there is no uri to read next that would
  bring the caller anything new: a chain that runs from the root, a head that
  could not be read and so names no parent, a head whose parent the page
  already holds, and a walk that turned back on itself and stopped at a uri it
  had already read. Nil is not "the conversation is complete" — that is what
  `chain_truncated` answers — it is "nowhere to resume". A caller that wants to
  try past a head the walk could not read has that head's own uri in the chain,
  flagged `unresolved`.

  The chain never repeats a post. A response whose parent links do not converge
  on the root — a reply whose declared root is not its topmost ancestor, or two
  records naming each other as parent — ends the walk instead of prepending
  ancestors it has already read.
  """
  @impl true
  def get_thread_chain(session, uri, opts \\ []) when is_binary(uri) do
    # `AtMcp.Effects.get_thread_chain/3` refuses anything else before a session
    # is taken, so a `before` that reaches here is a uri or nothing. The third
    # clause is still here because a cursor comes back from whoever holds it,
    # and a backend that raises on a bad argument is a harder failure than one
    # that refuses it.
    case Keyword.get(opts, :before) do
      nil -> chain_ending_at(session, uri, @chain_depth, :with_replies)
      before when is_binary(before) -> chain_ending_at(session, before, 0, :chain_only)
      _other -> {:error, :invalid_before}
    end
  end

  defp chain_ending_at(session, uri, depth, replies) do
    with {:ok, node} <- fetch_thread(session, uri, depth) do
      did = Map.get(session, :did)
      declared = AtMcp.Response.dig(node, [:post, :record, :reply, :root, :uri])
      root_uri = if is_binary(declared), do: declared, else: uri

      {walked, truncated, stop} =
        reach_root(session, chain_elements(node, did), root_uri, did, @chain_walk_limit)

      {chain, chain_omitted} = cap_chain(walked)
      {replies, replies_omitted} = chain_replies(node, did, replies)
      truncated = truncated or chain_omitted > 0 or Enum.any?(chain, &unreadable_element?/1)

      {:ok,
       %{
         root_uri: root_uri,
         chain: chain,
         chain_omitted: chain_omitted,
         chain_truncated: truncated,
         chain_before: chain_before(chain, truncated, stop),
         replies: replies,
         replies_omitted: replies_omitted
       }}
    end
  end

  # Where a caller resumes, and nil wherever resuming would hand it a post it
  # already has. A chain that runs from the root has nothing above it. A head
  # that could not be read names no parent, so there is no uri to read next
  # that is not one of these; the head element carries its own uri and says it
  # is unresolved, which is what a caller reads to decide whether to try it.
  # And a head whose parent is already in the page is a walk that turned back
  # on itself — two records naming each other as parent, or a declared root
  # below the topmost ancestor — where resuming would return this page again,
  # forever.
  defp chain_before(_chain, false, _stop), do: nil
  defp chain_before(_chain, true, :turned_back), do: nil
  defp chain_before([], _truncated, _stop), do: nil

  defp chain_before([head | _rest] = chain, true, _stop) do
    if not head.unresolved and is_binary(head.reply_to) and
         not Enum.any?(chain, &(&1.uri == head.reply_to)),
       do: head.reply_to
  end

  @impl true
  def get_timeline(session, opts) do
    limit = Keyword.get(opts, :limit, 20)

    case AtMcp.ATProto.get_timeline(
           session,
           AtMcp.ATProto.params(%{limit: limit, cursor: Keyword.get(opts, :cursor)})
         ) do
      {:ok, feed} -> page(feed, :feed, &feed_item/1)
      {:error, reason} -> {:error, failure(reason)}
    end
  end

  @impl true
  def get_author_feed(session, actor, opts) when is_binary(actor) do
    session
    |> AtMcp.ATProto.get_author_feed(paging(opts, %{actor: actor}))
    |> read(:feed, &feed_item/1)
  end

  @impl true
  def get_profile(session, actor) when is_binary(actor) do
    case AtMcp.ATProto.get_profile(session, %{actor: actor}) do
      {:ok, profile} -> {:ok, summarize_profile(profile)}
      {:error, reason} -> {:error, failure(reason)}
    end
  end

  @impl true
  def get_profiles(session, actors) when is_list(actors) do
    session
    |> AtMcp.ATProto.get_profiles(actors)
    |> read(:profiles, &summarize_profile/1)
  end

  @impl true
  def get_posts(session, uris) when is_list(uris) do
    session
    |> AtMcp.ATProto.get_posts(uris)
    |> read(:posts, &post_view/1)
  end

  # `AtMcp.Effects.search_posts/3`'s filters in the words the tool takes, and
  # the `feed.searchPostsV2` parameter each becomes. A single author, mention
  # or language is the one-entry list the service takes.
  @search_params %{
    author: "authors",
    mentions: "mentions",
    lang: "languages",
    exclude_authors: "excludeAuthors",
    exclude_mentions: "excludeMentions",
    domains: "domains",
    exclude_domains: "excludeDomains",
    urls: "urls",
    exclude_urls: "excludeUrls",
    embeds: "embeddedAtUris",
    exclude_embeds: "excludeEmbeddedAtUris",
    hashtags: "hashtags",
    exclude_hashtags: "excludeHashtags",
    exclude_langs: "excludeLanguages",
    since: "since",
    until: "until",
    has_media: "hasMedia",
    has_video: "hasVideo",
    reply_to: "replyParentUri",
    thread_root: "threadRootUri",
    following: "following",
    query_language: "queryLanguage"
  }

  @impl true
  def search_posts(session, query, opts) do
    filters =
      for {key, value} <- opts, wire = @search_params[key], into: %{} do
        {wire, if(key in [:author, :mentions, :lang], do: [value], else: value)}
      end

    params =
      filters
      |> Map.merge(%{
        "query" => query,
        "limit" => Keyword.get(opts, :limit, 20),
        "cursor" => Keyword.get(opts, :cursor),
        # A call that says nothing gets what the first version gave it, whose
        # lexicon defaults `sort` to latest and whose handler always searches
        # every post (`allTime: true // match v1 behavior, v2 defaults to
        # false`, packages/bsky/src/api/app/bsky/feed/searchPosts.ts). This
        # version defaults to top and to its recent window. The tool says
        # latest, as the first version did; this version says recent.
        "sort" =>
          case Keyword.get(opts, :sort) do
            "top" -> "top"
            _latest_or_nil -> "recent"
          end,
        "allTime" => if(Keyword.get(opts, :all_time, true), do: true),
        "excludeReplies" => if(Keyword.get(opts, :replies) == "exclude", do: true),
        "repliesOnly" => if(Keyword.get(opts, :replies) == "only", do: true)
      })
      |> AtMcp.ATProto.params()

    case AtMcp.ATProto.search_posts(session, params) do
      {:ok, raw} -> page(raw, :posts, &post_view/1)
      {:error, reason} -> {:error, failure(reason)}
    end
  end

  @impl true
  def search_actors(session, query, opts) when is_binary(query) do
    limit = Keyword.get(opts, :limit, 20)

    case AtMcp.ATProto.search_actors(
           session,
           AtMcp.ATProto.params(%{q: query, limit: limit, cursor: Keyword.get(opts, :cursor)})
         ) do
      {:ok, raw} -> page(raw, :actors, &summarize_profile/1)
      {:error, reason} -> {:error, failure(reason)}
    end
  end

  # --- graph reads ---

  @impl true
  def get_followers(session, actor, opts) when is_binary(actor) do
    session
    |> AtMcp.ATProto.get_followers(paging(opts, %{actor: actor}))
    |> read(:followers, &summarize_profile/1)
  end

  @impl true
  def get_follows(session, actor, opts) when is_binary(actor) do
    session
    |> AtMcp.ATProto.get_follows(paging(opts, %{actor: actor}))
    |> read(:follows, &summarize_profile/1)
  end

  @impl true
  def get_known_followers(session, actor, opts) when is_binary(actor) do
    session
    |> AtMcp.ATProto.get_known_followers(paging(opts, %{actor: actor}))
    |> read(:followers, &summarize_profile/1)
  end

  @impl true
  def get_suggested_follows(session, actor) when is_binary(actor) do
    session
    |> AtMcp.ATProto.get_suggested_follows_by_actor(%{actor: actor})
    |> read(:suggestions, &summarize_profile/1)
  end

  @impl true
  def get_suggested_accounts(session, "actor.getSuggestions", opts) do
    session
    |> AtMcp.ATProto.get_suggestions(paging(opts, %{}))
    |> read(:actors, &summarize_profile/1)
  end

  def get_suggested_accounts(session, suffix, opts) do
    params =
      AtMcp.ATProto.params(%{
        limit: Keyword.get(opts, :limit, 20),
        category: Keyword.get(opts, :category)
      })

    session
    |> AtMcp.ATProto.get_suggested_users(suffix, params)
    |> read(:actors, &summarize_profile/1)
  end

  @impl true
  def get_blocks(session, opts) do
    session
    |> AtMcp.ATProto.get_blocks(paging(opts, %{}))
    |> read(:blocks, &summarize_profile/1)
  end

  @impl true
  def get_mutes(session, opts) do
    session
    |> AtMcp.ATProto.get_mutes(paging(opts, %{}))
    |> read(:mutes, &summarize_profile/1)
  end

  # The AppView resolves only `actor` and keys `others` by DID, so a handle
  # there is never found. Resolve each entry here, the way a mention is
  # resolved before a post is built, and send only DIDs. A handle that does
  # not resolve stays in its place as `not_found`, named by the handle the
  # caller passed. Retire this when that service resolves `others` the same way.
  @impl true
  def get_relationships(session, actor, others) when is_binary(actor) and is_list(others) do
    with {:ok, resolved} <- resolve_others(session, others) do
      case for {:ok, did} <- resolved, do: did do
        [] ->
          {:ok, relationship_page(Enum.map(resolved, &missing_relationship/1))}

        dids ->
          session
          |> AtMcp.ATProto.get_relationships(actor, dids)
          |> read(:relationships, &relationship_item/1)
          |> align_relationships(resolved, dids)
      end
    end
  end

  defp resolve_others(session, others) do
    others
    |> Enum.reduce_while([], fn other, acc ->
      case resolve_actor(session, other) do
        {:ok, did} ->
          {:cont, [{:ok, did} | acc]}

        {:error, {:handle_not_resolved, handle}} ->
          {:cont, [{:error, {:handle_not_resolved, handle}} | acc]}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:error, reason} -> {:error, reason}
      acc -> {:ok, Enum.reverse(acc)}
    end
  end

  # The service's list is one entry per DID sent, in that order. A different
  # length cannot be zipped back onto the accounts that were asked about: the
  # one relationship left would be reported for the wrong account.
  defp align_relationships({:ok, %{items: items} = page}, resolved, dids)
       when length(items) == length(dids) do
    zipped = zip_relationships(resolved, items)
    {:ok, %{page | items: zipped, count: length(zipped)}}
  end

  defp align_relationships({:ok, page}, _resolved, _dids),
    do: {:error, unreadable("a page of relationships", page)}

  defp align_relationships({:error, _} = error, _resolved, _dids), do: error

  defp zip_relationships(resolved, items) do
    {zipped, []} =
      Enum.map_reduce(resolved, items, fn
        {:error, {:handle_not_resolved, _handle}} = missing, rest ->
          {missing_relationship(missing), rest}

        {:ok, _did}, [item | rest] ->
          {item, rest}
      end)

    zipped
  end

  defp missing_relationship({:error, {:handle_not_resolved, handle}}) do
    relationship_item(%{"did" => handle, "notFound" => true})
  end

  defp relationship_page(items) do
    %{count: length(items), items: items, cursor: nil}
  end

  # --- engagement reads ---

  # A like is a record about an actor, the way a feed item is a record about a
  # post. The affordance is who liked this, so the actor is what is summarized.
  @impl true
  def get_likes(session, uri, opts) when is_binary(uri) do
    session
    |> AtMcp.ATProto.get_likes(paging(opts, %{uri: uri}))
    |> read(:likes, &actor_item/1)
  end

  @impl true
  def get_reposted_by(session, uri, opts) when is_binary(uri) do
    session
    |> AtMcp.ATProto.get_reposted_by(paging(opts, %{uri: uri}))
    |> read(:reposted_by, &summarize_profile/1)
  end

  @impl true
  def get_quotes(session, uri, opts) when is_binary(uri) do
    session
    |> AtMcp.ATProto.get_quotes(paging(opts, %{uri: uri}))
    |> read(:posts, &post_view/1)
  end

  @impl true
  def get_actor_likes(session, actor, opts) when is_binary(actor) do
    session
    |> AtMcp.ATProto.get_actor_likes(paging(opts, %{actor: actor}))
    |> read(:feed, &feed_item/1)
  end

  # --- feeds ---

  @impl true
  def get_feed(session, feed, opts) when is_binary(feed) do
    session
    |> AtMcp.ATProto.get_feed(paging(opts, %{feed: feed}))
    |> read(:feed, &feed_item/1)
  end

  @impl true
  def get_suggested_feeds(session, opts) do
    if Keyword.get(opts, :source) == :unspecced do
      session
      |> AtMcp.ATProto.get_unspecced_suggested_feeds(%{limit: Keyword.get(opts, :limit, 20)})
      |> read(:feeds, &summarize_generator/1)
    else
      session
      |> AtMcp.ATProto.get_suggested_feeds(paging(opts, %{}))
      |> read(:feeds, &summarize_generator/1)
    end
  end

  # One feed is read with `getFeedGenerator`, which says whether its service
  # is online and valid. Several are read with `getFeedGenerators`, which does
  # not say, and leaves out a feed it does not know; those are `not_found`.
  @impl true
  def get_feed_info(session, [uri]) do
    case AtMcp.ATProto.get_feed_generator(session, %{feed: uri}) do
      {:ok, response} -> feed_info(response)
      {:error, reason} -> {:error, failure(reason)}
    end
  end

  def get_feed_info(session, uris) when is_list(uris) do
    with {:ok, page} <-
           session
           |> AtMcp.ATProto.get_feed_generators(uris)
           |> read(:feeds, &summarize_generator/1) do
      found = MapSet.new(page.items, &Map.get(&1, :uri))
      items = Enum.map(page.items, &Map.merge(&1, %{is_online: nil, is_valid: nil}))
      {:ok, %{page | items: items} |> Map.put(:not_found, Enum.reject(uris, &(&1 in found)))}
    end
  end

  defp feed_info(response) do
    case AtMcp.Response.fetch(response, :view) do
      {:ok, view} when is_map(view) ->
        item =
          view
          |> summarize_generator()
          |> Map.merge(%{
            is_online: boolean_field(response, :is_online),
            is_valid: boolean_field(response, :is_valid)
          })

        {:ok, %{count: 1, items: [item], cursor: nil, not_found: []}}

      _ ->
        {:error, unreadable("a feed generator", response)}
    end
  end

  defp boolean_field(map, key) do
    case field(map, key) do
      value when is_boolean(value) -> value
      _ -> nil
    end
  end

  @impl true
  def get_actor_feeds(session, actor, opts) when is_binary(actor) do
    session
    |> AtMcp.ATProto.get_actor_feeds(paging(opts, %{actor: actor}))
    |> read(:feeds, &summarize_generator/1)
  end

  @impl true
  def search_feeds(session, query, opts) do
    session
    |> AtMcp.ATProto.get_popular_feed_generators(paging(opts, %{query: query}))
    |> read(:feeds, &summarize_generator/1)
  end

  @impl true
  def get_suggested_starter_packs(session, suffix, opts) do
    session
    |> AtMcp.ATProto.get_suggested_starter_packs(suffix, %{limit: Keyword.get(opts, :limit, 20)})
    |> read(:starter_packs, &pack_view/1)
  end

  @impl true
  def get_trends(session, "unspecced.getTrends", opts) do
    session
    |> AtMcp.ATProto.get_trends(%{limit: Keyword.get(opts, :limit, 20)})
    |> read(:trends, &trend/1)
  end

  def get_trends(session, "unspecced.getTrendingTopics", opts) do
    case AtMcp.ATProto.get_trending_topics(session, %{limit: Keyword.get(opts, :limit, 20)}) do
      {:ok, response} -> topics(response)
      {:error, reason} -> {:error, failure(reason)}
    end
  end

  # Trending topics, and beside them the topics the service suggests.
  defp topics(response) do
    with {:ok, page} <- page(response, :topics, &trend/1) do
      case field(response, :suggested) do
        suggested when is_list(suggested) ->
          {:ok, Map.put(page, :suggested, Enum.map(suggested, &trend/1))}

        _ ->
          {:error, unreadable("trending topics", response)}
      end
    end
  end

  defp trend(item), do: AtMcp.Summary.extract(:trend, item)

  @impl true
  def get_record(session, uri) when is_binary(uri) do
    {:ok, {repo, collection, rkey}} = AtMcp.ATProto.parse_uri(uri)

    case AtMcp.ATProto.get_record_as_stored(session, %{
           repo: repo,
           collection: collection,
           rkey: rkey
         }) do
      {:ok, %{"value" => value} = response} ->
        {:ok,
         %{
           uri: canonical(response, uri),
           cid: Map.get(response, "cid"),
           value: value
         }}

      {:ok, other} ->
        {:error, unreadable("a record", other)}

      {:error, :unreadable_record} ->
        {:error, unreadable("a record", %{})}

      {:error, reason} ->
        {:error, not_found_or_failure(reason, "record", uri)}
    end
  end

  # What a read answers for a record, list or starter pack that does not exist,
  # deleted or never written, as the reference services at the vendored
  # lexicons' commit word it: `repo.getRecord` with the lexicon's
  # `RecordNotFound`; `graph.getList` and `graph.getStarterPack`, which declare
  # no error of their own, with `InvalidRequest` and these messages. Any other
  # failure keeps its kind.
  @not_found %{
    "record" => {:record_not_found, nil},
    "list" => {:invalid_request, "List not found"},
    "starter pack" => {:invalid_request, "Starter pack not found"}
  }

  defp not_found_or_failure(%ProtoRune.XRPC.Error{} = error, what, uri) do
    {reason, message} = Map.fetch!(@not_found, what)

    # proto_rune gives an error name it has an atom for as that atom, and any
    # other as its snake_case string.
    if error.reason in [reason, Atom.to_string(reason)] and
         (is_nil(message) or error.message == message) do
      AtMcp.Effects.Failure.new(:refused,
        status: error.http_status,
        message: error.message,
        detail: {:not_found, what, uri}
      )
    else
      failure(error)
    end
  end

  defp not_found_or_failure(reason, _what, _uri), do: failure(reason)

  # Invitation codes are delve.town's: the town's app lists them, and asks for
  # used ones and newly earned ones as it does here.
  @impl true
  def get_invite_codes(session) do
    if AtMcp.Network.name() == :delve do
      case AtMcp.ATProto.get_invite_codes(session, %{includeUsed: true, createAvailable: true}) do
        {:ok, response} -> invite_codes(response)
        {:error, reason} -> {:error, failure(reason)}
      end
    else
      {:error, AtMcp.Effects.Failure.new(:refused, detail: :invite_codes_not_supported)}
    end
  end

  defp invite_codes(response) do
    with {:ok, page} <- page(response, :codes, &AtMcp.Summary.extract(:invite_code, &1)) do
      # Whether the town issues earned codes. Read when it is there and never
      # required: the method has no published lexicon to promise it.
      collection =
        case field(response, :collection) do
          collection when is_binary(collection) -> collection
          _ -> nil
        end

      {:ok, page |> Map.delete(:cursor) |> Map.put(:collection, collection)}
    end
  end

  @impl true
  def get_list_feed(session, list, opts) when is_binary(list) do
    session
    |> AtMcp.ATProto.get_list_feed(paging(opts, %{list: list}))
    |> read(:feed, &feed_item/1)
  end

  # --- lists and starter packs ---

  @impl true
  def get_list(session, uri, opts) when is_binary(uri) do
    case AtMcp.ATProto.get_list(session, paging(opts, %{list: uri})) do
      {:ok, response} -> list_page(response)
      {:error, reason} -> {:error, not_found_or_failure(reason, "list", uri)}
    end
  end

  # A list's members are a page; the list itself rides beside them.
  defp list_page(response) do
    with {:ok, page} <- page(response, :items, &list_member/1) do
      case AtMcp.Response.fetch(response, :list) do
        {:ok, list} when is_map(list) -> {:ok, Map.put(page, :list, list_view(list))}
        _ -> {:error, unreadable("a list", response)}
      end
    end
  end

  @impl true
  def get_lists(session, actor, opts) when is_binary(actor) do
    session
    |> AtMcp.ATProto.get_lists(list_paging(opts, actor))
    |> read(:lists, &list_view/1)
  end

  @impl true
  def get_lists_with_membership(session, actor, opts) when is_binary(actor) do
    session
    |> AtMcp.ATProto.get_lists_with_membership(list_paging(opts, actor))
    |> read(:lists_with_membership, fn item -> with_membership(item, :list, &list_view/1) end)
  end

  defp list_paging(opts, actor),
    do: Map.put(paging(opts, %{actor: actor}), :purposes, Keyword.get(opts, :purposes, []))

  @impl true
  def get_starter_pack(session, uri) when is_binary(uri) do
    case AtMcp.ATProto.get_starter_pack(session, %{starterPack: uri}) do
      {:ok, response} ->
        case AtMcp.Response.fetch(response, :starter_pack) do
          {:ok, pack} when is_map(pack) -> {:ok, pack_view(pack)}
          _ -> {:error, unreadable("a starter pack", response)}
        end

      {:error, reason} ->
        {:error, not_found_or_failure(reason, "starter pack", uri)}
    end
  end

  @impl true
  def get_actor_starter_packs(session, actor, opts) when is_binary(actor) do
    session
    |> AtMcp.ATProto.get_actor_starter_packs(paging(opts, %{actor: actor}))
    |> read(:starter_packs, &pack_view/1)
  end

  @impl true
  def search_starter_packs(session, query, opts) when is_binary(query) do
    session
    |> AtMcp.ATProto.search_starter_packs(paging(opts, %{q: query}))
    |> read(:starter_packs, &pack_view/1)
  end

  @impl true
  def get_starter_packs_with_membership(session, actor, opts) when is_binary(actor) do
    session
    |> AtMcp.ATProto.get_starter_packs_with_membership(paging(opts, %{actor: actor}))
    |> read(:starter_packs_with_membership, fn item ->
      with_membership(item, :starter_pack, &pack_view/1)
    end)
  end

  # A list or starter pack read with an account in mind, and the list item
  # that puts that account in it, if one does.
  defp with_membership(item, key, view) when is_map(item) do
    viewed =
      case AtMcp.Response.fetch(item, key) do
        {:ok, value} when is_map(value) -> view.(value)
        _ -> view.(%{})
      end

    item_uri =
      AtMcp.Response.dig(item, [:list_item, :uri]) ||
        AtMcp.Response.dig(item, ["listItem", "uri"])

    Map.put(viewed, :member_item, if(is_binary(item_uri), do: item_uri))
  end

  defp with_membership(other, _key, _view), do: %{value: to_string_safe(other)}

  @impl true
  def prepare_list_write(session, {:create_list, fields}) do
    with {:ok, avatar} <- upload_avatar(session, fields[:avatar]) do
      [rkey] = AtMcp.ATProto.tids(1)

      record =
        AtMcp.ATProto.list_record(
          name: fields.name,
          purpose: fields.purpose,
          description: blank_nil(fields[:description]),
          avatar: avatar
        )

      prepared(
        [new_record(:list, rkey, record)],
        %{
          action: :create_list,
          uri: own_uri(session, :list, rkey),
          name: fields.name,
          purpose: purpose_name(fields.purpose)
        }
      )
    end
  end

  def prepare_list_write(session, {:update_list, uri, changes}) do
    with {:ok, current, cid} <- own_record(session, uri, "uri", "list"),
         {:ok, avatar} <- upload_avatar(session, changes[:avatar]) do
      edits =
        %{}
        |> edit("name", changes[:name])
        |> edit("description", changes[:description])
        |> edit("avatar", avatar && AtMcp.ATProto.wire_blob(avatar))

      replacement(uri, current, cid, edits, %{
        action: :update_list,
        uri: uri,
        name: changes[:name]
      })
    end
  end

  def prepare_list_write(session, {:delete_list, uri}) do
    with {:ok, commit} <- latest_commit(session),
         {:ok, current} <- own_value(session, uri, "uri", "list"),
         :ok <- not_pack_list(current),
         {:ok, items} <- list_items(session, uri, nil) do
      # The items go first: a list too large for one commit is left standing
      # until the last, so what remains of a failed deletion is still a list
      # that delete_list can be asked about again.
      prepared(
        Enum.map(items ++ [uri], &removal/1),
        %{action: :delete_list, uri: uri, deleted: items ++ [uri]},
        swap_commit: commit
      )
    end
  end

  def prepare_list_write(session, {:add_to_list, uri, did}) do
    with {:ok, commit} <- latest_commit(session),
         {:ok, list} <- target_list(session, uri),
         {:ok, items} <- list_items(session, list, did) do
      case items do
        # Already on it: a second item would be one more record to remove.
        [item | _] ->
          prepared([], %{action: :add_to_list, uri: item, list: list, actor: did, unchanged: true})

        [] ->
          [rkey] = AtMcp.ATProto.tids(1)
          record = AtMcp.ATProto.list_item_record(subject: did, list: list)

          prepared(
            [new_record(:list_item, rkey, record)],
            %{
              action: :add_to_list,
              uri: own_uri(session, :list_item, rkey),
              list: list,
              actor: did
            },
            swap_commit: commit
          )
      end
    end
  end

  def prepare_list_write(session, {:remove_from_list, uri, did}) do
    with {:ok, commit} <- latest_commit(session),
         {:ok, list} <- target_list(session, uri),
         {:ok, items} <- list_items(session, list, did) do
      case items do
        [] ->
          {:error, {:invalid_argument, "actor", "#{did} is not on the list #{list}"}}

        [first | _] ->
          prepared(
            Enum.map(items, &removal/1),
            %{action: :remove_from_list, uri: first, list: list, actor: did, deleted: items},
            swap_commit: commit
          )
      end
    end
  end

  def prepare_list_write(session, {:create_starter_pack, fields}) do
    dids = fields[:actors] || []
    [list_rkey, pack_rkey | item_rkeys] = AtMcp.ATProto.tids(2 + length(dids))
    list = own_uri(session, :list, list_rkey)

    items =
      Enum.zip_with(dids, item_rkeys, fn did, rkey ->
        new_record(
          :list_item,
          rkey,
          AtMcp.ATProto.list_item_record(subject: did, list: list)
        )
      end)

    pack =
      AtMcp.ATProto.starter_pack_record(
        name: fields.name,
        list: list,
        description: blank_nil(fields[:description]),
        feeds: if(fields[:feeds] in [nil, []], do: nil, else: fields[:feeds])
      )

    # A pack's name may run to 500 bytes and a list's to 64. The list is not
    # shown apart from its pack, so it takes as much of the name as fits.
    {_min, list_name_bytes, _graphemes} = AtMcp.Effects.text_limits().list_name
    list_name = fit_bytes(fields.name, list_name_bytes)

    prepared(
      [
        new_record(
          :list,
          list_rkey,
          AtMcp.ATProto.list_record(name: list_name, purpose: :referencelist)
        )
        | items
      ] ++ [new_record(:starter_pack, pack_rkey, pack)],
      %{
        action: :create_starter_pack,
        uri: own_uri(session, :starter_pack, pack_rkey),
        list: list,
        name: fields.name
      }
    )
  end

  def prepare_list_write(session, {:update_starter_pack, uri, changes}) do
    with {:ok, current, cid} <- own_record(session, uri, "uri", "starter pack") do
      feeds =
        case changes[:feeds] do
          nil -> nil
          [] -> ""
          uris -> AtMcp.ATProto.pack_feeds(uris)
        end

      edits =
        %{}
        |> edit("name", changes[:name])
        |> edit("description", changes[:description])
        |> edit("feeds", feeds)

      replacement(uri, current, cid, edits, %{
        action: :update_starter_pack,
        uri: uri,
        name: changes[:name]
      })
    end
  end

  def prepare_list_write(session, {:delete_starter_pack, uri}) do
    with {:ok, commit} <- latest_commit(session),
         {:ok, current} <- own_value(session, uri, "uri", "starter pack") do
      list = string_value(current, :list)

      # The pack's list and its items are this account's own records unless the
      # pack names a list somewhere else, which this leaves alone.
      list_owned? = own_repo_uri?(session, list)

      with {:ok, items} <- if(list_owned?, do: list_items(session, list, nil), else: {:ok, []}) do
        # Items, then the list, then the pack: a deletion that stops between
        # commits leaves a pack that still names what is left of it, so
        # delete_starter_pack can be asked again.
        deleted = items ++ if(list_owned?, do: [list], else: []) ++ [uri]

        prepared(
          Enum.map(deleted, &removal/1),
          %{action: :delete_starter_pack, uri: uri, list: list, deleted: deleted},
          swap_commit: commit
        )
      end
    end
  end

  def prepare_list_write(session, {:set_list_opt_out, uri, opted_out}) do
    with {:ok, commit} <- latest_commit(session),
         {:ok, list} <- viewed_list(session, uri) do
      list_uri = string_value(list, :uri)
      purpose = string_value(list, :purpose)
      result = %{action: :set_list_opt_out, list: list_uri, opted_out: opted_out}

      if purpose_name(purpose) != "reference" do
        {:error,
         {:invalid_argument, "list",
          "only a starter pack's list can be opted out of; #{list_uri} is a #{purpose_name(purpose)} list"}}
      else
        # The opt-outs are this account's own records, read from its PDS: the
        # AppView's `viewer.referenceListOptOut` can lag a record just written.
        with {:ok, existing} <-
               own_records(session, :list_opt_out, &(string_value(&1, :subject) == list_uri)) do
          swap = [swap_commit: commit]

          case {opted_out, existing} do
            {true, [first | _]} ->
              prepared([], Map.merge(result, %{uri: first, unchanged: true}))

            {true, []} ->
              [rkey] = AtMcp.ATProto.tids(1)
              record = AtMcp.ATProto.list_opt_out_record(subject: list_uri)

              prepared(
                [new_record(:list_opt_out, rkey, record)],
                Map.put(result, :uri, own_uri(session, :list_opt_out, rkey)),
                swap
              )

            {false, []} ->
              prepared([], Map.merge(result, %{uri: nil, unchanged: true}))

            {false, [first | _]} ->
              prepared(
                Enum.map(existing, &removal/1),
                Map.merge(result, %{uri: first, deleted: existing}),
                swap
              )
          end
        end
      end
    end
  end

  # As many whole graphemes of `text` as fit in `bytes`, or, when not even the
  # first grapheme fits (a letter under dozens of combining marks), as many
  # whole codepoints: a name is never cut to nothing, nor inside a character.
  defp fit_bytes(text, bytes) do
    case fit(String.graphemes(text), bytes) do
      "" -> fit(String.codepoints(text), bytes)
      fitted -> fitted
    end
  end

  defp fit(parts, bytes) do
    Enum.reduce_while(parts, "", fn part, kept ->
      if byte_size(kept) + byte_size(part) <= bytes,
        do: {:cont, kept <> part},
        else: {:halt, kept}
    end)
  end

  @impl true
  def write_list(_session, %{writes: [], put: nil, result: result}),
    do: {:ok, Map.put(result, :ok, true)}

  # A record rebuilt from the one read, replaced only if it is still that one.
  def write_list(session, %{put: %{uri: uri, record: record, swap: cid}, result: result}) do
    {:ok, {_repo, collection, rkey}} = AtMcp.ATProto.parse_uri(uri)

    params =
      AtMcp.ATProto.params(%{
        repo: session.did,
        collection: collection,
        rkey: rkey,
        record: record,
        swap_record: cid
      })

    case AtMcp.ATProto.put_record(session, params) do
      {:ok, response} ->
        {:ok, result |> Map.put(:ok, true) |> Map.put(:cid, string_value(response, :cid))}

      {:error, %ProtoRune.XRPC.Error{reason: reason}}
      when reason in [:invalid_swap, "invalid_swap"] ->
        {:error, changed_meanwhile("The record at #{uri}")}

      {:error, reason} ->
        {:error, failure(reason)}
    end
  end

  # One commit, or, for a deletion larger than one commit takes, several in
  # order. The first names the commit the reads began at, and each later one
  # the commit the one before it made, so a change made meanwhile stops the
  # rest. Once one has landed, a later failure leaves part of the deletion
  # done: that is said, with the records the landed commits deleted.
  def write_list(session, %{writes: writes, result: result} = p) do
    batches = Enum.chunk_every(writes, AtMcp.ATProto.max_writes())

    batches
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, [], [], p.swap_commit}, fn {batch, index},
                                                          {:ok, done, gone, commit} ->
      case AtMcp.ATProto.apply_writes(session, session.did, batch, swap_commit: commit) do
        {:ok, response} ->
          {:cont,
           {:ok, done ++ write_results(response), gone ++ deletions(session, batch),
            commit_of(response)}}

        {:error, %ProtoRune.XRPC.Error{reason: reason}}
        when index == 0 and reason in [:invalid_swap, "invalid_swap"] ->
          {:halt, {:error, changed_meanwhile("The account's repository")}}

        {:error, reason} when index == 0 ->
          {:halt, {:error, failure(reason)}}

        {:error, reason} ->
          {:halt, {:error, partially_written(failure(reason), gone, index, length(batches))}}
      end
    end)
    |> case do
      {:ok, results, _gone, _commit} ->
        cid = Enum.find_value(results, &(&1.uri == result[:uri] && &1.cid))
        {:ok, result |> Map.put(:ok, true) |> Map.put(:cid, cid)}

      error ->
        error
    end
  end

  # Part of a deletion landed and the rest did not, or may not have. It is
  # reported as what it is, with the records already deleted and what the
  # service said about the commit that did not land; calling again deletes what
  # is left.
  defp partially_written(upstream, deleted, landed, total) do
    rest =
      if upstream.kind == :indeterminate,
        do: "Whether the next one landed is unknown",
        else: "The next one was refused"

    said = if upstream.message, do: " (#{upstream.message})", else: ""

    AtMcp.Effects.Failure.new(:refused,
      status: upstream.status,
      message:
        "#{landed} of #{total} commits landed, deleting #{Enum.join(deleted, ", ")}. " <>
          "#{rest}#{said}. Call again to delete what is left.",
      detail: {:partially_written, deleted, upstream}
    )
  end

  defp commit_of(response) do
    case AtMcp.Response.dig(response, [:commit, :cid]) do
      cid when is_binary(cid) -> cid
      _ -> nil
    end
  end

  defp prepared(writes, result, swap \\ []),
    do: {:ok, %{writes: writes, put: nil, result: result, swap_commit: swap[:swap_commit]}}

  defp replacement(uri, current, cid, edits, result) do
    {:ok, {_repo, collection, _rkey}} = AtMcp.ATProto.parse_uri(uri)
    record = AtMcp.ATProto.edit_record(current, collection, edits)

    {:ok,
     %{
       writes: [],
       put: %{uri: uri, record: record, swap: cid},
       result: result,
       swap_commit: nil
     }}
  end

  defp deletions(session, batch) do
    for {:delete, collection, rkey} <- batch, do: "at://#{session.did}/#{collection}/#{rkey}"
  end

  defp write_results(response) do
    case AtMcp.Response.fetch(response, :results) do
      {:ok, results} when is_list(results) ->
        for result <- results, is_map(result) do
          %{uri: string_value(result, :uri), cid: string_value(result, :cid)}
        end

      _ ->
        []
    end
  end

  # A changed field: `nil` is unchanged, `""` removes it, anything else is the
  # new value.
  defp edit(edits, _key, nil), do: edits
  defp edit(edits, key, ""), do: Map.put(edits, key, nil)
  defp edit(edits, key, value), do: Map.put(edits, key, value)

  defp own_repo_uri?(session, uri) do
    case is_binary(uri) && AtMcp.ATProto.parse_uri(uri) do
      {:ok, {repo, _, _}} -> repo == session.did
      _ -> false
    end
  end

  defp new_record(kind, rkey, record), do: {:create, AtMcp.Network.collection(kind), rkey, record}

  defp removal(uri) do
    {:ok, {_repo, collection, rkey}} = AtMcp.ATProto.parse_uri(uri)
    {:delete, collection, rkey}
  end

  defp own_uri(session, kind, rkey),
    do: "at://#{session.did}/#{AtMcp.Network.collection(kind)}/#{rkey}"

  defp blank_nil(""), do: nil
  defp blank_nil(value), do: value

  # The record at one of this account's URIs, read before it is changed so
  # every field the change does not name is kept. A record the service will not
  # hand over is not one to edit: the call names the argument and sends nothing.
  defp own_value(session, uri, field, what) do
    with {:ok, value, _cid} <- own_record(session, uri, field, what), do: {:ok, value}
  end

  # The record at one of this account's URIs and its CID, read before it is
  # changed so every field the change does not name is kept, and so the change
  # applies only to the record read. A record the service will not hand over is
  # not one to edit: the call names the argument and sends nothing.
  defp own_record(session, uri, field, what) do
    {:ok, {repo, collection, rkey}} = AtMcp.ATProto.parse_uri(uri)

    case AtMcp.ATProto.get_record(session, %{repo: repo, collection: collection, rkey: rkey}) do
      {:ok, response} ->
        case AtMcp.Response.fetch(response, :value) do
          {:ok, value} when is_map(value) -> {:ok, value, string_value(response, :cid)}
          _ -> {:error, unreadable("a #{what} record", response)}
        end

      {:error, reason} ->
        case failure(reason) do
          %AtMcp.Effects.Failure{kind: :refused} ->
            {:error,
             {:invalid_argument, field, "no #{what} at #{uri} could be read; it may be deleted"}}

          other ->
            {:error, other}
        end
    end
  end

  # The list a membership change applies to: the list itself, or a starter
  # pack's list. Either is read, so a list that is gone is refused here. A
  # pack naming a list in another repository is refused too: the AppView
  # ignores a list item for a list its author does not own.
  defp target_list(session, uri) do
    {:ok, {_repo, collection, _rkey}} = AtMcp.ATProto.parse_uri(uri)

    if AtMcp.Network.collection?(collection, :starter_pack) do
      with {:ok, pack} <- own_value(session, uri, "list", "starter pack") do
        list = string_value(pack, :list)

        cond do
          not is_binary(list) ->
            {:error, unreadable("a starter pack record", pack)}

          not own_repo_uri?(session, list) ->
            {:error,
             {:invalid_argument, "list",
              "the starter pack names the list #{list}, which is in another account's repository"}}

          true ->
            with {:ok, _list} <- own_value(session, list, "list", "list"), do: {:ok, list}
        end
      end
    else
      with {:ok, _list} <- own_value(session, uri, "list", "list"), do: {:ok, uri}
    end
  end

  # A starter pack's list goes with its pack.
  defp not_pack_list(list) do
    if purpose_name(string_value(list, :purpose)) == "reference",
      do:
        {:error,
         {:invalid_argument, "uri",
          "this is a starter pack's list; delete_starter_pack deletes the pack and its list together"}},
      else: :ok
  end

  # The list items in this account's repository that put `subject` (any
  # account, when nil) on `list`.
  defp list_items(session, list, subject) do
    own_records(session, :list_item, fn value ->
      string_value(value, :list) == list and
        (is_nil(subject) or string_value(value, :subject) == subject)
    end)
  end

  # How many pages of one collection a write reads to find the records it
  # changes: 100 records a page, so 10,000. One past that is refused rather
  # than read without end.
  @own_record_pages 100

  # The AT URIs of this account's records of `kind` whose value `keep?` accepts,
  # read from its PDS, so a record the AppView has not indexed yet is found too.
  defp own_records(session, kind, keep?),
    do: own_records(session, kind, keep?, nil, @own_record_pages, [])

  defp own_records(_session, kind, _keep?, _cursor, 0, _found) do
    {:error,
     AtMcp.Effects.Failure.new(:refused,
       message:
         "This account has more than #{@own_record_pages * 100} #{AtMcp.Network.collection(kind)} records, more than AtMcp reads to find the ones to change. Nothing was sent."
     )}
  end

  defp own_records(session, kind, keep?, cursor, pages, found) do
    params =
      AtMcp.ATProto.params(%{
        repo: session.did,
        collection: AtMcp.Network.collection(kind),
        limit: 100,
        cursor: cursor
      })

    with {:ok, response} <- AtMcp.ATProto.list_records(session, params),
         {:ok, records} when is_list(records) <- AtMcp.Response.fetch(response, :records) do
      matching =
        for record <- records,
            value = field(record, :value),
            is_map(value),
            keep?.(value),
            uri = string_value(record, :uri),
            do: uri

      case cursor_of(response) do
        next when is_binary(next) and records != [] ->
          own_records(session, kind, keep?, next, pages - 1, found ++ matching)

        _ ->
          {:ok, found ++ matching}
      end
    else
      {:error, reason} -> {:error, failure(reason)}
      _ -> {:error, unreadable("a page of records", %{})}
    end
  end

  # The view of a list or of a starter pack's list, which says its purpose and
  # its URI in DID form.
  defp viewed_list(session, uri) do
    {:ok, {_repo, collection, _rkey}} = AtMcp.ATProto.parse_uri(uri)

    {response, key} =
      if AtMcp.Network.collection?(collection, :starter_pack),
        do:
          {AtMcp.ATProto.get_starter_pack(session, %{starterPack: uri}), [:starter_pack, :list]},
        else: {AtMcp.ATProto.get_list(session, %{list: uri, limit: 1}), [:list]}

    case response do
      {:ok, body} ->
        case AtMcp.Response.dig(body, key) do
          list when is_map(list) -> {:ok, list}
          _ -> {:error, unreadable("a list", body)}
        end

      {:error, reason} ->
        case failure(reason) do
          %AtMcp.Effects.Failure{kind: :refused} ->
            {:error,
             {:invalid_argument, "list", "no starter pack or list at #{uri} could be read"}}

          other ->
            {:error, other}
        end
    end
  end

  # An avatar is a blob the list record references, uploaded before the record
  # is built, as a post's images are. A failed upload sends no record.
  defp upload_avatar(_session, nil), do: {:ok, nil}

  defp upload_avatar(session, image) do
    case upload_images(session, [image]) do
      {:ok, [%{blob: blob}]} ->
        {:ok, blob}

      {:error, reason} ->
        case failure(reason) do
          %AtMcp.Effects.Failure{kind: :auth_refused} = refused ->
            {:error, refused}

          other ->
            {:error,
             %{
               other
               | kind: :refused,
                 message:
                   "The avatar could not be uploaded (#{other.message || "no answer"}). Nothing was written."
             }}
        end
    end
  end

  # A list's purpose in the words the list tools take: a token's name on any
  # network, or the value as sent when this version does not know it.
  defp purpose_name(token) when is_atom(token) and not is_nil(token),
    do: purpose_name(Atom.to_string(token))

  defp purpose_name(token) when is_binary(token) do
    case token |> String.split("#") |> List.last() do
      "curatelist" -> "curate"
      "modlist" -> "moderation"
      "referencelist" -> "reference"
      _ -> token
    end
  end

  defp purpose_name(other), do: other

  defp list_view(list) when is_map(list) do
    summary = AtMcp.Summary.extract(:list, list)
    %{summary | purpose: purpose_name(summary.purpose)}
  end

  defp list_view(other), do: %{value: to_string_safe(other)}

  defp list_member(item), do: AtMcp.Summary.extract(:list_member, item)

  defp pack_view(pack), do: AtMcp.Summary.extract(:starter_pack, pack)

  defp string_value(map, key) do
    case field(map, key) do
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  @doc """
  Publish a post. `opts` carries what a post can hold beyond its text:
  `:reply` (a parent AT URI), `:images`, `:quote` and `:langs`.

  `:images` entries are `%{data: binary, mime_type: String.t(), alt: String.t()}`;
  each is uploaded as a blob before the record is built, because the record
  references a blob rather than carrying one. A quote is an AT URI, whose CID
  is read from the record it names — a strong reference has to be strong, and
  the caller has only the URI.
  """
  @impl true
  def prepare_post(session, text, opts) do
    with :ok <- validate_post_languages(opts),
         {rich_text, unresolved} = AtMcp.RichText.build(text, session),
         {:ok, opts} <- resolve_references(session, opts),
         {:ok, opts} <- resolve_reply_lists(session, opts),
         {:ok, images} <- upload_images(session, Keyword.get(opts, :images)),
         {:ok, link} <- upload_link_thumb(session, Keyword.get(opts, :link)) do
      record =
        AtMcp.ATProto.post_record(
          text: rich_text.text,
          facets: rich_text.facets,
          langs: Keyword.get(opts, :langs),
          reply: Keyword.get(opts, :reply_ref),
          images: images,
          link: link,
          quote: Keyword.get(opts, :quote_ref),
          labels: Keyword.get(opts, :labels)
        )

      {rkey, gates} = post_gates(session, record, opts)

      {:ok,
       %{
         record: record,
         unresolved: unresolved,
         reply: Keyword.get(opts, :reply),
         rkey: rkey,
         gates: gates
       }}
    else
      {:error, {:referenced_record_unreadable, _uri}} = error -> error
      {:error, {:reply_disabled, _uri}} = error -> error
      {:error, reason} -> {:error, failure(reason)}
    end
  rescue
    error ->
      {:error,
       AtMcp.Effects.Failure.new(:refused,
         message: "The post could not be prepared. No post was sent.",
         detail: error
       )}
  end

  # This is a targeted lexicon-derived check, not full record validation.
  # proto_rune 0.5.3's generator drops array bounds, emits unresolved refs that
  # Peri rejects, and expects DateTime structs where records carry ISO strings.
  # Peri also projects away undeclared fields. Keep the original record intact;
  # retire this check only when schema validation preserves it and these bounds.
  # Run before reference reads or blob uploads, as well as quota and dispatch.
  defp validate_post_languages(opts) do
    langs = Keyword.get(opts, :langs)
    maximum = AtMcp.Network.post_language_limit()

    if is_list(langs) and length(langs) > maximum do
      {:error,
       AtMcp.Effects.Failure.new(:refused,
         message: "A post can have at most #{maximum} language tags. No post was sent."
       )}
    else
      :ok
    end
  end

  # The direct backend API and Effects use the same preparation path. Effects
  # calls it before reserving quota; this convenience entry point has no quota.
  def post(session, text, opts \\ [])

  def post(session, text, opts) when is_binary(text) and is_list(opts) do
    with {:ok, prepared} <- prepare_post(session, text, opts),
         do: post(session, text, prepared)
  end

  # A post with a reply or quote rule is written with its gates in one
  # commit: the post never exists without them, so nobody can reply or quote
  # in between, and a failure leaves neither.
  @impl true
  def post(session, text, %{record: record, rkey: rkey, gates: [_ | _] = gates} = prepared) do
    post = AtMcp.Network.collection(:post)

    writes =
      [{:create, post, rkey, record}] ++
        Enum.map(gates, fn {kind, gate} ->
          {:create, AtMcp.Network.collection(kind), rkey, gate}
        end)

    case AtMcp.ATProto.apply_writes(session, session.did, writes) do
      {:ok, response} ->
        # A successful applyWrites committed every write, and `results` is
        # optional in its output: the post's address is known before sending
        # (this account's DID and the record key chosen here), so a service
        # that leaves results out still says what was written. Only the CID
        # then comes back as nil.
        written =
          case field(response, :results) do
            [first | _] when is_map(first) -> first
            _ -> %{}
          end

        summary =
          written
          |> summarize_write(text)
          |> Map.update!(:uri, &(&1 || "at://#{session.did}/#{post}/#{rkey}"))
          |> Map.merge(
            Map.new(gates, fn {kind, _} ->
              {:"#{kind}_uri", "at://#{session.did}/#{AtMcp.Network.collection(kind)}/#{rkey}"}
            end)
          )

        summary =
          if prepared.reply, do: Map.put(summary, :reply_to, prepared.reply), else: summary

        {:ok, mention_warnings(summary, prepared.unresolved)}

      {:error, reason} ->
        {:error, failure(reason)}
    end
  end

  def post(session, text, %{record: record, unresolved: unresolved, reply: reply}) do
    case create(session, :post, record) do
      {:ok, result} ->
        summary = summarize_write(result, text)
        summary = if reply, do: Map.put(summary, :reply_to, reply), else: summary
        {:ok, mention_warnings(summary, unresolved)}

      {:error, reason} ->
        {:error, failure(reason)}
    end
  end

  @impl true
  def like(session, uri, cid) when is_binary(uri) and is_binary(cid) do
    case create(session, :like, AtMcp.ATProto.like_record(subject: %{uri: uri, cid: cid})) do
      {:ok, result} ->
        {:ok,
         Map.merge(summarize_record(result), %{subject_uri: uri, subject_cid: cid, action: :like})}

      {:error, reason} ->
        {:error, failure(reason)}
    end
  end

  @impl true
  def repost(session, uri, cid) when is_binary(uri) and is_binary(cid) do
    case create(session, :repost, AtMcp.ATProto.repost_record(subject: %{uri: uri, cid: cid})) do
      {:ok, result} ->
        {:ok,
         Map.merge(summarize_record(result), %{
           subject_uri: uri,
           subject_cid: cid,
           action: :repost
         })}

      {:error, reason} ->
        {:error, failure(reason)}
    end
  end

  @impl true
  def follow(session, "did:" <> _ = did) do
    case create(session, :follow, AtMcp.ATProto.follow_record(subject: did)) do
      {:ok, result} -> {:ok, Map.merge(summarize_record(result), %{actor: did, action: :follow})}
      {:error, reason} -> {:error, failure(reason)}
    end
  end

  @impl true
  def block(session, "did:" <> _ = did) do
    case create(session, :block, AtMcp.ATProto.block_record(subject: did)) do
      {:ok, result} -> {:ok, Map.merge(summarize_record(result), %{actor: did, action: :block})}
      {:error, reason} -> {:error, failure(reason)}
    end
  end

  @impl true
  def viewer_record(session, action, subject) when action in [:like, :repost] do
    {:ok, {_repo, collection, _rkey}} = AtMcp.ATProto.parse_uri(subject)

    {read, key} =
      cond do
        AtMcp.Network.collection?(collection, :generator) ->
          {AtMcp.ATProto.get_feed_generators(session, [subject]), :feeds}

        AtMcp.Network.collection?(collection, :labeler) ->
          {:ok, {did, _, _}} = AtMcp.ATProto.parse_uri(subject)
          {AtMcp.ATProto.get_services(session, [did]), :views}

        true ->
          {AtMcp.ATProto.get_posts(session, [subject]), :posts}
      end

    with {:ok, uri} <- viewer_field(read, key, action),
         do: confirmed(session, uri, subject)
  end

  def viewer_record(session, action, did) when action in [:follow, :block] do
    read = AtMcp.ATProto.get_profile(session, %{actor: did})

    with {:ok, uri} <-
           viewer_field(read, nil, if(action == :follow, do: :following, else: :blocking)),
         do: confirmed(session, uri, did)
  end

  # The viewer's record in the view a read returned: the response itself, or
  # the first of its `key` list. A subject the AppView does not have (no view,
  # or for a profile its "Profile not found") has no record there to find.
  # Any other failure, a rate limit included, is the read's, and nothing was
  # sent.
  defp viewer_field({:ok, response}, key, field) do
    view =
      cond do
        is_nil(key) -> response
        match?([_ | _], field(response, key)) -> hd(field(response, key))
        true -> %{}
      end

    case AtMcp.Response.dig(view, [:viewer, field]) do
      uri when is_binary(uri) -> {:ok, uri}
      _ -> {:ok, nil}
    end
  end

  defp viewer_field(
         {:error, %ProtoRune.XRPC.Error{reason: reason, message: "Profile not found"}},
         nil,
         _field
       )
       when reason in [:invalid_request, "invalid_request"],
       do: {:ok, nil}

  defp viewer_field({:error, reason}, _key, _field), do: {:error, failure(reason)}

  # The AppView's viewer state can be behind the repository: a record deleted
  # moments ago can still be named. So a record it names counts only once this
  # account's PDS still holds it, with this subject.
  defp confirmed(_session, nil, _subject), do: {:ok, nil}

  defp confirmed(session, uri, subject) do
    with {:ok, {repo, collection, rkey}} <- AtMcp.ATProto.parse_uri(uri),
         true <- AtMcp.Interactions.own_repo?(session, repo) do
      case AtMcp.ATProto.get_record(session, %{repo: repo, collection: collection, rkey: rkey}) do
        {:ok, response} ->
          if undo_subject(field(response, :value)) == subject, do: {:ok, uri}, else: {:ok, nil}

        {:error, %ProtoRune.XRPC.Error{reason: reason}}
        when reason in [:record_not_found, "record_not_found"] ->
          {:ok, nil}

        {:error, reason} ->
          {:error, failure(reason)}
      end
    else
      _ -> {:ok, nil}
    end
  end

  @undo_kinds %{unlike: :like, unrepost: :repost, unfollow: :follow, unblock: :block}

  @impl true
  def prepare_undo(session, action, uri) do
    kind = Map.fetch!(@undo_kinds, action)

    with {:ok, {repo, collection, rkey}} <- AtMcp.ATProto.parse_uri(uri),
         :ok <- require_record_kind(collection, kind, action),
         {:ok, deleted} <- undo_records(session, kind, repo, collection, rkey, uri) do
      prepared = %{action: action, uri: uri, deleted: deleted}

      if deleted == [],
        do: {:ok, {:unchanged, undo_summary(Map.put(prepared, :unchanged, true))}},
        else: {:ok, prepared}
    else
      {:error, reason} -> {:error, failure(reason)}
    end
  end

  # The record named, read for its subject, and the record the AppView's
  # viewer state names for that subject when it is another one, confirmed as
  # `viewer_record/3` confirms it. That second one is what a retried like,
  # repost, follow or block leaves behind. A record that is not there has
  # nothing to delete; one in another repository is deleted alone, for its
  # service to refuse.
  defp undo_records(session, kind, repo, collection, rkey, uri) do
    case AtMcp.ATProto.get_record(session, %{repo: repo, collection: collection, rkey: rkey}) do
      {:ok, response} ->
        subject = undo_subject(field(response, :value))
        own = "at://#{session.did}/#{collection}/#{rkey}"

        if is_binary(subject) and AtMcp.Interactions.own_repo?(session, repo) do
          case viewer_record(session, kind, subject) do
            {:ok, other} when is_binary(other) and other != own -> {:ok, [uri, other]}
            {:ok, _} -> {:ok, [uri]}
            error -> error
          end
        else
          {:ok, [uri]}
        end

      {:error, %ProtoRune.XRPC.Error{reason: reason}}
      when reason in [:record_not_found, "record_not_found"] ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # A like's or repost's subject is a strong reference; a follow's or block's
  # is a DID.
  defp undo_subject(value) do
    case field(value, :subject) do
      subject when is_binary(subject) -> subject
      subject when is_map(subject) -> string_value(subject, :uri)
      _ -> nil
    end
  end

  # One record is deleted as it is named; two are deleted together, in one
  # commit of this account's repository.
  @impl true
  def undo(session, %{deleted: [uri]} = prepared) do
    with {:ok, %{ok: true}} <- delete(session, uri, prepared.action, @undo_kinds[prepared.action]),
         do: {:ok, undo_summary(prepared)}
  end

  def undo(session, %{deleted: deleted} = prepared) do
    case AtMcp.ATProto.apply_writes(session, session.did, Enum.map(deleted, &removal/1)) do
      {:ok, _} ->
        {:ok, undo_summary(prepared)}

      # A record read a moment ago and gone by the commit: the commit applies
      # all of its writes or none.
      {:error, %ProtoRune.XRPC.Error{reason: reason} = error}
      when reason in [:record_not_found, "record_not_found"] ->
        {:error,
         AtMcp.Effects.Failure.new(:refused,
           status: error.http_status,
           message:
             "#{error.message}. One of #{Enum.join(deleted, ", ")} was gone before the deletion; nothing was applied.",
           detail: reason
         )}

      {:error, reason} ->
        {:error, failure(reason)}
    end
  end

  # A record that was not there says nothing about other records of its
  # subject, so the result says so.
  defp undo_summary(%{unchanged: true} = prepared) do
    %{
      ok: true,
      uri: prepared.uri,
      action: prepared.action,
      deleted: [],
      unchanged: true,
      note:
        "There is no record at #{prepared.uri}, so nothing was deleted. This says nothing about other records of the same subject."
    }
  end

  defp undo_summary(prepared),
    do: %{ok: true, uri: prepared.uri, action: prepared.action, deleted: prepared.deleted}

  # A mute is server-side state rather than a record, so it is a method call
  # and not a write to the repository.
  @impl true
  def mute(session, "did:" <> _ = did) do
    case AtMcp.ATProto.mute_actor(session, %{actor: did}) do
      {:ok, _} -> {:ok, %{ok: true, actor: did, action: :mute}}
      {:error, reason} -> {:error, failure(reason)}
    end
  end

  @impl true
  def unmute(session, "did:" <> _ = did) do
    case AtMcp.ATProto.unmute_actor(session, %{actor: did}) do
      {:ok, _} -> {:ok, %{ok: true, actor: did, action: :unmute}}
      {:error, reason} -> {:error, failure(reason)}
    end
  end

  @impl true
  def delete_post(session, post_uri) when is_binary(post_uri),
    do: delete(session, post_uri, :delete_post, :post)

  @impl true
  def update_profile(session, updates) when is_list(updates) do
    safe = Keyword.take(updates, [:display_name, :description, :pronouns, :website])

    with {:ok, current, swap} <- current_profile(session),
         {:ok, plan} <- links_plan(session, current, Keyword.fetch(updates, :links)),
         {:ok, blobs} <- upload_profile_images(session, updates),
         {:ok, links} <- create_links(session, plan),
         record =
           current
           |> merge_profile(safe)
           |> with_links(links)
           |> AtMcp.ATProto.profile_record(blobs),
         {:ok, result} <- put_profile_with_links(session, record, swap, links) do
      {:ok,
       %{
         ok: true,
         action: :update_profile,
         display_name: Keyword.get(safe, :display_name),
         description: Keyword.get(safe, :description),
         pronouns: Keyword.get(safe, :pronouns),
         website: Keyword.get(safe, :website),
         uri: Map.get(result, :uri) || Map.get(result, "uri")
       }
       |> Map.merge(Map.new(blobs, fn {key, blob} -> {:"#{key}_cid", blob_cid(blob)} end))
       |> Map.merge(links_result(session, links))}
    else
      {:error, reason} -> {:error, failure(reason)}
    end
  end

  # The profile's links are `actor.link` records in this repository, which the
  # profile's `links` names in order by strong reference. As the app does, a
  # link given exactly as one the profile shows (same url and title) keeps its
  # record; any other is a new record, written before the profile so the
  # profile can name its CID; and the records the profile stops naming are
  # deleted after it is written.
  defp links_plan(_session, _current, :error), do: {:ok, nil}

  defp links_plan(session, current, {:ok, wanted}) do
    with {:ok, existing} <- current_links(session, current) do
      # One batch of keys, distinct by construction: keys drawn one at a time
      # in the same microsecond share their clock id one time in 1,024.
      {plan, {unused, _keys}} =
        Enum.map_reduce(wanted, {existing, AtMcp.ATProto.tids(length(wanted))}, fn
          link, {available, [key | keys]} ->
            title = blank_nil(Map.get(link, :title))

            case Enum.split_with(available, &(&1.url == link.url and &1.title == title)) do
              {[same | others], rest} ->
                {{:keep, same}, {others ++ rest, keys}}

              {[], _} ->
                record = AtMcp.ATProto.link_record(%{url: link.url, title: title})
                {{:create, key, record}, {available, keys}}
            end
        end)

      {:ok,
       %{
         plan: plan,
         removed: Enum.map(unused, & &1.uri),
         previous: Enum.map(existing, &Map.take(&1, [:uri, :url, :title]))
       }}
    end
  end

  # The links the profile names now, each read from its record. A record the
  # profile names that is gone, or in another repository, is not one of them.
  defp current_links(session, current) do
    refs = AtMcp.Response.dig(current, [:links])
    refs = if is_list(refs), do: refs, else: []

    Enum.reduce_while(refs, {:ok, []}, fn ref, {:ok, acc} ->
      with uri when is_binary(uri) <- field(ref, :uri),
           {:ok, {repo, collection, rkey}} <- AtMcp.ATProto.parse_uri(uri),
           true <- repo == session.did and AtMcp.Network.collection?(collection, :link) do
        case AtMcp.ATProto.get_record(session, %{repo: repo, collection: collection, rkey: rkey}) do
          {:ok, response} ->
            value = field(response, :value) || %{}

            link = %{
              uri: uri,
              cid: field(response, :cid),
              url: field(value, :url),
              title: field(value, :title)
            }

            {:cont, {:ok, acc ++ [link]}}

          {:error, %ProtoRune.XRPC.Error{reason: reason}}
          when reason in [:not_found, :record_not_found] ->
            {:cont, {:ok, acc}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      else
        _ -> {:cont, {:ok, acc}}
      end
    end)
  end

  defp create_links(_session, nil), do: {:ok, nil}

  defp create_links(session, %{plan: plan} = links) do
    creates =
      for {:create, rkey, record} <- plan,
          do: {:create, AtMcp.Network.collection(:link), rkey, record}

    created =
      if creates == [],
        do: {:ok, %{}},
        else: AtMcp.ATProto.apply_writes(session, session.did, creates)

    with {:ok, response} <- created do
      results = if creates == [], do: [], else: write_results(response)
      by_rkey = Map.new(Enum.zip(for({:create, rkey, _} <- plan, do: rkey), results))

      refs =
        for step <- plan do
          case step do
            {:keep, link} ->
              link

            {:create, rkey, record} ->
              result = Map.get(by_rkey, rkey, %{})

              %{
                uri: result[:uri] || own_uri(session, :link, rkey),
                cid: result[:cid],
                url: record["url"],
                title: record["title"],
                created: true
              }
          end
        end

      if Enum.any?(refs, &is_nil(&1.cid)),
        do: {:error, unreadable("the link records written", response)},
        else: {:ok, Map.put(links, :refs, refs)}
    end
  end

  defp with_links(record, nil), do: record

  defp with_links(record, %{refs: refs}) do
    record = Map.drop(record, ["links", :links])

    case refs do
      [] -> record
      refs -> Map.put(record, "links", Enum.map(refs, &%{"uri" => &1.uri, "cid" => &1.cid}))
    end
  end

  # With links, the new link records were written first. A profile write the
  # service refused leaves them named by nothing, so they are deleted again
  # and the refusal stays true: the account is as it was.
  defp put_profile_with_links(session, record, swap, nil), do: put_profile(session, record, swap)

  defp put_profile_with_links(session, record, swap, %{refs: refs} = links) do
    case put_profile(session, record, swap) do
      {:ok, _} = ok ->
        ok

      {:error, reason} = error ->
        created = for %{created: true} = link <- refs, do: link.uri
        failure = failure(reason)

        cond do
          created == [] ->
            error

          # The service did not apply the profile, so the new records are
          # named by nothing; they are deleted again and the refusal stays
          # true. A refused credential is retried whole after the session is
          # recovered, which writes the links again: the first set is deleted
          # now, or, if that fails too, the error stops being a credential
          # refusal, so no second set is written over a first left behind.
          failure.kind in [:refused, :auth_refused] ->
            cleanup(session, created, error)

          # The profile may or may not have been written, so neither set of
          # records can be tidied: the error names both.
          true ->
            {:error, %{failure | detail: {:profile_links, created, links.removed}}}
        end
    end
  end

  defp cleanup(session, created, error) do
    deletes =
      for uri <- created do
        {:ok, {_repo, collection, rkey}} = AtMcp.ATProto.parse_uri(uri)
        {:delete, collection, rkey}
      end

    case AtMcp.ATProto.apply_writes(session, session.did, deletes) do
      {:ok, _} ->
        error

      {:error, _} ->
        {:error,
         AtMcp.Effects.Failure.new(:refused,
           message:
             "The profile was not changed: the service refused it (#{inspect_reason(error)}). " <>
               "The link records written for it could not be deleted again; nothing shows them: " <>
               Enum.join(created, ", "),
           detail: {:links_left, created}
         )}
    end
  end

  defp inspect_reason({:error, reason}) do
    case failure(reason) do
      %{message: message} when is_binary(message) -> message
      _ -> "no reason given"
    end
  end

  # What the profile now shows, what it showed before, and the records the
  # change removed. The removed records are deleted after the profile is
  # written; one that could not be is named in `left_behind`. Nothing shows it.
  defp links_result(_session, nil), do: %{}

  defp links_result(session, %{refs: refs, removed: removed, previous: previous}) do
    left_behind =
      case removed do
        [] ->
          []

        uris ->
          deletes =
            for uri <- uris do
              {:ok, {_repo, collection, rkey}} = AtMcp.ATProto.parse_uri(uri)
              {:delete, collection, rkey}
            end

          case AtMcp.ATProto.apply_writes(session, session.did, deletes) do
            {:ok, _} -> []
            {:error, _} -> uris
          end
      end

    %{
      links: Enum.map(refs, &Map.take(&1, [:uri, :url, :title])),
      replaced_links: Enum.map(previous, &Map.take(&1, [:url, :title])),
      removed: removed -- left_behind,
      left_behind: left_behind
    }
  end

  # The profile is written only over the record it was built from. Between the
  # read and this write the app, or another client, may have changed it; a
  # write over that change would undo it without anyone seeing. `swapRecord`
  # makes the service refuse instead. With no record read, nothing is swapped:
  # the lexicon's null swap would also refuse a profile created meanwhile, but
  # it is "nullable and optional" and not every PDS reads it the same way.
  defp put_profile(session, record, swap) do
    params = %{
      repo: session.did,
      collection: AtMcp.Network.collection(:profile),
      rkey: "self",
      record: record
    }

    params = if swap, do: Map.put(params, :swap_record, swap), else: params

    case AtMcp.ATProto.put_record(session, params) do
      {:error, %ProtoRune.XRPC.Error{reason: reason}}
      when reason in [:invalid_swap, "invalid_swap"] ->
        {:error, changed_meanwhile("The profile")}

      other ->
        other
    end
  end

  # A compare-and-swap the service refused: the record changed between the
  # read and the write, and the write did not happen.
  defp changed_meanwhile(what) do
    AtMcp.Effects.Failure.new(:refused,
      message:
        "#{what} changed between reading it and writing it, so nothing was written. " <>
          "Read it again and retry if the change still applies.",
      detail: {:changed_meanwhile, what}
    )
  end

  # An avatar or banner is a blob the profile record references, so it is
  # uploaded first, as a post's images are. A failed upload leaves the profile
  # record unwritten.
  defp upload_profile_images(session, updates) do
    Enum.reduce_while([:avatar, :banner], {:ok, %{}}, fn key, {:ok, blobs} ->
      case Keyword.get(updates, key) do
        nil ->
          {:cont, {:ok, blobs}}

        image ->
          case upload_images(session, [image]) do
            {:ok, [%{blob: blob}]} -> {:cont, {:ok, Map.put(blobs, key, blob)}}
            {:error, reason} -> {:halt, {:error, upload_refused(failure(reason), key)}}
          end
      end
    end)
  end

  # Whatever became of the upload, the profile record was never sent, so the
  # update is refused rather than of unknown outcome. A refused credential
  # keeps its kind, so the account recovers its session and retries once.
  defp upload_refused(%AtMcp.Effects.Failure{kind: :auth_refused} = failure, _key), do: failure

  defp upload_refused(%AtMcp.Effects.Failure{} = failure, key) do
    %{
      failure
      | kind: :refused,
        message:
          "The #{key} could not be uploaded (#{failure.message || "no answer"}). The profile was not changed."
    }
  end

  defp blob_cid(blob) do
    with {:ok, ref} when is_map(ref) <- AtMcp.Response.fetch(blob, :ref),
         {:ok, cid} when is_binary(cid) <- AtMcp.Response.fetch(ref, :"$link") do
      cid
    else
      _ -> nil
    end
  end

  # --- saved feeds ---

  @doc """
  Read the account's preferences and build them with one feed saved,
  re-pinned or removed, keeping every other preference as stored. This
  follows the app's own library (`updateSavedFeedsV2Preferences` in
  packages/api/src/agent.ts): saved feeds are `savedFeedsPrefV2`, pinned ones
  first; an account with none yet starts from its first-version
  `savedFeedsPref`, or from the Following timeline alone, as the app would
  start it; and a first-version preference is kept in step by adding to it.
  """
  @impl true
  def prepare_saved_feed(session, {verb, uri, pinned}) do
    case AtMcp.ATProto.preferences_as_stored(session) do
      {:ok, preferences} -> {:ok, saved_feeds(preferences, verb, uri, pinned)}
      {:error, :unreadable_preferences} -> {:error, unreadable("the account's preferences", %{})}
      {:error, reason} -> {:error, failure(reason)}
    end
  end

  @no_swap "Preferences are written whole and the service offers no compare-and-swap for them: a change another client made between this read and this write is lost."

  defp saved_feeds(preferences, verb, uri, pinned) do
    v2_type = AtMcp.Network.type(:saved_feeds_v2)
    current = preferences |> Enum.reverse() |> Enum.find(&saved_v2?/1)
    items = if current, do: current["items"], else: migrated(preferences)
    matching = Enum.filter(items, &(&1["value"] == uri))

    # `pinned` nil keeps a saved feed as it is, and saves a new one unpinned.
    {items, unchanged?, now_pinned} =
      case {verb, matching} do
        {:save_feed, []} ->
          item = %{
            "id" => nil,
            "type" => feed_type(uri),
            "value" => uri,
            "pinned" => pinned == true
          }

          {items ++ [item], false, pinned == true}

        {:save_feed, [first | _] = found} ->
          if is_nil(pinned) or Enum.all?(found, &(&1["pinned"] == pinned)),
            do: {items, true, if(is_nil(pinned), do: first["pinned"] == true, else: pinned)},
            else:
              {Enum.map(
                 items,
                 &if(&1["value"] == uri, do: Map.put(&1, "pinned", pinned), else: &1)
               ), false, pinned}

        {:unsave_feed, []} ->
          {items, true, nil}

        {:unsave_feed, _found} ->
          {Enum.reject(items, &(&1["value"] == uri)), false, nil}
      end

    result = %{
      ok: true,
      action: verb,
      uri: uri,
      pinned: now_pinned,
      unchanged: unchanged?,
      note: if(not unchanged?, do: @no_swap)
    }

    if unchanged? do
      %{preferences: nil, result: result}
    else
      # Pinned first, each group in its order, as the app keeps them.
      {pinned_items, saved_items} = Enum.split_with(items, &(&1["pinned"] == true))
      items = with_ids(pinned_items ++ saved_items)
      v2 = Map.put(current || %{"$type" => v2_type}, "items", items)

      updated =
        preferences
        |> Enum.reject(&(is_map(&1) and &1["$type"] == v2_type))
        |> Kernel.++([v2])
        |> with_first_version(v2["items"])

      %{preferences: updated, result: result}
    end
  end

  # New items are built without an id and given theirs here, in one batch,
  # which makes them distinct: ids drawn one at a time in the same
  # microsecond share their clock id one time in 1,024.
  defp with_ids(items) do
    {items, []} =
      Enum.map_reduce(items, AtMcp.ATProto.tids(Enum.count(items, &is_nil(&1["id"]))), fn
        %{"id" => nil} = item, [id | ids] -> {Map.put(item, "id", id), ids}
        item, ids -> {item, ids}
      end)

    items
  end

  defp saved_v2?(%{"$type" => type, "items" => items}) when is_list(items),
    do: type == AtMcp.Network.type(:saved_feeds_v2)

  defp saved_v2?(_preference), do: false

  defp saved_v1?(%{"$type" => type, "saved" => saved, "pinned" => pinned})
       when is_list(saved) and is_list(pinned),
       do: type == AtMcp.Network.type(:saved_feeds)

  defp saved_v1?(_preference), do: false

  defp feed_type(uri) do
    {:ok, {_repo, collection, _rkey}} = AtMcp.ATProto.parse_uri(uri)
    if AtMcp.Network.collection?(collection, :list), do: "list", else: "feed"
  end

  defp known_feed?(uri) do
    case AtMcp.ATProto.parse_uri(uri) do
      {:ok, {_repo, collection, _rkey}} ->
        AtMcp.Network.collection?(collection, :generator) or
          AtMcp.Network.collection?(collection, :list)

      _ ->
        false
    end
  end

  # The saved feeds of an account that has no `savedFeedsPrefV2` yet: the
  # Following timeline first, then its first-version pinned feeds, then the
  # rest it saved, each once.
  defp migrated(preferences) do
    timeline = %{
      "id" => nil,
      "type" => "timeline",
      "value" => "following",
      "pinned" => true
    }

    case preferences |> Enum.reverse() |> Enum.find(&saved_v1?/1) do
      nil ->
        [timeline]

      %{"saved" => saved, "pinned" => pinned} ->
        pinned = for uri <- Enum.uniq(pinned), known_feed?(uri), do: {uri, true}

        saved =
          for uri <- Enum.uniq(saved),
              known_feed?(uri),
              uri not in Enum.map(pinned, &elem(&1, 0)),
              do: {uri, false}

        [timeline] ++
          for {uri, pin} <- pinned ++ saved do
            %{
              "id" => nil,
              "type" => feed_type(uri),
              "value" => uri,
              "pinned" => pin
            }
          end
    end
  end

  # An account that still has a first-version `savedFeedsPref` gets the saved
  # feeds added to it too, as the app's library double-writes during the
  # transition; nothing is removed from it.
  defp with_first_version(preferences, items) do
    v1_type = AtMcp.Network.type(:saved_feeds)

    case preferences |> Enum.reverse() |> Enum.find(&saved_v1?/1) do
      nil ->
        preferences

      v1 ->
        feeds = Enum.filter(items, &(&1["type"] in ["feed", "list"]))

        v1 = %{
          v1
          | "saved" => Enum.uniq(v1["saved"] ++ Enum.map(feeds, & &1["value"])),
            "pinned" =>
              Enum.uniq(v1["pinned"] ++ for(%{"pinned" => true, "value" => v} <- feeds, do: v))
        }

        Enum.reject(preferences, &(is_map(&1) and &1["$type"] == v1_type)) ++ [v1]
    end
  end

  @impl true
  def write_preferences(_session, %{preferences: nil, result: result}), do: {:ok, result}

  def write_preferences(session, %{preferences: preferences, result: result}) do
    case AtMcp.ATProto.put_preferences_as_stored(session, preferences) do
      {:ok, _} -> {:ok, result}
      {:error, reason} -> {:error, failure(reason)}
    end
  end

  # --- live status ---

  @doc """
  Read the account's status record, and build what replaces it: a live
  status, or none (`:clear`).
  """
  @impl true
  def prepare_status(session, request) do
    case AtMcp.ATProto.get_record(session, %{
           repo: session.did,
           collection: AtMcp.Network.collection(:status),
           rkey: "self"
         }) do
      {:ok, response} ->
        {:ok, status_plan(session, request, field(response, :value), field(response, :cid))}

      {:error, %ProtoRune.XRPC.Error{reason: reason}}
      when reason in [:not_found, :record_not_found] ->
        {:ok, status_plan(session, request, nil, nil)}

      {:error, reason} ->
        {:error, failure(reason)}
    end
  end

  defp status_plan(session, request, current, cid) do
    previous =
      if is_map(current) do
        %{
          url: AtMcp.Response.dig(current, [:embed, :external, :uri]),
          duration_minutes: field(current, :duration_minutes),
          created_at: field(current, :created_at)
        }
      end

    record =
      case request do
        :clear -> nil
        {:live, fields} -> AtMcp.ATProto.status_record(fields)
      end

    %{
      uri: own_uri(session, :status, "self"),
      record: record,
      swap: cid,
      previous: previous,
      exists: not is_nil(cid) or is_map(current)
    }
  end

  @impl true
  def write_status(_session, %{record: nil, exists: false} = plan),
    do: {:ok, status_result(plan, :clear, true)}

  # Cleared only if it is still the status read, as a new one is written only
  # over it: a status set meanwhile by another client is not deleted unseen.
  def write_status(session, %{record: nil, swap: swap} = plan) do
    params = %{
      repo: session.did,
      collection: AtMcp.Network.collection(:status),
      rkey: "self"
    }

    params = if swap, do: Map.put(params, :swap_record, swap), else: params

    case AtMcp.ATProto.delete_record(session, params) do
      {:ok, _} ->
        {:ok, status_result(plan, :clear, false)}

      {:error, %ProtoRune.XRPC.Error{reason: reason}}
      when reason in [:invalid_swap, "invalid_swap"] ->
        {:error, changed_meanwhile("The account's status")}

      {:error, reason} ->
        {:error, failure(reason)}
    end
  end

  def write_status(session, %{record: record, swap: swap} = plan) do
    params = %{
      repo: session.did,
      collection: AtMcp.Network.collection(:status),
      rkey: "self",
      record: record
    }

    params = if swap, do: Map.put(params, :swap_record, swap), else: params

    case AtMcp.ATProto.put_record(session, params) do
      {:ok, _} ->
        {:ok, status_result(plan, :live, false)}

      {:error, %ProtoRune.XRPC.Error{reason: reason}}
      when reason in [:invalid_swap, "invalid_swap"] ->
        {:error, changed_meanwhile("The account's status")}

      {:error, reason} ->
        {:error, failure(reason)}
    end
  end

  defp status_result(plan, kind, unchanged?) do
    live =
      case plan.record do
        %{"durationMinutes" => minutes, "createdAt" => at} = record ->
          {:ok, start, _} = DateTime.from_iso8601(at)

          %{
            url: get_in(record, ["embed", "external", "uri"]),
            duration_minutes: minutes,
            expires_at: start |> DateTime.add(minutes * 60) |> DateTime.to_iso8601()
          }

        nil ->
          %{}
      end

    Map.merge(
      %{
        ok: true,
        action: :set_status,
        status: Atom.to_string(kind),
        uri: plan.uri,
        replaced: plan.previous,
        unchanged: unchanged?
      },
      live
    )
  end

  # --- feed feedback ---

  @doc """
  Read the feed a feedback is about: its generator's service, which the
  feedback goes to, and whether it takes feedback at all. One that does not is
  refused, naming `feed`, before anything is sent.
  """
  @impl true
  def prepare_feed_feedback(session, request) do
    case AtMcp.ATProto.get_feed_generator(session, %{feed: request.feed}) do
      {:ok, response} ->
        view = field(response, :view) || %{}
        service = field(view, :did)

        cond do
          not AtMcp.Effects.takes_feedback?(request.feed, field(view, :accepts_interactions)) ->
            {:error,
             {:invalid_argument, "feed",
              "this feed does not take feedback: its generator does not accept interactions and it is not one of the app's own feeds that always do, so the app offers none"}}

          not is_binary(service) ->
            {:error, unreadable("a feed generator", response)}

          true ->
            interaction =
              %{"item" => request.item, "event" => AtMcp.Network.type(request.event)}
              |> put_string("feedContext", request.feed_context)
              |> put_string("reqId", request.req_id)

            {:ok, Map.merge(request, %{service: service, interaction: interaction})}
        end

      {:error, reason} ->
        {:error, failure(reason)}
    end
  end

  defp put_string(map, _key, nil), do: map
  defp put_string(map, key, value), do: Map.put(map, key, value)

  @impl true
  def send_feed_feedback(session, prepared) do
    case AtMcp.ATProto.send_interactions(session, prepared.service, %{
           feed: prepared.feed,
           interactions: [prepared.interaction]
         }) do
      {:ok, _} ->
        {:ok,
         %{
           ok: true,
           action: :feed_feedback,
           uri: prepared.item,
           subject_uri: prepared.feed,
           kind: prepared.kind
         }}

      {:error, reason} ->
        {:error, failure(reason)}
    end
  end

  @impl true
  def update_seen(session, %DateTime{} = seen_at) do
    case AtMcp.ATProto.update_seen(session, %{seen_at: DateTime.to_iso8601(seen_at)}) do
      {:ok, _} -> {:ok, %{ok: true, action: :update_seen, seen_at: DateTime.to_iso8601(seen_at)}}
      :ok -> {:ok, %{ok: true, action: :update_seen, seen_at: DateTime.to_iso8601(seen_at)}}
      {:error, reason} -> {:error, failure(reason)}
    end
  end

  # --- a post's gates ---

  # The gates a new post is written with, and the record key they share with
  # it. A post with none is written as before, under a key the PDS picks.
  defp post_gates(session, record, opts) do
    quotes = Keyword.get(opts, :quotes)

    if Keyword.has_key?(opts, :reply_rule) or quotes == :disabled do
      rkey = AtMcp.ATProto.tid()
      uri = "at://#{session.did}/#{AtMcp.Network.collection(:post)}/#{rkey}"
      created = %{"createdAt" => record["createdAt"]}

      gates =
        [
          if(Keyword.has_key?(opts, :reply_rule),
            do:
              {:threadgate,
               AtMcp.ATProto.threadgate_record(
                 uri,
                 Keyword.fetch!(opts, :reply_rule),
                 [],
                 created
               )}
          ),
          if(quotes == :disabled,
            do: {:postgate, AtMcp.ATProto.postgate_record(uri, :disabled, [], created)}
          )
        ]
        |> Enum.reject(&is_nil/1)

      {rkey, gates}
    else
      {nil, []}
    end
  end

  # A link card's thumbnail is a blob the record references, like an image.
  defp upload_link_thumb(_session, nil), do: {:ok, nil}
  defp upload_link_thumb(_session, %{thumb: nil} = link), do: {:ok, link}

  defp upload_link_thumb(session, %{thumb: thumb} = link) do
    with {:ok, [%{blob: blob}]} <- upload_images(session, [thumb]),
         do: {:ok, link |> Map.delete(:thumb) |> Map.put(:thumb_blob, blob)}
  end

  @doc """
  Read what an edit to a post's gates needs and build the writes, before
  anything is sent. `edit` is one of:

    * `{:interactions, uri, allow, quotes}`: set who may reply to and quote
      this account's post at `uri`;
    * `{:hide_reply, uri, hide?}`: hide or unhide a reply in a thread this
      account started;
    * `{:detach_quote, uri, detach?}`: detach or reattach a post quoting one
      of this account's posts.

  Each reads the gate it changes and keeps everything it does not change.
  """
  #
  # Every edit reads the repository's commit before anything else, and writes
  # only over it (`swapCommit`): a gate changed meanwhile, by the app or
  # another client, is never overwritten with what was read before.
  @impl true
  def prepare_gates(session, {:interactions, uri, allow, quotes}) do
    {:ok, {_repo, collection, rkey}} = AtMcp.ATProto.parse_uri(uri)
    post = "at://#{session.did}/#{collection}/#{rkey}"

    with {:ok, commit} <- latest_commit(session),
         {:ok, response} <- read_post(session, uri),
         :ok <- first_post(response, allow),
         {:ok, allow} <- resolve_lists(session, allow),
         {:ok, threadgate} <- own_record(session, :threadgate, rkey),
         {:ok, postgate} <- own_record(session, :postgate, rkey) do
      # A reply has no thread of its own to gate: its threadgate is left as is.
      reply? = reply?(response)
      allow = if reply?, do: :keep, else: allow
      hidden = strings(threadgate, :hidden_replies)
      detached = strings(postgate, :detached_embedding_uris)
      threadgate_now = AtMcp.ATProto.threadgate_record(post, allow, hidden, threadgate)
      postgate_now = AtMcp.ATProto.postgate_record(post, quotes, detached, postgate)

      gates([
        {:threadgate, rkey, threadgate, threadgate_now},
        {:postgate, rkey, postgate, postgate_now}
      ])
      |> with_result(
        %{
          action: :set_post_interactions,
          uri: post,
          reply_rule: if(not reply?, do: AtMcp.Interactions.reply_rule_words(threadgate_now)),
          quotes: AtMcp.Interactions.quotes_word(postgate_now)
        },
        commit
      )
    end
  end

  def prepare_gates(session, {:hide_reply, uri, hide?}) do
    with {:ok, commit} <- latest_commit(session),
         {:ok, response} <- read_post(session, uri),
         {:ok, root} <- thread_root(response, uri),
         {:ok, {root_repo, collection, rkey}} <- AtMcp.ATProto.parse_uri(root),
         :ok <- own(session, root_repo, "the reply's thread was started by #{root_repo}"),
         {:ok, threadgate} <- own_record(session, :threadgate, rkey),
         reply = canonical(response, uri),
         {:ok, hidden} <-
           AtMcp.Interactions.hidden_replies(strings(threadgate, :hidden_replies), reply, hide?) do
      post = "at://#{session.did}/#{collection}/#{rkey}"

      gates([
        {:threadgate, rkey, threadgate,
         AtMcp.ATProto.threadgate_record(post, :keep, hidden, threadgate)}
      ])
      |> with_result(
        %{
          action: if(hide?, do: :hide_reply, else: :unhide_reply),
          uri: reply,
          subject_uri: post
        },
        commit
      )
    end
  end

  def prepare_gates(session, {:detach_quote, uri, detach?}) do
    with {:ok, commit} <- latest_commit(session),
         {:ok, response} <- read_post(session, uri),
         {:ok, quoted} <- quoted_post(response, uri),
         {:ok, {quoted_repo, collection, rkey}} <- AtMcp.ATProto.parse_uri(quoted),
         :ok <- own(session, quoted_repo, "it quotes #{quoted}, a post by another account"),
         {:ok, postgate} <- own_record(session, :postgate, rkey),
         quoting = canonical(response, uri),
         {:ok, detached} <-
           AtMcp.Interactions.detached_quotes(
             strings(postgate, :detached_embedding_uris),
             quoting,
             detach?
           ) do
      post = "at://#{session.did}/#{collection}/#{rkey}"

      gates([
        {:postgate, rkey, postgate,
         AtMcp.ATProto.postgate_record(post, :keep, detached, postgate)}
      ])
      |> with_result(
        %{
          action: if(detach?, do: :detach_quote, else: :reattach_quote),
          uri: quoting,
          subject_uri: post
        },
        commit
      )
    end
  end

  @doc """
  Write what `prepare_gates/2` built, in one commit over the one it read.
  Nothing to change writes nothing, and the result says `unchanged`.
  """
  @impl true
  def write_gates(_session, %{writes: [], result: result}),
    do: {:ok, Map.put(result, :unchanged, true)}

  def write_gates(session, %{writes: writes, result: result, commit: commit}) do
    case AtMcp.ATProto.apply_writes(session, session.did, writes, swap_commit: commit) do
      {:ok, _} ->
        {:ok, Map.put(result, :unchanged, false)}

      {:error, %ProtoRune.XRPC.Error{reason: reason}}
      when reason in [:invalid_swap, "invalid_swap"] ->
        {:error, changed_meanwhile("The account's repository")}

      {:error, reason} ->
        {:error, failure(reason)}
    end
  end

  # The commit an edit is built over. A PDS always serves this; an answer
  # without a CID is one AtMcp cannot write over safely.
  defp latest_commit(session) do
    case AtMcp.ATProto.get_latest_commit(session, session.did) do
      {:ok, response} ->
        case field(response, :cid) do
          cid when is_binary(cid) -> {:ok, cid}
          _ -> {:error, unreadable("the repository's latest commit", response)}
        end

      {:error, reason} ->
        {:error, failure(reason)}
    end
  end

  # A list rule names its list by address, and the AppView lets a reply
  # through only when that address, in DID form, is a list its author is on.
  # A list given by a handle-form address is resolved before anything is
  # written; one whose handle cannot be resolved is refused, naming the entry.
  defp resolve_reply_lists(session, opts) do
    case Keyword.fetch(opts, :reply_rule) do
      {:ok, rules} when is_list(rules) ->
        with {:ok, rules} <- resolve_lists(session, rules),
             do: {:ok, Keyword.put(opts, :reply_rule, rules)}

      _ ->
        {:ok, opts}
    end
  end

  defp resolve_lists(session, rules) when is_list(rules) do
    rules
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {rule, i}, {:ok, acc} ->
      case did_form_rule(session, rule, i) do
        {:ok, rule} -> {:cont, {:ok, acc ++ [rule]}}
        error -> {:halt, error}
      end
    end)
  end

  defp resolve_lists(_session, rules), do: {:ok, rules}

  defp did_form_rule(_session, {:list, "at://did:" <> _} = rule, _i), do: {:ok, rule}

  defp did_form_rule(session, {:list, uri}, i) do
    {:ok, {repo, collection, rkey}} = AtMcp.ATProto.parse_uri(uri)

    case resolve_actor(session, repo) do
      {:ok, did} ->
        {:ok, {:list, "at://#{did}/#{collection}/#{rkey}"}}

      {:error, {:handle_not_resolved, _}} ->
        invalid(
          "reply_rule/#{i}",
          "the handle #{repo} in #{uri} could not be resolved; give the list's AT URI in DID form (at://did:.../#{collection}/#{rkey})"
        )

      error ->
        error
    end
  end

  defp did_form_rule(_session, rule, _i), do: {:ok, rule}

  # Each gate as it was and as it will be becomes a create, an update, a
  # delete, or nothing; the result names each gate the post has afterwards.
  defp gates(changes) do
    writes =
      Enum.flat_map(changes, fn {kind, rkey, before, now} ->
        collection = AtMcp.Network.collection(kind)

        case {before, now} do
          {nil, nil} ->
            []

          {nil, now} ->
            [{:create, collection, rkey, now}]

          {_, nil} ->
            [{:delete, collection, rkey}]

          {before, now} ->
            if same_gate?(before, now), do: [], else: [{:update, collection, rkey, now}]
        end
      end)

    uris =
      Map.new(changes, fn {kind, rkey, _before, now} ->
        {:"#{kind}_uri", if(now, do: gate_uri(now, kind, rkey))}
      end)

    {writes, uris}
  end

  # A gate rebuilt from the record read, with nothing set differently, is the
  # same record: writing it would change nothing but the repository's commit.
  defp same_gate?(before, now), do: AtMcp.ATProto.wire_record(before) == now

  defp gate_uri(gate, kind, rkey) do
    {:ok, {repo, _, _}} = AtMcp.ATProto.parse_uri(gate["post"])
    "at://#{repo}/#{AtMcp.Network.collection(kind)}/#{rkey}"
  end

  defp with_result({writes, uris}, result, commit),
    do:
      {:ok,
       %{
         writes: writes,
         commit: commit,
         result: Map.merge(%{ok: true}, Map.merge(result, uris))
       }}

  # The post an edit names, read through the account's service. A post the
  # service will not hand over is the same refusal a reply's parent gets.
  defp read_post(session, uri) do
    with {:ok, {repo, collection, rkey}} <- AtMcp.ATProto.parse_uri(uri) do
      case AtMcp.ATProto.get_record(session, %{repo: repo, collection: collection, rkey: rkey}) do
        {:ok, response} when is_map(response) -> {:ok, response}
        {:ok, _other} -> {:error, {:referenced_record_unreadable, uri}}
        {:error, reason} -> reference_error(uri, failure(reason))
      end
    end
  end

  # One of this account's gate records, or nil when the repository has none.
  defp own_record(session, kind, rkey) do
    case AtMcp.ATProto.get_record(session, %{
           repo: session.did,
           collection: AtMcp.Network.collection(kind),
           rkey: rkey
         }) do
      {:ok, response} ->
        case AtMcp.Response.fetch(response, :value) do
          {:ok, value} when is_map(value) -> {:ok, value}
          _ -> {:ok, nil}
        end

      {:error, %ProtoRune.XRPC.Error{reason: reason}}
      when reason in [:not_found, :record_not_found] ->
        {:ok, nil}

      {:error, reason} ->
        {:error, failure(reason)}
    end
  end

  defp reply?(response),
    do: is_binary(AtMcp.Response.dig(response, [:value, :reply, :root, :uri]))

  defp first_post(response, allow) do
    if reply?(response) and allow not in [nil, :keep],
      do:
        invalid(
          "reply_rule",
          "applies to a thread's first post; this post is a reply, so who may reply is set on the thread's first post"
        ),
      else: :ok
  end

  defp thread_root(response, uri) do
    case AtMcp.Response.dig(response, [:value, :reply, :root, :uri]) do
      root when is_binary(root) -> {:ok, root}
      _ -> invalid("uri", "#{uri} is not a reply; only replies can be hidden")
    end
  end

  # The post a post quotes, alone or beside media.
  defp quoted_post(response, uri) do
    embed = AtMcp.Response.dig(response, [:value, :embed])

    quoted =
      AtMcp.Response.dig(embed, [:record, :record, :uri]) ||
        AtMcp.Response.dig(embed, [:record, :uri])

    with true <- is_binary(quoted),
         {:ok, {_repo, collection, _rkey}} <- AtMcp.ATProto.parse_uri(quoted),
         true <- AtMcp.Network.collection?(collection, :post) do
      {:ok, quoted}
    else
      _ -> invalid("uri", "#{uri} does not quote a post")
    end
  end

  defp own(session, repo, why) do
    if AtMcp.Interactions.own_repo?(session, repo),
      do: :ok,
      else: invalid("uri", "names a post of another account's thread or post: #{why}")
  end

  defp strings(nil, _key), do: []

  defp strings(record, key) do
    case AtMcp.Response.fetch(record, key) do
      {:ok, list} when is_list(list) -> Enum.filter(list, &is_binary/1)
      _ -> []
    end
  end

  defp invalid(path, message), do: {:error, {:invalid_argument, path, message}}

  @doc """
  The replies a thread read leaves out under the post at `uri`: those the
  thread's author hid and those the account's own settings push down, such as
  replies by accounts it muted. Each says which.
  """
  @impl true
  def get_hidden_replies(session, uri) do
    case AtMcp.ATProto.get_post_thread_other(session, %{anchor: uri}) do
      {:ok, response} ->
        case field(response, :thread) do
          items when is_list(items) -> {:ok, Enum.map(items, &hidden_reply/1)}
          _ -> {:error, unreadable("the replies a thread leaves out", response)}
        end

      {:error, reason} ->
        {:error, failure(reason)}
    end
  end

  defp hidden_reply(item) when is_map(item) do
    value = of_type(item, :value, &is_map/1) || %{}

    (of_type(value, :post, &is_map/1) || %{uri: field(item, :uri)})
    |> post_view()
    |> Map.merge(%{
      depth: of_type(item, :depth, &is_integer/1),
      hidden_by_threadgate: flag(value, [:hidden_by_threadgate, :hiddenByThreadgate]),
      muted_by_viewer: flag(value, [:muted_by_viewer, :mutedByViewer])
    })
  end

  defp hidden_reply(other), do: %{value: to_string_safe(other)}

  # --- pins, thread mutes and bookmarks ---

  @doc """
  Read the post at `uri`: the strong reference a bookmark or a pin needs, and
  the root of its thread, which a thread mute names. A post that is not a
  reply is its own root.
  """
  @impl true
  def resolve_post(session, uri) when is_binary(uri) do
    with {:ok, ref, response} <- fetch_strong_ref(session, uri) do
      root = root_of(response)
      {:ok, Map.put(ref, :root, if(root, do: root.uri, else: ref.uri))}
    end
  end

  @doc """
  Build the profile record that pins `uri`, or unpins when `uri` is nil, from
  the profile as it stands. The post is read for its CID; the profile is read
  so every field the pin does not touch is written back unchanged.
  """
  @impl true
  def prepare_pin(session, uri) do
    with {:ok, ref} <- pin_ref(session, uri),
         {:ok, current, swap} <- current_profile(session) do
      previous = AtMcp.Response.dig(current, [:pinned_post, :uri])
      previous = if is_binary(previous), do: previous

      record =
        if is_nil(uri) and is_nil(previous),
          do: nil,
          else: AtMcp.ATProto.pinned_profile_record(current, ref)

      {:ok, %{record: record, pinned: ref && ref.uri, previous: previous, swap: swap}}
    else
      {:error, {:referenced_record_unreadable, _}} = error -> error
      {:error, reason} -> {:error, failure(reason)}
    end
  end

  defp pin_ref(_session, nil), do: {:ok, nil}

  defp pin_ref(session, uri) do
    with {:ok, ref, _response} <- fetch_strong_ref(session, uri), do: {:ok, ref}
  end

  # Unpinning a profile that pins nothing writes nothing.
  @impl true
  def pin(_session, %{record: nil, previous: nil}),
    do: {:ok, %{ok: true, action: :unpin_post, uri: nil, subject_uri: nil, replaced_uri: nil}}

  def pin(session, %{record: record, pinned: pinned, previous: previous, swap: swap}) do
    case put_profile(session, record, swap) do
      {:ok, result} ->
        {:ok,
         %{
           ok: true,
           action: if(pinned, do: :pin_post, else: :unpin_post),
           uri: summarize_record(result).uri,
           subject_uri: pinned,
           replaced_uri: previous
         }}

      {:error, reason} ->
        {:error, failure(reason)}
    end
  end

  @impl true
  def mute_thread(session, root) when is_binary(root),
    do: thread_mute(session, root, :mute_thread, &AtMcp.ATProto.mute_thread/2)

  @impl true
  def unmute_thread(session, root) when is_binary(root),
    do: thread_mute(session, root, :unmute_thread, &AtMcp.ATProto.unmute_thread/2)

  defp thread_mute(session, root, action, call) do
    case call.(session, %{root: root}) do
      {:error, reason} -> {:error, failure(reason)}
      _ok -> {:ok, %{ok: true, action: action, uri: root}}
    end
  end

  @impl true
  def bookmark(session, %{uri: uri, cid: cid}) do
    case AtMcp.ATProto.create_bookmark(session, %{uri: uri, cid: cid}) do
      {:error, reason} -> {:error, failure(reason)}
      _ok -> {:ok, %{ok: true, action: :bookmark, uri: uri}}
    end
  end

  @impl true
  def unbookmark(session, uri) when is_binary(uri) do
    case AtMcp.ATProto.delete_bookmark(session, %{uri: uri}) do
      {:error, reason} -> {:error, failure(reason)}
      _ok -> {:ok, %{ok: true, action: :unbookmark, uri: uri}}
    end
  end

  @impl true
  def get_bookmarks(session, opts) do
    session
    |> AtMcp.ATProto.get_bookmarks(paging(opts, %{}))
    |> read(:bookmarks, &bookmark_item/1)
  end

  # --- drafts ---

  @impl true
  def get_drafts(session, opts) do
    session
    |> AtMcp.ATProto.get_drafts(paging(opts, %{}))
    |> read(:drafts, &AtMcp.Summary.extract(:draft, &1))
  end

  # The service has no read of one draft, so finding one is reading pages of
  # them. Drafts are few — the service may cap how many an account keeps — and
  # this many pages of the largest page the lexicon allows is far past any
  # cap seen; a draft beyond them is reported as not found.
  @draft_page 100
  @draft_pages 10

  @doc """
  The draft with this id, as the service holds it, in the keys it is written
  with. A draft this account does not have is refused, naming `id`: the
  service would ignore an update to it without saying so.
  """
  @impl true
  def find_draft(session, id) when is_binary(id), do: find_draft(session, id, nil, @draft_pages)

  defp find_draft(_session, id, _cursor, 0), do: no_draft(id)

  defp find_draft(session, id, cursor, pages) do
    case AtMcp.ATProto.get_drafts(
           session,
           AtMcp.ATProto.params(%{limit: @draft_page, cursor: cursor})
         ) do
      {:ok, response} ->
        drafts = field(response, :drafts)

        found =
          is_list(drafts) &&
            Enum.find(drafts, &(is_map(&1) and field(&1, :id) == id))

        cond do
          not is_list(drafts) ->
            {:error, unreadable("a page of drafts", response)}

          found ->
            {:ok, AtMcp.ATProto.wire_record(field(found, :draft) || %{})}

          is_binary(cursor_of(response)) ->
            find_draft(session, id, cursor_of(response), pages - 1)

          true ->
            no_draft(id)
        end

      {:error, reason} ->
        {:error, failure(reason)}
    end
  end

  defp no_draft(id),
    do: {:error, {:invalid_argument, "id", "this account has no draft with id #{id}"}}

  @impl true
  def save_draft(session, nil, draft) do
    case AtMcp.ATProto.create_draft(session, %{draft: draft}) do
      {:ok, response} when is_map(response) ->
        case field(response, :id) do
          id when is_binary(id) -> {:ok, draft_result(:save_draft, id, draft)}
          _ -> {:error, unreadable("a created draft", response)}
        end

      {:ok, other} ->
        {:error, unreadable("a created draft", other)}

      {:error, reason} ->
        {:error, failure(reason)}
    end
  end

  def save_draft(session, id, draft) when is_binary(id) do
    case AtMcp.ATProto.update_draft(session, %{draft: %{"id" => id, "draft" => draft}}) do
      {:error, reason} -> {:error, failure(reason)}
      _ok -> saved_draft(session, id, draft)
    end
  end

  # `updateDraft` answers success for an id it does not hold and ignores the
  # update (its lexicon says so), so a draft deleted between the read that
  # found it and the update would be reported saved when nothing was. The
  # draft is read again, for whether it still exists only: the service queues
  # an update and applies it later, so `getDrafts` can still show the text from
  # before, and the result carries the draft as sent. A draft gone by then is a
  # refusal; a read that fails says nothing either way, so the update's outcome
  # is unknown. A deletion still queued is not seen by this check.
  defp saved_draft(session, id, draft) do
    case find_draft(session, id) do
      {:ok, _still_there} ->
        {:ok, draft_result(:save_draft, id, draft)}

      {:error, {:invalid_argument, "id", _}} ->
        {:error,
         AtMcp.Effects.Failure.new(:refused,
           message:
             "The draft #{id} was deleted before the update reached it, and the service ignores an update to a draft it does not hold, so nothing was saved. " <>
               "Call save_draft without an id to keep the text as a new draft.",
           detail: {:draft_gone, id}
         )}

      {:error, reason} ->
        {:error, AtMcp.Effects.Failure.new(:indeterminate, detail: {:draft_unconfirmed, reason})}
    end
  end

  @impl true
  def delete_draft(session, id, draft) when is_binary(id) do
    case AtMcp.ATProto.delete_draft(session, %{id: id}) do
      {:error, reason} -> {:error, failure(reason)}
      _ok -> {:ok, draft_result(:delete_draft, id, draft)}
    end
  end

  defp draft_result(action, id, draft) do
    %{
      ok: true,
      action: action,
      id: id,
      draft: AtMcp.Summary.extract(:draft, %{"id" => id, "draft" => draft})
    }
  end

  # --- the write half ---

  # Every record AtMcp creates goes through here, so the collection and the
  # record's `$type` cannot disagree: both are `AtMcp.Network`'s answer for the
  # same kind.
  defp create(session, kind, record) do
    AtMcp.ATProto.create_record(session, %{
      repo: session.did,
      collection: AtMcp.Network.collection(kind),
      record: record
    })
  end

  # The URI selects the network, but the tool selects the record kind. An
  # account may delete records from either supported network after reconfiguring;
  # undoing a repost must never delete the original post instead. Repository
  # ownership (including handle references) is still enforced by the home PDS.
  defp delete(session, uri, action, kind) do
    with {:ok, {repo, collection, rkey}} <- AtMcp.ATProto.parse_uri(uri),
         :ok <- require_record_kind(collection, kind, action),
         {:ok, _} <-
           AtMcp.ATProto.delete_record(session, %{
             repo: repo,
             collection: collection,
             rkey: rkey
           }) do
      {:ok, %{ok: true, uri: uri, action: action}}
    else
      {:error, reason} -> {:error, failure(reason)}
    end
  end

  defp require_record_kind(collection, kind, action) do
    if AtMcp.Network.collection?(collection, kind) do
      :ok
    else
      {:error,
       AtMcp.Effects.Failure.new(:refused,
         message:
           "#{action} requires a #{kind} record URI from a supported network; nothing was sent",
         detail: {:wrong_record_kind, kind, collection}
       )}
    end
  end

  @doc """
  Resolve a handle to the DID a follow or block record names, through the
  account's own service. A DID is returned as given.

  A string that is not a handle is refused before anything is sent, and a
  service that answers the resolution with a 400 naming `HandleNotFound` (the
  lexicon's error) or `InvalidRequest` (what the reference PDS answers both for
  a handle it cannot find and when its own lookup fails) could not resolve it;
  both are `{:handle_not_resolved, actor}`. Any other failure keeps its own
  kind: a rate limit or an outage says nothing about the handle, and an agent
  told to wait should not be told the handle is wrong. An answer that is not a
  DID is not one either, and is never passed on to build a record.
  """
  @impl true
  def resolve_actor(_session, "did:" <> _ = did), do: {:ok, did}

  def resolve_actor(session, handle) when is_binary(handle) do
    case ProtoRune.Atproto.Identity.resolve_handle(
           ProtoRune.Session.service_url(session),
           handle
         ) do
      {:ok, "did:" <> _ = did} ->
        {:ok, did}

      {:error, :invalid_format} ->
        {:error, {:handle_not_resolved, handle}}

      {:error, %ProtoRune.XRPC.Error{http_status: 400, reason: reason}}
      when reason in [:handle_not_found, :invalid_request] ->
        {:error, {:handle_not_resolved, handle}}

      {:error, reason} ->
        {:error, failure(reason)}

      {:ok, not_a_did} ->
        {:error, unreadable("a handle resolution", %{did: not_a_did})}
    end
  end

  @doc """
  Read the records a write refers to, and return the options carrying them.

  A reply and a quote both need a strong reference — a uri and the record's
  CID — and a CID is not derivable from a uri, so building either record means
  reading the record it points at. That read can fail, and it fails for
  ordinary reasons: the post was deleted, or it is not indexed yet, or the uri
  names something that is not a post. AtMcp runs it before the write quota
  is charged so a refusal that never reached the network costs nothing.

  Already-resolved options pass through: resolving twice would spend two reads
  on one write.
  """
  @impl true
  def resolve_references(session, opts) when is_list(opts) do
    if Keyword.has_key?(opts, :reply_ref) and Keyword.has_key?(opts, :quote_ref) do
      {:ok, opts}
    else
      with {:ok, reply} <- reply_refs(session, Keyword.get(opts, :reply)),
           {:ok, quoted} <- strong_ref_for(session, Keyword.get(opts, :quote)) do
        {:ok, opts |> Keyword.put(:reply_ref, reply) |> Keyword.put(:quote_ref, quoted)}
      end
    end
  end

  # A reply's root is the parent's own root when the parent is itself a reply,
  # and the parent otherwise. Both references carry a CID, which is why the
  # parent record has to be read rather than assumed from its URI.
  defp reply_refs(_session, nil), do: {:ok, nil}

  defp reply_refs(session, uri) when is_binary(uri) do
    with {:ok, parent, response} <- fetch_strong_ref(session, uri),
         :ok <- reply_allowed(session, parent.uri) do
      {:ok, %{root: root_of(response) || parent, parent: parent}}
    end
  end

  # Whether this account may reply to a post is the AppView's answer,
  # `viewer.replyDisabled`, from the thread's reply rule (its threadgate); the
  # app disables its reply button on it. The PDS accepts a reply the rule
  # excludes, and the AppView then leaves it out of the thread, so such a reply
  # is refused here, before anything is written. A post the AppView does not
  # return (`getPosts` leaves out what it does not have) says nothing either
  # way, and the reply goes ahead. Any failure of the read, a rate limit or a
  # refused credential included, fails the reply with nothing sent.
  defp reply_allowed(session, uri) do
    case AtMcp.ATProto.get_posts(session, [uri]) do
      {:ok, response} ->
        case field(response, :posts) do
          [post | _] when is_map(post) ->
            # The client snake-cases the keys of every body it decodes.
            if AtMcp.Response.dig(post, [:viewer, :reply_disabled]) == true,
              do: {:error, {:reply_disabled, uri}},
              else: :ok

          _ ->
            :ok
        end

      {:error, reason} ->
        failure = failure(reason)

        {:error,
         %{
           failure
           | message:
               "Could not read whether the thread's reply rule lets this account reply to #{uri}, so nothing was sent: #{failure.message || "no message"}"
         }}
    end
  end

  # A quote is given as an AT URI, and a strong reference needs the CID too.
  defp strong_ref_for(_session, nil), do: {:ok, nil}

  defp strong_ref_for(session, uri) when is_binary(uri) do
    with {:ok, ref, _response} <- fetch_strong_ref(session, uri), do: {:ok, ref}
  end

  # A record's CID is not derivable from its URI, so a strong reference to
  # anything means reading it first. A response without one is not a reference
  # AtMcp can weaken: it is a read it could not complete.
  defp fetch_strong_ref(session, uri) do
    with {:ok, {repo, collection, rkey}} <- AtMcp.ATProto.parse_uri(uri),
         {:ok, response} <-
           AtMcp.ATProto.get_record(session, %{repo: repo, collection: collection, rkey: rkey}),
         {:ok, cid} when is_binary(cid) <- AtMcp.Response.fetch(response, :cid) do
      {:ok, %{uri: canonical(response, uri), cid: cid}, response}
    else
      # An answer arrived and carried no CID: the record is unusable as a
      # reference whatever else it is.
      :error -> {:error, {:referenced_record_unreadable, uri}}
      {:ok, _not_a_cid} -> {:error, {:referenced_record_unreadable, uri}}
      {:error, reason} -> reference_error(uri, failure(reason))
    end
  end

  # A service that refuses to hand over one record is saying something about
  # that record: it is deleted, not indexed yet, or not what the uri claims,
  # and the caller's move is to reference something else. A transport failure,
  # an outage, or a credential the service rejected says nothing about the
  # record at all, and a caller told "it may be deleted" about a post that is
  # still there stops trying instead of retrying. So only a refusal becomes
  # `referenced_record_unreadable`; everything else keeps its own kind.
  defp reference_error(uri, %AtMcp.Effects.Failure{kind: :refused}),
    do: {:error, {:referenced_record_unreadable, uri}}

  defp reference_error(_uri, %AtMcp.Effects.Failure{} = failure), do: {:error, failure}

  # The address a record is known by everywhere: the DID form the service
  # answers a read with, whichever form the caller named it in. A handle can
  # move to another account and back, and the AppView matches pins, thread
  # mutes, bookmarks and gates by the DID form, so a reference written with a
  # handle names nothing it will ever show. A service that answers without a
  # DID-form uri leaves the caller's.
  defp canonical(response, uri) do
    case AtMcp.Response.fetch(response, :uri) do
      {:ok, "at://did:" <> _ = canonical} -> canonical
      _ -> uri
    end
  end

  defp root_of(response) do
    with {:ok, value} when is_map(value) <- AtMcp.Response.fetch(response, :value),
         {:ok, reply} when is_map(reply) <- AtMcp.Response.fetch(value, :reply),
         {:ok, root} when is_map(root) <- AtMcp.Response.fetch(reply, :root),
         {:ok, uri} when is_binary(uri) <- AtMcp.Response.fetch(root, :uri),
         {:ok, cid} when is_binary(cid) <- AtMcp.Response.fetch(root, :cid) do
      %{uri: uri, cid: cid}
    else
      _ -> nil
    end
  end

  # A record references a blob; it does not carry one. So the bytes are
  # uploaded first, and the record is built around what the service gives back.
  defp upload_images(_session, nil), do: {:ok, nil}
  defp upload_images(_session, []), do: {:ok, nil}

  defp upload_images(session, images) when is_list(images) do
    Enum.reduce_while(images, {:ok, []}, fn image, {:ok, acc} ->
      case AtMcp.ATProto.upload_blob(
             session,
             Map.fetch!(image, :data),
             Map.get(image, :mime_type, "application/octet-stream")
           ) do
        {:ok, response} ->
          case AtMcp.Response.fetch(response, :blob) do
            {:ok, blob} when is_map(blob) ->
              {:cont, {:ok, acc ++ [%{blob: blob, alt: Map.get(image, :alt)}]}}

            _ ->
              {:halt, {:error, :blob_not_returned}}
          end

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  # A profile update starts from the record it is about to replace, so a field
  # nobody mentioned survives it, and writes it back only if it is still that
  # record: the CID read here is the `swapRecord` of the write (`put_profile/3`).
  # A repository with no profile record yet is not an error: the account simply
  # has no profile, and this writes the first; its CID is nil.
  defp current_profile(session) do
    case AtMcp.ATProto.get_record(session, %{
           repo: session.did,
           collection: AtMcp.Network.collection(:profile),
           rkey: "self"
         }) do
      {:ok, response} ->
        cid =
          case AtMcp.Response.fetch(response, :cid) do
            {:ok, cid} when is_binary(cid) -> cid
            _ -> nil
          end

        case AtMcp.Response.fetch(response, :value) do
          {:ok, value} when is_map(value) -> {:ok, value, cid}
          _ -> {:ok, %{}, cid}
        end

      {:error, %ProtoRune.XRPC.Error{reason: reason}}
      when reason in [:not_found, :record_not_found] ->
        {:ok, %{}, nil}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The read came back snakelized; the write goes out camelCase. Naming the two
  # profile fields once here is what keeps `displayName` from being written as
  # `display_name` and silently becoming a field the lexicon does not define.
  @profile_fields %{
    display_name: "displayName",
    description: "description",
    pronouns: "pronouns",
    website: "website"
  }

  # A field not given is kept. Pronouns and a website given empty are removed;
  # the tool drops an empty display name or description before it gets here.
  defp merge_profile(current, updates) do
    current = Map.new(current, fn {key, value} -> {to_string(key), value} end)

    current =
      Map.new(current, fn {key, value} ->
        {Map.get(@profile_fields, String.to_atom(key), key), value}
      end)

    Enum.reduce(@profile_fields, current, fn {key, wire}, record ->
      case Keyword.get(updates, key) do
        nil -> record
        "" -> Map.delete(record, wire)
        value -> Map.put(record, wire, value)
      end
    end)
  end

  # The one place a client library's failures become AtMcp's three kinds. Above
  # this line, no module needs to know what ProtoRune or its transport return.
  @auth_reasons [:expired_token, :invalid_token, :unauthorized, :token_required]

  defp failure(%AtMcp.Effects.Failure{} = failure), do: failure

  defp failure(%ProtoRune.XRPC.Error{} = error) do
    kind =
      cond do
        error.reason in @auth_reasons and error.http_status in [400, 401] -> :auth_refused
        error.reason in @auth_reasons -> :auth_refused
        is_integer(error.http_status) and error.http_status in 400..499 -> :refused
        # 501 Not Implemented: the service does not run this method at all, so
        # nothing it was asked to do happened. A deployment that does not serve
        # an endpoint (bookmarks, drafts) answers this way.
        error.http_status == 501 -> :refused
        true -> :indeterminate
      end

    AtMcp.Effects.Failure.new(kind,
      status: error.http_status,
      message: error.message,
      detail: error.reason
    )
  end

  # Request validation runs before anything is sent, so the action did not happen.
  defp failure([%Peri.Error{} | _] = errors),
    do: AtMcp.Effects.Failure.new(:refused, message: AtMcp.MCP.Tools.format_reason(errors))

  defp failure(%Peri.Error{} = error),
    do: AtMcp.Effects.Failure.new(:refused, message: AtMcp.MCP.Tools.format_reason(error))

  defp failure(reason) when reason in [:malformed_at_uri, :invalid_at_uri_format],
    do: AtMcp.Effects.Failure.new(:refused, message: "the record reference is not a valid AT URI")

  defp failure(reason) when reason in @auth_reasons,
    do: AtMcp.Effects.Failure.new(:auth_refused, detail: reason)

  # A lost or unrecognized response says nothing about whether the action ran.
  defp failure(reason), do: AtMcp.Effects.Failure.new(:indeterminate, detail: reason)

  defp decode_json_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      _ -> %{}
    end
  end

  defp decode_json_body(body) when is_map(body), do: body
  defp decode_json_body(_), do: %{}

  # --- summarizers ---

  # Every page the AppView returns is one shape under a different name for the
  # list: a count, its items and a cursor. One reader serves all of them, and it
  # matches atom and string keys alike.
  #
  # A response that does not carry the list is not an empty page. It is a
  # response AtMcp could not read, and the read is reported as unknown rather
  # than as a result the caller would believe.
  # Every paged read takes the same two options. A parameter the caller did not
  # give is left out rather than sent empty: `cursor=` asks a service to
  # continue from nowhere.
  defp paging(opts, params) do
    AtMcp.ATProto.params(
      Map.merge(params, %{
        limit: Keyword.get(opts, :limit, 20),
        cursor: Keyword.get(opts, :cursor)
      })
    )
  end

  # One endpoint result becomes one page, or one failure of AtMcp's three kinds.
  defp read({:ok, response}, key, item_fun), do: page(response, key, item_fun)
  defp read({:error, reason}, _key, _item_fun), do: {:error, failure(reason)}

  defp page(list, _key, item_fun) when is_list(list) do
    {:ok, %{count: length(list), items: Enum.map(list, item_fun), cursor: nil}}
  end

  defp page(source, key, item_fun) when is_map(source) do
    case AtMcp.Response.fetch(source, key) do
      {:ok, list} when is_list(list) ->
        {:ok,
         %{
           count: length(list),
           items: Enum.map(list, item_fun),
           cursor: cursor_of(source)
         }}

      _ ->
        {:error, unreadable("a page of #{key}", source)}
    end
  end

  defp page(other, key, _item_fun), do: {:error, unreadable("a page of #{key}", other)}

  defp cursor_of(source) do
    case AtMcp.Response.fetch(source, :cursor) do
      {:ok, cursor} when is_binary(cursor) -> cursor
      _ -> nil
    end
  end

  # The service answered; AtMcp could not read the answer. That is neither a
  # refusal nor an unknown outcome at the service, and it is not worth retrying,
  # because the limit is this parser. The message names the shape for an
  # operator without publishing the response.
  defp unreadable(what, source) do
    AtMcp.Effects.Failure.new(:unreadable,
      message: "The service returned #{what} in a shape AtMcp does not recognize.",
      detail: {:unrecognized_shape, keys_of(source)}
    )
  end

  defp notif_item(n), do: AtMcp.Summary.extract(:notification, n)

  defp fetch_thread(session, uri, depth) do
    params = %{uri: uri, depth: depth, parentHeight: @chain_parent_height}

    case AtMcp.ATProto.get_post_thread(session, params) do
      {:ok, response} ->
        case field(response, :thread) do
          node when is_map(node) ->
            if thread_node?(node),
              do: {:ok, node},
              else: {:error, unreadable("a thread", response)}

          _ ->
            {:error, unreadable("a thread", response)}
        end

      {:error, reason} ->
        {:error, failure(reason)}
    end
  end

  # A thread node is either a post view or one of the placeholders that carry a
  # uri and nothing else. A map with neither says nothing about any post, and
  # reading it as an element would put a uri-less placeholder in the chain and
  # leave the walk with nowhere to go but the uri it started from.
  defp thread_node?(node) do
    is_map(of_type(node, :post, &is_map/1)) or is_binary(field(node, :uri))
  end

  # The chain the service returned, root first: each node's `parent` link
  # walked up, then read back down. The counter is not a policy, it is a
  # terminator — a response deeper than the @chain_parent_height it was asked
  # for must not take the caller with it. What is over the cap is cut once, by
  # `cap_chain/1`, where the count it reports is taken.
  defp chain_elements(node, did), do: chain_elements(node, did, [], @chain_read_limit)

  defp chain_elements(node, did, acc, remaining) when is_map(node) and remaining > 0 do
    acc = [chain_element(node, did) | acc]

    case field(node, :parent) do
      parent when is_map(parent) -> chain_elements(parent, did, acc, remaining - 1)
      _ -> acc
    end
  end

  defp chain_elements(_node, _did, acc, _remaining), do: acc

  # Whether the chain begins where the conversation did. The requested post
  # names its own root, so arriving is checkable rather than assumed: a service
  # that answered with fewer parents than it was asked for is indistinguishable
  # from a short thread without this.
  #
  # The walk also says why it stopped, because a caller cannot resume from
  # every stop. `:turned_back` is the one that matters: the uri above the head
  # is one this walk has already read and refused, so reading from it returns
  # what the caller already has.
  defp reach_root(session, chain, root_uri, did, calls_left) do
    reach_root(session, chain, root_uri, did, calls_left, seen(chain))
  end

  defp reach_root(session, chain, root_uri, did, calls_left, seen) do
    top = hd(chain)

    cond do
      top.uri == root_uri ->
        {chain, false, :root}

      # The chain already carries all it can. Ancestors read now would only be
      # cut again, so the reads are not spent.
      length(chain) >= @chain_max_elements ->
        {chain, true, :cap}

      calls_left == 0 ->
        {[unresolved(top.reply_to || root_uri) | chain], true, :walk_limit}

      true ->
        # A post that could not be read does not name its own parents, so the
        # only uri left to try is the root the requested post declared: read it
        # by uri, and report that what sits between is not known.
        {next, jumped} =
          if is_binary(top.reply_to), do: {top.reply_to, false}, else: {root_uri, true}

        # Reading a post the chain already holds cannot bring it closer to the
        # root, and prepending it again would hand the caller a conversation
        # that never happened. Two shapes arrive here: a reply whose declared
        # root is not its topmost ancestor, so `root_uri` sits below the head
        # and is never reached, and records that name each other as parent.
        if MapSet.member?(seen, next) do
          {chain, true, :turned_back}
        else
          climb(session, chain, next, root_uri, did, calls_left, jumped, seen)
        end
    end
  end

  defp climb(session, chain, uri, root_uri, did, calls_left, jumped, seen) do
    with {:ok, node} <- fetch_thread(session, uri, 0),
         fresh = chain_elements(node, did),
         false <- Enum.any?(fresh, &MapSet.member?(seen, &1.uri)) do
      {chain, truncated, stop} =
        reach_root(
          session,
          fresh ++ chain,
          root_uri,
          did,
          calls_left - 1,
          Enum.reduce(fresh, seen, &put_seen(&2, &1.uri))
        )

      {chain, truncated or jumped, stop}
    else
      # The response repeats a post the chain already holds: stop here rather
      # than read the same ancestors again. This uri has now been read and
      # refused, so it is not a place to resume either.
      true -> {chain, true, :turned_back}
      {:error, _reason} -> {[unresolved(uri) | chain], true, :walk_limit}
    end
  end

  defp seen(chain), do: Enum.reduce(chain, MapSet.new(), &put_seen(&2, &1.uri))

  defp put_seen(set, uri) when is_binary(uri), do: MapSet.put(set, uri)
  defp put_seen(set, _uri), do: set

  # Root first, so what is cut is what is furthest from the post being
  # answered, and the count is what the caller is told it is missing.
  defp cap_chain(chain) do
    case length(chain) - @chain_max_elements do
      extra when extra > 0 -> {Enum.drop(chain, extra), extra}
      _ -> {chain, 0}
    end
  end

  defp unreadable_element?(element) do
    element.not_found or element.blocked or element.unresolved
  end

  # A page read from `before` carries no replies at all. Asking for depth 0 is
  # not enough to promise that: a service free to answer with more than it was
  # asked for would put a post in two pages, and the promise is AtMcp's to keep.
  defp chain_replies(_node, _did, :chain_only), do: {[], 0}

  defp chain_replies(node, did, :with_replies) do
    replies = of_type(node, :replies, &is_list/1) || []
    visible = Enum.take(replies, @chain_max_replies)
    {Enum.map(visible, &chain_element(&1, did)), length(replies) - length(visible)}
  end

  defp chain_element(node, did) when is_map(node) do
    case of_type(node, :post, &is_map/1) do
      post when is_map(post) -> post_element(node, post, did)
      _ -> node_placeholder(node)
    end
  end

  defp chain_element(_node, _did), do: placeholder(nil)

  defp post_element(node, post, did) do
    base = AtMcp.Summary.extract(:chain_post, post)

    Map.merge(base, %{
      # A handle is a name the account can change; the DID is the account.
      is_self: is_binary(did) and base.author_did == did,
      not_found: flag(node, [:not_found, :notFound]),
      blocked: flag(node, [:blocked]),
      unresolved: false
    })
  end

  # `notFoundPost` and `blockedPost` carry a uri and nothing else worth
  # reading. The element keeps its place in the chain: an agent that cannot
  # see one post of a conversation is somewhere different from one reading a
  # conversation that is one post shorter.
  defp node_placeholder(node) do
    author_did = AtMcp.Response.dig(node, [:author, :did])

    node
    |> field(:uri)
    |> placeholder()
    |> Map.put(:author_did, if(is_binary(author_did), do: author_did))
    |> Map.put(:not_found, flag(node, [:not_found, :notFound]))
    |> Map.put(:blocked, flag(node, [:blocked]))
  end

  defp unresolved(uri), do: uri |> placeholder() |> Map.put(:unresolved, true)

  defp placeholder(uri) do
    %{
      uri: if(is_binary(uri), do: uri),
      cid: nil,
      text: nil,
      author: nil,
      author_did: nil,
      display_name: nil,
      created_at: nil,
      reply_to: nil,
      facets: [],
      is_self: false,
      not_found: false,
      blocked: false,
      unresolved: false
    }
  end

  @doc false
  # The summarizers by the response they read, for the field-coverage test: it
  # hands each a recorded response and checks every field either reaches the
  # summary or is listed in `AtMcp.LeftOut`.
  def summarize(:feed, response), do: page(response, :feed, &feed_item/1)
  def summarize(:thread, response), do: {:ok, summarize_thread(response)}
  def summarize(:profile, response), do: {:ok, summarize_profile(response)}
  def summarize(:likes, response), do: page(response, :likes, &actor_item/1)
  def summarize(:feeds, response), do: page(response, :feeds, &summarize_generator/1)
  def summarize(:feed_info, response), do: feed_info(response)
  def summarize(:trends, response), do: page(response, :trends, &trend/1)
  def summarize(:topics, response), do: topics(response)
  def summarize(:list, response), do: list_page(response)
  def summarize(:lists, response), do: page(response, :lists, &list_view/1)

  def summarize(:starter_pack, response),
    do: {:ok, pack_view(field(response, :starter_pack))}

  def summarize(:starter_packs, response), do: page(response, :starter_packs, &pack_view/1)

  defp summarize_thread(thread) when is_map(thread) do
    node = field(thread, :thread) || thread

    node
    |> thread_node(2, 2)
    |> mark_hidden(hidden_by_threadgate(thread, node))
    |> Map.put(:context, %{depth: 2, parent_height: 2, max_replies_per_node: @thread_max_replies})
  end

  defp summarize_thread(other), do: %{value: to_string_safe(other)}

  # `feed.getPostThread` returns the replies the thread's author hid among the
  # others, unmarked; the app leaves them out because the thread's threadgate
  # lists them. The response carries that threadgate (beside the thread, and on
  # the root post's view when the root is the post read), so each reply it
  # lists is marked where it stands.
  defp hidden_by_threadgate(thread, node) do
    [[:threadgate, :record, :hidden_replies], [:post, :threadgate, :record, :hidden_replies]]
    |> Enum.zip([thread, node])
    |> Enum.flat_map(fn {path, from} ->
      case AtMcp.Response.dig(from, path) do
        list when is_list(list) -> Enum.filter(list, &is_binary/1)
        _ -> []
      end
    end)
    |> MapSet.new()
  end

  defp mark_hidden(node, hidden) do
    if MapSet.size(hidden) == 0, do: node, else: mark_hidden_node(node, hidden)
  end

  defp mark_hidden_node(node, hidden) when is_map(node) do
    node =
      if MapSet.member?(hidden, node[:uri]),
        do: Map.put(node, :hidden_by_threadgate, true),
        else: node

    node
    |> Map.update(:parent, nil, &mark_hidden_node(&1, hidden))
    |> Map.update(:replies, [], fn replies -> Enum.map(replies, &mark_hidden_node(&1, hidden)) end)
  end

  defp mark_hidden_node(other, _hidden), do: other

  # `shown_below` is 1 for a parent: one of its replies is the post this read
  # shows under it.
  defp thread_node(node, parents, depth, shown_below \\ 0) when is_map(node) do
    post = of_type(node, :post, &is_map/1) || node
    replies = of_type(node, :replies, &is_list/1) || []
    parent = field(node, :parent)
    visible = if depth > 0, do: Enum.take(replies, @thread_max_replies), else: []

    post_view(post)
    |> Map.put(:type, field(node, :"$type"))
    |> Map.put(:not_found, flag(node, [:not_found, :notFound]))
    |> Map.put(:blocked, flag(node, [:blocked]))
    |> Map.put(:parent, if(parent && parents > 0, do: thread_node(parent, parents - 1, 0, 1)))
    |> Map.put(:parent_omitted, not is_nil(parent) and parents == 0)
    |> Map.put(:replies, Enum.map(visible, &thread_node(&1, 0, depth - 1)))
    |> Map.put(:replies_omitted, replies_omitted(node, post, replies, visible, shown_below))
  end

  # A post at the read's depth limit, and a parent, come back with no `replies`
  # at all: the service was not asked for them. Counting the list it sent would
  # say 0 however many replies the post has, so the count is the post's own
  # `replyCount` (`reply_count` once decoded), less what this read shows, or
  # nil when the service gave none.
  defp replies_omitted(node, post, replies, visible, shown_below) do
    case {field(node, :replies), field(post, :reply_count) || field(post, :replyCount)} do
      {nil, count} when is_integer(count) -> max(count - shown_below, 0)
      {nil, _unknown} -> nil
      _sent -> length(replies) - length(visible)
    end
  end

  # `false` is a value. Read through a chain of `||` fallbacks it becomes the same
  # answer as a key the response never sent, so an unread notification would
  # report an unknown state. These two flags want `false` in both cases, so they
  # are read once and explicitly here rather than by a fallback the next flag
  # would inherit.
  defp flag(node, keys) do
    Enum.reduce_while(keys, false, fn key, default ->
      case AtMcp.Response.fetch(node, key) do
        {:ok, value} when is_boolean(value) -> {:halt, value}
        _ -> {:cont, default}
      end
    end)
  end

  defp of_type(map, key, predicate) do
    value = field(map, key)
    if predicate.(value), do: value
  end

  defp field(map, key) do
    case AtMcp.Response.fetch(map, key) do
      {:ok, value} -> value
      :error -> nil
    end
  end

  # A feed item wraps the post with what the feed says about it: why it is
  # there and who a reply answers (`AtMcp.Post.feed_context/1`).
  defp feed_item(item) when is_map(item) do
    case AtMcp.Response.fetch(item, :post) do
      {:ok, post} when is_map(post) ->
        post
        |> Map.put("feed_context", AtMcp.Post.feed_context(item))
        |> post_view()

      _ ->
        post_view(item)
    end
  end

  defp feed_item(other), do: %{value: to_string_safe(other)}

  # `getLikes` returns the like record, not the account; the account is inside
  # it. Unwrapping here is the same move `feed_item/1` makes for `post`.
  defp actor_item(item) when is_map(item) do
    case AtMcp.Response.fetch(item, :actor) do
      {:ok, actor} when is_map(actor) -> summarize_profile(actor)
      _ -> summarize_profile(item)
    end
  end

  defp actor_item(other), do: %{value: to_string_safe(other)}

  # A bookmark wraps the post it saved, or the placeholder the service sends
  # when that post is deleted or hidden by a block. The placeholder keeps its
  # place and says which, as a thread's does.
  defp bookmark_item(item) when is_map(item) do
    post = of_type(item, :item, &is_map/1) || %{}

    post
    |> post_view()
    |> Map.merge(%{
      not_found: flag(post, [:not_found, :notFound]),
      blocked: flag(post, [:blocked]),
      bookmarked_at: string_field(item, [:created_at, :createdAt])
    })
  end

  defp bookmark_item(other), do: %{value: to_string_safe(other)}

  defp string_field(map, keys) do
    Enum.find_value(keys, fn key ->
      case field(map, key) do
        value when is_binary(value) -> value
        _ -> nil
      end
    end)
  end

  defp relationship_item(item), do: AtMcp.Summary.extract(:relationship, item)

  defp post_view(post), do: AtMcp.Summary.extract(:post, post)

  defp summarize_profile(p), do: AtMcp.Summary.extract(:profile, p)

  defp summarize_generator(item), do: AtMcp.Summary.extract(:generator, item)

  defp mention_warnings(result, []), do: result

  defp mention_warnings(result, handles) do
    Map.merge(result, %{
      unresolved_mentions: handles,
      warning:
        "These handles could not be resolved. They were published as plain text, without mention facets."
    })
  end

  defp summarize_write(result, text) when is_map(result) do
    %{
      uri: Map.get(result, :uri) || Map.get(result, "uri"),
      cid: Map.get(result, :cid) || Map.get(result, "cid"),
      text: text
    }
  end

  defp summarize_write(result, text), do: %{result: to_string_safe(result), text: text}

  defp summarize_record(result) when is_map(result) do
    %{
      uri: Map.get(result, :uri) || Map.get(result, "uri"),
      cid: Map.get(result, :cid) || Map.get(result, "cid")
    }
  end

  defp summarize_record(result), do: %{result: to_string_safe(result)}

  defp keys_of(map) when is_map(map), do: Map.keys(map) |> Enum.map(&to_string/1) |> Enum.take(20)
  defp keys_of(_), do: []

  defp to_string_safe(v) when is_binary(v), do: v
  defp to_string_safe(v), do: inspect(v, limit: 20)
end
