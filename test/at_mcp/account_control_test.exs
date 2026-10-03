defmodule AtMcp.AccountControlTest do
  use ExUnit.Case, async: true

  test "fixed release RPC safely carries an arbitrary account name and preserves failure" do
    id = "account\"; System.halt(); #"

    assert {:ok, %{"ok" => false, "error" => "unknown_account"}} =
             AtMcp.AccountControl.execute(["disconnect", id],
               release_root: "/tmp/release with spaces",
               rpc: fn command, args, options ->
                 assert command == "/tmp/release with spaces/bin/at_mcp"

                 assert args == [
                          "rpc",
                          "AtMcp.CLI.account(\"disconnect\", #{inspect(Base.encode64(id))})"
                        ]

                 assert options == [stderr_to_stdout: true]
                 {"diagnostic\n{\"ok\":false,\"error\":\"unknown_account\"}\n", 0}
               end
             )
  end

  test "rejects ambiguous output and never returns raw failed RPC diagnostics" do
    for {output, status, expected} <- [
          {"{\"ok\":true}\n{\"ok\":false}\n", 0, :invalid_response},
          {"private backend details", 1, :unavailable}
        ] do
      assert {:error, ^expected} =
               AtMcp.AccountControl.execute(["status"],
                 release_root: "/tmp/at_mcp",
                 rpc: fn _, _, _ -> {output, status} end
               )
    end
  end

  test "invalid commands never invoke RPC" do
    for args <- [["reload", "other-file"], ["disconnect"], ["status", "--file", "x"]] do
      assert {:error, :usage} =
               AtMcp.AccountControl.execute(args,
                 rpc: fn _, _, _ -> flunk("unexpected RPC") end
               )
    end
  end
end
