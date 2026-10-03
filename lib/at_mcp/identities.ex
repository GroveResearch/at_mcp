defmodule AtMcp.Identities do
  @moduledoc """
  DynamicSupervisor for N AtMcp identities on one BEAM.

  Each child is a `AtMcp.Identity` (own Effects + Listen + optional Notifications).
  Identities share Jetstream fanout and durable account policy through the
  outbox, quota store, and lifecycle owner, and they share the one MCP endpoint
  the application supervisor starts — a request reaches an identity by presenting a grant
  for it. Credentials and sessions remain separate; aliases of one account DID
  share its quota.

  ## Boot

  The OTP app starts this supervisor, then boots the accounts named in the
  accounts file (`AT_MCP_ACCOUNTS_FILE`, or the per-user default). That file is
  the only way an installation is configured; an installation without one has no
  accounts yet.

  An account whose login fails at boot does not fail the boot. It stays
  configured and not running, and `AtMcp.Accounts` decides what happens next
  from the failure's kind: a PDS that did not answer is retried with backoff,
  a refused credential is reported and left for the operator.

  Runtime:

      AtMcp.Identities.start_identity(
        id: "grug",
        handle: "grug.bsky.social",
        password: "..."
      )
  """

  use DynamicSupervisor

  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Start one identity under the DynamicSupervisor.

  Required: `:id` (string or atom). Optional: `:handle`, `:password`,
  `:effects_name`, `:backend`, `:write_quota`,
  `:notifications_enabled` and `:service` (account PDS URL).
  Every identity uses the durable account quota; hosts own activity limits.
  `:write_quota` names a running quota server and defaults to AtMcp.WriteQuota.
  Explicit nil and retired turn-runtime options are refused.

  Returns `{:ok, pid}` for the identity supervisor once it is ready. Without
  credentials, the identity can start without a logged-in session; success does
  not by itself prove account authentication. Supplied credentials are checked
  before the account is ready. `:expected_did` can require a specific account DID.

  The configuration is retained in memory even when a durable disconnect causes
  `{:error, :account_disconnected}`. This is intentional when restoring configurations
  after a restart: wait for an explicit `AtMcp.Accounts.reconnect/1` rather than
  automatically undoing the owner's disconnect. Dynamic configurations must be supplied
  again after the lifecycle owner restarts.

  Other errors include `{:missing_option, :id}`, `:invalid_configuration`,
  `:account_runtime_unavailable`, `:account_control_unavailable`, and
  `{:authentication_failed, reason}`. Supervisor startup and DID-binding errors
  are returned as well. Account IDs may be strings or atoms and are normalized
  to strings.
  """
  @spec start_identity(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_identity(opts) when is_list(opts), do: AtMcp.Accounts.start_identity(opts)

  @doc false
  def start_identity_runtime(opts) when is_list(opts) do
    _id = Keyword.fetch!(opts, :id)

    if Enum.any?(
         [:host_token, :max_writes_per_turn, :max_posts_per_turn, :require_turn],
         &Keyword.has_key?(opts, &1)
       ),
       do: raise(ArgumentError, "turn runtime options were removed; configure the account quota")

    case DynamicSupervisor.start_child(__MODULE__, {AtMcp.Identity, opts}) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        {:ok, pid}

      other ->
        other
    end
  rescue
    e in KeyError -> {:error, {:missing_option, e.key}}
  end

  @doc "Stop an identity by id."
  def stop_identity(id) do
    case AtMcp.Identity.whereis(id) do
      nil ->
        {:error, :not_found}

      pid ->
        DynamicSupervisor.terminate_child(__MODULE__, pid)
    end
  catch
    :exit, _ -> {:error, :identity_runtime_unavailable}
  end

  @doc "List running identity ids."
  def list_ids do
    DynamicSupervisor.which_children(__MODULE__)
    |> Enum.flat_map(fn
      {_, pid, :supervisor, _} when is_pid(pid) ->
        Enum.filter(Registry.keys(AtMcp.Identity.Registry, pid), &is_binary/1)

      _ ->
        []
    end)
  catch
    :exit, _ -> []
  end

  @doc """
  Boot the configured identities (called by Application after tree start).

  A login that fails is the account owner's to report and, when the failure
  was indeterminate, to retry; the application starts either way, and
  readiness stays false until the account runs. What still halts the boot is a
  runtime that cannot start an identity at all — invalid configuration, or a
  lifecycle owner or store that is unavailable — because no retry fixes those.
  """
  def boot_from_env! do
    Enum.reduce_while(env_identity_specs(), :ok, fn opts, :ok ->
      case start_identity(opts) do
        {:ok, _pid} -> {:cont, :ok}
        {:error, :account_disconnected} -> {:cont, :ok}
        {:error, {:authentication_failed, _reason}} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:identity_start_failed, opts[:id], reason}}}
      end
    end)
  end

  @doc """
  Configured identities, from the accounts file.

  A missing accounts file is an installation with no accounts configured, not a
  failure: discovery exists to be asked during setup, before anything is
  configured.
  """
  def env_identity_specs do
    if boot_from_env?() do
      case named_identity_specs(AtMcp.AccountConfig.path()) do
        {:ok, specs} -> specs
        # Nothing configured yet is an installation mid-setup, not a failure.
        {:error, :config_missing} -> []
        {:error, reason} -> raise ArgumentError, "AtMcp account configuration: #{reason}"
      end
    else
      []
    end
  end

  @doc false
  def named_identity_specs(path) do
    if File.lstat(path) == {:error, :enoent} do
      # A reload must not read a deleted file as "no accounts configured".
      {:error, :config_missing}
    else
      load_identity_specs(path)
    end
  end

  defp load_identity_specs(path) do
    case AtMcp.AccountConfig.load(path) do
      {:ok, accounts} -> {:ok, Enum.map(accounts, &configured_identity/1)}
      error -> error
    end
  end

  @doc """
  Migrate an installation configured through `BLUESKY_*` into the accounts file.

  This runs once, at boot, and only when no accounts file exists: an existing
  installation that was started from the environment pair writes itself an
  accounts file and then runs the single configured path, rather than breaking.
  With a file already present the environment is not consulted at all.
  """
  def bootstrap_configuration! do
    if boot_from_env?(),
      do: AtMcp.AccountSetup.bootstrap_from_env!(AtMcp.AccountConfig.path()),
      else: :ok
  end

  defp configured_identity(account) do
    [
      id: account["id"],
      handle: account["handle"],
      password: account["password"],
      service: account["service"],
      expected_did: account["did"]
    ]
  end

  @doc false
  def boot_from_env?, do: Application.get_env(:at_mcp, :boot_from_env, true)
end
