defmodule AtMcp.ReadPositions do
  @moduledoc """
  Where an account has read to in each feed: the time of the newest item a
  read returned, per DID and feed, so a read can ask for only what is newer
  (`since: "last_read"` on a read tool).

  A feed is named by `key/2`: the timeline, a list's feed by its AT URI, an
  author's posts by the actor as the caller named it (a handle and its DID
  hold separate positions), and the notifications. A custom feed holds none:
  its generator orders it as it chooses, so no time says what in it is new.
  Every client of an account shares its positions, as they share its write
  quota.

  A position moves only on a read that asks it to (`since: "last_read"`,
  unless it passes `mark_read: false`, or a read without `since` that passes
  `mark_read: true`; never a read since a time, which looks back),
  only forward, and only once the read has reached it: a page whose items
  are all newer leaves items between it and the position unread, so its
  newest time is held as pending until the read that reaches the position
  commits it (`advance/5`). No read moves the position past an item it has
  not returned. Positions live in `read-positions.json` in the state
  directory beside the write quota (`AtMcp.Inbound.Store.default_dir/0`),
  rewritten whole under `AtMcp.PrivateFile`'s lock, so they survive a
  restart.

  An item's time is where its feed lists it: a repost at the repost's time,
  anything else at the earlier of its own date and when the service indexed
  it, as the AppView sorts a feed.
  """

  @version 1

  @doc "The file positions are kept in."
  def path, do: Path.join(AtMcp.Inbound.Store.default_dir(), "read-positions.json")

  @doc "The name a feed's position is kept under."
  def key(:timeline, nil), do: "timeline"
  def key(:notifications, nil), do: "notifications"
  def key(:list_feed, uri) when is_binary(uri), do: "list:" <> uri
  def key(:author, actor) when is_binary(actor), do: "author:" <> String.downcase(actor)

  @doc """
  What is held for `did` in `feed`: `at`, the position, and `pending`, the
  newest time a read returned before it had reached the position (see
  `advance/5`); nil for none.
  """
  @spec get(binary(), binary(), binary()) ::
          {:ok, %{at: binary() | nil, pending: binary() | nil}} | {:error, term()}
  def get(did, feed, path \\ path()) when is_binary(did) and is_binary(feed) do
    case AtMcp.PrivateFile.read(path) do
      {:ok, contents} ->
        with {:ok, data} <- decode(contents),
             do: {:ok, held(get_in(data, ["accounts", did, feed]))}

      {:error, :config_missing} ->
        {:ok, held(nil)}

      error ->
        error
    end
  end

  defp held(%{} = row), do: %{at: row["at"], pending: row["pending"]}
  defp held(_none), do: %{at: nil, pending: nil}

  # Another read of the same account holds the lock for the moment it takes to
  # rewrite the file. A read waits briefly for it rather than leave its
  # position unsaved.
  @attempts 20
  @pause_ms 10

  @doc """
  Record that a read of `did`'s `feed` returned items up to `newest` (an ISO
  8601 time).

  With `reached?` true the read reached the position it read from, so every
  item up to `newest` has been returned: the position moves to the latest of
  itself, `newest` and anything pending, and nothing stays pending. With
  `reached?` false, items between the position and this read are still
  unread: the position stays, and `newest` is held as pending for the read
  that reaches it. Returns what is held after.
  """
  @spec advance(binary(), binary(), binary(), boolean(), binary()) ::
          {:ok, %{at: binary() | nil, pending: binary() | nil}} | {:error, term()}
  def advance(did, feed, newest, reached?, path \\ path())
      when is_binary(did) and is_binary(feed) and is_boolean(reached?) do
    {:ok, _, _} = DateTime.from_iso8601(newest)
    advance(did, feed, newest, reached?, path, @attempts)
  end

  defp advance(did, feed, newest, reached?, path, attempts) do
    case AtMcp.PrivateFile.mutate(path, &change(&1, did, feed, newest, reached?)) do
      {:error, :config_busy} when attempts > 1 ->
        Process.sleep(@pause_ms)
        advance(did, feed, newest, reached?, path, attempts - 1)

      result ->
        result
    end
  end

  defp change(current, did, feed, newest, reached?) do
    data =
      case current do
        :missing -> {:ok, %{"version" => @version, "accounts" => %{}}}
        contents -> decode(contents)
      end

    with {:ok, data} <- data do
      %{at: at, pending: pending} = held(get_in(data, ["accounts", did, feed]))

      row =
        if reached?,
          do: %{"at" => latest([at, pending, newest]), "pending" => nil},
          else: %{"at" => at, "pending" => latest([pending, newest])}

      accounts = Map.update(data["accounts"], did, %{feed => row}, &Map.put(&1, feed, row))
      {:ok, Jason.encode!(%{data | "accounts" => accounts}), held(row)}
    end
  end

  defp latest(times) do
    times
    |> Enum.filter(&is_binary/1)
    |> Enum.reduce(nil, fn t, max -> if is_nil(max) or later?(t, max), do: t, else: max end)
  end

  @doc "Whether `a` is later than `b`, both ISO 8601 times."
  def later?(a, b) do
    with {:ok, a, _} <- DateTime.from_iso8601(a),
         {:ok, b, _} <- DateTime.from_iso8601(b) do
      DateTime.compare(a, b) == :gt
    else
      _ -> false
    end
  end

  defp decode(contents) do
    case Jason.decode(contents) do
      {:ok, %{"version" => @version, "accounts" => accounts} = data} when is_map(accounts) ->
        {:ok, data}

      _ ->
        {:error, :config_corrupt}
    end
  end
end
