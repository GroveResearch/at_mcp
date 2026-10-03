defmodule AtMcp.IdentitySupervisorRecoveryTest do
  use ExUnit.Case, async: false

  @tag :tmp_dir
  test "owner rebuilds configured and dynamic accounts, keeping disconnects and retrying login",
       %{
         tmp_dir: dir
       } do
    env =
      for key <- [
            "BLUESKY_HANDLE",
            "BLUESKY_APP_PASSWORD",
            "BLUESKY_HANDLE_2",
            "BLUESKY_APP_PASSWORD_2",
            "AT_MCP_HOST_TOKEN",
            "AT_MCP_HOST_TOKEN_FILE",
            "AT_MCP_DELIVERY_URL",
            "AT_MCP_ENV_FILE"
          ],
          do: {key, nil}

    {output, status} =
      System.cmd(
        "mix",
        [
          "run",
          "--no-start",
          Path.expand("../support/identity_supervisor_recovery.exs", __DIR__),
          dir
        ],
        env: [{"MIX_ENV", "test"} | env],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output =~ "identity-supervisor-recovery-passed"
  end
end
