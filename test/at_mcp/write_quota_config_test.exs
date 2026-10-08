defmodule AtMcp.WriteQuotaConfigTest do
  use ExUnit.Case, async: false

  @keys ["AT_MCP_WRITE_LIMIT", "AT_MCP_WRITE_WINDOW_SECONDS"]

  setup do
    previous = Map.new(@keys, &{&1, System.get_env(&1)})
    Enum.each(@keys, &System.delete_env/1)

    on_exit(fn ->
      for {key, value} <- previous do
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end
    end)

    :ok
  end

  # A release reads config/runtime.exs at boot; this is that read.
  defp runtime, do: Config.Reader.read!("config/runtime.exs", env: :prod)

  test "unset variables leave the write quota at its defaults" do
    assert runtime()[:at_mcp][:write_quota] == nil

    dir =
      Path.join(System.tmp_dir!(), "at_mcp-quota-default-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(dir) end)
    quota = start_supervised!({AtMcp.WriteQuota, name: nil, state_dir: dir})
    assert %{limit: 16, window_seconds: 3600} = AtMcp.WriteQuota.status(quota, "did:plc:a")
  end

  test "the variables set the limit and window the quota enforces and reports" do
    System.put_env("AT_MCP_WRITE_LIMIT", "2")
    System.put_env("AT_MCP_WRITE_WINDOW_SECONDS", "60")
    config = runtime()[:at_mcp][:write_quota]
    assert config == [limit: 2, window_seconds: 60]

    dir =
      Path.join(System.tmp_dir!(), "at_mcp-quota-config-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(dir) end)

    quota =
      start_supervised!(
        {AtMcp.WriteQuota, [name: nil, state_dir: dir, clock: fn -> 1000 end] ++ config}
      )

    assert :ok = AtMcp.WriteQuota.reserve(quota, "did:plc:a")
    assert :ok = AtMcp.WriteQuota.reserve(quota, "did:plc:a")
    assert {:error, {:write_quota_exhausted, 1060}} = AtMcp.WriteQuota.reserve(quota, "did:plc:a")

    assert %{limit: 2, window_seconds: 60, used: 2} = AtMcp.WriteQuota.status(quota, "did:plc:a")
  end

  test "one variable alone changes only its own setting" do
    System.put_env("AT_MCP_WRITE_LIMIT", "40")
    assert runtime()[:at_mcp][:write_quota] == [limit: 40]
  end

  test "a value that is not a positive integer refuses to start, naming the variable" do
    for name <- @keys, bad <- ["0", "-1", "ten", "1.5", "16 ", ""] do
      System.put_env(name, bad)

      error = assert_raise ArgumentError, fn -> runtime() end
      assert error.message =~ name

      System.delete_env(name)
    end
  end
end
