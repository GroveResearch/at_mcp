defmodule AtMcp.MCP.HTTPClientTest do
  @moduledoc """
  Interoperability of the loopback HTTP endpoint with an independent client.

  A fixture proves mechanics; this proves that a client nobody here wrote can
  attach to one identity of a shared endpoint with the grant it was given, read
  the tool surface, write, and be stopped by the account's own write quota — and
  that the same URL with another identity's grant, or with none, reaches neither.
  """
  use ExUnit.Case, async: false

  setup do
    dir = Path.join(System.tmp_dir!(), "at_mcp-http-quota-#{System.unique_integer([:positive])}")
    quota = start_supervised!({AtMcp.WriteQuota, name: nil, state_dir: dir, limit: 1})
    on_exit(fn -> File.rm_rf!(dir) end)

    accounts =
      for id <- ["alice", "bob"] do
        {:ok, _} =
          AtMcp.Identities.start_identity(
            id: "http-#{id}",
            listen_enabled: false,
            backend: AtMcp.Test.MockBackend,
            backend_state: %{did: "did:plc:#{id}"},
            expected_did: "did:plc:#{id}",
            write_quota: quota
          )

        on_exit(fn -> AtMcp.Identities.stop_identity("http-#{id}") end)
        {AtMcp.Test.Grant.token("http-#{id}"), "did:plc:#{id}"}
      end

    {:ok, accounts: accounts}
  end

  @tag skip:
         if(is_nil(System.get_env("MCP_SDK_PATH")),
           do: "set MCP_SDK_PATH to an installed @modelcontextprotocol/sdk (tested with 1.29.0)",
           else: false
         )
  test "independent TypeScript MCP SDK calls tools without an ACP host", %{accounts: accounts} do
    [{alice_grant, alice_did}, {bob_grant, _bob_did}] = accounts

    {output, status} =
      System.cmd(
        System.find_executable("node"),
        [
          Path.expand("../support/mcp_sdk_probe.mjs", __DIR__),
          AtMcp.Test.Grant.url(),
          alice_grant,
          alice_did,
          bob_grant
        ],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output =~ ~s("passed":true)
    assert output =~ ~s("one_endpoint":true)
    assert output =~ ~s("credential_required":true)
  end
end
