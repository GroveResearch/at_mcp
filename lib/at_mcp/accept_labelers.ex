defmodule AtMcp.AcceptLabelers do
  @moduledoc """
  Which labelers' labels a read asks the AppView for, as the app asks.

  The AppView puts on a response the labels of the labelers a request names
  in its `atproto-accept-labelers` header, and with no header, those of its
  own default labelers only. The app names the network's own moderation
  service with `;redact` (`appLabelers`, which cannot be unsubscribed), then
  each labeler the account subscribes to (`labelersPref`), so a label from a
  labeler the account chose arrives (@atproto/api's `labelersHeader`, which
  social-app configures from the account's preferences). AtMcp sends the same
  header on every application-namespace read: through the account's PDS,
  which forwards it to the AppView, and on a direct read
  (`AtMcp.ATProto.ServiceAuth`).

  The subscribed labelers are those the account's preferences named when
  AtMcp last read or wrote them (`AtMcp.ATProto.preferences_as_stored/1` and
  `put_preferences_as_stored/2`). Besides the settings tools, only a read that
  marks moderation reads the preferences, so only such a read refreshes the
  list. A change another client makes reaches the reads that follow the next
  one that marks moderation; until then every other read (notifications,
  lists, feeds) names the labelers as they were last read, however long ago.
  The first read of an account reads its preferences first. If that fails,
  the read names the network's moderation service alone, as the app does
  before it has loaded the preferences, and the next read tries again. A
  direct read (`AT_MCP_APPVIEW_READS=direct`) does not read them first,
  since that read goes through the PDS's proxy, which the direct route exists
  to do without; it names what is already known, or the network's service
  alone.

  The list is kept in a table owned by this process, by DID and the account's
  service (aliases of one DID share it). A service started where another one
  was, as a local test server reusing a port, is a different service:
  `forget_service/1` drops what the earlier one left.
  """
  use GenServer

  @table __MODULE__
  @header "atproto-accept-labelers"

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
    {:ok, nil}
  end

  @doc """
  The header for a read by `session`. `read_preferences` reads the account's
  preferences when none are known yet; it is expected to `remember/2` them.
  """
  def header(session, read_preferences) do
    subscribed =
      case known(session) do
        {:ok, dids} ->
          dids

        :error ->
          case read_preferences.() do
            {:ok, preferences} when is_list(preferences) ->
              AtMcp.Moderation.subscribed(preferences)

            _ ->
              []
          end
      end

    %{@header => value(subscribed)}
  end

  @doc "Keep the labelers `preferences` subscribes to, for `session`'s later reads."
  def remember(session, preferences) when is_list(preferences) do
    if table?() do
      :ets.insert(@table, {key(session), AtMcp.Moderation.subscribed(preferences)})
    end

    :ok
  end

  def remember(_session, _preferences), do: :ok

  @doc """
  Forget the labelers kept for every account at `service_url`, so the next
  read there reads the account's preferences first.
  """
  def forget_service(service_url) when is_binary(service_url) do
    if table?(), do: :ets.match_delete(@table, {{:_, service_url}, :_})
    :ok
  end

  @doc """
  The header's value: the network's own labelers with `;redact`, then the
  subscribed ones, each once. A subscribed one that is not a DID is left out:
  the AppView drops the whole header when one of its DIDs is invalid, and a
  line break would make the read fail.
  """
  def value(subscribed) do
    app = AtMcp.Moderation.app_labelers()

    subscribed =
      subscribed
      |> Enum.filter(&AtMcp.WebLink.did?/1)
      |> Enum.uniq()
      |> Enum.reject(&(&1 in app))

    (Enum.map(app, &(&1 <> ";redact")) ++ subscribed)
    |> Enum.join(", ")
  end

  defp known(session) do
    if table?() do
      case :ets.lookup(@table, key(session)) do
        [{_key, dids}] -> {:ok, dids}
        [] -> :error
      end
    else
      :error
    end
  end

  defp table?, do: :ets.whereis(@table) != :undefined

  defp key(session),
    do: {ProtoRune.Session.did(session), ProtoRune.Session.service_url(session)}
end
