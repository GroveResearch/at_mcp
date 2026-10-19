defmodule AtMcp.PreferencesTest do
  @moduledoc """
  Preferences and notification settings (#91).

  The first part calls the tools over the mock backend: what each refuses
  before anything is sent. The second runs the real backend against a fake PDS
  and checks what reached the wire: a preference changes the way the app's
  library changes it, every other preference is kept as stored, a setting
  already as asked writes nothing, a declaration record is written over the
  version read, and a list or an account named by a handle is written in its
  DID form.
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
    # The input schema refuses an enum it does not hold before the tool runs.
    assert hd(result.content).text =~ ~r/Nothing was sent|No operation was attempted/
    hd(result.content).text
  end

  describe "through the tools, over the mock backend" do
    test "set_preference takes one kind's fields, at least one, each as the app offers it" do
      state = mock()

      assert refused(call(state, "set_preference", %{"kind" => "threads"}), "kind") =~
               "sort, tree_view"

      assert refused(
               call(state, "set_preference", %{"kind" => "threads", "hide_reposts" => true}),
               "hide_reposts"
             ) =~ "kind home_feed"

      for {args, path} <- [
            {%{"kind" => "threads", "sort" => "hotness"}, "sort"},
            {%{"kind" => "interests", "tags" => ["art", String.duplicate("x", 65)]}, "tags"},
            {%{"kind" => "interaction_defaults", "reply_rule" => ["everyone", "following"]},
             "reply_rule/0"},
            {%{"kind" => "interaction_defaults", "reply_rule" => ["at://x/app.bsky.feed.post/p"]},
             "reply_rule/0"}
          ] do
        refused(call(state, "set_preference", args), path)
      end

      refute call(state, "set_preference", %{"kind" => "home_feed", "hide_quotes" => true})[
               :isError
             ]
    end

    test "set_notification_setting refuses chat, include where a reason has none, and nothing to change" do
      state = mock()

      refused(
        call(state, "set_notification_setting", %{"reason" => "chat", "push" => false}),
        "reason"
      )

      assert {:error, {:invalid_argument, "reason", message}} =
               AtMcp.Effects.set_notification_setting(state.effects, "chat", push: false)

      assert message =~ "chat service"

      assert refused(
               call(state, "set_notification_setting", %{
                 "reason" => "verified",
                 "include" => "follows"
               }),
               "include"
             ) =~ "like"

      refused(call(state, "set_notification_setting", %{"reason" => "like"}), "reason")
    end

    test "subscribe_to_activity takes replies only with posts" do
      state = mock()

      assert refused(
               call(state, "subscribe_to_activity", %{
                 "actor" => "alice.test",
                 "posts" => false,
                 "replies" => true
               }),
               "replies"
             ) =~ "with posts"
    end
  end

  describe "preferences, against a fake PDS" do
    test "home_feed changes the home feedViewPref as the library does, keeps every other preference, and writes nothing when already as asked" do
      odd = %{"$type" => "app.bsky.actor.defs#bskyAppStatePref", "queued_nudges" => ["x"]}
      other_feed = %{"$type" => "app.bsky.actor.defs#feedViewPref", "feed" => "at://f"}

      home = %{
        "$type" => "app.bsky.actor.defs#feedViewPref",
        "feed" => "home",
        "hideRepliesByUnfollowed" => false,
        "hideReplies" => false
      }

      adult = %{"$type" => "app.bsky.actor.defs#adultContentPref", "enabled" => false}
      %{effects: effects, pds: pds} = pds(preferences: [odd, home, other_feed, adult])

      assert {:ok,
              %{
                kind: "home_feed",
                changed: ["hide_reposts", "saved_feed_samples"],
                previous: %{hide_reposts: false, saved_feed_samples: false},
                now: %{hide_reposts: true, saved_feed_samples: true, hide_replies: false},
                unchanged: false,
                note: note
              }} =
               AtMcp.Effects.set_preference(
                 effects,
                 "home_feed",
                 %{hide_reposts: true, hide_replies: false, saved_feed_samples: true}
               )

      assert note =~ "no compare-and-swap"

      [%{body: body}] = FakePDS.sent(pds, "app.bsky.actor.putPreferences")

      # The app writes `lab_mergeFeedEnabled`, which the lexicon does not
      # declare; every other key is the lexicon's, but for the one the
      # preference AtMcp did not touch was stored with.
      assert Lexicon.problems(body, "app.bsky.actor.putPreferences") == [
               "/preferences/0/queued_nudges: not in the lexicon",
               "/preferences/3/lab_mergeFeedEnabled: not in the lexicon"
             ]

      assert [^odd, ^other_feed, ^adult, new_home] = FakePDS.preferences(pds)

      assert new_home == %{
               "$type" => "app.bsky.actor.defs#feedViewPref",
               "feed" => "home",
               "hideRepliesByUnfollowed" => false,
               "hideReplies" => false,
               "hideReposts" => true,
               "lab_mergeFeedEnabled" => true
             }

      assert {:ok, %{unchanged: true, changed: []}} =
               AtMcp.Effects.set_preference(effects, "home_feed", %{hide_reposts: true})

      assert [_] = FakePDS.sent(pds, "app.bsky.actor.putPreferences")
    end

    test "threads reads a sort the app does not offer as top, and writes sort and tree view" do
      stored = %{"$type" => "app.bsky.actor.defs#threadViewPref", "sort" => "hotness"}
      %{effects: effects, pds: pds} = pds(preferences: [stored])

      assert {:ok, %{unchanged: true, now: %{sort: "top", tree_view: false}}} =
               AtMcp.Effects.set_preference(effects, "threads", %{sort: "top"})

      assert FakePDS.sent(pds, "app.bsky.actor.putPreferences") == []

      assert {:ok, %{changed: ["sort", "tree_view"]}} =
               AtMcp.Effects.set_preference(effects, "threads", %{sort: "oldest", tree_view: true})

      assert [
               %{
                 "$type" => "app.bsky.actor.defs#threadViewPref",
                 "sort" => "oldest",
                 "lab_treeViewEnabled" => true
               }
             ] = FakePDS.preferences(pds)
    end

    test "interaction_defaults writes a list named by a handle in DID form, and keeps a rule not given" do
      %{effects: effects, pds: pds} = pds()

      assert {:ok, %{now: %{reply_rule: ["following", list], quotes: "disabled"}}} =
               AtMcp.Effects.set_preference(effects, "interaction_defaults", %{
                 reply_rule: ["following", "at://alice.test/app.bsky.graph.list/l"],
                 quotes: "disabled"
               })

      assert list == "at://did:plc:alice/app.bsky.graph.list/l"
      [%{body: body}] = FakePDS.sent(pds, "app.bsky.actor.putPreferences")
      assert Lexicon.problems(body, "app.bsky.actor.putPreferences") == []

      assert [
               %{
                 "threadgateAllowRules" => [
                   %{"$type" => "app.bsky.feed.threadgate#followingRule"},
                   %{"$type" => "app.bsky.feed.threadgate#listRule", "list" => ^list}
                 ],
                 "postgateEmbeddingRules" => [%{"$type" => "app.bsky.feed.postgate#disableRule"}]
               }
             ] = FakePDS.preferences(pds)

      # Everyone may reply: no rule at all, as the app writes it; quotes kept.
      assert {:ok,
              %{changed: ["reply_rule"], now: %{reply_rule: ["everyone"], quotes: "disabled"}}} =
               AtMcp.Effects.set_preference(effects, "interaction_defaults", %{
                 reply_rule: ["everyone"]
               })

      assert [pref] = FakePDS.preferences(pds)
      refute Map.has_key?(pref, "threadgateAllowRules")

      assert {:ok, %{now: %{quotes: "allowed"}}} =
               AtMcp.Effects.set_preference(effects, "interaction_defaults", %{quotes: "allowed"})

      assert [%{"postgateEmbeddingRules" => []}] = FakePDS.preferences(pds)
    end

    test "adult content is turned on only for an account whose declared age is 18 or over" do
      %{effects: effects, pds: pds} = pds()

      assert {:error, {:invalid_argument, "enabled", message}} =
               AtMcp.Effects.set_preference(effects, "adult_content", %{enabled: true})

      assert message =~ "18 or over"
      assert FakePDS.sent(pds, "app.bsky.actor.putPreferences") == []

      # Turning it off is always taken; here it is off already.
      assert {:ok, %{unchanged: true}} =
               AtMcp.Effects.set_preference(effects, "adult_content", %{enabled: false})

      declared = %{"$type" => "app.bsky.actor.defs#declaredAgePref", "isOverAge18" => true}
      %{effects: effects, pds: pds} = pds(preferences: [declared])

      assert {:ok, %{now: %{enabled: true}}} =
               AtMcp.Effects.set_preference(effects, "adult_content", %{enabled: true})

      assert [^declared, %{"$type" => "app.bsky.actor.defs#adultContentPref", "enabled" => true}] =
               FakePDS.preferences(pds)
    end

    test "interests replace the tags and stamp updatedAt; verification hides badges" do
      %{effects: effects, pds: pds} = pds()

      assert {:ok, %{now: %{tags: ["art", "science"]}}} =
               AtMcp.Effects.set_preference(effects, "interests", %{
                 tags: ["art", "science", "art"]
               })

      assert {:ok, %{now: %{hide_badges: true}}} =
               AtMcp.Effects.set_preference(effects, "verification", %{hide_badges: true})

      assert [
               %{"$type" => "app.bsky.actor.defs#interestsPref", "tags" => ["art", "science"]} =
                 interests,
               %{"$type" => "app.bsky.actor.defs#verificationPrefs", "hideBadges" => true}
             ] = FakePDS.preferences(pds)

      assert {:ok, _, _} = DateTime.from_iso8601(interests["updatedAt"])

      for %{body: body} <- FakePDS.sent(pds, "app.bsky.actor.putPreferences"),
          do: assert(Lexicon.problems(body, "app.bsky.actor.putPreferences") == [])
    end

    test "discoverable and activity_subscriptions write their record over the version read, and nothing when already as asked" do
      %{effects: effects, pds: pds} = pds()
      uri = "at://did:plc:self/app.bsky.actor.contentVisibilityDeclaration/self"

      # No record means nothing is hidden, so asking for that writes nothing.
      assert {:ok, %{unchanged: true, uri: nil}} =
               AtMcp.Effects.set_preference(effects, "discoverable", %{
                 hide_from_recommendations: false
               })

      assert {:ok, %{uri: ^uri, changed: ["hide_from_recommendations"]}} =
               AtMcp.Effects.set_preference(effects, "discoverable", %{
                 hide_from_recommendations: true
               })

      # No record was read, so it is written only if there still is none.
      assert [%{body: first}] = FakePDS.sent(pds, "com.atproto.repo.putRecord")
      assert Map.fetch(first, "swapRecord") == {:ok, nil}

      assert Lexicon.problems(first["record"], "app.bsky.actor.contentVisibilityDeclaration") ==
               []

      assert {:ok, %{previous: %{hide_from_recommendations: true}}} =
               AtMcp.Effects.set_preference(effects, "discoverable", %{
                 hide_from_recommendations: false
               })

      assert [_, %{body: %{"swapRecord" => swap}}] =
               FakePDS.sent(pds, "com.atproto.repo.putRecord")

      assert swap == FakePDS.cid(uri)

      assert {:ok, %{now: %{allow: "mutuals"}}} =
               AtMcp.Effects.set_preference(effects, "activity_subscriptions", %{allow: "mutuals"})

      declaration = "at://did:plc:self/app.bsky.notification.declaration/self"

      assert FakePDS.record(pds, declaration) == %{
               "$type" => "app.bsky.notification.declaration",
               "allowSubscriptions" => "mutuals"
             }

      assert Lexicon.problems(
               FakePDS.record(pds, declaration),
               "app.bsky.notification.declaration"
             ) == []

      assert {:ok,
              %{
                discoverable: %{hide_from_recommendations: false},
                activity_subscriptions: %{allow: "mutuals"}
              }} = AtMcp.Effects.get_preferences(effects)
    end

    test "a declaration changed between the read and the write is refused as changed meanwhile" do
      uri = "at://did:plc:self/app.bsky.notification.declaration/self"

      %{effects: effects} =
        pds(
          records: %{uri => %{"allowSubscriptions" => "none"}},
          answers: %{
            "com.atproto.repo.putRecord" => {400, %{error: "InvalidSwap", message: "changed"}}
          }
        )

      assert {:error, %AtMcp.Effects.Failure{kind: :refused, message: message}} =
               AtMcp.Effects.set_preference(effects, "activity_subscriptions", %{
                 allow: "followers"
               })

      assert message =~ "nothing was written"
    end

    test "a declaration, profile or status another client creates between the read and the write is not written over" do
      declaration = "at://did:plc:self/app.bsky.notification.declaration/self"
      profile = "at://did:plc:self/app.bsky.actor.profile/self"
      status = "at://did:plc:self/app.bsky.actor.status/self"

      # The read finds nothing; by the write, each record is there.
      %{effects: effects, pds: pds} =
        pds(
          records: %{
            declaration => %{"allowSubscriptions" => "none"},
            profile => %{"displayName" => "theirs"},
            status => %{"status" => "app.bsky.actor.status#live"}
          },
          answers: %{
            "com.atproto.repo.getRecord" =>
              {400, %{error: "RecordNotFound", message: "Could not locate record"}}
          }
        )

      for {write, what} <- [
            {fn ->
               AtMcp.Effects.set_preference(effects, "activity_subscriptions", %{allow: "mutuals"})
             end, "notification.declaration"},
            {fn -> AtMcp.Effects.update_profile(effects, display_name: "mine") end, "profile"},
            {fn ->
               AtMcp.Effects.set_status(effects, "live",
                 url: "https://twitch.tv/x",
                 duration_minutes: 30
               )
             end, "status"}
          ] do
        assert {:error, %AtMcp.Effects.Failure{kind: :refused, message: message}} = write.(),
               what

        assert message =~ "nothing was written", what
      end

      assert FakePDS.record(pds, declaration) == %{"allowSubscriptions" => "none"}
      assert FakePDS.record(pds, profile) == %{"displayName" => "theirs"}
      assert FakePDS.record(pds, status) == %{"status" => "app.bsky.actor.status#live"}
    end

    test "threads changes one setting and keeps the other as the app shows it" do
      preferences = [
        %{"$type" => "app.bsky.actor.defs#threadViewPref", "sort" => "newest"},
        %{"$type" => "app.bsky.actor.defs#threadViewPref", "lab_treeViewEnabled" => true}
      ]

      %{effects: effects, pds: pds} = pds(preferences: preferences)

      assert {:ok, %{changed: ["tree_view"], now: %{sort: "newest", tree_view: false}}} =
               AtMcp.Effects.set_preference(effects, "threads", %{tree_view: false})

      assert [
               %{
                 "$type" => "app.bsky.actor.defs#threadViewPref",
                 "sort" => "newest",
                 "lab_treeViewEnabled" => false
               }
             ] = FakePDS.preferences(pds)

      assert {:ok, %{now: %{sort: "newest", tree_view: false}}} =
               AtMcp.Effects.get_preferences(effects)
               |> then(fn {:ok, p} -> {:ok, %{now: p.threads}} end)
    end

    test "interests keep a stored tag the app does not offer, refuse a new one, and the same set in another order is no change" do
      stored = %{"$type" => "app.bsky.actor.defs#interestsPref", "tags" => ["knitting", "art"]}
      %{effects: effects, pds: pds} = pds(preferences: [stored])

      assert {:ok, %{unchanged: true}} =
               AtMcp.Effects.set_preference(effects, "interests", %{tags: ["art", "knitting"]})

      assert {:error, {:invalid_argument, "tags", message}} =
               AtMcp.Effects.set_preference(effects, "interests", %{tags: ["art", "kites"]})

      assert message =~ "kites"
      assert FakePDS.sent(pds, "app.bsky.actor.putPreferences") == []

      assert {:ok, %{changed: ["tags"], now: %{tags: ["knitting", "science"]}}} =
               AtMcp.Effects.set_preference(effects, "interests", %{tags: ["knitting", "science"]})
    end

    test "get_preferences reads each kind as the app does, the saved feeds it migrates, and never the birth date" do
      preferences = [
        %{"$type" => "app.bsky.actor.defs#personalDetailsPref", "birthDate" => "1990-01-01"},
        %{
          "$type" => "app.bsky.actor.defs#declaredAgePref",
          "isOverAge13" => true,
          "isOverAge16" => true,
          "isOverAge18" => true
        },
        %{
          "$type" => "app.bsky.actor.defs#savedFeedsPref",
          "saved" => ["at://did:plc:f/app.bsky.feed.generator/a"],
          "pinned" => []
        },
        # Not valid: the library skips it, so the one before it counts.
        %{"$type" => "app.bsky.actor.defs#adultContentPref", "enabled" => true},
        %{"$type" => "app.bsky.actor.defs#adultContentPref", "enabled" => "yes"},
        %{"$type" => "app.bsky.actor.defs#threadViewPref", "lab_treeViewEnabled" => true},
        %{"$type" => "app.bsky.actor.defs#threadViewPref", "sort" => "newest"}
      ]

      %{effects: effects} = pds(preferences: preferences)

      assert {:ok, summary} = AtMcp.Effects.get_preferences(effects)

      assert summary.adult_content == %{
               enabled: true,
               birth_date_set: true,
               declared_over_18: true
             }

      assert summary.threads == %{sort: "newest", tree_view: true}
      assert summary.interaction_defaults == %{reply_rule: ["everyone"], quotes: "allowed"}

      assert summary.saved_feeds == [
               %{type: "timeline", value: "following", pinned: true},
               %{type: "feed", value: "at://did:plc:f/app.bsky.feed.generator/a", pinned: false}
             ]

      refute inspect(summary) =~ "1990"
      text = AtMcp.Reading.preferences(Jason.decode!(Jason.encode!(summary)))
      assert text =~ "birth date set, 18 or over"
      refute text =~ "1990"
    end
  end

  describe "notification settings, against a fake PDS" do
    test "set_notification_setting sends that reason alone, keeps what it is not given, and reports what the service keeps" do
      %{effects: effects, pds: pds} =
        pds(
          notification_preferences: %{
            "like" => %{"include" => "all", "list" => true, "push" => false}
          }
        )

      assert {:ok, %{settings: settings}} = AtMcp.Effects.get_notification_settings(effects)
      assert %{reason: "like", include: "all", list: true, push: false} = hd(settings)
      assert Enum.map(settings, & &1.reason) == AtMcp.Preferences.notification_reasons()

      assert {:ok,
              %{
                reason: "like",
                changed: ["include"],
                previous: %{include: "all", list: true, push: false},
                now: %{include: "follows", list: true, push: false}
              }} = AtMcp.Effects.set_notification_setting(effects, "like", include: "follows")

      assert [%{body: body}] = FakePDS.sent(pds, "app.bsky.notification.putPreferencesV2")
      assert body == %{"like" => %{"include" => "follows", "list" => true, "push" => false}}
      assert Lexicon.problems(body, "app.bsky.notification.putPreferencesV2") == []

      assert {:ok, %{unchanged: true}} =
               AtMcp.Effects.set_notification_setting(effects, "like", include: "follows")

      assert [_] = FakePDS.sent(pds, "app.bsky.notification.putPreferencesV2")

      assert {:ok, %{now: %{include: nil, list: false, push: true}}} =
               AtMcp.Effects.set_notification_setting(effects, "subscribed_post", list: false)

      assert [_, %{body: %{"subscribedPost" => %{"list" => false, "push" => true} = plain}}] =
               FakePDS.sent(pds, "app.bsky.notification.putPreferencesV2")

      refute Map.has_key?(plain, "include")
    end
  end

  describe "activity subscriptions, against a fake PDS" do
    defp profile(allow, viewer) do
      {200,
       %{
         did: "did:plc:alice",
         handle: "alice.test",
         associated:
           if(allow, do: %{activitySubscription: %{allowSubscriptions: allow}}, else: %{}),
         viewer: viewer
       }}
    end

    test "subscribing names the account by DID and is refused where the account does not allow it" do
      following = %{following: "at://did:plc:self/app.bsky.graph.follow/f"}

      for {allow, viewer, allowed?} <- [
            {nil, %{}, false},
            {nil, following, true},
            {"followers", following, true},
            {"mutuals", following, false},
            {"mutuals", Map.put(following, :followedBy, "at://did:plc:alice/x/y"), true},
            {"none", following, false}
          ] do
        %{effects: effects, pds: pds} =
          pds(answers: %{"app.bsky.actor.getProfile" => profile(allow, viewer)})

        result = AtMcp.Effects.subscribe_to_activity(effects, "alice.test", true, false)

        if allowed? do
          assert {:ok,
                  %{
                    actor: "did:plc:alice",
                    handle: "alice.test",
                    previous: %{posts: false, replies: false},
                    now: %{posts: true, replies: false}
                  }} = result

          assert [%{body: body}] =
                   FakePDS.sent(pds, "app.bsky.notification.putActivitySubscription")

          assert body == %{
                   "subject" => "did:plc:alice",
                   "activitySubscription" => %{"post" => true, "reply" => false}
                 }

          assert Lexicon.problems(body, "app.bsky.notification.putActivitySubscription") == []
        else
          assert {:error, {:invalid_argument, "actor", _}} = result, inspect({allow, viewer})
          assert FakePDS.sent(pds, "app.bsky.notification.putActivitySubscription") == []
        end
      end
    end

    test "unsubscribing is taken whatever the account allows, and one already as asked sends nothing" do
      subscribed = %{activitySubscription: %{post: true, reply: true}}

      %{effects: effects, pds: pds} =
        pds(answers: %{"app.bsky.actor.getProfile" => profile("none", subscribed)})

      assert {:ok, %{unchanged: true}} =
               AtMcp.Effects.subscribe_to_activity(effects, "did:plc:alice", true, true)

      assert {:ok,
              %{previous: %{posts: true, replies: true}, now: %{posts: false, replies: false}}} =
               AtMcp.Effects.subscribe_to_activity(effects, "did:plc:alice", false, false)

      assert [%{body: %{"activitySubscription" => %{"post" => false, "reply" => false}}}] =
               FakePDS.sent(pds, "app.bsky.notification.putActivitySubscription")
    end

    test "this account cannot subscribe to itself, by any name that resolves to it" do
      %{effects: effects, pds: pds} = pds()

      for actor <- ["self.example", "did:plc:self", "also-self.test"] do
        assert {:error, {:invalid_argument, "actor", _}} =
                 AtMcp.Effects.subscribe_to_activity(effects, actor, true, false)
      end

      refute "app.bsky.notification.putActivitySubscription" in FakePDS.methods(pds)
    end

    test "an unsubscribe is sent even when the profile shows no subscription, which a block can hide" do
      %{effects: effects, pds: pds} =
        pds(
          answers: %{
            "app.bsky.actor.getProfile" =>
              profile(nil, %{blocking: "at://did:plc:self/app.bsky.graph.block/b"})
          }
        )

      assert {:ok, %{unchanged: false, note: note}} =
               AtMcp.Effects.subscribe_to_activity(effects, "did:plc:alice", false, false)

      assert note =~ "block"
      assert [_] = FakePDS.sent(pds, "app.bsky.notification.putActivitySubscription")

      # Subscribing says a block may be why it is not allowed.
      assert {:error, {:invalid_argument, "actor", message}} =
               AtMcp.Effects.subscribe_to_activity(effects, "did:plc:alice", true, false)

      assert message =~ "block"
    end
  end

  test "the text a model reads names each notification setting and a profile's subscription" do
    settings =
      AtMcp.Preferences.notification_view(%{
        "like" => %{"include" => "follows", "list" => true, "push" => false}
      })

    text =
      AtMcp.Reading.notification_settings(Jason.decode!(Jason.encode!(%{settings: settings})))

    assert text =~ "like: from follows, list on, push off"
    assert text =~ "verified: list on, push on"

    profile =
      AtMcp.Summary.extract(:profile, %{
        "did" => "did:plc:alice",
        "handle" => "alice.test",
        "associated" => %{"activitySubscription" => %{"allowSubscriptions" => "mutuals"}},
        "viewer" => %{"activitySubscription" => %{"post" => true, "reply" => false}}
      })

    text = AtMcp.Reading.profile(Jason.decode!(Jason.encode!(profile)))
    assert text =~ "Lets only mutuals subscribe to its posts"
    assert text =~ "You are subscribed to its posts"
    refute text =~ "and replies"
  end

  test "a group of subscribed posts is one account posting several times" do
    group =
      AtMcp.Summary.extract(:notification_group, %{
        "kind" => "subscribedPostGroup",
        "count" => 3,
        "actors" => [%{"did" => "did:plc:alice", "handle" => "alice.test"}],
        "posts" => [
          %{"uri" => "at://did:plc:alice/app.bsky.feed.post/1"},
          %{"uri" => "at://did:plc:alice/app.bsky.feed.post/2"},
          %{"uri" => "at://did:plc:alice/app.bsky.feed.post/3"}
        ]
      })

    text =
      AtMcp.Reading.notifications(
        Jason.decode!(Jason.encode!(%{items: [group], count: 1, seen_at: nil}))
      )

    assert text =~ "alice.test posted 3 times (you are subscribed)"
    refute text =~ "others"
  end

  describe "grouped notifications" do
    @grouped %{
      "groups" => [
        %{
          "id" => "g1",
          "isRead" => false,
          "indexedAt" => "2026-10-18T00:00:00.000Z",
          "count" => 3,
          "kind" => %{
            "$type" => "app.bsky.notification.getGroupedNotifications#likeGroup",
            "post" => "at://did:plc:self/app.bsky.feed.post/p",
            "items" => [%{"actor" => "did:plc:alice"}, %{"actor" => "did:plc:bob"}]
          }
        },
        %{
          "id" => "g2",
          "isRead" => true,
          "indexedAt" => "2026-10-17T00:00:00.000Z",
          "count" => 1,
          "kind" => %{
            "$type" => "app.bsky.notification.getGroupedNotifications#replyNotification",
            "post" => "at://did:plc:alice/app.bsky.feed.post/r",
            "parent" => "at://did:plc:self/app.bsky.feed.post/p"
          }
        }
      ],
      "seenAt" => "2026-10-16T00:00:00.000Z",
      "cursor" => "next",
      "relatedViews" => [
        %{
          "$type" => "app.bsky.actor.defs#profileViewBasic",
          "did" => "did:plc:alice",
          "handle" => "alice.test"
        },
        %{
          "$type" => "app.bsky.feed.defs#postView",
          "uri" => "at://did:plc:self/app.bsky.feed.post/p",
          "record" => %{"text" => "a kite"}
        },
        %{
          "$type" => "app.bsky.feed.defs#postView",
          "uri" => "at://did:plc:alice/app.bsky.feed.post/r",
          "author" => %{"did" => "did:plc:alice", "handle" => "alice.test"},
          "record" => %{
            "text" => "nice kite @self.test",
            "facets" => [
              %{
                "index" => %{"byteStart" => 10, "byteEnd" => 20},
                "features" => [
                  %{"$type" => "app.bsky.richtext.facet#mention", "did" => "did:plc:self"}
                ]
              }
            ]
          }
        }
      ]
    }

    test "get_notifications grouped reads a tab of the app's Notifications screen, each group hydrated from the related views" do
      %{effects: effects, pds: pds} =
        pds(answers: %{"app.bsky.notification.getGroupedNotifications" => {200, @grouped}})

      state = %{effects: effects}

      result =
        call(state, "get_notifications", %{
          "grouped" => true,
          "feed" => "conversations",
          "limit" => 5
        })

      refute result[:isError], inspect(result)

      assert [%{query: %{"feed" => "conversations", "limit" => "5"}}] =
               FakePDS.sent(pds, "app.bsky.notification.getGroupedNotifications")

      assert %{
               "count" => 2,
               "cursor" => "next",
               "seen_at" => "2026-10-16T00:00:00.000Z",
               "items" => [like, reply]
             } = result.structuredContent

      assert %{
               "kind" => "likeGroup",
               "count" => 3,
               "is_read" => false,
               "actors" => [
                 %{"did" => "did:plc:alice", "handle" => "alice.test"},
                 %{"did" => "did:plc:bob", "handle" => nil}
               ],
               "posts" => [
                 %{"uri" => "at://did:plc:self/app.bsky.feed.post/p", "text" => "a kite"}
               ]
             } = like

      # A reply names no actor; its post's author is who acted.
      assert %{
               "kind" => "replyNotification",
               "actors" => [%{"did" => "did:plc:alice", "handle" => "alice.test"}],
               "parent" => "at://did:plc:self/app.bsky.feed.post/p",
               # The mention reads with the DID it notified, as in any post.
               "posts" => [%{"text" => "nice kite @self.test <did:plc:self>"}]
             } = reply

      {:ok, tools, nil, ^state} = AtMcp.MCP.Server.handle_list_tools(nil, state)
      schema = Enum.find(tools, &(&1.name == "get_notifications")).outputSchema

      assert AtMcp.Test.Schema.valid?(
               Jason.decode!(Jason.encode!(result.structuredContent)),
               schema
             )

      text = hd(result.content).text
      assert text =~ "2 notification groups."
      assert text =~ "alice.test, did:plc:bob and 1 other liked your post"

      assert text =~
               ~s(at://did:plc:self/app.bsky.feed.post/p · link: https://bsky.app/profile/did:plc:self/post/p · "a kite")

      assert text =~ "alice.test replied"
      assert text =~ ~s("nice kite @self.test <did:plc:self>")
      assert text =~ "replying to at://did:plc:self/app.bsky.feed.post/p"
    end

    test "reasons is the ungrouped read's and feed the grouped one's; nothing is sent for either" do
      %{effects: effects, pds: pds} = pds()
      state = %{effects: effects}

      refused(
        call(state, "get_notifications", %{"grouped" => true, "reasons" => ["like"]}),
        "reasons"
      )

      refused(call(state, "get_notifications", %{"feed" => "followers"}), "feed")
      assert FakePDS.methods(pds) == []
    end
  end

  describe "on delve.town" do
    test "grouped notifications, which the town does not serve, are refused before anything is sent" do
      Application.put_env(:at_mcp, :network, :delve)
      on_exit(fn -> Application.delete_env(:at_mcp, :network) end)
      %{effects: effects, pds: pds} = pds()

      result = call(%{effects: effects}, "get_notifications", %{"grouped" => true})

      assert %{code: "not_served", method: "town.delve.notification.getGroupedNotifications"} =
               result.structuredContent

      assert FakePDS.methods(pds) == []
    end
  end

  describe "on delve.town, settings" do
    setup do
      Application.put_env(:at_mcp, :network, :delve)
      on_exit(fn -> Application.delete_env(:at_mcp, :network) end)
      :ok
    end

    test "the preferences, records and methods are the town's" do
      %{effects: effects, pds: pds} = pds()

      assert {:ok, _} =
               AtMcp.Effects.set_preference(effects, "verification", %{hide_badges: true})

      assert [%{"$type" => "town.delve.actor.defs#verificationPrefs"}] = FakePDS.preferences(pds)

      assert {:ok, %{uri: "at://did:plc:self/town.delve.actor.contentVisibilityDeclaration/self"}} =
               AtMcp.Effects.set_preference(effects, "discoverable", %{
                 hide_from_recommendations: true
               })

      assert {:ok, _} = AtMcp.Effects.set_notification_setting(effects, "reply", push: false)
      assert [_] = FakePDS.sent(pds, "town.delve.notification.putPreferencesV2")
    end
  end

  defp pds(opts \\ []) do
    {session, pds} =
      FakePDS.start(
        records: Keyword.get(opts, :records, %{}),
        preferences: Keyword.get(opts, :preferences, []),
        notification_preferences: Keyword.get(opts, :notification_preferences, %{}),
        answers: Keyword.get(opts, :answers, %{}),
        handles: %{"alice.test" => "did:plc:alice", "also-self.test" => "did:plc:self"}
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
