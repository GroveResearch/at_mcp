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

  appview_reads =
    case System.get_env("AT_MCP_APPVIEW_READS") do
      nil -> Application.get_env(:at_mcp, :appview_reads, :proxy)
      "proxy" -> :proxy
      "direct" -> :direct
      other -> raise ArgumentError, "unknown AT_MCP_APPVIEW_READS #{inspect(other)}"
    end

  # The account write quota. Unset keeps `AtMcp.WriteQuota`'s defaults (16
  # publishing writes per 3600 seconds); a value that is not a positive integer
  # refuses to start rather than falling back, naming the variable.
  positive_integer = fn name ->
    case System.get_env(name) do
      nil ->
        nil

      value ->
        case Integer.parse(value) do
          {n, ""} when n > 0 ->
            n

          _ ->
            raise ArgumentError,
                  "#{name} must be a positive integer, got #{inspect(value)}"
        end
    end
  end

  write_quota =
    [
      limit: positive_integer.("AT_MCP_WRITE_LIMIT"),
      window_seconds: positive_integer.("AT_MCP_WRITE_WINDOW_SECONDS")
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)

  jetstream = System.get_env("AT_MCP_JETSTREAM", "0") in ["1", "true"]
  notifications = System.get_env("AT_MCP_NOTIFICATIONS", "1") not in ["0", "false"]

  config :at_mcp,
    network: network,
    appview_reads: appview_reads,
    mcp_port: port,
    control_port: control_port,
    jetstream_enabled: jetstream,
    notifications_enabled: notifications

  if write_quota != [], do: config(:at_mcp, write_quota: write_quota)
end
