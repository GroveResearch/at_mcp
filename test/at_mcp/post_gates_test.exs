defmodule AtMcp.PostGatesTest do
  @moduledoc """
  Who may reply to a post and quote it, hidden replies, detached quotes, and
  what else a post can now carry: self-labels and a link card (#88).

  Over the mock backend, through the MCP surface: what is refused before
  anything is sent, naming the argument, and what counts against the write
  quota. Against a fake PDS with the real backend: the records that reach the
  wire, that each matches its lexicon (`AtMcp.Test.Lexicon`), that an edit
  keeps every field it does not change, and that a post and its gates are one
  commit.
  """
  use ExUnit.Case, async: false

  alias AtMcp.Test.FakePDS
  alias AtMcp.Test.Lexicon

  # These tests are about what a program reads: a read's summary.
  defp call(state, name, arguments) do
    state = Map.put(state, :format, "json")
    {:ok, result, ^state} = AtMcp.MCP.Server.handle_call_tool(name, arguments, state)
    result
  end

  # What a model reads: a read's text, as it comes without format.
  defp text(state, name, arguments) do
    {:ok, result, ^state} = AtMcp.MCP.Server.handle_call_tool(name, arguments, state)
    hd(result.content).text
  end

  defp problem_paths(result), do: Enum.map(result.structuredContent.problems, & &1.path)

  describe "through the tools, over the mock backend" do
    setup do
      {:ok, effects} =
        AtMcp.Test.QuotaFixture.start_effects(
          backend: AtMcp.Test.MockBackend,
          backend_state: %{mock: true, did: "did:plc:mock", handle: "mock.test"}
        )

      %{state: %{effects: effects}, effects: effects}
    end

    test "a reply_rule entry that is neither a word nor a list is refused, naming it", ctx do
      generator = "at://did:plc:x/app.bsky.feed.generator/hot"

      for {rule, path} <- [
            {["everyone", "mentioned"], "reply_rule/0"},
            {["mentioned", generator], "reply_rule/1"}
          ] do
        result = call(ctx.state, "post", %{"text" => "t", "reply_rule" => rule})
        assert result.isError
        assert problem_paths(result) == [path]
        assert hd(result.content).text =~ "Nothing was sent"
      end

      assert AtMcp.Effects.quota_status(ctx.effects).used == 0
    end

    # A model that fills every optional field it is offered sends this for a
    # post with no card. Read as a card, its thumb is an image that cannot be
    # read, and the whole post was refused.
    @every_optional_empty %{
      "link" => %{
        "url" => "",
        "title" => "",
        "description" => "",
        "thumb" => %{"data" => "", "mimeType" => "", "path" => ""}
      },
      "images" => [%{"data" => "", "mimeType" => "", "path" => "", "alt" => ""}],
      "quote" => "",
      "quotes" => "",
      "labels" => [],
      "langs" => []
    }

    test "a post or reply with every optional argument empty is sent without them", ctx do
      for {name, arguments} <- [
            {"post", %{"text" => "t"}},
            {"reply",
             %{"uri" => "at://did:plc:x/app.bsky.feed.post/3k22222222222", "text" => "t"}},
            # The link card a caller named with `uri`, as the record does.
            {"post", %{"text" => "t", "link" => %{"uri" => "", "thumb" => %{"data" => ""}}}}
          ] do
        result = call(ctx.state, name, Map.merge(@every_optional_empty, arguments))
        refute result[:isError], "#{name}: #{hd(result.content).text}"
        refute hd(result.content).text =~ "ignored"
      end

      assert AtMcp.Effects.quota_status(ctx.effects).used == 3
    end

    test "an empty value that means something is kept" do
      schema = fn name ->
        {:ok, tools, nil, :state} = AtMcp.MCP.Server.handle_list_tools(nil, :state)
        Jason.decode!(Jason.encode!(Enum.find(tools, &(&1.name == name)).inputSchema))
      end

      post = schema.("post")

      assert %{"reply_rule" => []} =
               AtMcp.MCP.Input.drop_empty("post", %{"reply_rule" => []}, post)

      profile = %{"pronouns" => "", "website" => " ", "links" => [], "description" => ""}

      assert AtMcp.MCP.Input.drop_empty("update_profile", profile, schema.("update_profile")) ==
               %{"pronouns" => "", "website" => " ", "links" => [], "description" => ""}

      # Links each of which is empty are not `[]`: the profile's links are kept.
      assert AtMcp.MCP.Input.drop_empty(
               "update_profile",
               %{"links" => [%{"url" => "", "title" => ""}]},
               schema.("update_profile")
             ) == %{}

      assert AtMcp.MCP.Input.drop_empty(
               "update_list",
               %{"uri" => "at://x", "description" => "", "avatar" => %{"data" => ""}},
               schema.("update_list")
             ) == %{"uri" => "at://x", "description" => ""}
    end

    test "quotes and labels outside their values are refused by the schema, naming them", ctx do
      assert ["quotes"] =
               call(ctx.state, "post", %{"text" => "t", "quotes" => "never"}) |> problem_paths()

      assert ["labels/0"] =
               call(ctx.state, "post", %{"text" => "t", "labels" => ["spoiler"]})
               |> problem_paths()
    end

    test "a link card needs an http url and cannot come with images", ctx do
      image = %{"data" => Base.encode64("png"), "mime_type" => "image/png", "alt" => "a"}

      assert ["link/url"] =
               call(ctx.state, "post", %{"text" => "t", "link" => %{"url" => "ftp://x.example"}})
               |> problem_paths()

      assert ["link"] =
               call(ctx.state, "post", %{
                 "text" => "t",
                 "link" => %{"url" => "https://x.example"},
                 "images" => [image]
               })
               |> problem_paths()

      assert AtMcp.Effects.quota_status(ctx.effects).used == 0
    end

    test "a post with its gates counts once and names them", ctx do
      result =
        call(ctx.state, "post", %{"text" => "t", "reply_rule" => [], "quotes" => "disabled"})

      assert %{"threadgate_uri" => "at://" <> _, "postgate_uri" => "at://" <> _} =
               result.structuredContent

      assert AtMcp.Effects.quota_status(ctx.effects).used == 1
    end

    test "a reply cannot set who may reply to the thread", ctx do
      assert {:error, {:invalid_argument, "reply_rule", _}} =
               AtMcp.Effects.reply(
                 ctx.effects,
                 "at://did:plc:x/app.bsky.feed.post/3k22222222222",
                 "t",
                 reply_rule: [:mention]
               )

      refute Map.has_key?(tool_arguments("reply"), :reply_rule)
    end

    test "set_post_interactions refuses another account's post", ctx do
      result =
        call(ctx.state, "set_post_interactions", %{
          "uri" => "at://did:plc:other/app.bsky.feed.post/3k22222222222",
          "quotes" => "disabled"
        })

      assert ["uri"] = problem_paths(result)
      assert hd(result.content).text =~ "did:plc:other is another account"
    end

    test "get_thread with include_hidden reads the replies left out, and why", ctx do
      text =
        text(ctx.state, "get_thread", %{
          "uri" => "at://did:plc:mock/app.bsky.feed.post/3k22222222222",
          "include_hidden" => true
        })

      assert text =~ "Replies under this post left out of the thread: 1."
      assert text =~ "[left out 1] @muted.test"
      assert text =~ "Hidden by the thread's author"

      plain =
        call(ctx.state, "get_thread", %{
          "uri" => "at://did:plc:mock/app.bsky.feed.post/3k22222222222"
        })

      refute Map.has_key?(plain.structuredContent, "hidden_replies")
      refute Enum.find(plain.content, &(&1.type == "text")).text =~ "left out"
    end
  end

  defp tool_arguments(name) do
    {:ok, tools, nil, :state} = AtMcp.MCP.Server.handle_list_tools(nil, :state)
    Enum.find(tools, &(&1.name == name)).inputSchema.properties
  end

  describe "on the wire" do
    setup context do
      Application.put_env(:at_mcp, :network, context[:network] || :bluesky)
      on_exit(fn -> Application.delete_env(:at_mcp, :network) end)
      :ok
    end

    defp pds(records \\ %{}, answers \\ %{}, preferences \\ []) do
      {session, pds} =
        FakePDS.start(records: records, answers: answers, preferences: preferences)

      effects =
        start_supervised!(
          {AtMcp.Effects,
           backend: AtMcp.Effects.ProtoRune,
           backend_state: session,
           write_quota: AtMcp.Test.QuotaFixture.quota(10)},
          id: make_ref()
        )

      %{effects: effects, pds: pds, session: session, state: %{effects: effects}}
    end

    @mine "at://did:plc:self/app.bsky.feed.post/3kmine2222222"
    @threadgate "at://did:plc:self/app.bsky.feed.threadgate/3kmine2222222"
    @postgate "at://did:plc:self/app.bsky.feed.postgate/3kmine2222222"
    @list "at://did:plc:self/app.bsky.graph.list/friends"
    @at "2026-10-01T00:00:00.000Z"

    defp post(text, extra \\ %{}),
      do: Map.merge(%{"$type" => "app.bsky.feed.post", "text" => text, "createdAt" => @at}, extra)

    defp reply_to(root), do: %{"root" => root, "parent" => root}

    defp applied(pds) do
      [apply] = FakePDS.sent(pds, "com.atproto.repo.applyWrites")
      assert Lexicon.problems(apply.body, "com.atproto.repo.applyWrites") == []
      apply.body["writes"]
    end

    defp valid!(record, nsid), do: assert(Lexicon.problems(record, nsid) == [], inspect(record))

    test "a post and its gates are one commit, under one record key" do
      %{effects: effects, pds: pds} = pds()

      assert {:ok, result} =
               AtMcp.Effects.post(effects, "gated",
                 reply_rule: ["mentioned", "followers", @list],
                 quotes: "disabled"
               )

      assert [post, threadgate, postgate] = applied(pds)
      assert FakePDS.sent(pds, "com.atproto.repo.createRecord") == []

      assert Enum.map([post, threadgate, postgate], & &1["collection"]) ==
               ["app.bsky.feed.post", "app.bsky.feed.threadgate", "app.bsky.feed.postgate"]

      assert Enum.all?(
               [post, threadgate, postgate],
               &(&1["$type"] == "com.atproto.repo.applyWrites#create")
             )

      rkey = post["rkey"]
      assert rkey =~ ~r/\A[2-7a-z]{13}\z/
      assert threadgate["rkey"] == rkey and postgate["rkey"] == rkey

      uri = "at://did:plc:self/app.bsky.feed.post/#{rkey}"
      assert threadgate["value"]["post"] == uri
      assert postgate["value"]["post"] == uri
      assert threadgate["value"]["createdAt"] == post["value"]["createdAt"]

      assert threadgate["value"]["allow"] == [
               %{"$type" => "app.bsky.feed.threadgate#mentionRule"},
               %{"$type" => "app.bsky.feed.threadgate#followerRule"},
               %{"$type" => "app.bsky.feed.threadgate#listRule", "list" => @list}
             ]

      assert postgate["value"]["embeddingRules"] == [
               %{"$type" => "app.bsky.feed.postgate#disableRule"}
             ]

      valid!(post["value"], "app.bsky.feed.post")
      valid!(threadgate["value"], "app.bsky.feed.threadgate")
      valid!(postgate["value"], "app.bsky.feed.postgate")

      assert result.uri == uri
      assert result.threadgate_uri == "at://did:plc:self/app.bsky.feed.threadgate/#{rkey}"
      assert result.postgate_uri == "at://did:plc:self/app.bsky.feed.postgate/#{rkey}"
      assert AtMcp.Effects.quota_status(effects).used == 1
    end

    test "reply_rule [] is nobody: the threadgate allows nothing" do
      %{effects: effects, pds: pds} = pds()

      assert {:ok, %{threadgate_uri: "at://" <> _}} =
               AtMcp.Effects.post(effects, "x", reply_rule: [])

      [_post, threadgate] = applied(pds)
      assert threadgate["value"]["allow"] == []
      refute Map.has_key?(threadgate["value"], "hiddenReplies")
      valid!(threadgate["value"], "app.bsky.feed.threadgate")
    end

    # applyWrites' `results` is optional. The writes were committed; the
    # post's address was chosen before sending, so the result still names it.
    test "a post with gates is reported written when the service leaves out results" do
      %{effects: effects, pds: pds} =
        pds(%{}, %{
          "com.atproto.repo.applyWrites" => {200, %{commit: %{cid: "bafycommit", rev: "r"}}}
        })

      assert {:ok, result} = AtMcp.Effects.post(effects, "gated", quotes: "disabled")
      [post, _postgate] = applied(pds)
      rkey = post["rkey"]

      assert result.uri == "at://did:plc:self/app.bsky.feed.post/#{rkey}"
      assert result.cid == nil
      assert result.postgate_uri == "at://did:plc:self/app.bsky.feed.postgate/#{rkey}"
    end

    test "a list named by its handle-form address is written in DID form" do
      by_handle = "at://self.example/app.bsky.graph.list/friends"
      %{effects: effects, pds: pds} = pds(%{@mine => post("mine")})

      assert {:ok, _} = AtMcp.Effects.post(effects, "x", reply_rule: [by_handle])
      [_post, threadgate] = applied(pds)
      assert [%{"list" => @list}] = threadgate["value"]["allow"]

      assert {:ok, %{reply_rule: ["mentioned", @list]}} =
               AtMcp.Effects.set_post_interactions(effects, @mine, ["mentioned", by_handle], nil)

      assert {:error, {:invalid_argument, "reply_rule/0", message}} =
               AtMcp.Effects.set_post_interactions(
                 effects,
                 @mine,
                 ["at://nobody.example/app.bsky.graph.list/x"],
                 nil
               )

      assert message =~ "could not be resolved; give the list's AT URI in DID form"

      # Indexes are the caller's, duplicates included, and one list named
      # both ways is one rule.
      assert {:error, {:invalid_argument, "reply_rule/2", _}} =
               AtMcp.Effects.set_post_interactions(
                 effects,
                 @mine,
                 ["mentioned", "mentioned", "at://nobody.example/app.bsky.graph.list/x"],
                 nil
               )

      assert {:ok, %{reply_rule: [@list]}} =
               AtMcp.Effects.set_post_interactions(effects, @mine, [by_handle, @list], nil)

      assert [%{"list" => @list}] = FakePDS.record(pds, @threadgate)["allow"]
    end

    test "a gate edit writes only over the commit it read, and refuses when the repository moved" do
      %{effects: effects, pds: pds} = pds(%{@mine => post("mine")})

      assert {:ok, _} = AtMcp.Effects.set_post_interactions(effects, @mine, nil, "disabled")
      [apply] = FakePDS.sent(pds, "com.atproto.repo.applyWrites")
      [%{}] = FakePDS.sent(pds, "com.atproto.sync.getLatestCommit")
      assert is_binary(apply.body["swapCommit"])

      # Another write lands between the read and the write.
      %{pds: pds, state: state} =
        pds(%{@mine => post("mine")}, %{
          "com.atproto.sync.getLatestCommit" => {200, %{cid: "bafystale", rev: "1"}}
        })

      {:ok, result, ^state} =
        AtMcp.MCP.Server.handle_call_tool(
          "set_post_interactions",
          %{"uri" => @mine, "quotes" => "disabled"},
          state
        )

      assert result.isError
      assert result.structuredContent.code == "changed_meanwhile"
      assert hd(result.content).text =~ "nothing was written"
      assert FakePDS.record(pds, @postgate) == nil
    end

    # What the app saved as the account's settings for new posts: only
    # people it follows may reply, and nobody may quote.
    @saved [
      %{
        "$type" => "app.bsky.actor.defs#postInteractionSettingsPref",
        "threadgateAllowRules" => [%{"$type" => "app.bsky.feed.threadgate#followingRule"}],
        "postgateEmbeddingRules" => [%{"$type" => "app.bsky.feed.postgate#disableRule"}]
      }
    ]

    test "a post that leaves its rules out takes the account's saved ones, as the app does" do
      %{effects: effects, pds: pds} = pds(%{}, %{}, @saved)
      assert {:ok, result} = AtMcp.Effects.post(effects, "as saved")

      assert [_post, threadgate, postgate] = applied(pds)

      assert threadgate["value"]["allow"] == [
               %{"$type" => "app.bsky.feed.threadgate#followingRule"}
             ]

      assert postgate["value"]["embeddingRules"] == [
               %{"$type" => "app.bsky.feed.postgate#disableRule"}
             ]

      valid!(threadgate["value"], "app.bsky.feed.threadgate")
      valid!(postgate["value"], "app.bsky.feed.postgate")
      assert result.from_saved_settings == ["reply_rule", "quotes"]
      assert AtMcp.Effects.quota_status(effects).used == 1

      # Through the tool, the result says so within its declared schema.
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          result = call(%{effects: effects}, "post", %{"text" => "as saved, by tool"})
          refute result[:isError], hd(result.content).text
          assert result.structuredContent["from_saved_settings"] == ["reply_rule", "quotes"]
        end)

      refute log =~ "unvalidated"
    end

    test "a rule given wins over the saved one, everyone and allowed included" do
      %{effects: effects, pds: pds} = pds(%{}, %{}, @saved)

      assert {:ok, result} =
               AtMcp.Effects.post(effects, "open", reply_rule: ["everyone"], quotes: "allowed")

      assert FakePDS.sent(pds, "com.atproto.repo.applyWrites") == []
      assert [_] = FakePDS.sent(pds, "com.atproto.repo.createRecord")
      refute Map.has_key?(result, :threadgate_uri)
      refute Map.has_key?(result, :from_saved_settings)

      # One rule given, the other taken from what was saved.
      %{effects: effects, pds: pds} = pds(%{}, %{}, @saved)
      assert {:ok, result} = AtMcp.Effects.post(effects, "quotable", quotes: "allowed")
      assert [_post, threadgate] = applied(pds)
      assert threadgate["collection"] == "app.bsky.feed.threadgate"
      assert result.from_saved_settings == ["reply_rule"]
    end

    test "a reply takes the saved quote rule and no reply rule" do
      parent = "at://did:plc:other/app.bsky.feed.post/3kparent22222"
      %{effects: effects, pds: pds} = pds(%{parent => post("theirs")}, %{}, @saved)

      assert {:ok, result} = AtMcp.Effects.reply(effects, parent, "a reply")
      assert [_reply, postgate] = applied(pds)
      assert postgate["collection"] == "app.bsky.feed.postgate"
      assert result.from_saved_settings == ["quotes"]
      refute Map.has_key?(result, :threadgate_uri)
    end

    test "saved settings that cannot be read leave the post unsent and uncounted, quoting the service" do
      unreadable = %{
        "app.bsky.actor.getPreferences" => {500, %{error: "InternalServerError", message: "down"}}
      }

      unknown = [
        %{
          "$type" => "app.bsky.actor.defs#postInteractionSettingsPref",
          "threadgateAllowRules" => [%{"$type" => "app.bsky.feed.threadgate#somedayRule"}]
        }
      ]

      for {answers, preferences, says, advice} <- [
            # The service's answer is its own, quoted; the rest is at_mcp's,
            # and one sentence says what to do.
            {unreadable, [],
             ~s|the account's service answered 500: "down". The account's saved settings for who may reply to and quote a new post could not be read|,
             "Pass reply_rule and quotes to post without the saved settings, or wait a short while and try again."},
            {%{}, unknown,
             ~s|has a rule at_mcp cannot read ("app.bsky.feed.threadgate#somedayRule")|,
             "Pass reply_rule to choose who may reply, and try again."}
          ] do
        %{effects: effects, pds: pds, state: state} = pds(%{}, answers, preferences)
        result = call(state, "post", %{"text" => "x"})
        text = hd(result.content).text

        assert result.isError
        assert result.structuredContent.code == "saved_settings_unreadable"
        assert result.structuredContent.retry == "change_argument"
        assert text =~ says
        assert String.ends_with?(text, advice)
        refute text =~ "Wait about"
        assert FakePDS.sent(pds, "com.atproto.repo.applyWrites") == []
        assert FakePDS.sent(pds, "com.atproto.repo.createRecord") == []
        assert AtMcp.Effects.quota_status(effects).used == 0

        if answers == unreadable,
          do: assert(result.structuredContent.upstream_message == "down")

        # Given both rules, the post needs nothing saved and is sent.
        assert {:ok, _} =
                 AtMcp.Effects.post(effects, "x", reply_rule: ["everyone"], quotes: "allowed")
      end
    end

    test "the saved settings are read once a minute at most, and a change made here applies at once" do
      %{effects: effects, pds: pds, session: session} = pds(%{}, %{}, @saved)
      reads = fn -> length(FakePDS.sent(pds, "app.bsky.actor.getPreferences")) end

      assert {:ok, %{from_saved_settings: ["reply_rule", "quotes"]}} =
               AtMcp.Effects.post(effects, "one")

      assert {:ok, %{from_saved_settings: ["reply_rule", "quotes"]}} =
               AtMcp.Effects.post(effects, "two")

      assert reads.() == 1

      # set_preference writes the preferences, and what it wrote is kept.
      assert {:ok, _} =
               AtMcp.Effects.set_preference(effects, "interaction_defaults", %{
                 reply_rule: ["everyone"],
                 quotes: "allowed"
               })

      before = reads.()
      assert {:ok, open} = AtMcp.Effects.post(effects, "three")
      refute Map.has_key?(open, :from_saved_settings)
      assert reads.() == before

      # Kept longer than a minute, the settings are read again.
      key = {session.did, session.service_url}
      stale = System.monotonic_time(:millisecond) - AtMcp.PostDefaults.ttl_ms() - 1
      true = :ets.update_element(AtMcp.PostDefaults, key, {3, stale})
      assert {:ok, _} = AtMcp.Effects.post(effects, "four")
      assert reads.() == before + 1
    end

    test "a post without gates is written as before, and quotes allowed writes no postgate" do
      %{effects: effects, pds: pds} = pds()
      assert {:ok, result} = AtMcp.Effects.post(effects, "plain", quotes: "allowed")

      assert FakePDS.sent(pds, "com.atproto.repo.applyWrites") == []
      assert [_] = FakePDS.sent(pds, "com.atproto.repo.createRecord")
      refute Map.has_key?(result, :threadgate_uri)
    end

    test "self-labels and a link card beside a quote, with the card's thumbnail uploaded" do
      quoted = "at://did:plc:other/app.bsky.feed.post/3kq2222222222"
      %{effects: effects, pds: pds} = pds(%{quoted => post("quoted")})

      assert {:ok, _} =
               AtMcp.Effects.post(effects, "see",
                 quote: quoted,
                 labels: ["graphic-media", "nudity", "graphic-media"],
                 link: %{
                   url: "https://example.com/a",
                   title: "A page",
                   thumb: %{data: <<1, 2, 3>>, mime_type: "image/png"}
                 }
               )

      [create] = FakePDS.sent(pds, "com.atproto.repo.createRecord")
      record = create.body["record"]

      assert record["labels"] == %{
               "$type" => "com.atproto.label.defs#selfLabels",
               "values" => [%{"val" => "graphic-media"}, %{"val" => "nudity"}]
             }

      assert %{
               "$type" => "app.bsky.embed.recordWithMedia",
               "record" => %{"record" => %{"uri" => ^quoted}},
               "media" => %{
                 "$type" => "app.bsky.embed.external",
                 "external" => %{
                   "uri" => "https://example.com/a",
                   "title" => "A page",
                   "description" => "",
                   "thumb" => %{"$type" => "blob", "mimeType" => "image/png"}
                 }
               }
             } = record["embed"]

      assert [%{body: <<1, 2, 3>>}] = FakePDS.sent(pds, "com.atproto.repo.uploadBlob")
      valid!(record, "app.bsky.feed.post")
    end

    test "through post, reply_rule [] is still nobody, and an empty thumb leaves the card without one" do
      %{pds: pds, state: state} = pds()

      result =
        call(state, "post", %{
          "text" => "see",
          "reply_rule" => [],
          "images" => [],
          "link" => %{
            "url" => "https://example.com/a",
            "title" => "A page",
            "description" => "",
            "thumb" => %{"data" => "", "mimeType" => "", "path" => ""}
          }
        })

      refute result[:isError], hd(result.content).text
      [post, threadgate] = applied(pds)
      assert threadgate["value"]["allow"] == []

      assert post["value"]["embed"] == %{
               "$type" => "app.bsky.embed.external",
               "external" => %{
                 "uri" => "https://example.com/a",
                 "title" => "A page",
                 "description" => ""
               }
             }

      assert FakePDS.sent(pds, "com.atproto.repo.uploadBlob") == []
      valid!(post["value"], "app.bsky.feed.post")
    end

    test "through post, a link card with nothing in it writes a post with no embed" do
      %{pds: pds, state: state} = pds()

      result =
        call(state, "post", %{
          "text" => "plain",
          "link" => %{
            "url" => "",
            "title" => "",
            "description" => "",
            "thumb" => %{"data" => "", "mimeType" => "", "path" => ""}
          }
        })

      refute result[:isError], hd(result.content).text
      [create] = FakePDS.sent(pds, "com.atproto.repo.createRecord")
      refute Map.has_key?(create.body["record"], "embed")
    end

    test "set_post_interactions replaces both rules and keeps hidden replies and createdAt" do
      hidden = "at://did:plc:other/app.bsky.feed.post/3krude2222222"

      %{effects: effects, pds: pds} =
        pds(%{
          @mine => post("mine"),
          @threadgate => %{
            "$type" => "app.bsky.feed.threadgate",
            "post" => @mine,
            "createdAt" => "2026-09-01T00:00:00.000Z",
            "allow" => [%{"$type" => "app.bsky.feed.threadgate#mentionRule"}],
            "hiddenReplies" => [hidden]
          }
        })

      assert {:ok, result} =
               AtMcp.Effects.set_post_interactions(effects, @mine, ["following"], "disabled")

      assert %{threadgate_uri: @threadgate, postgate_uri: @postgate} = result

      assert [update, create] = applied(pds)
      assert update["$type"] == "com.atproto.repo.applyWrites#update"
      assert create["$type"] == "com.atproto.repo.applyWrites#create"

      assert update["value"] == %{
               "$type" => "app.bsky.feed.threadgate",
               "post" => @mine,
               "createdAt" => "2026-09-01T00:00:00.000Z",
               "allow" => [%{"$type" => "app.bsky.feed.threadgate#followingRule"}],
               "hiddenReplies" => [hidden]
             }

      valid!(update["value"], "app.bsky.feed.threadgate")
      valid!(create["value"], "app.bsky.feed.postgate")
    end

    defp gated(allow, embedding_rules) do
      pds(%{
        @mine => post("mine"),
        @threadgate => %{
          "$type" => "app.bsky.feed.threadgate",
          "post" => @mine,
          "createdAt" => @at,
          "allow" => allow
        },
        @postgate => %{
          "$type" => "app.bsky.feed.postgate",
          "post" => @mine,
          "createdAt" => @at,
          "embeddingRules" => embedding_rules
        }
      })
    end

    @following [%{"$type" => "app.bsky.feed.threadgate#followingRule"}]
    @disabled [%{"$type" => "app.bsky.feed.postgate#disableRule"}]

    # The app's dialog starts from the post's current settings, so a rule not
    # given is one the person did not touch.
    test "set_post_interactions keeps a rule it is not given, and says which rules are in force" do
      %{effects: effects, pds: pds} = gated(@following, [])

      assert {:ok, result} = AtMcp.Effects.set_post_interactions(effects, @mine, nil, "disabled")
      assert %{reply_rule: ["following"], quotes: "disabled", unchanged: false} = result
      assert %{threadgate_uri: @threadgate, postgate_uri: @postgate} = result

      # Only the postgate was written; the threadgate is as it was.
      assert [%{"$type" => "com.atproto.repo.applyWrites#update", "collection" => collection}] =
               applied(pds)

      assert collection == "app.bsky.feed.postgate"
      assert FakePDS.record(pds, @threadgate)["allow"] == @following
    end

    test "set_post_interactions with neither rule writes nothing and says so" do
      %{effects: effects, pds: pds} = gated(@following, @disabled)

      assert {:ok, %{unchanged: true, reply_rule: ["following"], quotes: "disabled"}} =
               AtMcp.Effects.set_post_interactions(effects, @mine, nil, nil)

      assert FakePDS.sent(pds, "com.atproto.repo.applyWrites") == []
    end

    test "set_post_interactions opens the post when told everyone and allowed, deleting the gates" do
      %{effects: effects, pds: pds} = gated([], @disabled)

      assert {:ok,
              %{
                threadgate_uri: nil,
                postgate_uri: nil,
                reply_rule: ["everyone"],
                quotes: "allowed"
              }} = AtMcp.Effects.set_post_interactions(effects, @mine, ["everyone"], "allowed")

      assert Enum.map(applied(pds), & &1["$type"]) == [
               "com.atproto.repo.applyWrites#delete",
               "com.atproto.repo.applyWrites#delete"
             ]

      assert FakePDS.record(pds, @threadgate) == nil
    end

    test "a reply takes a quote rule, and a reply rule is refused for it" do
      root = %{
        "uri" => "at://did:plc:other/app.bsky.feed.post/3kroot2222222",
        "cid" => "bafyroot"
      }

      %{effects: effects, pds: pds} =
        pds(%{@mine => post("a reply", %{"reply" => reply_to(root)})})

      for rule <- [["followers"], ["everyone"]] do
        assert {:error, {:invalid_argument, "reply_rule", _}} =
                 AtMcp.Effects.set_post_interactions(effects, @mine, rule, nil)
      end

      assert FakePDS.sent(pds, "com.atproto.repo.applyWrites") == []

      assert {:ok, %{postgate_uri: @postgate, threadgate_uri: nil}} =
               AtMcp.Effects.set_post_interactions(effects, @mine, nil, "disabled")

      assert [%{"collection" => "app.bsky.feed.postgate"}] = applied(pds)
    end

    test "nothing is read or sent for another account's post" do
      %{effects: effects, pds: pds} = pds()

      assert {:error, {:invalid_argument, "uri", _}} =
               AtMcp.Effects.set_post_interactions(
                 effects,
                 "at://did:plc:other/app.bsky.feed.post/3k22222222222",
                 nil,
                 "disabled"
               )

      assert FakePDS.methods(pds) == []
    end

    test "hide_reply adds the reply to the root's threadgate, keeps its rule, and unhide removes it" do
      reply = "at://did:plc:other/app.bsky.feed.post/3kr2222222222"
      root = %{"uri" => @mine, "cid" => "bafymine"}

      %{effects: effects, pds: pds} =
        pds(%{
          @mine => post("root"),
          reply => post("rude", %{"reply" => reply_to(root)}),
          @threadgate => %{
            "$type" => "app.bsky.feed.threadgate",
            "post" => @mine,
            "createdAt" => @at,
            "allow" => [%{"$type" => "app.bsky.feed.threadgate#mentionRule"}]
          }
        })

      assert {:ok,
              %{action: :hide_reply, uri: ^reply, subject_uri: @mine, threadgate_uri: @threadgate}} =
               AtMcp.Effects.hide_reply(effects, reply, true)

      held = FakePDS.record(pds, @threadgate)
      assert held["hiddenReplies"] == [reply]
      assert held["allow"] == [%{"$type" => "app.bsky.feed.threadgate#mentionRule"}]
      valid!(held, "app.bsky.feed.threadgate")

      # Hiding it again changes nothing, so nothing is written.
      assert {:ok, %{unchanged: true}} = AtMcp.Effects.hide_reply(effects, reply, true)
      assert [_] = FakePDS.sent(pds, "com.atproto.repo.applyWrites")

      assert {:ok, %{action: :unhide_reply}} = AtMcp.Effects.hide_reply(effects, reply, false)
      held = FakePDS.record(pds, @threadgate)
      refute Map.has_key?(held, "hiddenReplies")
      assert held["allow"] == [%{"$type" => "app.bsky.feed.threadgate#mentionRule"}]
    end

    test "hiding in a thread with no gate creates one, and unhiding the last reply deletes it" do
      reply = "at://did:plc:other/app.bsky.feed.post/3kr2222222222"
      root = %{"uri" => @mine, "cid" => "bafymine"}

      %{effects: effects, pds: pds} =
        pds(%{@mine => post("root"), reply => post("rude", %{"reply" => reply_to(root)})})

      assert {:ok, _} = AtMcp.Effects.hide_reply(effects, reply, true)

      assert %{"hiddenReplies" => [^reply], "post" => @mine} =
               held = FakePDS.record(pds, @threadgate)

      refute Map.has_key?(held, "allow")
      valid!(held, "app.bsky.feed.threadgate")

      assert {:ok, %{threadgate_uri: nil}} = AtMcp.Effects.hide_reply(effects, reply, false)
      assert FakePDS.record(pds, @threadgate) == nil
    end

    test "hide_reply refuses a reply in another account's thread, and a post that is no reply" do
      theirs = %{
        "uri" => "at://did:plc:other/app.bsky.feed.post/3kroot2222222",
        "cid" => "bafyroot"
      }

      reply = "at://did:plc:third/app.bsky.feed.post/3kr2222222222"

      %{effects: effects, pds: pds} =
        pds(%{reply => post("r", %{"reply" => reply_to(theirs)}), @mine => post("root")})

      assert {:error, {:invalid_argument, "uri", message}} =
               AtMcp.Effects.hide_reply(effects, reply, true)

      assert message =~ "started by did:plc:other"

      assert {:error, {:invalid_argument, "uri", message}} =
               AtMcp.Effects.hide_reply(effects, @mine, true)

      assert message =~ "not a reply"
      assert FakePDS.sent(pds, "com.atproto.repo.applyWrites") == []
    end

    test "detach_quote lists the quoting post on the quoted post's postgate, keeping its rule" do
      quoting = "at://did:plc:other/app.bsky.feed.post/3kq2222222222"

      embed = %{
        "$type" => "app.bsky.embed.recordWithMedia",
        "record" => %{
          "$type" => "app.bsky.embed.record",
          "record" => %{"uri" => @mine, "cid" => "bafymine"}
        },
        "media" => %{"$type" => "app.bsky.embed.images", "images" => []}
      }

      %{effects: effects, pds: pds} =
        pds(%{
          @mine => post("mine"),
          quoting => post("look", %{"embed" => embed}),
          @postgate => %{
            "$type" => "app.bsky.feed.postgate",
            "post" => @mine,
            "createdAt" => @at,
            "embeddingRules" => [%{"$type" => "app.bsky.feed.postgate#disableRule"}]
          }
        })

      assert {:ok,
              %{action: :detach_quote, uri: ^quoting, subject_uri: @mine, postgate_uri: @postgate}} =
               AtMcp.Effects.detach_quote(effects, quoting, true)

      held = FakePDS.record(pds, @postgate)
      assert held["detachedEmbeddingUris"] == [quoting]
      assert held["embeddingRules"] == [%{"$type" => "app.bsky.feed.postgate#disableRule"}]
      valid!(held, "app.bsky.feed.postgate")

      assert {:ok, %{action: :reattach_quote}} =
               AtMcp.Effects.detach_quote(effects, quoting, false)

      refute Map.has_key?(FakePDS.record(pds, @postgate), "detachedEmbeddingUris")
    end

    test "detach_quote refuses a post quoting another account's post, and one quoting nothing" do
      quoting = "at://did:plc:other/app.bsky.feed.post/3kq2222222222"
      plain = "at://did:plc:other/app.bsky.feed.post/3kp2222222222"
      theirs = %{"uri" => "at://did:plc:third/app.bsky.feed.post/3kx2222222222", "cid" => "bafyx"}

      %{effects: effects, pds: pds} =
        pds(%{
          quoting =>
            post("look", %{"embed" => %{"$type" => "app.bsky.embed.record", "record" => theirs}}),
          plain => post("plain")
        })

      assert {:error, {:invalid_argument, "uri", message}} =
               AtMcp.Effects.detach_quote(effects, quoting, true)

      assert message =~ "a post by another account"

      assert {:error, {:invalid_argument, "uri", message}} =
               AtMcp.Effects.detach_quote(effects, plain, true)

      assert message =~ "does not quote a post"
      assert FakePDS.sent(pds, "com.atproto.repo.applyWrites") == []
    end

    @rude "at://did:plc:other/app.bsky.feed.post/3kr2222222222"
    @deep "at://did:plc:other/app.bsky.feed.post/3kdeep2222222"
    @child "at://did:plc:other/app.bsky.feed.post/3kchild222222"
    @tagged "at://did:plc:other/app.bsky.feed.post/3ktagged22222"

    defp view(uri, text),
      do: %{
        uri: uri,
        cid: "bafy" <> text,
        author: %{did: "did:plc:other", handle: "other.example"},
        record: %{text: text, createdAt: "2026-10-01T00:00:00.000Z"}
      }

    # As `unspecced.getPostThreadV2` answers: the post, then its replies depth
    # first, the one the thread's author hid marked so, and the threadgate
    # that lists it beside the thread.
    defp thread do
      %{
        thread: [
          %{
            uri: @mine,
            depth: 0,
            value: %{
              "$type" => "app.bsky.unspecced.defs#threadItemPost",
              post: %{
                uri: @mine,
                cid: "bafymine",
                author: %{did: "did:plc:self", handle: "self.example"},
                record: %{text: "mine", createdAt: "2026-10-01T00:00:00.000Z"}
              },
              hiddenByThreadgate: false,
              mutedByViewer: false,
              moreParents: false,
              moreReplies: 0,
              opThread: true
            }
          },
          put_in(other_item(@rude, "rude", 1, true), [:value, :mutedByViewer], false),
          unflagged_item(@child, "child", 2),
          unflagged_item("at://did:plc:other/app.bsky.feed.post/3kkind2222222", "kind", 1),
          unflagged_item(@tagged, "tagged", 1)
        ],
        hasOtherReplies: true,
        threadgate: %{
          uri: "at://did:plc:self/app.bsky.feed.threadgate/3kmine2222222",
          cid: "bafygate",
          record: %{
            "$type" => "app.bsky.feed.threadgate",
            post: @mine,
            createdAt: "2026-10-01T00:00:00.000Z",
            hiddenReplies: [@rude]
          }
        }
      }
    end

    defp other_item(uri, text, depth, hidden?),
      do: %{
        uri: uri,
        depth: depth,
        value: %{
          "$type" => "app.bsky.unspecced.defs#threadItemPost",
          post: view(uri, text),
          hiddenByThreadgate: hidden?,
          mutedByViewer: not hidden?,
          moreParents: false,
          moreReplies: 0,
          opThread: false
        }
      }

    # A reply left out for a reason the service does not name: a moderation
    # tag, say, or a reply under one it leaves out.
    defp unflagged_item(uri, text, depth) do
      item = other_item(uri, text, depth, false)
      put_in(item, [:value, :mutedByViewer], false)
    end

    test "a reply the thread's author hid is marked where it stands, without include_hidden" do
      %{state: state} = pds(%{}, %{"app.bsky.unspecced.getPostThreadV2" => {200, thread()}})

      result = call(state, "get_thread", %{"uri" => @mine})
      [rude, kind, _tagged] = result.structuredContent["replies"]
      assert rude["hidden_by_threadgate"] == true
      refute kind["hidden_by_threadgate"]
      assert text(state, "get_thread", %{"uri" => @mine}) =~ "Hidden by the thread's author"
    end

    test "get_thread with include_hidden marks the left-out replies it read, and lists the rest once" do
      other = %{
        thread: [
          other_item(@rude, "rude", 1, true),
          unflagged_item(@child, "child", 2),
          other_item(@deep, "deep", 3, false),
          unflagged_item(@tagged, "tagged", 1)
        ]
      }

      %{effects: effects, pds: pds, state: state} =
        pds(%{}, %{
          "app.bsky.unspecced.getPostThreadV2" => {200, thread()},
          "app.bsky.unspecced.getPostThreadOtherV2" => {200, other}
        })

      assert {:ok, %{replies: [rude, kind, tagged], hidden_replies: [deep]}} =
               AtMcp.Effects.get_thread(effects, @mine, include_hidden: true)

      assert %{uri: @rude, left_out: true, hidden_by_threadgate: true, muted_by_viewer: false} =
               rude

      refute Map.get(kind, :left_out)
      assert [%{uri: @child, left_out: true, depth: 2}] = rude.replies
      assert %{uri: @tagged, left_out: true, depth: 1, hidden_by_threadgate: false} = tagged

      assert %{uri: @deep, text: "deep", depth: 3, hidden_by_threadgate: false} = deep
      assert deep.muted_by_viewer == true

      assert [%{query: %{"anchor" => @mine}} | _] =
               FakePDS.sent(pds, "app.bsky.unspecced.getPostThreadOtherV2")

      text =
        text(state, "get_thread", %{"uri" => @mine, "include_hidden" => true})

      # Each reply appears once.
      assert length(String.split(text, "uri: #{@rude}")) == 2
      assert length(String.split(text, "uri: #{@deep}")) == 2
      assert text =~ "each marked where it stands: 3."
      # No reason is claimed where the service named none.
      assert text =~ "Under a reply the app leaves out of the thread"
      assert text =~ "Left out of the thread by the app"
      refute text =~ "this account's settings"
      assert text =~ "Replies under this post left out of the thread: 1."
    end

    @tag network: :delve
    test "a service that does not serve hidden replies leaves the thread and says so; the gates are delve's own" do
      %{effects: effects, pds: pds, state: state} =
        pds(%{}, %{
          "town.delve.unspecced.getPostThreadV2" => {200, thread()},
          "town.delve.unspecced.getPostThreadOtherV2" =>
            {501, %{error: "MethodNotImplemented", message: "Method Not Implemented"}}
        })

      # The thread read is kept; only the left-out replies are missing, and
      # the result says so in one line.
      result = call(state, "get_thread", %{"uri" => @mine, "include_hidden" => true})
      refute result[:isError]
      assert [_, _, _] = result.structuredContent["replies"]
      refute Map.has_key?(result.structuredContent, "hidden_replies")
      text = text(state, "get_thread", %{"uri" => @mine, "include_hidden" => true})
      assert text =~ "[this post]"

      assert text =~
               "The replies this thread leaves out could not be read: the account's service does not serve them (it answered 501)."

      assert {:ok, _} =
               AtMcp.Effects.post(effects, "x", reply_rule: ["mentioned"], quotes: "disabled")

      [post, threadgate, postgate] = applied(pds)
      assert post["collection"] == "town.delve.feed.post"
      assert threadgate["value"]["$type"] == "town.delve.feed.threadgate"

      assert [%{"$type" => "town.delve.feed.threadgate#mentionRule"}] =
               threadgate["value"]["allow"]

      assert [%{"$type" => "town.delve.feed.postgate#disableRule"}] =
               postgate["value"]["embeddingRules"]

      valid!(threadgate["value"], "app.bsky.feed.threadgate")
      valid!(postgate["value"], "app.bsky.feed.postgate")
    end
  end
end
