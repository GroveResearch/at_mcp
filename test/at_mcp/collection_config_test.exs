defmodule AtMcp.CollectionConfigTest do
  use ExUnit.Case, async: false

  setup do
    keys = ["AT_MCP_JETSTREAM", "AT_MCP_NOTIFICATIONS"]
    previous = Map.new(keys, &{&1, System.get_env(&1)})
    Enum.each(keys, &System.delete_env/1)

    on_exit(fn ->
      for {key, value} <- previous do
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end
    end)

    :ok
  end

  test "ordinary configuration collects account notifications without a network-wide stream" do
    config = Config.Reader.read!("config/config.exs", env: :dev)
    assert config[:at_mcp][:notifications_enabled] == true
    assert config[:at_mcp][:jetstream_enabled] == false
    assert config[:proto_rune][:retry] == false

    runtime = Config.Reader.read!("config/runtime.exs", env: :dev)
    assert runtime[:at_mcp][:notifications_enabled] == true
    assert runtime[:at_mcp][:jetstream_enabled] == false
  end

  test "runtime permits explicit stream opt-in and no collection" do
    for {on, off} <- [{"1", "0"}, {"true", "false"}] do
      System.put_env("AT_MCP_JETSTREAM", on)
      System.put_env("AT_MCP_NOTIFICATIONS", off)
      runtime = Config.Reader.read!("config/runtime.exs", env: :dev)
      assert runtime[:at_mcp][:jetstream_enabled] == true
      assert runtime[:at_mcp][:notifications_enabled] == false

      System.put_env("AT_MCP_JETSTREAM", off)
      runtime = Config.Reader.read!("config/runtime.exs", env: :dev)
      assert runtime[:at_mcp][:jetstream_enabled] == false
    end
  end
end
