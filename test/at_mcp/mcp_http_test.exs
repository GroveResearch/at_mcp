defmodule AtMcp.MCP.HTTPTest do
  @moduledoc """
  The one endpoint, against the wire.

  There is nothing per-account left to separate these identities: one listener,
  one URL, and a grant each. So the claims worth making here are that the
  separation survives on a shared listener — each credential reaches its own
  account's Effects, its own durable account quota, and nothing else — and that a
  caller cannot reach an identity its grant does not name.
  """
  use ExUnit.Case, async: false

  alias AtMcp.Test.Grant

  test "one listener serves every identity, and a grant reaches only its own" do
    identities =
      for {id, did} <- [{"http_alice", "did:plc:alice"}, {"http_bob", "did:plc:bob"}] do
        {:ok, _} =
          AtMcp.Identities.start_identity(
            id: id,
            listen_enabled: false,
            backend: AtMcp.Test.MockBackend,
            backend_state: %{did: did, mock: true},
            expected_did: did,
            write_quota: AtMcp.Test.QuotaFixture.quota(1)
          )

        on_exit(fn -> AtMcp.Identities.stop_identity(id) end)
        {client, token} = Grant.client(id)
        {id, did, client, token}
      end

    # One URL for both, so the only thing that differs is the credential.
    assert length(Enum.uniq(Enum.map(identities, fn _ -> Grant.url() end))) == 1

    for {_id, did, client, _token} <- identities do
      assert call(client, "identity_status", %{}) |> Jason.decode!() |> Map.fetch!("did") == did

      # Account quotas stay separate across identities on one listener.
      assert call(client, "post", %{"text" => "mock only"}) =~ "post"
      assert call(client, "post", %{"text" => "over quota"}) =~ "quota exhausted"
    end

    # A grant for alice asserting bob's DID is refused, rather than serving
    # either of them: the header confirms and never selects.
    [{_, alice_did, _, alice_token}, {_, bob_did, _, _}] = identities

    mismatched =
      Req.post!(Grant.url(),
        headers: Grant.headers(alice_token) ++ [{"x-at-mcp-account-did", bob_did}],
        json: request("identity_status", %{"format" => "json"}),
        retry: false
      )

    assert mismatched.status == 409
    assert mismatched.body["error"] == "account_identity_mismatch"

    # And with its own DID asserted it still reaches only alice.
    matched =
      Req.post!(Grant.url(),
        headers: Grant.session!(alice_token) ++ [{"x-at-mcp-account-did", alice_did}],
        json: request("identity_status", %{"format" => "json"}),
        retry: false
      )

    assert matched.status == 200
    assert structured(matched)["did"] == alice_did
  end

  test "invalid arguments leave the HTTP session usable and its quota untouched" do
    id = "http_invalid_arguments"

    {:ok, _} =
      AtMcp.Identities.start_identity(
        id: id,
        listen_enabled: false,
        backend: AtMcp.Test.MockBackend,
        backend_state: %{did: "did:plc:invalidargs", mock: true},
        write_quota: AtMcp.Test.QuotaFixture.quota(1)
      )

    on_exit(fn -> AtMcp.Identities.stop_identity(id) end)
    headers = Grant.session!(Grant.token(id))

    for {tool, arguments} <- [{"get_author_feed", %{}}, {"post", %{"text" => 42}}] do
      response = post(headers, tool, arguments)
      assert response.status == 200
      assert response.body["result"]["isError"] == true
      assert structured(response)["code"] == "invalid_arguments"
    end

    assert structured(post(headers, "identity_status", %{"format" => "json"}))["write_quota"][
             "used"
           ] == 0

    assert post(headers, "post", %{"text" => "valid mock write"}).body["result"]["isError"] !=
             true

    assert structured(post(headers, "identity_status", %{"format" => "json"}))["write_quota"][
             "used"
           ] == 1
  end

  test "a grant issued for json makes json its reads' default, and a call can still ask for text" do
    id = "http_json_grant"

    {:ok, _} =
      AtMcp.Identities.start_identity(
        id: id,
        listen_enabled: false,
        backend: AtMcp.Test.MockBackend,
        backend_state: %{did: "did:plc:jsongrant", mock: true}
      )

    on_exit(fn -> AtMcp.Identities.stop_identity(id) end)
    {:ok, json} = AtMcp.Grants.issue(id, scope: :read, format: "json")
    on_exit(fn -> AtMcp.Grants.revoke(json.token) end)
    plain = Grant.token(id, :read)

    by_grant = post(Grant.session!(json.token), "get_timeline").body["result"]
    assert %{"count" => 0, "items" => []} = by_grant["structuredContent"]
    assert Jason.decode!(hd(by_grant["content"])["text"]) == by_grant["structuredContent"]

    asked_text =
      post(Grant.session!(json.token), "get_timeline", %{"format" => "text"}).body["result"]

    refute Map.has_key?(asked_text, "structuredContent")

    default = post(Grant.session!(plain), "get_timeline").body["result"]
    refute Map.has_key?(default, "structuredContent")
    assert hd(default["content"])["text"] == hd(asked_text["content"])["text"]
  end

  test "the endpoint refuses a caller that presents nothing" do
    {:ok, _} =
      AtMcp.Identities.start_identity(
        id: "http_uncredentialed",
        listen_enabled: false,
        backend: AtMcp.Test.MockBackend,
        backend_state: %{did: "did:plc:uncredentialed", mock: true}
      )

    on_exit(fn -> AtMcp.Identities.stop_identity("http_uncredentialed") end)

    # If an uncredentialed caller were served, nothing would be separated: an
    # agent that wanted another identity would simply omit the header.
    response =
      Req.post!(Grant.url(),
        json: request("identity_status", %{"format" => "json"}),
        retry: false
      )

    assert response.status == 401
    assert response.body["error"] == "grant_required"
    assert Req.Response.get_header(response, "www-authenticate") == [~s(Bearer realm="at_mcp")]

    revoked = Grant.token("http_uncredentialed")
    :ok = AtMcp.Grants.revoke(revoked)

    refused =
      Req.post!(Grant.url(),
        headers: Grant.headers(revoked),
        json: request("identity_status", %{"format" => "json"}),
        retry: false
      )

    assert refused.status == 401
    assert refused.body["error"] == "unknown_grant"
  end

  test "a grant's scope bounds the tools it reaches, from the tools' own hints" do
    {:ok, _} =
      AtMcp.Identities.start_identity(
        id: "http_reader",
        listen_enabled: false,
        backend: AtMcp.Test.MockBackend,
        backend_state: %{did: "did:plc:reader", mock: true},
        write_quota: AtMcp.Test.QuotaFixture.quota(10)
      )

    on_exit(fn -> AtMcp.Identities.stop_identity("http_reader") end)

    read = Grant.session!(Grant.token("http_reader", :read))
    write = Grant.session!(Grant.token("http_reader", :write))

    assert post(read, "identity_status").status == 200
    assert post(write, "identity_status").status == 200

    refused = post(read, "post", %{"text" => "not in scope"})
    assert refused.status == 403
    assert refused.body == %{"error" => "out_of_scope", "tool" => "post"}

    assert post(write, "post", %{"text" => "mock only"}).status == 200

    # delete_post declares destructiveHint, so :write does not reach it and the
    # classification comes from the tool rather than from a list of verbs.
    assert post(write, "delete_post", %{"uri" => "at://x/app.bsky.feed.post/1"}).status == 403
    assert AtMcp.Grants.permits_scope?(:manage, "delete_post")

    # A tool nobody declares is reached by no scope, so a rename fails closed.
    refute AtMcp.Grants.permits_scope?(:manage, "post_but_renamed")
  end

  test "tools/list offers only the tools a grant's scope reaches" do
    id = "http_lister"

    {:ok, _} =
      AtMcp.Identities.start_identity(
        id: id,
        listen_enabled: false,
        backend: AtMcp.Test.MockBackend,
        backend_state: %{did: "did:plc:lister", mock: true}
      )

    on_exit(fn -> AtMcp.Identities.stop_identity(id) end)

    listed =
      Map.new([:read, :write, :manage], fn scope ->
        headers = Grant.session!(Grant.token(id, scope, tools: "full"))
        response = Req.post!(Grant.url(), headers: headers, json: list_request(), retry: false)
        assert response.status == 200
        {scope, response.body["result"]["tools"]}
      end)

    # :manage is offered the whole surface; the other two are judged against
    # each tool's own annotations as :manage was shown them.
    everything = listed.manage

    assert MapSet.new(everything, & &1["name"]) ==
             MapSet.new(Map.keys(AtMcp.Grants.tool_scopes()))

    hint = fn tool, key -> get_in(tool, ["annotations", key]) == true end

    names = fn tools -> tools |> Enum.map(& &1["name"]) |> Enum.sort() end
    read_only = Enum.filter(everything, &hint.(&1, "readOnlyHint"))
    not_destructive = Enum.reject(everything, &hint.(&1, "destructiveHint"))

    assert names.(listed.read) == names.(read_only)
    assert names.(listed.write) == names.(not_destructive)

    # Each set is a real cut: the narrower scopes are offered less.
    assert length(listed.read) < length(listed.write)
    assert length(listed.write) < length(everything)
  end

  test "an identity the service does not hold is unavailable, not unauthorized" do
    token = Grant.token("http_never_started")

    response =
      Req.post!(Grant.url(),
        headers: Grant.headers(token),
        json: request("identity_status", %{"format" => "json"}),
        retry: false
      )

    assert response.status == 503
    assert response.body["error"] == "account_unavailable"
  end

  test "initialize reports the running release's version as serverInfo.version" do
    id = "http_version"

    {:ok, _} =
      AtMcp.Identities.start_identity(
        id: id,
        listen_enabled: false,
        backend: AtMcp.Test.MockBackend,
        backend_state: %{did: "did:plc:version", mock: true},
        expected_did: "did:plc:version"
      )

    on_exit(fn -> AtMcp.Identities.stop_identity(id) end)
    {client, _token} = Grant.client(id)

    assert {:ok, info} = ExMCP.Client.server_info(client)
    version = Map.get(info, "version") || Map.get(info, :version)
    assert version == to_string(Application.spec(:at_mcp, :vsn))
  end

  test "logging/setLevel answers without changing the node's log level" do
    id = "http_log_level"

    {:ok, _} =
      AtMcp.Identities.start_identity(
        id: id,
        listen_enabled: false,
        backend: AtMcp.Test.MockBackend,
        backend_state: %{did: "did:plc:loglevel", mock: true}
      )

    on_exit(fn -> AtMcp.Identities.stop_identity(id) end)
    headers = Grant.session!(Grant.token(id))
    before = Logger.level()
    on_exit(fn -> Logger.configure(level: before) end)

    # The test runs at a level other than debug, so a change would show.
    refute before == :debug

    set_level = fn level ->
      Req.post!(Grant.url(),
        headers: headers,
        json: %{
          jsonrpc: "2.0",
          id: System.unique_integer([:positive]),
          method: "logging/setLevel",
          params: %{level: level}
        },
        retry: false
      )
    end

    accepted = set_level.("debug")
    assert accepted.status == 200
    assert accepted.body["result"] == %{}
    assert Logger.level() == before

    refused = set_level.("chatty")
    assert refused.body["error"]
    assert Logger.level() == before
  end

  test "a cancellation for a request that never ran leaves nothing behind" do
    id = "http_cancel_unknown"

    {:ok, _} =
      AtMcp.Identities.start_identity(
        id: id,
        listen_enabled: false,
        backend: AtMcp.Test.MockBackend,
        backend_state: %{did: "did:plc:cancelunknown", mock: true}
      )

    on_exit(fn -> AtMcp.Identities.stop_identity(id) end)
    headers = Grant.session!(Grant.token(id))

    # ExMCP's private table of cancellable requests (GHSA-22m7-hr37-pxg3: up to
    # 1.6.1 every cancellation for an unknown id added a row to it that was
    # never removed). If upstream renames it, this fails rather than passing on
    # :undefined.
    table = :ex_mcp_cancelled_requests
    assert is_integer(:ets.info(table, :size))

    for n <- 1..50 do
      response =
        Req.post!(Grant.url(),
          headers: headers,
          json: %{
            jsonrpc: "2.0",
            method: "notifications/cancelled",
            params: %{requestId: "never-sent-#{n}"}
          },
          retry: false
        )

      assert response.status in 200..299
    end

    # Only these ids are checked, so other rows (requests in flight, upstream's
    # sweep) cannot move the result. Keys are a bare id up to 1.6.1 and
    # {scope, id} after.
    left_behind =
      for row <- :ets.tab2list(table),
          key = elem(row, 0),
          id = if(is_tuple(key), do: elem(key, tuple_size(key) - 1), else: key),
          is_binary(id) and String.starts_with?(id, "never-sent-"),
          do: id

    assert left_behind == []
  end

  defp post(headers, tool, arguments \\ %{}) do
    Req.post!(Grant.url(), headers: headers, json: request(tool, arguments), retry: false)
  end

  defp request(tool, arguments) do
    %{
      jsonrpc: "2.0",
      id: System.unique_integer([:positive]),
      method: "tools/call",
      params: %{name: tool, arguments: arguments}
    }
  end

  defp list_request,
    do: %{jsonrpc: "2.0", id: System.unique_integer([:positive]), method: "tools/list"}

  defp structured(response), do: response.body["result"]["structuredContent"]

  defp call(client, name, args) do
    assert {:ok, result} = ExMCP.Client.call_tool(client, name, args, format: :map)
    content = Map.get(result, "content") || Map.fetch!(result, :content)
    Enum.map_join(content, fn item -> Map.get(item, "text") || Map.fetch!(item, :text) end)
  end
end
