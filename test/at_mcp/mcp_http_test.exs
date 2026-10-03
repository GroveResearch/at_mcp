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
        headers: Grant.headers(alice_token) ++ [{"x-kite-account-did", bob_did}],
        json: request("identity_status"),
        retry: false
      )

    assert mismatched.status == 409
    assert mismatched.body["error"] == "account_identity_mismatch"

    # And with its own DID asserted it still reaches only alice.
    matched =
      Req.post!(Grant.url(),
        headers: Grant.session!(alice_token) ++ [{"x-kite-account-did", alice_did}],
        json: request("identity_status"),
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

    assert structured(post(headers, "identity_status"))["write_quota"]["used"] == 0

    assert post(headers, "post", %{"text" => "valid mock write"}).body["result"]["isError"] !=
             true

    assert structured(post(headers, "identity_status"))["write_quota"]["used"] == 1
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
    response = Req.post!(Grant.url(), json: request("identity_status"), retry: false)
    assert response.status == 401
    assert response.body["error"] == "grant_required"
    assert Req.Response.get_header(response, "www-authenticate") == [~s(Bearer realm="at_mcp")]

    revoked = Grant.token("http_uncredentialed")
    :ok = AtMcp.Grants.revoke(revoked)

    refused =
      Req.post!(Grant.url(),
        headers: Grant.headers(revoked),
        json: request("identity_status"),
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

  test "an identity the service does not hold is unavailable, not unauthorized" do
    token = Grant.token("http_never_started")

    response =
      Req.post!(Grant.url(),
        headers: Grant.headers(token),
        json: request("identity_status"),
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

  defp post(headers, tool, arguments \\ %{}) do
    Req.post!(Grant.url(), headers: headers, json: request(tool, arguments), retry: false)
  end

  defp request(tool, arguments \\ %{}) do
    %{
      jsonrpc: "2.0",
      id: System.unique_integer([:positive]),
      method: "tools/call",
      params: %{name: tool, arguments: arguments}
    }
  end

  defp structured(response), do: response.body["result"]["structuredContent"]

  defp call(client, name, args) do
    assert {:ok, result} = ExMCP.Client.call_tool(client, name, args, format: :map)
    content = Map.get(result, "content") || Map.fetch!(result, :content)
    Enum.map_join(content, fn item -> Map.get(item, "text") || Map.fetch!(item, :text) end)
  end
end
