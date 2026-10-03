defmodule AtMcp.Listen do
  @moduledoc """
  Per-identity registrar + fan-out API for inbound events.

  ## Role

  Each AtMcp identity (own credentials, own `AtMcp.Effects`) waits until it has a
  session DID, then `AtMcp.Inbound.track/1` so the **shared** Jetstream consumer
  can fan inbound mentions/replies/quotes to this identity.

  Listening is **not** `wanted_dids: [self]`. That filter only sees commits
  authored *by* the DID (own-repo echo). Inbound listens to the post collection
  slice and matches other-repo commits client-side — see `AtMcp.Inbound.Match`.

  ## Messages

  Subscribers receive `{:at_mcp_listen, event}` on topic `:events` (all matches
  for tracked DIDs on this BEAM) or `{:did, did}` (one identity).

  Event sources:

  - `:inbound` — Jetstream Match hit (inbound and optional own-repo echo)
  - `:notifications` — account notification collection (`AtMcp.Notifications`)
  """

  use GenServer

  # How often to look for the account's DID until it has one: an account logs
  # in after this process starts, and stream matching needs the DID.
  @did_poll_ms 2_000

  require Logger

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Subscribe the calling process to listen/inbound events."
  def subscribe(topic \\ :events) do
    Registry.register(AtMcp.Listen.Registry, topic, nil)
  end

  @doc "Notify all subscribers (Inbound, Notifications, and tests)."
  def notify(event, topic \\ :events) do
    Registry.dispatch(AtMcp.Listen.Registry, topic, fn entries ->
      for {pid, _} <- entries, do: send(pid, {:at_mcp_listen, event})
    end)

    :ok
  end

  @impl true
  def init(opts) do
    enabled? =
      Keyword.get(opts, :enabled, Application.get_env(:at_mcp, :jetstream_enabled, false))

    effects = Keyword.get(opts, :effects, AtMcp.Effects)
    inbound = Keyword.get(opts, :inbound, AtMcp.Inbound)
    poll_ms = Keyword.get(opts, :did_poll_ms, @did_poll_ms)

    state = %{
      enabled?: enabled?,
      effects: effects,
      inbound: inbound,
      did: nil,
      inbound_ref: nil,
      did_poll_ms: poll_ms
    }

    if enabled? do
      {:ok, state, {:continue, :await_did}}
    else
      {:ok, state}
    end
  end

  @impl true
  def handle_continue(:await_did, state), do: maybe_track(state)

  @impl true
  def handle_info(:check_did, state), do: maybe_track(state)

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{inbound_ref: ref} = state)
      when is_reference(ref) do
    # Inbound is shared infrastructure. Its restart must not restart identities
    # or erase their write quotas and sessions.
    Process.send_after(self(), :check_did, state.did_poll_ms)
    {:noreply, %{state | did: nil, inbound_ref: nil}}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp maybe_track(%{did: did} = state) when is_binary(did) and did != "" do
    {:noreply, state}
  end

  defp maybe_track(state) do
    # Eager login when credentials are present — do not stay deaf until a tool call.
    _ = maybe_eager_login(state.effects)
    did = AtMcp.Effects.session_did(state.effects)

    cond do
      not is_binary(did) or did == "" ->
        Process.send_after(self(), :check_did, state.did_poll_ms)
        {:noreply, state}

      true ->
        case register(state.inbound, did) do
          {:ok, ref} ->
            Logger.info(
              "AtMcp.Listen tracked #{did} on Inbound (inbound via Match, not wanted_dids)"
            )

            {:noreply, %{state | did: did, inbound_ref: ref}}

          :retry ->
            Process.send_after(self(), :check_did, state.did_poll_ms)
            {:noreply, state}
        end
    end
  end

  defp maybe_eager_login(effects) do
    cond do
      AtMcp.Effects.logged_in?(effects) ->
        :ok

      not AtMcp.Effects.credentials?(effects) ->
        :ok

      true ->
        case AtMcp.Effects.login(effects) do
          {:ok, _} ->
            :ok

          {:error, reason} ->
            Logger.warning("AtMcp.Listen eager login deferred: #{inspect(reason)}")
            :ok
        end
    end
  end

  defp register(inbound, did) do
    case GenServer.whereis(inbound) do
      pid when is_pid(pid) ->
        :ok = do_track(pid, did)
        {:ok, Process.monitor(pid)}

      nil ->
        # A custom in-process test/host registrar may expose track without a
        # named GenServer. Production named servers retry while unavailable.
        if inbound != AtMcp.Inbound and is_atom(inbound) and
             function_exported?(inbound, :track, 1) do
          :ok = do_track(inbound, did)
          {:ok, nil}
        else
          :retry
        end
    end
  catch
    :exit, _ -> :retry
  end

  defp do_track(AtMcp.Inbound, did), do: AtMcp.Inbound.track(AtMcp.Inbound, did, %{owner: self()})

  defp do_track(pid, did) when is_pid(pid), do: AtMcp.Inbound.track(pid, did, %{owner: self()})

  # A registrar may also be a module exporting track/1 or track/2, which an
  # in-process test or host registrar uses instead of a named GenServer.
  defp do_track(mod, did) when is_atom(mod) do
    cond do
      function_exported?(mod, :track, 2) -> apply(mod, :track, [did, %{owner: self()}])
      function_exported?(mod, :track, 1) -> apply(mod, :track, [did])
      true -> AtMcp.Inbound.track(mod, did, %{owner: self()})
    end
  end
end
