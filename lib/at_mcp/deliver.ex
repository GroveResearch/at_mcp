defmodule AtMcp.Deliver do
  @moduledoc """
  Deliver-callback registry for listen/inbound events — global and per-DID.

  Hosts (Dwell, Haven, tests) register a 1-arity callback that receives
  normalized listen events. Callbacks are optional — AtMcp runs without a
  host connected. Events still fan out via `AtMcp.Listen.notify/1`.

  ## Routing

  `deliver/1` prefers a **per-DID** callback for `event.matched_did` when set;
  otherwise it invokes the global callback. This keeps N identities from
  sharing one communal deliver filter.

      AtMcp.Deliver.set_callback(fn event -> IO.inspect(event, label: "deliver") end)
      AtMcp.Deliver.set_callback("did:plc:alice", fn event -> Dwell.Inbound.ingest(event) end)

  ## Event shapes

  - Inbound: `%{source: :inbound, inbound?: true/false, matched_did: ..., reasons: [...], kind: ...}`
  - Account notifications: `%{source: :notifications, ...}`

  ## Order, concurrency and the deadline

  `AtMcp.Inbound.Store` calls `deliver/1`: collectors accept events into the
  store, and the store delivers them. It delivers one account's events in the
  order it accepted them, one at a time, and different accounts' events
  concurrently. A callback therefore runs in parallel with itself for different
  DIDs, never for the same DID, and sees each DID's events in collection order.

  A callback has `timeout_ms/0` to return. After that the store kills the
  process running it and retries the event, so a callback that does its own
  I/O should give up before the deadline and report why.

  Path: collector → `AtMcp.Inbound.Store` → `AtMcp.Deliver.deliver` → host
  callback. This does **not** invent an agent reply; the host/agent decides
  whether to act (MCP tools / dwell session).
  """

  @global :at_mcp_deliver_callback
  @by_did :at_mcp_deliver_by_did

  # How long one delivery may run before the store kills it and schedules a
  # retry. It is long enough for a consumer to persist an event and answer,
  # and short enough that a hung consumer costs its own account a retry rather
  # than stalling that account's lane for minutes.
  @timeout_ms 10_000

  @doc "Milliseconds a delivery callback may run before the store kills it and retries."
  def timeout_ms, do: @timeout_ms

  @doc "Install or replace the global deliver callback."
  def set_callback(fun) when is_function(fun, 1) do
    :persistent_term.put(@global, fun)
    :ok
  end

  @doc "Install or replace a per-DID deliver callback."
  def set_callback(did, fun) when is_binary(did) and is_function(fun, 1) do
    map = by_did_map()
    :persistent_term.put(@by_did, Map.put(map, did, fun))
    :ok
  end

  @doc "Clear the global deliver callback."
  def clear_callback do
    :persistent_term.erase(@global)
    :ok
  end

  @doc "Clear a per-DID deliver callback (or all DID callbacks when given `:all`)."
  def clear_callback(did) when is_binary(did) do
    map = Map.delete(by_did_map(), did)

    if map_size(map) == 0 do
      :persistent_term.erase(@by_did)
    else
      :persistent_term.put(@by_did, map)
    end

    :ok
  end

  def clear_callback(:all) do
    :persistent_term.erase(@by_did)
    :ok
  end

  @doc "Return the global deliver callback, or nil."
  def callback do
    try do
      :persistent_term.get(@global)
    rescue
      ArgumentError -> nil
    end
  end

  @doc "Return the per-DID deliver callback for `did`, or nil."
  def callback(did) when is_binary(did) do
    Map.get(by_did_map(), did)
  end

  @doc """
  Invoke the best deliver callback for `event`.

  Prefers `callback(matched_did)` when present; else the global callback.
  Returns `:ok` on acceptance or `{:error, reason}` on failure. Missing
  callbacks return `{:error, :no_callback}` so events survive host absence. Callbacks that return
  `{:error, reason}`, raise, throw, or exit are retried by the inbound store.
  """
  def deliver(event) do
    fun = resolve_callback(event)
    invoke(fun, event)
  end

  defp resolve_callback(event) do
    did = matched_did(event)

    cond do
      is_binary(did) ->
        case callback(did) do
          nil -> callback()
          fun -> fun
        end

      true ->
        callback()
    end
  end

  defp matched_did(event) when is_map(event) do
    Map.get(event, :matched_did) || Map.get(event, "matched_did")
  end

  defp matched_did(_), do: nil

  defp by_did_map do
    try do
      :persistent_term.get(@by_did)
    rescue
      ArgumentError -> %{}
    end
  end

  defp invoke(nil, _event), do: {:error, :no_callback}

  defp invoke(fun, event) do
    try do
      case fun.(event) do
        {:error, _} = error -> error
        _ -> :ok
      end
    rescue
      error ->
        require Logger
        Logger.warning("AtMcp.Deliver callback crashed: #{Exception.message(error)}")
        {:error, :callback_crashed}
    catch
      kind, reason ->
        require Logger
        Logger.warning("AtMcp.Deliver callback #{kind}: #{inspect(reason)}")
        {:error, :callback_crashed}
    end
  end
end
