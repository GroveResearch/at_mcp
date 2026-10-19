defmodule AtMcp.FeedProfileWritesTest do
  @moduledoc """
  Feeds, discovery and profile details (#93): the writes.

  The first part calls the tools through the MCP surface over the mock
  backend: what each refuses before anything is sent, and that none of them
  spends the write quota. The second runs the real backend against a fake PDS
  and checks what reached the wire: each record and procedure input matches
  its lexicon (`AtMcp.Test.Lexicon`), an edit keeps every field and every
  preference it does not change, and a handle-form AT URI is written in its DID
  form.
  """
  use ExUnit.Case, async: false

  alias AtMcp.Test.FakePDS
  alias AtMcp.Test.Lexicon

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

  @feed "at://did:plc:mock/app.bsky.feed.generator/kites"
  @post "at://did:plc:mock/app.bsky.feed.post/p"

  describe "through the tools, over the mock backend" do
    test "like takes a post, a feed or a labeler, and refuses anything else" do
      state = mock()

      for uri <- [@post, @feed, "at://did:plc:labeler/app.bsky.labeler.service/self"] do
        refute call(state, "like", %{"uri" => uri, "cid" => "bafy"})[:isError], uri
      end

      assert refused(
               call(state, "like", %{
                 "uri" => "at://did:plc:mock/app.bsky.graph.list/l",
                 "cid" => "bafy"
               }),
               "uri"
             ) =~ "a post, a feed generator or a labeler"
    end

    test "save_feed and unsave_feed take a feed or a list" do
      state = mock()

      assert %{"pinned" => true} =
               call(state, "save_feed", %{"uri" => @feed, "pinned" => true}).structuredContent

      refute call(state, "unsave_feed", %{"uri" => "at://did:plc:mock/app.bsky.graph.list/l"})[
               :isError
             ]

      refused(call(state, "save_feed", %{"uri" => @post}), "uri")
    end

    test "set_status refuses a live status without a URL or for a span the service would not show" do
      state = mock()
      first..last//_ = AtMcp.Effects.status_minutes()

      refused(call(state, "set_status", %{"kind" => "live", "duration_minutes" => 30}), "url")

      refused(
        call(state, "set_status", %{"kind" => "live", "url" => "https://twitch.tv/k"}),
        "duration_minutes"
      )

      for minutes <- [first - 1, last + 1] do
        result =
          call(state, "set_status", %{
            "kind" => "live",
            "url" => "https://twitch.tv/k",
            "duration_minutes" => minutes
          })

        assert result.isError
        assert result.structuredContent.code == "invalid_arguments"
      end

      assert %{"status" => "live", "duration_minutes" => 30} =
               call(state, "set_status", %{
                 "kind" => "live",
                 "url" => "https://twitch.tv/k",
                 "duration_minutes" => 30
               }).structuredContent

      assert %{"status" => "clear"} =
               call(state, "set_status", %{"kind" => "clear"}).structuredContent
    end

    test "update_profile refuses pronouns, a website or links the profile would not show" do
      state = mock()

      %{pronouns: %{graphemes: pronouns}, link_title: %{graphemes: title}} =
        AtMcp.Effects.profile_limits()

      refused(
        call(state, "update_profile", %{"pronouns" => String.duplicate("é", pronouns + 1)}),
        "pronouns"
      )

      refused(call(state, "update_profile", %{"website" => "http://example.com"}), "website")

      assert refused(
               call(state, "update_profile", %{"links" => [%{"url" => "https://bit.ly/x"}]}),
               "links[0]"
             ) =~ "URL shortener"

      refused(
        call(state, "update_profile", %{
          "links" => [%{"url" => "https://a.example"}, %{"url" => "https://a.example"}]
        }),
        "links[1]"
      )

      refused(
        call(state, "update_profile", %{
          "links" => [
            %{"url" => "https://a.example", "title" => String.duplicate("t", title + 1)}
          ]
        }),
        "links[0].title"
      )

      refused(
        call(state, "update_profile", %{"links" => [%{"url" => "ftp://a.example"}]}),
        "links[0]"
      )

      assert %{"pronouns" => "", "links" => []} =
               call(state, "update_profile", %{"pronouns" => " ", "links" => []}).structuredContent
    end

    test "feed_feedback takes a feed generator and a post" do
      state = mock()

      refused(
        call(state, "feed_feedback", %{"feed" => @post, "uri" => @post, "kind" => "show_more"}),
        "feed"
      )

      refused(
        call(state, "feed_feedback", %{"feed" => @feed, "uri" => @feed, "kind" => "show_more"}),
        "uri"
      )

      assert %{"kind" => "show_less", "uri" => @post} =
               call(state, "feed_feedback", %{
                 "feed" => @feed,
                 "uri" => @post,
                 "kind" => "show_less"
               }).structuredContent
    end

    test "none of them spends the write quota" do
      %{effects: effects} = state = mock()
      assert {:ok, _} = AtMcp.Effects.post(effects, "spends the only write")

      for {name, args} <- [
            {"like", %{"uri" => @feed, "cid" => "bafy"}},
            {"save_feed", %{"uri" => @feed}},
            {"unsave_feed", %{"uri" => @feed}},
            {"set_status",
             %{"kind" => "live", "url" => "https://twitch.tv/k", "duration_minutes" => 30}},
            {"set_status", %{"kind" => "clear"}},
            {"update_profile", %{"pronouns" => "they/them", "website" => "https://k.example"}},
            {"feed_feedback", %{"feed" => @feed, "uri" => @post, "kind" => "show_more"}}
          ] do
        refute call(state, name, args)[:isError], name
      end

      assert AtMcp.Effects.quota_status(effects).used == 1
    end
  end

  test "the limits AtMcp enforces are the lexicons' and the AppView's" do
    record = fn nsid ->
      (Path.join(["test/fixtures/lexicons" | String.split(nsid, ".")]) <> ".json")
      |> File.read!()
      |> Jason.decode!()
      |> get_in(["defs", "main", "record", "properties"])
    end

    profile = record.("app.bsky.actor.profile")
    link = record.("app.bsky.actor.link")
    limits = AtMcp.Effects.profile_limits()

    assert limits.pronouns ==
             %{
               graphemes: profile["pronouns"]["maxGraphemes"],
               bytes: profile["pronouns"]["maxLength"]
             }

    assert limits.link_title ==
             %{graphemes: link["title"]["maxGraphemes"], bytes: link["title"]["maxLength"]}

    assert limits.links == profile["links"]["maxLength"]
    assert record.("app.bsky.actor.status")["durationMinutes"]["minimum"] <= 5

    interaction =
      "test/fixtures/lexicons/app/bsky/feed/defs.json"
      |> File.read!()
      |> Jason.decode!()
      |> get_in(["defs", "interaction", "properties"])

    assert AtMcp.Effects.feedback_limits() ==
             %{
               feed_context: interaction["feedContext"]["maxLength"],
               req_id: interaction["reqId"]["maxLength"]
             }
  end

  describe "on delve.town" do
    setup do
      Application.put_env(:at_mcp, :network, :delve)
      on_exit(fn -> Application.delete_env(:at_mcp, :network) end)
      :ok
    end

    test "profile links and feed feedback, which the town does not serve, are refused before anything is sent" do
      %{effects: effects, pds: pds} = pds()
      state = %{effects: effects}

      for {name, args, method} <- [
            {"update_profile", %{"links" => [%{"url" => "https://k.example"}]},
             "town.delve.actor.link"},
            {"feed_feedback",
             %{
               "feed" => "at://did:plc:f/town.delve.feed.generator/k",
               "uri" => "at://did:plc:f/town.delve.feed.post/p",
               "kind" => "show_more"
             }, "town.delve.feed.sendInteractions"}
          ] do
        result = call(state, name, args)
        assert %{code: "not_served", method: ^method} = result.structuredContent, name
      end

      assert FakePDS.methods(pds) == []
    end

    test "a like of a feed named with a handle names it in DID form" do
      %{effects: effects, pds: pds} = pds()

      assert {:ok, _} =
               AtMcp.Effects.like(effects, "at://alice.test/town.delve.feed.generator/k", "bafyk")

      assert [%{body: %{"record" => record, "collection" => "town.delve.feed.like"}}] =
               FakePDS.sent(pds, "com.atproto.repo.createRecord")

      assert record["subject"] ==
               %{"uri" => "at://did:plc:alice/town.delve.feed.generator/k", "cid" => "bafyk"}

      assert Lexicon.problems(record, "app.bsky.feed.like") == []
    end

    test "save_feed migrates the first-version preference, keeps every other one, and adds to the old one" do
      v1 = %{
        "$type" => "town.delve.actor.defs#savedFeedsPref",
        "saved" => ["at://did:plc:f/town.delve.feed.generator/old"],
        "pinned" => ["at://did:plc:f/town.delve.feed.generator/old"]
      }

      adult = %{"$type" => "town.delve.actor.defs#adultContentPref", "enabled" => false}
      other = %{"$type" => "town.delve.actor.defs#threadViewPref", "sort" => "oldest"}
      %{effects: effects, pds: pds} = pds(preferences: [adult, v1, other])

      assert {:ok, %{unchanged: false, pinned: false, note: note}} =
               AtMcp.Effects.save_feed(
                 effects,
                 "at://alice.test/town.delve.feed.generator/k",
                 false
               )

      assert note =~ "no compare-and-swap"

      new = "at://did:plc:alice/town.delve.feed.generator/k"
      [%{body: body}] = FakePDS.sent(pds, "town.delve.actor.putPreferences")
      assert Lexicon.problems(body, "app.bsky.actor.putPreferences") == []

      [^adult, ^other, v2, v1_after] = FakePDS.preferences(pds)

      assert [
               %{"type" => "timeline", "value" => "following", "pinned" => true},
               %{
                 "type" => "feed",
                 "value" => "at://did:plc:f/town.delve.feed.generator/old",
                 "pinned" => true
               },
               %{"type" => "feed", "value" => ^new, "pinned" => false}
             ] = v2["items"]

      assert v2["$type"] == "town.delve.actor.defs#savedFeedsPrefV2"
      assert v1_after["saved"] == v1["saved"] ++ [new]
      assert v1_after["pinned"] == v1["pinned"]

      # Saved as asked already: nothing is written.
      assert {:ok, %{unchanged: true}} = AtMcp.Effects.save_feed(effects, new, false)
      assert [_] = FakePDS.sent(pds, "town.delve.actor.putPreferences")

      # Pinning moves it among the pinned, which come first.
      assert {:ok, %{pinned: true}} = AtMcp.Effects.save_feed(effects, new, true)
      v2 = Enum.find(FakePDS.preferences(pds), &(&1["$type"] =~ "PrefV2"))
      assert Enum.map(v2["items"], & &1["pinned"]) == [true, true, true]

      assert {:ok, %{unchanged: false}} = AtMcp.Effects.unsave_feed(effects, new)
      v2 = Enum.find(FakePDS.preferences(pds), &(&1["$type"] =~ "PrefV2"))
      refute Enum.any?(v2["items"], &(&1["value"] == new))

      assert {:ok, %{unchanged: true}} = AtMcp.Effects.unsave_feed(effects, new)
    end

    test "preferences are written back as stored, keys and all" do
      odd = %{"$type" => "town.delve.actor.defs#bskyAppStatePref", "queued_nudges" => ["x"]}

      v2 = %{
        "$type" => "town.delve.actor.defs#savedFeedsPrefV2",
        "items" => [
          %{"id" => "t", "type" => "timeline", "value" => "following", "pinned" => true}
        ]
      }

      %{effects: effects, pds: pds} = pds(preferences: [odd, v2])

      assert {:ok, _} =
               AtMcp.Effects.save_feed(effects, "at://did:plc:f/town.delve.graph.list/l", true)

      assert [^odd, %{"items" => [_, %{"type" => "list", "pinned" => true}]}] =
               FakePDS.preferences(pds)
    end

    test "set_status writes a live status over the one it read, and clear deletes it" do
      status = "at://did:plc:self/town.delve.actor.status/self"
      %{effects: effects, pds: pds} = pds()

      assert {:ok, %{status: "live", replaced: nil, expires_at: expires}} =
               AtMcp.Effects.set_status(effects, "live",
                 url: "https://twitch.tv/kites",
                 duration_minutes: 60,
                 title: "Kites"
               )

      assert is_binary(expires)
      [%{body: body}] = FakePDS.sent(pds, "com.atproto.repo.putRecord")
      refute Map.has_key?(body, "swapRecord")
      assert Lexicon.problems(body["record"], "app.bsky.actor.status") == []

      assert %{
               "status" => "town.delve.actor.status#live",
               "durationMinutes" => 60,
               "embed" => %{
                 "$type" => "town.delve.embed.external",
                 "external" => %{"uri" => "https://twitch.tv/kites", "title" => "Kites"}
               }
             } = FakePDS.record(pds, status)

      # A second one replaces the first, written only over it, and names it.
      assert {:ok, %{replaced: %{url: "https://twitch.tv/kites", duration_minutes: 60}}} =
               AtMcp.Effects.set_status(effects, "live",
                 url: "https://stream.place/k",
                 duration_minutes: 30
               )

      [_, %{body: body}] = FakePDS.sent(pds, "com.atproto.repo.putRecord")
      assert body["swapRecord"] == FakePDS.cid(status)

      assert {:ok, %{status: "clear", unchanged: false}} =
               AtMcp.Effects.set_status(effects, "clear")

      assert FakePDS.record(pds, status) == nil

      assert {:ok, %{unchanged: true, replaced: nil}} = AtMcp.Effects.set_status(effects, "clear")
      assert [_] = FakePDS.sent(pds, "com.atproto.repo.deleteRecord")
    end

    test "a status changed between the read and the write is refused as changed_meanwhile" do
      %{effects: effects} =
        pds(
          answers: %{
            "com.atproto.repo.putRecord" => {400, %{error: "InvalidSwap", message: "moved"}}
          },
          records: %{
            "at://did:plc:self/town.delve.actor.status/self" => %{
              "$type" => "town.delve.actor.status",
              "status" => "town.delve.actor.status#live",
              "createdAt" => "2026-10-18T00:00:00.000Z"
            }
          }
        )

      result =
        call(%{effects: effects}, "set_status", %{
          "kind" => "live",
          "url" => "https://twitch.tv/k",
          "duration_minutes" => 30
        })

      assert %{code: "changed_meanwhile"} = result.structuredContent
    end

    test "update_profile sets and removes pronouns and a website, keeping every other field" do
      profile = "at://did:plc:self/town.delve.actor.profile/self"

      %{effects: effects, pds: pds} =
        pds(
          records: %{
            profile => %{
              "$type" => "town.delve.actor.profile",
              "displayName" => "Self",
              "pronouns" => "it/its",
              "pinnedPost" => %{
                "uri" => "at://did:plc:self/town.delve.feed.post/p",
                "cid" => "bafyp"
              }
            }
          }
        )

      assert {:ok, %{pronouns: "", website: "https://self.example"}} =
               AtMcp.Effects.update_profile(effects,
                 pronouns: "",
                 website: "https://self.example"
               )

      [%{body: body}] = FakePDS.sent(pds, "com.atproto.repo.putRecord")
      assert body["swapRecord"] == FakePDS.cid(profile)
      assert Lexicon.problems(body["record"], "app.bsky.actor.profile") == []

      assert %{"displayName" => "Self", "website" => "https://self.example", "pinnedPost" => _} =
               record = FakePDS.record(pds, profile)

      refute Map.has_key?(record, "pronouns")
    end
  end

  describe "profile links and feed feedback, on Bluesky" do
    setup do
      Application.put_env(:at_mcp, :network, :bluesky)
      on_exit(fn -> Application.delete_env(:at_mcp, :network) end)
      :ok
    end

    @profile "at://did:plc:self/app.bsky.actor.profile/self"
    @a "at://did:plc:self/app.bsky.actor.link/a"
    @b "at://did:plc:self/app.bsky.actor.link/b"

    defp linked(extra \\ []) do
      records = %{
        @profile => %{
          "$type" => "app.bsky.actor.profile",
          "displayName" => "Self",
          "links" => [
            %{"uri" => @a, "cid" => FakePDS.cid(@a)},
            %{"uri" => @b, "cid" => FakePDS.cid(@b)}
          ]
        },
        @a => %{
          "$type" => "app.bsky.actor.link",
          "url" => "https://a.example",
          "createdAt" => "2026-10-01T00:00:00.000Z"
        },
        @b => %{
          "$type" => "app.bsky.actor.link",
          "url" => "https://b.example",
          "title" => "B",
          "createdAt" => "2026-10-01T00:00:00.000Z"
        }
      }

      pds(Keyword.merge([records: records], extra))
    end

    test "links keep the records of links given as shown, write new ones first, and delete the rest after" do
      %{effects: effects, pds: pds} = linked()

      assert {:ok, result} =
               AtMcp.Effects.update_profile(effects,
                 links: [
                   %{url: "https://b.example", title: "B"},
                   %{url: "https://c.example", title: nil}
                 ]
               )

      assert [%{uri: @b}, %{url: "https://c.example", uri: new}] = result.links

      assert result.replaced_links == [
               %{url: "https://a.example", title: nil},
               %{url: "https://b.example", title: "B"}
             ]

      assert result.removed == [@a]
      assert result.left_behind == []

      assert [
               "com.atproto.repo.applyWrites",
               "com.atproto.repo.putRecord",
               "com.atproto.repo.applyWrites"
             ] =
               pds |> FakePDS.methods() |> Enum.filter(&(&1 =~ ~r/applyWrites|putRecord/))

      [%{body: created}, %{body: deleted}] = FakePDS.sent(pds, "com.atproto.repo.applyWrites")
      assert Lexicon.problems(created, "com.atproto.repo.applyWrites") == []
      assert [%{"value" => link}] = created["writes"]
      assert Lexicon.problems(link, "app.bsky.actor.link") == []
      refute Map.has_key?(link, "title")

      assert [%{"$type" => "com.atproto.repo.applyWrites#delete", "rkey" => "a"}] =
               deleted["writes"]

      [%{body: put}] = FakePDS.sent(pds, "com.atproto.repo.putRecord")
      assert put["swapRecord"] == FakePDS.cid(@profile)
      assert Lexicon.problems(put["record"], "app.bsky.actor.profile") == []

      assert put["record"]["links"] == [
               %{"uri" => @b, "cid" => FakePDS.cid(@b)},
               %{"uri" => new, "cid" => FakePDS.cid(new)}
             ]

      assert put["record"]["displayName"] == "Self"
      assert FakePDS.record(pds, @a) == nil
      assert FakePDS.record(pds, new)["url"] == "https://c.example"
    end

    test "empty links remove them all, and the records with them" do
      %{effects: effects, pds: pds} = linked()

      assert {:ok, %{links: [], removed: [@a, @b]}} =
               AtMcp.Effects.update_profile(effects, links: [])

      refute Map.has_key?(FakePDS.record(pds, @profile), "links")
      assert FakePDS.record(pds, @a) == nil and FakePDS.record(pds, @b) == nil
    end

    test "a profile changed meanwhile is refused, and the link records written for it are deleted again" do
      %{effects: effects, pds: pds} =
        linked(
          answers: %{
            "com.atproto.repo.putRecord" => {400, %{error: "InvalidSwap", message: "moved"}}
          }
        )

      result =
        call(%{effects: effects}, "update_profile", %{
          "links" => [%{"url" => "https://c.example"}]
        })

      assert %{code: "changed_meanwhile"} = result.structuredContent

      [%{body: created}, %{body: deleted}] = FakePDS.sent(pds, "com.atproto.repo.applyWrites")
      [%{"rkey" => rkey}] = created["writes"]

      assert [%{"$type" => "com.atproto.repo.applyWrites#delete", "rkey" => ^rkey}] =
               deleted["writes"]

      assert FakePDS.record(pds, "at://did:plc:self/app.bsky.actor.link/#{rkey}") == nil
      assert FakePDS.record(pds, @a) != nil
    end

    test "feed_feedback goes to the feed's own service, naming the feed and the post in DID form" do
      %{effects: effects, pds: pds} =
        pds(
          answers: %{
            "app.bsky.feed.getFeedGenerator" =>
              {200,
               %{
                 view: %{
                   uri: "at://did:plc:alice/app.bsky.feed.generator/k",
                   did: "did:web:feeds.example",
                   acceptsInteractions: true
                 },
                 isOnline: true,
                 isValid: true
               }}
          }
        )

      assert {:ok, %{kind: "show_less", uri: "at://did:plc:alice/app.bsky.feed.post/p"}} =
               AtMcp.Effects.feed_feedback(
                 effects,
                 "at://alice.test/app.bsky.feed.generator/k",
                 "at://alice.test/app.bsky.feed.post/p",
                 "show_less",
                 feed_context: "t-kites"
               )

      assert [%{body: body, proxy: "did:web:feeds.example#bsky_fg"}] =
               FakePDS.sent(pds, "app.bsky.feed.sendInteractions")

      assert Lexicon.problems(body, "app.bsky.feed.sendInteractions") == []

      assert body == %{
               "feed" => "at://did:plc:alice/app.bsky.feed.generator/k",
               "interactions" => [
                 %{
                   "item" => "at://did:plc:alice/app.bsky.feed.post/p",
                   "event" => "app.bsky.feed.defs#requestLess",
                   "feedContext" => "t-kites"
                 }
               ]
             }
    end

    test "a feed that takes no feedback is refused, naming feed, and nothing is sent to it" do
      %{effects: effects, pds: pds} =
        pds(
          answers: %{
            "app.bsky.feed.getFeedGenerator" =>
              {200, %{view: %{did: "did:web:feeds.example"}, isOnline: true, isValid: true}}
          }
        )

      result =
        call(%{effects: effects}, "feed_feedback", %{
          "feed" => "at://did:plc:alice/app.bsky.feed.generator/k",
          "uri" => "at://did:plc:alice/app.bsky.feed.post/p",
          "kind" => "show_more"
        })

      assert refused(result, "feed") =~ "does not take feedback"
      assert FakePDS.sent(pds, "app.bsky.feed.sendInteractions") == []
    end

    test "a custom feed's items carry what its generator gave them" do
      {:ok, page} =
        AtMcp.Effects.ProtoRune.summarize(
          :feed,
          ProtoRune.Case.snakelize_enum(%{
            "feed" => [
              %{
                "post" => %{"uri" => "at://did:plc:a/app.bsky.feed.post/p", "record" => %{}},
                "feedContext" => "t-kites",
                "reqId" => "r1"
              }
            ]
          })
        )

      assert [%{feed_context: "t-kites", req_id: "r1"} = item] = page.items

      text = AtMcp.Reading.posts(Jason.decode!(Jason.encode!(%{items: [item]})))
      assert text =~ "For feed_feedback: feed_context: t-kites · req_id: r1"
    end
  end

  defp pds(opts \\ []) do
    {session, pds} =
      FakePDS.start(
        records: Keyword.get(opts, :records, %{}),
        preferences: Keyword.get(opts, :preferences, []),
        answers:
          Map.merge(
            %{"com.atproto.identity.resolveHandle" => {200, %{did: "did:plc:alice"}}},
            Keyword.get(opts, :answers, %{})
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
