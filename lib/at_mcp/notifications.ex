defmodule AtMcp.Notifications do
  @moduledoc """
  Collect an account's notifications without changing its read/unread state.

  Each identity owns one poller. A sweep pages from the newest notification back
  to the account's watermark, then enters the durable outbox oldest first, by
  indexed_at, so the account's lane delivers a post before the reply to it; the
  watermark advances only after the whole sweep is accepted. Pagination cursors
  live only for one sweep: after a failure or restart, fetch the newest page
  again and let the outbox deduplicate. A cursor is a page location, not a
  delivery acknowledgement.

  The first sweep starts five minutes before collection begins. Later sweeps
  overlap the last completed watermark by five minutes to catch late indexing.
  This is an inbox, not an archive: older initial history, events absent from the
  provider's notifications, and indexing delayed beyond the overlap aren't
  guaranteed. The outbox and host retain their at-least-once delivery contract.

  Req owns transient HTTP retries. This process only schedules the next sweep;
  it does not add another request retry policy or session owner.
  """

  use GenServer
  require Logger

  alias AtMcp.Inbound.Store

  # A sweep a minute: how long a mention can wait before it reaches the
  # consumer, and how often each account asks its own PDS.
  # `AT_MCP_NOTIFICATIONS_INTERVAL_SECONDS` sets it (`config/runtime.exs`).
  @interval_ms 60_000
  # The overlap with the last completed sweep, for late indexing (see above).
  @overlap_us 300_000_000
  @reasons ["mention", "reply", "quote", "like", "repost"]
  # One page's worth, the page this poller reads (`AtMcp.Effects.page_limits/0`):
  # each accept rewrites the outbox file, so a chunk per event would multiply
  # that cost, and one chunk per sweep could never fit a sweep larger than the
  # account's room in the outbox.
  @accept_chunk AtMcp.Effects.page_limits().max

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    interval =
      Keyword.get_lazy(opts, :interval_ms, fn ->
        Application.get_env(:at_mcp, :notifications_interval_ms, @interval_ms)
      end)

    clock = Keyword.get(opts, :clock, fn -> System.system_time(:microsecond) end)

    state = %{
      interval_ms: interval,
      effects: Keyword.get(opts, :effects, AtMcp.Effects),
      store: Keyword.get(opts, :store, Store),
      clock: clock,
      initial_at: clock.(),
      cursor: nil,
      sweep: nil,
      timer: nil
    }

    enabled? =
      Keyword.get(opts, :enabled, Application.get_env(:at_mcp, :notifications_enabled, true))

    {:ok, if(enabled?, do: schedule(state, interval), else: state)}
  end

  @impl true
  def handle_info(:poll, state) do
    if state.timer, do: Process.cancel_timer(state.timer)

    case poll_page(state) do
      {:ok, state} ->
        {:noreply, schedule(state, if(state.sweep, do: 0, else: state.interval_ms))}

      {:error, reason} ->
        Logger.warning(
          "AtMcp notifications retained checkpoint; next sweep will retry: #{inspect(reason)}"
        )

        {:noreply, schedule(%{state | cursor: nil, sweep: nil}, state.interval_ms)}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp schedule(state, delay), do: %{state | timer: Process.send_after(self(), :poll, delay)}

  defp poll_page(state) do
    started_at = state.clock.()

    with {:ok, state} <- prepare(state, started_at),
         {:ok, %{items: items} = page} when is_list(items) <-
           AtMcp.Effects.list_notifications(state.effects,
             # The largest page the account allows, so a sweep takes the fewest reads.
             limit: AtMcp.Effects.page_limits().max,
             cursor: state.cursor,
             reasons: @reasons
           ),
         did when is_binary(did) and did != "" <- AtMcp.Effects.session_did(state.effects),
         {:ok, sweep} <- sweep(state, did, started_at),
         {:ok, dated} <- date_items(items),
         :ok <- valid_cursor(page[:cursor], sweep) do
      # A provider timestamp in the future must not skip subsequent real arrivals.
      newest = Enum.reduce(dated, sweep.watermark, fn {_, at}, acc -> max(acc, at) end)

      sweep = %{
        sweep
        | watermark: min(newest, sweep.started_at),
          collected: [events(dated, sweep) | sweep.collected]
      }

      if is_nil(page[:cursor]) or
           (dated != [] and Enum.all?(dated, fn {_, at} -> at < sweep.since end)) do
        with :ok <- accept_sweep(state, sweep),
             :ok <- Store.checkpoint_notifications(state.store, did, sweep.watermark) do
          {:ok, %{state | cursor: nil, sweep: nil}}
        end
      else
        sweep = %{sweep | cursors: MapSet.put(sweep.cursors, page.cursor)}
        {:ok, %{state | cursor: page.cursor, sweep: sweep}}
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :unreadable_notification_page}
    end
  end

  # The provider pages newest first; the outbox delivers each account in the
  # order it accepts. So a completed sweep is accepted oldest first, by
  # indexed_at, with ties kept in the provider's order reversed. Chunks keep a
  # sweep larger than the outbox's room for this account able to make
  # progress: a refused chunk leaves the older ones accepted, the checkpoint
  # where it was, and the next sweep deduplicates what is already in.
  defp accept_sweep(state, sweep) do
    sweep.collected
    |> Enum.reverse()
    |> Enum.concat()
    |> Enum.reverse()
    |> Enum.sort_by(fn {_event, at} -> at end)
    |> Enum.map(fn {event, _at} -> event end)
    |> Enum.chunk_every(@accept_chunk)
    |> Enum.reduce_while(:ok, fn chunk, :ok ->
      case Store.accept(state.store, chunk) do
        {:ok, added} ->
          Enum.each(added, fn event ->
            AtMcp.Listen.notify(event)
            AtMcp.Listen.notify(event, {:did, sweep.did})
          end)

          {:cont, :ok}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
  end

  # Establish a connected account's initial boundary before the HTTP call, so
  # an outage cannot slide its lookback forward. Login may also happen lazily
  # inside Effects, in which case sweep/3 uses the poller's original start time.
  defp prepare(state, started_at) do
    case AtMcp.Effects.session_did(state.effects) do
      did when is_binary(did) and did != "" ->
        with {:ok, sweep} <- sweep(state, did, started_at), do: {:ok, %{state | sweep: sweep}}

      _ ->
        {:ok, state}
    end
  end

  defp sweep(%{sweep: %{did: did} = sweep}, did, _started_at), do: {:ok, sweep}

  defp sweep(%{sweep: sweep}, _did, _started_at) when not is_nil(sweep),
    do: {:error, :notification_identity_changed}

  defp sweep(state, did, started_at) do
    watermark = Store.notification_checkpoint(state.store, did)

    # Persist the initial boundary even if this sweep later fails. A prolonged
    # outage must not move the starting point forward on each retry.
    with :ok <-
           if(is_nil(watermark),
             do: Store.checkpoint_notifications(state.store, did, state.initial_at),
             else: :ok
           ) do
      watermark = watermark || state.initial_at

      {:ok,
       %{
         did: did,
         watermark: watermark,
         since: watermark - @overlap_us,
         started_at: started_at,
         cursors: MapSet.new(),
         # Each page's {event, indexed_at} pairs, most recent page first.
         collected: []
       }}
    end
  end

  defp date_items(items) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, dated} ->
      with true <- is_map(item),
           uri when is_binary(uri) and uri != "" <- item[:uri],
           reason when is_binary(reason) and reason != "" <- item[:reason],
           at when is_binary(at) <- item[:indexed_at],
           {:ok, datetime, _offset} <- DateTime.from_iso8601(at) do
        {:cont, {:ok, [{item, DateTime.to_unix(datetime, :microsecond)} | dated]}}
      else
        _ -> {:halt, {:error, :unreadable_notification_item}}
      end
    end)
    |> case do
      {:ok, dated} -> {:ok, Enum.reverse(dated)}
      error -> error
    end
  end

  defp valid_cursor(nil, _sweep), do: :ok

  defp valid_cursor(cursor, sweep) when is_binary(cursor) and cursor != "" do
    if MapSet.member?(sweep.cursors, cursor),
      do: {:error, :repeated_notification_cursor},
      else: :ok
  end

  defp valid_cursor(_cursor, _sweep), do: {:error, :invalid_notification_cursor}

  defp events(dated, sweep) do
    for {item, at} <- dated,
        at >= sweep.since,
        item[:reason] in @reasons do
      event =
        item
        |> Map.delete(:is_read)
        |> Map.merge(%{
          source: :notifications,
          matched_did: sweep.did,
          kind: :inbound_notification,
          inbound?: true
        })
        |> Map.merge(
          AtMcp.Inbound.Match.thread_refs(
            item[:reason],
            item[:reply_root_uri],
            item[:reply_parent_uri],
            item[:uri]
          )
        )

      {event, at}
    end
  end
end
