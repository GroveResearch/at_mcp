defmodule AtMcp.Deliver.HTTPBridgeTest do
  use ExUnit.Case, async: false

  alias AtMcp.Deliver.HTTPBridge

  setup do
    AtMcp.Deliver.clear_callback()

    on_exit(fn -> AtMcp.Deliver.clear_callback() end)

    :ok
  end

  test "maybe_attach_from_env! skips when no delivery URL is set" do
    AtMcp.Test.Settings.put(delivery: [])
    assert :skipped = HTTPBridge.maybe_attach_from_env!()
    assert is_nil(AtMcp.Deliver.callback())
  end

  test "maybe_attach_from_env! fails closed when no collector is enabled" do
    AtMcp.Test.Settings.put(
      delivery: [url: "http://127.0.0.1:9/inbound", token: "test-token"],
      jetstream_enabled: false,
      notifications_enabled: false
    )

    # No collection at all can never deliver anything, so this is the one
    # configuration attaching refuses; host reachability is the outbox's job.
    assert {:error, {:delivery_bridge_unready, [:no_inbound_collector]}} =
             HTTPBridge.maybe_attach_from_env!()

    assert is_nil(AtMcp.Deliver.callback())
  end

  # A network with no firehose has only the notification poll, which goes through
  # the account's own PDS. Either collector is enough to attach, so such an
  # installation boots with the collector it has.
  test "the notification poll is a collector, so a network without a firehose delivers" do
    AtMcp.Test.Settings.put(
      delivery: [url: "http://127.0.0.1:9/inbound", token: "test-token"],
      jetstream_enabled: false,
      notifications_enabled: true
    )

    assert :ok = HTTPBridge.maybe_attach_from_env!()
    assert is_function(AtMcp.Deliver.callback(), 1)

    # Callback must not crash the Deliver path on connection failure.
    assert {:error, _} =
             AtMcp.Deliver.callback().(%{source: :inbound, matched_did: "did:plc:test"})
  end

  # This drives the callback the bridge itself registers and asserts the
  # credential that reaches the wire. Checking that `access_token/0` re-reads
  # the file would not show whether the delivery path does.
  test "a rotated access token reaches the next delivery" do
    parent = self()
    ref = make_ref()

    {:ok, server} =
      Plug.Cowboy.http(AtMcp.Test.TokenEchoPlug, {parent, ref}, ip: {127, 0, 0, 1}, port: 0)

    port = :ranch.get_port(AtMcp.Test.TokenEchoPlug.HTTP)
    on_exit(fn -> Plug.Cowboy.shutdown(AtMcp.Test.TokenEchoPlug.HTTP) end)
    assert is_pid(server)

    path = Path.join(System.tmp_dir!(), "consumer-token-#{System.unique_integer([:positive])}")
    File.write!(path, "first-token")

    AtMcp.Test.Settings.put(delivery: [token_file: path])
    on_exit(fn -> File.rm_rf!(path) end)

    # The callback the bridge registers, not a second copy of what it does.
    deliver = HTTPBridge.callback("http://127.0.0.1:#{port}/inbound")
    event = %{matched_did: "did:plc:token", source: :inbound, kind: :inbound_mention}

    deliver.(event)
    assert_receive {^ref, "Bearer first-token"}, 2_000

    File.write!(path, "rotated-token")

    deliver.(event)
    assert_receive {^ref, "Bearer rotated-token"}, 2_000
  end
end
