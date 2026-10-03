defmodule AtMcp.MCP.SharedStdioTest do
  use ExUnit.Case, async: false
  alias AtMcp.MCP.SharedStdio

  setup do
    # The release entrypoint traps exits; failed linked client init may also
    # deliver an EXIT after returning its error tuple. Exercise that same context.
    Process.flag(:trap_exit, true)
    id = "shared-front-#{System.unique_integer([:positive])}"
    did = "did:plc:" <> id

    {:ok, _} =
      AtMcp.Identities.start_identity(
        id: id,
        listen_enabled: false,
        expected_did: did,
        backend: AtMcp.Test.MockBackend,
        backend_state: %{did: did, handle: id}
      )

    on_exit(fn -> AtMcp.Identities.stop_identity(id) end)
    %{url: AtMcp.Test.Grant.url(), did: did, id: id, grant: AtMcp.Test.Grant.token(id)}
  end

  test "two connections preserve tools and results from one owner", %{
    url: url,
    did: did,
    id: id,
    grant: grant
  } do
    login_count = AtMcp.Effects.login_count(AtMcp.Identity.effects_name(id))
    a = start_connection(:a, url, did, grant)
    b = start_connection(:b, url, did, grant)
    {:ok, sa} = SharedStdio.init(client: a)
    {:ok, sb} = SharedStdio.init(client: b)
    {:ok, tools, nil, ^sa} = SharedStdio.handle_list_tools(nil, sa)
    {:ok, direct} = ExMCP.Client.list_tools(a, format: :map)
    assert tools == direct["tools"]
    assert Enum.find(tools, &(&1["name"] == "post"))["annotations"]["readOnlyHint"] == false
    {:ok, first, ^sa} = SharedStdio.handle_call_tool("post", %{"text" => "one"}, sa)
    refute first["isError"]
    {:ok, status, ^sb} = SharedStdio.handle_call_tool("identity_status", %{}, sb)
    {:ok, body} = Jason.decode(hd(status["content"])["text"])
    assert body["did"] == did
    assert body["login_count"] == login_count
    assert body["write_quota"]["used"] == 1
    ExMCP.Client.stop(a)
    assert is_pid(AtMcp.Identity.whereis(id))
    {:ok, _, ^sb} = SharedStdio.handle_call_tool("identity_status", %{}, sb)
  end

  test "wrong account fails initialization without granting tools", %{url: url, grant: grant} do
    assert {:error, _} = SharedStdio.connect(url, "did:plc:other", grant)
  end

  # The grant is what names the identity now, so a stdio bridge without one is a
  # misconfigured bridge rather than an unavailable service, and it never reaches
  # the wire to find that out.
  test "a connection with no grant is refused before it is attempted", %{url: url, did: did} do
    for absent <- [nil, "", "   ", "has space", "has\nnewline"] do
      assert {:error, :invalid_connection} = SharedStdio.connect(url, did, absent)
    end
  end

  test "a grant for another identity cannot front this one", %{url: url, did: did} do
    {:ok, _} =
      AtMcp.Identities.start_identity(
        id: "shared-front-other",
        listen_enabled: false,
        expected_did: "did:plc:shared-front-other",
        backend: AtMcp.Test.MockBackend,
        backend_state: %{did: "did:plc:shared-front-other"}
      )

    on_exit(fn -> AtMcp.Identities.stop_identity("shared-front-other") end)

    assert {:error, _} =
             SharedStdio.connect(url, did, AtMcp.Test.Grant.token("shared-front-other"))
  end

  test "dead upstream reports unknown outcome without throwing raw errors", %{
    url: url,
    did: did,
    grant: grant
  } do
    {:ok, client} = SharedStdio.connect(url, did, grant)
    {:ok, state} = SharedStdio.init(client: client)
    ExMCP.Client.stop(client)

    {:ok, result, ^state} =
      SharedStdio.handle_call_tool("post", %{"text" => "sentinel-secret"}, state)

    assert result.isError
    assert result.structuredContent.outcome == "unknown"
    refute Jason.encode!(result) =~ "sentinel-secret"
  end

  test "modern discovery advertises the same tools-only surface as legacy initialize" do
    request = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "server/discover",
      "params" => %{
        "_meta" => %{
          "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
          "io.modelcontextprotocol/clientInfo" => %{"name" => "test", "version" => "1"},
          "io.modelcontextprotocol/clientCapabilities" => %{}
        }
      }
    }

    assert {:response, %{"result" => result}, _} =
             ExMCP.Server.Dispatch.dispatch(request, SharedStdio, %{})

    assert result["capabilities"]["tools"] == %{}
    refute Map.has_key?(result["capabilities"], "resources")
    assert result["_meta"]["io.modelcontextprotocol/serverInfo"]["name"] == "at_mcp"
  end

  test "initialize and discovery report the running release's version" do
    version = to_string(Application.spec(:at_mcp, :vsn))

    initialize = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => "2025-06-18",
        "clientInfo" => %{"name" => "test", "version" => "1"},
        "capabilities" => %{}
      }
    }

    assert {:response, %{"result" => result}, _} =
             ExMCP.Server.Dispatch.dispatch(initialize, SharedStdio, %{})

    assert result["serverInfo"]["version"] == version

    discover = %{
      "jsonrpc" => "2.0",
      "id" => 2,
      "method" => "server/discover",
      "params" => %{
        "_meta" => %{
          "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
          "io.modelcontextprotocol/clientInfo" => %{"name" => "test", "version" => "1"},
          "io.modelcontextprotocol/clientCapabilities" => %{}
        }
      }
    }

    assert {:response, %{"result" => result}, _} =
             ExMCP.Server.Dispatch.dispatch(discover, SharedStdio, %{})

    assert result["_meta"]["io.modelcontextprotocol/serverInfo"]["version"] == version
  end

  test "rejects nonloopback, credential-bearing or malformed targets" do
    for url <- [
          "https://example.com/mcp",
          "http://example.com/mcp",
          "http://user:secret@localhost/mcp",
          "http://localhost/mcp?secret=1",
          "http://127.0.0.1:0/mcp"
        ] do
      assert {:error, _} = SharedStdio.validate_target(url, "did:plc:account")
    end

    assert {:error, _} =
             SharedStdio.validate_target(
               "http://127.0.0.1/mcp",
               "did:plc:account\r\nX-Secret: value"
             )
  end

  defp start_connection(id, url, did, grant) do
    start_supervised!(%{
      id: id,
      start: {SharedStdio, :connect, [url, did, grant]},
      restart: :temporary
    })
  end
end
