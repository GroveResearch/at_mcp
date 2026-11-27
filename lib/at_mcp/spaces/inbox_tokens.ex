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

  @impl true
  def init(opts) do
    every = Keyword.get(opts, :every_ms, @every_ms)
    Process.send_after(self(), :vouch, Keyword.get(opts, :first_ms, @first_ms))
    {:ok, %{every: every, last: %{}}}
  end

  @impl true
  def handle_info(:vouch, state) do
    Process.send_after(self(), :vouch, state.every)
    {last, prepared} = vouch_all(Map.get(state, :prepared, MapSet.new()))
    {:noreply, state |> Map.put(:last, last) |> Map.put(:prepared, prepared)}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @doc "Whether tokens are handed over: town spaces, Spaces on, and no standing reader."
  def on? do
    AtMcp.Network.spaces() != nil and AtMcp.Spaces.Helper.available() == :ok
  end

  @doc false
  # One pass over the running accounts that have a login key. The first pass
  # for each account makes its inbox if it has none (`prepare/1`): a group
  # can invite only an account whose inbox exists. Answers each account's
  # status, and the accounts whose inbox is known to exist.
  def vouch_all(prepared \\ MapSet.new()) do
    if on?() do
      Enum.reduce(running(), {%{}, prepared}, fn {id, effects}, {last, prepared} ->
        prepared =
          if MapSet.member?(prepared, id) or prepare(effects) != :ok,
            do: prepared,
            else: MapSet.put(prepared, id)

        {Map.put(last, id, vouch(effects)), prepared}
      end)
    else
      {%{}, prepared}
    end
  end

  defp running do
    for id <- AtMcp.Identities.list_ids(),
        effects = AtMcp.Identity.effects_name(id),
        effects != nil,
        key?(effects),
        do: {id, effects}
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

  defp key?(effects) do
    case AtMcp.Effects.session_did(effects) do
      did when is_binary(did) -> AtMcp.Spaces.Login.key?(did)
      _ -> false
    end
  catch
    :exit, _ -> false
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
