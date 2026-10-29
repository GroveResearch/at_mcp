defmodule AtMcp.StdioTest do
  use ExUnit.Case, async: false

  @tag timeout: 90_000
  @tag skip: is_nil(System.get_env("MCP_CLIENT_PATH"))
  test "independent clients exercise client-launched accounts, ownership, quota and Unicode" do
    paths = :code.get_path() |> Enum.flat_map(&["-pa", to_string(&1)])

    {output, code} =
      System.cmd("node", [Path.expand("../support/stdio_sdk_probe.mjs", __DIR__)],
        env: [
          {"TEST_STDIO_RELEASE", "0"},
          {"TEST_MCP_COMMAND", System.find_executable("elixir")},
          {"TEST_MCP_ARGS",
           Jason.encode!(
             paths ++ ["-e", AtMcp.Test.Settings.from_environment() <> "AtMcp.Stdio.run()"]
           )}
        ],
        stderr_to_stdout: true
      )

    assert code == 0, output
    assert output =~ ~s("modern":"2026-07-28")
    # Derived, not pinned: a literal here would be a second place to update
    # when a tool is added, and it fails only in CI, where this probe is not
    # skipped. No tool lists an output schema. The account started with
    # AT_MCP_TOOLS=full is offered every tool the server declares, through
    # config/runtime.exs as a release reads it; the other, the default set.
    # Both are cut to what the network serves (`AtMcp.MCP.Served`).
    {:ok, declared, nil, :state} = AtMcp.MCP.Server.handle_list_tools(nil, :state)
    served = AtMcp.MCP.Served.offered(declared)
    default = Enum.count(served, &(&1.name in AtMcp.MCP.ToolSet.default()))
    assert output =~ ~s("output_schemas":0)

    assert output =~ ~s("listed":{"full":#{length(served)},"default":#{default}})

    assert output =~ ~s("structured_content":true)
    assert output =~ ~s("real_summaries":["get_timeline","get_thread"])
    assert output =~ ~s("iso_quota_reset":true)
    assert output =~ ~s("public_writes":0)
  end
end
