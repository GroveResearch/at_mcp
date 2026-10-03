defmodule AtMcp.Deliver.HTTPBridgeTest do
  use ExUnit.Case, async: false

  alias AtMcp.Deliver.HTTPBridge

  setup do
    AtMcp.Deliver.clear_callback()

    on_exit(fn ->
      AtMcp.Deliver.clear_callback()
      System.delete_env("AT_MCP_DELIVERY_URL")
      System.delete_env("AT_MCP_DELIVERY_TOKEN")
      System.delete_env("AT_MCP_DELIVERY_TOKEN_FILE")
      System.delete_env("AT_MCP_JETSTREAM")
      System.delete_env("AT_MCP_NOTIFICATIONS")
    end)

    :ok
  end

  test "maybe_attach_from_env! skips when AT_MCP_DELIVERY_URL unset" do
    System.delete_env("AT_MCP_DELIVERY_URL")
    assert :skipped = HTTPBridge.maybe_attach_from_env!()
    assert is_nil(AtMcp.Deliver.callback())
  end

  test "maybe_attach_from_env! fails closed when no collector is enabled" do
    System.put_env("AT_MCP_DELIVERY_URL", "http://127.0.0.1:9/inbound")
    System.put_env("AT_MCP_DELIVERY_TOKEN", "test-token")
    System.put_env("AT_MCP_JETSTREAM", "0")
    System.put_env("AT_MCP_NOTIFICATIONS", "0")

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
    System.put_env("AT_MCP_DELIVERY_URL", "http://127.0.0.1:9/inbound")
    System.put_env("AT_MCP_DELIVERY_TOKEN", "test-token")
    System.put_env("AT_MCP_JETSTREAM", "0")
    System.put_env("AT_MCP_NOTIFICATIONS", "1")

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

    previous = System.get_env("AT_MCP_DELIVERY_TOKEN_FILE")
    System.put_env("AT_MCP_DELIVERY_TOKEN_FILE", path)
    System.delete_env("AT_MCP_DELIVERY_TOKEN")

    on_exit(fn ->
      File.rm_rf!(path)

      if previous,
        do: System.put_env("AT_MCP_DELIVERY_TOKEN_FILE", previous),
        else: System.delete_env("AT_MCP_DELIVERY_TOKEN_FILE")
    end)

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
