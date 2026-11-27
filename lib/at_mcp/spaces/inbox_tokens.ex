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
    {:noreply, %{state | last: vouch_all()}}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @doc "Whether tokens are handed over: town spaces, Spaces on, and no standing reader."
  def on? do
    AtMcp.Network.spaces() != nil and AtMcp.Spaces.Helper.available() == :ok
  end

  @doc false
  # One pass over the running accounts that have a login key.
  def vouch_all do
    if on?() do
      for id <- AtMcp.Identities.list_ids(),
          effects = AtMcp.Identity.effects_name(id),
          effects != nil,
          key?(effects),
          into: %{} do
        {id, vouch(effects)}
      end
    else
      %{}
    end
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
