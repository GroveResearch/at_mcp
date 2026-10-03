defmodule AtMcp.Inbound do
  @moduledoc """
  Shared Jetstream inbound ears for N AtMcp identities on one BEAM.

  ## How matching works

  A mention, reply or quote aimed at a tracked DID is a commit in *another*
  repository, so a consumer cannot subscribe with `wanted_dids: [self]`. One
  stream serves every identity instead:

  1. Subscribe with `wanted_collections: AtMcp.Network.inbound_collections()` and
     **empty** `wanted_dids` (a server-side collection slice of the firehose).
  2. Filter each commit with `AtMcp.Inbound.Match` against the registry of
     tracked DIDs.
  3. Accept the matched events into `AtMcp.Inbound.Store`, which delivers them,
     and fan out `{:at_mcp_listen, event}` to subscribers for the matched DIDs.

  One cursor covers every tracked DID, so when the store refuses a batch
  because one account's lane is full, the stream pauses for all of them until
  that lane drains. The notification poll, which is per account, keeps
  collecting for the others.

  Credentials are never shared. Tracking a DID does not grant write access —
  each `AtMcp.Effects` session stays private to its identity.

  ## Ops / cost

  Collection runs through a `AtMcp.Stream` adapter, which owns its service's
  filter, option names and message shape. The current adapter is Jetstream v1
  through ProtoRune's client; it subscribes to a slice of record collections
  with no DID filter, so expect steady JSON commit volume. Identity and account
  events arrive regardless of the collection filter; `AtMcp.Inbound.Match` drops
  the ones no tracked DID authored.

  Jetstream v2 has the knobs this filter lacks — an event-kind filter, sequence
  cursors and historical replay. Reaching them means another module
  implementing `AtMcp.Stream`, not new options here.

  Inbound persists the last cursor its adapter reports and resumes from it on
  restart, so consumers must be idempotent: a service may redeliver a handful of
  events around the cursor. `AtMcp.Notifications` is the default account
  collector; this stream is an explicit opt-in for raw repository events.

  ## API

      AtMcp.Inbound.track("did:plc:alice")
      AtMcp.Inbound.untrack("did:plc:alice")
      AtMcp.Inbound.tracked_dids()
  """

  use GenServer

  # A restart delay, so a client that exits immediately cannot spin.
  @jetstream_restart_ms 1_000

  # How soon a batch refused by a full outbox is offered again. The stream is
  # paused meanwhile, so this only sets how quickly collection resumes once
  # delivery makes room.
  @retry_paused_ms 1_000

  require Logger

  alias AtMcp.Inbound.Match

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Register a DID for inbound fanout. `meta: %{owner: pid}` registrations are
  reference-counted and automatically released on owner death. Calls without
  an owner are manual registrations and require `untrack` to release.
  """
  def track(server \\ __MODULE__, did, meta \\ %{}) when is_binary(did) do
    GenServer.call(server, {:track, did, meta})
  end

  @doc "Stop tracking a DID. Jetstream stays up while any DID remains."
  def untrack(server \\ __MODULE__, did) when is_binary(did) do
    GenServer.call(server, {:untrack, did})
  end

  @doc "DIDs currently tracked for inbound fanout."
  def tracked_dids(server \\ __MODULE__) do
    GenServer.call(server, :tracked_dids)
  end

  @doc "Inject a service-shaped event, as a stream adapter would decode one."
  def inject(server \\ __MODULE__, event) do
    GenServer.cast(server, {:inject, AtMcp.Stream.Event.from(event)})
  end

  @doc """
  Last delivered Jetstream `time_us` cursor held by Inbound, or `nil`.

  Updated on every event (live or inject). Passed as `:cursor` when
  (re)starting the Jetstream consumer so reconnects resume without a full
  live tip jump. Survives last-untrack stop; checkpointed to
  `AtMcp.Inbound.Store` for VM restarts. Matched events
  are committed atomically with their cursor before host delivery; unmatched
  traffic checkpoints once per second and may replay after a crash.
  """
  def cursor(server \\ __MODULE__) do
    GenServer.call(server, :cursor)
  end

  @impl true
  def init(opts) do
    enabled? =
      Keyword.get(opts, :enabled, Application.get_env(:at_mcp, :jetstream_enabled, false))

    # Not a module attribute: the collections belong to the configured network,
    # which is read when Inbound starts rather than when this module compiles.
    collections = Keyword.get(opts, :wanted_collections, AtMcp.Network.inbound_collections())
    stream_mod = Keyword.get(opts, :stream, AtMcp.Stream.Jetstream)
    stream_name = Keyword.get(opts, :stream_name, AtMcp.Inbound.Stream)

    state = %{
      enabled?: enabled?,
      collections: collections,
      stream_mod: stream_mod,
      stream_name: stream_name,
      jetstream: nil,
      jetstream_ref: nil,
      # DID registrations are owned by Listen/Effects pids or explicitly manual.
      tracked: %{},
      owner_monitors: %{},
      # Also emit an own_repo echo when the commit author is tracked.
      echo_own?: Keyword.get(opts, :echo_own, true),
      store: Keyword.get(opts, :store, AtMcp.Inbound.Store),
      paused: nil,
      checkpoint_ms: Keyword.get(opts, :checkpoint_ms, 1_000),
      # The stream position to resume from on (re)start.
      cursor: load_cursor(opts)
    }

    Process.send_after(self(), :checkpoint, state.checkpoint_ms)
    {:ok, state}
  end

  @impl true
  def handle_call({:track, did, meta}, _from, state) do
    meta = meta || %{}
    owner = Map.get(meta, :owner)
    entry = Map.get(state.tracked, did, %{owners: MapSet.new(), manual?: false})

    {entry, monitors} =
      if is_pid(owner) do
        if MapSet.member?(entry.owners, owner) do
          {entry, state.owner_monitors}
        else
          ref = Process.monitor(owner)

          {%{entry | owners: MapSet.put(entry.owners, owner)},
           Map.put(state.owner_monitors, ref, {did, owner})}
        end
      else
        {%{entry | manual?: true}, state.owner_monitors}
      end

    state = %{state | tracked: Map.put(state.tracked, did, entry), owner_monitors: monitors}
    state = maybe_start_jetstream(state)
    {:reply, :ok, state}
  end

  def handle_call({:untrack, did}, _from, state) do
    tracked = Map.delete(state.tracked, did)

    monitors =
      Enum.reduce(state.owner_monitors, state.owner_monitors, fn
        {ref, {^did, _}}, acc ->
          Process.demonitor(ref, [:flush])
          Map.delete(acc, ref)

        _, acc ->
          acc
      end)

    state = %{state | tracked: tracked, owner_monitors: monitors}
    state = maybe_stop_jetstream(state)
    {:reply, :ok, state}
  end

  def handle_call(:tracked_dids, _from, state) do
    {:reply, Map.keys(state.tracked), state}
  end

  def handle_call(:cursor, _from, state) do
    {:reply, state.cursor, state}
  end

  @impl true
  def handle_cast({:inject, event}, state) do
    {:noreply, handle_event(event, state)}
  end

  @impl true
  def handle_info({:at_mcp_stream_event, event}, state) do
    {:noreply, handle_event(event, state)}
  end

  # The stream client owns its own socket reconnect; this covers the process
  # itself exiting. Without it, collection stops silently until something tracks
  # a DID or resumes from pause — the checkpoint tick does not restart it.
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{jetstream_ref: ref} = state) do
    Logger.warning("AtMcp.Inbound Jetstream exited (#{inspect(reason)}); restarting")
    Process.send_after(self(), :restart_jetstream, @jetstream_restart_ms)
    {:noreply, %{state | jetstream: nil, jetstream_ref: nil}}
  end

  def handle_info(:restart_jetstream, state) do
    {:noreply, maybe_start_jetstream(state)}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.owner_monitors, ref) do
      {nil, _} ->
        {:noreply, state}

      {{did, owner}, monitors} ->
        entry = Map.fetch!(state.tracked, did)
        entry = %{entry | owners: MapSet.delete(entry.owners, owner)}

        tracked =
          if MapSet.size(entry.owners) == 0 and not entry.manual?,
            do: Map.delete(state.tracked, did),
            else: Map.put(state.tracked, did, entry)

        {:noreply, maybe_stop_jetstream(%{state | tracked: tracked, owner_monitors: monitors})}
    end
  end

  def handle_info(:checkpoint, state) do
    :ok = AtMcp.Inbound.Store.checkpoint(state.store, state.cursor)
    Process.send_after(self(), :checkpoint, state.checkpoint_ms)
    {:noreply, state}
  end

  def handle_info(:retry_paused, %{paused: {events, cursor}} = state) do
    case accept(events, cursor, state) do
      {:ok, state} ->
        {:noreply, maybe_start_jetstream(%{state | paused: nil})}

      {:error, :full} ->
        Process.send_after(self(), :retry_paused, @retry_paused_ms)
        {:noreply, state}
    end
  end

  # Anything unrecognized may be the stream client's own message shape, which
  # only its adapter knows.
  def handle_info(message, state) do
    case state.stream_mod.decode(message) do
      {:ok, event} -> handle_info({:at_mcp_stream_event, event}, state)
      :ignore -> {:noreply, state}
    end
  end

  defp maybe_stop_jetstream(%{tracked: tracked, jetstream: pid} = state)
       when map_size(tracked) == 0 and is_pid(pid) do
    Logger.info("AtMcp.Inbound Jetstream stopped (no tracked DIDs)")
    end_jetstream(state)
  end

  defp maybe_stop_jetstream(state), do: state

  # Ending the stream on purpose releases the monitor with it. A stop that left
  # the reference in place would come back as a DOWN, which Inbound can only read
  # as a crash: it would log the deliberate pause as an exit and schedule a
  # restart nobody asked for. There is one way to end this stream, and it does
  # both halves.
  defp end_jetstream(%{jetstream: pid} = state) when is_pid(pid) do
    demonitor_jetstream(state)
    stop_jetstream(pid)
    %{state | jetstream: nil, jetstream_ref: nil}
  end

  defp end_jetstream(state), do: %{state | jetstream: nil, jetstream_ref: nil}

  defp demonitor_jetstream(%{jetstream_ref: ref}) when is_reference(ref),
    do: Process.demonitor(ref, [:flush])

  defp demonitor_jetstream(_state), do: :ok

  defp stop_jetstream(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      # Prefer normal stop so a linked Inbound (start_link from Jetstream) is not
      # taken down by a non-normal EXIT — tests also link Inbound to the case.
      try do
        GenServer.stop(pid, :normal, 1_000)
      catch
        :exit, _ ->
          Process.exit(pid, :kill)
          :ok
      end
    else
      :ok
    end
  end

  defp maybe_start_jetstream(%{paused: paused} = state) when not is_nil(paused), do: state

  defp maybe_start_jetstream(%{jetstream: pid} = state) when is_pid(pid) do
    if Process.alive?(pid) do
      state
    else
      maybe_start_jetstream(%{state | jetstream: nil})
    end
  end

  defp maybe_start_jetstream(%{enabled?: false} = state), do: state

  defp maybe_start_jetstream(%{tracked: tracked} = state) when map_size(tracked) == 0, do: state

  defp maybe_start_jetstream(state) do
    case start_jetstream(state) do
      {:ok, pid} ->
        Logger.info(
          "AtMcp.Inbound Jetstream started (collections=#{inspect(state.collections)}, wanted_dids=[] — inbound via client Match)"
        )

        %{state | jetstream: pid, jetstream_ref: Process.monitor(pid)}

      {:error, reason} ->
        Logger.warning("AtMcp.Inbound Jetstream failed: #{inspect(reason)}")
        state
    end
  end

  defp start_jetstream(state) do
    # The adapter owns its service's filter and option names; AtMcp asks for the
    # record types it matches on and where to resume.
    state.stream_mod.start_link(
      handler: self(),
      collections: state.collections,
      cursor: state.cursor,
      name: state.stream_name
    )
  end

  # While paused, the stream is disconnected. Already buffered events are
  # discarded and replayed from the last accepted cursor after capacity returns.
  defp handle_event(_event, %{paused: paused} = state) when not is_nil(paused), do: state

  defp handle_event(event, state) do
    cursor = event_cursor(event, state.cursor)

    events =
      Match.match_dids(event, Map.keys(state.tracked))
      |> Enum.filter(fn {_did, reasons} -> deliver_reasons?(reasons, state.echo_own?) end)
      |> Enum.map(fn {did, reasons} -> summarize(event, did, reasons) end)

    case events do
      [] ->
        %{state | cursor: cursor}

      _ ->
        case accept(events, cursor, state) do
          {:ok, state} ->
            state

          {:error, :full} ->
            Logger.error("AtMcp inbound outbox full; pausing Jetstream without advancing cursor")
            Process.send_after(self(), :retry_paused, @retry_paused_ms)
            %{end_jetstream(state) | paused: {events, cursor}}
        end
    end
  end

  defp accept(events, cursor, state) do
    case AtMcp.Inbound.Store.accept(state.store, events, cursor) do
      {:ok, added} ->
        Enum.each(added, fn summary ->
          AtMcp.Listen.notify(summary, :events)
          AtMcp.Listen.notify(summary, {:did, summary.matched_did})
        end)

        {:ok, %{state | cursor: cursor}}

      {:error, :full} = error ->
        error
    end
  end

  defp event_cursor(event, old) do
    case event.cursor do
      n when is_integer(n) and n > 0 -> max(old || 0, n)
      _ -> old
    end
  end

  defp load_cursor(opts) do
    Keyword.get(opts, :cursor) ||
      Application.get_env(:at_mcp, :jetstream_cursor) ||
      AtMcp.Inbound.Store.status(Keyword.get(opts, :store, AtMcp.Inbound.Store)).cursor
  end

  defp deliver_reasons?(reasons, echo_own?) do
    inbound = reasons -- [:own_repo]
    inbound != [] or (echo_own? and :own_repo in reasons)
  end

  defp summarize(event, matched_did, reasons) do
    inbound_reasons = Enum.reject(reasons, &(&1 == :own_repo))
    inbound? = inbound_reasons != []

    kind =
      cond do
        :reply in reasons -> :inbound_reply
        :mention in reasons -> :inbound_mention
        :quote in reasons -> :inbound_quote
        :like in reasons -> :inbound_like
        :repost in reasons -> :inbound_repost
        :own_repo in reasons -> :own_repo_commit
        true -> :inbound_match
      end

    %{
      did: author,
      collection: collection,
      rkey: rkey,
      cid: cid,
      cursor: time_us,
      operation: operation,
      record: record
    } = event

    uri =
      if is_binary(author) and is_binary(collection) and is_binary(rkey) do
        "at://#{author}/#{collection}/#{rkey}"
      else
        nil
      end

    text = record_text(record)
    reply_parent = reply_parent_ref(record)

    %{
      source: :inbound,
      kind: kind,
      reasons: reasons,
      matched_did: matched_did,
      author_did: author,
      did: author,
      collection: collection,
      rkey: rkey,
      uri: uri,
      cid: cid,
      operation: operation,
      time_us: time_us,
      inbound?: inbound?,
      # The parent URI is already in the Jetstream record; the parent's text
      # would need another fetch, so it is omitted.
      text: text,
      reply_parent_uri: reply_parent[:uri],
      reply_parent_cid: reply_parent[:cid],
      reply_root_uri: reply_parent[:root_uri],
      subject_uri: AtMcp.Inbound.Match.subject_uri(collection, record)
    }
    |> Map.merge(
      if collection == AtMcp.Network.collection(:post),
        do: AtMcp.Post.content(%{uri: uri, record: record}),
        else: %{}
    )
    |> Map.merge(
      AtMcp.Inbound.Match.thread_refs(reasons, reply_parent[:root_uri], reply_parent[:uri], uri)
    )
    |> reject_nils()
  end

  defp record_text(record) when is_map(record) do
    case Map.get(record, "text") || Map.get(record, :text) do
      text when is_binary(text) and text != "" -> text
      _ -> nil
    end
  end

  defp record_text(_), do: nil

  # Cheap reply parent from the post record (no network).
  defp reply_parent_ref(record) when is_map(record) do
    reply = Map.get(record, "reply") || Map.get(record, :reply)

    parent = dig_map(reply, ["parent"]) || dig_map(reply, [:parent])
    root = dig_map(reply, ["root"]) || dig_map(reply, [:root])

    %{
      uri: dig_map(parent, ["uri"]) || dig_map(parent, [:uri]),
      cid: dig_map(parent, ["cid"]) || dig_map(parent, [:cid]),
      root_uri: dig_map(root, ["uri"]) || dig_map(root, [:uri])
    }
  end

  defp reply_parent_ref(_), do: %{}

  defp dig_map(nil, _), do: nil
  defp dig_map(map, [key]) when is_map(map), do: Map.get(map, key)

  defp dig_map(map, [key | rest]) when is_map(map) do
    case Map.get(map, key) do
      next when is_map(next) -> dig_map(next, rest)
      _ -> nil
    end
  end

  defp dig_map(_, _), do: nil

  defp reject_nils(map) do
    Map.reject(map, fn {_k, v} -> is_nil(v) end)
  end
end
