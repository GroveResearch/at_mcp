defmodule AtMcp.ReadPositions do
  @moduledoc """
  Where an account has read to in each feed: the time of the newest item a
  read returned, per DID and feed, so a read can ask for only what is newer
  (`since: "last_read"` on a read tool).

  A feed is named by `key/2`: the timeline, a custom feed or a list's feed by
  its AT URI, an author's posts by the actor as the caller named it (a handle
  and its DID hold separate positions), and the notifications. Every client
  of an account shares its positions, as they share its write quota.

  A position moves only on a read that asks it to: one with `since`, unless
  it passes `mark_read: false`, or one with `mark_read: true`. A plain read,
  by an operator or another client, leaves it alone. It only moves forward: a read of an older page, or one whose newest
  item is older than the position, leaves it where it is. Positions live in
  `read-positions.json` in the state directory beside the write quota
  (`AtMcp.Inbound.Store.default_dir/0`), rewritten whole under
  `AtMcp.PrivateFile`'s lock, so they survive a restart.

  Limits: an item's time is when its feed listed it (a repost's time, else
  when the service indexed it). A timeline, an author feed and the
  notifications are in that order, so a read stops at the position. A custom
  feed is in whatever order its generator chooses, so `since` there keeps the
  page's items newer than the position, and a newer item further down the
  feed is not looked for.
  """

  @version 1

  @doc "The file positions are kept in."
  def path, do: Path.join(AtMcp.Inbound.Store.default_dir(), "read-positions.json")

  @doc "The name a feed's position is kept under."
  def key(:timeline, nil), do: "timeline"
  def key(:notifications, nil), do: "notifications"
  def key(:feed, uri) when is_binary(uri), do: "feed:" <> uri
  def key(:list_feed, uri) when is_binary(uri), do: "list:" <> uri
  def key(:author, actor) when is_binary(actor), do: "author:" <> String.downcase(actor)

  @doc "The position held for `did` in `feed`, or nil for none."
  @spec get(binary(), binary(), binary()) :: {:ok, binary() | nil} | {:error, term()}
  def get(did, feed, path \\ path()) when is_binary(did) and is_binary(feed) do
    case AtMcp.PrivateFile.read(path) do
      {:ok, contents} ->
        with {:ok, data} <- decode(contents), do: {:ok, get_in(data, ["accounts", did, feed])}

      {:error, :config_missing} ->
        {:ok, nil}

      error ->
        error
    end
  end

  # Another read of the same account holds the lock for the moment it takes to
  # rewrite the file. A read waits briefly for it rather than leave its
  # position unsaved.
  @attempts 20
  @pause_ms 10

  @doc """
  Move `did`'s position in `feed` to `at` (an ISO 8601 time) if that is later
  than the one held. Returns the position now held.
  """
  @spec advance(binary(), binary(), binary(), binary()) :: {:ok, binary()} | {:error, term()}
  def advance(did, feed, at, path \\ path()) when is_binary(did) and is_binary(feed) do
    {:ok, _, _} = DateTime.from_iso8601(at)
    advance(did, feed, at, path, @attempts)
  end

  defp advance(did, feed, at, path, attempts) do
    case AtMcp.PrivateFile.mutate(path, &change(&1, did, feed, at)) do
      {:error, :config_busy} when attempts > 1 ->
        Process.sleep(@pause_ms)
        advance(did, feed, at, path, attempts - 1)

      result ->
        result
    end
  end

  defp change(current, did, feed, at) do
    data =
      case current do
        :missing -> {:ok, %{"version" => @version, "accounts" => %{}}}
        contents -> decode(contents)
      end

    with {:ok, data} <- data do
      held = get_in(data, ["accounts", did, feed])
      kept = if held && later?(held, at), do: held, else: at
      accounts = Map.update(data["accounts"], did, %{feed => kept}, &Map.put(&1, feed, kept))
      {:ok, Jason.encode!(%{data | "accounts" => accounts}), kept}
    end
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
