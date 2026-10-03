defmodule AtMcp.Inbound.Store do
  @moduledoc """
  Disk-backed, at-least-once host delivery and collection checkpoints.

  A single atomically replaced, fsynced snapshot commits matched events before
  their stream cursor. Successful deliveries retain a bounded receipt window
  (default 10,000 records); hosts must also deduplicate because a crash after
  host acceptance but before the receipt reaches disk can repeat delivery.
  Pending events are never evicted. Capacity exhaustion returns `:full` so the
  collector can pause instead of acknowledging data it has not retained.

  ## Delivery order

  Every accepted event gets an acceptance sequence number, persisted with it.
  Events are delivered in lanes: one lane per recipient account (the event's
  `matched_did`), and one more for events that name no account. A lane
  delivers its events in acceptance order, one at a time: the next event waits
  while the one before it is in flight or waiting out a retry backoff, so a
  consumer sees an account's activity in the order AtMcp collected it. Lanes run
  in parallel, each with its own worker, so one account's slow, failing or
  disconnected consumer never delays another account's events.

  Each delivery runs in a process this store spawns, links and monitors, and
  is killed when it outlives `AtMcp.Deliver.timeout_ms/0`. A failure or timeout
  keeps the event at the head of its lane and retries it with capped
  exponential backoff. The time a retry is due is read from the `:clock`
  option (Unix milliseconds, `System.system_time/1` by default) and persisted
  with the event, so a restarted store waits out the backoff its predecessor
  set. Disconnecting an account kills that account's in-flight
  delivery and keeps its event; stopping the store kills every in-flight
  delivery. Store files contain event text, never credentials; keep the state
  directory private and on persistent storage.

  ## Capacity

  Capacity is held per lane, because a lane whose consumer never
  accepts its first event keeps every event behind it: a store-wide limit would
  let one stuck account refuse every other account's events. A batch is
  refused, whole and with its cursor, only when a lane it adds to would exceed
  `max_pending` events (default 10,000) or `max_lane_bytes` of event data
  (default a quarter of `max_bytes`, 16 MiB). `max_bytes` (default 64 MiB)
  bounds the whole file, events, receipts and checkpoints together; one full
  lane cannot reach it, so it refuses everything only when several lanes are
  full at once.

  What a refusal holds depends on the collector. A notification sweep covers
  one account, so only that account's collection pauses. The Jetstream
  collector has one cursor for every account, so a refused batch pauses the
  stream for all of them until the full lane drains; the notification poll
  keeps collecting for the others meanwhile.
  """
  use GenServer
  require Logger

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  def accept(server \\ __MODULE__, events, cursor \\ nil),
    do: GenServer.call(server, {:accept, events, cursor}, :infinity)

  def checkpoint(server \\ __MODULE__, cursor),
    do: GenServer.call(server, {:checkpoint, cursor}, :infinity)

  @doc "Notification collection boundary for this DID, in Unix microseconds."
  def notification_checkpoint(server \\ __MODULE__, did),
    do: GenServer.call(server, {:notification_checkpoint, did})

  @doc "Initialize the collection boundary, or advance it after accepting a complete sweep."
  def checkpoint_notifications(server \\ __MODULE__, did, watermark)
      when is_binary(did) and byte_size(did) > 0 and is_integer(watermark) and watermark > 0,
      do: GenServer.call(server, {:checkpoint_notifications, did, watermark}, :infinity)

  # Account policy shares the outbox commit boundary; credentials never enter it.
  def accounts, do: GenServer.call(__MODULE__, :accounts)
  def account(action), do: GenServer.call(__MODULE__, {:account, action}, :infinity)

  def ready(id) do
    if Process.whereis(AtMcp.Accounts),
      do: account({:ready, id}),
      else: {:error, :account_control_unavailable}
  catch
    :exit, _ -> {:error, :account_control_unavailable}
  end

  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @doc """
  The lanes whose delivery is stalled: their oldest event has failed and waits
  to be tried again, holding the lane's later events behind it. Keyed by
  account DID (`:no_account` for events without one), each with the shape of
  the consumer's last answer as text (its strings left out), when the event
  first failed (Unix seconds), how many times it has failed (counted up to 20,
  where the backoff stops growing), and how many events the lane holds.
  """
  def stalls(server \\ __MODULE__), do: GenServer.call(server, :stalls)

  def default_dir do
    Application.get_env(:at_mcp, :inbound_state_dir) ||
      System.get_env("AT_MCP_STATE_DIR") ||
      AtMcp.Rename.default_state_path()
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    dir = Keyword.get_lazy(opts, :state_dir, &default_dir/0)
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)
    path = Path.join(dir, "inbound.term")
    data = load!(path)
    max_bytes = Keyword.get(opts, :max_bytes, 64 * 1024 * 1024)

    state = %{
      account_control: Keyword.get(opts, :name, __MODULE__) == __MODULE__,
      path: path,
      data: data,
      # lane => %{pid, ref, key, timer}; at most one in-flight delivery per lane.
      workers: %{},
      starting: MapSet.new(),
      ready: %{},
      drain_timer: nil,
      max_pending: Keyword.get(opts, :max_pending, 10_000),
      max_lane_bytes: Keyword.get(opts, :max_lane_bytes, div(max_bytes, 4)),
      max_bytes: max_bytes,
      max_receipts: Keyword.get(opts, :max_receipts, 10_000),
      retry_ms: Keyword.get(opts, :retry_ms, 1_000),
      max_retry_ms: Keyword.get(opts, :max_retry_ms, 60_000),
      timeout_ms: Keyword.get(opts, :timeout_ms, AtMcp.Deliver.timeout_ms()),
      clock: Keyword.get(opts, :clock, fn -> System.system_time(:millisecond) end)
    }

    send(self(), :announce_runtime)
    send(self(), :drain)
    {:ok, state}
  end

  @impl true
  def handle_call(:accounts, _from, state), do: {:reply, state.data.accounts, state}

  def handle_call({:account, action}, _from, state) do
    {reply, state} = account_action(action, state)
    {:reply, reply, state}
  end

  def handle_call(:status, _from, state) do
    {:reply,
     %{
       cursor: state.data.cursor,
       pending: map_size(state.data.pending),
       receipts: length(state.data.receipts)
     }, state}
  end

  def handle_call(:stalls, _from, state) do
    stalls =
      state.data.pending
      |> Enum.group_by(fn {_key, entry} -> lane(entry.event) end, fn {_key, entry} -> entry end)
      |> Enum.flat_map(fn {lane, entries} ->
        head = Enum.min_by(entries, & &1.seq)

        case head do
          %{failing_since: since, last_error: reason} ->
            [
              {lane,
               %{
                 reason: reason,
                 since_unix: div(since, 1000),
                 attempts: head.attempts,
                 pending: length(entries)
               }}
            ]

          _ ->
            []
        end
      end)
      |> Map.new()

    {:reply, stalls, state}
  end

  def handle_call({:checkpoint, cursor}, _from, state) do
    data = %{state.data | cursor: latest(state.data.cursor, cursor)}
    {:reply, :ok, commit(state, data)}
  end

  def handle_call({:notification_checkpoint, did}, _from, state) do
    {:reply, Map.get(state.data.notifications, did), state}
  end

  def handle_call({:checkpoint_notifications, did, watermark}, _from, state) do
    notifications =
      Map.update(state.data.notifications, did, watermark, &max(&1, watermark))

    data = %{state.data | notifications: notifications}

    if byte_size(:erlang.term_to_binary(data)) > state.max_bytes do
      {:reply, {:error, :full}, state}
    else
      {:reply, :ok, commit(state, data)}
    end
  end

  def handle_call({:accept, events, cursor}, _from, state) do
    receipts = MapSet.new(state.data.receipts)

    {pending, added, next_seq} =
      Enum.reduce(events, {state.data.pending, [], state.data.next_seq}, &stage(&1, &2, receipts))

    data = %{
      state.data
      | pending: pending,
        cursor: latest(state.data.cursor, cursor),
        next_seq: next_seq
    }

    if lane_full?(state, pending, added) or
         byte_size(:erlang.term_to_binary(data)) > state.max_bytes do
      {:reply, {:error, :full}, state}
    else
      state = commit(state, data)
      send(self(), :drain)
      {:reply, {:ok, Enum.reverse(added)}, state}
    end
  end

  @impl true
  def handle_info(:announce_runtime, state) do
    if state.account_control and Process.whereis(AtMcp.Accounts),
      do: send(AtMcp.Accounts, :store_ready)

    {:noreply, state}
  end

  def handle_info(:drain, state) do
    if state.drain_timer, do: Process.cancel_timer(state.drain_timer)
    now = state.clock.()

    {state, waiting} =
      state
      |> idle_lane_heads()
      |> Enum.reduce({state, []}, fn {lane, {key, entry}}, {state, waiting} ->
        cond do
          not eligible?(state, entry.event) -> {state, waiting}
          entry.due <= now -> {start_delivery(state, lane, key, entry), waiting}
          true -> {state, [entry.due | waiting]}
        end
      end)

    timer =
      case waiting do
        [] -> nil
        dues -> Process.send_after(self(), :drain, max(Enum.min(dues) - now, 1))
      end

    {:noreply, %{state | drain_timer: timer}}
  end

  def handle_info({:delivered, pid, result}, state) do
    case Enum.find(state.workers, fn {_lane, worker} -> worker.pid == pid end) do
      {lane, worker} ->
        Process.cancel_timer(worker.timer)
        Process.demonitor(worker.ref, [:flush])
        {:noreply, finish(state, lane, result)}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case worker_by_ref(state, ref) do
      {lane, worker} ->
        Process.cancel_timer(worker.timer)
        {:noreply, finish(state, lane, {:error, {:worker_exit, reason}})}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info({:delivery_timeout, ref}, state) do
    case worker_by_ref(state, ref) do
      {lane, worker} ->
        Process.exit(worker.pid, :kill)
        Process.demonitor(ref, [:flush])
        {:noreply, finish(state, lane, {:error, :timeout})}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state),
    do: Enum.each(state.workers, fn {_lane, worker} -> Process.exit(worker.pid, :kill) end)

  defp account_action(:suspend_runtime, state),
    do: {:ok, %{state | starting: MapSet.new(), ready: %{}}}

  # Never call the identity supervisor from Store: its child init calls back
  # into Store to ask whether it may start. Existing readiness is already validated.
  defp account_action(:reset_runtime, state),
    do: {:ok, %{state | starting: MapSet.new()}}

  defp account_action({:register, id}, state) do
    accounts = Map.put_new(state.data.accounts, id, %{did: nil, disabled: false})
    {:ok, commit(state, %{state.data | accounts: accounts})}
  end

  defp account_action({:starting, id, value}, state) do
    starting =
      if value, do: MapSet.put(state.starting, id), else: MapSet.delete(state.starting, id)

    ready = if value, do: Map.delete(state.ready, id), else: state.ready
    {:ok, %{state | starting: starting, ready: ready}}
  end

  defp account_action({:can_start, id}, state) do
    allowed =
      MapSet.member?(state.starting, id) or
        (Map.has_key?(state.data.accounts, id) and not disabled?(state.data, id))

    {allowed, state}
  end

  defp account_action({:ready, id}, state) do
    result =
      if ready_runtime?(state, id) and
           not disabled?(state.data, id),
         do: :ok,
         else: {:error, :account_disconnected}

    {result, state}
  end

  defp account_action({:bind, id, did}, state) do
    record = Map.fetch!(state.data.accounts, id)
    did = did || record.did

    disabled =
      record.disabled or
        (is_binary(did) and
           Enum.any?(state.data.accounts, fn {_, r} -> r.did == did and r.disabled end))

    accounts = Map.put(state.data.accounts, id, %{record | did: did, disabled: disabled})
    {:ok, commit(state, %{state.data | accounts: accounts})}
  end

  defp account_action({:enable, ids, ready}, state) do
    if Enum.all?(ready, fn {id, pid} ->
         is_pid(pid) and Process.alive?(pid) and AtMcp.Identity.whereis(id) == pid
       end) do
      accounts =
        Map.new(state.data.accounts, fn {id, record} ->
          {id, if(id in ids, do: %{record | disabled: false}, else: record)}
        end)

      state = commit(state, %{state.data | accounts: accounts})
      send(self(), :drain)

      {:ok,
       %{
         state
         | ready: Map.merge(state.ready, Map.new(ready)),
           starting: Enum.reduce(ids, state.starting, &MapSet.delete(&2, &1))
       }}
    else
      {{:error, :stale_identity_runtime}, state}
    end
  end

  defp account_action({:disconnect, id}, state) do
    record = Map.fetch!(state.data.accounts, id)

    ids =
      for {other, r} <- state.data.accounts,
          other == id or (is_binary(record.did) and r.did == record.did),
          do: other

    accounts =
      Map.new(state.data.accounts, fn {other, r} ->
        {other, if(other in ids, do: %{r | disabled: true}, else: r)}
      end)

    state = commit(state, %{state.data | accounts: accounts})

    # A killed delivery may have crossed the consumer's acceptance boundary, so
    # its event stays pending. The call answers only after each one is dead.
    {stopped, running} =
      Map.split_with(state.workers, fn {_lane, worker} ->
        disconnected_event?(state.data, Map.fetch!(state.data.pending, worker.key).event)
      end)

    Enum.each(stopped, fn {_lane, worker} -> Process.exit(worker.pid, :kill) end)

    Enum.each(stopped, fn {_lane, worker} ->
      receive do
        {:DOWN, ref, :process, _, _} when ref == worker.ref -> :ok
      end

      Process.cancel_timer(worker.timer)
    end)

    state = %{state | workers: running}

    send(self(), :drain)

    {{:ok, ids},
     %{
       state
       | ready: Map.drop(state.ready, ids),
         starting: Enum.reduce(ids, state.starting, &MapSet.delete(&2, &1))
     }}
  end

  defp ready_runtime?(state, id) do
    pid = state.ready[id]
    is_pid(pid) and Process.alive?(pid) and AtMcp.Identity.whereis(id) == pid
  end

  defp disabled?(data, id) do
    case data.accounts[id] do
      nil ->
        true

      r ->
        r.disabled or
          (is_binary(r.did) and
             Enum.any?(data.accounts, fn {_, a} -> a.did == r.did and a.disabled end))
    end
  end

  defp eligible?(state, event) do
    (not state.account_control or not is_nil(Process.whereis(AtMcp.Accounts))) and
      not disconnected_event?(state.data, event) and runtime_ready?(state, event)
  end

  defp runtime_ready?(%{account_control: false}, _event), do: true

  defp runtime_ready?(state, event) do
    did = event[:matched_did] || event["matched_did"]
    ids = for {id, record} <- state.data.accounts, is_binary(did) and record.did == did, do: id

    ids == [] or
      Enum.any?(ids, fn id ->
        ready_runtime?(state, id)
      end)
  end

  defp disconnected_event?(data, event) do
    did = event[:matched_did] || event["matched_did"]
    is_binary(did) and Enum.any?(data.accounts, fn {_, r} -> r.did == did and r.disabled end)
  end

  # Whether any lane this batch adds to is over its limits once it is added.
  defp lane_full?(_state, _pending, []), do: false

  defp lane_full?(state, pending, added) do
    lanes = MapSet.new(added, &lane/1)

    pending
    |> Enum.reduce(%{}, fn {_key, entry}, usage ->
      lane = lane(entry.event)

      if MapSet.member?(lanes, lane) do
        size = :erlang.external_size(entry.event)
        Map.update(usage, lane, {1, size}, fn {n, bytes} -> {n + 1, bytes + size} end)
      else
        usage
      end
    end)
    |> Enum.any?(fn {_lane, {n, bytes}} ->
      n > state.max_pending or bytes > state.max_lane_bytes
    end)
  end

  # Numbers each new event in the order this call received it.
  defp stage(event, {pending, added, seq}, receipts) do
    key = event_key(event)

    if Map.has_key?(pending, key) or MapSet.member?(receipts, key) do
      {pending, added, seq}
    else
      entry = %{event: event, attempts: 0, due: 0, seq: seq}
      {Map.put(pending, key, entry), [event | added], seq + 1}
    end
  end

  # Events that name no account come from no collector (both set matched_did);
  # a host or test can still hand one to the store. They share one lane of
  # their own: ordered among themselves, and never queued behind or ahead of
  # an account's events.
  defp lane(event) do
    case event[:matched_did] || event["matched_did"] do
      did when is_binary(did) -> did
      _ -> :no_account
    end
  end

  # The earliest-accepted pending event of each lane with nothing in flight.
  defp idle_lane_heads(state) do
    Enum.reduce(state.data.pending, %{}, fn {key, %{seq: seq} = entry}, heads ->
      lane = lane(entry.event)

      case heads do
        _ when is_map_key(state.workers, lane) -> heads
        %{^lane => {_, %{seq: earlier}}} when earlier < seq -> heads
        _ -> Map.put(heads, lane, {key, entry})
      end
    end)
  end

  defp start_delivery(state, lane, key, entry) do
    parent = self()

    {pid, ref} =
      :erlang.spawn_opt(
        fn -> send(parent, {:delivered, self(), AtMcp.Deliver.deliver(entry.event)}) end,
        [:link, :monitor]
      )

    timer = Process.send_after(self(), {:delivery_timeout, ref}, state.timeout_ms)
    worker = %{pid: pid, ref: ref, key: key, timer: timer}
    %{state | workers: Map.put(state.workers, lane, worker)}
  end

  defp worker_by_ref(state, ref),
    do: Enum.find(state.workers, fn {_lane, worker} -> worker.ref == ref end)

  defp finish(state, lane, :ok) do
    {%{key: key}, workers} = Map.pop!(state.workers, lane)

    data = %{
      state.data
      | pending: Map.delete(state.data.pending, key),
        receipts: Enum.take([key | state.data.receipts], state.max_receipts)
    }

    state = commit(%{state | workers: workers}, data)
    send(self(), :drain)
    state
  end

  # The failed event keeps its sequence number, so it stays at the head of its
  # lane and the events behind it wait out its backoff.
  defp finish(state, lane, {:error, reason}) do
    {%{key: key}, workers} = Map.pop!(state.workers, lane)
    entry = Map.fetch!(state.data.pending, key)
    attempts = min(entry.attempts + 1, 20)
    delay = min(state.retry_ms * Integer.pow(2, attempts - 1), state.max_retry_ms)
    now = state.clock.()

    # When the event first failed and what the consumer said last, kept with the
    # event so an operator sees a stalled lane, and since when, across restarts.
    entry =
      entry
      |> Map.merge(%{attempts: attempts, due: now + delay, last_error: describe(reason)})
      |> Map.put_new(:failing_since, now)

    Logger.warning("AtMcp inbound delivery retained for retry: #{inspect(reason)}")

    state =
      commit(%{state | workers: workers}, %{
        state.data
        | pending: Map.put(state.data.pending, key, entry)
      })

    send(self(), :drain)
    state
  end

  # What the operator reads for a failed delivery: the shape of the consumer's
  # answer, short. Its text is left out, because a consumer's answer can carry
  # the event it was sent or its own credentials; the log line keeps it whole.
  defp describe(reason), do: reason |> redact() |> inspect(limit: 10, charlists: :as_lists)

  defp redact(text) when is_binary(text), do: :redacted
  defp redact([_ | _] = list) when is_list(list), do: redact_list(list)

  defp redact(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> redact_list() |> List.to_tuple()

  defp redact(%module{} = struct) when is_atom(module),
    do: Map.merge(struct, struct |> Map.from_struct() |> redact())

  defp redact(map) when is_map(map), do: Map.new(map, fn {k, v} -> {redact(k), redact(v)} end)
  defp redact(other), do: other

  # A list of character codes is text too.
  defp redact_list(list) do
    if :io_lib.printable_unicode_list(list), do: :redacted, else: redact_items(list)
  end

  defp redact_items([head | tail]) when is_list(tail), do: [redact(head) | redact_items(tail)]
  defp redact_items([head | tail]), do: [redact(head) | redact(tail)]
  defp redact_items([]), do: []

  # URI + recipient deduplicates stream and notification collection for the same
  # record. Record updates deliberately do not trigger an extra host wake.
  defp event_key(event) do
    did = event[:matched_did] || event["matched_did"]
    uri = event[:uri] || event["uri"]
    :crypto.hash(:sha256, :erlang.term_to_binary(if uri, do: {did, uri}, else: event))
  end

  defp latest(old, new) when is_integer(new) and new > 0, do: max(old || 0, new)
  defp latest(old, _), do: old

  defp load!(path) do
    case File.read(path) do
      {:ok, binary} ->
        # Decoded without [:safe] on purpose. The checkpoint is a file this
        # module wrote itself, mode 0600 inside its own 0700 state directory;
        # it is not untrusted input. [:safe] guards against atom table
        # exhaustion from a hostile peer, and its failure mode here was refusing
        # to start: an event key like :thread_root_uri exists only in the
        # collector module that produced it, and on a fresh VM that module has
        # not been loaded, so the decode raised and took the application down
        # with every pending event still on disk. Preloading the producing
        # modules cannot hold — moving one field between modules silently breaks
        # cold start again. Trust in the bytes is not trust in their shape: the
        # structural checks below still reject a damaged checkpoint rather than
        # resetting it.
        %{version: 1, cursor: _, pending: pending, receipts: receipts} =
          data =
          :erlang.binary_to_term(binary)

        true = is_map(pending) and is_list(receipts)
        accounts = Map.get(data, :accounts, %{})

        true =
          is_map(accounts) and
            Enum.all?(accounts, fn {id, r} ->
              is_binary(id) and is_map(r) and is_boolean(r.disabled) and
                (is_nil(r.did) or is_binary(r.did))
            end)

        notifications = Map.get(data, :notifications, %{})

        true =
          is_map(notifications) and
            Enum.all?(notifications, fn {did, watermark} ->
              is_binary(did) and byte_size(did) > 0 and is_integer(watermark) and watermark > 0
            end)

        {pending, next_seq} = sequence!(pending, Map.get(data, :next_seq, 0))

        data
        |> Map.put(:accounts, accounts)
        |> Map.put(:notifications, notifications)
        |> Map.put(:pending, pending)
        |> Map.put(:next_seq, next_seq)

      {:error, :enoent} ->
        %{
          version: 1,
          cursor: nil,
          pending: %{},
          receipts: [],
          accounts: %{},
          notifications: %{},
          next_seq: 0
        }

      {:error, reason} ->
        raise File.Error, reason: reason, action: "read", path: path
    end
  end

  # Checks each pending entry and gives every one an acceptance sequence number.
  #
  # A file written before sequence numbers existed has entries without one. It
  # recorded no acceptance order, so there is none to recover; those entries
  # are numbered in the term order of their keys, after any entry that already
  # has a number. Key order is the same on every load and every VM, so an
  # unnumbered queue restarts in the same order until the next commit writes
  # the numbers down. The format stays version 1 because the fields are
  # additive: a build that predates them ignores them and keeps its queue.
  defp sequence!(pending, next_seq) do
    true = is_integer(next_seq) and next_seq >= 0

    true =
      Enum.all?(pending, fn {_key, entry} ->
        is_map(entry) and is_map(entry.event) and is_integer(entry.attempts) and
          is_integer(entry.due) and
          (not is_map_key(entry, :seq) or (is_integer(entry.seq) and entry.seq >= 0))
      end)

    {numbered, unnumbered} =
      Enum.split_with(pending, fn {_, entry} -> is_map_key(entry, :seq) end)

    seqs = Enum.map(numbered, fn {_, entry} -> entry.seq end)
    true = length(Enum.uniq(seqs)) == length(seqs)
    first = Enum.max([next_seq | Enum.map(seqs, &(&1 + 1))])

    renumbered =
      unnumbered
      |> Enum.sort()
      |> Enum.with_index(first)
      |> Map.new(fn {{key, entry}, seq} -> {key, Map.put(entry, :seq, seq)} end)

    {Map.merge(Map.new(numbered), renumbered), first + map_size(renumbered)}
  end

  defp commit(%{data: data} = state, data), do: state

  defp commit(state, data) do
    tmp = state.path <> ".tmp"
    {:ok, file} = :file.open(String.to_charlist(tmp), [:write, :binary, :raw])

    try do
      File.chmod!(tmp, 0o600)
      :ok = :file.write(file, :erlang.term_to_binary(data))
      :ok = :file.sync(file)
    after
      :file.close(file)
    end

    File.rename!(tmp, state.path)
    %{state | data: data}
  end
end
