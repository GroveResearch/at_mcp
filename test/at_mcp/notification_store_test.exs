defmodule AtMcp.NotificationStoreTest do
  use ExUnit.Case, async: true
  alias AtMcp.Inbound.Store

  setup do
    dir =
      Path.join(System.tmp_dir!(), "at_mcp-notifications-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp store(dir, opts \\ []),
    do: start_supervised!({Store, Keyword.merge([name: nil, state_dir: dir], opts)})

  test "completed sweeps survive restart, advance monotonically and belong to a DID", %{dir: dir} do
    pid = store(dir)
    assert Store.notification_checkpoint(pid, "did:plc:alice") == nil
    assert :ok = Store.checkpoint_notifications(pid, "did:plc:alice", 1_000_000)
    assert :ok = Store.checkpoint_notifications(pid, "did:plc:alice", 2_000_000)
    assert :ok = Store.checkpoint_notifications(pid, "did:plc:alice", 1_500_000)
    assert :ok = Store.checkpoint_notifications(pid, "did:plc:bob", 3_000_000)
    stop_supervised!(Store)
    pid = store(dir)
    assert Store.notification_checkpoint(pid, "did:plc:alice") == 2_000_000
    assert Store.notification_checkpoint(pid, "did:plc:bob") == 3_000_000
    assert Store.notification_checkpoint(pid, "did:plc:charlie") == nil
    assert Store.status(pid).cursor == nil
  end

  test "old snapshots retain their stream cursor while gaining private checkpoints", %{dir: dir} do
    data = %{version: 1, cursor: 123, pending: %{}, receipts: []}
    File.write!(Path.join(dir, "inbound.term"), :erlang.term_to_binary(data))
    pid = store(dir)
    assert Store.notification_checkpoint(pid, "did:plc:alice") == nil
    assert Store.status(pid).cursor == 123
    assert :ok = Store.checkpoint_notifications(pid, "did:plc:alice", 1000)
    stop_supervised!(Store)
    pid = store(dir)
    assert Store.status(pid).cursor == 123
    assert Store.notification_checkpoint(pid, "did:plc:alice") == 1000
  end

  test "checkpoint capacity failure leaves the last completed sweep on disk", %{dir: dir} do
    pid = store(dir, max_bytes: 250)
    assert :ok = Store.checkpoint_notifications(pid, "did:plc:alice", 1000)
    assert {:error, :full} = Store.checkpoint_notifications(pid, String.duplicate("x", 500), 2000)
    assert Store.notification_checkpoint(pid, "did:plc:alice") == 1000
    stop_supervised!(Store)
    pid = store(dir)
    assert Store.notification_checkpoint(pid, "did:plc:alice") == 1000
    assert Store.notification_checkpoint(pid, String.duplicate("x", 500)) == nil
  end

  test "malformed checkpoint state fails startup rather than skipping incoming work", %{dir: dir} do
    for notifications <- [
          %{"did:plc:alice" => -1},
          %{"did:plc:alice" => "100"},
          %{nil => 100},
          []
        ] do
      data = %{version: 1, cursor: nil, pending: %{}, receipts: [], notifications: notifications}
      File.write!(Path.join(dir, "inbound.term"), :erlang.term_to_binary(data))
      assert {:error, _} = start_supervised({Store, name: nil, state_dir: dir})
    end
  end
end
