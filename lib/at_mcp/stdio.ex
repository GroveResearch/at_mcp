defmodule AtMcp.Stdio do
  @moduledoc "Client-launched MCP process for one account, using the standard streams."

  def run do
    # Release eval does not start AtMcp. Redirect diagnostics before starting any
    # dependency; stdout belongs exclusively to the MCP transport.
    {:ok, log_config} = :logger.get_handler_config(:default)
    :ok = :logger.remove_handler(:default)

    :ok =
      :logger.add_handler(
        :default,
        :logger_std_h,
        log_config |> Map.drop([:id, :module]) |> put_in([:config, :type], :standard_error)
      )

    Process.flag(:trap_exit, true)
    # Startup failures can contain backend responses or supervisor arguments.
    # Report the known failing stage ourselves, without exposing those terms.
    Logger.configure(level: :none)

    opts = account_options!()
    Application.put_env(:at_mcp, :boot_from_env, false)
    Application.put_env(:at_mcp, :start_mcp, false)
    Application.put_env(:at_mcp, :jetstream_enabled, false)
    Application.put_env(:at_mcp, :notifications_enabled, false)
    Application.put_env(:at_mcp, :inbound_state_dir, state_dir(opts))

    start_runtime!()
    start_account!(opts)

    case AtMcp.MCP.Server.start_link(
           transport: :stdio,
           effects: AtMcp.Identity.effects_name("stdio")
         ) do
      {:ok, server} ->
        # ExMCP suppresses logs for generic stdio launchers. This launcher has
        # already assigned diagnostics to stderr, so retain ordinary diagnostics.
        Logger.configure(level: :info)

        receive do
          {:EXIT, ^server, :normal} ->
            Application.stop(:at_mcp)
            :ok

          {:EXIT, ^server, _reason} ->
            fail("AtMcp MCP transport stopped unexpectedly.")
        end

      _ ->
        fail(
          "AtMcp could not start its MCP transport. Restart the client and check the installed release."
        )
    end
  end

  defp start_runtime! do
    case Application.ensure_all_started(:at_mcp) do
      {:ok, _} ->
        :ok

      {:error, {:at_mcp, {reason, {AtMcp.Application, :start, _}}}} ->
        runtime_failure(reason)

      {:error, {:at_mcp, reason}} ->
        runtime_failure(reason)

      {:error, {dependency, _}} when is_atom(dependency) ->
        fail(
          "AtMcp dependency #{dependency} could not start. Check the installed release and run AtMcp as an ordinary user."
        )

      _ ->
        fail("AtMcp could not start its runtime. Check the installed release.")
    end
  end

  defp runtime_failure(reason)
       when reason in [:state_directory_in_use, :state_runtime_already_running],
       do:
         fail(
           "Another AtMcp process owns this state directory. Close that client, or use one shared HTTP service for this account."
         )

  defp runtime_failure(:state_directory_unavailable),
    do:
      fail(
        "AtMcp cannot access its state directory. Check AT_MCP_STATE_DIR, its parent directory, and your file permissions."
      )

  defp runtime_failure({:shutdown, {:failed_to_start_child, owner, reason}})
       when owner in [AtMcp.Inbound.Store, AtMcp.WriteQuota] do
    case reason do
      {%File.Error{}, _stack} ->
        fail(
          "AtMcp cannot read its saved state. Check the state directory and your file permissions; preserve the existing files."
        )

      _ ->
        fail(
          "AtMcp could not load its saved state. Preserve the files and restore a known-good backup; do not delete or reset state to bypass this failure."
        )
    end
  end

  defp runtime_failure(_),
    do:
      fail(
        "AtMcp could not start its account runtime. Check the installed release and state directory."
      )

  defp start_account!(opts) do
    case AtMcp.Identities.start_identity(opts) do
      {:ok, _} ->
        :ok

      {:error, {:authentication_failed, _}} ->
        fail(
          "AtMcp could not log into this account. Check BLUESKY_HANDLE, BLUESKY_APP_PASSWORD, and BLUESKY_SERVICE, then reconnect the client."
        )

      {:error, :account_disconnected} ->
        fail(
          "This AtMcp account is disconnected. Reconnect it through the host that manages the account."
        )

      _ ->
        fail(
          "AtMcp could not start this account. Check its configuration and restart the client."
        )
    end
  end

  defp account_options! do
    [
      id: "stdio",
      handle: required!("BLUESKY_HANDLE"),
      password: required!("BLUESKY_APP_PASSWORD"),
      service: System.get_env("BLUESKY_SERVICE"),
      listen_enabled: false,
      notifications_enabled: false,
      write_quota: AtMcp.WriteQuota
    ]
  end

  defp required!(key) do
    case System.get_env(key) do
      value when is_binary(value) and value != "" ->
        value

      _ ->
        fail(
          "AtMcp requires #{key}. Set it in the MCP client's environment or AT_MCP_STDIO_ENV_FILE."
        )
    end
  end

  defp state_dir(opts) do
    case System.get_env("AT_MCP_STATE_DIR") do
      value when is_binary(value) and value != "" ->
        Path.expand(value)

      _ ->
        key =
          :crypto.hash(:sha256, [
            opts[:service] || AtMcp.Network.default_service(),
            "\n",
            opts[:handle]
          ])

        AtMcp.Rename.default_state_path(["stdio", Base.encode16(key, case: :lower)])
    end
  end

  defp fail(message) do
    IO.puts(:stderr, message)
    System.halt(1)
  end
end
