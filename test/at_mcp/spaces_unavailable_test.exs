defmodule AtMcp.SpacesUnavailableTest do
  @moduledoc """
  Spaces are optional: with no Node, no built helper, or `AT_MCP_SPACES`
  false, the Spaces tools are refused before anything is sent, saying why,
  and the rest of AtMcp works as before.
  """
  use ExUnit.Case, async: false

  alias AtMcp.Spaces.Helper

  setup do
    :ok = Supervisor.terminate_child(AtMcp.Supervisor, Helper)
    on_exit(fn -> {:ok, _} = Supervisor.restart_child(AtMcp.Supervisor, Helper) end)
    :ok
  end

  defp start(opts) do
    {:ok, pid} = Helper.start_link(opts)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    pid
  end

  test "each reason Spaces are off is answered, and a call is refused with it" do
    for {opts, reason, says} <- [
          {[enabled: false], :disabled, "AT_MCP_SPACES is false"},
          {[node: "/nonexistent/node"], :no_node, "no node executable"},
          {[script: "/nonexistent/at_mcp-spaces.mjs"], :no_script, "no built Spaces helper"}
        ] do
      pid = start(opts)
      assert Helper.available() == {:error, reason}

      assert {:error, %AtMcp.Effects.Failure{kind: :refused, detail: :spaces_unavailable} = f} =
               Helper.call("oauth.status", %{did: "did:plc:x"})

      assert f.message =~ says
      GenServer.stop(pid)
    end
  end

  test "a notes tool is refused as unavailable, while the account's other tools work" do
    start(enabled: false)

    {:ok, effects} =
      AtMcp.Test.QuotaFixture.start_effects(
        backend: AtMcp.Effects.ProtoRune,
        backend_state: %ProtoRune.Atproto.Session{
          did: "did:plc:plain",
          handle: "plain.test",
          access_jwt: "a",
          refresh_jwt: "r",
          service_url: "https://pds.invalid/xrpc"
        }
      )

    previous = Application.get_env(:at_mcp, :network)
    Application.put_env(:at_mcp, :network, :delve)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:at_mcp, :network, previous),
        else: Application.delete_env(:at_mcp, :network)
    end)

    state = %{effects: effects}
    {:ok, result, _} = AtMcp.MCP.Server.handle_call_tool("list_notes", %{}, state)
    assert result[:isError]
    assert hd(result.content).text =~ "Spaces are not available in this installation"

    {:ok, status, _} = AtMcp.MCP.Server.handle_call_tool("identity_status", %{}, state)
    refute status[:isError]
  end

  test "the town AppView reads inboxes only when the setting says so" do
    previous = Application.get_env(:at_mcp, :network)
    Application.put_env(:at_mcp, :network, :delve)

    on_exit(fn ->
      Application.delete_env(:at_mcp, :town_inbox_reader)

      if previous,
        do: Application.put_env(:at_mcp, :network, previous),
        else: Application.delete_env(:at_mcp, :network)
    end)

    assert AtMcp.Spaces.inbox_readers() == []
    Application.put_env(:at_mcp, :town_inbox_reader, true)
    assert AtMcp.Spaces.inbox_readers() == ["did:web:api.delve.town"]

    Application.put_env(:at_mcp, :network, :bluesky)
    assert AtMcp.Spaces.inbox_readers() == []
  end
end
