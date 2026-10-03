defmodule AtMcp.CLI do
  @moduledoc """
  Entrypoints for mix tasks / release boots.
  """

  @doc "Release readiness: OTP has completed application startup, including bridge attachment."
  def service_status do
    started? =
      Enum.any?(Application.started_applications(1_000), fn {app, _, _} -> app == :at_mcp end)

    owners = [
      AtMcp.Supervisor,
      AtMcp.Accounts,
      AtMcp.Identities,
      AtMcp.Inbound.Store,
      AtMcp.Inbound,
      AtMcp.WriteQuota
    ]

    ready? =
      started? and Enum.all?(owners, &(not is_nil(Process.whereis(&1)))) and
        configured_accounts_ready?()

    IO.puts(Jason.encode!(%{ready: ready?, pid: System.pid()}))
    :ok
  end

  defp configured_accounts_ready? do
    case AtMcp.Accounts.status() do
      {:ok, rows} ->
        expected = Enum.map(AtMcp.Identities.env_identity_specs(), &to_string(&1[:id]))

        Enum.all?(expected, fn id -> Enum.any?(rows, &(&1.id == id)) end) and
          Enum.all?(rows, fn row ->
            cond do
              row.disconnected -> not row.running
              row.configured -> row.running and row.ready
              true -> true
            end
          end)

      _ ->
        false
    end
  end

  @doc "Fixed release-RPC entrypoint used by `at_mcp-accounts status|reload|disconnect|reconnect`."
  def account(action, encoded_id) do
    id = Base.decode64!(encoded_id)

    result =
      case action do
        "status" -> AtMcp.Accounts.status()
        "reload" -> AtMcp.Accounts.reload()
        "disconnect" -> AtMcp.Accounts.disconnect(id)
        "reconnect" -> AtMcp.Accounts.reconnect(id)
      end

    response =
      case result do
        {:ok, rows} when is_list(rows) ->
          %{ok: true, accounts: rows}

        {:ok, %{accounts: rows} = details} ->
          ready? =
            Enum.all?(rows, &(&1.status != "unavailable")) and
              Map.get(details, :stop_failed, []) == []

          Map.put(details, :ok, ready?)

        {:ok, details} when is_map(details) ->
          Map.put(details, :ok, true)

        {:ok, _} ->
          %{ok: true}

        :ok ->
          %{ok: true}

        {:error, {category, _detail}} ->
          %{ok: false, error: to_string(category)}

        {:error, reason} when is_atom(reason) ->
          %{ok: false, error: to_string(reason)}

        _ ->
          %{ok: false, error: "account_control_failed"}
      end

    IO.puts(Jason.encode!(response))
    :ok
  end

  @doc """
  Keep the BEAM alive with the application supervision tree.

  Prefer `mix at_mcp.server` (which runs the app) or `MIX_ENV=prod mix run --no-halt`.
  """
  def server do
    ids = AtMcp.Identities.list_ids()

    IO.puts("AtMcp accounts: #{Enum.join(ids, ", ")}")

    if Application.get_env(:at_mcp, :start_mcp, true) do
      IO.puts("MCP endpoint: #{AtMcp.AccountConfig.endpoint()}")

      IO.puts("Each identity is reached with its own grant: at_mcp-accounts connection NAME")
    end

    IO.puts(
      "Inbound: account notifications (default). AT_MCP_JETSTREAM=1 opts into the network-wide stream."
    )

    Process.sleep(:infinity)
  end
end
