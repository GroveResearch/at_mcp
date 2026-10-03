defmodule AtMcp.Application do
  @moduledoc false

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    :ok = AtMcp.Rename.check_application!()
    # An installation configured only by BLUESKY_* writes itself the accounts
    # file it is missing, then runs the one configured path like any other.
    :ok = AtMcp.Identities.bootstrap_configuration!()

    # Validate the configuration before any listener can bind or login.
    _ = AtMcp.Identities.env_identity_specs()

    quota_dir =
      Application.get_env(:at_mcp, :write_quota, [])
      |> Keyword.get_lazy(:state_dir, &AtMcp.Inbound.Store.default_dir/0)

    with {:ok, dirs} <-
           AtMcp.StateLock.acquire_all([AtMcp.Inbound.Store.default_dir(), quota_dir]) do
      case start_runtime() do
        {:ok, pid} ->
          {:ok, pid, dirs}

        error ->
          Enum.each(dirs, &AtMcp.StateLock.release/1)
          error
      end
    end
  end

  @impl true
  def stop(dirs) do
    Enum.each(dirs, &AtMcp.StateLock.release/1)
    :ok
  end

  # Operator HTTP is opt-in: an installation that was never told a port does not
  # open one. Loopback only, as the MCP endpoints are.
  defp control_children(nil), do: []

  defp control_children(port) when is_integer(port) do
    [
      Plug.Cowboy.child_spec(
        scheme: :http,
        plug: AtMcp.Control,
        options: [port: port, ip: {127, 0, 0, 1}, ref: :at_mcp_control_http]
      )
    ]
  end

  # One MCP endpoint for every identity. Which identity a request reaches is
  # decided by the grant it presents, so there is nothing per-account to bind
  # and nothing to start per account. Opt out with `start_mcp: false`, which is
  # what the single-account stdio launcher does.
  defp mcp_children do
    if Application.get_env(:at_mcp, :start_mcp, true) do
      port = Application.get_env(:at_mcp, :mcp_port, 4400)

      [
        Plug.Cowboy.child_spec(
          scheme: :http,
          plug: {AtMcp.MCP.HTTP, port: port},
          options: [port: port, ip: {127, 0, 0, 1}, ref: :at_mcp_http]
        )
      ]
    else
      []
    end
  end

  defp start_runtime do
    children =
      [
        {Registry, keys: :unique, name: AtMcp.Identity.Registry},
        {Registry, keys: :duplicate, name: AtMcp.Listen.Registry},
        {AtMcp.Inbound.Store, []},
        {AtMcp.WriteQuota, Application.get_env(:at_mcp, :write_quota, [])},
        # Shared Jetstream inbound ears — N identities track DIDs onto this one WS.
        {AtMcp.Inbound, name: AtMcp.Inbound},
        # N identities (Effects + Listen + optional MCP) — never communal login.
        {AtMcp.Identities, []},
        {Task.Supervisor, name: AtMcp.Accounts.TaskSupervisor},
        {AtMcp.Accounts, []}
      ] ++
        mcp_children() ++ control_children(Application.get_env(:at_mcp, :control_port))

    opts = [strategy: :one_for_one, name: AtMcp.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        result =
          with :ok <- AtMcp.Identities.boot_from_env!(),
               :ok <- AtMcp.Accounts.await_initialization() do
            if AtMcp.Identities.boot_from_env?(),
              do: AtMcp.Deliver.HTTPBridge.maybe_attach_from_env!(),
              else: :ok
          end

        case result do
          :ok ->
            {:ok, pid}

          :skipped ->
            {:ok, pid}

          {:error, reason} ->
            Logger.error("AtMcp startup failed: #{inspect(reason)}")

            # Fail-closed: tear down half-boot (e.g. eaddrinuse MCP + empty Identities).
            _ = Supervisor.stop(pid, :normal, 5_000)
            {:error, reason}
        end

      other ->
        other
    end
  end
end
