defmodule AtMcp.MCP.GrantAttemptsTest do
  @moduledoc """
  The limit on failed grant presentations: after the limit, a source is
  refused for the rest of the minute, a valid grant included, and the
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

  test "the endpoint answers 429 to a source past the limit, a good grant included", ctx do
    {:ok, good} =
      AtMcp.Grants.issue("nobody-here",
        path: Path.join(System.tmp_dir!(), "ga-#{System.unique_integer([:positive])}.grants.json")
      )

    for _ <- 1..3, do: GrantAttempts.failed("127.0.0.1")
    on_exit(fn -> :ets.delete(AtMcp.MCP.GrantAttempts, "127.0.0.1") end)

    conn =
      Plug.Test.conn(:post, "/mcp", "{}")
      |> Map.put(:remote_ip, {127, 0, 0, 1})
      |> Plug.Conn.put_req_header("authorization", "Bearer " <> good.token)
      |> AtMcp.MCP.HTTP.call(AtMcp.MCP.HTTP.init(effects: :unused, port: 4499))

    assert conn.status == 429
    assert Jason.decode!(conn.resp_body)["error"] == "too_many_failed_grants"
    _ = ctx
  end
end
