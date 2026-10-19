defmodule AtMcp.DiscoveryTest do
  @moduledoc """
  Feeds and discovery (#93): the reads.

  The first part calls the tools through the MCP surface over the mock
  backend: what each refuses before anything is sent, and the text a model
  reads. The second runs the real backend against a fake PDS and checks what
  reached the wire: the method each place in the app calls, on this network's
  namespace, the parameters it takes, and a handle-form AT URI asked for in
  its DID form. What delve.town does not serve is refused there before
  anything is sent (`AtMcp.Endpoints.deployments/0`).
  """
  use ExUnit.Case, async: false

  alias AtMcp.Test.FakePDS

  defp mock do
    {:ok, effects} =
      AtMcp.Test.QuotaFixture.start_effects(
        backend: AtMcp.Test.MockBackend,
        backend_state: %{mock: true, did: "did:plc:mock", handle: "mock.test"},
        quota_limit: 1
      )

    %{effects: effects}
  end

  defp call(state, name, arguments) do
    {:ok, result, ^state} = AtMcp.MCP.Server.handle_call_tool(name, arguments, state)
    result
  end

  defp refused(result, path) do
    assert result.isError, inspect(result)
    assert %{code: "invalid_arguments", problems: [%{path: ^path}]} = result.structuredContent
    assert hd(result.content).text =~ "Nothing was sent"
    hd(result.content).text
  end

  @feed "at://did:plc:mock/app.bsky.feed.generator/whats-hot"

  describe "through the tools, over the mock backend" do
    test "get_suggested_follows reads one place in the app, the Explore page by default" do
      state = mock()

      assert %{"method" => "unspecced.getSuggestedUsersForExplore"} =
               call(state, "get_suggested_follows", %{}).structuredContent

      for {context, method} <- [
            {"discover", "unspecced.getSuggestedUsersForDiscover"},
            {"see_more", "unspecced.getSuggestedUsersForSeeMore"},
            {"onboarding", "unspecced.getSuggestedOnboardingUsers"},
            {"general", "unspecced.getSuggestedUsers"},
            {"browse", "actor.getSuggestions"}
          ] do
        assert %{"method" => ^method} =
                 call(state, "get_suggested_follows", %{"context" => context}).structuredContent
      end

      assert %{"category" => "art"} =
               call(state, "get_suggested_follows", %{"category" => "art"}).structuredContent
    end

    test "get_suggested_follows refuses what the place it reads does not take" do
      state = mock()

      assert refused(
               call(state, "get_suggested_follows", %{"actor" => "a.test", "context" => "explore"}),
               "context"
             ) =~ "with actor"

      refused(
        call(state, "get_suggested_follows", %{"context" => "discover", "category" => "art"}),
        "category"
      )

      refused(call(state, "get_suggested_follows", %{"cursor" => "c"}), "cursor")
    end

    test "a read whose method takes fewer than a page refuses more, naming limit" do
      state = mock()

      assert refused(
               call(state, "get_suggested_feeds", %{"source" => "unspecced", "limit" => 26}),
               "limit"
             ) =~ "at most #{AtMcp.Effects.short_page_max()}"

      refused(
        call(state, "get_suggested_feeds", %{"source" => "unspecced", "cursor" => "c"}),
        "cursor"
      )
    end

    test "get_feed_info takes feed generators only, and get_record an AT URI" do
      state = mock()

      assert refused(
               call(state, "get_feed_info", %{
                 "uris" => [@feed, "at://did:plc:mock/app.bsky.graph.list/l1"]
               }),
               "uris"
             ) =~ "feed generator"

      refused(call(state, "get_record", %{"uri" => "did:plc:mock"}), "uri")
    end

    test "search_posts takes a query, a filter or both, and refuses a hashtag too long" do
      state = mock()

      refused(call(state, "search_posts", %{"sort" => "top"}), "query")

      assert %{"filters" => %{"hashtags" => ["kites"], "replies" => "only"}} =
               call(state, "search_posts", %{"hashtags" => ["#kites"], "replies" => "only"}).structuredContent

      %{graphemes: graphemes} = AtMcp.Effects.hashtag_limits()

      refused(
        call(state, "search_posts", %{"hashtags" => [String.duplicate("k", graphemes + 1)]}),
        "hashtags"
      )
    end

    test "reads are text a model reads, with the uri and cid a write tool takes" do
      state = mock()

      feeds = hd(call(state, "get_feed_info", %{"uris" => [@feed]}).content).text
      assert feeds =~ ~s(1 feed.)
      assert feeds =~ ~s([1] "What's hot" · by @alice.bsky.social · 3 likes · online)
      assert feeds =~ "uri: #{@feed} · cid: bafyGEN"

      trends = hd(call(state, "get_trends", %{"kind" => "topics"}).content).text
      assert trends =~ "[1] Kites · hot · sports · 12 posts · since 2026-10-18T00:00:00Z"
      assert trends =~ "Posting: Alice (@alice.test)"
      assert trends =~ "link: /search?q=kites"
      assert trends =~ "Suggested beside them: Kites · /search?q=kites"

      codes = hd(call(state, "get_invite_codes", %{}).content).text
      assert codes =~ "1 invitation code. Earned codes: enabled."
      assert codes =~ "[1] town-abcde · 1 of 1 uses left"
    end
  end

  describe "on delve.town" do
    setup do
      Application.put_env(:at_mcp, :network, :delve)
      on_exit(fn -> Application.delete_env(:at_mcp, :network) end)
      :ok
    end

    test "what the town does not serve is refused before anything is sent" do
      %{effects: effects, pds: pds} = pds()
      state = %{effects: effects}

      for {name, args, method} <- [
            {"get_trends", %{}, "town.delve.unspecced.getTrends"},
            {"get_trends", %{"kind" => "topics"}, "town.delve.unspecced.getTrendingTopics"},
            {"get_suggested_follows", %{"context" => "general"},
             "town.delve.unspecced.getSuggestedUsers"},
            {"get_suggested_feeds", %{"source" => "unspecced"},
             "town.delve.unspecced.getSuggestedFeeds"}
          ] do
        result = call(state, name, args)
        assert result.isError, name
        assert %{code: "not_served", method: ^method} = result.structuredContent
        assert hd(result.content).text =~ "delve.town does not serve #{method}"
        assert hd(result.content).text =~ "Nothing was sent"
      end

      assert FakePDS.methods(pds) == []
    end

    test "each place in the app that suggests accounts reads its own method" do
      %{effects: effects, pds: pds} =
        pds(%{
          "town.delve.unspecced.getSuggestedUsersForExplore" => {200, %{actors: []}},
          "town.delve.unspecced.getSuggestedOnboardingUsers" => {200, %{actors: []}},
          "town.delve.actor.getSuggestions" => {200, %{actors: [], cursor: "next"}},
          "town.delve.graph.getSuggestedFollowsByActor" => {200, %{suggestions: []}}
        })

      assert {:ok, _} = AtMcp.Effects.get_suggested_follows(effects, nil, category: "art")
      assert {:ok, _} = AtMcp.Effects.get_suggested_follows(effects, nil, context: "onboarding")

      assert {:ok, %{cursor: "next"}} =
               AtMcp.Effects.get_suggested_follows(effects, nil, context: "browse", cursor: "c")

      assert {:ok, _} = AtMcp.Effects.get_suggested_follows(effects, "alice.test")

      assert [%{query: %{"category" => "art", "limit" => "20"}}] =
               FakePDS.sent(pds, "town.delve.unspecced.getSuggestedUsersForExplore")

      assert [%{query: query}] =
               FakePDS.sent(pds, "town.delve.unspecced.getSuggestedOnboardingUsers")

      refute Map.has_key?(query, "category")

      assert [%{query: %{"cursor" => "c"}}] = FakePDS.sent(pds, "town.delve.actor.getSuggestions")
      assert [_] = FakePDS.sent(pds, "town.delve.graph.getSuggestedFollowsByActor")
    end

    test "get_feed_info asks for one feed with whether it is online, and several together" do
      generator = fn uri ->
        %{
          uri: uri,
          cid: "bafygen",
          did: "did:web:feeds.example",
          creator: %{did: "did:plc:alice", handle: "alice.test"},
          displayName: "Kites",
          acceptsInteractions: true,
          indexedAt: "2026-10-18T00:00:00.000Z"
        }
      end

      one = "at://did:plc:alice/town.delve.feed.generator/kites"
      two = "at://did:plc:alice/town.delve.feed.generator/gone"

      %{effects: effects, pds: pds} =
        pds(%{
          "town.delve.feed.getFeedGenerator" =>
            {200, %{view: generator.(one), isOnline: false, isValid: true}},
          "town.delve.feed.getFeedGenerators" => {200, %{feeds: [generator.(one)]}}
        })

      assert {:ok, %{items: [item], not_found: []}} =
               AtMcp.Effects.get_feed_info(effects, [
                 "at://alice.test/town.delve.feed.generator/kites"
               ])

      assert %{uri: ^one, is_online: false, is_valid: true, accepts_interactions: true} = item

      # A handle-form uri is asked for in the DID form the AppView keys feeds by.
      assert [%{query: %{"feed" => ^one}}] = FakePDS.sent(pds, "town.delve.feed.getFeedGenerator")

      assert {:ok, %{items: [item], not_found: [^two]}} =
               AtMcp.Effects.get_feed_info(effects, [one, two])

      assert %{is_online: nil, is_valid: nil} = item

      assert [%{raw: raw}] = FakePDS.sent(pds, "town.delve.feed.getFeedGenerators")
      assert raw =~ "feeds=#{URI.encode_www_form(one)}&feeds=#{URI.encode_www_form(two)}"
    end

    test "feeds by an account, by search and suggested read this network's methods" do
      %{effects: effects, pds: pds} =
        pds(%{
          "town.delve.feed.getActorFeeds" => {200, %{feeds: []}},
          "town.delve.unspecced.getPopularFeedGenerators" => {200, %{feeds: []}},
          "town.delve.feed.getSuggestedFeeds" => {200, %{feeds: []}},
          "town.delve.unspecced.getSuggestedStarterPacks" => {200, %{starterPacks: []}},
          "town.delve.unspecced.getOnboardingSuggestedStarterPacks" => {200, %{starterPacks: []}}
        })

      assert {:ok, %{count: 0}} = AtMcp.Effects.get_actor_feeds(effects, "alice.test", limit: 5)
      assert {:ok, _} = AtMcp.Effects.search_feeds(effects, "kites")
      assert {:ok, _} = AtMcp.Effects.search_feeds(effects, " ")
      assert {:ok, _} = AtMcp.Effects.get_suggested_feeds(effects, cursor: "c")
      assert {:ok, _} = AtMcp.Effects.get_suggested_starter_packs(effects, limit: 3)
      assert {:ok, _} = AtMcp.Effects.get_suggested_starter_packs(effects, context: "onboarding")

      assert [%{query: %{"actor" => "alice.test", "limit" => "5"}}] =
               FakePDS.sent(pds, "town.delve.feed.getActorFeeds")

      assert [%{query: %{"query" => "kites"}}, %{query: popular}] =
               FakePDS.sent(pds, "town.delve.unspecced.getPopularFeedGenerators")

      refute Map.has_key?(popular, "query")

      assert [%{query: %{"cursor" => "c"}}] =
               FakePDS.sent(pds, "town.delve.feed.getSuggestedFeeds")

      assert [%{query: %{"limit" => "3"}}] =
               FakePDS.sent(pds, "town.delve.unspecced.getSuggestedStarterPacks")

      assert [_] = FakePDS.sent(pds, "town.delve.unspecced.getOnboardingSuggestedStarterPacks")
    end

    test "a custom feed named with a handle is read by its DID form" do
      %{effects: effects, pds: pds} = pds(%{"town.delve.feed.getFeed" => {200, %{feed: []}}})

      assert {:ok, _} =
               AtMcp.Effects.get_feed(effects, "at://alice.test/town.delve.feed.generator/kites")

      assert [%{query: %{"feed" => "at://did:plc:alice/town.delve.feed.generator/kites"}}] =
               FakePDS.sent(pds, "town.delve.feed.getFeed")
    end

    test "search_posts asks searchPostsV2 with the parameters it names" do
      %{effects: effects, pds: pds} =
        pds(%{"town.delve.feed.searchPostsV2" => {200, %{posts: [], cursor: "next"}}})

      assert {:ok, %{cursor: "next"}} =
               AtMcp.Effects.search_posts(effects, "kites",
                 author: "alice.test",
                 sort: "latest",
                 lang: "en",
                 exclude_authors: ["bob.test", "carol.test"],
                 hashtags: ["#kites"],
                 reply_to: "at://alice.test/town.delve.feed.post/p",
                 replies: "only",
                 has_media: true,
                 following: false
               )

      assert [%{query: query, raw: raw}] = FakePDS.sent(pds, "town.delve.feed.searchPostsV2")

      assert %{
               "query" => "kites",
               "authors" => "alice.test",
               "sort" => "recent",
               "languages" => "en",
               "hashtags" => "kites",
               "replyParentUri" => "at://did:plc:alice/town.delve.feed.post/p",
               "repliesOnly" => "true",
               "hasMedia" => "true"
             } = query

      assert raw =~ "excludeAuthors=bob.test&excludeAuthors=carol.test"
      refute Map.has_key?(query, "following")
      refute Map.has_key?(query, "excludeReplies")

      lexicon =
        "test/fixtures/lexicons/app/bsky/feed/searchPostsV2.json"
        |> File.read!()
        |> Jason.decode!()
        |> get_in(["defs", "main", "parameters", "properties"])

      for key <- Map.keys(query), do: assert(Map.has_key?(lexicon, key), key)
    end

    test "get_record returns the record as stored, every key as written" do
      value = %{
        "$type" => "town.delve.feed.threadgate",
        "post" => "at://did:plc:alice/town.delve.feed.post/p",
        "createdAt" => "2026-10-18T00:00:00.000Z",
        "snake_key" => %{"nestedCamel" => 1}
      }

      %{effects: effects, pds: pds} =
        pds(%{
          "com.atproto.repo.getRecord" =>
            {200,
             %{
               uri: "at://did:plc:alice/town.delve.feed.threadgate/p",
               cid: "bafygate",
               value: value
             }}
        })

      assert {:ok, %{uri: "at://did:plc:alice/town.delve.feed.threadgate/p", value: ^value}} =
               AtMcp.Effects.get_record(effects, "at://alice.test/town.delve.feed.threadgate/p")

      assert [%{query: %{"repo" => "alice.test", "rkey" => "p"}}] =
               FakePDS.sent(pds, "com.atproto.repo.getRecord")
    end

    test "get_invite_codes asks for the codes as the town's app does" do
      %{effects: effects, pds: pds} =
        pds(%{
          "town.delve.invitation.getCodes" =>
            {200,
             %{
               collection: "enabled",
               codes: [
                 %{
                   code: "town-abcde",
                   available: 2,
                   disabled: false,
                   forAccount: "did:plc:self",
                   createdBy: "admin",
                   createdAt: "2026-10-18T00:00:00.000Z",
                   uses: [%{usedBy: "did:plc:bob", usedAt: "2026-10-18T01:00:00.000Z"}]
                 }
               ]
             }}
        })

      assert {:ok, %{collection: "enabled", items: [code]}} =
               AtMcp.Effects.get_invite_codes(effects)

      assert %{code: "town-abcde", available: 2, uses: [%{used_by: "did:plc:bob"}]} = code

      assert [%{query: %{"includeUsed" => "true", "createAvailable" => "true"}}] =
               FakePDS.sent(pds, "town.delve.invitation.getCodes")
    end
  end

  describe "on Bluesky" do
    setup do
      Application.put_env(:at_mcp, :network, :bluesky)
      on_exit(fn -> Application.delete_env(:at_mcp, :network) end)
      :ok
    end

    test "trends and topics read their methods, and invitation codes are refused" do
      %{effects: effects, pds: pds} =
        pds(%{
          "app.bsky.unspecced.getTrends" =>
            {200,
             %{
               trends: [
                 %{
                   topic: "kites",
                   displayName: "Kites",
                   link: "/profile/did:plc:x/feed/kites",
                   startedAt: "2026-10-18T00:00:00.000Z",
                   postCount: 9,
                   actors: [%{did: "did:plc:alice", handle: "alice.test"}]
                 }
               ]
             }},
          "app.bsky.unspecced.getTrendingTopics" =>
            {200, %{topics: [%{topic: "kites", link: "/search?q=kites"}], suggested: []}}
        })

      assert {:ok, %{items: [%{post_count: 9, actors: [%{handle: "alice.test"}]}]}} =
               AtMcp.Effects.get_trends(effects, "trends", limit: 5)

      assert {:ok, %{items: [%{topic: "kites"}], suggested: []}} =
               AtMcp.Effects.get_trends(effects, "topics")

      assert [%{query: %{"limit" => "5"}}] = FakePDS.sent(pds, "app.bsky.unspecced.getTrends")

      result = call(%{effects: effects}, "get_invite_codes", %{})
      assert %{code: "invite_codes_not_supported"} = result.structuredContent
      assert FakePDS.sent(pds, "app.bsky.invitation.getCodes") == []
    end
  end

  test "every search_posts filter is a parameter of searchPostsV2's lexicon" do
    lexicon =
      "test/fixtures/lexicons/app/bsky/feed/searchPostsV2.json"
      |> File.read!()
      |> Jason.decode!()
      |> get_in(["defs", "main", "parameters", "properties"])

    hashtags = lexicon["hashtags"]["items"]

    assert AtMcp.Effects.hashtag_limits() == %{
             graphemes: hashtags["maxGraphemes"],
             bytes: hashtags["maxLength"]
           }

    assert lexicon["sort"]["knownValues"] == ["recent", "top"]
  end

  defp pds(answers \\ %{}) do
    {session, pds} =
      FakePDS.start(
        answers:
          Map.merge(
            %{"com.atproto.identity.resolveHandle" => {200, %{did: "did:plc:alice"}}},
            answers
          ),
        handles: %{"alice.test" => "did:plc:alice"}
      )

    effects =
      start_supervised!(
        {AtMcp.Effects,
         backend: AtMcp.Effects.ProtoRune,
         backend_state: session,
         write_quota: AtMcp.Test.QuotaFixture.quota(10)},
        id: make_ref()
      )

    %{effects: effects, pds: pds}
  end
end
