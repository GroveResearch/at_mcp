defmodule AtMcp.MCP.GrantWatchTest do
  @moduledoc """
  An open stream outlives the request that opened it, so it is watched: it is
  closed once its grant is revoked or expires, and kept while the grant lives.
  """
  use ExUnit.Case, async: false

  defp stream, do: spawn(fn -> Process.sleep(:infinity) end)

  test "a stream whose grant is revoked is closed; one whose grant lives is kept" do
    {:ok, kept} = AtMcp.Grants.issue("nobody-here")
    {:ok, revoked} = AtMcp.Grants.issue("nobody-here")
    on_exit(fn -> AtMcp.Grants.revoke(kept.token) end)

    live = stream()
    gone = stream()
    live_ref = Process.monitor(live)
    gone_ref = Process.monitor(gone)
    AtMcp.MCP.HTTP.watch_grant(live, kept.token, 20)
    AtMcp.MCP.HTTP.watch_grant(gone, revoked.token, 20)

    Process.sleep(100)
    assert Process.alive?(live) and Process.alive?(gone)

    :ok = AtMcp.Grants.revoke(revoked.token)
    assert_receive {:DOWN, ^gone_ref, :process, ^gone, :killed}, 1_000
    refute_receive {:DOWN, ^live_ref, _, _, _}, 200
    Process.exit(live, :kill)
  end

  test "the watcher ends with its stream" do
    {:ok, grant} = AtMcp.Grants.issue("nobody-here")
    on_exit(fn -> AtMcp.Grants.revoke(grant.token) end)
    s = stream()
    watcher = AtMcp.MCP.HTTP.watch_grant(s, grant.token, 20)
    ref = Process.monitor(watcher)
    Process.exit(s, :kill)
    assert_receive {:DOWN, ^ref, :process, ^watcher, :normal}, 1_000
  end
end
