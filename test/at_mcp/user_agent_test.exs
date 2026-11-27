defmodule AtMcp.UserAgentTest do
  @moduledoc """
  Every request AtMcp sends names it: `at_mcp/<version>`, so a service's logs
  show at_mcp use exactly.
  """
  use ExUnit.Case, async: false

  test "a request AtMcp sends through Req carries at_mcp/<version>" do
    :ok = AtMcp.UserAgent.install()
    owner = self()

    plug = fn conn ->
      send(owner, {:user_agent, Plug.Conn.get_req_header(conn, "user-agent")})
      Plug.Conn.send_resp(conn, 200, "{}")
    end

    {:ok, _} = Req.get("http://pds.invalid/xrpc/_health", plug: plug, retry: false)
    assert_receive {:user_agent, [agent]}
    assert agent == AtMcp.UserAgent.value()
    assert agent =~ ~r{\Aat_mcp/\d+\.\d+\.\d+}

    # proto_rune's own adapter goes through Req too.
    {:ok, _} = ProtoRune.HTTPClient.Adapters.Req.request(:get, "http://pds.invalid/x", plug: plug)
    assert_receive {:user_agent, [^agent]}
  end
end
