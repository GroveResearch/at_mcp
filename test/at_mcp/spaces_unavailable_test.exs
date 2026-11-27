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
          {[enabled: true, node: "/nonexistent/node"], :no_node, "no node executable"},
          {[enabled: true, script: "/nonexistent/at_mcp-spaces.mjs"], :no_script,
           "no built Spaces helper"}
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
    {:ok, result, _} = AtMcp.MCP.Server.handle_call_tool("get_notes", %{}, state)
    assert result[:isError]
    assert hd(result.content).text =~ "Spaces are not available in this installation"

    {:ok, status, _} = AtMcp.MCP.Server.handle_call_tool("identity_status", %{}, state)
    refute status[:isError]
  end

  test "the town AppView is a listed reader of new inboxes only when the setting turns it on" do
    previous = Application.get_env(:at_mcp, :network)
    Application.put_env(:at_mcp, :network, :delve)

    on_exit(fn ->
      Application.delete_env(:at_mcp, :town_inbox_reader)

      if previous,
        do: Application.put_env(:at_mcp, :network, previous),
        else: Application.delete_env(:at_mcp, :network)
    end)

    # Off by default: the AppView reads inboxes through grants.
    Application.delete_env(:at_mcp, :town_inbox_reader)
    assert AtMcp.Spaces.inbox_readers() == []

    # On, as the fallback: a listed reader of new inboxes.
    Application.put_env(:at_mcp, :town_inbox_reader, true)
    assert [reader] = AtMcp.Spaces.inbox_readers()
    assert reader =~ "did:"

    assert AtMcp.Spaces.scope_for("did:plc:x") =~
             "org.atgrp.inbox?action=read&manage=create&manage=update"

    Application.put_env(:at_mcp, :network, :bluesky)
    assert AtMcp.Spaces.inbox_readers() == []
  end

  test "identity_status says plainly when the account is logged out" do
    {:ok, effects} =
      AtMcp.Test.QuotaFixture.start_effects(
        backend: AtMcp.Effects.ProtoRune,
        handle: "out.test",
        password: "p",
        logged_in: false
      )

    {:ok, result, _} =
      AtMcp.MCP.Server.handle_call_tool("identity_status", %{}, %{effects: effects})

    status = Jason.decode!(Jason.encode!(result.structuredContent))
    assert status["logged_in"] == false
    assert status["logged_out"] =~ "This account is logged out"

    {:ok, logged_in} =
      AtMcp.Test.QuotaFixture.start_effects(
        backend: AtMcp.Test.MockBackend,
        backend_state: %{did: "did:plc:in", handle: "in.test"}
      )

    {:ok, result, _} =
      AtMcp.MCP.Server.handle_call_tool("identity_status", %{}, %{effects: logged_in})

    refute Map.has_key?(Jason.decode!(Jason.encode!(result.structuredContent)), "logged_out")
  end
end
