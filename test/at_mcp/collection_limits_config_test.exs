defmodule AtMcp.CollectionLimitsConfigTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir
  @keys [
    "AT_MCP_INBOUND_MAX_EVENTS",
    "AT_MCP_INBOUND_MAX_BYTES",
    "AT_MCP_NOTIFICATIONS_INTERVAL_SECONDS"
  ]

  setup do
    previous = Map.new(@keys, &{&1, System.get_env(&1)})
    Enum.each(@keys, &System.delete_env/1)

    on_exit(fn ->
      Application.delete_env(:at_mcp, :inbound_store)

      for {key, value} <- previous do
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end
    end)

    :ok
  end

  # A release reads config/runtime.exs at boot; this is that read.
  defp runtime, do: Config.Reader.read!("config/runtime.exs", env: :prod)[:at_mcp]

  defp event(n, did),
    do: %{source: :inbound, matched_did: did, uri: "at://did:plc:author/app.bsky.feed.post/#{n}"}

  test "unset variables leave the store and the poll at their defaults" do
    config = runtime()
    assert config[:inbound_store] == nil
    assert config[:notifications_interval_ms] == nil
  end

  test "the event limit is the per-account queue length the store holds", %{tmp_dir: dir} do
    System.put_env("AT_MCP_INBOUND_MAX_EVENTS", "2")
    System.put_env("AT_MCP_INBOUND_MAX_BYTES", "1048576")
    config = runtime()[:inbound_store]
    assert config == [max_pending: 2, max_bytes: 1_048_576]
    Application.put_env(:at_mcp, :inbound_store, config)

    store = start_supervised!({AtMcp.Inbound.Store, name: nil, state_dir: dir})
    assert {:ok, [_, _]} = AtMcp.Inbound.Store.accept(store, [event(1, "a"), event(2, "a")], 1)
    assert {:error, :full} = AtMcp.Inbound.Store.accept(store, [event(3, "a")], 2)
    # Another account's lane has its own room.
    assert {:ok, [_]} = AtMcp.Inbound.Store.accept(store, [event(4, "b")], 3)
  end

  test "the byte limit bounds the store file", %{tmp_dir: dir} do
    System.put_env("AT_MCP_INBOUND_MAX_BYTES", "2000")
    Application.put_env(:at_mcp, :inbound_store, runtime()[:inbound_store])

    store = start_supervised!({AtMcp.Inbound.Store, name: nil, state_dir: dir})
    big = Map.put(event(1, "a"), :text, String.duplicate("x", 3_000))
    assert {:error, :full} = AtMcp.Inbound.Store.accept(store, [big], 1)
  end

  test "the poll interval is read in seconds" do
    System.put_env("AT_MCP_NOTIFICATIONS_INTERVAL_SECONDS", "15")
    assert runtime()[:notifications_interval_ms] == 15_000
  end

  test "a value that is not a positive integer refuses to start, naming the variable" do
    for name <- @keys, bad <- ["0", "-1", "ten", "1.5", "60 ", ""] do
      System.put_env(name, bad)

      error = assert_raise ArgumentError, fn -> runtime() end
      assert error.message =~ name

      System.delete_env(name)
    end
  end
end
