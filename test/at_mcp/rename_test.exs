defmodule AtMcp.RenameTest do
  use ExUnit.Case, async: false

  test "old configuration is rejected with the exact replacement, never its secret value" do
    previous = System.get_env("KITE_MCP_PORT")
    System.put_env("KITE_MCP_PORT", "secret-value")

    on_exit(fn ->
      if previous,
        do: System.put_env("KITE_MCP_PORT", previous),
        else: System.delete_env("KITE_MCP_PORT")
    end)

    error = assert_raise ArgumentError, &AtMcp.Rename.check_environment!/0
    assert error.message =~ "KITE_MCP_PORT was renamed to AT_MCP_PORT"
    refute error.message =~ "secret-value"
  end

  test "the old embedded application configuration cannot silently select new default state" do
    old = Application.fetch_env(:kite, :inbound_state_dir)
    Application.put_env(:kite, :inbound_state_dir, "/private/fixture-old-state")

    on_exit(fn ->
      case old do
        {:ok, value} -> Application.put_env(:kite, :inbound_state_dir, value)
        :error -> Application.delete_env(:kite, :inbound_state_dir)
      end
    end)

    error = assert_raise ArgumentError, fn -> AtMcp.Application.start(:normal, []) end
    assert error.message =~ "config :kite was renamed to config :at_mcp"
    refute error.message =~ "/private/fixture-old-state"
  end

  test "unrelated application configuration does not trigger the transition guard" do
    Application.put_env(:kite, :unrelated_package_option, true)
    on_exit(fn -> Application.delete_env(:kite, :unrelated_package_option) end)
    assert :ok = AtMcp.Rename.check_application!()
  end

  test "old default data requires an explicit path; a fresh install uses the new path" do
    root = Path.join(System.tmp_dir!(), "at-mcp-rename-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    old = Path.join(root, "kite/inbound")
    new = Path.join(root, "at_mcp/inbound")
    assert AtMcp.Rename.default_path(new, old, "AT_MCP_STATE_DIR") == new
    File.mkdir_p!(old)

    error =
      assert_raise ArgumentError, fn ->
        AtMcp.Rename.default_path(new, old, "AT_MCP_STATE_DIR")
      end

    assert error.message =~ "AT_MCP_STATE_DIR=#{old}"
    refute File.exists?(new)
  end
end
