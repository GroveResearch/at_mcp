defmodule AtMcp.CallDeadlineTest do
  @moduledoc """
  An account's service that stops answering, against the wire.

  The MCP endpoint gives each tool call a fixed time to answer and abandons the
  call when it runs out. A write abandoned there may already have reached the
  service, so what the caller is told has to come from AtMcp, in AtMcp's own
  vocabulary, before that deadline: a write that was sent is an unknown
  outcome, and one that never left AtMcp is a request that did not happen.
  """
  use ExUnit.Case, async: false

  alias AtMcp.Test.Grant

  @deadline 500

  defmodule PDS do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    # `hang` names the request paths that never answer on their own. Each one
    # reports its arrival to the test and waits to be released, which is what a
    # PDS that has stopped responding looks like from AtMcp's side.
    def call(conn, opts) do
      {:ok, _body, conn} = read_body(conn)
      send(opts[:test], {:pds, conn.request_path, self()})

      if Enum.any?(opts[:hang], &String.ends_with?(conn.request_path, &1)) do
        receive do
          :release -> :ok
        after
          30_000 -> :ok
        end
      end

      {status, body} = answer(conn.request_path, opts)

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(body))
    end

    defp answer("/xrpc/com.atproto.server.createSession", opts),
      do: {200, %{accessJwt: "access", refreshJwt: "refresh", did: opts[:did], handle: "g.test"}}

    defp answer("/xrpc/com.atproto.repo.getRecord", _opts),
      do:
        {200,
         %{
           uri: "at://did:plc:author/app.bsky.feed.post/parent",
           cid: "bafyreiparent",
           value: %{text: "Hmm", createdAt: "2026-09-24T02:26:18.529Z"}
         }}

    defp answer("/xrpc/com.atproto.repo.createRecord", opts),
      do: {200, %{uri: "at://#{opts[:did]}/app.bsky.feed.post/reply", cid: "bafyreireply"}}

    defp answer(_path, _opts), do: {404, %{error: "NotFound"}}
  end

  setup do
    previous = Application.fetch_env(:at_mcp, :call_deadline_ms)
    Application.put_env(:at_mcp, :call_deadline_ms, @deadline)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:at_mcp, :call_deadline_ms, value)
        :error -> Application.delete_env(:at_mcp, :call_deadline_ms)
      end
    end)
  end

  test "a reply the service never answers is an unknown outcome, reported before the endpoint gives up" do
    headers = account("deadline_sent", hang: ["createRecord"])

    {elapsed, response} = :timer.tc(fn -> post(headers, "reply", reply()) end, :millisecond)

    # The write left AtMcp: the service received it and has not said what it did.
    assert_received {:pds, "/xrpc/com.atproto.repo.createRecord", _}

    assert response.status == 200
    refute response.body["error"], inspect(response.body)
    result = response.body["result"]
    assert result["isError"]
    assert result["structuredContent"]["code"] == "write_outcome_unknown"
    assert result["structuredContent"]["outcome"] == "unknown"
    assert hd(result["content"])["text"] =~ "may have completed"

    # AtMcp answered at its own deadline, well inside the endpoint's.
    assert elapsed < @deadline + 2_000
  end

  test "a reply whose parent never arrives was not sent, and says so" do
    headers = account("deadline_parent", hang: ["getRecord"])

    result = post(headers, "reply", reply()).body["result"]

    assert_received {:pds, "/xrpc/com.atproto.repo.getRecord", _}
    refute_received {:pds, "/xrpc/com.atproto.repo.createRecord", _}
    assert result["isError"]
    assert result["structuredContent"]["code"] == "call_deadline_exceeded"
    refute result["structuredContent"]["outcome"]
    assert hd(result["content"])["text"] =~ "Nothing was changed"
  end

  test "a reply queued behind a write the service never answers was not sent, and says so" do
    headers = account("deadline_queued", hang: ["createRecord"])

    # One reply holds the account's write order while its service does not
    # answer. It is given longer than the next reply, so the next one is still
    # waiting for its turn when its time is up.
    Application.put_env(:at_mcp, :call_deadline_ms, 10_000)
    first = Task.async(fn -> post(headers, "reply", reply()) end)
    assert_receive {:pds, "/xrpc/com.atproto.repo.createRecord", held}, 2_000
    Application.put_env(:at_mcp, :call_deadline_ms, @deadline)

    result = post(headers, "reply", reply()).body["result"]

    assert result["isError"]
    assert result["structuredContent"]["code"] == "call_deadline_exceeded"
    refute result["structuredContent"]["outcome"]
    assert hd(result["content"])["text"] =~ "Nothing was changed"

    send(held, :release)
    assert Task.await(first, 5_000).status == 200
    refute_receive {:pds, "/xrpc/com.atproto.repo.createRecord", _}, 500
  end

  test "a reply is sent while a read the service never answers is still waiting" do
    headers = account("deadline_read", hang: ["getPostThread"])

    reader =
      Task.async(fn ->
        post(headers, "get_thread", %{"uri" => "at://did:plc:author/app.bsky.feed.post/parent"})
      end)

    assert_receive {:pds, "/xrpc/app.bsky.feed.getPostThread", held}, 2_000

    result = post(headers, "reply", reply()).body["result"]

    refute result["isError"], inspect(result)
    assert_received {:pds, "/xrpc/com.atproto.repo.createRecord", _}

    send(held, :release)
    assert Task.await(reader, 5_000).status == 200
  end

  defp account(id, opts) do
    ref = {:pds, id}
    did = "did:plc:#{String.replace(id, "_", "")}"

    start_supervised!(
      Plug.Cowboy.child_spec(
        scheme: :http,
        plug: {PDS, test: self(), did: did, hang: Keyword.fetch!(opts, :hang)},
        options: [port: 0, ip: {127, 0, 0, 1}, ref: ref]
      ),
      id: ref
    )

    # The login that starts the account runs under the account's deadline too.
    # It is not what these tests hold up, so it gets the default deadline, and
    # a loaded machine cannot fail the setup.
    deadline = Application.get_env(:at_mcp, :call_deadline_ms)
    Application.delete_env(:at_mcp, :call_deadline_ms)

    {:ok, _} =
      AtMcp.Identities.start_identity(
        id: id,
        handle: "g.test",
        password: "disposable-password",
        service: "http://127.0.0.1:#{:ranch.get_port(ref)}",
        expected_did: did,
        write_quota: AtMcp.Test.QuotaFixture.quota(10),
        listen_enabled: false,
        notifications_enabled: false
      )

    Application.put_env(:at_mcp, :call_deadline_ms, deadline)
    on_exit(fn -> AtMcp.Identities.stop_identity(id) end)
    Grant.session!(Grant.token(id))
  end

  defp reply,
    do: %{"uri" => "at://did:plc:author/app.bsky.feed.post/parent", "text" => "Received."}

  defp post(headers, tool, arguments) do
    Req.post!(Grant.url(),
      headers: headers,
      json: %{
        jsonrpc: "2.0",
        id: System.unique_integer([:positive]),
        method: "tools/call",
        params: %{name: tool, arguments: arguments}
      },
      retry: false,
      receive_timeout: 30_000
    )
  end
end
