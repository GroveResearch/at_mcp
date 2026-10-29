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

  @doc """
  A page of notification groups, each hydrated from the response's related
  views: who acted (handle and display name from their profile views) and the
  posts acted on (their text from their post views). A reply, quote or mention
  also carries its post whole, as `get_posts` reads one but without moderation
  marks (notifications are not marked yet), because the app's Notifications
  screen shows it as a full post (social-app
  NotificationFeedItem.tsx at 62b95002, lines 212-233). The service names at
  most the first ten of each in a group; `count` is how many it holds.
  """
  @impl true
  def get_grouped_notifications(session, opts) do
    params =
      opts
      |> Keyword.take([:feed, :limit, :cursor])
      |> Map.new()
      |> AtMcp.ATProto.params()

    case AtMcp.ATProto.grouped_notifications(session, params) do
      {:ok, response} -> grouped(response)
      {:error, reason} -> {:error, failure(reason)}
    end
  end

  # The groups the app shows as a full post, not a line about one.
  @whole_post_kinds ~w(replyNotification quoteNotification mentionNotification)

  # The raw body, camelCase as the service sent it.
  defp grouped(%{"groups" => groups} = response) when is_list(groups) do
    views = related_views(response["relatedViews"])

    {:ok,
     %{
       count: length(groups),
       items: for(%{} = group <- groups, do: notification_group(group, views)),
       cursor: response["cursor"],
       seen_at: response["seenAt"]
     }}
  end

  defp grouped(other),
    do: {:error, unreadable("grouped notifications", if(is_map(other), do: other, else: %{}))}

  # The related views by what names them: a profile by DID, anything else by
  # its uri.
  defp related_views(views) when is_list(views) do
    Map.new(
      for %{} = view <- views, key = view["did"] || view["uri"], is_binary(key), do: {key, view}
    )
  end

  defp related_views(_views), do: %{}

  defp notification_group(group, views) do
    kind = if is_map(group["kind"]), do: group["kind"], else: %{}
    items = for %{} = item <- List.wrap(kind["items"]), do: item

    actors =
      ([%{"actor" => kind["actor"], "starterPack" => kind["starterPack"]}] ++ items)
      |> Enum.filter(&is_binary(&1["actor"]))
      |> Enum.uniq_by(& &1["actor"])
      |> Enum.map(fn item ->
        view = Map.get(views, item["actor"], %{})

        %{
          "did" => item["actor"],
          "handle" => view["handle"],
          "displayName" => view["displayName"],
          "starterPack" => if(is_map_key(item, "post"), do: nil, else: item["starterPack"])
        }
      end)

    # A reply, quote or mention names no actor: its post's author acted.
    actors =
      with [] <- actors,
           %{"did" => did} = author when is_binary(did) <-
             get_in(views, [kind["post"], "author"]) do
        [%{"did" => did, "handle" => author["handle"], "displayName" => author["displayName"]}]
      else
        _ -> actors
      end

    whole? = kind_name(kind["$type"]) in @whole_post_kinds

    posts =
      ([%{"post" => kind["post"], "viaRepost" => kind["viaRepost"]}] ++ items)
      |> Enum.filter(&is_binary(&1["post"]))
      |> Enum.map(fn item ->
        %{
          "uri" => item["post"],
          "author" => get_in(views, [item["post"], "author", "handle"]),
          # Read as a post's text is anywhere: links at their destination,
          # each mention with the DID it links to.
          "text" => post_text(get_in(views, [item["post"], "record"])),
          "viaRepost" => item["viaRepost"],
          "parent" => item["parent"],
          "post" => if(whole?, do: whole_post(Map.get(views, item["post"])))
        }
      end)

    AtMcp.Summary.extract(:notification_group, %{
      "id" => group["id"],
      "kind" => kind_name(kind["$type"]),
      "count" => group["count"],
      "isRead" => group["isRead"],
      "indexedAt" => group["indexedAt"],
      "actors" => actors,
      "posts" => posts,
      "parent" => if(is_binary(kind["post"]), do: kind["parent"]),
      "starterPack" =>
        kind["starterPack"] ||
          Enum.find_value(items, &if(is_binary(&1["starterPack"]), do: &1["starterPack"])),
      "generator" => kind["generator"]
    })
  end

  # A related post view read as any other read's post view is: snakelized, as
  # the XRPC client returns every other response.
  defp whole_post(%{"record" => %{}} = view), do: ProtoRune.Case.snakelize_enum(view)
  defp whole_post(_view), do: nil

  defp post_text(%{"text" => text} = record) do
    {rendered, _facets} = AtMcp.RichText.render(text, record["facets"])
    rendered
  end

  defp post_text(_record), do: nil

  # `...notification.getGroupedNotifications#likeGroup` is `likeGroup`.
  defp kind_name(type) when is_binary(type), do: type |> String.split("#") |> List.last()
  defp kind_name(_type), do: nil

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

  # How the app reads a thread (social-app `usePostThread` at 62b95002, its
  # `const.ts` and `useThreadPreferences.ts`): `getPostThreadV2` with every
  # parent, the account's thread sort (`threadViewPref.sort`, "top" when it
  # has none), and its view. The linear view, the default, reads 10 levels of
  # replies and one reply per post below the first level; the tree view reads
  # 4 levels (6 on a wide web page) and the service's default of 10. Every
  # direct reply to the post comes back whatever the breadth (the lexicon's
  # note on `branchingFactor`), in the service's order for the sort.
  @thread_views %{linear: %{depth: 10, breadth: 1}, tree: %{depth: 4, breadth: 10}}

  # What `unspecced.getPostThreadV2` accepts: `below` 0-20, `branchingFactor`
  # 0-100.
  @thread_limits %{depth: 20, breadth: 100}

  @doc "The levels and breadth `get_thread/3` may be asked for, and how the app reads by default."
  def thread_shape, do: Map.merge(@thread_limits, %{views: @thread_views})

  @impl true
  def get_thread(session, uri, opts \\ []) when is_binary(uri) do
    %{sort: sort, tree_view: tree?} = thread_preferences(session)
    view = if tree?, do: :tree, else: :linear
    depth = Keyword.get(opts, :depth) || @thread_views[view].depth
    breadth = Keyword.get(opts, :breadth) || @thread_views[view].breadth

    case AtMcp.ATProto.get_post_thread_v2(session, %{
           anchor: uri,
           above: true,
           below: depth,
           branchingFactor: breadth,
           sort: sort
         }) do
      {:ok, thread} ->
        {:ok,
         thread
         |> summarize_thread()
         |> Map.put(:context, %{depth: depth, breadth: breadth, sort: sort, view: view})}

      {:error, reason} ->
        {:error, failure(reason)}
    end
  end

  # Reads the account's thread settings. If the read fails, get_thread
  # falls back to the defaults the app uses for an account with no settings.
  defp thread_preferences(session) do
    case stored_preferences(session) do
      {:ok, preferences} -> AtMcp.Preferences.kind_view(preferences, "threads")
      {:error, _} -> AtMcp.Preferences.kind_view([], "threads")
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

  `include_replies: false` reads only that chain using native depth zero.
  The default also reads direct replies. A chain-only result carries no
  replies even if a service returns them despite the requested depth.

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
    case {Keyword.get(opts, :before), Keyword.get(opts, :include_replies, true)} do
      {_, include} when not is_boolean(include) -> {:error, :invalid_include_replies}
      {nil, false} -> chain_ending_at(session, uri, 0, :chain_only)
      {nil, true} -> chain_ending_at(session, uri, @chain_depth, :with_replies)
      {before, _} when is_binary(before) -> chain_ending_at(session, before, 0, :chain_only)
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

  # The network's policy pages are web pages, read with no credential of the
  # account (`AtMcp.PolicyPage`).
  @impl true
  def get_policy(_session, page) do
    case AtMcp.Network.policy_url(page) do
      nil ->
        {:error, AtMcp.Effects.Failure.new(:refused, detail: :policies_not_published)}

      url ->
        with {:ok, %{title: title, text: text}} <- AtMcp.PolicyPage.read(url),
             do: {:ok, %{page: page, title: title, url: url, text: text}}
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

  # A list block is a record in this account's repository naming the list in
  # DID form, which is what the AppView matches (`agent.blockModList`). The
  # list is read first: the app offers a block for a moderation list alone.
  # The blocks this account has are read from its PDS, so one the AppView has
  # not indexed yet is found too, and a second is not written beside it.
  def prepare_list_write(session, {:block_list, uri}) do
    with {:ok, commit} <- latest_commit(session),
         {:ok, list} <- viewed_list(session, uri, "uri"),
         :ok <- moderation_list(list, "block"),
         {:ok, existing} <-
           own_records(session, :list_block, &(string_value(&1, :subject) == uri)) do
      result = %{action: :block_list, list: uri, name: string_value(list, :name)}

      case existing do
        [first | _] ->
          prepared([], Map.merge(result, %{uri: first, unchanged: true}))

        [] ->
          [rkey] = AtMcp.ATProto.tids(1)

          prepared(
            [new_record(:list_block, rkey, AtMcp.ATProto.list_block_record(subject: uri))],
            Map.put(result, :uri, own_uri(session, :list_block, rkey)),
            swap_commit: commit
          )
      end
    end
  end

  # Every list block of this account's that names the list goes, in one
  # commit over the one the reads began at, so a list stays blocked by none.
  # A list block named by its own URI is read for the list it names.
  def prepare_list_write(session, {:unblock_list, uri}) do
    {:ok, {_repo, collection, _rkey}} = AtMcp.ATProto.parse_uri(uri)

    with {:ok, commit} <- latest_commit(session),
         {:ok, list} <-
           (if AtMcp.Network.collection?(collection, :list_block) do
              with {:ok, block} <- own_value(session, uri, "uri", "list block") do
                case string_value(block, :subject) do
                  list when is_binary(list) -> {:ok, list}
                  _ -> {:error, unreadable("a list block record", block)}
                end
              end
            else
              {:ok, uri}
            end),
         {:ok, existing} <-
           own_records(session, :list_block, &(string_value(&1, :subject) == list)) do
      case existing do
        [] ->
          prepared([], %{
            action: :unblock_list,
            list: list,
            uri: nil,
            deleted: [],
            unchanged: true,
            note: "This account has no list block naming #{list}, so nothing was deleted."
          })

        [first | _] ->
          prepared(
            Enum.map(existing, &removal/1),
            %{action: :unblock_list, list: list, uri: first, deleted: existing},
            swap_commit: commit
          )
      end
    end
  end

  # The app offers muting and blocking for moderation lists alone (its list
  # screen shows them only when `purpose` is `modlist`).
  defp moderation_list(list, verb) do
    case purpose_name(string_value(list, :purpose)) do
      "moderation" ->
        :ok

      purpose ->
        {:error,
         {:invalid_argument, "uri",
          "#{string_value(list, :uri)} is a #{purpose} list; the app offers #{verb} only for a moderation list"}}
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
          "#{rest}#{said}.",
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
  defp viewed_list(session, uri, field \\ "list") do
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
             {:invalid_argument, field,
              "no starter pack or list at #{uri} could be read; it may be deleted"}}

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

  `facets: :none` publishes the text exactly as given, with no facets: no
  handle is resolved and nothing in it becomes a mention, link or tag. The
  default, `:detect`, builds them with `AtMcp.RichText.build/3`.

  `:images` entries are `%{data: binary, mime_type: String.t(), alt: String.t()}`;
  each is uploaded as a blob before the record is built, because the record
  references a blob rather than carrying one. A quote is an AT URI, whose CID
  is read from the record it names — a strong reference has to be strong, and
  the caller has only the URI.
  """
  @impl true
  def prepare_post(session, text, opts) do
    with :ok <- validate_post_languages(opts),
         {rich_text, unresolved} = rich_text(text, session, Keyword.get(opts, :facets)),
         {opts, link_card} = link_card(opts, rich_text),
         {:ok, opts} <- resolve_references(session, opts),
         {:ok, opts} <- resolve_reply_lists(session, opts),
         {:ok, images} <- upload_images(session, Keyword.get(opts, :images)),
         {:ok, link} <- upload_link_thumb(session, Keyword.get(opts, :link)) do
      record =
        AtMcp.ATProto.post_record(
          text: rich_text.text,
          facets: rich_text.facets,
          langs: Keyword.get(opts, :langs) || get_in(opts, [:reply_ref, :parent_langs]),
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
         declared_root: get_in(opts, [:reply_ref, :declared_root]),
         rkey: rkey,
         gates: gates,
         link_card: link_card
       }}
    else
      {:error, {:referenced_record_unreadable, _uri, _cause}} = error -> error
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

  defp rich_text(text, _session, :none), do: {%{text: text, facets: []}, []}
  defp rich_text(text, session, _detect), do: AtMcp.RichText.build(text, session)

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

        {:ok,
         summary
         |> with_link_card(prepared)
         |> mention_warnings(prepared.unresolved)
         |> root_warning(Map.get(prepared, :declared_root), record)}

      {:error, reason} ->
        {:error, failure(reason)}
    end
  end

  def post(session, text, %{record: record, unresolved: unresolved, reply: reply} = prepared) do
    case create(session, :post, record) do
      {:ok, result} ->
        summary = summarize_write(result, text)
        summary = if reply, do: Map.put(summary, :reply_to, reply), else: summary

        {:ok,
         summary
         |> with_link_card(prepared)
         |> mention_warnings(unresolved)
         |> root_warning(Map.get(prepared, :declared_root), record)}

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
    with record = AtMcp.ATProto.follow_record([subject: did], true),
         {:ok, result} <-
           create_in(session, AtMcp.Network.identity_collection(:follow, true), record) do
      {:ok, Map.merge(summarize_record(result), %{actor: did, action: :follow})}
    else
      {:error, reason} -> {:error, failure(reason)}
    end
  end

  @impl true
  def block(session, "did:" <> _ = did) do
    with record = AtMcp.ATProto.block_record([subject: did], true),
         {:ok, result} <-
           create_in(session, AtMcp.Network.identity_collection(:block, true), record) do
      {:ok, Map.merge(summarize_record(result), %{actor: did, action: :block})}
    else
      {:error, reason} -> {:error, failure(reason)}
    end
  end

  @impl true
  def viewer_record(session, action, subject) when action in [:like, :repost] do
    with {:ok, %{record: record}} <- subject_view(session, action, subject), do: {:ok, record}
  end

  def viewer_record(session, action, did) when action in [:follow, :block] do
    read = AtMcp.ATProto.get_profile(session, %{actor: did})

    with {:ok, uri} <-
           viewer_field(read, nil, if(action == :follow, do: :following, else: :blocking)),
         do: confirmed(session, uri, did)
  end

  # The one read before a like or repost: the subject's view, which names this
  # account's record of it (`viewer.like`, `viewer.repost`) and carries the
  # subject's current CID. A subject the AppView has no view of has neither.
  @impl true
  def subject_view(session, action, subject) when action in [:like, :repost] do
    case AtMcp.ATProto.parse_uri(subject) do
      {:ok, {repo, collection, _rkey}} ->
        {read, key} =
          cond do
            AtMcp.Network.collection?(collection, :generator) ->
              {AtMcp.ATProto.get_feed_generators(session, [subject]), :feeds}

            AtMcp.Network.collection?(collection, :labeler) ->
              {AtMcp.ATProto.get_services(session, [repo]), :views}

            true ->
              {AtMcp.ATProto.get_posts(session, [subject]), :posts}
          end

        with {:ok, uri} <- viewer_field(read, key, action),
             {:ok, record} <- confirmed(session, uri, subject) do
          {:ok, %{record: record, cid: view_cid(read, key)}}
        end

      {:error, reason} ->
        {:error, failure(reason)}
    end
  end

  defp view_cid({:ok, response}, key) do
    with [view | _] <- field(response, key),
         cid when is_binary(cid) <- field(view, :cid),
         do: cid,
         else: (_ -> nil)
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
  def prepare_undo(session, action, uri) when action in [:unfollow, :unblock] do
    kind = Map.fetch!(@undo_kinds, action)

    with {:ok, {repo, collection, rkey}} <- AtMcp.ATProto.parse_uri(uri),
         :ok <- require_record_kind(collection, kind, action),
         true <- AtMcp.Interactions.own_repo?(session, repo),
         {:ok, commit} <- latest_commit(session),
         {:ok, record} <- relationship_source(session, collection, rkey) do
      if is_nil(record) do
        {:ok, {:unchanged, undo_summary(%{action: action, uri: uri, unchanged: true})}}
      else
        with subject when is_binary(subject) <- undo_subject(field(record, :value)),
             {:ok, records} <- relationship_inventory(session, kind, subject),
             true <-
               Enum.any?(
                 records,
                 &(&1.uri == "at://#{session.did}/#{collection}/#{rkey}" and
                     &1.cid == field(record, :cid))
               ),
             {:ok, ^commit} <- latest_commit(session),
             :ok <- relationship_batch_size(records) do
          {:ok,
           %{
             action: action,
             uri: uri,
             deleted: Enum.map(records, & &1.uri),
             records: records,
             repo: session.did,
             commit: commit
           }}
        else
          {:error, reason} -> {:error, failure(reason)}
          _ -> {:error, changed_meanwhile("The relationship inventory")}
        end
      end
    else
      false ->
        {:error,
         AtMcp.Effects.Failure.new(:refused,
           message: "Only this account's relationships can be removed."
         )}

      {:error, reason} ->
        {:error, failure(reason)}

      _ ->
        {:error, unreadable("the relationship", %{})}
    end
  end

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

  defp relationship_batch_size(records) do
    if length(records) <= AtMcp.ATProto.max_writes() do
      :ok
    else
      {:error,
       AtMcp.Effects.Failure.new(:refused,
         message:
           "There are too many matching relationship records to remove atomically. Nothing was deleted."
       )}
    end
  end

  defp relationship_source(session, collection, rkey) do
    case AtMcp.ATProto.get_record(session, %{
           repo: session.did,
           collection: collection,
           rkey: rkey
         }) do
      {:error, %ProtoRune.XRPC.Error{reason: reason}}
      when reason in [:record_not_found, "record_not_found"] ->
        {:ok, nil}

      result ->
        result
    end
  end

  defp relationship_inventory(session, kind, subject) do
    collections = AtMcp.Network.relationship_collections(kind)

    Enum.reduce_while(collections, {:ok, []}, fn collection, {:ok, records} ->
      case relationship_page(session, collection, subject, nil, @own_record_pages, []) do
        {:ok, found} -> {:cont, {:ok, records ++ found}}
        error -> {:halt, error}
      end
    end)
  end

  defp relationship_page(_session, _collection, _subject, _cursor, 0, _found),
    do:
      {:error,
       AtMcp.Effects.Failure.new(:refused,
         message: "Relationship inventory exceeds the supported page limit. Nothing was deleted."
       )}

  defp relationship_page(session, collection, subject, cursor, pages, found) do
    params =
      AtMcp.ATProto.params(%{
        repo: session.did,
        collection: collection,
        limit: 100,
        cursor: cursor
      })

    with {:ok, response} <- AtMcp.ATProto.list_records(session, params),
         records when is_list(records) <- field(response, :records) do
      matching =
        for record <- records,
            undo_subject(field(record, :value)) == subject,
            do: %{uri: field(record, :uri), cid: field(record, :cid)}

      valid =
        Enum.all?(matching, fn record ->
          case AtMcp.ATProto.parse_uri(record.uri || "") do
            {:ok, {did, ^collection, _}} -> did == session.did and is_binary(record.cid)
            _ -> false
          end
        end)

      if valid and length(Enum.uniq_by(found ++ matching, & &1.uri)) == length(found ++ matching) do
        case cursor_of(response) do
          next when is_binary(next) and next != cursor and records != [] ->
            relationship_page(session, collection, subject, next, pages - 1, found ++ matching)

          nil ->
            {:ok, found ++ matching}

          _ ->
            {:error, unreadable("the relationship inventory cursor", response)}
        end
      else
        {:error, unreadable("the relationship inventory", response)}
      end
    else
      {:error, reason} -> {:error, failure(reason)}
      _ -> {:error, unreadable("the relationship inventory", %{})}
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
  # The prepared DID and commit are immutable. A new login or a concurrent
  # repository write cannot turn this removal into a different operation.
  @impl true
  def undo(session, %{repo: repo, commit: commit, deleted: deleted} = prepared) do
    if session.did != repo do
      {:error,
       AtMcp.Effects.Failure.new(:refused,
         message: "The prepared removal belongs to another account."
       )}
    else
      case AtMcp.ATProto.apply_writes(session, repo, Enum.map(deleted, &removal/1),
             swap_commit: commit
           ) do
        {:ok, _} ->
          {:ok, undo_summary(prepared)}

        {:error, %ProtoRune.XRPC.Error{reason: reason}}
        when reason in [:invalid_swap, "invalid_swap"] ->
          {:error, changed_meanwhile("The relationships")}

        {:error, reason} ->
          {:error, failure(reason)}
      end
    end
  end

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

  # put_record and delete_record read the current record first, then send
  # its CID as swapRecord. The server refuses the write if the record changed
  # in between.
  @impl true
  def prepare_record_write(_session, {:put, collection, nil, record, nil}),
    do: {:ok, %{op: :create, collection: collection, rkey: nil, record: record}}

  def prepare_record_write(session, {:put, collection, rkey, record, cid}) do
    with {:ok, current} <- current_record(session, collection, rkey),
         :ok <- still_at(current, cid, session, collection, rkey) do
      {:ok, %{op: :put, collection: collection, rkey: rkey, record: record, swap: current}}
    end
  end

  def prepare_record_write(session, {:delete, collection, rkey, cid}) do
    case current_record(session, collection, rkey) do
      {:ok, nil} ->
        {:ok,
         {:unchanged,
          %{
            ok: true,
            action: :delete_record,
            uri: record_uri(session, collection, rkey),
            unchanged: true
          }}}

      {:ok, current} ->
        with :ok <- still_at(current, cid, session, collection, rkey),
             do: {:ok, %{op: :delete, collection: collection, rkey: rkey, swap: current}}

      error ->
        error
    end
  end

  @impl true
  def write_record(session, %{op: :delete} = prepared) do
    params = %{
      repo: session.did,
      collection: prepared.collection,
      rkey: prepared.rkey,
      swap_record: prepared.swap
    }

    case AtMcp.ATProto.delete_record(session, params) do
      {:ok, _} ->
        {:ok,
         %{
           ok: true,
           action: :delete_record,
           uri: record_uri(session, prepared.collection, prepared.rkey)
         }}

      error ->
        record_write_error(error, session, prepared)
    end
  end

  def write_record(session, prepared) do
    case AtMcp.ATProto.write_record_as_given(session, prepared) do
      {:ok, response} ->
        {:ok,
         %{
           ok: true,
           action: :put_record,
           uri: string_value(response, :uri),
           cid: string_value(response, :cid),
           replaced: is_binary(prepared[:swap])
         }}

      error ->
        record_write_error(error, session, prepared)
    end
  end

  defp record_write_error({:error, %ProtoRune.XRPC.Error{reason: reason}}, session, prepared)
       when reason in [:invalid_swap, "invalid_swap"],
       do:
         {:error,
          changed_meanwhile(
            "The record at #{record_uri(session, prepared.collection, prepared.rkey)}"
          )}

  defp record_write_error({:error, reason}, _session, _prepared), do: {:error, failure(reason)}

  # The CID of the record at collection/rkey in this account's repository, or
  # nil when there is none.
  defp current_record(session, collection, rkey) do
    case AtMcp.ATProto.get_record_as_stored(session, %{
           repo: session.did,
           collection: collection,
           rkey: rkey
         }) do
      {:ok, %{"cid" => cid}} when is_binary(cid) ->
        {:ok, cid}

      {:ok, other} ->
        {:error, unreadable("a record", other)}

      {:error, :unreadable_record} ->
        {:error, unreadable("a record", %{})}

      {:error, reason} ->
        uri = record_uri(session, collection, rkey)

        case not_found_or_failure(reason, "record", uri) do
          %AtMcp.Effects.Failure{detail: {:not_found, _, _}} -> {:ok, nil}
          failure -> {:error, failure}
        end
    end
  end

  # If the caller passed a cid, the write goes ahead only when the current
  # record still has that cid.
  defp still_at(_current, nil, _session, _collection, _rkey), do: :ok
  defp still_at(cid, cid, _session, _collection, _rkey), do: :ok

  defp still_at(_current, _cid, session, collection, rkey),
    do: {:error, changed_meanwhile("The record at #{record_uri(session, collection, rkey)}")}

  defp record_uri(session, collection, rkey), do: "at://#{session.did}/#{collection}/#{rkey}"

  @impl true
  def get_own_profile(session) do
    if AtMcp.Network.name() == :delve do
      with {:ok, snapshot} <- town_profile_snapshot(session),
           do: {:ok, %{value: snapshot.value}}
    else
      with {:ok, record} <- stored_profile(session, AtMcp.Network.collection(:profile)),
           do: {:ok, %{value: record.value}}
    end
  end

  @impl true
  def update_profile(session, updates) when is_list(updates) do
    if AtMcp.Network.name() == :delve,
      do: update_town_profile(session, updates),
      else: update_network_profile(session, updates)
  end

  defp update_town_profile(session, updates) do
    if Keyword.has_key?(updates, :links) do
      {:error,
       AtMcp.Effects.Failure.new(:refused,
         message: "Town does not serve profile links. Nothing was written."
       )}
    else
      with {:ok, snapshot} <- town_profile_snapshot(session),
           {:ok, blobs} <- upload_profile_images(session, updates) do
        safe = Keyword.take(updates, [:display_name, :description, :pronouns, :website])
        labels = Keyword.fetch(updates, :labels)

        # Presentation is the Town record's; self-labels, such as the bot
        # declaration, stay on the shared profile, which the reader prefers
        # for them. Both writes go in one commit over the one read, so the
        # call changes both or neither.
        town_write =
          if safe != [] or blobs != %{} do
            record =
              snapshot.value
              |> merge_profile_fields(safe)
              |> Map.put("presentation", true)
              |> AtMcp.ATProto.profile_record(blobs)

            [{snapshot.operation, AtMcp.Network.collection(:profile), "self", record}]
          else
            []
          end

        writes = town_write ++ shared_labels_write(snapshot.shared, labels)

        uri =
          case writes do
            [{_op, collection, _rkey, _record} | _] -> "at://#{session.did}/#{collection}/self"
            [] -> nil
          end

        result =
          if writes == [],
            do: {:ok, :unchanged},
            else:
              AtMcp.ATProto.apply_writes(session, session.did, writes,
                swap_commit: snapshot.commit,
                preserve_record_keys: true
              )

        case result do
          {:ok, _} ->
            {:ok,
             %{
               ok: true,
               action: :update_profile,
               display_name: Keyword.get(safe, :display_name),
               description: Keyword.get(safe, :description),
               pronouns: Keyword.get(safe, :pronouns),
               website: Keyword.get(safe, :website),
               labels: Keyword.get(updates, :labels),
               uri: uri
             }
             |> Map.merge(Map.new(blobs, fn {key, blob} -> {:"#{key}_cid", blob_cid(blob)} end))}

          {:error, %ProtoRune.XRPC.Error{reason: reason}}
          when reason in [:invalid_swap, "invalid_swap"] ->
            {:error, changed_meanwhile("The profile")}

          {:error, reason} ->
            {:error, failure(reason)}
        end
      else
        {:error, reason} -> {:error, failure(reason)}
      end
    end
  end

  # Presentation ownership is signed into the Town profile. Unmarked historical
  # profiles are selected by the server's finite continuity record, never by
  # graph activation. Its exact source CID must still match the repository.
  defp town_profile_snapshot(session) do
    local = AtMcp.Network.collection(:profile)
    shared = AtMcp.Network.identity_collection(:profile, true)

    with {:ok, commit} <- latest_commit(session),
         {:ok, town} <- stored_profile(session, local),
         {:ok, external} <- stored_profile(session, shared),
         {:ok, presentation, view} <- selected_presentation(session, town, external),
         {:ok, ^commit} <- latest_commit(session) do
      value =
        town.value
        |> Map.drop(["displayName", "description", "avatar"])
        |> Map.merge(Map.take(presentation, ["displayName", "description", "avatar"]))

      with {:ok, value} <- initial_town_banner(town.operation, value, presentation, view) do
        {:ok, %{value: value, operation: town.operation, commit: commit, shared: external}}
      end
    else
      {:error, reason} -> {:error, failure(reason)}
      _ -> {:error, changed_meanwhile("The profile")}
    end
  end

  # The shared profile with only its self-labels replaced, every other field
  # kept as stored. With none to remove and no record, nothing is written.
  defp shared_labels_write(_shared, :error), do: []
  defp shared_labels_write(%{operation: :create}, {:ok, []}), do: []

  defp shared_labels_write(shared, {:ok, values}) do
    collection = AtMcp.Network.identity_collection(:profile, true)

    record =
      shared.value
      |> with_self_labels({:ok, values})
      |> Map.put("$type", collection)

    [{shared.operation, collection, "self", record}]
  end

  defp selected_presentation(_session, %{value: %{"presentation" => true}} = town, _shared),
    do: {:ok, town.value, nil}

  defp selected_presentation(session, town, shared) do
    with {:ok, view} <- AtMcp.ATProto.get_profile(session, %{actor: session.did}) do
      case field(view, :profile_source) do
        nil ->
          {:ok, %{}, view}

        source when is_map(source) ->
          case Enum.find(
                 [town, shared],
                 &(&1.uri == field(source, :uri) and &1.cid == field(source, :cid) and
                     is_binary(&1.cid))
               ) do
            nil -> {:error, changed_meanwhile("The displayed profile source")}
            record -> {:ok, record.value, view}
          end

        _ ->
          {:error, unreadable("the displayed profile source", view)}
      end
    end
  end

  # Existing Town records own their banner, including its absence. Only the
  # first Town record preserves a shared banner that the AppView actually shows.
  defp initial_town_banner(:update, value, _presentation, _view), do: {:ok, value}

  defp initial_town_banner(:create, value, presentation, view) do
    case field(view, :banner) do
      nil ->
        {:ok, Map.delete(value, "banner")}

      url when is_binary(url) ->
        blob = Map.get(presentation, "banner")

        cid = if is_map(blob), do: blob_cid(blob)

        if is_binary(cid) and displayed_blob_cid(url) == cid,
          do: {:ok, Map.put(value, "banner", blob)},
          else: {:error, changed_meanwhile("The displayed profile banner")}

      _ ->
        {:error, unreadable("the displayed profile banner", view)}
    end
  end

  defp displayed_blob_cid(url) do
    with %URI{path: path} when is_binary(path) <- URI.parse(url),
         filename when is_binary(filename) <- path |> String.split("/") |> List.last(),
         [cid | _] <- String.split(filename, "@", parts: 2),
         true <- cid != "" do
      URI.decode(cid)
    else
      _ -> nil
    end
  end

  defp stored_profile(session, collection) do
    uri = "at://#{session.did}/#{collection}/self"

    case AtMcp.ATProto.get_record_as_stored(session, %{
           repo: session.did,
           collection: collection,
           rkey: "self"
         }) do
      {:ok, %{"uri" => ^uri, "cid" => cid, "value" => value}}
      when is_binary(cid) and is_map(value) ->
        {:ok, %{uri: uri, cid: cid, value: value, operation: :update}}

      {:ok, response} ->
        {:error, unreadable("the stored profile", response)}

      {:error, %ProtoRune.XRPC.Error{reason: reason}}
      when reason in [:not_found, :record_not_found, "record_not_found"] ->
        {:ok, %{uri: uri, cid: nil, value: %{}, operation: :create}}

      {:error, reason} ->
        {:error, failure(reason)}
    end
  end

  defp update_network_profile(session, updates) do
    safe = Keyword.take(updates, [:display_name, :description, :pronouns, :website])

    with {:ok, current, swap} <- current_profile(session),
         {:ok, plan} <- links_plan(session, current, Keyword.fetch(updates, :links)),
         {:ok, blobs} <- upload_profile_images(session, updates),
         {:ok, links} <- create_links(session, plan),
         record =
           current
           |> merge_profile(safe)
           |> with_links(links)
           |> with_self_labels(Keyword.fetch(updates, :labels))
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
         labels: Keyword.get(updates, :labels),
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

  defp with_self_labels(record, :error), do: record
  defp with_self_labels(record, {:ok, []}), do: Map.drop(record, ["labels", :labels])

  defp with_self_labels(record, {:ok, values}),
    do: record |> Map.drop([:labels]) |> Map.put("labels", AtMcp.ATProto.self_labels(values))

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
  # makes the service refuse instead. With no record read, the swap is null:
  # the PDS then refuses a profile created meanwhile (`put_record/2`).
  defp put_profile(session, record, swap) do
    params = %{
      repo: session.did,
      collection: AtMcp.Network.collection(:profile),
      rkey: "self",
      record: record,
      swap_record: swap
    }

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
      message: "#{what} changed between reading it and writing it, so nothing was written.",
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
    with {:ok, preferences} <- stored_preferences(session),
         do: {:ok, saved_feeds(preferences, verb, uri, pinned)}
  end

  defp stored_preferences(session) do
    case AtMcp.ATProto.preferences_as_stored(session) do
      {:ok, preferences} -> {:ok, preferences}
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

  # --- settings: preferences, declarations, notification settings ---

  @impl true
  def get_preferences(session) do
    with {:ok, preferences} <- stored_preferences(session),
         {:ok, discoverable, _cid} <- declaration(session, "discoverable"),
         {:ok, subscriptions, _cid} <- declaration(session, "activity_subscriptions") do
      {:ok,
       preferences
       |> AtMcp.Preferences.view()
       |> Map.merge(%{
         saved_feeds: saved_feed_view(preferences),
         app_pinned_feeds: app_pinned_feed_view(),
         discoverable: AtMcp.Preferences.record_view("discoverable", discoverable),
         activity_subscriptions:
           AtMcp.Preferences.record_view("activity_subscriptions", subscriptions)
       })}
    end
  end

  # The saved feeds as the app shows them: the second version's, or, for an
  # account that has none yet, the first version's as the app migrates them.
  defp saved_feed_view(preferences) do
    items =
      case preferences |> Enum.reverse() |> Enum.find(&saved_v2?/1) do
        nil -> migrated(preferences)
        current -> current["items"]
      end

    for %{} = item <- items,
        do: %{type: item["type"], value: item["value"], pinned: item["pinned"] == true}
  end

  # The feeds the network's app pins for every account, in the saved feeds'
  # shape. They come from `AtMcp.Network`, not from the preferences read.
  defp app_pinned_feed_view,
    do:
      for(uri <- AtMcp.Network.app_pinned_feeds(), do: %{type: "feed", value: uri, pinned: true})

  # One of the account's declaration records, as stored, and its CID; nil and
  # nil when the account has none.
  defp declaration(session, kind) do
    {collection, _field} = AtMcp.Preferences.record(kind)

    case AtMcp.ATProto.get_record_as_stored(session, %{
           repo: session.did,
           collection: AtMcp.Network.collection(collection),
           rkey: "self"
         }) do
      {:ok, %{"value" => value} = response} when is_map(value) ->
        {:ok, value, response["cid"]}

      {:ok, response} ->
        {:error, unreadable("the account's #{collection} record", response)}

      {:error, :unreadable_record} ->
        {:error, unreadable("the account's #{collection} record", %{})}

      {:error, %ProtoRune.XRPC.Error{reason: reason}}
      when reason in [:not_found, :record_not_found] ->
        {:ok, nil, nil}

      {:error, reason} ->
        {:error, failure(reason)}
    end
  end

  @doc """
  Read what a `set_preference` request changes and build the change. A
  preference kind is changed in the preferences as stored
  (`AtMcp.Preferences.change/3`) and written back whole, which the result's
  note says; a record kind is written over the record read, with
  `swapRecord`. Either way the result names the fields that changed, with the
  kind's values before and after.
  """
  @impl true
  def prepare_preference(session, {kind, changes}) do
    case AtMcp.Preferences.record(kind) do
      nil -> prepare_preference_change(session, kind, changes)
      {collection, _field} -> prepare_declaration(session, kind, collection, changes)
    end
  end

  defp prepare_preference_change(session, kind, changes) do
    with {:ok, changes} <- default_reply_lists(session, changes),
         {:ok, preferences} <- stored_preferences(session),
         :ok <- adult_content_shown(kind, changes, preferences),
         :ok <- interests_offered(kind, changes, preferences) do
      before = AtMcp.Preferences.kind_view(preferences, kind)
      updated = AtMcp.Preferences.change(preferences, kind, changes)
      result = setting_result(kind, before, AtMcp.Preferences.kind_view(updated, kind))

      if result.unchanged,
        do: {:ok, {:unchanged, result}},
        else: {:ok, %{preferences: updated, result: Map.put(result, :note, @no_swap)}}
    end
  end

  defp default_reply_lists(session, %{reply_rule: rules} = changes) when is_list(rules) do
    with {:ok, rules} <- resolve_lists(session, rules),
         do: {:ok, %{changes | reply_rule: rules}}
  end

  defp default_reply_lists(_session, changes), do: {:ok, changes}

  # The app turns adult content on only for an account whose declared age is
  # 18 or over (`adultContentDisabled` in social-app's src/ageAssurance/util.ts
  # at 485405a: an account with no declared age counts as under 18), so the
  # setting would show nowhere for any other.
  defp adult_content_shown("adult_content", %{enabled: true}, preferences) do
    if AtMcp.Preferences.declared_over_18(preferences),
      do: :ok,
      else:
        invalid(
          "enabled",
          "the app shows adult content only to an account whose declared age is 18 or over, and this account declares no such age. Its birth date is set in the app's account settings; at_mcp does not set one"
        )
  end

  defp adult_content_shown(_kind, _changes, _preferences), do: :ok

  defp interests_offered("interests", %{tags: tags}, preferences),
    do: AtMcp.Preferences.interests_offered(preferences, tags)

  defp interests_offered(_kind, _changes, _preferences), do: :ok

  defp prepare_declaration(session, kind, collection, changes) do
    with {:ok, current, cid} <- declaration(session, kind) do
      record = AtMcp.Preferences.record_value(kind, current, changes)

      result =
        setting_result(
          kind,
          AtMcp.Preferences.record_view(kind, current),
          AtMcp.Preferences.record_view(kind, record)
        )

      uri = own_uri(session, collection, "self")

      if result.unchanged,
        do: {:ok, {:unchanged, Map.put(result, :uri, if(current, do: uri))}},
        else:
          {:ok,
           %{
             record: record,
             collection: collection,
             swap: cid,
             result: Map.put(result, :uri, uri)
           }}
    end
  end

  defp setting_result(kind, before, now) do
    %{
      ok: true,
      action: :set_preference,
      kind: kind,
      changed: Enum.map(AtMcp.Preferences.changed(kind, before, now), &to_string/1),
      previous: before,
      now: now,
      unchanged: AtMcp.Preferences.changed(kind, before, now) == []
    }
  end

  @impl true
  def write_preference(session, %{preferences: _} = prepared),
    do: write_preferences(session, prepared)

  # Written only over the record read (`swapRecord`); when there was none,
  # only if there still is none (a null swap).
  def write_preference(session, %{record: record, collection: collection, swap: swap} = prepared) do
    params = %{
      repo: session.did,
      collection: AtMcp.Network.collection(collection),
      rkey: "self",
      record: record,
      swap_record: swap
    }

    case AtMcp.ATProto.put_record(session, params) do
      {:ok, _} ->
        {:ok, prepared.result}

      {:error, %ProtoRune.XRPC.Error{reason: reason}}
      when reason in [:invalid_swap, "invalid_swap"] ->
        {:error,
         changed_meanwhile("The account's #{AtMcp.Network.collection(collection)} record")}

      {:error, reason} ->
        {:error, failure(reason)}
    end
  end

  @impl true
  def get_notification_settings(session) do
    with {:ok, settings} <- notification_settings(session),
         do: {:ok, %{settings: AtMcp.Preferences.notification_view(settings)}}
  end

  defp notification_settings(session) do
    case AtMcp.ATProto.notification_preferences(session) do
      {:ok, %{"preferences" => settings}} when is_map(settings) -> {:ok, settings}
      {:ok, %{} = other} -> {:error, unreadable("the notification settings", other)}
      {:ok, :unreadable} -> {:error, unreadable("the notification settings", %{})}
      {:error, reason} -> {:error, failure(reason)}
    end
  end

  @impl true
  def prepare_notification_setting(session, {reason, changes}) do
    with {:ok, settings} <- notification_settings(session) do
      before = AtMcp.Preferences.notification_setting(settings, reason)
      now = Map.merge(before, changes)
      result = notification_result(reason, before, now)

      if result.unchanged,
        do: {:ok, {:unchanged, result}},
        else:
          {:ok,
           %{
             input: AtMcp.Preferences.notification_input(reason, now),
             reason: reason,
             result: result
           }}
    end
  end

  # The service answers with every setting as it now is, so the result says
  # what it keeps rather than what was asked.
  @impl true
  def write_notification_setting(session, %{input: input, reason: reason, result: result}) do
    case AtMcp.ATProto.put_notification_preferences(session, input) do
      {:ok, %{"preferences" => settings}} when is_map(settings) ->
        {:ok,
         notification_result(
           reason,
           result.previous,
           AtMcp.Preferences.notification_setting(settings, reason)
         )}

      {:ok, _other} ->
        {:ok,
         Map.put(
           result,
           :note,
           "The service accepted the change but its answer could not be read, so now is what was sent, not what the service says it keeps."
         )}

      {:error, reason} ->
        {:error, failure(reason)}
    end
  end

  defp notification_result(reason, before, now) do
    %{
      ok: true,
      action: :set_notification_setting,
      reason: reason,
      changed: for(key <- [:include, :list, :push], before[key] != now[key], do: to_string(key)),
      previous: before,
      now: now,
      unchanged: before == now
    }
  end

  # --- activity subscriptions ---

  @doc """
  Read the account `did` for the subscription this account has to its
  activity and for who it lets subscribe, and build the change. The app shows
  the bell on a profile only when the account's `notification.declaration`
  lets this account subscribe (`subscriptionsAllowed` in social-app's
  src/screens/Profile/Header/ProfileHeaderStandard.tsx at 485405a): no
  declaration or `followers` when this account follows it, `mutuals` when
  they follow each other, `none` never. Unsubscribing is always offered.
  """
  @impl true
  def prepare_activity_subscription(session, did, %{posts: posts, replies: replies} = asked) do
    case AtMcp.ATProto.get_profile(session, %{actor: did}) do
      {:ok, profile} ->
        viewer = field(profile, :viewer)
        current = activity_subscription(field(viewer || %{}, :activity_subscription))

        allow =
          AtMcp.Response.dig(profile, [:associated, :activity_subscription, :allow_subscriptions])

        handle = string_value(profile, :handle)

        result = %{
          ok: true,
          action: :subscribe_to_activity,
          actor: did,
          handle: handle,
          previous: current,
          now: asked,
          unchanged: current == asked
        }

        unsubscribe? = not posts and not replies

        cond do
          # An unsubscribe is sent even when the profile shows none: a block
          # hides viewer state, so a subscription may be there unseen, and the
          # service answers an unsubscribe from nothing by doing nothing.
          current == asked and not unsubscribe? ->
            {:ok, {:unchanged, result}}

          posts and not subscriptions_allowed?(allow, viewer) ->
            invalid(
              "actor",
              "#{handle || did} lets #{allowed_who(allow)} subscribe to its posts, so the app offers this account no subscription to it" <>
                block_note(viewer)
            )

          unsubscribe? and current == asked ->
            {:ok,
             %{
               did: did,
               subscription: %{"post" => false, "reply" => false},
               result:
                 Map.put(
                   result,
                   :note,
                   "The profile showed no subscription; the unsubscribe was sent anyway, as a block hides one that may be there."
                 )
             }}

          true ->
            {:ok,
             %{did: did, subscription: %{"post" => posts, "reply" => replies}, result: result}}
        end

      {:error, reason} ->
        {:error, failure(reason)}
    end
  end

  defp activity_subscription(%{} = subscription),
    do: %{
      posts: field(subscription, :post) == true,
      replies: field(subscription, :reply) == true
    }

  defp activity_subscription(_none), do: %{posts: false, replies: false}

  # The AppView leaves follows out of the viewer state across a block, so
  # "does not follow" may be a block's doing.
  defp block_note(viewer) do
    viewer = viewer || %{}

    if present?(field(viewer, :blocking)) or field(viewer, :blocked_by) == true or
         present?(field(viewer, :blocking_by_list)),
       do:
         ". A block between the two accounts may be why: the service does not show follows across one",
       else: ""
  end

  defp subscriptions_allowed?(allow, viewer) when allow in [nil, "followers"],
    do: present?(field(viewer || %{}, :following))

  defp subscriptions_allowed?("mutuals", viewer),
    do:
      present?(field(viewer || %{}, :following)) and present?(field(viewer || %{}, :followed_by))

  defp subscriptions_allowed?(_none, _viewer), do: false

  defp present?(value), do: is_binary(value) and value != ""

  defp allowed_who(allow) when allow in [nil, "followers"],
    do: "only accounts that follow it, and this account does not,"

  defp allowed_who("mutuals"),
    do: "only accounts it follows back, and the two do not follow each other,"

  defp allowed_who("none"), do: "no one"
  defp allowed_who(other), do: "only #{other}"

  @impl true
  def put_activity_subscription(session, %{did: did, subscription: subscription, result: result}) do
    case AtMcp.ATProto.put_activity_subscription(session, did, subscription) do
      {:ok, %{"subject" => _} = answer} ->
        {:ok,
         %{result | now: activity_subscription(answer["activitySubscription"]), unchanged: false}}

      {:ok, _other} ->
        {:ok,
         Map.put(
           result,
           :note,
           "The service accepted the change but its answer could not be read, so now is what was sent, not what the service says it keeps."
         )}

      {:error, reason} ->
        {:error, failure(reason)}
    end
  end

  @impl true
  def get_activity_subscriptions(session, opts) do
    session
    |> AtMcp.ATProto.list_activity_subscriptions(paging(opts, %{}))
    |> read(:subscriptions, &summarize_profile/1)
  end

  # --- moderation: reports, muted words, moderation lists, labelers ---

  @doc """
  Read what a report names and build it as the app's report dialog builds it
  (`useSubmitReportMutation` in social-app's ReportDialog/action.ts at
  485405a): the service must be one this account takes labels from (the
  dialog lists those alone), must take reports on this kind of subject, this
  record type and this reason (`subjectTypes`, `subjectCollections`,
  `reasonTypes` on its labeler view, each unlimited when absent), and gets the
  first-version reason when it declares that and not the finer one. A record
  is read for its CID. Nothing is sent here.
  """
  @impl true
  def prepare_report(session, %{subject: subject, reason: reason, labeler: labeler} = request) do
    with {:ok, preferences} <- stored_preferences(session),
         :ok <- report_service_offered(labeler, preferences),
         {:ok, view} <- labeler_view(session, labeler, "labeler"),
         :ok <- own_service_reason(reason, labeler),
         {:ok, ref, kind, collection} <- report_subject_ref(session, subject),
         {:ok, reason_type} <- report_accepted(view, kind, collection, reason) do
      input =
        %{"reasonType" => reason_type, "subject" => ref}
        |> then(&if(request.details, do: Map.put(&1, "reason", request.details), else: &1))

      {:ok,
       %{
         labeler: labeler,
         input: input,
         result: %{
           ok: true,
           action: :report,
           labeler: labeler,
           labeler_handle: get_in(view, ["creator", "handle"]),
           subject: report_subject_name(subject),
           reason: reason,
           reason_type: reason_type
         }
       }}
    end
  end

  defp report_service_offered(labeler, preferences) do
    if labeler in AtMcp.Moderation.labelers(preferences),
      do: :ok,
      else:
        {:error,
         {:invalid_argument, "labeler",
          "this account does not subscribe to #{labeler}; the app's report dialog offers the moderation services an account subscribes to and #{AtMcp.Network.label()}'s own"}}
  end

  defp own_service_reason(reason, labeler) do
    if AtMcp.Moderation.own_service_only?(reason) and
         labeler != AtMcp.Network.moderation_service(),
       do:
         {:error,
          {:invalid_argument, "labeler",
           "the app sends #{reason} reports to #{AtMcp.Network.label()}'s own moderation service alone; leave labeler out"}},
       else: :ok
  end

  defp report_subject_ref(_session, {:account, did}),
    do:
      {:ok, %{"$type" => "com.atproto.admin.defs#repoRef", "did" => did}, "account",
       AtMcp.Network.collection(:profile)}

  defp report_subject_ref(session, {:record, uri, collection}) do
    with {:ok, _value, cid} <- own_record(session, uri, "subject", "record") do
      if is_binary(cid),
        do:
          {:ok, %{"$type" => "com.atproto.repo.strongRef", "uri" => uri, "cid" => cid}, "record",
           collection},
        else: {:error, unreadable("a record's CID", %{uri: uri})}
    end
  end

  defp report_subject_name({:account, did}), do: did
  defp report_subject_name({:record, uri, _collection}), do: uri

  # The dialog's filters on the services it lists (`supportedLabelers` in
  # ReportDialog/index.tsx). An account's collection is `actor.profile`, as
  # the dialog names it.
  defp report_accepted(view, kind, collection, reason) do
    who = get_in(view, ["creator", "handle"]) || get_in(view, ["creator", "did"])
    types = view["subjectTypes"]
    collections = view["subjectCollections"]

    cond do
      is_list(types) and kind not in types ->
        {:error,
         {:invalid_argument, "labeler",
          "#{who} takes reports on #{Enum.join(types, ", ")}, not on #{if kind == "account", do: "an account", else: "a record"}"}}

      is_list(collections) and collection not in collections ->
        {:error,
         {:invalid_argument, "labeler",
          "#{who} takes reports on #{Enum.join(collections, ", ")} records, not #{collection}"}}

      true ->
        case AtMcp.Moderation.reason_type_for(reason, view["reasonTypes"]) do
          nil ->
            {:error,
             {:invalid_argument, "reason",
              "#{who} does not take #{reason} reports; it takes #{Enum.join(view["reasonTypes"], ", ")}"}}

          type ->
            {:ok, type}
        end
    end
  end

  # The service's answer names the report; it is the moderation service's
  # record of it, so the result says what it says.
  @impl true
  def send_report(session, %{labeler: labeler, input: input, result: result}) do
    note =
      "The moderators of #{result.labeler_handle || labeler} see this report and that this account sent it, and decide what, if anything, to do about it. at_mcp does not publish it, and it cannot be withdrawn."

    case AtMcp.ATProto.create_report(session, labeler, input) do
      {:ok, %{"id" => id} = answer} ->
        {:ok,
         Map.merge(result, %{
           id: id,
           created_at: answer["createdAt"],
           reason_type: answer["reasonType"] || result.reason_type,
           note: note
         })}

      {:ok, _other} ->
        {:ok,
         Map.put(
           result,
           :note,
           note <>
             " The service accepted the report, but its answer could not be read, so it has no id here."
         )}

      {:error, reason} ->
        {:error, failure(reason)}
    end
  end

  # A labeler's detailed view, as the service sent it, or the argument named
  # as one that runs no labeler.
  defp labeler_view(session, did, argument) do
    case labeler_views(session, [did]) do
      {:ok, views} ->
        case Enum.find(views, &(get_in(&1, ["creator", "did"]) == did)) do
          nil ->
            {:error,
             {:invalid_argument, argument,
              "#{did} runs no labeler #{AtMcp.Network.label()}'s AppView knows of"}}

          view ->
            {:ok, view}
        end

      error ->
        error
    end
  end

  defp labeler_views(session, dids) do
    case AtMcp.ATProto.labeler_services(session, dids) do
      {:ok, %{"views" => views}} when is_list(views) -> {:ok, Enum.filter(views, &is_map/1)}
      {:ok, %{} = other} -> {:error, unreadable("labelers", other)}
      {:ok, _} -> {:error, unreadable("labelers", %{})}
      {:error, reason} -> {:error, failure(reason)}
    end
  end

  @impl true
  def moderation_preferences(session), do: stored_preferences(session)

  @impl true
  def labeler_definitions(session, dids), do: labeler_views(session, dids)

  @moderation_note "The app applies this on the device; the service does not, so at_mcp's reads return what it serves either way."

  @doc """
  Read the preferences and build a moderation change of them
  (`AtMcp.Moderation`). Each result names what changed, with what it was and
  what it now is.
  """
  @impl true
  def prepare_moderation_preference(session, {:mute_word, word}) do
    with {:ok, preferences} <- stored_preferences(session) do
      {updated, previous, now} = AtMcp.Moderation.mute_word(preferences, word)

      result = %{
        ok: true,
        action: :mute_word,
        value: word.value,
        previous: Enum.map(previous, &AtMcp.Moderation.word_view/1),
        now: Enum.map(now, &AtMcp.Moderation.word_view/1),
        unchanged: is_nil(updated)
      }

      preference_change(
        updated,
        result,
        if(previous == [],
          do: "unmute_word with this value undoes it. ",
          else:
            "previous holds the muted word as it was; mute_word with its value, targets, only_non_followed and expires_at puts it back. "
        ) <> @moderation_note
      )
    end
  end

  def prepare_moderation_preference(session, {:unmute_word, value}) do
    with {:ok, preferences} <- stored_preferences(session) do
      {updated, removed} = AtMcp.Moderation.unmute_word(preferences, value)

      result = %{
        ok: true,
        action: :unmute_word,
        value: value,
        removed: Enum.map(removed, &AtMcp.Moderation.word_view/1),
        unchanged: is_nil(updated)
      }

      if is_nil(updated),
        do:
          {:ok,
           {:unchanged,
            Map.put(result, :note, "No muted word has this value; nothing was written.")}},
        else:
          preference_change(
            updated,
            result,
            "removed holds each muted word as it was; mute_word with its value, targets, only_non_followed and expires_at mutes it again exactly so, under a new id."
          )
    end
  end

  def prepare_moderation_preference(session, {verb, did})
      when verb in [:subscribe_labeler, :unsubscribe_labeler] do
    subscribe? = verb == :subscribe_labeler

    with :ok <- not_app_labeler(did),
         {:ok, preferences} <- stored_preferences(session),
         {:ok, view} <-
           if(subscribe?, do: labeler_view(session, did, "actor"), else: {:ok, nil}),
         :ok <- labeler_room(session, preferences, did, subscribe?) do
      updated = AtMcp.Moderation.subscribe(preferences, did, subscribe?)
      before = did in AtMcp.Moderation.subscribed(preferences)

      result = %{
        ok: true,
        action: verb,
        actor: did,
        handle: view && get_in(view, ["creator", "handle"]),
        previous: before,
        now: subscribe?,
        unchanged: is_nil(updated)
      }

      preference_change(
        updated,
        result,
        if(subscribe?,
          do:
            "The app takes this labeler's labels from now and shows its label settings; set_label_visibility changes them. at_mcp's reads do not yet ask the AppView for the labelers this account subscribes to, so they may not carry this one's labels.",
          else: "The app no longer takes this labeler's labels."
        )
      )
    end
  end

  def prepare_moderation_preference(session, {:set_label_visibility, label, visibility, labeler}) do
    with {:ok, preferences} <- stored_preferences(session),
         :ok <- adult_labels_shown(preferences, label, labeler),
         {:ok, default, definition} <-
           label_default(session, preferences, label, labeler, visibility) do
      updated = AtMcp.Moderation.set_label(preferences, label, labeler, visibility)
      adult? = AtMcp.Preferences.kind_view(preferences, "adult_content").enabled

      shown = fn prefs ->
        stored = AtMcp.Moderation.label_visibility(prefs, label, labeler, default)

        if definition,
          do: AtMcp.Moderation.shown_setting(stored, definition, adult?),
          else: AtMcp.Moderation.visibility_word(stored)
      end

      # As the app shows it: a change it would show no differently is none.
      before = shown.(preferences)
      now = shown.(updated)

      result = %{
        ok: true,
        action: :set_label_visibility,
        label: label,
        labeler: labeler,
        previous: before,
        now: now,
        unchanged: before == now
      }

      preference_change(if(before == now, do: nil, else: updated), result, @moderation_note)
    end
  end

  defp preference_change(nil, result, _note), do: {:ok, {:unchanged, result}}

  defp preference_change(updated, result, note),
    do: {:ok, %{preferences: updated, result: Map.put(result, :note, note <> " " <> @no_swap)}}

  defp not_app_labeler(did) do
    if did in AtMcp.Moderation.app_labelers(),
      do:
        {:error,
         {:invalid_argument, "actor",
          "#{did} is #{AtMcp.Network.label()}'s own moderation service, which every account has; the app offers no subscription to it"}},
      else: :ok
  end

  # The app counts the labelers an account has against its limit after
  # removing those that are gone: no profile (taken down or deactivated) or no
  # longer a labeler (`useLabelerSubscriptionMutation` in social-app's
  # src/state/queries/labeler.ts). at_mcp removes nothing it was not asked to,
  # so at the limit it reads which those are and names them, for
  # unsubscribe_labeler.
  defp labeler_room(session, preferences, did, true) do
    labelers = AtMcp.Moderation.labelers(preferences)
    max = AtMcp.Moderation.max_labelers()

    if did not in labelers and length(labelers) >= max do
      with {:ok, gone} <- gone_labelers(session, AtMcp.Moderation.subscribed(preferences)) do
        why =
          case gone do
            [] ->
              "unsubscribe_labeler one first"

            gone ->
              "of these, #{Enum.join(gone, ", ")} #{if length(gone) == 1, do: "is", else: "are"} gone (taken down, deactivated or no longer a labeler); the app removes such labelers before it counts, and at_mcp does not, so unsubscribe_labeler them, or another, first"
          end

        {:error,
         {:invalid_argument, "actor",
          "this account has #{length(labelers)} labelers, #{AtMcp.Network.label()}'s own included, and the app allows #{max}; #{why}"}}
      end
    else
      :ok
    end
  end

  defp labeler_room(_session, _preferences, _did, false), do: :ok

  defp gone_labelers(session, dids) do
    dids
    |> Enum.uniq()
    |> Enum.chunk_every(AtMcp.Effects.max_batch())
    |> Enum.reduce_while({:ok, []}, fn batch, {:ok, gone} ->
      case AtMcp.ATProto.get_profiles(session, batch) do
        {:ok, response} ->
          profiles = List.wrap(field(response, :profiles))

          labelers =
            for profile <- profiles,
                not (is_map(field(profile, :associated)) and
                       AtMcp.Response.dig(profile, [:associated, :labeler]) != true),
                do: string_value(profile, :did)

          {:cont, {:ok, gone ++ Enum.reject(batch, &(&1 in labelers))}}

        {:error, reason} ->
          {:halt, {:error, failure(reason)}}
      end
    end)
  end

  # The four labels of the app's moderation screen show only while adult
  # content is on (social-app src/screens/Moderation/index.tsx at 485405a).
  defp adult_labels_shown(preferences, _label, nil) do
    if AtMcp.Preferences.kind_view(preferences, "adult_content").enabled,
      do: :ok,
      else:
        {:error,
         {:invalid_argument, "label",
          "the app shows these settings only while adult content is on, and it is off for this account (set_preference kind adult_content)"}}
  end

  defp adult_labels_shown(_preferences, _label, _labeler), do: :ok

  @global_defaults %{
    "porn" => "hide",
    "sexual" => "warn",
    "graphic-media" => "warn",
    "nudity" => "ignore"
  }

  defp label_default(_session, _preferences, label, nil, _visibility),
    do: {:ok, Map.fetch!(@global_defaults, label), nil}

  # A labeler's own label is set on its page in the app, for a labeler the
  # account takes labels from, when the page lists it as the labeler's own
  # (`AtMcp.Moderation.labeler_labels/1`); `warn` only when the label blurs or
  # warns at all, and an adult-only label only while adult content is on
  # (`LabelerLabelPreference` in social-app's
  # src/components/moderation/LabelPreference.tsx).
  defp label_default(session, preferences, label, labeler, visibility) do
    with :ok <-
           if(labeler in AtMcp.Moderation.labelers(preferences),
             do: :ok,
             else:
               {:error,
                {:invalid_argument, "labeler",
                 "this account does not subscribe to #{labeler}; the app reads label settings only for the labelers an account takes labels from"}}
           ),
         {:ok, view} <- labeler_view(session, labeler, "labeler") do
      labels = AtMcp.Moderation.labeler_labels(view)
      adult? = AtMcp.Preferences.kind_view(preferences, "adult_content").enabled

      own =
        for {:custom, definition} <- labels, do: definition["identifier"]

      definition =
        Enum.find_value(labels, fn
          {:custom, %{"identifier" => ^label} = definition} -> definition
          _ -> nil
        end)

      cond do
        {:global, label} in labels ->
          {:error,
           {:invalid_argument, "label",
            "#{label} is one of the app's adult content filters, which apply to every labeler's labels; set it without labeler"}}

        is_nil(definition) ->
          {:error,
           {:invalid_argument, "label",
            "the app lists no label #{label} of #{labeler}'s to set; it lists #{own |> Enum.join(", ") |> blank_none()}"}}

        definition["adultOnly"] == true and not adult? ->
          {:error,
           {:invalid_argument, "label",
            "#{label} is adult content, and the app shows its setting only while adult content is on"}}

        visibility == "warn" and not AtMcp.Moderation.can_warn?(definition) ->
          {:error,
           {:invalid_argument, "visibility",
            "#{label} neither blurs nor warns, so the app offers show or hide for it"}}

        true ->
          {:ok, AtMcp.Moderation.default_setting(definition), definition}
      end
    end
  end

  defp blank_none(""), do: "none"
  defp blank_none(text), do: text

  @doc """
  Read a moderation list mute: the list (in DID form) for its purpose and
  whether this account mutes it now. A mute of a list that is not a
  moderation list is refused, as the app offers none.
  """
  @impl true
  def prepare_list_mute(session, {verb, uri}) do
    with {:ok, list} <- viewed_list(session, uri, "uri"),
         :ok <- if(verb == :mute_list, do: moderation_list(list, "mute"), else: :ok) do
      {:ok,
       %{
         verb: verb,
         list: string_value(list, :uri) || uri,
         result: %{
           ok: true,
           action: verb,
           list: string_value(list, :uri) || uri,
           name: string_value(list, :name),
           previous: AtMcp.Response.dig(list, [:viewer, :muted]) == true
         }
       }}
    end
  end

  # Sent whatever the list's view said: the AppView keeps a list mute by its
  # URI and applies a repeated mute or unmute as nothing, and its view can lag
  # one just made.
  @impl true
  def mute_list(session, %{verb: verb, list: list, result: result}) do
    call =
      if verb == :mute_list,
        do: &AtMcp.ATProto.mute_actor_list/2,
        else: &AtMcp.ATProto.unmute_actor_list/2

    case call.(session, %{list: list}) do
      {:ok, _} ->
        {:ok,
         Map.merge(result, %{
           muted: verb == :mute_list,
           note:
             "Mutes are private to the account. #{if verb == :mute_list, do: "unmute_list", else: "mute_list"} with this list undoes it."
         })}

      {:error, reason} ->
        {:error, failure(reason)}
    end
  end

  @impl true
  def get_moderation_lists(session, kind, opts) do
    read =
      if kind == "muted",
        do: &AtMcp.ATProto.get_list_mutes/2,
        else: &AtMcp.ATProto.get_list_blocks/2

    session
    |> read.(paging(opts, %{}))
    |> read(:lists, &list_view/1)
  end

  @doc """
  Labelers in detail, with this account's settings for each: whether it
  subscribes, and for each label the labeler defines, what the app does with
  it. Nil reads the labelers this account takes labels from.
  """
  @impl true
  def get_labelers(session, dids) do
    with {:ok, preferences} <- stored_preferences(session) do
      dids = dids || AtMcp.Moderation.labelers(preferences)

      with {:ok, views} <- if(dids == [], do: {:ok, []}, else: labeler_views(session, dids)) do
        {global, by_labeler} = AtMcp.Moderation.label_settings(preferences)
        subscribed = AtMcp.Moderation.subscribed(preferences)
        adult? = AtMcp.Preferences.kind_view(preferences, "adult_content").enabled
        found = Enum.map(views, &get_in(&1, ["creator", "did"]))

        {:ok,
         %{
           count: length(views),
           items: Enum.map(views, &labeler_summary(&1, by_labeler, subscribed, global, adult?)),
           missing: Enum.reject(dids, &(&1 in found))
         }}
      end
    end
  end

  defp labeler_summary(view, by_labeler, subscribed, global, adult?) do
    did = get_in(view, ["creator", "did"])
    settings = Map.get(by_labeler, did)

    %{
      did: did,
      handle: get_in(view, ["creator", "handle"]),
      display_name: get_in(view, ["creator", "displayName"]),
      web_url: AtMcp.WebLink.profile(get_in(view, ["creator", "handle"]), did),
      uri: view["uri"],
      cid: view["cid"],
      like_count: view["likeCount"],
      like: get_in(view, ["viewer", "like"]),
      built_in: did in AtMcp.Moderation.app_labelers(),
      subscribed: did in subscribed,
      label_values: List.wrap(get_in(view, ["policies", "labelValues"])),
      labels:
        for label <- AtMcp.Moderation.labeler_labels(view) do
          case label do
            {:custom, definition} ->
              strings = locale_strings(definition["locales"])
              default = AtMcp.Moderation.default_setting(definition)

              %{
                identifier: definition["identifier"],
                name: strings["name"],
                description: strings["description"],
                severity: definition["severity"],
                blurs: definition["blurs"],
                global: false,
                default: AtMcp.Moderation.shown_setting(default, definition, true),
                adult_only: definition["adultOnly"] == true,
                setting:
                  if(settings,
                    do:
                      AtMcp.Moderation.shown_setting(
                        Map.get(settings, definition["identifier"], default),
                        definition,
                        adult?
                      )
                  )
              }

            {:global, value} ->
              # One of the app's adult content filters, set for every labeler
              # in its moderation screen; the app hides it while adult
              # content is off.
              %{
                identifier: value,
                global: true,
                adult_only: true,
                setting:
                  if(adult?,
                    do: AtMcp.Moderation.visibility_word(Map.get(global, value, "warn")),
                    else: "hide"
                  )
              }
          end
        end,
      reason_types: view["reasonTypes"],
      subject_types: view["subjectTypes"],
      subject_collections: view["subjectCollections"]
    }
  end

  # A label's name and description in English, or the first language given.
  defp locale_strings(locales) when is_list(locales) do
    locales = Enum.filter(locales, &is_map/1)
    Enum.find(locales, &(&1["lang"] == "en")) || List.first(locales) || %{}
  end

  defp locale_strings(_locales), do: %{}

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
  # A delete is never sent with a null swap, which the PDS always refuses
  # (there is a record to delete); one runs only after a record was read.
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

  # Written over the status read, or, when there was none, only if there
  # still is none (a null swap).
  def write_status(session, %{record: record, swap: swap} = plan) do
    params = %{
      repo: session.did,
      collection: AtMcp.Network.collection(:status),
      rkey: "self",
      record: record,
      swap_record: swap
    }

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

  # --- a post's link card ---

  # The link card a post carries, and how it came to: `{opts, report}`.
  #
  #   * `given`: the caller wrote the card's title or description, or gave a
  #     thumbnail; it is written as given.
  #   * `card_service`: the caller gave only the url, and the card was looked
  #     up (`AtMcp.LinkCards`).
  #   * `text`: the caller gave no card, images or quote, and the post's text
  #     links a page: the app's composer adds a card for the first link, and so
  #     does this, looked up the same way.
  #   * `url_only`: the caller gave only the url and nothing was looked up.
  #
  # A link in text published without facets (`facets: :none`) is the caller's
  # quoted text, not its own: no card is added for it. A network with no card
  # service adds none for a link in text either.
  defp link_card(opts, rich_text) do
    link = Keyword.get(opts, :link)

    cond do
      link && given_card?(link) ->
        {opts, %{url: link.url, from: :given}}

      link && AtMcp.LinkCards.looked_up?(link.url) ->
        card = AtMcp.LinkCards.lookup(link.url)
        {Keyword.put(opts, :link, Map.delete(card, :note)), report(card, :card_service)}

      link ->
        {opts, %{url: link.url, from: :url_only, note: url_only_note(link.url)}}

      Keyword.get(opts, :facets) != :none and blank?(Keyword.get(opts, :images)) and
          is_nil(Keyword.get(opts, :quote)) ->
        with url when is_binary(url) <- first_link(rich_text.facets),
             true <- AtMcp.LinkCards.looked_up?(url) do
          card = AtMcp.LinkCards.lookup(url)
          {Keyword.put(opts, :link, Map.delete(card, :note)), report(card, :text)}
        else
          _ -> {opts, nil}
        end

      true ->
        {opts, nil}
    end
  end

  defp given_card?(link),
    do:
      Map.get(link, :title, "") != "" or Map.get(link, :description, "") != "" or
        not is_nil(Map.get(link, :thumb))

  defp report(card, from),
    do:
      %{url: card.url, from: from}
      |> then(&if(card.note, do: Map.put(&1, :note, card.note), else: &1))

  defp url_only_note(url) do
    if is_nil(AtMcp.Network.card_service()),
      do:
        "This network looks up no link card, so the card shows only the link. Pass the link's title and description to show them.",
      else:
        "The card shows only the link: at_mcp looks up no card for #{url}, as the app does not for a link into the app itself or to an image."
  end

  defp blank?(nil), do: true
  defp blank?([]), do: true
  defp blank?(_), do: false

  defp first_link(facets) do
    link_type = AtMcp.Network.type(:link_facet)

    Enum.find_value(facets || [], fn facet ->
      Enum.find_value(Map.get(facet, :features, []), fn feature ->
        if feature[:"$type"] == link_type and http?(feature[:uri]), do: feature[:uri]
      end)
    end)
  end

  defp http?(url) when is_binary(url), do: URI.parse(url).scheme in ["http", "https"]
  defp http?(_), do: false

  defp with_link_card(summary, %{link_card: %{} = card}),
    do: Map.put(summary, :link_card, Map.update!(card, :from, &Atom.to_string/1))

  defp with_link_card(summary, _prepared), do: summary

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
        {:ok, _other} -> {:error, {:referenced_record_unreadable, uri, :unusable_answer}}
        {:error, reason} -> reference_error(uri, reason)
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
      {:error, {:referenced_record_unreadable, _uri, _cause}} = error -> error
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
             "The draft #{id} was deleted before the update reached it, and the service ignores an update to a draft it does not hold, so nothing was saved.",
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
  defp create(session, kind, record),
    do: create_in(session, AtMcp.Network.collection(kind), record)

  defp create_in(session, collection, record) do
    AtMcp.ATProto.create_record(session, %{
      repo: session.did,
      collection: collection,
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
         :ok <- reply_allowed(session, parent.uri),
         {:ok, refs} <- reply_root(session, root_of(response), parent) do
      {:ok, Map.put(refs, :parent_langs, langs_of(response))}
    end
  end

  # When the caller gives no languages for a reply, the reply gets its parent's
  # tags. The app's composer does the same (Composer.tsx in social-app at
  # 62b95002). Replies are usually in the language of the post they answer,
  # and feeds and searches that filter by language leave out untagged posts.
  # langs_of/1 keeps the parent's non-empty string tags, up to the network's
  # limit for a post, and returns nil if none are left.
  defp langs_of(response) do
    with {:ok, value} when is_map(value) <- AtMcp.Response.fetch(response, :value),
         {:ok, langs} when is_list(langs) <- AtMcp.Response.fetch(value, :langs),
         [_ | _] = langs <-
           langs
           |> Enum.filter(&(is_binary(&1) and &1 != ""))
           |> Enum.take(AtMcp.Network.post_language_limit()) do
      langs
    else
      _ -> nil
    end
  end

  # The parent's record names the root as its writer spelled it, and a client
  # may have spelled it with the root author's handle. An AppView matches a
  # reply to its thread by the string in reply.root.uri, filed under the DID
  # form: the reference AppView serves no reply that copied a handle-form
  # root, and another was seen counting such a reply on its parent while
  # listing it in no thread. So a DID-form root is copied as declared, CID and
  # all, as the app copies it; a handle-form one has its handle resolved and
  # keeps the CID the parent declared. The root is not read: the app does not
  # read it, and a root whose author's repository is gone must still be
  # answerable. A handle that does not resolve refuses the reply before
  # anything is written: there is no DID-form root to write.
  defp reply_root(_session, nil, parent), do: {:ok, %{root: parent, parent: parent}}

  defp reply_root(session, %{uri: declared, cid: cid}, parent) do
    with {:ok, root_uri} <- root_did_uri(session, declared, parent.uri) do
      refs = %{root: %{uri: root_uri, cid: cid}, parent: parent}
      {:ok, if(root_uri == declared, do: refs, else: Map.put(refs, :declared_root, declared))}
    end
  end

  # The DID-form URI of the root a parent declares. A DID-form one is taken as
  # it is; a handle-form one has its handle resolved. A moved handle would name
  # another account's record; the declared CID then names nothing there, and
  # catching that would cost a read of the root on every such reply. It is not
  # checked.
  defp root_did_uri(session, declared, parent_uri) do
    case AtMcp.ATProto.parse_uri(declared) do
      {:ok, {"did:" <> _, _collection, _rkey}} ->
        {:ok, declared}

      {:ok, {handle, collection, rkey}} ->
        case resolve_actor(session, handle) do
          {:ok, did} ->
            {:ok, "at://#{did}/#{collection}/#{rkey}"}

          {:error, {:handle_not_resolved, _}} ->
            {:error,
             AtMcp.Effects.Failure.new(:refused,
               message:
                 "The post #{parent_uri} names its thread's root as #{declared}, and the handle #{handle} in it could not be resolved to a DID, so the root could not be named the way the app files threads. Nothing was sent."
             )}

          {:error, _} = error ->
            error
        end

      # Not an AT URI: no form of it is the root's, so it is left as written.
      {:error, _} ->
        {:ok, declared}
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
      :error -> {:error, {:referenced_record_unreadable, uri, :unusable_answer}}
      {:ok, _not_a_cid} -> {:error, {:referenced_record_unreadable, uri, :unusable_answer}}
      {:error, reason} -> reference_error(uri, reason)
    end
  end

  # A service that refuses to hand over one record is saying something about
  # that record, and the refusal carries what: `RecordNotFound` (read as
  # `not_found_or_failure/3` reads it) means it holds no such record; any other
  # refusal passes on the service's error name and message. A transport
  # failure, an outage, or a credential the service rejected says nothing about
  # the record at all, and a caller told "it may be deleted" about a post that
  # is still there stops trying instead of retrying. So only a refusal becomes
  # `referenced_record_unreadable`; everything else keeps its own kind.
  defp reference_error(uri, reason) do
    case not_found_or_failure(reason, "record", uri) do
      %AtMcp.Effects.Failure{detail: {:not_found, _, _}} ->
        {:error, {:referenced_record_unreadable, uri, :not_found}}

      %AtMcp.Effects.Failure{kind: :refused} = failure ->
        {:error,
         {:referenced_record_unreadable, uri, {:refused, error_name(reason), failure.message}}}

      failure ->
        {:error, failure}
    end
  end

  # The service's error name as it sent it: proto_rune keeps it as an atom or
  # a snake_case string.
  defp error_name(%ProtoRune.XRPC.Error{reason: reason})
       when is_atom(reason) and not is_nil(reason),
       do: reason |> Atom.to_string() |> Macro.camelize()

  defp error_name(%ProtoRune.XRPC.Error{reason: reason}) when is_binary(reason),
    do: Macro.camelize(reason)

  defp error_name(_reason), do: nil

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

  @profile_wire_fields Map.new(@profile_fields, fn {key, wire} -> {Atom.to_string(key), wire} end)

  # Omitted fields are kept. Explicit empty display name, description, pronouns
  # or website values remove their optional record keys.
  defp merge_profile(current, updates) do
    current = Map.new(current, fn {key, value} -> {to_string(key), value} end)

    current =
      Map.new(current, fn {key, value} ->
        {Map.get(@profile_wire_fields, key, key), value}
      end)

    merge_profile_fields(current, updates)
  end

  defp merge_profile_fields(current, updates) do
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
  def summarize(:notifications, response), do: page(response, :notifications, &notif_item/1)
  # Read from the raw body, as `get_grouped_notifications/2` reads it.
  def summarize(:grouped_notifications, response), do: grouped(response)

  # `getPostThreadV2` returns a flat list: parents at negative depths with
  # the root first, the post at depth 0, then the replies depth first, each
  # followed by its own replies. summarize_thread/1 rebuilds that list into
  # the post with its `parent` chain and a `replies` list under each post.
  defp summarize_thread(thread) when is_map(thread) do
    items = Enum.filter(of_type(thread, :thread, &is_list/1) || [], &is_map/1)
    {above, rest} = Enum.split_with(items, &(depth(&1) < 0))
    below = Enum.filter(rest, &(depth(&1) > 0))

    parent =
      above
      |> Enum.sort_by(&depth/1)
      |> Enum.reduce(nil, fn item, ancestor ->
        item |> thread_item() |> unreturned(1) |> Map.put(:parent, ancestor)
      end)

    replies = thread_replies(below, 0)

    case Enum.find(rest, &(depth(&1) == 0)) do
      nil -> placeholder(nil) |> Map.put(:not_found, true)
      anchor -> anchor |> thread_item() |> unreturned(length(replies))
    end
    |> Map.merge(%{parent: parent, replies: replies})
    |> Map.put(:other_replies, flag(thread, [:has_other_replies, :hasOtherReplies]))
  end

  defp summarize_thread(other), do: %{value: to_string_safe(other)}

  # Sets `replies_omitted` from the post's own reply count when the count is
  # higher than what the service returned. V2 sends `moreReplies: 0` for
  # every parent, and it can return fewer direct replies than a post has
  # without saying so. A post without a count keeps the service's number.
  defp unreturned(node, shown) do
    case node[:reply_count] do
      count when is_integer(count) ->
        Map.put(node, :replies_omitted, max(node[:replies_omitted] || 0, count - shown))

      _ ->
        node
    end
  end

  defp depth(item) do
    case field(item, :depth) do
      depth when is_integer(depth) -> depth
      _ -> 0
    end
  end

  # The items at one level below `level`, each with the items under it.
  defp thread_replies([], _level), do: []

  defp thread_replies([item | rest], level) do
    {under, siblings} = Enum.split_while(rest, &(depth(&1) > level + 1))

    [
      item |> thread_item() |> Map.put(:replies, thread_replies(under, level + 1))
      | thread_replies(siblings, level)
    ]
  end

  # One thread item: the post, or what stands in for one the service could
  # not show, with what the service says about its place in the thread.
  defp thread_item(item) do
    value = of_type(item, :value, &is_map/1) || %{}
    type = field(value, :"$type")
    post = of_type(value, :post, &is_map/1)

    if(post, do: post_view(post), else: placeholder(field(item, :uri)))
    |> Map.merge(%{
      type: type,
      not_found: is_binary(type) and String.ends_with?(type, "#threadItemNotFound"),
      blocked: is_binary(type) and String.ends_with?(type, "#threadItemBlocked"),
      parent: nil,
      parent_omitted: flag(value, [:more_parents, :moreParents]),
      replies: [],
      replies_omitted: integer(value, [:more_replies, :moreReplies]),
      op_thread_index: integer(value, [:op_thread_post_index, :opThreadPostIndex]),
      op_thread_count: integer(value, [:op_thread_post_count, :opThreadPostCount])
    })
    |> Map.merge(
      for {key, keys} <- [
            hidden_by_threadgate: [:hidden_by_threadgate, :hiddenByThreadgate],
            muted_by_viewer: [:muted_by_viewer, :mutedByViewer]
          ],
          flag(value, keys),
          into: %{},
          do: {key, true}
    )
    |> blocked_author(value)
  end

  defp blocked_author(%{blocked: true} = node, value) do
    case AtMcp.Response.dig(value, [:author, :did]) do
      did when is_binary(did) -> Map.put(node, :author_did, did)
      _ -> node
    end
  end

  defp blocked_author(node, _value), do: node

  defp integer(map, keys) do
    Enum.find_value(keys, fn key ->
      case field(map, key) do
        n when is_integer(n) -> n
        _ -> nil
      end
    end)
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

  # The parent names its root in a form the AppView does not file threads
  # under, so the app may show the parent out of its thread. The reply itself
  # names the root by DID; this says so, as a fact about the parent.
  defp root_warning(result, nil, _record), do: result

  defp root_warning(result, declared, record) do
    written = get_in(record, ["reply", "root", "uri"])

    note =
      "The parent names its thread's root as #{declared}, not by DID; the app may not show the parent in that thread. This reply names the root as #{written}."

    Map.update(result, :warning, note, &(&1 <> " " <> note))
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
