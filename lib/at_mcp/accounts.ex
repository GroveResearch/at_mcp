defmodule AtMcp.Accounts do
  @moduledoc """
  Account readiness, disconnect and reconnect within one AtMcp runtime.

  Account configurations contain credentials and live only in memory. Which
  accounts are disconnected, and each account's DID, are persisted with the
  inbound store. After an application restart, an embedding host must supply
  dynamic configurations again with `AtMcp.Identities.start_identity/1`;
  supplying a configuration never reconnects a disconnected account.

  Controls apply to all known aliases of the same DID within this runtime.
  They do not revoke credentials or control independent AtMcp processes.

  ## A login that fails

  An account whose login fails stays configured and not running, and the
  application stays up: `status/0` and `GET /identities` report it, and
  `AtMcp.CLI.service_status/0` is not ready until it runs. What happens next is
  decided by the backend's own vocabulary, `AtMcp.Effects.Failure`:

  - `:indeterminate` (a timeout, a lost response, a 5xx) — the service may
    answer next time, so this owner tries again with backoff, from one second
    doubling to thirty. This is what a PDS that does not answer at boot
    produces, and the reason a service under a service manager must not exit on it.
  - `:refused` or `:auth_refused`, or a session whose DID is not the one the
    accounts file names — the same credential will be refused again, so it is
    reported once in the log and left alone until `reconnect/1` or `reload/0`.
  """
  use GenServer
  require Logger
  alias AtMcp.Inbound.Store

  # Login retry backoff: the first retry after a second, doubling to thirty
  # seconds, so a PDS that is down at boot is asked again soon and then rarely.
  @retry_first_ms 1_000
  @retry_max_ms 30_000

  # How soon to look again when a process this owner depends on (the inbound
  # store, the identity supervisor) is restarting: long enough for a restart to
  # finish, short enough that nobody notices the wait.
  @dependency_wait_ms 100

  @type account_id :: String.t() | atom()
  @type account_status :: %{
          id: String.t(),
          did: String.t() | nil,
          disconnected: boolean(),
          running: boolean(),
          configured: boolean(),
          ready: boolean(),
          delivery:
            nil
            | %{
                state: String.t(),
                reason: String.t(),
                since: String.t(),
                attempts: pos_integer(),
                pending: pos_integer()
              }
        }

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def start_identity(opts) do
    case Keyword.fetch(opts, :id) do
      {:ok, id} when is_binary(id) or is_atom(id) -> call({:start, opts})
      _ -> {:error, {:missing_option, :id}}
    end
  end

  @doc """
  Persist that an account and its known DID aliases are disconnected.

  Stops tool calls and inbound delivery, cancels active deliveries, retains
  accepted work for later, and requests shutdown of the affected identity
  processes. `:ok` acknowledges the durable disconnect; it does not assert that every process
  terminated. Use `status/0` to inspect runtime state.

  Repeated calls for a known account are idempotent. Returns `{:error, :not_found}`
  for an unknown ID, or `{:error, :account_control_unavailable}` if the lifecycle
  owner cannot complete the call. A disconnect already persisted before a
  failure remains in effect. Only an explicit `reconnect/1` clears it.
  """
  @spec disconnect(account_id()) ::
          :ok | {:error, :not_found | :account_control_unavailable}
  def disconnect(id), do: call({:disconnect, to_string(id)})

  @doc """
  Authenticate an account and its configured DID aliases, then make it ready again.

  Returns `{:ok, pid}` for the selected identity supervisor once every configured
  alias has authenticated and the durable disconnect is cleared. Retained inbound work
  can then resume. This operation also replaces an already running account.

  Returns `{:error, :configuration_required}` when this runtime has no configuration
  for the ID, including an unknown ID. Supply one through
  `AtMcp.Identities.start_identity/1` first. Other errors include
  `:account_identity_changed`, `:account_runtime_unavailable`,
  `:account_control_unavailable`, and `{:authentication_failed, reason}`;
  supervisor startup errors are returned as well. Failed authentication or
  identity verification does not clear the durable disconnect.
  """
  @spec reconnect(account_id()) :: {:ok, pid()} | {:error, term()}
  def reconnect(id), do: call({:reconnect, to_string(id)})

  @doc """
  Return public lifecycle state for every known account, including disconnected ones.

  Each row contains the normalized `:id`, the bound `:did` (or `nil` before
  binding), and four independent flags: `:disconnected` is the stored
  disconnect, `:running` reports an identity process, `:configured` reports an
  in-memory configuration, and `:ready` reports that the account is logged in,
  verified and serving tool calls and delivery. A running process need not be
  ready. Row order is unspecified; credentials are never included.

  Returns `{:error, :account_control_unavailable}` if the lifecycle owner cannot
  complete the call. The result is a snapshot, not a reservation for later work.
  """
  @spec status() :: {:ok, [account_status()]} | {:error, :account_control_unavailable}
  def status, do: call(:status)

  @doc "Reconcile the explicitly selected named file; removed accounts stay disconnected."
  def reload, do: call(:reload)

  @doc false
  # Application startup waits for its runtime transitions, while status remains
  # a prompt snapshot even if another account is authenticating.
  def await_initialization, do: call(:await_initialization)

  defp call(message) do
    GenServer.call(__MODULE__, message, :infinity)
  catch
    :exit, _ -> {:error, :account_control_unavailable}
  end

  @impl true
  def init(_) do
    Process.flag(:trap_exit, true)
    :ok = Store.account(:reset_runtime)
    configs = Map.new(AtMcp.Identities.env_identity_specs(), &{to_string(&1[:id]), &1})

    {:ok,
     %{
       configs: configs,
       config_path:
         if(
           AtMcp.Identities.boot_from_env?() and
             Application.get_env(:at_mcp, :accounts_file),
           do: AtMcp.AccountConfig.path()
         ),
       supervisor: nil,
       monitor: nil,
       retry_ms: @retry_first_ms,
       retry: nil,
       pending: MapSet.new(Map.keys(configs) ++ AtMcp.Identities.list_ids()),
       operations: %{},
       boot_waiters: [],
       sequence: 0,
       versions: %{}
     }, {:continue, :boot}}
  end

  @impl true
  def handle_continue(:boot, state) do
    {:noreply, reconcile(state)}
  catch
    :exit, {_, {GenServer, :call, [Store | _]}} -> {:noreply, store_unavailable(state)}
  end

  @impl true
  def handle_call(message, from, state) do
    handle_request(message, from, state)
  catch
    :exit, {_, {GenServer, :call, [Store | _]}} ->
      {:reply, {:error, :account_control_unavailable}, store_unavailable(state)}
  end

  @impl true
  def handle_info(message, state) do
    process_message(message, state)
  catch
    :exit, {_, {GenServer, :call, [Store | _]}} -> {:noreply, store_unavailable(state)}
  end

  # Losing the policy store fences the work, not the configuration owner. Keep configurations
  # across this dependency restart and reauthenticate after Store announces it
  # is ready. No worker from the old store generation may commit afterward.
  defp store_unavailable(state) do
    pending =
      Enum.reduce(state.operations, state.pending, fn {_, op}, pending ->
        Task.shutdown(op.task, :brutal_kill)
        reply(op.waiters, {:error, :account_control_unavailable})
        MapSet.union(pending, op.ids)
      end)

    Enum.each(state.boot_waiters, &GenServer.reply(&1, {:error, :account_control_unavailable}))
    schedule(%{state | operations: %{}, boot_waiters: [], pending: pending}, @dependency_wait_ms)
  end

  defp handle_request(:status, _, state) do
    stalls = Store.stalls()

    rows =
      Enum.map(Store.accounts(), fn {id, record} ->
        %{
          id: id,
          did: record.did,
          disconnected: record.disabled,
          running: not is_nil(AtMcp.Identity.whereis(id)),
          configured: Map.has_key?(state.configs, id),
          ready: Store.ready(id) == :ok,
          delivery: delivery(stalls[record.did])
        }
      end)

    {:reply, {:ok, rows}, state}
  end

  defp handle_request(:await_initialization, from, state) do
    if map_size(state.operations) == 0,
      do: {:reply, :ok, state},
      else: {:noreply, %{state | boot_waiters: [from | state.boot_waiters]}}
  end

  defp handle_request({:start, opts}, from, state) do
    id = to_string(Keyword.fetch!(opts, :id))

    opts =
      if AtMcp.Identity.whereis(id),
        do: Keyword.merge(Map.get(state.configs, id, []), opts),
        else: opts

    opts = Keyword.put(opts, :id, id)
    previous = state.configs[id]
    state = %{state | configs: Map.put(state.configs, id, opts)}
    :ok = Store.account({:register, id})

    cond do
      disconnected?(id) ->
        state =
          if previous != opts do
            ids = aliases(id, Store.accounts()[id].did)
            state |> invalidate(ids) |> launch(ids, {:stop, ids}, nil)
          else
            state
          end

        {:reply, {:error, :account_disconnected}, state}

      previous == opts and operation_for(state, id) != nil ->
        {token, op} = operation_for(state, id)

        {:noreply,
         put_in(state.operations[token], %{op | waiters: [{from, {:identity, id}} | op.waiters]})}

      true ->
        replace? = operation_for(state, id) != nil
        state = invalidate(state, [id])
        {:noreply, launch(state, [id], {:start, id, opts, replace?}, from)}
    end
  end

  defp handle_request({:disconnect, id}, from, state) do
    case Store.accounts()[id] do
      nil ->
        {:reply, {:error, :not_found}, state}

      _ ->
        {:ok, ids} = Store.account({:disconnect, id})
        state = invalidate(state, ids)
        {:noreply, launch(state, ids, {:stop, ids}, from)}
    end
  end

  defp handle_request({:reconnect, id}, from, state) do
    case Map.fetch(state.configs, id) do
      :error ->
        {:reply, {:error, :configuration_required}, state}

      {:ok, opts} ->
        :ok = Store.account({:register, id})
        {:ok, ids} = Store.account({:disconnect, id})
        state = invalidate(state, ids)
        {:noreply, launch(state, ids, {:reconnect, id, opts, state.configs, ids}, from)}
    end
  end

  defp handle_request(:reload, _, %{config_path: nil} = state),
    do: {:reply, {:error, :named_configuration_required}, state}

  defp handle_request(:reload, from, state) do
    with {:ok, specs} <- AtMcp.Identities.named_identity_specs(state.config_path),
         :ok <- validate_saved_identities(specs) do
      configs = Map.new(specs, &{to_string(&1[:id]), &1})

      disconnected_running =
        for {id, _} <- Store.accounts(),
            disconnected?(id) and not is_nil(AtMcp.Identity.whereis(id)),
            do: id

      removed = Enum.uniq(Map.keys(state.configs) ++ disconnected_running) -- Map.keys(configs)

      changed =
        for {id, opts} <- configs, state.configs[id] != opts or id in disconnected_running, do: id

      previously_disconnected = Map.new(changed, &{&1, already_disconnected?(&1)})
      affected = Enum.uniq(removed ++ changed)

      stop_ids =
        Enum.flat_map(affected, fn id ->
          if Map.has_key?(Store.accounts(), id) do
            {:ok, disconnected_ids} = Store.account({:disconnect, id})
            disconnected_ids
          else
            []
          end
        end)
        |> Enum.uniq()

      Enum.each(changed, &Store.account({:register, &1}))
      state = invalidate(%{state | configs: configs}, Enum.uniq(affected ++ stop_ids))

      plan = %{
        configs: configs,
        changed: changed,
        removed: removed,
        stop: stop_ids,
        previously_disconnected: previously_disconnected,
        unchanged: Enum.sort(Map.keys(configs) -- changed)
      }

      {:noreply, launch(state, affected ++ stop_ids, {:reload, plan}, from)}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  # Workers carry an operation reference, never permission to mutate Store on
  # their own. Policy changes and commits share this mailbox, so a late network
  # result cannot clear a newer disconnect or make obsolete credentials ready.
  defp handle_request({:operation, token, command}, _, state) do
    with {:ok, op} <- Map.fetch(state.operations, token),
         ids <- command_ids(command),
         true <- current?(state, op, ids) do
      op = %{op | ids: MapSet.union(op.ids, MapSet.new(ids))}
      state = put_in(state.operations[token], op)

      case command do
        {:claim, _} ->
          {:reply, :ok, state}

        {:account, {:disconnect, id}} ->
          {:ok, disconnected_ids} = result = Store.account({:disconnect, id})
          state = invalidate(state, disconnected_ids, token)

          state =
            update_in(state.operations[token], fn op ->
              versions =
                Enum.reduce(
                  disconnected_ids,
                  op.own_versions,
                  &Map.put(&2, &1, state.versions[&1])
                )

              %{op | own_versions: versions}
            end)

          {:reply, result, state}

        {:account, action} ->
          {:reply, Store.account(action), state}
      end
    else
      _ -> {:reply, :superseded, state}
    end
  end

  defp process_message({ref, result}, state) when is_reference(ref) do
    case Enum.find(state.operations, fn {_, op} -> op.task.ref == ref end) do
      nil ->
        {:noreply, state}

      {token, op} ->
        Process.demonitor(ref, [:flush])
        {:noreply, finish(state, token, op, result)}
    end
  end

  defp process_message({:DOWN, ref, :process, _pid, _reason}, %{monitor: ref} = state) do
    :ok = Store.account(:suspend_runtime)
    state = cancel_all(state)
    pending = MapSet.union(state.pending, MapSet.new(Map.keys(state.configs)))
    {:noreply, schedule(%{state | supervisor: nil, monitor: nil, pending: pending}, 0)}
  end

  defp process_message({:DOWN, ref, :process, _pid, _reason}, state) do
    case Enum.find(state.operations, fn {_, op} -> op.task.ref == ref end) do
      nil -> {:noreply, state}
      {token, op} -> {:noreply, finish(state, token, op, {:error, :account_runtime_unavailable})}
    end
  end

  defp process_message(:store_ready, state) do
    state = cancel_all(state)
    pending = MapSet.union(state.pending, MapSet.new(AtMcp.Identities.list_ids()))
    {:noreply, reconcile(%{state | pending: pending})}
  end

  defp process_message({:identity_started, id, pid}, state) do
    if AtMcp.Identity.whereis(id) == pid and Store.ready(id) != :ok and
         operation_for(state, id) == nil,
       do: {:noreply, reconcile(%{state | pending: MapSet.put(state.pending, id)})},
       else: {:noreply, state}
  end

  defp process_message({:recover_supervisor, token}, %{retry: {_, token}} = state),
    do: {:noreply, reconcile(%{state | retry: nil, retry_ms: next_retry_ms(state)})}

  defp process_message({:recover_supervisor, _}, state), do: {:noreply, state}
  defp process_message({:EXIT, _, _}, state), do: {:noreply, state}

  @impl true
  def terminate(_, state) do
    Enum.each(state.operations, fn {_, op} -> Task.shutdown(op.task, :brutal_kill) end)
    :ok
  end

  defp reconcile(state) do
    if state.retry, do: Process.cancel_timer(elem(state.retry, 0))
    state = %{state | retry: nil}

    case Process.whereis(AtMcp.Identities) do
      nil ->
        schedule(state, @dependency_wait_ms)

      pid ->
        ref =
          if state.supervisor == pid do
            state.monitor
          else
            if state.supervisor, do: Store.account(:suspend_runtime)
            if state.monitor, do: Process.demonitor(state.monitor, [:flush])
            Process.monitor(pid)
          end

        state = %{state | supervisor: pid, monitor: ref}

        Enum.reduce(state.pending, state, fn id, state ->
          cond do
            operation_for(state, id) ->
              state

            not Map.has_key?(state.configs, id) and is_nil(AtMcp.Identity.whereis(id)) ->
              %{state | pending: MapSet.delete(state.pending, id)}

            true ->
              if Map.has_key?(state.configs, id), do: Store.account({:register, id})

              launch(
                state,
                aliases(id, Store.accounts()[id].did),
                {:recover, id, state.configs[id]},
                nil
              )
          end
        end)
    end
  end

  defp launch(state, ids, command, from) do
    {state, _token} = launch_operation(state, ids, command, from)
    state
  end

  defp launch_operation(state, ids, command, from) do
    owner = self()
    token = make_ref()

    task =
      Task.Supervisor.async(AtMcp.Accounts.TaskSupervisor, fn ->
        AtMcp.Accounts.Operation.run(owner, token, command)
      end)

    op = %{
      task: task,
      ids: MapSet.new(ids),
      sequence: state.sequence,
      own_versions: %{},
      command: command,
      waiters: if(from, do: [{from, :direct}], else: [])
    }

    {%{state | operations: Map.put(state.operations, token, op)}, token}
  end

  defp finish(state, token, %{command: {:cleanup, _}} = op, :superseded),
    do: finish(state, token, op, {:error, :account_runtime_unavailable})

  defp finish(state, token, op, :superseded) do
    state = %{state | operations: Map.delete(state.operations, token)}
    Enum.each(op.ids, &Store.account({:starting, &1, false}))
    {state, cleanup_token} = launch_operation(state, op.ids, {:cleanup, op.ids}, nil)
    cleanup = state.operations[cleanup_token]
    put_in(state.operations[cleanup_token], %{cleanup | waiters: op.waiters})
  end

  defp finish(state, token, op, result) do
    if store = Process.whereis(Store), do: send(store, :drain)
    Enum.each(op.ids, &Store.account({:starting, &1, false}))

    result =
      case {op.command, result} do
        {{:recover, id, _}, :ok} -> {:ok, AtMcp.Identity.whereis(id)}
        _ -> result
      end

    state = %{state | operations: Map.delete(state.operations, token)}
    retry? = retry?(result)
    report(op.command, result, retry?)

    pending =
      Enum.reduce(op.ids, state.pending, fn id, pending ->
        cond do
          disconnected?(id) ->
            MapSet.delete(pending, id)

          Store.ready(id) == :ok ->
            MapSet.delete(pending, id)

          retry? and (Map.has_key?(state.configs, id) or is_pid(AtMcp.Identity.whereis(id))) ->
            MapSet.put(pending, id)

          true ->
            MapSet.delete(pending, id)
        end
      end)

    state = %{state | pending: pending}

    state =
      cond do
        MapSet.size(pending) == 0 ->
          if state.retry, do: Process.cancel_timer(elem(state.retry, 0))
          %{state | retry_ms: @retry_first_ms, retry: nil}

        state.retry ->
          state

        true ->
          schedule(state, state.retry_ms)
      end

    reply(op.waiters, result)

    if map_size(state.operations) == 0 do
      Enum.each(state.boot_waiters, &GenServer.reply(&1, :ok))
      %{state | boot_waiters: []}
    else
      state
    end
  end

  # Whether a failed start is worth another attempt without an operator. The
  # backend's own vocabulary decides: `:indeterminate` means the service may
  # answer next time. A refused credential, or a login that produced a
  # different DID than the file names, will be refused again until the
  # configuration changes, so it is reported once and left for reconnect or
  # reload. Every other failure is the runtime's own and is retried as before.
  defp retry?({:error, {:authentication_failed, :account_identity_changed}}), do: false

  defp retry?({:error, {:authentication_failed, reason}}),
    do: AtMcp.Effects.Failure.kind(reason) == :indeterminate

  defp retry?(_result), do: true

  defp report(command, {:error, {:authentication_failed, reason}}, retry?) do
    case account_of(command) do
      nil ->
        :ok

      id when retry? ->
        Logger.warning(
          "AtMcp account #{id}: login did not complete (#{inspect(reason)}); retrying with backoff"
        )

      id ->
        Logger.error(
          "AtMcp account #{id}: login refused (#{inspect(reason)}); not retried until the account is reconnected or reloaded"
        )
    end
  end

  defp report(_command, _result, _retry?), do: :ok

  defp account_of({:start, id, _, _}), do: id
  defp account_of({:recover, id, _}), do: id
  defp account_of({:reconnect, id, _, _, _}), do: id
  defp account_of(_), do: nil

  defp invalidate(state, ids, except \\ nil) do
    sequence = state.sequence + 1
    versions = Enum.reduce(ids, state.versions, &Map.put(&2, &1, sequence))

    state = %{
      state
      | sequence: sequence,
        versions: versions,
        pending: MapSet.difference(state.pending, MapSet.new(ids))
    }

    Enum.reduce(state.operations, state, fn {token, op}, state ->
      if token != except and not MapSet.disjoint?(op.ids, MapSet.new(ids)),
        do: cancel(state, token, op),
        else: state
    end)
  end

  defp cancel_all(state),
    do:
      Enum.reduce(state.operations, state, fn {token, op}, state -> cancel(state, token, op) end)

  defp cancel(state, token, op) do
    Task.shutdown(op.task, :brutal_kill)
    reply(op.waiters, {:error, :account_runtime_unavailable})
    Enum.each(op.ids, &Store.account({:starting, &1, false}))

    pending =
      Enum.reduce(op.ids, state.pending, fn id, pending ->
        if not disconnected?(id) and
             (Map.has_key?(state.configs, id) or is_pid(AtMcp.Identity.whereis(id))),
           do: MapSet.put(pending, id),
           else: pending
      end)

    state = %{state | operations: Map.delete(state.operations, token), pending: pending}
    if MapSet.size(pending) > 0, do: schedule(state, 0), else: state
  end

  defp current?(state, op, ids),
    do:
      Enum.all?(
        MapSet.union(op.ids, MapSet.new(ids)),
        fn id ->
          version = Map.get(state.versions, id, 0)
          valid_version? = version <= op.sequence or version == op.own_versions[id]

          unclaimed? =
            not Enum.any?(state.operations, fn {_, other} ->
              other.task.ref != op.task.ref and MapSet.member?(other.ids, id)
            end)

          valid_version? and unclaimed?
        end
      )

  defp reply(waiters, result) do
    replies =
      Enum.map(waiters, fn
        {from, {:identity, id}} ->
          value =
            case result do
              {:ok, _} ->
                with :ok <- Store.ready(id),
                     pid when is_pid(pid) <- AtMcp.Identity.whereis(id),
                     do: {:ok, pid}

              error ->
                error
            end

          {from, value}

        {from, :direct} ->
          {from, result}
      end)

    Enum.each(replies, fn {from, value} -> GenServer.reply(from, value) end)
  end

  defp command_ids({:claim, ids}), do: ids
  defp command_ids({:account, {:bind, id, did}}), do: aliases(id, did)

  defp command_ids({:account, {:enable, ids, _}}),
    do: Enum.flat_map(ids, &aliases(&1, Store.accounts()[&1].did))

  defp command_ids({:account, {:disconnect, id}}), do: aliases(id, Store.accounts()[id].did)
  defp command_ids({:account, {:starting, id, _}}), do: [id]

  defp aliases(id, did),
    do:
      [
        id
        | for(
            {other, record} <- Store.accounts(),
            is_binary(did) and record.did == did,
            do: other
          )
      ]
      |> Enum.uniq()

  defp operation_for(state, id),
    do: Enum.find(state.operations, fn {_, op} -> MapSet.member?(op.ids, id) end)

  defp schedule(state, delay) do
    if state.retry, do: Process.cancel_timer(elem(state.retry, 0))
    token = make_ref()
    timer = Process.send_after(self(), {:recover_supervisor, token}, delay)
    %{state | retry: {timer, token}}
  end

  defp next_retry_ms(state) do
    if is_pid(state.supervisor) and state.supervisor == Process.whereis(AtMcp.Identities),
      do: min(state.retry_ms * 2, @retry_max_ms),
      else: @retry_first_ms
  end

  # Delivery is reported only when it is stalled; nil means it is flowing.
  defp delivery(nil), do: nil

  defp delivery(stall) do
    %{
      state: "stalled",
      reason: stall.reason,
      since: stall.since_unix |> DateTime.from_unix!() |> DateTime.to_iso8601(),
      attempts: stall.attempts,
      pending: stall.pending
    }
  end

  defp already_disconnected?(id), do: Map.has_key?(Store.accounts(), id) and disconnected?(id)

  defp disconnected?(id) do
    records = Store.accounts()
    r = records[id]

    is_nil(r) or r.disabled or
      (is_binary(r.did) and
         Enum.any?(records, fn {_, other} -> other.did == r.did and other.disabled end))
  end

  defp validate_saved_identities(specs) do
    records = Store.accounts()

    if Enum.any?(specs, fn opts ->
         case records[to_string(opts[:id])] do
           %{did: did} when is_binary(did) -> did != opts[:expected_did]
           _ -> false
         end
       end), do: {:error, :account_identity_changed}, else: :ok
  end
end
