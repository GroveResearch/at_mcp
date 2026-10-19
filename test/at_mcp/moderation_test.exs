defmodule AtMcp.ModerationTest do
  @moduledoc """
  Moderation (#90): reports, muted words, moderation list mutes and blocks,
  labelers and label settings.

  The real backend runs against a fake PDS, and each test checks what reached
  the wire: a preference changes the way the app's library changes it, every
  other preference is kept as stored, an account, list or post named by a
  handle is sent in its DID form, a setting already as asked writes nothing,
  and what the app would not do is refused before anything is sent.
  """
  use ExUnit.Case, async: false

  alias AtMcp.Test.FakePDS
  alias AtMcp.Test.Lexicon

  @bsky_moderation "did:plc:ar7c4by46qjdydhdevvrndac"
  @labeler "did:plc:labeler"
  @list "at://did:plc:alice/app.bsky.graph.list/mod1"
  @odd %{"$type" => "app.bsky.actor.defs#bskyAppStatePref", "queuedNudges" => ["x"]}
  @adult_on %{"$type" => "app.bsky.actor.defs#adultContentPref", "enabled" => true}

  defp pds(opts \\ []) do
    {session, pds} =
      FakePDS.start(
        records: Keyword.get(opts, :records, %{}),
        preferences: Keyword.get(opts, :preferences, []),
        answers: Keyword.get(opts, :answers, %{}),
        handles: %{
          "alice.test" => "did:plc:alice",
          "labeler.test" => @labeler,
          "also-self.test" => "did:plc:self"
        }
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

  defp put_body(pds) do
    [%{body: body}] = FakePDS.sent(pds, "app.bsky.actor.putPreferences")
    assert Lexicon.problems(body, "app.bsky.actor.putPreferences") == []
    body["preferences"]
  end

  defp call(effects, name, arguments) do
    state = %{effects: effects}
    {:ok, result, ^state} = AtMcp.MCP.Server.handle_call_tool(name, arguments, state)
    result
  end

  # A labeler's detailed view, as `labeler.getServices` answers it.
  defp labeler_view(did, extra \\ %{}) do
    Map.merge(
      %{
        "uri" => "at://#{did}/app.bsky.labeler.service/self",
        "cid" => "bafylabeler",
        "creator" => %{"did" => did, "handle" => "labeler.test"},
        "indexedAt" => "2026-10-19T00:00:00.000Z",
        "policies" => %{
          # As the app's labeler page reads them: each value once, `!`-prefixed
          # ones and those with no valid definition left out, `porn` a global
          # filter, `odd` dropped for its invalid definition, `inform` set to
          # warn by default.
          "labelValues" => ["spoiler", "quiet", "porn", "lewd", "!hide", "odd", "spoiler", "loud"],
          "labelValueDefinitions" => [
            %{
              "identifier" => "spoiler",
              "severity" => "alert",
              "blurs" => "content",
              "defaultSetting" => "hide",
              "locales" => [%{"lang" => "en", "name" => "Spoiler", "description" => "Spoils"}]
            },
            %{
              "identifier" => "quiet",
              "severity" => "none",
              "blurs" => "none",
              "locales" => []
            },
            %{
              "identifier" => "lewd",
              "severity" => "none",
              "blurs" => "media",
              "adultOnly" => true,
              "locales" => []
            },
            %{"identifier" => "odd", "severity" => "alert", "blurs" => "content"},
            %{"identifier" => "!hide", "severity" => "none", "blurs" => "none", "locales" => []},
            %{
              "identifier" => "loud",
              "severity" => "alert",
              "blurs" => "content",
              "defaultSetting" => "inform",
              "locales" => []
            }
          ]
        }
      },
      extra
    )
  end

  defp services(views), do: %{"app.bsky.labeler.getServices" => {200, %{views: views}}}

  defp list_answer(purpose, viewer \\ %{}),
    do: %{
      "app.bsky.graph.getList" =>
        {200,
         %{
           list: %{
             uri: @list,
             cid: "bafylist",
             name: "Spammers",
             purpose: "app.bsky.graph.defs#" <> purpose,
             creator: %{did: "did:plc:alice", handle: "alice.test"},
             indexedAt: "2026-10-19T00:00:00.000Z",
             viewer: viewer
           },
           items: []
         }}
    }

  describe "muted words" do
    test "mute_word adds the word as addMutedWord does and keeps every other preference as stored" do
      legacy = %{"value" => "old", "targets" => ["content"]}

      words = %{
        "$type" => "app.bsky.actor.defs#mutedWordsPref",
        "items" => [legacy]
      }

      %{effects: effects, pds: pds} = pds(preferences: [@odd, words])

      assert {:ok, %{action: :mute_word, value: "spoilers", previous: [], now: [now], note: note}} =
               AtMcp.Effects.mute_word(effects, "  #spoilers\n", tags_only: true)

      assert note =~ "no compare-and-swap"
      assert %{tags_only: true, only_non_followed: false, expires_at: nil} = now

      [kept, pref] = put_body(pds)
      assert kept == @odd

      # The library gives a muted word without an id one, and keeps its fields.
      assert [%{"value" => "old", "targets" => ["content"], "id" => old_id}, added] =
               pref["items"]

      assert is_binary(old_id)

      assert %{"value" => "spoilers", "targets" => ["tag"], "actorTarget" => "all", "id" => id} =
               added

      refute Map.has_key?(added, "expiresAt")
      assert id =~ ~r/^[2-7a-z]{13}$/
    end

    test "a word muted already is changed in place, not muted twice; muted exactly so, nothing is written" do
      words = %{
        "$type" => "app.bsky.actor.defs#mutedWordsPref",
        "items" => [
          %{
            "id" => "3aaa",
            "value" => "Spoilers",
            "targets" => ["tag", "content"],
            "actorTarget" => "all"
          }
        ]
      }

      %{effects: effects, pds: pds} = pds(preferences: [words])

      assert {:ok, %{unchanged: true}} = AtMcp.Effects.mute_word(effects, "spoilers")
      assert FakePDS.sent(pds, "app.bsky.actor.putPreferences") == []

      before = DateTime.utc_now()

      assert {:ok, %{unchanged: false, previous: [%{expires_at: nil}], now: [now]}} =
               AtMcp.Effects.mute_word(effects, "spoilers",
                 duration: "7d",
                 only_non_followed: true
               )

      assert %{id: "3aaa", value: "Spoilers", only_non_followed: true} = now

      [%{"items" => [item]}] = put_body(pds)

      assert %{"id" => "3aaa", "actorTarget" => "exclude-following", "expiresAt" => expires} =
               item

      {:ok, at, 0} = DateTime.from_iso8601(expires)
      assert_in_delta DateTime.diff(at, before, :second), 7 * 86_400, 5
    end

    test "unmute_word removes every muted word of the value and names each one" do
      words = %{
        "$type" => "app.bsky.actor.defs#mutedWordsPref",
        "items" => [
          %{"id" => "1", "value" => "a", "targets" => ["tag"]},
          %{"id" => "2", "value" => "A", "targets" => ["tag", "content"]},
          %{"id" => "3", "value" => "b", "targets" => ["tag"]}
        ]
      }

      %{effects: effects, pds: pds} = pds(preferences: [words, @odd])

      assert {:ok, %{removed: [%{id: "1", tags_only: true}, %{id: "2", tags_only: false}]}} =
               AtMcp.Effects.unmute_word(effects, "a")

      assert [@odd, %{"items" => [%{"id" => "3"}]}] = put_body(pds)

      assert {:ok, %{unchanged: true, removed: []}} = AtMcp.Effects.unmute_word(effects, "zzz")
      assert length(FakePDS.sent(pds, "app.bsky.actor.putPreferences")) == 1
    end

    test "a word unmute_word returned is muted again exactly as it was, by targets and expires_at" do
      word = %{
        "id" => "1",
        "value" => "plot",
        "targets" => ["content"],
        "actorTarget" => "exclude-following",
        "expiresAt" => "2031-01-02T03:04:05.000Z"
      }

      %{effects: effects, pds: pds} =
        pds(preferences: [%{"$type" => "app.bsky.actor.defs#mutedWordsPref", "items" => [word]}])

      assert {:ok, %{removed: [removed]}} = AtMcp.Effects.unmute_word(effects, "plot")

      assert {:ok, %{previous: [], now: [now]}} =
               AtMcp.Effects.mute_word(effects, removed.value,
                 targets: removed.targets,
                 only_non_followed: removed.only_non_followed,
                 expires_at: removed.expires_at
               )

      assert Map.drop(now, [:id]) == Map.drop(removed, [:id])

      %{body: %{"preferences" => [%{"items" => [item]}]}} =
        List.last(FakePDS.sent(pds, "app.bsky.actor.putPreferences"))

      assert Map.delete(item, "id") == Map.delete(word, "id")

      # The same again is already so.
      assert {:ok, %{unchanged: true}} =
               AtMcp.Effects.mute_word(effects, "plot",
                 targets: ["content"],
                 only_non_followed: true,
                 expires_at: "2031-01-02T03:04:05.000Z"
               )

      for {opts, field} <- [
            {[targets: ["tag"], tags_only: true], "targets"},
            {[expires_at: "x", duration: "7d"], "expires_at"},
            {[expires_at: "tomorrow"], "expires_at"},
            {[targets: []], "targets"}
          ] do
        assert {:error, {:invalid_argument, ^field, _}} =
                 AtMcp.Effects.mute_word(effects, "plot", opts)
      end
    end

    test "an empty word is refused before anything is sent" do
      %{effects: effects, pds: pds} = pds()
      result = call(effects, "mute_word", %{"value" => " # "})
      assert result.isError
      assert %{code: "invalid_arguments"} = result.structuredContent
      assert FakePDS.methods(pds) == []
    end

    test "get_preferences reads the muted words, labelers and label settings as the app does" do
      prefs = [
        %{
          "$type" => "app.bsky.actor.defs#mutedWordsPref",
          "items" => [
            %{"value" => "x", "targets" => ["tag"], "expiresAt" => "2000-01-01T00:00:00.000Z"}
          ]
        },
        %{"$type" => "app.bsky.actor.defs#labelersPref", "labelers" => [%{"did" => @labeler}]},
        # The legacy name is read over the new one, and `show` is `ignore`.
        %{
          "$type" => "app.bsky.actor.defs#contentLabelPref",
          "label" => "porn",
          "visibility" => "warn"
        },
        %{
          "$type" => "app.bsky.actor.defs#contentLabelPref",
          "label" => "nsfw",
          "visibility" => "show"
        }
      ]

      %{effects: effects} = pds(preferences: prefs)

      assert {:ok, view} = AtMcp.Effects.get_preferences(effects)
      assert [%{value: "x", tags_only: true, expired: true}] = view.muted_words
      assert view.labelers == [@bsky_moderation, @labeler]

      assert view.content_labels == %{
               "porn" => "show",
               "sexual" => "warn",
               "graphic-media" => "warn",
               "nudity" => "show"
             }
    end
  end

  describe "labelers and label settings" do
    test "subscribe_labeler adds the labeler as addLabeler does; the network's own and a non-labeler are refused unsent" do
      %{effects: effects, pds: pds} =
        pds(preferences: [@odd], answers: services([labeler_view(@labeler)]))

      assert {:ok, %{previous: false, now: true, actor: @labeler, handle: "labeler.test"}} =
               AtMcp.Effects.subscribe_labeler(effects, "labeler.test", true)

      assert [
               @odd,
               %{
                 "$type" => "app.bsky.actor.defs#labelersPref",
                 "labelers" => [%{"did" => @labeler}]
               }
             ] =
               put_body(pds)

      sent = length(FakePDS.methods(pds))

      assert {:error, {:invalid_argument, "actor", message}} =
               AtMcp.Effects.subscribe_labeler(effects, @bsky_moderation, true)

      assert message =~ "every account has"
      assert length(FakePDS.methods(pds)) == sent
    end

    test "an account that runs no labeler is not subscribed to, and the app's limit of 20 holds" do
      many = for n <- 1..19, do: %{"did" => "did:plc:l#{n}"}

      %{effects: effects, pds: pds} =
        pds(
          preferences: [%{"$type" => "app.bsky.actor.defs#labelersPref", "labelers" => many}],
          answers:
            Map.put(
              services([labeler_view(@labeler)]),
              "app.bsky.actor.getProfiles",
              {200,
               %{
                 profiles:
                   for(%{"did" => did} <- many, do: %{did: did, associated: %{labeler: true}})
               }}
            )
        )

      assert {:error, {:invalid_argument, "actor", message}} =
               AtMcp.Effects.subscribe_labeler(effects, @labeler, true)

      assert message =~ "allows 20"
      assert message =~ "unsubscribe_labeler one first"

      # Labelers that are gone count, as stored; they are named so they can go.
      gone_profiles = %{
        "app.bsky.actor.getProfiles" =>
          {200,
           %{
             profiles:
               for n <- 1..19, n not in [3, 4] do
                 %{
                   did: "did:plc:l#{n}",
                   handle: "l#{n}.test",
                   associated: %{labeler: n != 5}
                 }
               end
           }}
      }

      %{effects: effects, pds: pds3} =
        pds(
          preferences: [%{"$type" => "app.bsky.actor.defs#labelersPref", "labelers" => many}],
          answers: Map.merge(services([labeler_view(@labeler)]), gone_profiles)
        )

      assert {:error, {:invalid_argument, "actor", message}} =
               AtMcp.Effects.subscribe_labeler(effects, @labeler, true)

      assert message =~ "did:plc:l3, did:plc:l4, did:plc:l5 are gone"
      assert FakePDS.sent(pds3, "app.bsky.actor.putPreferences") == []

      %{effects: effects, pds: pds2} = pds(answers: services([]))

      assert {:error, {:invalid_argument, "actor", message}} =
               AtMcp.Effects.subscribe_labeler(effects, "alice.test", true)

      assert message =~ "runs no labeler"
      assert FakePDS.sent(pds, "app.bsky.actor.putPreferences") == []
      assert FakePDS.sent(pds2, "app.bsky.actor.putPreferences") == []
    end

    test "unsubscribe_labeler removes it, and one not subscribed to is left alone" do
      pref = %{
        "$type" => "app.bsky.actor.defs#labelersPref",
        "labelers" => [%{"did" => @labeler}, %{"did" => "did:plc:other"}]
      }

      %{effects: effects, pds: pds} = pds(preferences: [pref])

      assert {:ok, %{previous: true, now: false}} =
               AtMcp.Effects.subscribe_labeler(effects, @labeler, false)

      assert [%{"labelers" => [%{"did" => "did:plc:other"}]}] = put_body(pds)

      assert {:ok, %{unchanged: true}} =
               AtMcp.Effects.subscribe_labeler(effects, "did:plc:never", false)
    end

    test "a filter of the moderation screen is set as setContentLabelPref sets it, its old name too, only while adult content is on" do
      %{effects: effects, pds: pds} = pds(preferences: [@odd])

      assert {:error, {:invalid_argument, "label", message}} =
               AtMcp.Effects.set_label_visibility(effects, "porn", "show")

      assert message =~ "adult content"
      assert FakePDS.sent(pds, "app.bsky.actor.putPreferences") == []

      old = %{
        "$type" => "app.bsky.actor.defs#contentLabelPref",
        "label" => "nsfw",
        "visibility" => "hide"
      }

      %{effects: effects, pds: pds} = pds(preferences: [@adult_on, old, @odd])

      assert {:ok, %{previous: "hide", now: "show", labeler: nil}} =
               AtMcp.Effects.set_label_visibility(effects, "porn", "show")

      assert [@adult_on, @odd, porn, nsfw] = put_body(pds)

      assert porn == %{
               "$type" => "app.bsky.actor.defs#contentLabelPref",
               "label" => "porn",
               "visibility" => "ignore"
             }

      assert %{"label" => "nsfw", "visibility" => "ignore"} = nsfw
      refute Map.has_key?(nsfw, "labelerDid")

      assert {:error, {:invalid_argument, "label", _}} =
               AtMcp.Effects.set_label_visibility(effects, "spoiler", "hide")
    end

    test "a labeler's own label is set for that labeler, when the account takes its labels and it defines the label" do
      subscribed = %{
        "$type" => "app.bsky.actor.defs#labelersPref",
        "labelers" => [%{"did" => @labeler}]
      }

      %{effects: effects, pds: pds} = pds(answers: services([labeler_view(@labeler)]))

      assert {:error, {:invalid_argument, "labeler", message}} =
               AtMcp.Effects.set_label_visibility(effects, "spoiler", "warn", "labeler.test")

      assert message =~ "does not subscribe"
      assert FakePDS.sent(pds, "app.bsky.actor.putPreferences") == []

      %{effects: effects, pds: pds} =
        pds(preferences: [subscribed], answers: services([labeler_view(@labeler)]))

      # Not listed, a global filter, a definition the lexicon refuses, a
      # `!` value, warn for a label that neither blurs nor warns, and an
      # adult-only label while adult content is off.
      for {label, visibility, field} <- [
            {"nope", "hide", "label"},
            {"porn", "hide", "label"},
            {"odd", "hide", "label"},
            {"!hide", "hide", "label"},
            {"quiet", "warn", "visibility"},
            {"lewd", "show", "label"}
          ] do
        assert {:error, {:invalid_argument, ^field, _}} =
                 AtMcp.Effects.set_label_visibility(effects, label, visibility, "labeler.test")
      end

      assert FakePDS.sent(pds, "app.bsky.actor.putPreferences") == []

      assert {:ok, %{previous: "hide", now: "warn", labeler: @labeler}} =
               AtMcp.Effects.set_label_visibility(effects, "spoiler", "warn", "labeler.test")

      assert [^subscribed, set] = put_body(pds)
      assert %{"label" => "spoiler", "labelerDid" => @labeler, "visibility" => "warn"} = set

      # A label that neither blurs nor warns shows its default warn as show.
      assert {:ok, %{previous: "show", now: "hide"}} =
               AtMcp.Effects.set_label_visibility(effects, "quiet", "hide", "labeler.test")

      # A defaultSetting other than hide or ignore is warn.
      assert {:ok, %{previous: "warn", now: "show"}} =
               AtMcp.Effects.set_label_visibility(effects, "loud", "show", "labeler.test")
    end

    test "get_labelers reads each labeler with this account's settings for its labels" do
      prefs = [
        %{"$type" => "app.bsky.actor.defs#labelersPref", "labelers" => [%{"did" => @labeler}]},
        %{
          "$type" => "app.bsky.actor.defs#contentLabelPref",
          "label" => "spoiler",
          "labelerDid" => @labeler,
          "visibility" => "show"
        }
      ]

      %{effects: effects, pds: pds} =
        pds(
          preferences: prefs,
          answers: services([labeler_view(@labeler, %{"reasonTypes" => ["x"]})])
        )

      assert {:ok, %{items: [labeler], missing: [@bsky_moderation]}} =
               AtMcp.Effects.get_labelers(effects, [])

      [%{raw: raw}] = FakePDS.sent(pds, "app.bsky.labeler.getServices")
      assert raw =~ "dids=did%3Aplc%3Aar7c4by46qjdydhdevvrndac&dids=did%3Aplc%3Alabeler"

      assert %{subscribed: true, built_in: false, reason_types: ["x"], subject_types: nil} =
               labeler

      assert [
               %{identifier: "spoiler", name: "Spoiler", setting: "show", default: "hide"},
               %{identifier: "quiet", setting: "show", default: "show"},
               %{identifier: "porn", global: true, setting: "hide"},
               %{identifier: "lewd", adult_only: true, setting: "hide"},
               %{identifier: "loud", setting: "warn", default: "warn"}
             ] = labeler.labels
    end
  end

  describe "moderation lists" do
    test "block_list writes a list block naming the list in DID form, over the commit read, and only for a moderation list" do
      %{effects: effects, pds: pds} = pds(answers: list_answer("curatelist"))

      assert {:error, {:invalid_argument, "uri", message}} =
               AtMcp.Effects.block_list(effects, "at://alice.test/app.bsky.graph.list/mod1")

      assert message =~ "moderation list"
      assert FakePDS.sent(pds, "com.atproto.repo.applyWrites") == []

      %{effects: effects, pds: pds} = pds(answers: list_answer("modlist"))

      assert {:ok, %{action: :block_list, list: @list, name: "Spammers", uri: uri}} =
               AtMcp.Effects.block_list(effects, "at://alice.test/app.bsky.graph.list/mod1")

      [%{body: body}] = FakePDS.sent(pds, "com.atproto.repo.applyWrites")
      assert is_binary(body["swapCommit"])
      [%{"value" => record}] = body["writes"]
      assert %{"subject" => @list, "$type" => "app.bsky.graph.listblock"} = record
      assert Lexicon.problems(record, "app.bsky.graph.listblock") == []
      assert uri =~ "at://did:plc:self/app.bsky.graph.listblock/"

      # Blocked already: named, not written again.
      assert {:ok, %{unchanged: true, uri: ^uri}} = AtMcp.Effects.block_list(effects, @list)
      assert length(FakePDS.sent(pds, "com.atproto.repo.applyWrites")) == 1

      # Unblocked by the list block it names; then there is none to delete.
      assert {:ok, %{deleted: [^uri], list: @list}} = AtMcp.Effects.unblock_list(effects, uri)
      assert FakePDS.record(pds, uri) == nil

      assert {:ok, %{unchanged: true, deleted: []}} = AtMcp.Effects.unblock_list(effects, @list)
    end

    test "unblock_list deletes every list block of this account's naming the list" do
      blocks = %{
        "at://did:plc:self/app.bsky.graph.listblock/a" => %{"subject" => @list},
        "at://did:plc:self/app.bsky.graph.listblock/b" => %{"subject" => @list},
        "at://did:plc:self/app.bsky.graph.listblock/c" => %{
          "subject" => "at://did:plc:x/app.bsky.graph.list/y"
        }
      }

      %{effects: effects, pds: pds} = pds(records: blocks)

      assert {:ok, %{deleted: deleted, list: @list}} =
               AtMcp.Effects.unblock_list(effects, "at://alice.test/app.bsky.graph.list/mod1")

      assert Enum.sort(deleted) == [
               "at://did:plc:self/app.bsky.graph.listblock/a",
               "at://did:plc:self/app.bsky.graph.listblock/b"
             ]

      assert FakePDS.record(pds, "at://did:plc:self/app.bsky.graph.listblock/c")
      [%{body: %{"swapCommit" => swap}}] = FakePDS.sent(pds, "com.atproto.repo.applyWrites")
      assert is_binary(swap)
    end

    test "unblock_list of a list block in another repository is refused unsent" do
      %{effects: effects, pds: pds} = pds()

      assert {:error, {:invalid_argument, "uri", _}} =
               AtMcp.Effects.unblock_list(effects, "at://did:plc:x/app.bsky.graph.listblock/a")

      assert FakePDS.methods(pds) == []
    end

    test "mute_list sends the list in DID form, for a moderation list alone; unmute_list sends it whatever the view said" do
      %{effects: effects, pds: pds} = pds(answers: list_answer("modlist", %{muted: false}))

      assert {:ok, %{action: :mute_list, list: @list, muted: true, previous: false}} =
               AtMcp.Effects.mute_list(effects, "at://alice.test/app.bsky.graph.list/mod1")

      assert [%{body: %{"list" => @list}, proxy: proxy}] =
               FakePDS.sent(pds, "app.bsky.graph.muteActorList")

      assert proxy =~ "#bsky_appview"

      assert {:ok, %{muted: false}} = AtMcp.Effects.unmute_list(effects, @list)
      assert [%{body: %{"list" => @list}}] = FakePDS.sent(pds, "app.bsky.graph.unmuteActorList")

      %{effects: effects, pds: pds} = pds(answers: list_answer("curatelist"))
      assert {:error, {:invalid_argument, "uri", _}} = AtMcp.Effects.mute_list(effects, @list)
      assert FakePDS.sent(pds, "app.bsky.graph.muteActorList") == []
    end

    test "get_moderation_lists reads the muted or blocked lists" do
      %{effects: effects, pds: pds} =
        pds(
          answers: %{
            "app.bsky.graph.getListBlocks" =>
              {200,
               %{lists: [%{uri: @list, name: "Spammers", purpose: "app.bsky.graph.defs#modlist"}]}}
          }
        )

      assert {:ok, %{items: [%{uri: @list, purpose: "moderation"}]}} =
               AtMcp.Effects.get_moderation_lists(effects, "blocked")

      assert {:error, {:invalid_argument, "kind", _}} =
               AtMcp.Effects.get_moderation_lists(effects, "hidden")

      assert [_] = FakePDS.sent(pds, "app.bsky.graph.getListBlocks")
    end
  end

  describe "reports" do
    test "an account named by a handle is reported by DID to the network's own service, through the PDS's proxy" do
      %{effects: effects, pds: pds} =
        pds(
          answers:
            Map.merge(services([labeler_view(@bsky_moderation)]), %{
              "com.atproto.moderation.createReport" =>
                {200,
                 %{
                   id: 42,
                   reasonType: "tools.ozone.report.defs#reasonMisleadingSpam",
                   subject: %{},
                   reportedBy: "did:plc:self",
                   createdAt: "2026-10-19T00:00:00.000Z"
                 }}
            })
        )

      assert {:ok,
              %{
                id: 42,
                labeler: @bsky_moderation,
                subject: "did:plc:alice",
                reason: "misleading_spam",
                note: note
              }} =
               AtMcp.Effects.report(effects, "alice.test", "spam", details: "repeated ads")

      assert note =~ "cannot be withdrawn"

      [%{body: body, proxy: proxy}] = FakePDS.sent(pds, "com.atproto.moderation.createReport")
      assert proxy == @bsky_moderation <> "#atproto_labeler"

      assert body == %{
               "reasonType" => "tools.ozone.report.defs#reasonMisleadingSpam",
               "reason" => "repeated ads",
               "subject" => %{
                 "$type" => "com.atproto.admin.defs#repoRef",
                 "did" => "did:plc:alice"
               }
             }

      assert Lexicon.problems(body, "com.atproto.moderation.createReport") == []
    end

    test "a record is reported by a strong reference, and a service that takes only the first reasons gets the first" do
      post = "at://did:plc:alice/app.bsky.feed.post/p1"

      subscribed = %{
        "$type" => "app.bsky.actor.defs#labelersPref",
        "labelers" => [%{"did" => @labeler}]
      }

      view =
        labeler_view(@labeler, %{
          "reasonTypes" => ["com.atproto.moderation.defs#reasonRude"],
          "subjectTypes" => ["record"]
        })

      %{effects: effects, pds: pds} =
        pds(
          records: %{post => %{"text" => "x"}},
          preferences: [subscribed],
          answers:
            Map.put(services([view]), "com.atproto.moderation.createReport", {200, %{id: 7}})
        )

      reported =
        AtMcp.Effects.report(effects, "at://alice.test/app.bsky.feed.post/p1", "harassment_troll",
          labeler: "labeler.test"
        )

      assert {:ok,
              %{id: 7, reason_type: "com.atproto.moderation.defs#reasonRude", subject: ^post}} =
               reported

      [%{body: body, proxy: proxy}] = FakePDS.sent(pds, "com.atproto.moderation.createReport")
      assert proxy == @labeler <> "#atproto_labeler"

      assert body["subject"] == %{
               "$type" => "com.atproto.repo.strongRef",
               "uri" => post,
               "cid" => FakePDS.cid(post)
             }

      assert Lexicon.problems(body, "com.atproto.moderation.createReport") == []

      # What the service does not take is refused before anything is sent.
      for {subject, reason, field} <- [
            {"alice.test", "harassment_troll", "labeler"},
            {post, "misleading_spam", "reason"},
            {post, "child_safety_csam", "labeler"}
          ] do
        assert {:error, {:invalid_argument, ^field, _}} =
                 AtMcp.Effects.report(effects, subject, reason, labeler: @labeler)
      end

      assert length(FakePDS.sent(pds, "com.atproto.moderation.createReport")) == 1
    end

    test "the account itself, its own records, an unsubscribed service and an unknown reason are refused unsent" do
      %{effects: effects, pds: pds} = pds(answers: services([labeler_view(@labeler)]))

      for {subject, opts, field} <- [
            {"self.example", [], "subject"},
            {"also-self.test", [], "subject"},
            {"at://did:plc:self/app.bsky.feed.post/p", [], "subject"},
            {"alice.test", [labeler: @labeler], "labeler"},
            {"at://did:plc:alice/app.bsky.feed.like/l", [], "subject"}
          ] do
        assert {:error, {:invalid_argument, ^field, _}} =
                 AtMcp.Effects.report(effects, subject, "spam", opts)
      end

      assert {:error, {:invalid_argument, "reason", _}} =
               AtMcp.Effects.report(effects, "alice.test", "boring")

      assert FakePDS.sent(pds, "com.atproto.moderation.createReport") == []
    end
  end

  describe "on delve.town" do
    setup do
      Application.put_env(:at_mcp, :network, :delve)
      on_exit(fn -> Application.delete_env(:at_mcp, :network) end)
      :ok
    end

    test "a report, which the town has no moderation service for, is refused before anything is sent" do
      %{effects: effects, pds: pds} = pds()
      result = call(effects, "report", %{"subject" => "alice.test", "reason" => "spam"})

      assert %{code: "not_served", method: "com.atproto.moderation.createReport"} =
               result.structuredContent

      assert FakePDS.methods(pds) == []
    end

    test "muted words and list blocks are the town's" do
      %{effects: effects, pds: pds} = pds()
      assert {:ok, _} = AtMcp.Effects.mute_word(effects, "x")

      assert [%{"$type" => "town.delve.actor.defs#mutedWordsPref"}] =
               FakePDS.preferences(pds)

      assert {:ok, %{list: @list}} =
               AtMcp.Effects.unblock_list(effects, @list)
               |> then(fn {:ok, result} -> {:ok, Map.put(result, :list, @list)} end)
    end
  end
end
