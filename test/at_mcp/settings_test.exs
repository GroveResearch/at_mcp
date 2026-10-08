defmodule AtMcp.SettingsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  # A release reads config/runtime.exs at boot; this is that read, given only
  # the variables a test names.
  defp boot(env) do
    saved =
      for {name, value} <- System.get_env(), name =~ ~r/^(AT_MCP|BLUESKY)_/, do: {name, value}

    Enum.each(saved, fn {name, _} -> System.delete_env(name) end)
    System.put_env(env)

    try do
      Config.Reader.read!("config/runtime.exs", env: :prod)[:at_mcp]
    after
      Enum.each(env, fn {name, _} -> System.delete_env(name) end)
      System.put_env(saved)
    end
  end

  test "with nothing set, every setting has its default" do
    config = boot(%{})
    assert config[:mcp_port] == 4400
    assert config[:notifications_enabled] == true
    assert config[:jetstream_enabled] == false
    assert {"AT_MCP_DELIVERY_TOKEN", "unset", :default} in config[:settings]
  end

  test "a bad value refuses to start, naming the variable" do
    error = assert_raise ArgumentError, fn -> boot(%{"AT_MCP_WRITE_LIMIT" => "ten"}) end
    assert error.message =~ "AT_MCP_WRITE_LIMIT must be a positive integer"
  end

  test "an unknown AT_MCP_ variable refuses to start, suggesting the closest setting" do
    error = assert_raise ArgumentError, fn -> boot(%{"AT_MCP_WRITE_LIMT" => "4"}) end
    assert error.message =~ "AT_MCP_WRITE_LIMT is not an AtMcp setting"
    assert error.message =~ "did you mean AT_MCP_WRITE_LIMIT?"
  end

  test "an old account variable still works, with a warning, and a secret is never shown" do
    env = %{"BLUESKY_HANDLE" => "agent.test", "AT_MCP_APP_PASSWORD" => "private-fixture"}

    stderr =
      capture_io(:stderr, fn ->
        config = boot(env)

        assert config[:env_accounts][:default] == [
                 handle: "agent.test",
                 password: "private-fixture"
               ]

        assert {"AT_MCP_HANDLE", "agent.test", "BLUESKY_HANDLE"} in config[:settings]
        assert {"AT_MCP_APP_PASSWORD", "set", "AT_MCP_APP_PASSWORD"} in config[:settings]
        refute inspect(config[:settings]) =~ "private-fixture"
      end)

    assert stderr =~ "BLUESKY_HANDLE is deprecated; rename it AT_MCP_HANDLE"
  end
end
