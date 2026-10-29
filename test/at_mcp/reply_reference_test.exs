defmodule AtMcp.ReplyReferenceTest do
  @moduledoc """
  A reply names a parent, and a reply record cannot be built without reading
  that parent: the strong reference carries a CID the URI does not. So the read
  can fail after the account's write quota has been charged on a write that
  never left the machine.

  These check the two halves of that: an unreadable reference costs nothing and
  says which record could not be read, and a reply that is actually sent still
  takes exactly one slot.

  They also check what the refusal is allowed to claim. "The record may be
  deleted" is a statement about the record, and only a service that answered
  about that record supports it; an outage supports nothing of the kind.
  """
  use ExUnit.Case, async: false

  @readable "at://did:plc:other/app.bsky.feed.post/3kreadable222"
  @gone "at://did:plc:other/app.bsky.feed.post/3kgonegone222"
  @broken "at://did:plc:other/app.bsky.feed.post/3kbroken22222"
  @no_repo "at://did:plc:nobody/app.bsky.feed.post/3knorepo22222"
  @japanese "at://did:plc:other/app.bsky.feed.post/3kjapanese222"

  # A post's key with two characters dropped: 11 characters, where a post's
  # key is a TID of 13. The service answers it as it answers any key it does
  # not hold.
  @short_key "3myrzn2372g"
  @short "at://did:plc:other/app.bsky.feed.post/#{@short_key}"

  defmodule PDS do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      conn = fetch_query_params(conn)
      {:ok, raw, conn} = read_body(conn)
      body = if raw == "", do: nil, else: Jason.decode!(raw)
      "/xrpc/" <> method = conn.request_path

      Agent.update(
        opts[:calls],
        &(&1 ++ [%{method: method, query: conn.query_params, body: body}])
      )

      {status, response} = response(method, conn)

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(response))
    end

    # The shape a PDS answers with for a record that is not there: a 400 with
    # an error name, not a 200 with an empty body.
    defp response("com.atproto.repo.getRecord", conn) do
      case conn.query_params["rkey"] do
        rkey when rkey in ["3kgonegone222", "3myrzn2372g"] ->
          {400, %{error: "RecordNotFound", message: "Could not locate record"}}

        # The AppView's answer for a repository it does not know.
        "3knorepo22222" ->
          {400, %{error: "InvalidRequest", message: "Could not find repo: did:plc:nobody"}}

        # The service is having a bad day. The record it was asked about may be
        # perfectly fine.
        "3kbroken22222" ->
          {500, %{error: "InternalServerError", message: "upstream is down"}}

        # A parent its author tagged as Japanese.
        "3kjapanese222" ->
          {200,
           %{
             uri: "at://did:plc:other/app.bsky.feed.post/3kjapanese222",
             cid: "bafyreijapanese",
             value: %{text: "こんにちは", langs: ["ja"]}
           }}

        rkey ->
          {200,
           %{
             uri: "at://#{conn.query_params["repo"]}/#{conn.query_params["collection"]}/#{rkey}",
             cid: "bafyreiparent",
             value: %{text: "parent"}
           }}
      end
    end

    defp response("com.atproto.repo.createRecord", _conn),
      do: {200, %{uri: "at://did:plc:self/app.bsky.feed.post/new", cid: "bafyreinew"}}

    defp response(_method, _conn), do: {200, %{}}
  end

  setup do
    calls = start_supervised!({Agent, fn -> [] end})
    ref = :"reply_reference_#{System.unique_integer([:positive])}"

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

    {:ok, effects} =
      AtMcp.Test.QuotaFixture.start_effects(
        backend: AtMcp.Effects.ProtoRune,
        backend_state: session,
        quota_limit: 10
      )

    %{calls: calls, effects: effects, state: %{effects: effects}}
  end

  defp sent(calls, method), do: calls |> Agent.get(& &1) |> Enum.filter(&(&1.method == method))

  test "a reply to a parent that cannot be read costs no write quota and names the record", %{
    calls: calls,
    effects: effects,
    state: state
  } do
    used = AtMcp.Effects.quota_status(effects).used

    assert {:ok, result, ^state} =
             AtMcp.MCP.Server.handle_call_tool(
               "reply",
               %{"uri" => @gone, "text" => "hello"},
               state
             )

    assert result[:isError]
    assert result.structuredContent.code == "referenced_record_unreadable"
    assert result.structuredContent.uri == @gone

    # The service said RecordNotFound, so the refusal says that and nothing else.
    assert result.structuredContent.cause == "not_found"

    text = Enum.find(result.content, &(&1.type == "text")).text
    assert text =~ @gone
    assert text =~ "RecordNotFound"
    refute text =~ "not a post"
    assert text =~ "write quota"

    # The write quota is the claim: a refusal that costs a write is the defect.
    assert AtMcp.Effects.quota_status(effects).used == used
    assert sent(calls, "com.atproto.repo.createRecord") == []
  end

  test "a reply given no languages takes its parent's, and one given languages keeps them", %{
    calls: calls,
    state: state
  } do
    written = fn arguments ->
      Agent.update(calls, fn _ -> [] end)

      assert {:ok, result, ^state} = AtMcp.MCP.Server.handle_call_tool("reply", arguments, state)
      refute result[:isError], inspect(result)
      [%{body: %{"record" => record}}] = sent(calls, "com.atproto.repo.createRecord")
      record
    end

    assert written.(%{"uri" => @japanese, "text" => "はい"})["langs"] == ["ja"]
    assert written.(%{"uri" => @japanese, "text" => "yes", "langs" => ["en"]})["langs"] == ["en"]

    # The parent has no language tags, so the reply is written without a langs field.
    refute Map.has_key?(written.(%{"uri" => @readable, "text" => "hello"}), "langs")
  end

  test "a quote of a record that cannot be read is refused the same way", %{
    effects: effects,
    state: state
  } do
    used = AtMcp.Effects.quota_status(effects).used

    assert {:ok, result, ^state} =
             AtMcp.MCP.Server.handle_call_tool(
               "post",
               %{"text" => "hello", "quote" => @gone},
               state
             )

    assert result[:isError]
    assert result.structuredContent.code == "referenced_record_unreadable"
    assert AtMcp.Effects.quota_status(effects).used == used
  end

  test "any other refusal passes on the service's error name and message", %{
    calls: calls,
    state: state
  } do
    assert {:ok, result, ^state} =
             AtMcp.MCP.Server.handle_call_tool(
               "reply",
               %{"uri" => @no_repo, "text" => "hello"},
               state
             )

    assert %{
             code: "referenced_record_unreadable",
             cause: "refused",
             service_error: "InvalidRequest"
           } = result.structuredContent

    text = Enum.find(result.content, &(&1.type == "text")).text
    assert text =~ ~s(InvalidRequest: "Could not find repo: did:plc:nobody")
    refute text =~ "deleted"
    assert sent(calls, "com.atproto.repo.createRecord") == []
  end

  test "a reply to a record that is not a post, or a quote of one the app does not show as a card, is refused before anything is read",
       %{calls: calls, effects: effects, state: state} do
    list = "at://did:plc:other/app.bsky.graph.list/l"
    like = "at://did:plc:other/app.bsky.feed.like/k"

    for {tool, arguments, expected} <- [
          {"reply", %{"uri" => list, "text" => "hello"}, ~s(uri: "must be the AT URI of a post)},
          {"post", %{"text" => "hello", "quote" => like},
           ~s(quote: "must be the AT URI of a post, a feed generator, a list)}
        ] do
      assert {:ok, result, ^state} = AtMcp.MCP.Server.handle_call_tool(tool, arguments, state)
      assert result.structuredContent.code == "invalid_arguments"
      assert Enum.find(result.content, &(&1.type == "text")).text =~ expected
    end

    assert Agent.get(calls, & &1) == []
    assert AtMcp.Effects.quota_status(effects).used == 0
  end

  # A post's record key is a TID (the post lexicon's `"key": "tid"`), so a key
  # that is not one says from the URI alone that no read will find the post.
  # The service would answer RecordNotFound, and "deleted" is the wrong thing
  # to tell a caller holding a URI it copied wrong.
  test "a reply or a quote naming a post by a key that cannot be a TID is refused before anything is read",
       %{calls: calls, effects: effects, state: state} do
    for {tool, arguments, path} <- [
          {"reply", %{"uri" => @short, "text" => "hello"}, "uri"},
          {"post", %{"text" => "hello", "quote" => @short}, "quote"}
        ] do
      assert {:ok, result, ^state} = AtMcp.MCP.Server.handle_call_tool(tool, arguments, state)
      assert result.structuredContent.code == "invalid_arguments"
      assert [%{path: ^path}] = result.structuredContent.problems

      text = Enum.find(result.content, &(&1.type == "text")).text
      assert text =~ @short_key
      assert text =~ "11 characters"
      assert text =~ "TID of 13 characters"
      refute text =~ "deleted"
    end

    assert Agent.get(calls, & &1) == []
    assert AtMcp.Effects.quota_status(effects).used == 0
  end

  test "a post key of 13 characters that a TID cannot have is refused the same way",
       %{calls: calls, state: state} do
    # 13 characters, but a TID's first character is 2-7 or a-j.
    uri = "at://did:plc:other/app.bsky.feed.post/zzzzzzzzzzzzz"

    assert {:ok, result, ^state} =
             AtMcp.MCP.Server.handle_call_tool("reply", %{"uri" => uri, "text" => "hello"}, state)

    assert result.structuredContent.code == "invalid_arguments"
    assert Enum.find(result.content, &(&1.type == "text")).text =~ "zzzzzzzzzzzzz is not a TID"
    assert Agent.get(calls, & &1) == []
  end

  # The app renders `embed.record` for a feed, a list, a starter pack or a
  # labeler as a card, so a quote of one is a quote like any other.
  test "a quote of a list is written as a record embed", %{calls: calls, state: state} do
    list = "at://did:plc:other/app.bsky.graph.list/l"

    assert {:ok, result, ^state} =
             AtMcp.MCP.Server.handle_call_tool(
               "post",
               %{"text" => "this list", "quote" => list},
               state
             )

    refute result[:isError]
    [write] = sent(calls, "com.atproto.repo.createRecord")

    assert write.body["record"]["embed"]["record"] == %{
             "uri" => list,
             "cid" => "bafyreiparent"
           }
  end

  test "a service that failed reading the parent is not reported as a missing record", %{
    calls: calls,
    effects: effects,
    state: state
  } do
    used = AtMcp.Effects.quota_status(effects).used

    assert {:ok, result, ^state} =
             AtMcp.MCP.Server.handle_call_tool(
               "reply",
               %{"uri" => @broken, "text" => "hello"},
               state
             )

    assert result[:isError]

    # The parent may well still be there. Telling a caller it may be deleted
    # sends it to write somewhere else over what is an outage it should wait
    # out, so the upstream failure keeps its own kind and its status.
    assert result.structuredContent.code == "upstream_unavailable"
    assert result.structuredContent.http_status == 500

    text = Enum.find(result.content, &(&1.type == "text")).text
    refute text =~ "deleted"

    # Still before the write quota: the read that failed cost no write.
    assert AtMcp.Effects.quota_status(effects).used == used
    assert sent(calls, "com.atproto.repo.createRecord") == []
  end

  test "a service that cannot be reached at all is not reported as a missing record", %{
    state: state
  } do
    # Nothing is listening on this port: a transport failure, which says
    # nothing whatever about the parent record.
    session = %ProtoRune.Atproto.Session{
      access_jwt: "access",
      refresh_jwt: "refresh",
      did: "did:plc:self",
      handle: "self.example",
      service_url: "http://127.0.0.1:9/xrpc"
    }

    {:ok, effects} =
      AtMcp.Test.QuotaFixture.start_effects(
        backend: AtMcp.Effects.ProtoRune,
        backend_state: session,
        quota_limit: 10
      )

    offline = %{state | effects: effects}
    used = AtMcp.Effects.quota_status(effects).used

    assert {:ok, result, ^offline} =
             AtMcp.MCP.Server.handle_call_tool(
               "reply",
               %{"uri" => @readable, "text" => "hello"},
               offline
             )

    assert result[:isError]
    assert result.structuredContent.code == "upstream_failed"
    refute Enum.find(result.content, &(&1.type == "text")).text =~ "deleted"
    assert AtMcp.Effects.quota_status(effects).used == used
  end

  test "a reply that is sent still reserves exactly one write", %{
    calls: calls,
    effects: effects,
    state: state
  } do
    used = AtMcp.Effects.quota_status(effects).used

    assert {:ok, result, ^state} =
             AtMcp.MCP.Server.handle_call_tool(
               "reply",
               %{"uri" => @readable, "text" => "hello"},
               state
             )

    refute result[:isError]
    assert AtMcp.Effects.quota_status(effects).used == used + 1
    assert length(sent(calls, "com.atproto.repo.createRecord")) == 1

    # The parent read happens before the write, not instead of it: the record
    # sent still carries the strong reference built from it.
    write = calls |> sent("com.atproto.repo.createRecord") |> List.last()
    assert write.body["record"]["reply"]["parent"]["uri"] == @readable
    assert write.body["record"]["reply"]["parent"]["cid"] == "bafyreiparent"
  end
end
