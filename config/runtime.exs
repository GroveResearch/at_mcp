import Config

if config_env() != :test, do: AtMcp.Rename.check_environment!()

if config_env() != :test and Application.get_env(:at_mcp, :boot_from_env, true) do
  port =
    case System.get_env("AT_MCP_PORT") do
      nil -> Application.get_env(:at_mcp, :mcp_port, 4400)
      s -> String.to_integer(s)
    end

  control_port =
    case System.get_env("AT_MCP_CONTROL_PORT") do
      nil -> nil
      s -> String.to_integer(s)
    end

  # Which network. An unknown name is left as the atom it was written as, so
  # `AtMcp.Network` raises with the name the operator typed rather than this file
  # silently choosing Bluesky for them.
  network =
    case System.get_env("AT_MCP_NETWORK") do
      nil -> Application.get_env(:at_mcp, :network, :bluesky)
      name -> String.to_atom(name)
    end

  jetstream = System.get_env("AT_MCP_JETSTREAM", "0") in ["1", "true"]
  notifications = System.get_env("AT_MCP_NOTIFICATIONS", "1") not in ["0", "false"]

  config :at_mcp,
    network: network,
    mcp_port: port,
    control_port: control_port,
    jetstream_enabled: jetstream,
    notifications_enabled: notifications
end
