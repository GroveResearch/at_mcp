defmodule AtMcp.WriteRecordsTest do
  @moduledoc """
  AtMcp builds the records it writes, and these check the bytes it sends.

  A builder returning the right map proves nothing about the request that
  leaves the machine, so every assertion here reads the body a fake PDS
  received. Each one is written to fail for a named defect: a collection or
  `$type` frozen at `app.bsky`, an embed dropped by a validator that does not
  declare it, a language nobody asked for, a facet type left behind by the
  upstream rich-text builder, or a delete aimed at the configured network
  rather than at the network the record is actually on.
  """
  use ExUnit.Case, async: false

  defmodule PDS do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      conn = fetch_query_params(conn)
      {:ok, raw, conn} = read_body(conn)

      body =
        case get_req_header(conn, "content-type") do
          ["image/" <> _] -> raw
          _ -> if raw == "", do: nil, else: Jason.decode!(raw)
        end

      "/xrpc/" <> method = conn.request_path

      Agent.update(
        opts[:calls],
        &(&1 ++ [%{method: method, query: conn.query_params, body: body}])
      )

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(response(method, conn)))
    end

    defp response("com.atproto.repo.createRecord", _conn),
      do: %{uri: "at://did:plc:self/c/new", cid: "bafyreinew"}

    defp response("com.atproto.repo.putRecord", _conn),
      do: %{uri: "at://did:plc:self/c/self", cid: "bafyreiself"}

    defp response("com.atproto.repo.getRecord", conn) do
      %{
        uri: "at://#{conn.query_params["repo"]}/#{conn.query_params["collection"]}/x",
        cid: "bafyreiparent",
        value: %{text: "parent", displayName: "Old name", pinnedPost: "at://kept"}
      }
    end

    defp response("com.atproto.repo.uploadBlob", _conn),
      do: %{
        blob: %{
          "$type": "blob",
          ref: %{"$link": "bafkreiblob"},
          mimeType: "image/png",
          size: 3
        }
      }

    defp response("com.atproto.identity.resolveHandle", _conn), do: %{did: "did:plc:other"}
    defp response(_method, _conn), do: %{}
  end

  setup context do
    Application.put_env(:at_mcp, :network, context[:network] || :delve)
    on_exit(fn -> Application.delete_env(:at_mcp, :network) end)

    calls = start_supervised!({Agent, fn -> [] end})
    ref = :"write_records_#{System.unique_integer([:positive])}"

    start_supervised!(
      Plug.Cowboy.child_spec(
        scheme: :http,
        plug: {PDS, calls: calls},
        options: [port: 0, ip: {127, 0, 0, 1}, ref: ref]
      )
    )

    session = %ProtoRune.Atproto.Session{
      access_jwt: "access",
      refresh_jwt: "refresh",
      did: "did:plc:self",
      handle: "self.example",
      service_url: "http://127.0.0.1:#{:ranch.get_port(ref)}/xrpc"
    }

    %{calls: calls, session: session}
  end

  defp sent(calls, method) do
    calls |> Agent.get(& &1) |> Enum.filter(&(&1.method == method))
  end

  defp written(calls), do: calls |> sent("com.atproto.repo.createRecord") |> List.last()

  test "punctuation-only hashtags can be replied with without an unknown outcome", ctx do
    effects = post_effects(ctx.session)
    text = "[[ ## completed ##]]"

    assert {:ok, _} =
             AtMcp.Effects.reply(effects, "at://did:plc:other/town.delve.feed.post/1", text)

    assert written(ctx.calls).body["record"]["text"] == text
    refute Map.has_key?(written(ctx.calls).body["record"], "facets")
    assert AtMcp.Effects.quota_status(effects).used == 1
  end

  test "a record that cannot be built is refused before dispatch and costs no quota", ctx do
    effects = post_effects(ctx.session)
    # Malformed resolved reference reaches the record builder, independently
    # of the hashtag detector. No createRecord may have happened here.
    assert {:error, %AtMcp.Effects.Failure{kind: :refused}} =
             AtMcp.Effects.post(effects, "not sent", reply_ref: :invalid, quote_ref: nil)

    assert sent(ctx.calls, "com.atproto.repo.createRecord") == []
    assert AtMcp.Effects.quota_status(effects).used == 0
  end

  defp post_effects(session) do
    start_supervised!(
      {AtMcp.Effects,
       backend: AtMcp.Effects.ProtoRune,
       backend_state: session,
       write_quota: AtMcp.Test.QuotaFixture.quota(10)}
    )
  end

  describe "the collection and the $type" do
    test "a post is written to the configured network, not to app.bsky", %{
      calls: calls,
      session: session
    } do
      assert {:ok, _} = AtMcp.Effects.ProtoRune.post(session, "hello")

      write = written(calls)
      assert write.body["collection"] == "town.delve.feed.post"
      assert write.body["record"]["$type"] == "town.delve.feed.post"
      assert write.body["repo"] == "did:plc:self"
    end

    @tag network: :bluesky
    test "and by default to app.bsky, exactly as before", %{calls: calls, session: session} do
      assert {:ok, _} = AtMcp.Effects.ProtoRune.post(session, "hello")

      write = written(calls)
      assert write.body["collection"] == "app.bsky.feed.post"
      assert write.body["record"]["$type"] == "app.bsky.feed.post"
    end

    # Every record-creating verb, named one by one, because a single one left
    # on the library's helper is exactly the defect that would survive a spot
    # check of `post`.
    test "every record AtMcp creates carries the configured network's collection", %{
      calls: calls,
      session: session
    } do
      subject = "at://did:plc:other/town.delve.feed.post/1"

      assert {:ok, _} = AtMcp.Effects.ProtoRune.post(session, "hello")
      assert {:ok, _} = AtMcp.Effects.ProtoRune.like(session, subject, "bafyreisubject")
      assert {:ok, _} = AtMcp.Effects.ProtoRune.repost(session, subject, "bafyreisubject")
      assert {:ok, _} = AtMcp.Effects.ProtoRune.follow(session, "did:plc:other")
      assert {:ok, _} = AtMcp.Effects.ProtoRune.block(session, "did:plc:other")

      writes = sent(calls, "com.atproto.repo.createRecord")

      assert Enum.map(writes, & &1.body["collection"]) == [
               "town.delve.feed.post",
               "town.delve.feed.like",
               "town.delve.feed.repost",
               "town.delve.graph.follow",
               "town.delve.graph.block"
             ]

      # A record whose `$type` disagrees with the collection it is written to is
      # a record the service will reject, and the two come from one place.
      for write <- writes, do: assert(write.body["record"]["$type"] == write.body["collection"])
    end

    test "a mute is the namespaced method, because it is not a record", %{
      calls: calls,
      session: session
    } do
      assert {:ok, _} = AtMcp.Effects.ProtoRune.mute(session, "did:plc:other")
      assert {:ok, _} = AtMcp.Effects.ProtoRune.unmute(session, "did:plc:other")

      assert calls |> Agent.get(& &1) |> Enum.map(& &1.method) == [
               "town.delve.graph.muteActor",
               "town.delve.graph.unmuteActor"
             ]
    end

    # The collection a delete names belongs to the record, not to the
    # installation: an account that posted on one network and was reconfigured
    # must still be able to delete what it wrote.
    test "a delete uses the collection in the URI it was given", %{
      calls: calls,
      session: session
    } do
      uri = "at://did:plc:self/app.bsky.feed.post/abc"
      assert {:ok, %{action: :delete_post}} = AtMcp.Effects.ProtoRune.delete_post(session, uri)

      deleted = calls |> sent("com.atproto.repo.deleteRecord") |> List.last()
      assert deleted.body["collection"] == "app.bsky.feed.post"
      assert deleted.body["rkey"] == "abc"
      assert deleted.body["repo"] == "did:plc:self"
    end

    @deletions [
      delete_post: "feed.post",
      unlike: "feed.like",
      unrepost: "feed.repost",
      unfollow: "graph.follow",
      unblock: "graph.block"
    ]

    for {action, suffix} <- @deletions do
      test "#{action} refuses every other record kind before HTTP, including through MCP", ctx do
        action = unquote(action)
        suffix = unquote(suffix)
        effects = post_effects(ctx.session)
        state = %{effects: effects}

        wrong_collections =
          for namespace <- ["app.bsky", "town.delve"],
              {_other_action, other_suffix} <- @deletions,
              other_suffix != suffix,
              do: namespace <> "." <> other_suffix

        for collection <- wrong_collections ++ ["evil.example." <> suffix] do
          uri = "at://did:plc:self/#{collection}/abc"

          assert {:ok, result, ^state} =
                   AtMcp.MCP.Server.handle_call_tool(
                     Atom.to_string(action),
                     %{"uri" => uri},
                     state
                   )

          assert result[:isError]

          assert {:error, %AtMcp.Effects.Failure{kind: :refused, message: message}} =
                   apply(AtMcp.Effects.ProtoRune, action, [ctx.session, uri])

          assert message =~ "record"
          assert result.structuredContent == %{code: "wrong_record_kind"}
          assert Enum.find(result.content, &(&1.type == "text")).text == message
          assert message =~ "nothing was sent"
          refute Enum.find(result.content, &(&1.type == "text")).text =~ "may have completed"

          refute Map.has_key?(result.structuredContent, :outcome)
          assert Agent.get(ctx.calls, & &1) == []
          assert AtMcp.Effects.quota_status(effects).used == 0
        end
      end

      test "#{action} retains both supported networks and handle repository references", ctx do
        for configured <- [:bluesky, :delve],
            namespace <- ["app.bsky", "town.delve"],
            repo <- ["did:plc:self", "self.example"] do
          Application.put_env(:at_mcp, :network, configured)
          collection = namespace <> "." <> unquote(suffix)
          uri = "at://#{repo}/#{collection}/abc"
          action = unquote(action)

          assert {:ok, %{action: ^action, uri: ^uri}} =
                   apply(AtMcp.Effects.ProtoRune, action, [ctx.session, uri])

          deleted = ctx.calls |> sent("com.atproto.repo.deleteRecord") |> List.last()
          assert deleted.body == %{"collection" => collection, "repo" => repo, "rkey" => "abc"}
        end
      end

      test "#{action} refuses malformed references without HTTP", ctx do
        for uri <- ["not-a-uri", "at://", "at://did:plc:self", "at://did:plc:self/c/"] do
          assert {:error, %AtMcp.Effects.Failure{kind: :refused}} =
                   apply(AtMcp.Effects.ProtoRune, unquote(action), [ctx.session, uri])
        end

        assert Agent.get(ctx.calls, & &1) == []
      end
    end

    test "a malformed AT URI is refused before anything is sent", %{
      calls: calls,
      session: session
    } do
      assert {:error, %AtMcp.Effects.Failure{kind: :refused}} =
               AtMcp.Effects.ProtoRune.unlike(session, "not-a-uri")

      assert Agent.get(calls, & &1) == []
    end
  end

  describe "the embed" do
    # The library validates the record through a Peri schema with no `embed`
    # key, and Peri drops what it does not declare without reporting it, so a
    # record built there can carry no media at all.
    test "images reach the wire, with their alt text and blob reference", %{
      calls: calls,
      session: session
    } do
      assert {:ok, _} =
               AtMcp.Effects.ProtoRune.post(session, "a picture",
                 images: [%{data: <<1, 2, 3>>, mime_type: "image/png", alt: "a at_mcp"}]
               )

      embed = written(calls).body["record"]["embed"]

      assert embed["$type"] == "town.delve.embed.images"
      assert [image] = embed["images"]
      assert image["alt"] == "a at_mcp"

      # The blob reference goes back out as the service gave it, including the
      # `mimeType` the XRPC client snakelizes on the way in.
      assert image["image"] == %{
               "$type" => "blob",
               "ref" => %{"$link" => "bafkreiblob"},
               "mimeType" => "image/png",
               "size" => 3
             }

      assert [upload] = sent(calls, "com.atproto.repo.uploadBlob")
      assert upload.body == <<1, 2, 3>>
    end

    test "a quote carries a strong reference read off the quoted record", %{
      calls: calls,
      session: session
    } do
      uri = "at://did:plc:other/town.delve.feed.post/1"
      assert {:ok, _} = AtMcp.Effects.ProtoRune.post(session, "see this", quote: uri)

      embed = written(calls).body["record"]["embed"]

      assert embed["$type"] == "town.delve.embed.record"
      assert embed["record"] == %{"uri" => uri, "cid" => "bafyreiparent"}
    end

    # The lexicon's answer to "both" is a third type rather than two keys.
    test "images and a quote together become one recordWithMedia", %{
      calls: calls,
      session: session
    } do
      assert {:ok, _} =
               AtMcp.Effects.ProtoRune.post(session, "both",
                 quote: "at://did:plc:other/town.delve.feed.post/1",
                 images: [%{data: <<1>>, mime_type: "image/png", alt: ""}]
               )

      embed = written(calls).body["record"]["embed"]

      assert embed["$type"] == "town.delve.embed.recordWithMedia"
      assert embed["record"]["$type"] == "town.delve.embed.record"
      assert embed["media"]["$type"] == "town.delve.embed.images"
    end

    test "a post with neither carries no embed key at all", %{calls: calls, session: session} do
      assert {:ok, _} = AtMcp.Effects.ProtoRune.post(session, "plain")
      refute Map.has_key?(written(calls).body["record"], "embed")
    end
  end

  describe "the language" do
    # `ProtoRune.Bsky.post/3` stamps `langs: ["en"]` on every record, so a post
    # written through it claims to be English whatever it is. A record that says
    # nothing about its language is the honest one.
    test "is absent unless a caller said one", %{calls: calls, session: session} do
      assert {:ok, _} = AtMcp.Effects.ProtoRune.post(session, "sin marcar")

      record = written(calls).body["record"]
      refute Map.has_key?(record, "langs")
    end

    test "is written when a caller does say one", %{calls: calls, session: session} do
      assert {:ok, _} = AtMcp.Effects.ProtoRune.post(session, "hola", langs: ["es"])

      assert written(calls).body["record"]["langs"] == ["es"]
    end
  end

  describe "the facets" do
    # The upstream builder writes `app.bsky.richtext.facet#link` and `#tag` into
    # the facet the same way its mention builder does, so every facet AtMcp
    # writes is built over `AtMcp.Network` instead.
    test "every facet type AtMcp writes is the configured network's", %{
      calls: calls,
      session: session
    } do
      text = "@self.example https://example.com #at_mcp"
      assert {:ok, _} = AtMcp.Effects.ProtoRune.post(session, text)

      types =
        written(calls).body["record"]["facets"]
        |> Enum.flat_map(& &1["features"])
        |> Enum.map(& &1["$type"])

      assert types == [
               "town.delve.richtext.facet#mention",
               "town.delve.richtext.facet#link",
               "town.delve.richtext.facet#tag"
             ]
    end

    test "carry the wire's own key names and byte offsets", %{calls: calls, session: session} do
      assert {:ok, _} = AtMcp.Effects.ProtoRune.post(session, "hi #at_mcp")

      assert [facet] = written(calls).body["record"]["facets"]
      assert facet["index"] == %{"byteStart" => 3, "byteEnd" => 10}

      assert [built] =
               AtMcp.ATProto.post_record(text: "hi #at_mcp", facets: at_mcp_facets())["facets"]

      assert built["index"] == %{"byteStart" => 3, "byteEnd" => 10}
    end

    defp at_mcp_facets do
      {rich_text, []} = AtMcp.RichText.build("hi #at_mcp", nil)
      rich_text.facets
    end
  end

  # The XRPC client camelizes every key in a body it is given, so a record built
  # in snake_case would only become correct downstream — and a test could not
  # read it back off the builder. Records leave the builder in the wire's own
  # spelling, and the client's pass over them is an identity.
  test "no key in a record AtMcp sends was spelled for the client to rewrite", %{
    calls: calls,
    session: session
  } do
    assert {:ok, _} =
             AtMcp.Effects.ProtoRune.post(session, "hi @self.example #at_mcp",
               images: [%{data: <<1>>, mime_type: "image/png", alt: "a"}],
               langs: ["en"]
             )

    assert snake_cased_keys(written(calls).body["record"]) == []

    # And in the record as built, which is where it has to be true: the client's
    # camelization would hide a snake_case key from the wire assertion above.
    built =
      AtMcp.ATProto.post_record(
        text: "hi #at_mcp",
        facets: at_mcp_facets(),
        images: [
          %{blob: %{"$type": "blob", ref: %{"$link": "b"}, mime_type: "image/png", size: 1}}
        ]
      )

    assert snake_cased_keys(built) == []
  end

  defp snake_cased_keys(map) when is_map(map) do
    Enum.flat_map(map, fn {key, value} ->
      if String.contains?(key, "_"), do: [key], else: snake_cased_keys(value)
    end)
  end

  defp snake_cased_keys(list) when is_list(list), do: Enum.flat_map(list, &snake_cased_keys/1)
  defp snake_cased_keys(_other), do: []

  describe "a reply" do
    test "retains the parent's root and both strong references", %{
      calls: calls,
      session: session
    } do
      parent = "at://did:plc:other/town.delve.feed.post/1"
      assert {:ok, result} = AtMcp.Effects.ProtoRune.post(session, "agreed", reply: parent)

      assert result.reply_to == parent

      # The fake parent is not itself a reply, so it is its own root.
      assert written(calls).body["record"]["reply"] == %{
               "root" => %{"uri" => parent, "cid" => "bafyreiparent"},
               "parent" => %{"uri" => parent, "cid" => "bafyreiparent"}
             }
    end
  end

  describe "the tool surface" do
    # A record can only carry an image if an agent has some way to hand AtMcp
    # bytes, and JSON-RPC carries bytes as base64 or not at all.
    test "an agent's base64 image reaches the record as bytes", %{
      calls: calls,
      session: session
    } do
      assert {:ok, opts} =
               AtMcp.MCP.Tools.post_options(%{
                 images: [
                   %{
                     "data" => Base.encode64(<<7, 8, 9>>),
                     "mime_type" => "image/png",
                     "alt" => "a"
                   }
                 ],
                 langs: ["es"],
                 quote: nil
               })

      assert {:ok, _} = AtMcp.Effects.ProtoRune.post(session, "mira", opts)

      assert [upload] = sent(calls, "com.atproto.repo.uploadBlob")
      assert upload.body == <<7, 8, 9>>
      assert written(calls).body["record"]["langs"] == ["es"]
      assert [%{"alt" => "a"}] = written(calls).body["record"]["embed"]["images"]
    end

    # An optional a caller filled in with nothing is one it did not fill in. A
    # model that sends `quote: ""` would otherwise reach the record builder, and
    # the service refuses the whole post: an empty string is not an AT URI.
    test "an optional filled in with nothing is absent, not a value" do
      for empty <- [nil, "", "   "] do
        assert {:ok, opts} = AtMcp.MCP.Tools.post_options(%{text: "hallo", quote: empty})
        refute Keyword.has_key?(opts, :quote), "quote: #{inspect(empty)} became a value"
      end

      for empty <- [nil, []] do
        assert {:ok, opts} = AtMcp.MCP.Tools.post_options(%{text: "hallo", langs: empty})
        refute Keyword.has_key?(opts, :langs), "langs: #{inspect(empty)} became a value"
      end

      # A real value still arrives.
      assert {:ok, opts} =
               AtMcp.MCP.Tools.post_options(%{
                 text: "hallo",
                 quote: "at://did:plc:x/app.bsky.feed.post/1",
                 langs: ["en"]
               })

      assert opts[:quote] == "at://did:plc:x/app.bsky.feed.post/1"
      assert opts[:langs] == ["en"]
    end

    # Refused before the write quota is charged, because nothing was sent.
    test "an image that is not base64 is refused, and nothing is sent", %{calls: calls} do
      assert {:error, :invalid_image} =
               AtMcp.MCP.Tools.post_options(%{
                 images: [%{"data" => "not base64!", "mime_type" => "image/png", "alt" => "a"}]
               })

      assert {:error, :invalid_image} =
               AtMcp.MCP.Tools.post_options(%{images: [%{"data" => Base.encode64("x")}]})

      assert Agent.get(calls, & &1) == []
    end

    test "post and reply both offer what a post record can carry" do
      {:ok, tools, nil, :state} = AtMcp.MCP.Server.handle_list_tools(nil, :state)

      for name <- ["post", "reply"] do
        tool = Enum.find(tools, &(&1.name == name))
        properties = tool.inputSchema.properties

        for field <- [:text, :images, :quote, :langs],
            do: assert(Map.has_key?(properties, field), "#{name} does not offer #{field}")
      end
    end
  end

  describe "a profile update" do
    test "writes the network's profile collection and keeps fields nobody mentioned", %{
      calls: calls,
      session: session
    } do
      assert {:ok, _} = AtMcp.Effects.ProtoRune.update_profile(session, display_name: "New name")

      written = calls |> sent("com.atproto.repo.putRecord") |> List.last()

      assert written.body["collection"] == "town.delve.actor.profile"
      assert written.body["rkey"] == "self"
      assert written.body["record"]["$type"] == "town.delve.actor.profile"
      assert written.body["record"]["displayName"] == "New name"

      # Read back snakelized, written out camelCase: a field that survives a
      # round trip as `display_name` is a field the lexicon does not define.
      refute Map.has_key?(written.body["record"], "display_name")
      assert written.body["record"]["pinnedPost"] == "at://kept"
    end
  end
end
