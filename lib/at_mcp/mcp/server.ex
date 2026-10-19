defmodule AtMcp.MCP.Server do
  @moduledoc """
  HTTP/stdio MCP surface for one identity on this network.

  Each network verb is one MCP tool. Tools call `AtMcp.Effects` and return
  summaries (never raw session dumps): as structured content, and as text for
  a model, which is the JSON of the summary except for reads made of posts,
  where it is `AtMcp.Reading`'s text of it.

  Tool calls go through AtMcp.Effects, which checks that the account is ready and
  counts what the account publishes against its write quota. Each write tool's
  description and `kite/publicWrite` annotation say whether it counts, derived
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
    {:ok, %{effects: effects, scope: Keyword.get(args, :scope)}}
  end

  tool "get_notifications", "Read recent notifications on this network for this account." do
    annotations(%{readOnlyHint: true, openWorldHint: true})
    output_schema(AtMcp.MCP.Schemas.notification_page())

    param(:limit, :integer, AtMcp.MCP.Schemas.page_limit("notifications"))

    param(:cursor, :string, description: "Continuation cursor returned by the previous page")

    run(fn a, state ->
      e = state.effects

      AtMcp.MCP.Tools.respond(
        AtMcp.Effects.list_notifications(e,
          limit: Map.get(a, :limit),
          cursor: Map.get(a, :cursor)
        ),
        state,
        :notifications
      )
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

    param(:before, :string,
      description:
        "AT URI from a previous call's chain_before. Given it, the chain ends at that post instead of at uri, which is how a conversation taller than one chain is read upward without repeating or skipping a post. A page read this way carries no replies."
    )

    run(fn a, state ->
      e = state.effects

      AtMcp.MCP.Tools.respond(
        AtMcp.Effects.get_thread_chain(e, Map.fetch!(a, :uri), before: Map.get(a, :before)),
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
        state
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
        state
      )
    end)
  end

  tool "search_posts",
       "Search public posts on this network by query string. Optional author, mentions, sort, since, until and lang narrow the same search; they are not a second query language." do
    annotations(%{readOnlyHint: true, openWorldHint: true})
    output_schema(AtMcp.MCP.Schemas.post_page())
    param(:query, :string, required: true, description: "Search query")

    param(:limit, :integer, AtMcp.MCP.Schemas.page_limit("results"))

    param(:cursor, :string, description: "Continuation cursor returned by the previous page")

    param(:author, :string, description: "Handle or DID; only posts by this account")

    param(:mentions, :string, description: "Handle or DID; only posts that mention this account")

    param(:sort, :string,
      description: "latest or top. Omit for the service default.",
      schema: %{type: "string", enum: ["latest", "top"]}
    )

    param(:since, :string,
      description: "ISO 8601 timestamp; only posts indexed after this instant"
    )

    param(:until, :string,
      description: "ISO 8601 timestamp; only posts indexed before this instant"
    )

    param(:lang, :string, description: "BCP-47 language tag, e.g. en")

    run(fn a, state ->
      e = state.effects

      AtMcp.MCP.Tools.respond(
        AtMcp.Effects.search_posts(e, Map.fetch!(a, :query),
          limit: Map.get(a, :limit),
          cursor: Map.get(a, :cursor),
          author: AtMcp.MCP.Tools.optional_actor(Map.get(a, :author)),
          mentions: AtMcp.MCP.Tools.optional_actor(Map.get(a, :mentions)),
          sort: Map.get(a, :sort),
          since: Map.get(a, :since),
          until: Map.get(a, :until),
          lang: Map.get(a, :lang)
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
        state
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
        state
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
        state
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
        state
      )
    end)
  end

  tool "get_suggested_follows",
       "Accounts the service suggests as similar to a handle or DID. Suggestions come from the service, not from AtMcp." do
    annotations(%{readOnlyHint: true, openWorldHint: true})
    output_schema(AtMcp.MCP.Schemas.profile_page())
    param(:actor, :string, required: true, description: "Handle or DID")

    run(fn a, state ->
      e = state.effects

      AtMcp.MCP.Tools.respond(
        AtMcp.Effects.get_suggested_follows(e, AtMcp.MCP.Tools.actor(Map.fetch!(a, :actor))),
        state
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
        state
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
        state
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
        state
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
        state
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
       "List custom feeds the service currently suggests. Each item's uri is what get_feed takes." do
    annotations(%{readOnlyHint: true, openWorldHint: true})
    output_schema(AtMcp.MCP.Schemas.generator_page())

    param(:limit, :integer, AtMcp.MCP.Schemas.page_limit("results"))

    param(:cursor, :string, description: "Continuation cursor returned by the previous page")

    run(fn a, state ->
      e = state.effects

      AtMcp.MCP.Tools.respond(
        AtMcp.Effects.get_suggested_feeds(e,
          limit: Map.get(a, :limit),
          cursor: Map.get(a, :cursor)
        ),
        state
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
        "AT URI of a post to quote. Its CID is read from the record itself, so only the URI is needed."
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

  tool "reply", write_description(:reply, "Reply to a post by AT URI.") do
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
        "AT URI of a post to quote. Its CID is read from the record itself, so only the URI is needed."
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

  tool "like", write_description(:like, "Like a post by AT URI and CID.") do
    annotations(
      write_annotations(:like, %{readOnlyHint: false, destructiveHint: false, openWorldHint: true})
    )

    output_schema(AtMcp.MCP.Schemas.record_result())
    param(:uri, :string, required: true, description: "Post AT URI")
    param(:cid, :string, required: true, description: "Post CID")

    run(fn a, state ->
      e = state.effects

      AtMcp.MCP.Tools.respond(
        AtMcp.Effects.like(e, Map.fetch!(a, :uri), Map.fetch!(a, :cid)),
        state
      )
    end)
  end

  tool "unlike", write_description(:unlike, "Remove a like by the like record AT URI.") do
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

  tool "repost", write_description(:repost, "Repost by AT URI and CID.") do
    annotations(
      write_annotations(:repost, %{
        readOnlyHint: false,
        destructiveHint: false,
        openWorldHint: true
      })
    )

    output_schema(AtMcp.MCP.Schemas.record_result())
    param(:uri, :string, required: true, description: "Post AT URI")
    param(:cid, :string, required: true, description: "Post CID")

    run(fn a, state ->
      e = state.effects

      AtMcp.MCP.Tools.respond(
        AtMcp.Effects.repost(e, Map.fetch!(a, :uri), Map.fetch!(a, :cid)),
        state
      )
    end)
  end

  tool "unrepost", write_description(:unrepost, "Remove a repost by the repost record AT URI.") do
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

  tool "follow", write_description(:follow, "Follow an actor by handle or DID.") do
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

  tool "unfollow", write_description(:unfollow, "Unfollow by the follow record AT URI.") do
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

  tool "block", write_description(:block, "Block an actor by handle or DID.") do
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

  tool "unblock", write_description(:unblock, "Unblock by the block record AT URI.") do
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

  tool "update_profile",
       write_description(
         :update_profile,
         "Update display name, description, avatar and/or banner. Fields not given are kept."
       ) do
    annotations(
      write_annotations(:update_profile, %{
        readOnlyHint: false,
        destructiveHint: false,
        openWorldHint: true
      })
    )

    output_schema(AtMcp.MCP.Schemas.action_result())
    param(:display_name, :string, description: "New display name")
    param(:description, :string, description: "New description")

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
    param(:seen_at, :string, description: "ISO8601 timestamp")

    run(fn a, state ->
      e = state.effects
      AtMcp.MCP.Tools.respond(AtMcp.Effects.update_seen(e, Map.get(a, :seen_at)), state)
    end)
  end

  # --- who may reply and quote ---

  tool "set_post_interactions",
       write_description(
         :set_post_interactions,
         "Set who may reply to one of this account's posts and whether others may quote it. Both are set at once, as the app's dialog sets them: an omitted reply_rule means everyone may reply, an omitted quotes means anyone may quote. Replies hidden and quotes detached stay as they are. Who may reply belongs to a thread's first post; for a reply, give no reply_rule. The result names the threadgate and postgate the post has afterwards."
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
      AtMcp.MCP.Schemas.reply_rule("Omit for everyone; this replaces the post's current rule.")
    )

    param(
      :quotes,
      :string,
      AtMcp.MCP.Schemas.quotes("Omitted: anyone may; this replaces the post's current rule.")
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
         "Save text as a draft to publish later; nothing is published. Without id, creates a new draft and returns its id. With the id of one of this account's drafts, replaces the text of its first post and keeps the rest of the draft; an id this account does not have is refused. The draft is read back after an update, so the result is what the service holds."
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
