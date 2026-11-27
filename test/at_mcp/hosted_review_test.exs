defmodule AtMcp.HostedReviewTest do
  @moduledoc """
  Review of the hosted-agent mode (feat/agent-state). Each test states the
  behaviour a network endpoint needs and fails on 80fd18d.
  """
  use ExUnit.Case, async: false
  alias AtMcp.MCP.GrantAttempts

  # A grant's scope bounds what its holder can do. approve_app_sign_in lets
  # the holder sign an outside app in as the account with any scope the app
  # asks for (transition:generic, rpc: agent control, ...), so a `write`
  # grant would hand out more than `write`. The guide recommends `write` for
  # a hosted platform.
  test "approving an app's sign-in needs a manage grant" do
    refute AtMcp.Grants.permits_scope?(:write, "approve_app_sign_in")
    refute AtMcp.Grants.permits_scope?(:read, "approve_app_sign_in")
  end

  # Hosted agent platforms share egress addresses. Anyone else sending from
  # the same address (another tenant) can present 10 bad grants a minute and
  # keep a valid grant from that address refused. Grants are 256-bit random,
  # so refusing a valid one buys nothing against guessing.
  test "failed presentations by others from the same address don't refuse a valid grant" do
    Application.put_env(:at_mcp, :grant_failures_per_minute, 3)
    on_exit(fn -> Application.delete_env(:at_mcp, :grant_failures_per_minute) end)

    {:ok, good} =
      AtMcp.Grants.issue("nobody-here",
        path: Path.join(System.tmp_dir!(), "hr-#{System.unique_integer([:positive])}.grants.json")
      )

    shared = "198.51.100.#{rem(System.unique_integer([:positive]), 250) + 1}"
    for _ <- 1..3, do: GrantAttempts.failed(shared)

    conn =
      Plug.Test.conn(:post, "/mcp", "{}")
      |> Map.put(:remote_ip, {127, 0, 0, 1})
      |> Plug.Conn.put_req_header("x-forwarded-for", shared)
      |> Plug.Conn.put_req_header("authorization", "Bearer " <> good.token)
      |> AtMcp.MCP.HTTP.call(AtMcp.MCP.HTTP.init(effects: :unused, port: 4499))

    refute conn.status == 429
  end
end
