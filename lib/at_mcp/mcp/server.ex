defmodule AtMcp.MCP.Server do
  @moduledoc """
  HTTP/stdio MCP surface for one identity on this network.

  Each network verb is one MCP tool. A tool calls `AtMcp.Effects` and returns
  a summary of the result, never a raw session dump. A write returns the
  summary as structured content and as its JSON text. A read returns
  `AtMcp.Reading`'s text of the summary, or the JSON for reads without a
  reading of their own. A read passed `format: "json"` returns the summary the
  way a write does (`AtMcp.MCP.Output`).

  Tool calls go through AtMcp.Effects, which checks that the account is ready and
  counts what the account publishes against its write quota. Each write tool's
  description and `at_mcp/publicWrite` annotation say whether it counts, derived
  from `AtMcp.Effects.publishing/0` when the tools are declared. The MCP host controls
  per-action permission; MCP itself does not supply consent. No client can
  reset a write quota.
  """

  use ExMCP.Server.Handler
  use AtMcp.MCP.DSL

  require AtMcp.MCP.Schemas

  @doc "The name and version every AtMcp MCP endpoint reports: the version is the release's."
  def server_info, do: %{name: "at_mcp", version: to_string(Application.spec(:at_mcp, :vsn))}

  @impl true
  def init(args) do
    effects = Keyword.get(args, :effects, AtMcp.Effects)

    {:ok,
     %{
       effects: effects,
       scope: Keyword.get(args, :scope),
       format: Keyword.get(args, :format),
       tools: Keyword.get(args, :tools)
     }}
  end

  # The MCP log levels (RFC 5424 names), as the spec lists them.
  @mcp_log_levels ~w(debug info notice warning error critical alert emergency)

  @doc """
  Accepts an MCP `logging/setLevel` and changes nothing.

  Up to ex_mcp 1.7.2 the default applied the level with `Logger.configure/1`,
  so any client could set the log level of the whole node (GHSA-5vm6-rrjx-3496).
  ex_mcp 1.7.3's default does what this does; AtMcp keeps its own so the node's
  log level never depends on which default a dependency ships. AtMcp sends no
  MCP log notifications, so there is no per-client level to keep: a valid level
  is acknowledged, anything else refused.
  """
  @impl true
  def handle_set_log_level(level, state) when level in @mcp_log_levels, do: {:ok, state}

  def handle_set_log_level(level, state),
    do: {:error, "unknown log level: #{inspect(level)}", state}

  tool "get_notifications",
       "Read recent notifications on this network for this account. With grouped true, read them grouped as the app's Notifications screen shows them (\"alice and 5 others liked your post\"): each group names who acted, the posts acted on and how many notifications it holds, a reply, quote or mention carries its post whole as get_posts reads one but without moderation marks, and feed picks the screen's tab." do
    annotations(%{readOnlyHint: true, openWorldHint: true})
    output_schema(AtMcp.MCP.Schemas.notification_page())

    param(:limit, :integer, AtMcp.MCP.Schemas.page_limit("notifications, or groups"))

    param(:cursor, :string, description: "Continuation cursor returned by the previous page")

    param(:reasons, {:array, :string}, AtMcp.MCP.Schemas.notification_reasons())

    param(:grouped, :boolean,
      description:
        "Read the groups the app's Notifications screen shows instead of one notification at a time. Not with reasons"
    )

    param(:feed, :string, AtMcp.MCP.Schemas.notification_feed())

    run(fn a, state ->
      e = state.effects

      AtMcp.Effects.list_notifications(e,
        limit: Map.get(a, :limit),
        cursor: Map.get(a, :cursor),
        reasons: AtMcp.MCP.Tools.optional(Map.get(a, :reasons)),
        grouped: Map.get(a, :grouped),
        feed: AtMcp.MCP.Tools.optional(Map.get(a, :feed))
      )
      |> case do
        # A network without grouped notifications still serves the plain list.
        {:error, {:not_served, nsid, evidence}} when a.grouped == true ->
          {:error, {:not_served, nsid, evidence, :ungrouped_notifications}}

        result ->
          result
      end
      |> AtMcp.MCP.Tools.respond(state, :notifications)
    end)
  end

  tool "get_unread_count", "Count unread notifications on this network." do
    annotations(%{readOnlyHint: true, openWorldHint: true})
    output_schema(AtMcp.MCP.Schemas.unread_count())

    run(fn _a, state ->
      e = state.effects
      AtMcp.MCP.Tools.respond(AtMcp.Effects.get_unread_count(e), state)
    end)
  end

  tool "get_timeline", "Read this account's home timeline." do
    annotations(%{readOnlyHint: true, openWorldHint: true})
    output_schema(AtMcp.MCP.Schemas.post_page())

    param(:limit, :integer, AtMcp.MCP.Schemas.page_limit("posts"))

    param(:cursor, :string, description: "Continuation cursor returned by the previous page")

    run(fn a, state ->
      e = state.effects

      AtMcp.MCP.Tools.respond(
        AtMcp.Effects.get_timeline(e, limit: Map.get(a, :limit), cursor: Map.get(a, :cursor)),
        state,
        :posts
      )
    end)
  end

  tool "get_author_feed", "Read recent public posts by a handle or DID." do
    annotations(%{readOnlyHint: true, openWorldHint: true})
    output_schema(AtMcp.MCP.Schemas.post_page())
    param(:actor, :string, required: true, description: "Handle or DID")

    param(:limit, :integer, AtMcp.MCP.Schemas.page_limit("posts"))

    param(:cursor, :string, description: "Continuation cursor returned by the previous page")

    run(fn a, state ->
      e = state.effects

      AtMcp.MCP.Tools.respond(
        AtMcp.Effects.get_author_feed(e, AtMcp.MCP.Tools.actor(Map.fetch!(a, :actor)),
          limit: Map.get(a, :limit),
          cursor: Map.get(a, :cursor)
        ),
        state,
        :posts
      )
    end)
  end

  tool "get_thread",
       AtMcp.MCP.Schemas.describe(
         "Read what surrounds a post: {thread}. For the conversation leading to a post, use get_thread_chain instead."
       ) do
    annotations(%{readOnlyHint: true, openWorldHint: true})
    output_schema(AtMcp.MCP.Schemas.thread())
    param(:uri, :string, required: true, description: "AT URI of the post")

    param(:include_hidden, :boolean,
      description:
        "Also read the replies under the post that the app leaves out of the thread: replies the thread's author hid, and replies the account's own settings push down, such as those by accounts it muted. A reply this read already shows is marked where it stands; the others are listed after the thread. Each says why when the service does. If they cannot be read, the thread is returned with a line saying so."
    )

    run(fn a, state ->
      e = state.effects

      AtMcp.MCP.Tools.respond(
        AtMcp.Effects.get_thread(e, Map.fetch!(a, :uri),
          include_hidden: Map.get(a, :include_hidden) == true
        ),
        state,
        :thread
      )
    end)
  end

  tool "get_thread_chain",
       "Read the conversation leading to a post: every ancestor from the thread root down to it, as a flat list in order, plus the replies directly under it. Each element says who wrote it, when, whether this account wrote it, and where its links and mentions point. A conversation taller than one chain carries is returned in pages nearest the requested post first: chain_truncated says the chain does not run from the root, chain_omitted counts what was dropped, and chain_before names the uri to pass back as `before` to read the page above. Use this to answer a post; use get_thread to look around one." do
    annotations(%{readOnlyHint: true, openWorldHint: true})
    output_schema(AtMcp.MCP.Schemas.thread_chain())
    param(:uri, :string, required: true, description: "AT URI of the post")

    param(:include_replies, :boolean,
      description:
        "Give false to leave out the replies directly under the post. The chain comes back the same either way."
    )

    param(:before, :string,
      description:
        "AT URI from a previous call's chain_before. Given it, the chain ends at that post instead of at uri, which is how a conversation taller than one chain is read upward without repeating or skipping a post. A page read this way carries no replies."
    )

    run(fn a, state ->
      e = state.effects

      AtMcp.MCP.Tools.respond(
        AtMcp.Effects.get_thread_chain(e, Map.fetch!(a, :uri),
          before: Map.get(a, :before),
          include_replies: Map.get(a, :include_replies, true)
        ),
        state,
        :chain
      )
    end)
  end

  tool "get_posts",
       AtMcp.MCP.Schemas.describe("Fetch posts by a list of AT URIs ({batch} per call).") do
    annotations(%{readOnlyHint: true, openWorldHint: true})
    output_schema(AtMcp.MCP.Schemas.post_page())

    param(:uris, {:array, :string}, AtMcp.MCP.Schemas.batch("AT URIs"))

    run(fn a, state ->
      e = state.effects

      AtMcp.MCP.Tools.respond(
        AtMcp.Effects.get_posts(e, List.wrap(Map.get(a, :uris, []))),
        state,
        :posts
      )
    end)
  end

  tool "get_post_images",
       "See the images attached to one post. Returns a text block listing each image by index (from 1) with its alt text, then each image that could be fetched, in the post's order, as image content. An image that could not be fetched is listed with the reason. Results can be large; use it only when the model reading the result accepts images. A quoted post's images are not included: call this with the quoted post's URI." do
    annotations(%{readOnlyHint: true, openWorldHint: true})
    output_schema(AtMcp.MCP.Schemas.post_images())
    param(:uri, :string, required: true, description: "AT URI of the post")

    run(fn a, state ->
      AtMcp.MCP.Tools.get_post_images(state.effects, Map.fetch!(a, :uri), state)
    end)
  end

  tool "get_profile",
       "Fetch a profile on this network by handle or DID. Omit actor for this account." do
    annotations(%{readOnlyHint: true, openWorldHint: true})
    output_schema(AtMcp.MCP.Schemas.profile_view())
    param(:actor, :string, description: "Handle or DID")

    run(fn a, state ->
      e = state.effects

      AtMcp.MCP.Tools.respond(
        AtMcp.MCP.Tools.get_profile(e, AtMcp.MCP.Tools.actor(Map.get(a, :actor))),
        state,
        :profile
      )
    end)
  end

  tool "get_profiles",
       AtMcp.MCP.Schemas.describe(
         "Fetch several profiles on this network by handle or DID ({batch} per call)."
       ) do
    annotations(%{readOnlyHint: true, openWorldHint: true})
    output_schema(AtMcp.MCP.Schemas.profile_page())

    param(:actors, {:array, :string}, AtMcp.MCP.Schemas.batch("Handles or DIDs"))

    run(fn a, state ->
      e = state.effects

      AtMcp.MCP.Tools.respond(
        AtMcp.Effects.get_profiles(e, AtMcp.MCP.Tools.actors(Map.get(a, :actors, []))),
        state,
        :profiles
      )
    end)
  end

  tool "search_posts",
       "Search public posts on this network, as the app's search does. Give a query, filters, or both. Without sort or all_time it searches every post, newest first, as before. author, mentions, since, until and lang narrow the search as before, and the rest include or exclude posts by who wrote them, who they mention, what they link to or quote, their hashtags, language, media, and where they sit in a thread. Filters are not a second query language." do
    annotations(%{readOnlyHint: true, openWorldHint: true})
    output_schema(AtMcp.MCP.Schemas.post_page())

    param(:query, :string,
      description: "Search query. May be left out when a filter says what to find."
    )

    param(:limit, :integer, AtMcp.MCP.Schemas.page_limit("results"))

    param(:cursor, :string, description: "Continuation cursor returned by the previous page")

    param(:author, :string, description: "Handle or DID; only posts by this account")

    param(:mentions, :string, description: "Handle or DID; only posts that mention this account")

    param(:sort, :string,
      description: "latest (the default: newest first) or top (the service's ranking)",
      schema: %{type: "string", enum: ["latest", "top"]}
    )

    param(:since, :string,
      description: "ISO 8601 timestamp or date (YYYY-MM-DD); only posts indexed at or after it"
    )

    param(:until, :string,
      description: "ISO 8601 timestamp or date (YYYY-MM-DD); only posts indexed before it"
    )

    param(:lang, :string, description: "BCP-47 language tag, e.g. en; only posts in it")

    param(:exclude_langs, {:array, :string},
      description: "BCP-47 language tags; leave out posts in any of them"
    )

    param(:exclude_authors, {:array, :string},
      description: "Handles or DIDs; leave out posts by any of them"
    )

    param(:exclude_mentions, {:array, :string},
      description: "Handles or DIDs; leave out posts that mention any of them"
    )

    param(:domains, {:array, :string},
      description: "Domains, e.g. example.com; only posts that link to one of them"
    )

    param(:exclude_domains, {:array, :string},
      description: "Domains; leave out posts that link to any of them"
    )

    param(:urls, {:array, :string}, description: "URLs; only posts that link to one of them")

    param(:exclude_urls, {:array, :string},
      description: "URLs; leave out posts that link to any of them"
    )

    param(:embeds, {:array, :string},
      description:
        "AT URIs of posts, feeds, lists or starter packs; only posts that quote or embed one of them"
    )

    param(:exclude_embeds, {:array, :string},
      description: "AT URIs; leave out posts that quote or embed any of them"
    )

    param(:hashtags, {:array, :string},
      description: "Hashtags, with or without the #; only posts tagged with one of them"
    )

    param(:exclude_hashtags, {:array, :string},
      description: "Hashtags; leave out posts tagged with any of them"
    )

    param(:has_media, :boolean, description: "true: only posts with images or video")
    param(:has_video, :boolean, description: "true: only posts with video")

    param(:reply_to, :string, description: "AT URI of a post; only the replies directly under it")

    param(:thread_root, :string,
      description: "AT URI of a thread's first post; only posts in that thread"
    )

    param(:replies, :string,
      description: "exclude: leave replies out. only: only replies. Omit for both.",
      schema: %{type: "string", enum: ["exclude", "only"]}
    )

    param(:following, :boolean, description: "true: only posts by accounts this account follows")

    param(:all_time, :boolean,
      description:
        "Omitted or true: search every post the service holds, as before. false: only its recent window"
    )

    param(:query_language, :string,
      description:
        "The language the query is written in, when the service cannot tell: ja, zh, ko, th or ar"
    )

    run(fn a, state ->
      e = state.effects

      AtMcp.MCP.Tools.respond(
        AtMcp.Effects.search_posts(
          e,
          AtMcp.MCP.Tools.optional(Map.get(a, :query)),
          [
            limit: Map.get(a, :limit),
            cursor: Map.get(a, :cursor),
            author: AtMcp.MCP.Tools.optional_actor(Map.get(a, :author)),
            mentions: AtMcp.MCP.Tools.optional_actor(Map.get(a, :mentions)),
            exclude_authors: AtMcp.MCP.Tools.actors(Map.get(a, :exclude_authors, [])),
            exclude_mentions: AtMcp.MCP.Tools.actors(Map.get(a, :exclude_mentions, []))
          ] ++
            Enum.map(
              [
                :sort,
                :since,
                :until,
                :lang,
                :exclude_langs,
                :domains,
                :exclude_domains,
                :urls,
                :exclude_urls,
                :embeds,
                :exclude_embeds,
                :hashtags,
                :exclude_hashtags,
                :has_media,
                :has_video,
                :reply_to,
                :thread_root,
                :replies,
                :following,
                :all_time,
                :query_language
              ],
              &{&1, Map.get(a, &1)}
            )
        ),
        state,
        :posts
      )
    end)
  end

  tool "search_actors", "Search actors/profiles on this network by query string." do
    annotations(%{readOnlyHint: true, openWorldHint: true})
    output_schema(AtMcp.MCP.Schemas.profile_page())
    param(:query, :string, required: true, description: "Search query")

    param(:limit, :integer, AtMcp.MCP.Schemas.page_limit("results"))

    param(:cursor, :string, description: "Continuation cursor returned by the previous page")

    run(fn a, state ->
      e = state.effects

      AtMcp.MCP.Tools.respond(
        AtMcp.Effects.search_actors(e, Map.fetch!(a, :query),
          limit: Map.get(a, :limit),
          cursor: Map.get(a, :cursor)
        ),
        state,
        :profiles
      )
    end)
  end

  # --- reading the social graph ---

  tool "get_followers",
       "List the accounts that follow a handle or DID. Use it on this account to see its own audience." do
    annotations(%{readOnlyHint: true, openWorldHint: true})
    output_schema(AtMcp.MCP.Schemas.profile_page())
    param(:actor, :string, required: true, description: "Handle or DID")

    param(:limit, :integer, AtMcp.MCP.Schemas.page_limit("results"))

    param(:cursor, :string, description: "Continuation cursor returned by the previous page")

    run(fn a, state ->
      e = state.effects

      AtMcp.MCP.Tools.respond(
        AtMcp.Effects.get_followers(e, AtMcp.MCP.Tools.actor(Map.fetch!(a, :actor)),
          limit: Map.get(a, :limit),
          cursor: Map.get(a, :cursor)
        ),
        state,
        :profiles
      )
    end)
  end

  tool "get_follows", "List the accounts a handle or DID follows." do
    annotations(%{readOnlyHint: true, openWorldHint: true})
    output_schema(AtMcp.MCP.Schemas.profile_page())
    param(:actor, :string, required: true, description: "Handle or DID")

    param(:limit, :integer, AtMcp.MCP.Schemas.page_limit("results"))

    param(:cursor, :string, description: "Continuation cursor returned by the previous page")

    run(fn a, state ->
      e = state.effects

      AtMcp.MCP.Tools.respond(
        AtMcp.Effects.get_follows(e, AtMcp.MCP.Tools.actor(Map.fetch!(a, :actor)),
          limit: Map.get(a, :limit),
          cursor: Map.get(a, :cursor)
        ),
        state,
        :profiles
      )
    end)
  end

  tool "get_known_followers",
       "List followers of a handle or DID that this account also follows — shared connections, not all followers." do
    annotations(%{readOnlyHint: true, openWorldHint: true})
    output_schema(AtMcp.MCP.Schemas.profile_page())
    param(:actor, :string, required: true, description: "Handle or DID")

    param(:limit, :integer, AtMcp.MCP.Schemas.page_limit("results"))

    param(:cursor, :string, description: "Continuation cursor returned by the previous page")

    run(fn a, state ->
      e = state.effects

      AtMcp.MCP.Tools.respond(
        AtMcp.Effects.get_known_followers(e, AtMcp.MCP.Tools.actor(Map.fetch!(a, :actor)),
          limit: Map.get(a, :limit),
          cursor: Map.get(a, :cursor)
        ),
        state,
        :profiles
      )
    end)
  end

  tool "get_suggested_follows",
       "Accounts the service suggests following. With actor, accounts like that one. Without, the suggestions one place in the app shows, named by context. Suggestions come from the service, not from AtMcp." do
    annotations(%{readOnlyHint: true, openWorldHint: true})
    output_schema(AtMcp.MCP.Schemas.profile_page())

    param(:actor, :string,
      description: "Handle or DID: suggest accounts like this one. Omit for context."
    )

    param(:context, :string, AtMcp.MCP.Schemas.suggestion_context())

    param(:category, :string,
      description:
        "An interest to suggest accounts for, as the app's Explore tabs do; with context explore, see_more, onboarding or general"
    )

    param(:limit, :integer, AtMcp.MCP.Schemas.page_limit("accounts; not with actor"))

    param(:cursor, :string,
      description: "With context browse: the cursor returned by the previous page"
    )

    run(fn a, state ->
      AtMcp.MCP.Tools.respond(
        AtMcp.Effects.get_suggested_follows(
          state.effects,
          AtMcp.MCP.Tools.optional_actor(Map.get(a, :actor)),
          context: Map.get(a, :context),
          category: Map.get(a, :category),
          limit: Map.get(a, :limit),
          cursor: Map.get(a, :cursor)
        ),
        state,
        :profiles
      )
    end)
  end

  tool "get_blocks", "List the accounts this account blocks." do
    annotations(%{readOnlyHint: true, openWorldHint: true})
    output_schema(AtMcp.MCP.Schemas.profile_page())

    param(:limit, :integer, AtMcp.MCP.Schemas.page_limit("results"))

    param(:cursor, :string, description: "Continuation cursor returned by the previous page")

    run(fn a, state ->
      e = state.effects

      AtMcp.MCP.Tools.respond(
        AtMcp.Effects.get_blocks(e, limit: Map.get(a, :limit), cursor: Map.get(a, :cursor)),
        state,
        :profiles
      )
    end)
  end

  tool "get_mutes", "List the accounts this account mutes. Mutes are private to the account." do
    annotations(%{readOnlyHint: true, openWorldHint: true})
    output_schema(AtMcp.MCP.Schemas.profile_page())

    param(:limit, :integer, AtMcp.MCP.Schemas.page_limit("results"))

    param(:cursor, :string, description: "Continuation cursor returned by the previous page")

    run(fn a, state ->
      e = state.effects

      AtMcp.MCP.Tools.respond(
        AtMcp.Effects.get_mutes(e, limit: Map.get(a, :limit), cursor: Map.get(a, :cursor)),
        state,
        :profiles
      )
    end)
  end

  tool "get_relationships",
       AtMcp.MCP.Schemas.describe(
         "Read how one account stands to each of several others: who follows whom, in each direction ({batch} others per call)."
       ) do
    annotations(%{readOnlyHint: true, openWorldHint: true})
    output_schema(AtMcp.MCP.Schemas.relationship_page())

    param(:actor, :string,
      required: true,
      description: "Handle or DID the relationships are measured from"
    )

    param(
      :others,
      {:array, :string},
      AtMcp.MCP.Schemas.batch("Handles or DIDs to compare against")
    )

    run(fn a, state ->
      e = state.effects

      AtMcp.MCP.Tools.respond(
        AtMcp.Effects.get_relationships(
          e,
          AtMcp.MCP.Tools.actor(Map.fetch!(a, :actor)),
          AtMcp.MCP.Tools.actors(Map.get(a, :others, []))
        ),
        state
      )
    end)
  end

  # --- reading the engagement on a record ---

  tool "get_likes", "List the accounts that liked a post." do
    annotations(%{readOnlyHint: true, openWorldHint: true})
    output_schema(AtMcp.MCP.Schemas.profile_page())
    param(:uri, :string, required: true, description: "AT URI of the post")

    param(:limit, :integer, AtMcp.MCP.Schemas.page_limit("results"))

    param(:cursor, :string, description: "Continuation cursor returned by the previous page")

    run(fn a, state ->
      e = state.effects

      AtMcp.MCP.Tools.respond(
        AtMcp.Effects.get_likes(e, Map.fetch!(a, :uri),
          limit: Map.get(a, :limit),
          cursor: Map.get(a, :cursor)
        ),
        state,
        :profiles
      )
    end)
  end

  tool "get_reposted_by", "List the accounts that reposted a post." do
    annotations(%{readOnlyHint: true, openWorldHint: true})
    output_schema(AtMcp.MCP.Schemas.profile_page())
    param(:uri, :string, required: true, description: "AT URI of the post")

    param(:limit, :integer, AtMcp.MCP.Schemas.page_limit("results"))

    param(:cursor, :string, description: "Continuation cursor returned by the previous page")

    run(fn a, state ->
      e = state.effects

      AtMcp.MCP.Tools.respond(
        AtMcp.Effects.get_reposted_by(e, Map.fetch!(a, :uri),
          limit: Map.get(a, :limit),
          cursor: Map.get(a, :cursor)
        ),
        state,
        :profiles
      )
    end)
  end

  tool "get_quotes", "List the posts that quote a post." do
    annotations(%{readOnlyHint: true, openWorldHint: true})
    output_schema(AtMcp.MCP.Schemas.post_page())
    param(:uri, :string, required: true, description: "AT URI of the post")

    param(:limit, :integer, AtMcp.MCP.Schemas.page_limit("results"))

    param(:cursor, :string, description: "Continuation cursor returned by the previous page")

    run(fn a, state ->
      e = state.effects

      AtMcp.MCP.Tools.respond(
        AtMcp.Effects.get_quotes(e, Map.fetch!(a, :uri),
          limit: Map.get(a, :limit),
          cursor: Map.get(a, :cursor)
        ),
        state,
        :posts
      )
    end)
  end

  tool "get_actor_likes", "List the posts a handle or DID has liked." do
    annotations(%{readOnlyHint: true, openWorldHint: true})
    output_schema(AtMcp.MCP.Schemas.post_page())
    param(:actor, :string, required: true, description: "Handle or DID")

    param(:limit, :integer, AtMcp.MCP.Schemas.page_limit("results"))

    param(:cursor, :string, description: "Continuation cursor returned by the previous page")

    run(fn a, state ->
      e = state.effects

      AtMcp.MCP.Tools.respond(
        AtMcp.Effects.get_actor_likes(e, AtMcp.MCP.Tools.actor(Map.fetch!(a, :actor)),
          limit: Map.get(a, :limit),
          cursor: Map.get(a, :cursor)
        ),
        state,
        :posts
      )
    end)
  end

  # --- feeds other than the home timeline ---

  tool "get_feed",
       "Read a custom feed by its generator AT URI." do
    annotations(%{readOnlyHint: true, openWorldHint: true})
    output_schema(AtMcp.MCP.Schemas.post_page())

    param(:feed, :string,
      required: true,
      description: "AT URI of the feed generator record"
    )

    param(:limit, :integer, AtMcp.MCP.Schemas.page_limit("results"))

    param(:cursor, :string, description: "Continuation cursor returned by the previous page")

    run(fn a, state ->
      e = state.effects

      AtMcp.MCP.Tools.respond(
        AtMcp.Effects.get_feed(e, Map.fetch!(a, :feed),
          limit: Map.get(a, :limit),
          cursor: Map.get(a, :cursor)
        ),
        state,
        :posts
      )
    end)
  end

  tool "get_suggested_feeds",
       "List custom feeds the service currently suggests. Each item's uri is what get_feed, get_feed_info and like take. A first page also lists in app_pinned_feeds the feeds the app pins as tabs for every account, when it pins any." do
    annotations(%{readOnlyHint: true, openWorldHint: true})
    output_schema(AtMcp.MCP.Schemas.suggested_feeds_page())

    param(:source, :string,
      description:
        "default: the suggestions read in pages. unspecced: the newer suggestion service the app's feed discovery uses, one page with a smaller limit.",
      schema: %{type: "string", enum: ["default", "unspecced"]}
    )

    param(:limit, :integer, AtMcp.MCP.Schemas.page_limit("results"))

    param(:cursor, :string,
      description: "With source default: the cursor returned by the previous page"
    )

    run(fn a, state ->
      e = state.effects

      AtMcp.MCP.Tools.respond(
        AtMcp.Effects.get_suggested_feeds(e,
          source: Map.get(a, :source),
          limit: Map.get(a, :limit),
          cursor: Map.get(a, :cursor)
        ),
        state,
        :feeds
      )
    end)
  end

  tool "get_feed_info",
       AtMcp.MCP.Schemas.describe(
         "Read what the service knows about custom feeds, by their generator AT URIs ({batch} per call): name, description, maker, likes, and whether it takes feedback. Asked about one feed, it also says whether the feed's service is online and valid."
       ) do
    annotations(%{readOnlyHint: true, openWorldHint: true})
    output_schema(AtMcp.MCP.Schemas.feed_info_page())

    param(:uris, {:array, :string}, AtMcp.MCP.Schemas.batch("AT URIs of feed generators"))

    run(fn a, state ->
      AtMcp.MCP.Tools.respond(
        AtMcp.Effects.get_feed_info(state.effects, List.wrap(Map.get(a, :uris, []))),
        state,
        :feeds
      )
    end)
  end

  tool "get_actor_feeds",
       "List the custom feeds an account made: its profile's Feeds tab." do
    annotations(%{readOnlyHint: true, openWorldHint: true})
    output_schema(AtMcp.MCP.Schemas.generator_page())
    param(:actor, :string, required: true, description: "Handle or DID")
    param(:limit, :integer, AtMcp.MCP.Schemas.page_limit("feeds"))
    param(:cursor, :string, description: "Continuation cursor returned by the previous page")

    run(fn a, state ->
      AtMcp.MCP.Tools.respond(
        AtMcp.Effects.get_actor_feeds(
          state.effects,
          AtMcp.MCP.Tools.actor(Map.fetch!(a, :actor)),
          limit: Map.get(a, :limit),
          cursor: Map.get(a, :cursor)
        ),
        state,
        :feeds
      )
    end)
  end

  tool "search_feeds",
       "Search custom feeds by name and description, most popular first, as the app's feed search does. Without a query, the most popular feeds." do
    annotations(%{readOnlyHint: true, openWorldHint: true})
    output_schema(AtMcp.MCP.Schemas.generator_page())
    param(:query, :string, description: "Search query. Omit for the most popular feeds.")
    param(:limit, :integer, AtMcp.MCP.Schemas.page_limit("feeds"))
    param(:cursor, :string, description: "Continuation cursor returned by the previous page")

    run(fn a, state ->
      AtMcp.MCP.Tools.respond(
        AtMcp.Effects.search_feeds(state.effects, Map.get(a, :query),
          limit: Map.get(a, :limit),
          cursor: Map.get(a, :cursor)
        ),
        state,
        :feeds
      )
    end)
  end

  tool "get_suggested_starter_packs",
       "List starter packs the service suggests: named sets of accounts and feeds to follow at once. get_starter_pack reads one in full." do
    annotations(%{readOnlyHint: true, openWorldHint: true})
    output_schema(AtMcp.MCP.Schemas.starter_pack_page())

    param(:context, :string,
      description: "default, or onboarding: the packs suggested to a new account",
      schema: %{type: "string", enum: ["default", "onboarding"]}
    )

    param(:limit, :integer, AtMcp.MCP.Schemas.short_page_limit("starter packs"))

    run(fn a, state ->
      AtMcp.MCP.Tools.respond(
        AtMcp.Effects.get_suggested_starter_packs(state.effects,
          context: Map.get(a, :context),
          limit: Map.get(a, :limit)
        ),
        state,
        :starter_packs
      )
    end)
  end

  tool "get_trends",
       "Read what is trending on the network, as the app's Explore page shows it. kind trends: each trend with when it started, how many posts it has and some of the accounts posting. kind topics: trending topics, and topics suggested beside them. Each has a link: the feed or search the app opens for it." do
    annotations(%{readOnlyHint: true, openWorldHint: true})
    output_schema(AtMcp.MCP.Schemas.trend_page())

    param(:kind, :string,
      description: "trends (the default) or topics",
      schema: %{type: "string", enum: ["trends", "topics"]}
    )

    param(:limit, :integer, AtMcp.MCP.Schemas.short_page_limit("trends"))

    run(fn a, state ->
      AtMcp.MCP.Tools.respond(
        AtMcp.Effects.get_trends(
          state.effects,
          AtMcp.MCP.Tools.optional(Map.get(a, :kind)),
          limit: Map.get(a, :limit)
        ),
        state,
        :trends
      )
    end)
  end

  tool "get_list_feed", "Read the posts of the accounts on one list, by the list's AT URI." do
    annotations(%{readOnlyHint: true, openWorldHint: true})
    output_schema(AtMcp.MCP.Schemas.post_page())

    param(:list, :string,
      required: true,
      description: "AT URI of the list record"
    )

    param(:limit, :integer, AtMcp.MCP.Schemas.page_limit("results"))

    param(:cursor, :string, description: "Continuation cursor returned by the previous page")

    run(fn a, state ->
      e = state.effects

      AtMcp.MCP.Tools.respond(
        AtMcp.Effects.get_list_feed(e, Map.fetch!(a, :list),
          limit: Map.get(a, :limit),
          cursor: Map.get(a, :cursor)
        ),
        state,
        :posts
      )
    end)
  end

  # --- lists and starter packs ---

  tool "get_list",
       "Read one list: its name, purpose, creator and description, and a page of the accounts on it. Each account carries item_uri, the list item record that puts it there." do
    annotations(%{readOnlyHint: true, openWorldHint: true})
    output_schema(AtMcp.MCP.Schemas.list_page())
    param(:uri, :string, required: true, description: "AT URI of the list record")

    param(:limit, :integer, AtMcp.MCP.Schemas.page_limit("accounts"))

    param(:cursor, :string, description: "Continuation cursor returned by the previous page")

    run(fn a, state ->
      AtMcp.MCP.Tools.respond(
        AtMcp.Effects.get_list(state.effects, Map.fetch!(a, :uri),
          limit: Map.get(a, :limit),
          cursor: Map.get(a, :cursor)
        ),
        state,
        :list
      )
    end)
  end

  tool "get_lists",
       "List the curation and moderation lists an account made. With contains, list this account's own lists instead, each saying whether that account is on it. A starter pack's list is read with get_starter_packs." do
    annotations(%{readOnlyHint: true, openWorldHint: true})
    output_schema(AtMcp.MCP.Schemas.lists_page())

    param(:actor, :string,
      description: "Handle or DID whose lists to read. Omit for this account's own."
    )

    param(:purpose, :string,
      description: "curate or moderation: only lists of that kind. Omit for both.",
      schema: %{type: "string", enum: ["curate", "moderation"]}
    )

    param(:contains, :string,
      description:
        "Handle or DID. Reads this account's own lists, each with member_item: the list item that puts this account on it, or null."
    )

    param(:limit, :integer, AtMcp.MCP.Schemas.page_limit("lists"))

    param(:cursor, :string, description: "Continuation cursor returned by the previous page")

    run(fn a, state ->
      AtMcp.MCP.Tools.respond(
        AtMcp.Effects.get_lists(state.effects,
          actor: AtMcp.MCP.Tools.optional_actor(Map.get(a, :actor)),
          purpose: Map.get(a, :purpose),
          contains: AtMcp.MCP.Tools.optional_actor(Map.get(a, :contains)),
          limit: Map.get(a, :limit),
          cursor: Map.get(a, :cursor)
        ),
        state,
        :lists
      )
    end)
  end

  tool "get_starter_pack",
       "Read one starter pack: its name, description, creator, the feeds it recommends, a sample of its accounts, and its list, which get_list reads in full." do
    annotations(%{readOnlyHint: true, openWorldHint: true})
    output_schema(AtMcp.MCP.Schemas.starter_pack())
    param(:uri, :string, required: true, description: "AT URI of the starter pack record")

    run(fn a, state ->
      AtMcp.MCP.Tools.respond(
        AtMcp.Effects.get_starter_pack(state.effects, Map.fetch!(a, :uri)),
        state,
        :starter_pack
      )
    end)
  end

  tool "get_starter_packs",
       "List starter packs by exactly one of: actor, the packs an account made; query, a search; or contains, this account's own packs, each saying whether that account is in it." do
    annotations(%{readOnlyHint: true, openWorldHint: true})
    output_schema(AtMcp.MCP.Schemas.starter_pack_page())
    param(:actor, :string, description: "Handle or DID whose starter packs to read")
    param(:query, :string, description: "Search query")

    param(:contains, :string,
      description:
        "Handle or DID. Reads this account's own starter packs, each with member_item: the list item that puts this account in it, or null."
    )

    param(:limit, :integer, AtMcp.MCP.Schemas.page_limit("starter packs"))

    param(:cursor, :string, description: "Continuation cursor returned by the previous page")

    run(fn a, state ->
      AtMcp.MCP.Tools.respond(
        AtMcp.Effects.get_starter_packs(state.effects,
          actor: AtMcp.MCP.Tools.optional_actor(Map.get(a, :actor)),
          query: Map.get(a, :query),
          contains: AtMcp.MCP.Tools.optional_actor(Map.get(a, :contains)),
          limit: Map.get(a, :limit),
          cursor: Map.get(a, :cursor)
        ),
        state,
        :starter_packs
      )
    end)
  end

  tool "create_list",
       write_description(
         :create_list,
         "Make a list. A curate list gathers accounts, for a feed of their posts (get_list_feed) or for who may reply; a moderation list is for muting or blocking them together. The name and description are public. The result's uri is the list."
       ) do
    annotations(
      write_annotations(:create_list, %{
        readOnlyHint: false,
        destructiveHint: false,
        openWorldHint: true
      })
    )

    output_schema(AtMcp.MCP.Schemas.list_result())
    param(:name, :string, required: true, description: "The list's name, 1 to 64 bytes")

    param(:purpose, :string,
      required: true,
      description: "curate or moderation",
      schema: %{type: "string", enum: ["curate", "moderation"]}
    )

    param(:description, :string, description: "What the list is for, up to 300 characters")

    param(
      :avatar,
      :object,
      AtMcp.MCP.Schemas.image_upload(
        "The list's picture: base64 data or a file path, and its MIME type (image/png or image/jpeg, at most 1,000,000 bytes)"
      )
    )

    run(fn a, state ->
      AtMcp.MCP.Tools.respond(
        with {:ok, fields} <-
               AtMcp.MCP.Tools.list_fields(a, [:name, :purpose, :description, :avatar]) do
          AtMcp.Effects.create_list(state.effects, fields)
        end,
        state
      )
    end)
  end

  tool "update_list",
       write_description(
         :update_list,
         "Change a list this account made: its name, description or picture. Fields not given are kept; an empty description removes it."
       ) do
    annotations(
      write_annotations(:update_list, %{
        readOnlyHint: false,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: true
      })
    )

    output_schema(AtMcp.MCP.Schemas.list_result())
    param(:uri, :string, required: true, description: "AT URI of the list")
    param(:name, :string, description: "New name, 1 to 64 bytes")
    param(:description, :string, description: "New description, up to 300 characters")

    param(
      :avatar,
      :object,
      AtMcp.MCP.Schemas.image_upload(
        "New picture: base64 data or a file path, and its MIME type (image/png or image/jpeg, at most 1,000,000 bytes)"
      )
    )

    run(fn a, state ->
      AtMcp.MCP.Tools.respond(
        with {:ok, changes} <- AtMcp.MCP.Tools.list_fields(a, [:name, :description, :avatar]) do
          AtMcp.Effects.update_list(state.effects, Map.fetch!(a, :uri), changes)
        end,
        state
      )
    end)
  end

  tool "delete_list",
       write_description(
         :delete_list,
         "Delete a list this account made and every list item on it: in one commit, or for a list of more than 199 accounts in several, the list itself last. A starter pack's list is deleted with delete_starter_pack. The result's deleted names every record removed."
       ) do
    annotations(
      write_annotations(:delete_list, %{
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: true,
        openWorldHint: true
      })
    )

    output_schema(AtMcp.MCP.Schemas.list_result())
    param(:uri, :string, required: true, description: "AT URI of the list")

    run(fn a, state ->
      AtMcp.MCP.Tools.respond(
        AtMcp.Effects.delete_list(state.effects, Map.fetch!(a, :uri)),
        state
      )
    end)
  end

  tool "add_to_list",
       write_description(
         :add_to_list,
         "Put an account on a list or starter pack this account made. The result's uri is the list item; an account already on it is left as it is."
       ) do
    annotations(
      write_annotations(:add_to_list, %{
        readOnlyHint: false,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: true
      })
    )

    output_schema(AtMcp.MCP.Schemas.list_result())

    param(:list, :string,
      required: true,
      description: "AT URI of the list, or of a starter pack, whose list it then is"
    )

    param(:actor, :string, required: true, description: "Handle or DID")

    run(fn a, state ->
      AtMcp.MCP.Tools.respond(
        AtMcp.Effects.add_to_list(
          state.effects,
          Map.fetch!(a, :list),
          AtMcp.MCP.Tools.actor(Map.fetch!(a, :actor))
        ),
        state
      )
    end)
  end

  tool "remove_from_list",
       write_description(
         :remove_from_list,
         "Take an account off a list or starter pack this account made. Its list items are found by reading this account's own list item records, so no record key is needed."
       ) do
    annotations(
      write_annotations(:remove_from_list, %{
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: true,
        openWorldHint: true
      })
    )

    output_schema(AtMcp.MCP.Schemas.list_result())

    param(:list, :string,
      required: true,
      description: "AT URI of the list, or of a starter pack, whose list it then is"
    )

    param(:actor, :string, required: true, description: "Handle or DID")

    run(fn a, state ->
      AtMcp.MCP.Tools.respond(
        AtMcp.Effects.remove_from_list(
          state.effects,
          Map.fetch!(a, :list),
          AtMcp.MCP.Tools.actor(Map.fetch!(a, :actor))
        ),
        state
      )
    end)
  end

  tool "create_starter_pack",
       write_description(
         :create_starter_pack,
         "Make a starter pack: a named set of accounts and up to 3 feeds that someone new can follow at once. Writes its list, the list's items and the pack in one commit. The result's uri is the pack and list its list."
       ) do
    annotations(
      write_annotations(:create_starter_pack, %{
        readOnlyHint: false,
        destructiveHint: false,
        openWorldHint: true
      })
    )

    output_schema(AtMcp.MCP.Schemas.list_result())
    param(:name, :string, required: true, description: "The pack's name, up to 50 characters")
    param(:description, :string, description: "What the pack is for, up to 300 characters")

    param(
      :actors,
      {:array, :string},
      AtMcp.MCP.Schemas.pack_actors(
        "Handles or DIDs of the accounts in it. add_to_list adds more later"
      )
    )

    param(:feeds, {:array, :string},
      description: "AT URIs of up to 3 feed generators it recommends",
      schema: %{type: "array", maxItems: 3, items: %{type: "string"}}
    )

    run(fn a, state ->
      AtMcp.MCP.Tools.respond(
        AtMcp.Effects.create_starter_pack(state.effects, %{
          name: Map.fetch!(a, :name),
          description: Map.get(a, :description),
          actors: AtMcp.MCP.Tools.actors(Map.get(a, :actors, [])),
          feeds: Map.get(a, :feeds)
        }),
        state
      )
    end)
  end

  tool "update_starter_pack",
       write_description(
         :update_starter_pack,
         "Change a starter pack this account made: its name, description or feeds. Fields not given are kept; an empty description or feeds list removes it. Its accounts change with add_to_list and remove_from_list."
       ) do
    annotations(
      write_annotations(:update_starter_pack, %{
        readOnlyHint: false,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: true
      })
    )

    output_schema(AtMcp.MCP.Schemas.list_result())
    param(:uri, :string, required: true, description: "AT URI of the starter pack")
    param(:name, :string, description: "New name, up to 50 characters")
    param(:description, :string, description: "New description, up to 300 characters")

    param(:feeds, {:array, :string},
      description: "AT URIs of up to 3 feed generators, replacing the ones it has",
      schema: %{type: "array", maxItems: 3, items: %{type: "string"}}
    )

    run(fn a, state ->
      AtMcp.MCP.Tools.respond(
        with {:ok, changes} <- AtMcp.MCP.Tools.list_fields(a, [:name, :description, :feeds]) do
          AtMcp.Effects.update_starter_pack(state.effects, Map.fetch!(a, :uri), changes)
        end,
        state
      )
    end)
  end

  tool "delete_starter_pack",
       write_description(
         :delete_starter_pack,
         "Delete a starter pack this account made, with its list and the list's items. The result's deleted names every record removed."
       ) do
    annotations(
      write_annotations(:delete_starter_pack, %{
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: true,
        openWorldHint: true
      })
    )

    output_schema(AtMcp.MCP.Schemas.list_result())
    param(:uri, :string, required: true, description: "AT URI of the starter pack")

    run(fn a, state ->
      AtMcp.MCP.Tools.respond(
        AtMcp.Effects.delete_starter_pack(state.effects, Map.fetch!(a, :uri)),
        state
      )
    end)
  end

  tool "set_list_opt_out",
       write_description(
         :set_list_opt_out,
         "Ask to be left out of someone's starter pack (opted_out true), or take that back (false). The pack then stops showing this account to others. Applies only to a starter pack's list."
       ) do
    annotations(
      write_annotations(:set_list_opt_out, %{
        readOnlyHint: false,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: true
      })
    )

    output_schema(AtMcp.MCP.Schemas.list_result())

    param(:list, :string,
      required: true,
      description: "AT URI of the starter pack, or of its list"
    )

    param(:opted_out, :boolean,
      required: true,
      description: "true to be left out, false to be shown again"
    )

    run(fn a, state ->
      AtMcp.MCP.Tools.respond(
        AtMcp.Effects.set_list_opt_out(
          state.effects,
          Map.fetch!(a, :list),
          Map.fetch!(a, :opted_out)
        ),
        state
      )
    end)
  end

  # The post limit is not written into this description. A tool description is
  # evaluated when this module compiles, while the network is an
  # application-environment value read at runtime, so a number here would be
  # frozen at whatever the build machine was configured for and a release pointed
  # at another network would advertise the wrong one. `identity_status` reports
  # the limit, and a refusal names it; both run at call time.
  tool "post",
       write_description(
         :post,
         "Publish a top-level post as this account. reply_rule and quotes set who may reply and quote; they are written with the post in one commit, so it never exists without them."
       ) do
    annotations(
      write_annotations(:post, %{readOnlyHint: false, destructiveHint: false, openWorldHint: true})
    )

    output_schema(AtMcp.MCP.Schemas.write_result())

    param(:text, :string,
      required: true,
      description:
        "Post text. Longer than the network's post record allows is refused before anything is sent; identity_status reports the limit."
    )

    param(:langs, {:array, :string},
      description:
        "BCP-47 language tags for the text, e.g. [\"en\"] or [\"es\"]. Omit when the language is not known; the record then carries no language tags."
    )

    param(:quote, :string,
      description:
        "AT URI of a post to quote, or of a feed, list, starter pack or labeler to show as a card. Its CID is read from the record itself, so only the URI is needed."
    )

    param(
      :images,
      {:array, :object},
      AtMcp.MCP.Schemas.image_upload(
        "Images to attach. Each is base64 data or a file path, its MIME type, and alt text. Alt text is what a reader who cannot see the image gets.",
        alt: true
      )
    )

    param(:link, :object, AtMcp.MCP.Schemas.link())
    param(:labels, {:array, :string}, AtMcp.MCP.Schemas.self_labels())

    param(
      :reply_rule,
      {:array, :string},
      AtMcp.MCP.Schemas.reply_rule("Omit for everyone.")
    )

    param(:quotes, :string, AtMcp.MCP.Schemas.quotes("Omit for anyone."))

    run(fn a, state ->
      e = state.effects

      AtMcp.MCP.Tools.respond(
        with {:ok, opts} <- AtMcp.MCP.Tools.post_options(a) do
          AtMcp.Effects.post(e, Map.fetch!(a, :text), opts)
        end,
        state
      )
    end)
  end

  tool "reply",
       write_description(
         :reply,
         "Reply to a post by AT URI. A reply the thread's reply rule does not let this account make is refused before anything is sent, as the app disables reply there."
       ) do
    annotations(
      write_annotations(:reply, %{
        readOnlyHint: false,
        destructiveHint: false,
        openWorldHint: true
      })
    )

    output_schema(AtMcp.MCP.Schemas.write_result())
    param(:uri, :string, required: true, description: "Parent AT URI")

    param(:text, :string,
      required: true,
      description:
        "Reply text. Longer than the network's post record allows is refused before anything is sent; identity_status reports the limit."
    )

    param(:langs, {:array, :string},
      description:
        "BCP-47 language tags for the text, e.g. [\"en\"] or [\"es\"]. Omit when the language is not known; the record then carries no language tags."
    )

    param(:quote, :string,
      description:
        "AT URI of a post to quote, or of a feed, list, starter pack or labeler to show as a card. Its CID is read from the record itself, so only the URI is needed."
    )

    param(
      :images,
      {:array, :object},
      AtMcp.MCP.Schemas.image_upload(
        "Images to attach. Each is base64 data or a file path, its MIME type, and alt text. Alt text is what a reader who cannot see the image gets.",
        alt: true
      )
    )

    param(:link, :object, AtMcp.MCP.Schemas.link())
    param(:labels, {:array, :string}, AtMcp.MCP.Schemas.self_labels())
    param(:quotes, :string, AtMcp.MCP.Schemas.quotes("Omit for anyone."))

    run(fn a, state ->
      e = state.effects

      AtMcp.MCP.Tools.respond(
        with {:ok, opts} <- AtMcp.MCP.Tools.post_options(a) do
          AtMcp.Effects.reply(e, Map.fetch!(a, :uri), Map.fetch!(a, :text), opts)
        end,
        state
      )
    end)
  end

  tool "like",
       write_description(
         :like,
         "Like a post, a custom feed or a labeler by AT URI. Leave cid out and the AppView's CID for it is used. A cid is refused when the AppView has the subject and the cid differs from the record's, naming the record's. Anything else is refused: nothing would count the like. One this account has liked already (the AppView names the like and this account's repository holds it) is not liked again: the result names that like, with unchanged true."
       ) do
    annotations(
      write_annotations(:like, %{readOnlyHint: false, destructiveHint: false, openWorldHint: true})
    )

    output_schema(AtMcp.MCP.Schemas.record_result())

    param(:uri, :string,
      required: true,
      description: "AT URI of the post, feed generator or labeler"
    )

    param(:cid, :string, description: "Its CID. Optional: omit it to use the AppView's")

    run(fn a, state ->
      e = state.effects

      AtMcp.MCP.Tools.respond(
        AtMcp.Effects.like(e, Map.fetch!(a, :uri), Map.get(a, :cid)),
        state
      )
    end)
  end

  tool "unlike",
       write_description(
         :unlike,
         "Remove a like by the like record AT URI. When the AppView names another like of this account's for the same subject, that one is deleted too; deleted lists what was deleted."
       ) do
    annotations(
      write_annotations(:unlike, %{
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: true,
        openWorldHint: true
      })
    )

    output_schema(AtMcp.MCP.Schemas.action_result())

    param(:uri, :string,
      required: true,
      description:
        "Like record AT URI from the like result or viewer.like in get_posts/get_thread; not the liked post URI"
    )

    run(fn a, state ->
      e = state.effects
      AtMcp.MCP.Tools.respond(AtMcp.Effects.unlike(e, Map.fetch!(a, :uri)), state)
    end)
  end

  tool "repost",
       write_description(
         :repost,
         "Repost a post by AT URI. Leave cid out and the AppView's CID for it is used. A cid is refused when the AppView has the subject and the cid differs from the record's, naming the record's. A post this account has reposted already (the AppView names the repost and this account's repository holds it) is not reposted again: the result names that repost, with unchanged true, and nothing is counted."
       ) do
    annotations(
      write_annotations(:repost, %{
        readOnlyHint: false,
        destructiveHint: false,
        openWorldHint: true
      })
    )

    output_schema(AtMcp.MCP.Schemas.record_result())
    param(:uri, :string, required: true, description: "Post AT URI")
    param(:cid, :string, description: "Post CID. Optional: omit it to use the AppView's")

    run(fn a, state ->
      e = state.effects

      AtMcp.MCP.Tools.respond(
        AtMcp.Effects.repost(e, Map.fetch!(a, :uri), Map.get(a, :cid)),
        state
      )
    end)
  end

  tool "unrepost",
       write_description(
         :unrepost,
         "Remove a repost by the repost record AT URI. When the AppView names another repost of this account's of the same post, that one is deleted too; deleted lists what was deleted."
       ) do
    annotations(
      write_annotations(:unrepost, %{
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: true,
        openWorldHint: true
      })
    )

    output_schema(AtMcp.MCP.Schemas.action_result())

    param(:uri, :string,
      required: true,
      description:
        "Repost record AT URI from the repost result or viewer.repost in get_posts/get_thread; not the original post URI"
    )

    run(fn a, state ->
      e = state.effects
      AtMcp.MCP.Tools.respond(AtMcp.Effects.unrepost(e, Map.fetch!(a, :uri)), state)
    end)
  end

  tool "follow",
       write_description(
         :follow,
         "Follow an actor by handle or DID. One this account follows already (the AppView names the follow and this account's repository holds it) is not followed again: the result names that follow, with unchanged true."
       ) do
    annotations(
      write_annotations(:follow, %{
        readOnlyHint: false,
        destructiveHint: false,
        openWorldHint: true
      })
    )

    output_schema(AtMcp.MCP.Schemas.record_result())
    param(:actor, :string, required: true, description: "Handle or DID")

    run(fn a, state ->
      e = state.effects

      AtMcp.MCP.Tools.respond(
        AtMcp.Effects.follow(e, AtMcp.MCP.Tools.actor(Map.fetch!(a, :actor))),
        state
      )
    end)
  end

  tool "unfollow",
       write_description(
         :unfollow,
         "Unfollow by the follow record AT URI. Reads this account's repository and removes every shared and old Town follow of the same account in one conditional commit. A changed repository refuses the removal. deleted lists what was deleted. If the named record is gone, its subject is unknown and nothing is deleted."
       ) do
    annotations(
      write_annotations(:unfollow, %{
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: true,
        openWorldHint: true
      })
    )

    output_schema(AtMcp.MCP.Schemas.action_result())

    param(:uri, :string,
      required: true,
      description:
        "Follow record AT URI from the follow result or viewer.following in get_profile; not the actor DID"
    )

    run(fn a, state ->
      e = state.effects
      AtMcp.MCP.Tools.respond(AtMcp.Effects.unfollow(e, Map.fetch!(a, :uri)), state)
    end)
  end

  tool "block",
       write_description(
         :block,
         "Block an actor by handle or DID. One this account blocks already (the AppView names the block and this account's repository holds it) is not blocked again: the result names that block, with unchanged true."
       ) do
    annotations(
      write_annotations(:block, %{readOnlyHint: false, destructiveHint: true, openWorldHint: true})
    )

    output_schema(AtMcp.MCP.Schemas.record_result())
    param(:actor, :string, required: true, description: "Handle or DID")

    run(fn a, state ->
      e = state.effects

      AtMcp.MCP.Tools.respond(
        AtMcp.Effects.block(e, AtMcp.MCP.Tools.actor(Map.fetch!(a, :actor))),
        state
      )
    end)
  end

  tool "unblock",
       write_description(
         :unblock,
         "Unblock by the block record AT URI. Reads this account's repository and removes every shared and old Town block of the same account in one conditional commit. A changed repository refuses the removal. deleted lists what was deleted. If the named record is gone, its subject is unknown and nothing is deleted."
       ) do
    annotations(
      write_annotations(:unblock, %{
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: true,
        openWorldHint: true
      })
    )

    output_schema(AtMcp.MCP.Schemas.action_result())

    param(:uri, :string,
      required: true,
      description:
        "Block record AT URI from the block result or viewer.blocking in get_profile; not the actor DID"
    )

    run(fn a, state ->
      e = state.effects
      AtMcp.MCP.Tools.respond(AtMcp.Effects.unblock(e, Map.fetch!(a, :uri)), state)
    end)
  end

  tool "mute", write_description(:mute, "Mute an actor by handle or DID.") do
    annotations(
      write_annotations(:mute, %{
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: true,
        openWorldHint: true
      })
    )

    output_schema(AtMcp.MCP.Schemas.action_result())
    param(:actor, :string, required: true, description: "Handle or DID")

    run(fn a, state ->
      e = state.effects

      AtMcp.MCP.Tools.respond(
        AtMcp.Effects.mute(e, AtMcp.MCP.Tools.actor(Map.fetch!(a, :actor))),
        state
      )
    end)
  end

  tool "unmute", write_description(:unmute, "Unmute an actor by handle or DID.") do
    annotations(
      write_annotations(:unmute, %{
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: true,
        openWorldHint: true
      })
    )

    output_schema(AtMcp.MCP.Schemas.action_result())
    param(:actor, :string, required: true, description: "Handle or DID")

    run(fn a, state ->
      e = state.effects

      AtMcp.MCP.Tools.respond(
        AtMcp.Effects.unmute(e, AtMcp.MCP.Tools.actor(Map.fetch!(a, :actor))),
        state
      )
    end)
  end

  tool "delete_post",
       write_description(:delete_post, "Delete one of this account's posts by AT URI.") do
    annotations(
      write_annotations(:delete_post, %{
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: true,
        openWorldHint: true
      })
    )

    output_schema(AtMcp.MCP.Schemas.action_result())
    param(:uri, :string, required: true, description: "Post AT URI")

    run(fn a, state ->
      e = state.effects
      AtMcp.MCP.Tools.respond(AtMcp.Effects.delete_post(e, Map.fetch!(a, :uri)), state)
    end)
  end

  tool "put_record",
       write_description(
         :put_record,
         "Create or replace a record in this account's own repository, for an application at_mcp has no other tool for, such as an issue on Tangled (collection sh.tangled.repo.issue). If the account's server knows the collection's lexicon, it validates the record. Otherwise it stores the record as given, so check the application's lexicon for the fields. Posts, likes, follows, the profile and the other records at_mcp has its own tools for are refused, and the error tells you which tool to use. To replace a record safely, read it with get_record first and pass its cid. If someone changes the record between your read and your write, the write is refused. Returns the record's uri and cid."
       ) do
    annotations(
      # Without rkey, every call creates a new record.
      write_annotations(:put_record, %{
        readOnlyHint: false,
        destructiveHint: false,
        idempotentHint: false,
        openWorldHint: true
      })
    )

    output_schema(AtMcp.MCP.Schemas.record_write_result())

    param(:collection, :string,
      required: true,
      description: "The record's collection, an NSID such as sh.tangled.repo.issue"
    )

    param(:rkey, :string,
      description:
        "The record's key, the last part of the record's uri. If you leave it out, the server picks a new key and creates a new record. If you give it, at_mcp creates the record at that key, or replaces the record already there"
    )

    param(:record, :object,
      required: true,
      description:
        "The record as a JSON object, with field names exactly as the application's lexicon spells them. If you leave out $type, at_mcp sets it to the collection. If you give a $type, it must equal the collection"
    )

    param(:cid, :string,
      description:
        "The cid that get_record returned for the record you are replacing. Requires rkey. If the record's cid has changed since you read it, nothing is written"
    )

    run(fn a, state ->
      AtMcp.MCP.Tools.respond(
        AtMcp.Effects.put_record(
          state.effects,
          Map.fetch!(a, :collection),
          a[:rkey],
          Map.fetch!(a, :record),
          a[:cid]
        ),
        state
      )
    end)
  end

  tool "delete_record",
       write_description(
         :delete_record,
         "Delete a record from this account's own repository by collection and key. Use it for records of other applications. Posts, likes and the other records at_mcp has its own tools for are refused, and the error tells you which tool to use. If there is no record at that key, nothing is sent, nothing counts against the quota, and the result has unchanged: true."
       ) do
    annotations(
      write_annotations(:delete_record, %{
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: true,
        openWorldHint: true
      })
    )

    output_schema(AtMcp.MCP.Schemas.record_write_result())

    param(:collection, :string, required: true, description: "The record's collection, an NSID")
    param(:rkey, :string, required: true, description: "The record's key")

    param(:cid, :string,
      description:
        "The cid that get_record returned for the record. If the record's cid has changed since you read it, nothing is deleted"
    )

    run(fn a, state ->
      AtMcp.MCP.Tools.respond(
        AtMcp.Effects.delete_record(
          state.effects,
          Map.fetch!(a, :collection),
          Map.fetch!(a, :rkey),
          a[:cid]
        ),
        state
      )
    end)
  end

  tool "update_profile",
       write_description(
         :update_profile,
         "Update display name, description, avatar, banner, pronouns, website, the links the profile shows and/or the labels the account gives itself. On Delvetown, saves complete Town presentation and leaves the shared profile unchanged apart from its labels; links are unsupported. Fields not given keep their current presentation; empty text removes that field and stays blank on Town. The write is conditional on the records read. get_record on this account's profile record (rkey self) reads it back; on Delvetown, labels are on app.bsky.actor.profile."
       ) do
    annotations(
      write_annotations(:update_profile, %{
        readOnlyHint: false,
        destructiveHint: false,
        openWorldHint: true
      })
    )

    output_schema(AtMcp.MCP.Schemas.action_result())

    param(:display_name, :string,
      description: "New display name; empty clears it, omitted keeps it"
    )

    param(:description, :string,
      description: "New description; empty clears it, omitted keeps it"
    )

    param(
      :avatar,
      :object,
      AtMcp.MCP.Schemas.image_upload(
        "New avatar image: base64 data or a file path, and its MIME type"
      )
    )

    param(
      :banner,
      :object,
      AtMcp.MCP.Schemas.image_upload(
        "New banner image: base64 data or a file path, and its MIME type"
      )
    )

    param(:pronouns, :string, AtMcp.MCP.Schemas.pronouns())

    param(:website, :string,
      description: "An https:// URL the profile shows as its website. Empty removes it."
    )

    param(:links, {:array, :object}, AtMcp.MCP.Schemas.profile_links())

    param(:labels, {:array, :string},
      description:
        "Labels the account gives itself, such as bot for an automated account, replacing those it has; at most 10. [] removes them all. On Delvetown they go on the shared app.bsky.actor.profile record."
    )

    run(fn a, state ->
      e = state.effects
      AtMcp.MCP.Tools.respond(AtMcp.MCP.Tools.update_profile(e, a), state)
    end)
  end

  tool "update_seen", write_description(:update_seen, "Mark notifications as seen.") do
    annotations(
      write_annotations(:update_seen, %{
        readOnlyHint: false,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: true
      })
    )

    output_schema(AtMcp.MCP.Schemas.action_result())

    param(:seen_at, :string,
      description:
        "ISO 8601 date-time to mark seen up to, e.g. 2026-01-01T12:00:00Z; omitted, now. One that does not parse is refused and nothing is sent. One after now is sent as given, so notifications that arrive before it read as seen; the result's note says so"
    )

    run(fn a, state ->
      e = state.effects
      seen_at = AtMcp.MCP.Tools.optional(Map.get(a, :seen_at))
      AtMcp.MCP.Tools.respond(AtMcp.Effects.update_seen(e, seen_at), state)
    end)
  end

  # --- who may reply and quote ---

  tool "set_post_interactions",
       write_description(
         :set_post_interactions,
         "Set who may reply to one of this account's posts and whether others may quote it. A rule left out is kept as the post has it, as the app's dialog starts from the current settings; a rule given replaces it. Replies hidden and quotes detached stay as they are. Who may reply belongs to a thread's first post; for a reply, give no reply_rule. The result states both rules now in force (reply_rule, quotes) and names the threadgate and postgate the post has afterwards. When nothing would change, nothing is written and unchanged is true."
       ) do
    annotations(
      write_annotations(:set_post_interactions, %{
        readOnlyHint: false,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: true
      })
    )

    output_schema(AtMcp.MCP.Schemas.action_result())
    param(:uri, :string, required: true, description: "AT URI of a post this account wrote")

    param(
      :reply_rule,
      {:array, :string},
      AtMcp.MCP.Schemas.reply_rule("Omit to keep the post's current rule; given, it replaces it.")
    )

    param(
      :quotes,
      :string,
      AtMcp.MCP.Schemas.quotes("Omit to keep the post's current rule; given, it replaces it.")
    )

    run(fn a, state ->
      AtMcp.MCP.Tools.respond(
        AtMcp.Effects.set_post_interactions(
          state.effects,
          Map.fetch!(a, :uri),
          Map.get(a, :reply_rule),
          AtMcp.MCP.Tools.optional(Map.get(a, :quotes))
        ),
        state
      )
    end)
  end

  tool "hide_reply",
       write_description(
         :hide_reply,
         "Hide a reply in a thread this account started. Readers see it behind a warning, as hidden by the author. The reply stays; unhide_reply shows it again."
       ) do
    annotations(
      write_annotations(:hide_reply, %{
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: true,
        openWorldHint: true
      })
    )

    output_schema(AtMcp.MCP.Schemas.action_result())
    param(:uri, :string, required: true, description: "AT URI of the reply")

    run(fn a, state ->
      AtMcp.MCP.Tools.respond(
        AtMcp.Effects.hide_reply(state.effects, Map.fetch!(a, :uri), true),
        state
      )
    end)
  end

  tool "unhide_reply",
       write_description(:unhide_reply, "Show a reply hidden with hide_reply again.") do
    annotations(
      write_annotations(:unhide_reply, %{
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: true,
        openWorldHint: true
      })
    )

    output_schema(AtMcp.MCP.Schemas.action_result())
    param(:uri, :string, required: true, description: "AT URI of the reply")

    run(fn a, state ->
      AtMcp.MCP.Tools.respond(
        AtMcp.Effects.hide_reply(state.effects, Map.fetch!(a, :uri), false),
        state
      )
    end)
  end

  tool "detach_quote",
       write_description(
         :detach_quote,
         "Detach a post that quotes one of this account's posts: readers of the quoting post no longer see this account's post in it. The quoting post stays; reattach_quote undoes this."
       ) do
    annotations(
      write_annotations(:detach_quote, %{
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: true,
        openWorldHint: true
      })
    )

    output_schema(AtMcp.MCP.Schemas.action_result())
    param(:uri, :string, required: true, description: "AT URI of the post that quotes")

    run(fn a, state ->
      AtMcp.MCP.Tools.respond(
        AtMcp.Effects.detach_quote(state.effects, Map.fetch!(a, :uri), true),
        state
      )
    end)
  end

  tool "reattach_quote",
       write_description(
         :reattach_quote,
         "Undo detach_quote: show this account's post in the post quoting it again."
       ) do
    annotations(
      write_annotations(:reattach_quote, %{
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: true,
        openWorldHint: true
      })
    )

    output_schema(AtMcp.MCP.Schemas.action_result())
    param(:uri, :string, required: true, description: "AT URI of the post that quotes")

    run(fn a, state ->
      AtMcp.MCP.Tools.respond(
        AtMcp.Effects.detach_quote(state.effects, Map.fetch!(a, :uri), false),
        state
      )
    end)
  end

  # --- saved feeds, live status and feed feedback ---

  tool "save_feed",
       write_description(
         :save_feed,
         "Save a custom feed or a list to this account's feeds, pinned (a tab on its home screen) or not. A feed already saved is pinned or unpinned as pinned says, and left as it is when pinned is left out; one already as asked is left alone and unchanged is true. Saved feeds are a preference: the preferences are read and written back whole, every other one kept, and the service offers no compare-and-swap for them, so a change another client makes in between is lost."
       ) do
    annotations(
      write_annotations(:save_feed, %{
        readOnlyHint: false,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: true
      })
    )

    output_schema(AtMcp.MCP.Schemas.action_result())
    param(:uri, :string, required: true, description: "AT URI of the feed generator or list")

    param(:pinned, :boolean,
      description:
        "true to pin it as a home screen tab, false to unpin it. Left out: a saved feed keeps its pin, and a new one is not pinned."
    )

    run(fn a, state ->
      AtMcp.MCP.Tools.respond(
        AtMcp.Effects.save_feed(state.effects, Map.fetch!(a, :uri), Map.get(a, :pinned)),
        state
      )
    end)
  end

  tool "unsave_feed",
       write_description(
         :unsave_feed,
         "Remove a custom feed or a list from this account's saved feeds. Preferences are written back whole, as for save_feed."
       ) do
    annotations(
      write_annotations(:unsave_feed, %{
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: true,
        openWorldHint: true
      })
    )

    output_schema(AtMcp.MCP.Schemas.action_result())
    param(:uri, :string, required: true, description: "AT URI of the feed generator or list")

    run(fn a, state ->
      AtMcp.MCP.Tools.respond(
        AtMcp.Effects.unsave_feed(state.effects, Map.fetch!(a, :uri)),
        state
      )
    end)
  end

  tool "set_status",
       write_description(
         :set_status,
         "Say this account is live, streaming at a URL, for a while (kind live), or end it (kind clear). Others see a Live badge on its avatar until it expires. The app shows the badge only for links to streaming sites it recognizes, such as twitch.tv, youtube.com and stream.place; another link is written and shown nowhere as live. The result's replaced is the status it replaced or cleared: its url, duration_minutes and created_at. Setting that url and duration again starts a new status from now, without the old card's title and description."
       ) do
    annotations(
      write_annotations(:set_status, %{
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: true,
        openWorldHint: true
      })
    )

    output_schema(AtMcp.MCP.Schemas.action_result())

    param(:kind, :string,
      required: true,
      description: "live or clear",
      schema: %{type: "string", enum: ["live", "clear"]}
    )

    param(:url, :string, description: "With live: where to watch, an http or https URL")
    param(:duration_minutes, :integer, AtMcp.MCP.Schemas.status_minutes())
    param(:title, :string, description: "With live: the link card's title")
    param(:description, :string, description: "With live: the link card's description")

    run(fn a, state ->
      AtMcp.MCP.Tools.respond(
        AtMcp.Effects.set_status(state.effects, Map.fetch!(a, :kind),
          url: Map.get(a, :url),
          duration_minutes: Map.get(a, :duration_minutes),
          title: AtMcp.MCP.Tools.optional(Map.get(a, :title)),
          description: AtMcp.MCP.Tools.optional(Map.get(a, :description))
        ),
        state
      )
    end)
  end

  tool "feed_feedback",
       write_description(
         :feed_feedback,
         "Tell a custom feed to show more, or less, like one of the posts it showed, as the app's menu on a feed item does. It goes to the feed's own service, not to the account's followers. Only a feed that takes feedback accepts it: one whose generator accepts interactions (get_feed_info says takes feedback), or the app's own Discover and video feeds, which always do. Another is refused before anything is sent."
       ) do
    annotations(
      write_annotations(:feed_feedback, %{
        readOnlyHint: false,
        destructiveHint: false,
        openWorldHint: true
      })
    )

    output_schema(AtMcp.MCP.Schemas.action_result())
    param(:feed, :string, required: true, description: "AT URI of the feed generator")
    param(:uri, :string, required: true, description: "AT URI of the post the feed showed")

    param(:kind, :string,
      required: true,
      description: "show_more or show_less",
      schema: %{type: "string", enum: ["show_more", "show_less"]}
    )

    param(:feed_context, :string,
      description: "The post's feed_context from get_feed, when the feed gave one"
    )

    param(:req_id, :string,
      description: "The post's req_id from get_feed, when the feed gave one"
    )

    run(fn a, state ->
      AtMcp.MCP.Tools.respond(
        AtMcp.Effects.feed_feedback(
          state.effects,
          Map.fetch!(a, :feed),
          Map.fetch!(a, :uri),
          Map.fetch!(a, :kind),
          feed_context: AtMcp.MCP.Tools.optional(Map.get(a, :feed_context)),
          req_id: AtMcp.MCP.Tools.optional(Map.get(a, :req_id))
        ),
        state
      )
    end)
  end

  # --- settings: preferences, notification settings, activity subscriptions ---

  tool "get_preferences",
       "Read this account's settings as the app shows them: the Following feed's (home_feed), threads', the reply and quote rules each new post starts with (interaction_defaults), adult content (with whether the account has a birth date and whether it makes the account 18 or over; the date itself is not read out), interests, verification checks, the saved feeds, whether the account asks apps to keep its posts out of recommendations (discoverable), and who may subscribe to its posts (activity_subscriptions); and the moderation settings: muted words (mute_word, unmute_word), the labelers the app takes labels from (subscribe_labeler, get_labelers) and what the app does with each adult content label (content_labels, set_label_visibility). set_preference changes the rest, save_feed and unsave_feed the saved feeds." do
    annotations(%{readOnlyHint: true, openWorldHint: true})
    output_schema(AtMcp.MCP.Schemas.preferences())

    run(fn _a, state ->
      AtMcp.MCP.Tools.respond(AtMcp.Effects.get_preferences(state.effects), state, :preferences)
    end)
  end

  tool "set_preference",
       write_description(
         :set_preference,
         "Change one of this account's settings, as the app's settings screens do. kind names the setting, and only its own fields are taken; a field left out keeps its value. home_feed: the Following feed (hide_replies, hide_reposts, hide_quotes, saved_feed_samples). threads: sort and tree_view. interaction_defaults: the reply_rule and quotes the app's composer starts each new post with; post does not read them. adult_content: enabled. interests: tags. verification: hide_badges. discoverable: hide_from_recommendations. activity_subscriptions: allow. home_feed, threads, adult_content and verification change what the app shows; at_mcp's reads return what the service serves either way. The result names the fields that changed (changed), with the setting's fields before (previous) and after (now); a setting already as asked is left alone and unchanged is true. discoverable and activity_subscriptions are records of the account's, written over the version read. The rest are preferences, read and written back whole with every other one kept; the service offers no compare-and-swap for them, so a change another client makes in between is lost."
       ) do
    annotations(
      write_annotations(:set_preference, %{
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: true,
        openWorldHint: true
      })
    )

    output_schema(AtMcp.MCP.Schemas.action_result())
    param(:kind, :string, AtMcp.MCP.Schemas.preference_kind())
    param(:hide_replies, :boolean, description: "home_feed: hide replies")
    param(:hide_reposts, :boolean, description: "home_feed: hide reposts")
    param(:hide_quotes, :boolean, description: "home_feed: hide quote posts")

    param(:saved_feed_samples, :boolean,
      description:
        "home_feed: show samples of the saved feeds in the Following feed (an experiment in the app)"
    )

    param(:sort, :string, AtMcp.MCP.Schemas.thread_sort())
    param(:tree_view, :boolean, description: "threads: show replies as a tree")

    param(
      :reply_rule,
      {:array, :string},
      AtMcp.MCP.Schemas.reply_rule("interaction_defaults: the rule each new post starts with.")
    )

    param(
      :quotes,
      :string,
      AtMcp.MCP.Schemas.quotes("interaction_defaults: the rule each new post starts with.")
    )

    param(:enabled, :boolean,
      description:
        "adult_content: show adult content. The app shows it only to an account whose birth date makes it 18 or over, and not in regions that require an age check; true is refused for an account whose birth date does not"
    )

    param(:tags, {:array, :string}, AtMcp.MCP.Schemas.interests())

    param(:hide_badges, :boolean,
      description: "verification: hide the verification checks the app shows beside names"
    )

    param(:hide_from_recommendations, :boolean,
      description:
        "discoverable: ask apps to keep this account's posts out of algorithmic recommendations, such as a discover feed"
    )

    param(:allow, :string, AtMcp.MCP.Schemas.subscription_allow())

    run(fn a, state ->
      AtMcp.MCP.Tools.respond(
        AtMcp.Effects.set_preference(
          state.effects,
          Map.fetch!(a, :kind),
          Map.new(AtMcp.Preferences.all_fields(), &{&1, Map.get(a, &1)})
        ),
        state
      )
    end)
  end

  tool "get_notification_settings",
       "Read this account's notification settings: for each reason, from whom (include: all, or follows, for the reasons that have it), whether the app lists them in the account's notifications (list) and whether they are pushed to phones signed in to the account (push). set_notification_setting changes them." do
    annotations(%{readOnlyHint: true, openWorldHint: true})
    output_schema(AtMcp.MCP.Schemas.notification_settings())

    run(fn _a, state ->
      AtMcp.MCP.Tools.respond(
        AtMcp.Effects.get_notification_settings(state.effects),
        state,
        :notification_settings
      )
    end)
  end

  tool "set_notification_setting",
       write_description(
         :set_notification_setting,
         "Change this account's notification setting for one reason, as the app's notification settings do: include (from all, or only accounts this account follows), list (the app lists them in the account's notifications) and push (they are pushed to phones signed in to the account; at_mcp delivers notifications itself, not by push). A field left out keeps its value. The result names the fields that changed, with the setting before (previous) and as the service now keeps it (now); a setting already as asked is left alone and unchanged is true. Chat notifications belong to the chat service and are not set here."
       ) do
    annotations(
      write_annotations(:set_notification_setting, %{
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: true,
        openWorldHint: true
      })
    )

    output_schema(AtMcp.MCP.Schemas.action_result())
    param(:reason, :string, AtMcp.MCP.Schemas.notification_setting_reason())
    param(:include, :string, AtMcp.MCP.Schemas.notification_include())
    param(:list, :boolean, description: "List them in the account's notifications")
    param(:push, :boolean, description: "Push them to phones signed in to the account")

    run(fn a, state ->
      AtMcp.MCP.Tools.respond(
        AtMcp.Effects.set_notification_setting(state.effects, Map.fetch!(a, :reason),
          include: Map.get(a, :include),
          list: Map.get(a, :list),
          push: Map.get(a, :push)
        ),
        state
      )
    end)
  end

  tool "subscribe_to_activity",
       write_description(
         :subscribe_to_activity,
         "Subscribe to an account's activity, as the bell on its profile does in the app: posts true makes each of its new posts a notification (reason subscribed-post), and replies true its replies too, which needs posts. Both false unsubscribes, and is sent even when no subscription shows, as a block hides one. Each account says who may subscribe to it (followers, the default; mutuals; or none); a subscription it does not allow is refused before anything is sent. The result names the account and its subscription before (previous) and now; one already as asked is left alone and unchanged is true. get_profile (activity_subscription) and get_activity_subscriptions read it back."
       ) do
    annotations(
      write_annotations(:subscribe_to_activity, %{
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: true,
        openWorldHint: true
      })
    )

    output_schema(AtMcp.MCP.Schemas.action_result())
    param(:actor, :string, required: true, description: "Handle or DID of the account")

    param(:posts, :boolean,
      required: true,
      description: "Get a notification for each of its new posts"
    )

    param(:replies, :boolean,
      required: true,
      description: "Get one for each of its replies too; needs posts"
    )

    run(fn a, state ->
      AtMcp.MCP.Tools.respond(
        AtMcp.Effects.subscribe_to_activity(
          state.effects,
          AtMcp.MCP.Tools.actor(Map.fetch!(a, :actor)),
          Map.fetch!(a, :posts),
          Map.fetch!(a, :replies)
        ),
        state
      )
    end)
  end

  tool "get_activity_subscriptions",
       "List the accounts this account is subscribed to (subscribe_to_activity), each with what it gets of them (activity_subscription)." do
    annotations(%{readOnlyHint: true, openWorldHint: true})
    output_schema(AtMcp.MCP.Schemas.profile_page())
    param(:limit, :integer, AtMcp.MCP.Schemas.page_limit("accounts"))
    param(:cursor, :string, description: "Continuation cursor returned by the previous page")

    run(fn a, state ->
      AtMcp.MCP.Tools.respond(
        AtMcp.Effects.get_activity_subscriptions(state.effects,
          limit: Map.get(a, :limit),
          cursor: Map.get(a, :cursor)
        ),
        state,
        :profiles
      )
    end)
  end

  # --- moderation: reports, muted words, moderation lists, labelers ---

  tool "report",
       write_description(
         :report,
         "Report a post, list, feed, starter pack or account to a moderation service, as the app's Report menu does. The service's moderators see the report and which account sent it, and decide what, if anything, to do about it; at_mcp does not publish it, and it cannot be withdrawn. labeler names the service: the network's own moderation service when omitted, or a labeler this account subscribes to that takes reports on this kind of subject and for this reason (get_labelers says which). The result names the report's id at that service (id) and the service it went to (labeler, labeler_handle). The account's own posts and the account itself cannot be reported."
       ) do
    annotations(
      write_annotations(:report, %{
        readOnlyHint: false,
        destructiveHint: false,
        idempotentHint: false,
        openWorldHint: true
      })
    )

    output_schema(AtMcp.MCP.Schemas.moderation_result())

    param(:subject, :string,
      required: true,
      description:
        "AT URI of the post, list, feed or starter pack, or a handle or DID for an account"
    )

    param(:reason, :string, AtMcp.MCP.Schemas.report_reason())

    param(:details, :string,
      description: "What the moderators should know, up to 2,000 characters"
    )

    param(:labeler, :string,
      description:
        "Handle or DID of the moderation service to send it to; the network's own when omitted"
    )

    run(fn a, state ->
      AtMcp.MCP.Tools.respond(
        AtMcp.Effects.report(
          state.effects,
          AtMcp.MCP.Tools.actor(Map.fetch!(a, :subject)),
          Map.fetch!(a, :reason),
          details: AtMcp.MCP.Tools.optional(Map.get(a, :details)),
          labeler: AtMcp.MCP.Tools.optional_actor(Map.get(a, :labeler))
        ),
        state
      )
    end)
  end

  tool "mute_word",
       write_description(
         :mute_word,
         "Mute a word, tag or phrase, as the app's muted words settings do: the app hides posts containing it from this account. tags_only mutes it only as a hashtag; only_non_followed mutes it only in posts by accounts this account does not follow; duration is 24h, 7d, 30d or forever (the default). targets and expires_at say the same as tags_only and duration in the stored form, so a word unmute_word removed can be muted again exactly as it was (with a new id). A word muted already, ignoring case, is changed to this rather than muted twice; one muted exactly so is left alone and unchanged is true. The app applies muted words on the device: at_mcp's reads return the posts as the service serves them. The result gives the muted word before (previous, empty when it was not muted) and after (now). Preferences are read and written back whole with every other one kept; the service offers no compare-and-swap for them, so a change another client makes in between is lost."
       ) do
    annotations(
      write_annotations(:mute_word, %{
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: true,
        openWorldHint: true
      })
    )

    output_schema(AtMcp.MCP.Schemas.moderation_result())

    param(:value, :string,
      required: true,
      description: "The word, tag or phrase; a leading # is dropped, as the app drops it"
    )

    param(:tags_only, :boolean,
      description: "Mute it only as a hashtag, not in post text (default false)"
    )

    param(:targets, {:array, :string},
      description:
        "Instead of tags_only, the targets as stored, such as a muted word unmute_word returned holds: tag, content, or both"
    )

    param(:duration, :string, AtMcp.MCP.Schemas.mute_duration())

    param(:expires_at, :string,
      description:
        "Instead of duration, when the mute ends, as an ISO 8601 datetime, such as a muted word unmute_word returned holds"
    )

    param(:only_non_followed, :boolean,
      description:
        "Mute it only in posts by accounts this account does not follow (default false)"
    )

    run(fn a, state ->
      AtMcp.MCP.Tools.respond(
        AtMcp.Effects.mute_word(state.effects, Map.fetch!(a, :value),
          tags_only: Map.get(a, :tags_only),
          targets: AtMcp.MCP.Tools.optional(Map.get(a, :targets)),
          duration: AtMcp.MCP.Tools.optional(Map.get(a, :duration)),
          expires_at: AtMcp.MCP.Tools.optional(Map.get(a, :expires_at)),
          only_non_followed: Map.get(a, :only_non_followed)
        ),
        state
      )
    end)
  end

  tool "unmute_word",
       write_description(
         :unmute_word,
         "Unmute a muted word, tag or phrase: every muted word with this value, ignoring case, is removed. The result lists each one removed as it was (removed); mute_word with its value, targets, only_non_followed and expires_at mutes it again exactly so; a value that is not muted is left alone and unchanged is true. Preferences are read and written back whole with every other one kept; the service offers no compare-and-swap for them, so a change another client makes in between is lost."
       ) do
    annotations(
      write_annotations(:unmute_word, %{
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: true,
        openWorldHint: true
      })
    )

    output_schema(AtMcp.MCP.Schemas.moderation_result())
    param(:value, :string, required: true, description: "The muted word, tag or phrase")

    run(fn a, state ->
      AtMcp.MCP.Tools.respond(
        AtMcp.Effects.unmute_word(state.effects, Map.fetch!(a, :value)),
        state
      )
    end)
  end

  tool "mute_list",
       write_description(
         :mute_list,
         "Mute every account on a moderation list, as the app's Mute list does: while the list is muted, each account on it is muted for this account as mute would mute it, and reads say so (muted_by_list). Mutes are private to the account. Only a moderation list can be muted. The result names the list and whether it was muted before (previous); unmute_list undoes it."
       ) do
    annotations(
      write_annotations(:mute_list, %{
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: true,
        openWorldHint: true
      })
    )

    output_schema(AtMcp.MCP.Schemas.moderation_result())
    param(:uri, :string, required: true, description: "AT URI of the moderation list")

    run(fn a, state ->
      AtMcp.MCP.Tools.respond(AtMcp.Effects.mute_list(state.effects, Map.fetch!(a, :uri)), state)
    end)
  end

  tool "unmute_list",
       write_description(
         :unmute_list,
         "Unmute the accounts on a list muted with mute_list. The result names the list and whether it was muted before (previous)."
       ) do
    annotations(
      write_annotations(:unmute_list, %{
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: true,
        openWorldHint: true
      })
    )

    output_schema(AtMcp.MCP.Schemas.moderation_result())
    param(:uri, :string, required: true, description: "AT URI of the list")

    run(fn a, state ->
      AtMcp.MCP.Tools.respond(
        AtMcp.Effects.unmute_list(state.effects, Map.fetch!(a, :uri)),
        state
      )
    end)
  end

  tool "block_list",
       write_description(
         :block_list,
         "Block every account on a moderation list, as the app's Block list does: while the list is blocked, each account on it is blocked for this account as block would block it, and reads say so (blocking_by_list). The block is a list block record in this account's repository, and records are public. Only a moderation list can be blocked. A list this account blocks already is left as it is and unchanged is true. The result's uri is the list block; unblock_list takes it or the list."
       ) do
    annotations(
      write_annotations(:block_list, %{
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: true,
        openWorldHint: true
      })
    )

    output_schema(AtMcp.MCP.Schemas.moderation_result())
    param(:uri, :string, required: true, description: "AT URI of the moderation list")

    run(fn a, state ->
      AtMcp.MCP.Tools.respond(
        AtMcp.Effects.block_list(state.effects, Map.fetch!(a, :uri)),
        state
      )
    end)
  end

  tool "unblock_list",
       write_description(
         :unblock_list,
         "Stop blocking the accounts on a list: every list block record of this account's that names the list is deleted, in one commit. uri is the list, or a list block from block_list or a list's viewer.blocked. deleted names each record deleted; a list this account does not block is left alone and unchanged is true."
       ) do
    annotations(
      write_annotations(:unblock_list, %{
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: true,
        openWorldHint: true
      })
    )

    output_schema(AtMcp.MCP.Schemas.moderation_result())
    param(:uri, :string, required: true, description: "AT URI of the list, or of a list block")

    run(fn a, state ->
      AtMcp.MCP.Tools.respond(
        AtMcp.Effects.unblock_list(state.effects, Map.fetch!(a, :uri)),
        state
      )
    end)
  end

  tool "get_moderation_lists",
       "List the moderation lists this account mutes (kind muted, mute_list) or blocks (kind blocked, block_list), each with its viewer state." do
    annotations(%{readOnlyHint: true, openWorldHint: true})
    output_schema(AtMcp.MCP.Schemas.lists_page())

    param(:kind, :string,
      required: true,
      description: "muted or blocked",
      schema: %{type: "string", enum: ["muted", "blocked"]}
    )

    param(:limit, :integer, AtMcp.MCP.Schemas.page_limit("lists"))
    param(:cursor, :string, description: "Continuation cursor returned by the previous page")

    run(fn a, state ->
      AtMcp.MCP.Tools.respond(
        AtMcp.Effects.get_moderation_lists(state.effects, Map.fetch!(a, :kind),
          limit: Map.get(a, :limit),
          cursor: Map.get(a, :cursor)
        ),
        state,
        :lists
      )
    end)
  end

  tool "get_labelers",
       AtMcp.MCP.Schemas.describe(
         "Read labelers (moderation services) in detail: the labels each defines, with what the app does with each for this account (setting), the reports it takes (reason_types, subject_types, subject_collections; null means any), and whether this account subscribes to it. Without actors, the labelers the app takes labels from for this account: the network's own moderation service and those it subscribes to ({batch} actors per call)."
       ) do
    annotations(%{readOnlyHint: true, openWorldHint: true})
    output_schema(AtMcp.MCP.Schemas.labelers())

    param(:actors, {:array, :string}, AtMcp.MCP.Schemas.labeler_actors())

    run(fn a, state ->
      AtMcp.MCP.Tools.respond(
        AtMcp.Effects.get_labelers(
          state.effects,
          AtMcp.MCP.Tools.actors(AtMcp.MCP.Tools.optional(Map.get(a, :actors)) || [])
        ),
        state,
        :labelers
      )
    end)
  end

  tool "subscribe_labeler",
       write_description(
         :subscribe_labeler,
         "Subscribe to a labeler, as its Subscribe button in the app does: the app then applies the labels it puts on posts and accounts (as set_label_visibility sets them for this account) and offers it in the report dialog. The network's own moderation service is always on and is not subscribed to. The app allows 20 labelers, the network's own included. at_mcp's reads do not yet ask for the labels of the labelers this account subscribes to, so they may not carry this one's. The result gives whether it was subscribed before (previous) and now (now); one subscribed already is left alone and unchanged is true. Preferences are read and written back whole with every other one kept; the service offers no compare-and-swap for them, so a change another client makes in between is lost."
       ) do
    annotations(
      write_annotations(:subscribe_labeler, %{
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: true,
        openWorldHint: true
      })
    )

    output_schema(AtMcp.MCP.Schemas.moderation_result())
    param(:actor, :string, required: true, description: "Handle or DID of the labeler")

    run(fn a, state ->
      AtMcp.MCP.Tools.respond(
        AtMcp.Effects.subscribe_labeler(
          state.effects,
          AtMcp.MCP.Tools.actor(Map.fetch!(a, :actor)),
          true
        ),
        state
      )
    end)
  end

  tool "unsubscribe_labeler",
       write_description(
         :unsubscribe_labeler,
         "Unsubscribe from a labeler subscribed to with subscribe_labeler: the app stops applying its labels. Its label settings stay stored, as the app keeps them. The result gives whether it was subscribed before (previous); one not subscribed to is left alone and unchanged is true. Preferences are read and written back whole with every other one kept; the service offers no compare-and-swap for them, so a change another client makes in between is lost."
       ) do
    annotations(
      write_annotations(:unsubscribe_labeler, %{
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: true,
        openWorldHint: true
      })
    )

    output_schema(AtMcp.MCP.Schemas.moderation_result())
    param(:actor, :string, required: true, description: "Handle or DID of the labeler")

    run(fn a, state ->
      AtMcp.MCP.Tools.respond(
        AtMcp.Effects.subscribe_labeler(
          state.effects,
          AtMcp.MCP.Tools.actor(Map.fetch!(a, :actor)),
          false
        ),
        state
      )
    end)
  end

  tool "set_label_visibility",
       write_description(
         :set_label_visibility,
         "Set what the app does with posts and accounts that carry a label: show them, warn (cover them with a warning to click through) or hide them. Without labeler, label is one of the app's adult content filters (porn, sexual, graphic-media, nudity), which apply whichever labeler applied the label; the app shows these only while adult content is on. With labeler, a label that labeler defines (get_labelers lists them), for a labeler the app takes labels from for this account. The app applies this on the device: at_mcp's reads return each post's labels as served. The result gives the setting before (previous) and after (now); one already as asked is left alone and unchanged is true. Preferences are read and written back whole with every other one kept; the service offers no compare-and-swap for them, so a change another client makes in between is lost."
       ) do
    annotations(
      write_annotations(:set_label_visibility, %{
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: true,
        openWorldHint: true
      })
    )

    output_schema(AtMcp.MCP.Schemas.moderation_result())

    param(:label, :string,
      required: true,
      description:
        "The label: porn, sexual, graphic-media or nudity without labeler, or a label the labeler defines"
    )

    param(:visibility, :string, AtMcp.MCP.Schemas.label_visibility())

    param(:labeler, :string,
      description:
        "Handle or DID of the labeler that defines the label; omit for the app's adult content filters"
    )

    run(fn a, state ->
      AtMcp.MCP.Tools.respond(
        AtMcp.Effects.set_label_visibility(
          state.effects,
          Map.fetch!(a, :label),
          Map.fetch!(a, :visibility),
          AtMcp.MCP.Tools.optional_actor(Map.get(a, :labeler))
        ),
        state
      )
    end)
  end

  # --- pins, thread mutes and bookmarks ---

  tool "pin_post",
       write_description(
         :pin_post,
         "Pin one of this account's posts to the top of its profile, replacing any post pinned before. Writes the profile record and keeps every other field of it. The result's replaced_uri is the post that was pinned before, if any."
       ) do
    annotations(
      write_annotations(:pin_post, %{
        readOnlyHint: false,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: true
      })
    )

    output_schema(AtMcp.MCP.Schemas.action_result())
    param(:uri, :string, required: true, description: "AT URI of a post this account wrote")

    run(fn a, state ->
      AtMcp.MCP.Tools.respond(AtMcp.Effects.pin_post(state.effects, Map.fetch!(a, :uri)), state)
    end)
  end

  tool "unpin_post",
       write_description(
         :unpin_post,
         "Remove the pinned post from this account's profile. The post itself stays. The result's replaced_uri is the post that was pinned; when nothing was pinned, nothing is written and it is null."
       ) do
    annotations(
      write_annotations(:unpin_post, %{
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: true,
        openWorldHint: true
      })
    )

    output_schema(AtMcp.MCP.Schemas.action_result())

    run(fn _a, state ->
      AtMcp.MCP.Tools.respond(AtMcp.Effects.unpin_post(state.effects), state)
    end)
  end

  tool "mute_thread",
       write_description(
         :mute_thread,
         "Mute a thread: this account gets no notifications from it. Any post in the thread names it; the result's uri is the thread's first post. Thread mutes are private to the account."
       ) do
    annotations(
      write_annotations(:mute_thread, %{
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: true,
        openWorldHint: true
      })
    )

    output_schema(AtMcp.MCP.Schemas.action_result())
    param(:uri, :string, required: true, description: "AT URI of any post in the thread")

    run(fn a, state ->
      AtMcp.MCP.Tools.respond(
        AtMcp.Effects.mute_thread(state.effects, Map.fetch!(a, :uri)),
        state
      )
    end)
  end

  tool "unmute_thread",
       write_description(
         :unmute_thread,
         "Unmute a thread muted with mute_thread. Any post in the thread names it."
       ) do
    annotations(
      write_annotations(:unmute_thread, %{
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: true,
        openWorldHint: true
      })
    )

    output_schema(AtMcp.MCP.Schemas.action_result())
    param(:uri, :string, required: true, description: "AT URI of any post in the thread")

    run(fn a, state ->
      AtMcp.MCP.Tools.respond(
        AtMcp.Effects.unmute_thread(state.effects, Map.fetch!(a, :uri)),
        state
      )
    end)
  end

  tool "bookmark",
       write_description(
         :bookmark,
         "Bookmark a post to read later. Bookmarks are private to this account; get_bookmarks lists them."
       ) do
    annotations(
      write_annotations(:bookmark, %{
        readOnlyHint: false,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: true
      })
    )

    output_schema(AtMcp.MCP.Schemas.action_result())
    param(:uri, :string, required: true, description: "AT URI of the post")

    run(fn a, state ->
      AtMcp.MCP.Tools.respond(AtMcp.Effects.bookmark(state.effects, Map.fetch!(a, :uri)), state)
    end)
  end

  tool "unbookmark",
       write_description(:unbookmark, "Remove a post from this account's bookmarks.") do
    annotations(
      write_annotations(:unbookmark, %{
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: true,
        openWorldHint: true
      })
    )

    output_schema(AtMcp.MCP.Schemas.action_result())
    param(:uri, :string, required: true, description: "AT URI of the bookmarked post")

    run(fn a, state ->
      AtMcp.MCP.Tools.respond(AtMcp.Effects.unbookmark(state.effects, Map.fetch!(a, :uri)), state)
    end)
  end

  tool "get_bookmarks",
       "List this account's bookmarked posts. A bookmarked post that was deleted or is hidden by a block keeps its place and says so." do
    annotations(%{readOnlyHint: true, openWorldHint: true})
    output_schema(AtMcp.MCP.Schemas.bookmark_page())

    param(:limit, :integer, AtMcp.MCP.Schemas.page_limit("bookmarks"))

    param(:cursor, :string, description: "Continuation cursor returned by the previous page")

    run(fn a, state ->
      AtMcp.MCP.Tools.respond(
        AtMcp.Effects.get_bookmarks(state.effects,
          limit: Map.get(a, :limit),
          cursor: Map.get(a, :cursor)
        ),
        state,
        :bookmarks
      )
    end)
  end

  # --- drafts ---

  tool "get_drafts",
       "List this account's drafts: posts written and not yet published. Drafts are private. Each item's id is what save_draft and delete_draft take." do
    annotations(%{readOnlyHint: true, openWorldHint: true})
    output_schema(AtMcp.MCP.Schemas.draft_page())

    param(:limit, :integer, AtMcp.MCP.Schemas.page_limit("drafts"))

    param(:cursor, :string, description: "Continuation cursor returned by the previous page")

    run(fn a, state ->
      AtMcp.MCP.Tools.respond(
        AtMcp.Effects.get_drafts(state.effects,
          limit: Map.get(a, :limit),
          cursor: Map.get(a, :cursor)
        ),
        state
      )
    end)
  end

  tool "save_draft",
       write_description(
         :save_draft,
         "Save text as a draft to publish later; nothing is published. Without id, creates a new draft and returns its id. With the id of one of this account's drafts, replaces the text of its first post and keeps the rest of the draft; an id this account does not have is refused. After an update the draft is checked to still exist; the result is the draft as sent, and the change may take a moment to show in get_drafts."
       ) do
    annotations(
      write_annotations(:save_draft, %{
        readOnlyHint: false,
        destructiveHint: false,
        openWorldHint: true
      })
    )

    output_schema(AtMcp.MCP.Schemas.draft_result())

    param(:text, :string, AtMcp.MCP.Schemas.draft_text())

    param(:id, :string,
      description: "Id of a draft to replace, from get_drafts or an earlier save_draft"
    )

    run(fn a, state ->
      AtMcp.MCP.Tools.respond(
        AtMcp.Effects.save_draft(
          state.effects,
          Map.fetch!(a, :text),
          AtMcp.MCP.Tools.optional(Map.get(a, :id))
        ),
        state
      )
    end)
  end

  tool "delete_draft",
       write_description(
         :delete_draft,
         "Delete one of this account's drafts. The result carries the draft as it was, so save_draft can recreate it."
       ) do
    annotations(
      write_annotations(:delete_draft, %{
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: true,
        openWorldHint: true
      })
    )

    output_schema(AtMcp.MCP.Schemas.draft_result())
    param(:id, :string, required: true, description: "The draft's id, from get_drafts")

    run(fn a, state ->
      AtMcp.MCP.Tools.respond(
        AtMcp.Effects.delete_draft(state.effects, Map.fetch!(a, :id)),
        state
      )
    end)
  end

  tool "get_record",
       "Read one record exactly as its repository holds it, by AT URI: any collection, any account. Use it for what no other read shows, such as a post's threadgate or a record of another application; the reads made for posts, profiles, lists and feeds are easier to read." do
    annotations(%{readOnlyHint: true, openWorldHint: true})
    output_schema(AtMcp.MCP.Schemas.record_view())
    param(:uri, :string, required: true, description: "AT URI of the record")

    run(fn a, state ->
      AtMcp.MCP.Tools.respond(AtMcp.Effects.get_record(state.effects, Map.fetch!(a, :uri)), state)
    end)
  end

  tool "get_invite_codes",
       "List this account's delve.town invitation codes, as the town's app shows them: each code, how many accounts it admits and who has used it. Like the app, it first collects any codes the account has earned since it last looked. Only on delve.town." do
    annotations(%{readOnlyHint: true, openWorldHint: true})
    output_schema(AtMcp.MCP.Schemas.invite_codes())

    run(fn _a, state ->
      AtMcp.MCP.Tools.respond(AtMcp.Effects.get_invite_codes(state.effects), state, :invite_codes)
    end)
  end

  tool "get_policy",
       "Read the text of one of delve.town's policy pages, which https://delve.town/support lists: the Community Rules, the AI Agent Policy, the Terms of Service, the Privacy Notice, or the Reporting and Appeals Policy. Only on delve.town." do
    annotations(%{readOnlyHint: true, openWorldHint: true})
    output_schema(AtMcp.MCP.Schemas.policy())

    param(:page, :string, AtMcp.MCP.Schemas.policy_page())

    run(fn a, state ->
      AtMcp.MCP.Tools.respond(
        AtMcp.Effects.get_policy(state.effects, Map.fetch!(a, :page)),
        state,
        :policy
      )
    end)
  end

  tool "get_membership",
       "Read your Delvetown membership. enabled says whether the service uses membership; null membership means no membership record. Otherwise inspect joined, status and suspended together. A service error does not mean you have not joined. Admission currently happens through delve.town; this tool does not join." do
    annotations(%{readOnlyHint: true, openWorldHint: true})
    output_schema(AtMcp.MCP.Schemas.membership())

    run(fn _a, state ->
      AtMcp.MCP.Tools.respond(AtMcp.Effects.get_membership(state.effects), state)
    end)
  end

  tool "identity_status",
       "Report login status, DID, the network this account acts on, and the write quota." do
    annotations(%{readOnlyHint: true, openWorldHint: true})
    output_schema(AtMcp.MCP.Schemas.identity_status())

    run(fn _a, state ->
      e = state.effects
      AtMcp.MCP.Tools.respond(AtMcp.MCP.Tools.identity_status(e), state)
    end)
  end
end
