defmodule AtMcp.DirectServiceAuthTest do
  use ExUnit.Case, async: false

  test "direct reads retain home preference exceptions and exclude protocol operations" do
    previous = for key <- [:network, :appview_reads], do: {key, Application.get_env(:at_mcp, key)}

    on_exit(fn ->
      for {key, value} <- previous do
        if value,
          do: Application.put_env(:at_mcp, key, value),
          else: Application.delete_env(:at_mcp, key)
      end
    end)

    Application.put_env(:at_mcp, :appview_reads, :direct)
    Application.put_env(:at_mcp, :network, :delve)
    external = %ProtoRune.Atproto.Session{service_url: "https://external.example/xrpc"}
    hosted = %{external | service_url: "https://pds.delve.town/xrpc"}
    assert AtMcp.Network.direct_read?(AtMcp.Network.nsid("actor.getPreferences"), external)
    refute AtMcp.Network.direct_read?(AtMcp.Network.nsid("actor.getPreferences"), hosted)
    refute AtMcp.Network.direct_read?("com.atproto.repo.getRecord", external)
    Application.put_env(:at_mcp, :network, :bluesky)
    refute AtMcp.Network.direct_read?(AtMcp.Network.nsid("actor.getPreferences"), external)
  end

  @tag timeout: 90_000
  @tag skip: is_nil(System.get_env("MCP_CLIENT_PATH"))
  test "ordinary MCP reads with scoped service tokens without leaking home credentials" do
    paths = :code.get_path() |> Enum.flat_map(&["-pa", to_string(&1)])

    setup =
      AtMcp.Test.Settings.from_environment() <>
        "Application.put_env(:at_mcp, :network, :delve); Application.put_env(:at_mcp, :appview_reads, :direct); Req.default_options(adapter: AtMcp.TestDirectRouteAdapter); AtMcp.Stdio.run()"

    {output, code} =
      System.cmd("node", [Path.expand("../support/direct_service_auth_probe.mjs", __DIR__)],
        env: [
          {"TEST_EXTERNAL_COMMAND", System.find_executable("elixir")},
          {"TEST_EXTERNAL_ARGS", Jason.encode!(paths ++ ["-e", setup])}
        ],
        stderr_to_stdout: true
      )

    assert code == 0, output
    assert output =~ "direct_service_auth_passed"
  end
end
