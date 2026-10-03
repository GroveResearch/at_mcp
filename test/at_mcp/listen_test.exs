defmodule AtMcp.ListenTest do
  use ExUnit.Case, async: false

  defmodule FakeInbound do
    def track(did, meta \\ %{}) do
      case :persistent_term.get(:at_mcp_listen_test_parent, nil) do
        nil -> :ok
        parent -> send(parent, {:inbound_tracked, did, meta})
      end

      :ok
    end
  end

  setup do
    :persistent_term.put(:at_mcp_listen_test_parent, self())

    on_exit(fn ->
      :persistent_term.erase(:at_mcp_listen_test_parent)
    end)

    :ok
  end

  test "subscribe receives notify fan-out" do
    assert {:ok, _} = AtMcp.Listen.subscribe(:events)
    :ok = AtMcp.Listen.notify(%{type: :commit, did: "did:plc:test"})
    assert_receive {:at_mcp_listen, %{type: :commit, did: "did:plc:test"}}, 500
  end

  test "registers session DID with Inbound once Effects has a DID" do
    {:ok, effects} =
      AtMcp.Test.QuotaFixture.start_effects(backend: AtMcp.Test.MockBackend, quota_limit: 2)

    assert {:ok, _} = AtMcp.Effects.login(effects)

    :sys.replace_state(effects, fn s ->
      %{s | backend_state: Map.put(s.backend_state, :did, "did:plc:at_mcp-test")}
    end)

    name = :"at_mcp_listen_#{System.unique_integer([:positive])}"

    {:ok, _listen} =
      AtMcp.Listen.start_link(
        name: name,
        effects: effects,
        enabled: true,
        did_poll_ms: 50,
        inbound: FakeInbound
      )

    assert_receive {:inbound_tracked, "did:plc:at_mcp-test", _}, 1_000
  end
end
