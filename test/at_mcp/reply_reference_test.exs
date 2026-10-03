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

  @readable "at://did:plc:other/app.bsky.feed.post/readable"
  @gone "at://did:plc:other/app.bsky.feed.post/gone"
  @broken "at://did:plc:other/app.bsky.feed.post/broken"

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
        "gone" ->
          {400, %{error: "RecordNotFound", message: "Could not locate record"}}

        # The service is having a bad day. The record it was asked about may be
        # perfectly fine.
        "broken" ->
          {500, %{error: "InternalServerError", message: "upstream is down"}}

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

    text = Enum.find(result.content, &(&1.type == "text")).text
    assert text =~ @gone
    assert text =~ "write quota"

    # The write quota is the claim: a refusal that costs a write is the defect.
    assert AtMcp.Effects.quota_status(effects).used == used
    assert sent(calls, "com.atproto.repo.createRecord") == []
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
