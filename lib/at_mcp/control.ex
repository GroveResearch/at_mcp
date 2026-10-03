defmodule AtMcp.Control do
  @moduledoc """
  Operator-facing HTTP for one installation.

  Serves the identities an installation holds, so a host learns which DIDs exist
  and how to reach each one instead of being configured with them by hand. This
  listener is loopback only and is not an MCP surface: an agent is connected to
  one identity, and no tool enumerates the others.

  The descriptor served here carries what a host would otherwise be told by
  hand — the shared MCP URL and the identity's DID — and no credential.
  `AtMcp.AccountConfig.public/1` decides what may be shown and `grant: :none`
  keeps one from being issued, so discovery cannot hand a local process a
  `:manage` grant for any identity. A credential comes from
  `at_mcp-accounts connection NAME`, which is the operator's act.
  """
  use Plug.Router

  plug(:match)
  plug(:dispatch)

  get "/identities" do
    case load_configured() do
      {:ok, accounts} ->
        send_json(conn, 200, %{identities: identities(accounts)})

      {:error, reason} ->
        # An installation that cannot read its own configuration holds an unknown
        # number of identities. Answering "none" would read as a healthy empty
        # installation and send an operator to add an account they already have.
        send_json(conn, 503, %{error: "configuration_unreadable", reason: to_string(reason)})
    end
  end

  match _ do
    send_json(conn, 404, %{error: "not_found"})
  end

  defp identities(configured) do
    runtime = Map.new(runtime_states(), &{&1.id, &1})

    Enum.map(configured, fn account ->
      state = runtime_view(Map.get(runtime, account["id"]))

      account
      |> AtMcp.AccountConfig.public()
      |> Map.put("descriptor", http_descriptor(account))
      |> Map.put("runtime", state)
    end)
  end

  # Everything listed is configured — that is what the list is. What an operator
  # needs to tell apart is an identity that is not running from one the runtime
  # has never heard of, because only the second is fixed by a reload. An absent
  # runtime record stays absent rather than being reported as a stopped one.
  defp runtime_view(nil), do: nil

  defp runtime_view(state) do
    %{
      "running" => state.running,
      "ready" => state.ready,
      "disconnected" => state.disconnected
    }
  end

  defp load_configured, do: AtMcp.AccountConfig.load(AtMcp.AccountConfig.path())

  # An installation still being set up is exactly when this is asked, so a runtime
  # that is not up yields no state rather than no identities.
  #
  # The shapes are matched strictly. A catch-all would report every identity as
  # unknown to the runtime whenever the snapshot's shape was misread, which is
  # indistinguishable from an installation that has not started yet; an
  # unexpected shape raises where it happens instead.
  defp runtime_states do
    case AtMcp.Accounts.status() do
      {:ok, accounts} when is_list(accounts) -> accounts
      {:error, _reason} -> []
    end
  catch
    :exit, _ -> []
  end

  defp http_descriptor(account) do
    case AtMcp.AccountConfig.descriptor(account, "http", grant: :none) do
      {:ok, descriptor} -> descriptor
      {:error, _} -> nil
    end
  end

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, JSON.encode!(body))
  end
end
