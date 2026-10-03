defmodule AtMcp.InboundRestartTest do
  use ExUnit.Case, async: false

  test "shared inbound and disk store crashes preserve live identities and restore registration" do
    identities =
      for suffix <- ["a", "b"] do
        id = "restart-#{suffix}"
        did = "did:plc:restart-#{suffix}"

        {:ok, _} =
          AtMcp.Identities.start_identity(
            id: id,
            backend: AtMcp.Test.MockBackend,
            backend_state: %{did: did},
            listen_enabled: true,
            did_poll_ms: 10,
            notifications_enabled: false,
            write_quota: AtMcp.Test.QuotaFixture.quota(2)
          )

        on_exit(fn -> AtMcp.Identities.stop_identity(id) end)
        effects = AtMcp.Identity.effects_name(id)
        assert {:ok, _} = AtMcp.Effects.post(effects, "local mock write before restart")
        {id, did, GenServer.whereis(effects)}
      end

    assert eventually(fn ->
             Enum.all?(identities, fn {_, did, _} -> did in AtMcp.Inbound.tracked_dids() end)
           end)

    old_inbound = Process.whereis(AtMcp.Inbound)
    Process.exit(old_inbound, :kill)

    assert eventually(fn ->
             pid = Process.whereis(AtMcp.Inbound)
             is_pid(pid) and pid != old_inbound
           end)

    assert eventually(fn ->
             Enum.all?(identities, fn {_, did, _} -> did in AtMcp.Inbound.tracked_dids() end)
           end)

    old_store = Process.whereis(AtMcp.Inbound.Store)
    Process.exit(old_store, :kill)

    assert eventually(fn ->
             pid = Process.whereis(AtMcp.Inbound.Store)
             is_pid(pid) and pid != old_store
           end)

    for {id, did, effects} <- identities do
      assert GenServer.whereis(AtMcp.Identity.effects_name(id)) == effects
      assert AtMcp.Effects.session_did(effects) == did
      assert AtMcp.Effects.quota_status(effects).used == 1
      assert AtMcp.Effects.login_count(effects) == 1
      assert did in AtMcp.Inbound.tracked_dids()
      AtMcp.Identities.stop_identity(id)
      assert eventually(fn -> did not in AtMcp.Inbound.tracked_dids() end)
    end
  end

  defp eventually(fun, attempts \\ 100) do
    cond do
      fun.() ->
        true

      attempts == 0 ->
        false

      true ->
        Process.sleep(10)
        eventually(fun, attempts - 1)
    end
  end

  defmodule ExitingStream do
    use Agent

    def start_link(opts) do
      case :persistent_term.get(:at_mcp_inbound_js_parent, nil) do
        nil -> :ok
        parent -> send(parent, {:inbound_js_started, opts})
      end

      Agent.start_link(fn -> opts end, name: Keyword.get(opts, :name, __MODULE__))
    end
  end

  test "collection restarts when the stream client process exits" do
    :persistent_term.put(:at_mcp_inbound_js_parent, self())
    on_exit(fn -> :persistent_term.erase(:at_mcp_inbound_js_parent) end)

    dir = Path.join(System.tmp_dir!(), "at_mcp-js-down-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    store = start_supervised!({AtMcp.Inbound.Store, name: nil, state_dir: dir}, id: make_ref())

    {:ok, inbound} =
      AtMcp.Inbound.start_link(
        name: :"restart_inbound_#{System.unique_integer([:positive])}",
        store: store,
        enabled: true,
        stream: ExitingStream,
        stream_name: :"restart_js_#{System.unique_integer([:positive])}"
      )

    assert :ok = AtMcp.Inbound.track(inbound, "did:plc:restart-stream")
    assert_receive {:inbound_js_started, _opts}, 1_000
    first = :sys.get_state(inbound).jetstream
    assert is_pid(first)

    # A normal exit does not propagate to a linked, non-trapping Inbound, so
    # supervision cannot help here: without the monitor, collection stops and
    # nothing restarts it until a DID is tracked or a pause resumes.
    :ok = Agent.stop(first, :normal)

    assert_receive {:inbound_js_started, _opts}, 3_000
    assert eventually(fn -> is_pid(:sys.get_state(inbound).jetstream) end)
    assert :sys.get_state(inbound).jetstream != first
  end
end
