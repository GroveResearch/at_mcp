defmodule AtMcp.MCP.GrantAttemptsTest do
  @moduledoc """
  The limit on failed grant presentations: after the limit, a source is
  refused for the rest of the minute while a valid grant is still served, and the
  source behind a proxy on the same machine is the address it forwards.
  """
  use ExUnit.Case, async: false
  alias AtMcp.MCP.GrantAttempts

  setup do
    Application.put_env(:at_mcp, :grant_failures_per_minute, 3)
    on_exit(fn -> Application.delete_env(:at_mcp, :grant_failures_per_minute) end)
    %{source: "203.0.113.#{System.unique_integer([:positive])}"}
  end

  test "a source past the limit waits out the minute", ctx do
    assert GrantAttempts.check(ctx.source) == :ok
    for _ <- 1..3, do: GrantAttempts.failed(ctx.source)
    assert {:wait, seconds} = GrantAttempts.check(ctx.source)
    assert seconds in 1..60
    # Another source is not held up by it.
    assert GrantAttempts.check(ctx.source <> "1") == :ok
  end

  test "behind a proxy on loopback the source is the address it forwards; elsewhere, the connection's" do
    proxied =
      Plug.Test.conn(:post, "/mcp")
      |> Map.put(:remote_ip, {127, 0, 0, 1})
      |> Plug.Conn.put_req_header("x-forwarded-for", "198.51.100.7, 10.0.0.1")

    assert GrantAttempts.source(proxied) == "198.51.100.7"

    # A header from a client that isn't the proxy counts for nothing.
    direct =
      Plug.Test.conn(:post, "/mcp")
      |> Map.put(:remote_ip, {192, 0, 2, 5})
      |> Plug.Conn.put_req_header("x-forwarded-for", "198.51.100.7")

    assert GrantAttempts.source(direct) == "192.0.2.5"
  end

  test "an IPv6 source counts by its /64, and a source whose minute is out is forgotten" do
    v6 =
      Plug.Test.conn(:post, "/mcp")
      |> Map.put(:remote_ip, {0x2001, 0xDB8, 1, 2, 3, 4, 5, 6})

    other_in_64 = Map.put(v6, :remote_ip, {0x2001, 0xDB8, 1, 2, 9, 9, 9, 9})
    assert GrantAttempts.source(v6) == "2001:db8:1:2::/64"
    assert GrantAttempts.source(other_in_64) == GrantAttempts.source(v6)

    old = "192.0.2.#{rem(System.unique_integer([:positive]), 250) + 1}"
    :ets.insert(GrantAttempts, {old, 9, System.monotonic_time(:millisecond) - 120_000})
    GrantAttempts.failed("192.0.2.254")
    assert :ets.lookup(GrantAttempts, old) == []
  end

  test "past the limit a source's bad grants are answered 429, and a good one is still served",
       ctx do
    {:ok, good} = AtMcp.Grants.issue("nobody-here")
    on_exit(fn -> AtMcp.Grants.revoke(good.token) end)
    for _ <- 1..3, do: GrantAttempts.failed("127.0.0.1")
    on_exit(fn -> :ets.delete(AtMcp.MCP.GrantAttempts, "127.0.0.1") end)
    plug = AtMcp.MCP.HTTP.init(effects: :unused, port: 4499)

    call = fn token ->
      Plug.Test.conn(:post, "/mcp", "{}")
      |> Map.put(:remote_ip, {127, 0, 0, 1})
      |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
      |> AtMcp.MCP.HTTP.call(plug)
    end

    bad = call.("at_mcp-wrong")
    assert bad.status == 429
    assert Jason.decode!(bad.resp_body)["error"] == "too_many_failed_grants"

    served = call.(good.token)
    assert Jason.decode!(served.resp_body)["error"] == "account_unavailable"
    _ = ctx
  end
end
