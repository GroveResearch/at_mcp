defmodule AtMcp.Spaces.InboxTokens do
  @moduledoc """
  While AtMcp runs, hands the town AppView a delegation token for each
  key-holding account's inbox, so group invites reach its notifications
  whether or not the AppView is a listed reader of the inbox
  (`AT_MCP_TOWN_INBOX_READER`): a second path beside the reader, and the
  only one where the reader is off or was removed.

  The cadence follows the town AppView's space sync: it holds a space
  credential for 600 seconds and renews it in the last 120, using a client's
  token only if it is under 50 seconds old. A token every 100 seconds puts
  one in every renewal window, and no more often: the AppView needs none
  while its credential lasts.

  It also makes each such account's invite inbox, with its reader, if the
  account has none, on its first pass after AtMcp starts: a group can invite
  only an account whose inbox exists, and only the account's own client can
  make it. A failed attempt is tried again after 5 seconds, then twice as long
  each time up to the 100-second pass, until the inbox exists.

  With the reader off, invites reach the notification list only while this
  runs (or another client of the account hands over tokens); they are always
  in `get_group_invites`.
  """

  use GenServer

  require Logger

  @every_ms 100_000
  @first_ms 5_000

  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "How often a token is handed over, in milliseconds."
  def every_ms, do: @every_ms

  # A missing inbox that could not be made is tried again sooner than the
  # next pass: 5 s, then twice as long each time, up to the pass itself.
  @retry_first_ms 5_000

  @impl true
  def init(opts) do
    every = Keyword.get(opts, :every_ms, @every_ms)
    Process.send_after(self(), :vouch, Keyword.get(opts, :first_ms, @first_ms))

    {:ok,
     %{
       every: every,
       last: %{},
       prepared: MapSet.new(),
       retry_first: Keyword.get(opts, :retry_first_ms, @retry_first_ms),
       retries: %{}
     }}
  end

  @impl true
  def handle_info(:vouch, state) do
    Process.send_after(self(), :vouch, state.every)
    {last, state} = vouch_all(state)
    {:noreply, %{state | last: last}}
  end

  # One account's inbox, tried again after a failure, until it exists.
  def handle_info({:prepare, id}, state) do
    state = %{state | retries: Map.update(state.retries, id, nil, &Map.put(&1, :timer, nil))}

    case on?() && List.keyfind(running(), id, 0) do
      {^id, effects} -> {:noreply, prepare_or_retry(state, id, effects)}
      _ -> {:noreply, %{state | retries: Map.delete(state.retries, id)}}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  @doc "Whether tokens are handed over: town spaces and Spaces on."
  def on? do
    AtMcp.Network.spaces() != nil and AtMcp.Spaces.Helper.available() == :ok
  end

  @doc false
  # One pass over the running accounts that have a login key: each one's
  # inbox is made if it has none (`prepare/1`), since a group can invite only
  # an account whose inbox exists; then the AppView gets a token for it.
  def vouch_all(
        state \\ %{
          prepared: MapSet.new(),
          retries: %{},
          retry_first: @retry_first_ms,
          every: @every_ms
        }
      ) do
    if on?() do
      Enum.reduce(running(), {%{}, state}, fn {id, effects}, {last, state} ->
        state =
          if MapSet.member?(state.prepared, id) or pending_retry?(state, id),
            do: state,
            else: prepare_or_retry(state, id, effects)

        {Map.put(last, id, vouch(effects)), state}
      end)
    else
      {%{}, state}
    end
  end

  defp pending_retry?(state, id), do: match?(%{timer: t} when t != nil, state.retries[id])

  defp prepare_or_retry(state, id, effects) do
    case prepare(effects) do
      :ok ->
        %{
          state
          | prepared: MapSet.put(state.prepared, id),
            retries: Map.delete(state.retries, id)
        }

      :failed ->
        delay = next_delay(state.retries[id], state.retry_first, state.every)

        # At the pass's own length the pass tries it; sooner, a timer does.
        timer =
          if delay < state.every, do: Process.send_after(self(), {:prepare, id}, delay)

        %{state | retries: Map.put(state.retries, id, %{delay: delay, timer: timer})}
    end
  end

  @doc false
  # How long after a failed attempt to make an inbox the next one comes.
  def next_delay(%{delay: previous}, _first, every), do: min(previous * 2, every)
  def next_delay(_none, first, _every), do: first

  defp running do
    for id <- AtMcp.Identities.list_ids(),
        effects = AtMcp.Identity.effects_name(id),
        effects != nil,
        key?(effects),
        do: {id, effects}
  end

  defp key?(effects) do
    case AtMcp.Effects.session_did(effects) do
      did when is_binary(did) -> AtMcp.Spaces.Login.key?(did)
      _ -> false
    end
  catch
    :exit, _ -> false
  end

  @doc false
  # Makes the account's inbox, with the town AppView as its listed reader
  # where that is on, and registers it with the AppView.
  def prepare(effects) do
    case AtMcp.Effects.spaces(effects, :prepare_inbox, []) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.info("making the account's invite inbox failed: #{inspect(reason, limit: 5)}")
        :failed
    end
  catch
    :exit, _ -> :failed
  end

  @doc false
  def vouch(effects) do
    case AtMcp.Effects.spaces(effects, :vouch_inbox, []) do
      {:ok, %{status: status}} ->
        status

      {:error, %AtMcp.Effects.Failure{detail: "SpaceNotFound"}} ->
        :no_inbox

      {:error, reason} ->
        Logger.info(
          "handing the town AppView an inbox token failed: #{inspect(reason, limit: 5)}"
        )

        :failed
    end
  catch
    :exit, _ -> :failed
  end
end
