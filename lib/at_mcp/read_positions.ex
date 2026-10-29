defmodule AtMcp.ReadPositions do
  @moduledoc """
  This module stores, for each account (DID) and feed, the time of the newest
  item the account has read. Read tools use it for `since: "last_read"`.

  `key/2` builds the feed key:
    - `"timeline"` and `"notifications"`
    - `"list:"` followed by the list's AT URI
    - `"author:"` followed by the actor as the caller wrote it, lowercased, so
      a handle and its DID get separate positions

  Custom feeds get no key, because their generators order posts in their own
  way.

  A read moves a position only when it asks to: `since: "last_read"` without
  `mark_read: false`, or a read without `since` that passes `mark_read: true`.
  When a read returns a page with every item newer than the position, older
  new items still wait below it. `advance/5` then stores the page's newest
  time as pending, and the read that gets back to the position commits it.

  An item's time follows the AppView. In a feed it follows the feed's sort: a
  repost uses the repost's time, and anything else uses the earlier of its
  `createdAt` and `indexedAt`. So a post indexed late sorts below the
  position, and a read since the position misses it as the app's feed shows
  it further down. A notification uses its `indexedAt`, which the AppView
  compares with `seenAt`, so a reply indexed late is still new.

  The positions are written whole to `read-positions.json` in the state
  directory, under `AtMcp.PrivateFile`'s lock, so every client of the account
  shares them and they survive a restart.
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
