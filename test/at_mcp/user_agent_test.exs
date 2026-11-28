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

  test "AT_MCP_CA_FILE makes every request trust that bundle; unset, the system's" do
    previous = Application.get_env(:at_mcp, :ca_file)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:at_mcp, :ca_file, previous),
        else: Application.delete_env(:at_mcp, :ca_file)

      AtMcp.UserAgent.install()
    end)

    Application.delete_env(:at_mcp, :ca_file)
    assert AtMcp.UserAgent.ca_options() == []

    Application.put_env(:at_mcp, :ca_file, "/stack/bundle.pem")
    :ok = AtMcp.UserAgent.install()

    assert Req.default_options()[:connect_options][:transport_opts][:cacertfile] ==
             "/stack/bundle.pem"

    assert Req.default_options()[:user_agent] == AtMcp.UserAgent.value()
  end
end
