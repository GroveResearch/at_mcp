defmodule AtMcp.PostDefaults do
  @moduledoc """
  The account's saved settings for a new post (`postInteractionSettingsPref`:
  who may reply, whether it may be quoted), kept for a short while so that a
  post leaving its rules out does not read the account's preferences each
  time (`AtMcp.Effects.ProtoRune.prepare_post/3`).

  They are kept from the account's preferences whenever AtMcp reads or writes
  them (`AtMcp.ATProto.preferences_as_stored/1` and
  `put_preferences_as_stored/2`), so `set_preference` takes effect on the
  next post. A change another client makes reaches posts within `ttl_ms/0`
  (#{60_000} ms), when what is kept is read again.

  The settings are kept in a table owned by this process, by DID and the
  account's service, as `AtMcp.AcceptLabelers` keeps labelers.
  `forget_service/1` drops what a service started where another one was left.
  """
  use GenServer

  @table __MODULE__
  @ttl_ms 60_000

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
    {:ok, nil}
  end

  @doc "How long kept settings are used before they are read again, in milliseconds."
  def ttl_ms, do: @ttl_ms

  @doc "Keep the post settings `preferences` hold, for `session`'s next posts."
  def remember(session, preferences) when is_list(preferences) do
    if table?() do
      saved = AtMcp.Preferences.kind_view(preferences, "interaction_defaults")
      :ets.insert(@table, {key(session), saved, System.monotonic_time(:millisecond)})
    end

    :ok
  end

  def remember(_session, _preferences), do: :ok

  @doc """
  The settings kept for `session` within `ttl_ms/0`, as
  `AtMcp.Preferences.kind_view/2` gives them for `interaction_defaults`, or
  `:error` when none are.
  """
  def known(session) do
    with true <- table?(),
         [{_key, saved, at}] <- :ets.lookup(@table, key(session)),
         true <- System.monotonic_time(:millisecond) - at < @ttl_ms do
      {:ok, saved}
    else
      _ -> :error
    end
  end

  @doc "Forget the settings kept for every account at `service_url`."
  def forget_service(service_url) when is_binary(service_url) do
    if table?(), do: :ets.match_delete(@table, {{:_, service_url}, :_, :_})
    :ok
  end

  defp table?, do: :ets.whereis(@table) != :undefined

  defp key(session),
    do: {ProtoRune.Session.did(session), ProtoRune.Session.service_url(session)}
end
