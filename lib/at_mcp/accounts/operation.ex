defmodule AtMcp.Accounts.Operation do
  @moduledoc false
  alias AtMcp.Inbound.Store

  # Runtime work may block on supervision or a PDS. Policy mutations always
  # return to Accounts, which rejects an obsolete operation before committing.
  def run(owner, token, command) do
    context = {owner, token}

    try do
      execute(context, command)
    rescue
      _ -> {:error, :invalid_configuration}
    catch
      :throw, :superseded -> :superseded
      :exit, _ -> {:error, :account_runtime_unavailable}
    end
  end

  defp execute(ctx, {:start, id, opts, replace?}) do
    if replace?, do: stop(ctx, id)
    prepare(ctx, id, opts, false)
  end

  defp execute(ctx, {:stop, ids}) do
    Enum.each(ids, &stop(ctx, &1))
    :ok
  end

  defp execute(ctx, {:cleanup, ids}) do
    Enum.each(ids, &stop(ctx, &1))
    {:error, :account_runtime_unavailable}
  end

  defp execute(ctx, {:reconnect, id, opts, configs, ids}) do
    Enum.each(ids, &stop(ctx, &1))

    if Enum.all?(ids, &is_nil(AtMcp.Identity.whereis(&1))),
      do: reconnect_group(ctx, id, opts, configs),
      else: {:error, :account_runtime_unavailable}
  end

  defp execute(ctx, {:recover, id, opts}) do
    live = AtMcp.Identity.whereis(id)

    cond do
      disconnected?(id) ->
        stop(ctx, id)

      is_pid(live) and id not in AtMcp.Identities.list_ids() ->
        {:error, :account_runtime_unavailable}

      Store.ready(id) == :ok ->
        {:ok, live}

      opts ->
        prepare(ctx, id, opts, false)

      is_pid(live) ->
        prepare_existing(ctx, id)

      true ->
        {:error, :configuration_required}
    end
  end

  defp execute(ctx, {:reload, plan}) do
    stop_failed =
      Enum.reduce(plan.stop, MapSet.new(), fn id, failed ->
        stop(ctx, id)
        if is_nil(AtMcp.Identity.whereis(id)), do: failed, else: MapSet.put(failed, id)
      end)

    results =
      Enum.map(Enum.sort(plan.changed), fn id ->
        result =
          cond do
            MapSet.member?(stop_failed, id) -> {:error, :account_runtime_unavailable}
            plan.previously_disconnected[id] -> {:error, :account_disconnected}
            disconnected?(id) -> reconnect_group(ctx, id, plan.configs[id], plan.configs)
            true -> prepare(ctx, id, plan.configs[id], false)
          end

        %{
          id: id,
          status:
            case result do
              {:ok, _} -> "ready"
              {:error, :account_disconnected} -> "disconnected"
              _ -> "unavailable"
            end
        }
      end)

    {:ok,
     %{
       accounts: results,
       stop_failed: Enum.sort(stop_failed),
       removed: Enum.sort(plan.removed),
       unchanged: plan.unchanged
     }}
  end

  defp reconnect_group(ctx, id, opts, configs) do
    with {:ok, _} <- prepare(ctx, id, opts, true) do
      records = Store.accounts()
      did = records[id].did
      ids = for {other, r} <- records, other == id or (is_binary(did) and r.did == did), do: other
      claim(ctx, ids)
      available = Enum.filter(ids, &Map.has_key?(configs, &1))

      result =
        Enum.reduce_while(available, {:ok, []}, fn other, {:ok, started} ->
          case prepare(ctx, other, Map.fetch!(configs, other), true) do
            {:ok, pid} -> {:cont, {:ok, [{other, pid} | started]}}
            error -> {:halt, error}
          end
        end)

      result =
        with {:ok, ready} <- result, :ok <- account(ctx, {:enable, ids, ready}), do: {:ok, ready}

      case result do
        {:ok, ready} ->
          {_, pid} = List.keyfind(ready, id, 0)
          {:ok, pid}

        error ->
          {:ok, disconnected_ids} = account(ctx, {:disconnect, id})
          Enum.each(Enum.uniq(disconnected_ids ++ available), &stop(ctx, &1))
          error
      end
    end
  end

  defp prepare_existing(ctx, id) do
    pid = AtMcp.Identity.whereis(id)
    effects = GenServer.whereis(AtMcp.Identity.effects_name(id))

    result =
      with :ok <- authenticate(effects, true),
           :ok <- bind(ctx, id, AtMcp.Effects.session_did(effects), true) do
        account(ctx, {:enable, [id], [{id, pid}]})
      end

    if result == {:error, {:authentication_failed, :not_connected}}, do: stop(ctx, id)
    result
  end

  defp prepare(ctx, id, opts, reconnect?) do
    claim(ctx, [id])
    :ok = account(ctx, {:starting, id, true})

    result =
      with {:ok, pid} <- AtMcp.Identities.start_identity_runtime(opts),
           effects when is_pid(effects) <- GenServer.whereis(AtMcp.Identity.effects_name(id)),
           :ok <- authenticate(effects, reconnect?),
           :ok <- bind(ctx, id, AtMcp.Effects.session_did(effects), reconnect?) do
        if reconnect? do
          {:ok, pid}
        else
          if disconnected?(id) do
            {:error, :account_disconnected}
          else
            with :ok <- account(ctx, {:enable, [id], [{id, pid}]}), do: {:ok, pid}
          end
        end
      else
        {:error, _} = error -> error
        _ -> {:error, :account_runtime_unavailable}
      end

    :ok = account(ctx, {:starting, id, false})
    if not match?({:ok, _}, result), do: stop(ctx, id)
    result
  end

  defp authenticate(effects, required?) do
    case AtMcp.Effects.authenticate(effects) do
      {:ok, _} -> :ok
      {:error, :not_connected} when not required? -> :ok
      {:error, reason} -> {:error, {:authentication_failed, reason}}
    end
  end

  defp bind(ctx, id, did, reconnect?) do
    previous = Store.accounts()[id].did

    if reconnect? and is_binary(previous) and previous != did,
      do: {:error, :account_identity_changed},
      else: account(ctx, {:bind, id, did})
  end

  defp stop(ctx, id) do
    claim(ctx, [id])
    # Barrier: an interrupted worker may already have queued start_child. Wait
    # for that request before resolving the exact runtime to stop.
    _ = DynamicSupervisor.which_children(AtMcp.Identities)
    claim(ctx, [id])
    AtMcp.Identities.stop_identity(id)
  end

  defp disconnected?(id) do
    records = Store.accounts()
    r = records[id]

    is_nil(r) or r.disabled or
      (is_binary(r.did) and
         Enum.any?(records, fn {_, other} ->
           other.did == r.did and other.disabled
         end))
  end

  defp claim(ctx, ids), do: request(ctx, {:claim, ids})
  defp account(ctx, action), do: request(ctx, {:account, action})

  defp request({owner, token}, command) do
    case GenServer.call(owner, {:operation, token, command}, :infinity) do
      :superseded -> throw(:superseded)
      result -> result
    end
  end
end
