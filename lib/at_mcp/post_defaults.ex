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

  The last settings read for each account are also kept in the state folder
  (`post-defaults.json`), with when they were read, for `last_known/1`: a post
  made while the preferences can't be read takes them rather than going out
  open, which could undo who may reply that the account chose (to keep
  harassment out, say), even after AtMcp restarts.
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
    saved = AtMcp.Preferences.kind_view(preferences, "interaction_defaults")
    read_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    changed? =
      case table?() && :ets.lookup(@table, key(session)) do
        [{_key, ^saved, _at, _read_at}] -> false
        _ -> true
      end

    if table?(),
      do: :ets.insert(@table, {key(session), saved, System.monotonic_time(:millisecond), read_at})

    # The state folder is rewritten only when they change.
    if changed?, do: store(session, saved, read_at)
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
         [{_key, saved, at, _read_at}] <- :ets.lookup(@table, key(session)),
         true <- System.monotonic_time(:millisecond) - at < @ttl_ms do
      {:ok, saved}
    else
      _ -> :error
    end
  end

  @doc """
  The settings last read for `session`, however long ago, and when (ISO
  8601): this process's, else the state folder's. `:error` when AtMcp has
  never read them for this account.
  """
  def last_known(session) do
    case table?() && :ets.lookup(@table, key(session)) do
      [{_key, saved, _at, read_at}] -> {:ok, saved, read_at}
      _ -> stored(session)
    end
  end

  @doc "Forget the settings kept for every account at `service_url`."
  def forget_service(service_url) when is_binary(service_url) do
    if table?(), do: :ets.match_delete(@table, {{:_, service_url}, :_, :_, :_})
    :ok
  end

  @doc false
  def path, do: Path.join(AtMcp.Inbound.Store.default_dir(), "post-defaults.json")

  defp file_key(session) do
    {did, service} = key(session)
    "#{did} #{service}"
  end

  defp stored(session) do
    with {:ok, contents} <- AtMcp.PrivateFile.read(path()),
         {:ok, %{"accounts" => %{} = accounts}} <- Jason.decode(contents),
         %{"reply_rule" => rule, "quotes" => quotes, "read_at" => read_at}
         when is_list(rule) and is_binary(read_at) <- accounts[file_key(session)] do
      {:ok, %{reply_rule: rule, quotes: quotes}, read_at}
    else
      _ -> :error
    end
  end

  defp store(session, saved, read_at) do
    row = %{"reply_rule" => saved.reply_rule, "quotes" => saved.quotes, "read_at" => read_at}

    result =
      AtMcp.PrivateFile.mutate(path(), fn current ->
        accounts =
          with contents when is_binary(contents) <- current,
               {:ok, %{"accounts" => %{} = accounts}} <- Jason.decode(contents) do
            accounts
          else
            _ -> %{}
          end

        next = %{"version" => 1, "accounts" => Map.put(accounts, file_key(session), row)}
        {:ok, Jason.encode!(next), :ok}
      end)

    case result do
      {:ok, :ok} -> :ok
      # Kept in this process; the state folder catches up at the next change.
      _ -> :ok
    end
  end

  defp table?, do: :ets.whereis(@table) != :undefined

  defp key(session),
    do: {ProtoRune.Session.did(session), ProtoRune.Session.service_url(session)}
end
