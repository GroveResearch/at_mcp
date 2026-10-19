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

  defp call(state, name, arguments) do
    {:ok, result, ^state} = AtMcp.MCP.Server.handle_call_tool(name, arguments, state)
    result
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
            {["everyone"], "reply_rule/0"},
            {["mentioned", generator], "reply_rule/1"}
          ] do
        result = call(ctx.state, "post", %{"text" => "t", "reply_rule" => rule})
        assert result.isError
        assert problem_paths(result) == [path]
        assert hd(result.content).text =~ "Nothing was sent"
      end

      assert AtMcp.Effects.quota_status(ctx.effects).used == 0
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
               AtMcp.Effects.reply(ctx.effects, "at://did:plc:x/app.bsky.feed.post/1", "t",
                 reply_rule: [:mention]
               )

      refute Map.has_key?(tool_arguments("reply"), :reply_rule)
    end

    test "set_post_interactions refuses another account's post", ctx do
      result =
        call(ctx.state, "set_post_interactions", %{
          "uri" => "at://did:plc:other/app.bsky.feed.post/1",
          "quotes" => "disabled"
        })

      assert ["uri"] = problem_paths(result)
      assert hd(result.content).text =~ "did:plc:other is another account"
    end

    test "get_thread with include_hidden reads the replies left out, and why", ctx do
      result =
        call(ctx.state, "get_thread", %{
          "uri" => "at://did:plc:mock/app.bsky.feed.post/1",
          "include_hidden" => true
        })

      text = Enum.find(result.content, &(&1.type == "text")).text
      assert text =~ "Replies under this post left out of the thread: 1."
      assert text =~ "[left out 1] @muted.test"
      assert text =~ "Hidden by the thread's author"

      plain = call(ctx.state, "get_thread", %{"uri" => "at://did:plc:mock/app.bsky.feed.post/1"})
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

    defp pds(records \\ %{}, answers \\ %{}) do
      {session, pds} = FakePDS.start(records: records, answers: answers)

      effects =
        start_supervised!(
          {AtMcp.Effects,
           backend: AtMcp.Effects.ProtoRune,
           backend_state: session,
           write_quota: AtMcp.Test.QuotaFixture.quota(10)},
          id: make_ref()
        )

      %{effects: effects, pds: pds, state: %{effects: effects}}
    end

    @mine "at://did:plc:self/app.bsky.feed.post/mine"
    @threadgate "at://did:plc:self/app.bsky.feed.threadgate/mine"
    @postgate "at://did:plc:self/app.bsky.feed.postgate/mine"
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

    test "a post without gates is written as before, and quotes allowed writes no postgate" do
      %{effects: effects, pds: pds} = pds()
      assert {:ok, result} = AtMcp.Effects.post(effects, "plain", quotes: "allowed")

      assert FakePDS.sent(pds, "com.atproto.repo.applyWrites") == []
      assert [_] = FakePDS.sent(pds, "com.atproto.repo.createRecord")
      refute Map.has_key?(result, :threadgate_uri)
    end

    test "self-labels and a link card beside a quote, with the card's thumbnail uploaded" do
      quoted = "at://did:plc:other/app.bsky.feed.post/q"
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

    test "set_post_interactions replaces both rules and keeps hidden replies and createdAt" do
      hidden = "at://did:plc:other/app.bsky.feed.post/rude"

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

    test "set_post_interactions with neither rule opens the post and deletes empty gates" do
      %{effects: effects, pds: pds} =
        pds(%{
          @mine => post("mine"),
          @threadgate => %{
            "$type" => "app.bsky.feed.threadgate",
            "post" => @mine,
            "createdAt" => @at,
            "allow" => []
          },
          @postgate => %{
            "$type" => "app.bsky.feed.postgate",
            "post" => @mine,
            "createdAt" => @at,
            "embeddingRules" => [%{"$type" => "app.bsky.feed.postgate#disableRule"}]
          }
        })

      assert {:ok, %{threadgate_uri: nil, postgate_uri: nil}} =
               AtMcp.Effects.set_post_interactions(effects, @mine, nil, nil)

      assert Enum.map(applied(pds), & &1["$type"]) == [
               "com.atproto.repo.applyWrites#delete",
               "com.atproto.repo.applyWrites#delete"
             ]

      assert FakePDS.record(pds, @threadgate) == nil
    end

    test "a reply takes a quote rule, and a reply rule is refused for it" do
      root = %{"uri" => "at://did:plc:other/app.bsky.feed.post/root", "cid" => "bafyroot"}

      %{effects: effects, pds: pds} =
        pds(%{@mine => post("a reply", %{"reply" => reply_to(root)})})

      assert {:error, {:invalid_argument, "reply_rule", _}} =
               AtMcp.Effects.set_post_interactions(effects, @mine, ["followers"], nil)

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
                 "at://did:plc:other/app.bsky.feed.post/1",
                 nil,
                 "disabled"
               )

      assert FakePDS.methods(pds) == []
    end

    test "hide_reply adds the reply to the root's threadgate, keeps its rule, and unhide removes it" do
      reply = "at://did:plc:other/app.bsky.feed.post/r"
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

      assert {:ok, %{action: :unhide_reply}} = AtMcp.Effects.hide_reply(effects, reply, false)
      held = FakePDS.record(pds, @threadgate)
      refute Map.has_key?(held, "hiddenReplies")
      assert held["allow"] == [%{"$type" => "app.bsky.feed.threadgate#mentionRule"}]
    end

    test "hiding in a thread with no gate creates one, and unhiding the last reply deletes it" do
      reply = "at://did:plc:other/app.bsky.feed.post/r"
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
      theirs = %{"uri" => "at://did:plc:other/app.bsky.feed.post/root", "cid" => "bafyroot"}
      reply = "at://did:plc:third/app.bsky.feed.post/r"

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
      quoting = "at://did:plc:other/app.bsky.feed.post/q"

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
      quoting = "at://did:plc:other/app.bsky.feed.post/q"
      plain = "at://did:plc:other/app.bsky.feed.post/p"
      theirs = %{"uri" => "at://did:plc:third/app.bsky.feed.post/x", "cid" => "bafyx"}

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

    @thread %{
      thread: %{
        "$type" => "app.bsky.feed.defs#threadViewPost",
        post: %{
          uri: "at://did:plc:self/app.bsky.feed.post/mine",
          cid: "bafymine",
          author: %{did: "did:plc:self", handle: "self.example"},
          record: %{text: "mine", createdAt: "2026-10-01T00:00:00.000Z"}
        },
        replies: []
      }
    }

    test "get_thread with include_hidden reads the replies the thread leaves out" do
      other = %{
        thread: [
          %{
            uri: "at://did:plc:other/app.bsky.feed.post/r",
            depth: 1,
            value: %{
              "$type" => "app.bsky.unspecced.defs#threadItemPost",
              post: %{
                uri: "at://did:plc:other/app.bsky.feed.post/r",
                cid: "bafyr",
                author: %{did: "did:plc:other", handle: "other.example"},
                record: %{text: "rude", createdAt: "2026-10-01T00:00:00.000Z"}
              },
              hiddenByThreadgate: true,
              mutedByViewer: false,
              moreParents: false,
              moreReplies: 0,
              opThread: false
            }
          }
        ]
      }

      %{effects: effects, pds: pds} =
        pds(%{}, %{
          "app.bsky.feed.getPostThread" => {200, @thread},
          "app.bsky.unspecced.getPostThreadOtherV2" => {200, other}
        })

      assert {:ok, %{hidden_replies: [hidden]}} =
               AtMcp.Effects.get_thread(effects, @mine, include_hidden: true)

      assert %{text: "rude", author: "other.example", depth: 1, hidden_by_threadgate: true} =
               hidden

      assert hidden.muted_by_viewer == false

      assert [%{query: %{"anchor" => @mine}}] =
               FakePDS.sent(pds, "app.bsky.unspecced.getPostThreadOtherV2")
    end

    @tag network: :delve
    test "a service that does not serve hidden replies says so, and the gates are delve's own" do
      %{effects: effects, pds: pds, state: state} =
        pds(%{}, %{
          "town.delve.feed.getPostThread" => {200, @thread},
          "town.delve.unspecced.getPostThreadOtherV2" =>
            {501, %{error: "MethodNotImplemented", message: "Method Not Implemented"}}
        })

      result = call(state, "get_thread", %{"uri" => @mine, "include_hidden" => true})
      assert result.structuredContent.code == "upstream_not_implemented"

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
