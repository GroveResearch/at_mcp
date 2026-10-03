defmodule AtMcp.SharedStdioTest do
  use ExUnit.Case, async: false

  defmodule Backend do
    def login(_opts) do
      Agent.get_and_update(__MODULE__, fn state ->
        {{:ok, %{did: state.did, handle: "shared.test"}}, %{state | logins: state.logins + 1}}
      end)
    end

    # References are read before the write quota is charged; nothing here
    # refers to another record.
    def prepare_post(session, _text, opts), do: resolve_references(session, opts)

    def resolve_references(_state, opts), do: {:ok, opts}

    def post(%{did: did}, text, _opts \\ []) do
      Agent.update(__MODULE__, &%{&1 | writes: &1.writes ++ [%{did: did, text: text}]})
      {:ok, %{uri: "at://#{did}/app.bsky.feed.post/fixture", cid: "fixture"}}
    end
  end

  defmodule Control do
    import Plug.Conn
    def init(opts), do: opts

    def call(conn, id) do
      case conn.request_path do
        "/disconnect" -> :ok = AtMcp.Accounts.disconnect(id)
        "/reconnect" -> {:ok, _} = AtMcp.Accounts.reconnect(id)
        "/state" -> :ok
      end

      state = Agent.get(Backend, & &1)
      body = Map.put(state, :owner_alive, is_pid(AtMcp.Identity.whereis(id)))
      conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(body))
    end
  end

  @tag timeout: 120_000
  @tag skip: is_nil(System.get_env("MCP_CLIENT_PATH")) or is_nil(System.get_env("MCP_SDK_PATH"))
  test "official stdio and HTTP clients share one account owner and one durable disconnect state" do
    id = "shared-stdio-#{System.unique_integer([:positive])}"
    did = "did:plc:#{id}"

    start_supervised!(%{
      id: Backend,
      start: {Agent, :start_link, [fn -> %{did: did, logins: 0, writes: []} end, [name: Backend]]}
    })

    control_port = free_port()

    {:ok, _} =
      AtMcp.Identities.start_identity(
        id: id,
        expected_did: did,
        backend: Backend,
        handle: "shared.test",
        password: "fixture",
        listen_enabled: false,
        notifications_enabled: false
      )

    on_exit(fn -> AtMcp.Identities.stop_identity(id) end)

    start_supervised!(
      Plug.Cowboy.child_spec(
        scheme: :http,
        plug: {Control, id},
        options: [port: control_port, ip: {127, 0, 0, 1}]
      )
    )

    paths = :code.get_path() |> Enum.flat_map(&["-pa", to_string(&1)])

    {output, code} =
      System.cmd("node", [Path.expand("../support/shared_stdio_sdk_probe.mjs", __DIR__)],
        env: [
          {"AT_MCP_MCP_COMMAND",
           System.get_env("AT_MCP_CONNECT_RELEASE") || System.find_executable("elixir")},
          {"AT_MCP_SHARED_RELEASE",
           if(System.get_env("AT_MCP_CONNECT_RELEASE"), do: "1", else: "0")},
          {"AT_MCP_MCP_ARGS", Jason.encode!(paths)},
          {"AT_MCP_SHARED_URL", AtMcp.Test.Grant.url()},
          {"AT_MCP_SHARED_DID", did},
          {"AT_MCP_GRANT", AtMcp.Test.Grant.token(id)},
          {"AT_MCP_TEST_CONTROL", "http://127.0.0.1:#{control_port}"}
        ],
        stderr_to_stdout: true
      )

    assert code == 0, output
    assert output =~ ~s("public_writes":0)
    assert output =~ ~s("no_duplicate_after_response_loss":true)
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end
end
