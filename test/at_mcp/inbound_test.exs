defmodule AtMcp.InboundTest do
  use ExUnit.Case, async: false

  defmodule FakeStream do
    use Agent

    def start_link(opts) do
      case :persistent_term.get(:at_mcp_inbound_js_parent, nil) do
        nil -> :ok
        parent -> send(parent, {:inbound_js_started, opts})
      end

      Agent.start_link(fn -> opts end, name: Keyword.get(opts, :name, __MODULE__))
    end
  end

  setup do
    unless Process.whereis(AtMcp.Listen.Registry) do
      {:ok, _} = Registry.start_link(keys: :duplicate, name: AtMcp.Listen.Registry)
    end

    :persistent_term.put(:at_mcp_inbound_js_parent, self())
    :persistent_term.erase({AtMcp.Inbound, :jetstream_cursor})
    Application.delete_env(:at_mcp, :jetstream_cursor)
    AtMcp.Deliver.clear_callback()

    on_exit(fn ->
      :persistent_term.erase(:at_mcp_inbound_js_parent)
      :persistent_term.erase({AtMcp.Inbound, :jetstream_cursor})
      Application.delete_env(:at_mcp, :jetstream_cursor)
      AtMcp.Deliver.clear_callback()

      for name <- [AtMcp.Inbound.Jetstream, FakeStream] do
        if pid = Process.whereis(name) do
          try do
            Agent.stop(pid)
          catch
            :exit, _ -> :ok
          end
        end
      end
    end)

    dir =
      Path.join(System.tmp_dir!(), "at_mcp-inbound-test-#{System.unique_integer([:positive])}")

    store = start_supervised!({AtMcp.Inbound.Store, name: nil, state_dir: dir, retry_ms: 20})
    on_exit(fn -> File.rm_rf!(dir) end)
    %{store: store}
  end

  @us "did:plc:at_mcp-us"
  @other "did:plc:at_mcp-other"

  test "inbound reply wakes AtMcp without notification poll", %{store: store} do
    name = :"inbound_#{System.unique_integer([:positive])}"
    js_name = :"inbound_js_#{System.unique_integer([:positive])}"

    {:ok, inbound} =
      AtMcp.Inbound.start_link(
        name: name,
        store: store,
        enabled: true,
        stream: FakeStream,
        stream_name: js_name
      )

    parent = self()
    AtMcp.Deliver.set_callback(fn event -> send(parent, {:deliver, event}) end)
    assert {:ok, _} = AtMcp.Listen.subscribe(:events)
    assert {:ok, _} = AtMcp.Listen.subscribe({:did, @us})

    assert :ok = AtMcp.Inbound.track(inbound, @us)
    assert_receive {:inbound_js_started, opts}, 1_000
    assert opts[:collections]
    assert "app.bsky.feed.post" in opts[:collections]
    assert opts[:handler] == inbound

    reply = %{
      type: :commit,
      did: @other,
      collection: "app.bsky.feed.post",
      rkey: "reply1",
      operation: :create,
      cid: "bafyreply",
      time_us: 1,
      record: %{
        "text" => "re: you",
        "reply" => %{
          "parent" => %{"uri" => "at://#{@us}/app.bsky.feed.post/orig", "cid" => "bafy0"},
          "root" => %{"uri" => "at://#{@us}/app.bsky.feed.post/orig", "cid" => "bafy0"}
        }
      }
    }

    :ok = AtMcp.Inbound.inject(inbound, reply)

    assert_receive {:at_mcp_listen, listen_event}, 500
    assert listen_event.source == :inbound
    assert listen_event.inbound? == true
    assert listen_event.kind == :inbound_reply
    assert listen_event.matched_did == @us
    assert listen_event.author_did == @other
    assert listen_event.text == "re: you"
    assert listen_event.reply_parent_uri == "at://#{@us}/app.bsky.feed.post/orig"

    assert_receive {:deliver, deliver_event}, 500
    assert deliver_event.source == :inbound
    assert deliver_event.inbound? == true
    assert deliver_event.matched_did == @us
    assert deliver_event.text == "re: you"
    assert deliver_event.reply_parent_uri == "at://#{@us}/app.bsky.feed.post/orig"
  end

  test "unrelated commit does not fan out", %{store: store} do
    name = :"inbound_neg_#{System.unique_integer([:positive])}"
    js_name = :"inbound_js_neg_#{System.unique_integer([:positive])}"

    {:ok, inbound} =
      AtMcp.Inbound.start_link(
        name: name,
        store: store,
        enabled: true,
        stream: FakeStream,
        stream_name: js_name
      )

    parent = self()
    AtMcp.Deliver.set_callback(fn event -> send(parent, {:deliver, event}) end)
    assert {:ok, _} = AtMcp.Listen.subscribe(:events)

    assert :ok = AtMcp.Inbound.track(inbound, @us)
    assert_receive {:inbound_js_started, _}, 1_000

    :ok =
      AtMcp.Inbound.inject(inbound, %{
        type: :commit,
        did: @other,
        collection: "app.bsky.feed.post",
        rkey: "nope",
        record: %{"text" => "unrelated"}
      })

    refute_receive {:at_mcp_listen, _}, 200
    refute_receive {:deliver, _}, 200
  end

  test "N tracked DIDs: fanout only to matched identity", %{store: store} do
    alice = "did:plc:alice"
    bob = "did:plc:bob"
    name = :"inbound_n_#{System.unique_integer([:positive])}"
    js_name = :"inbound_js_n_#{System.unique_integer([:positive])}"

    {:ok, inbound} =
      AtMcp.Inbound.start_link(
        name: name,
        store: store,
        enabled: true,
        stream: FakeStream,
        stream_name: js_name
      )

    assert {:ok, _} = AtMcp.Listen.subscribe({:did, alice})
    assert {:ok, _} = AtMcp.Listen.subscribe({:did, bob})

    assert :ok = AtMcp.Inbound.track(inbound, alice)
    assert :ok = AtMcp.Inbound.track(inbound, bob)
    assert_receive {:inbound_js_started, _}, 1_000

    :ok =
      AtMcp.Inbound.inject(inbound, %{
        type: :commit,
        did: @other,
        collection: "app.bsky.feed.post",
        rkey: "m1",
        record: %{
          "text" => "@alice",
          "facets" => [
            %{
              "features" => [
                %{"$type" => "app.bsky.richtext.facet#mention", "did" => alice}
              ]
            }
          ]
        }
      })

    # Long enough that this asserts the event reached only the matched identity,
    # not how quickly collection, matching and fanout complete on a busy runner.
    assert_receive {:at_mcp_listen, %{matched_did: ^alice, kind: :inbound_mention}}, 2_000
    refute_receive {:at_mcp_listen, %{matched_did: ^bob}}, 200
  end

  test "two identities share one Jetstream; deliver only matching DID", %{store: store} do
    alice = "did:plc:grug-a"
    bob = "did:plc:grug-b"
    name = :"inbound_ab_#{System.unique_integer([:positive])}"
    js_name = :"inbound_js_ab_#{System.unique_integer([:positive])}"

    {:ok, inbound} =
      AtMcp.Inbound.start_link(
        name: name,
        store: store,
        enabled: true,
        stream: FakeStream,
        stream_name: js_name
      )

    parent = self()

    # Two deliver paths, routed by DID; no credential is shared between them.
    deliver_a = fn event -> send(parent, {:deliver_a, event}) end
    deliver_b = fn event -> send(parent, {:deliver_b, event}) end

    assert {:ok, _} = AtMcp.Listen.subscribe({:did, alice})
    assert {:ok, _} = AtMcp.Listen.subscribe({:did, bob})

    assert :ok = AtMcp.Inbound.track(inbound, alice, %{label: :at_mcp_a})
    assert :ok = AtMcp.Inbound.track(inbound, bob, %{label: :at_mcp_b})
    assert_receive {:inbound_js_started, opts}, 1_000
    assert opts[:collections]

    # A deliver callback that routes by matched_did, as a host mapping DID to
    # agent would.
    AtMcp.Deliver.set_callback(fn
      %{matched_did: ^alice} = e -> deliver_a.(e)
      %{matched_did: ^bob} = e -> deliver_b.(e)
      _ -> :ok
    end)

    :ok =
      AtMcp.Inbound.inject(inbound, %{
        type: :commit,
        did: @other,
        collection: "app.bsky.feed.post",
        rkey: "to-a",
        record: %{
          "text" => "hey A",
          "reply" => %{
            "parent" => %{"uri" => "at://#{alice}/app.bsky.feed.post/p", "cid" => "c"},
            "root" => %{"uri" => "at://#{alice}/app.bsky.feed.post/p", "cid" => "c"}
          }
        }
      })

    assert_receive {:at_mcp_listen, %{matched_did: ^alice}}, 500
    assert_receive {:deliver_a, %{matched_did: ^alice, inbound?: true}}, 500
    refute_receive {:deliver_b, _}, 200
    refute_receive {:at_mcp_listen, %{matched_did: ^bob}}, 200

    :ok =
      AtMcp.Inbound.inject(inbound, %{
        type: :commit,
        did: @other,
        collection: "app.bsky.feed.post",
        rkey: "to-b",
        record: %{
          "text" => "@bob",
          "facets" => [
            %{
              "features" => [
                %{"$type" => "app.bsky.richtext.facet#mention", "did" => bob}
              ]
            }
          ]
        }
      })

    assert_receive {:at_mcp_listen, %{matched_did: ^bob, kind: :inbound_mention}}, 500
    assert_receive {:deliver_b, %{matched_did: ^bob}}, 500
    refute_receive {:deliver_a, _}, 200
  end

  test "like wakes as inbound_like not inbound_reply", %{store: store} do
    name = :"inbound_like_#{System.unique_integer([:positive])}"
    js_name = :"inbound_like_js_#{System.unique_integer([:positive])}"

    {:ok, inbound} =
      AtMcp.Inbound.start_link(
        name: name,
        store: store,
        enabled: true,
        stream: FakeStream,
        stream_name: js_name
      )

    parent = self()
    AtMcp.Deliver.set_callback(fn event -> send(parent, {:deliver, event}) end)
    assert :ok = AtMcp.Inbound.track(inbound, @us)
    assert_receive {:inbound_js_started, _}, 1_000

    :ok =
      AtMcp.Inbound.inject(inbound, %{
        type: :commit,
        did: @other,
        collection: "app.bsky.feed.like",
        rkey: "lk1",
        record: %{"subject" => %{"uri" => "at://#{@us}/app.bsky.feed.post/orig", "cid" => "c"}}
      })

    assert_receive {:deliver, %{kind: :inbound_like, reasons: reasons, matched_did: @us}}, 500
    assert :like in reasons
    refute :reply in reasons
  end

  # Pausing is a deliberate stop. A monitor left attached would arrive back as a
  # DOWN, so a full outbox would log "Jetstream exited (normal)" and schedule a
  # restart: the operator would be told the stream had crashed, and the one
  # signal that means it really did would stop being trustworthy.
  test "a full outbox pauses the stream without reporting a crash" do
    dir = Path.join(System.tmp_dir!(), "at_mcp-pause-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)

    full_store =
      start_supervised!(
        {AtMcp.Inbound.Store, name: nil, state_dir: dir, retry_ms: 20, max_pending: 0},
        id: :pause_store
      )

    name = :"inbound_pause_#{System.unique_integer([:positive])}"
    js_name = :"inbound_pause_js_#{System.unique_integer([:positive])}"

    {:ok, inbound} =
      AtMcp.Inbound.start_link(
        name: name,
        store: full_store,
        enabled: true,
        stream: FakeStream,
        stream_name: js_name
      )

    assert :ok = AtMcp.Inbound.track(inbound, @us)
    assert_receive {:inbound_js_started, _}, 1_000
    assert is_pid(Process.whereis(js_name))

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        :ok = AtMcp.Inbound.inject(inbound, mention_of(@us))
        assert until(fn -> is_nil(Process.whereis(js_name)) end)
        # Long enough for a scheduled restart warning to land if one was armed.
        Process.sleep(120)
        _ = :sys.get_state(inbound)
      end)

    assert log =~ "outbox full"
    refute log =~ "Jetstream exited"
  end

  defp until(fun, remaining \\ 100)
  defp until(_fun, 0), do: false

  defp until(fun, remaining) do
    if fun.() do
      true
    else
      Process.sleep(10)
      until(fun, remaining - 1)
    end
  end

  defp mention_of(did) do
    %{
      type: :commit,
      did: @other,
      collection: "app.bsky.feed.post",
      rkey: "pause1",
      operation: :create,
      cid: "bafypause",
      time_us: 1,
      record: %{"text" => "hey @you", "facets" => [mention_facet(did)]}
    }
  end

  defp mention_facet(did) do
    %{
      "index" => %{"byteStart" => 4, "byteEnd" => 8},
      "features" => [%{"$type" => "app.bsky.richtext.facet#mention", "did" => did}]
    }
  end

  test "untrack last DID stops Jetstream so it can restart later", %{store: store} do
    name = :"inbound_stop_#{System.unique_integer([:positive])}"
    js_name = :"inbound_stop_js_#{System.unique_integer([:positive])}"

    {:ok, inbound} =
      AtMcp.Inbound.start_link(
        name: name,
        store: store,
        enabled: true,
        stream: FakeStream,
        stream_name: js_name
      )

    assert :ok = AtMcp.Inbound.track(inbound, @us)
    assert_receive {:inbound_js_started, _opts}, 1_000
    pid = Process.whereis(js_name)
    assert is_pid(pid)
    assert Process.alive?(pid)

    assert :ok = AtMcp.Inbound.untrack(inbound, @us)
    # Inbound shuts the Agent down asynchronously.
    Process.sleep(50)
    refute Process.whereis(js_name)

    # Tracking again starts a fresh stream.
    assert :ok = AtMcp.Inbound.track(inbound, @us)
    assert_receive {:inbound_js_started, _}, 1_000
    assert is_pid(Process.whereis(js_name))
  end

  test "persists time_us cursor and resumes Jetstream after last untrack", %{store: store} do
    name = :"inbound_cursor_#{System.unique_integer([:positive])}"
    js_name = :"inbound_cursor_js_#{System.unique_integer([:positive])}"

    {:ok, inbound} =
      AtMcp.Inbound.start_link(
        name: name,
        store: store,
        enabled: true,
        stream: FakeStream,
        stream_name: js_name
      )

    assert AtMcp.Inbound.cursor(inbound) == nil

    assert :ok = AtMcp.Inbound.track(inbound, @us)
    assert_receive {:inbound_js_started, opts}, 1_000
    assert opts[:cursor] == nil

    :ok =
      AtMcp.Inbound.inject(inbound, %{
        type: :commit,
        did: @other,
        collection: "app.bsky.feed.post",
        rkey: "c1",
        time_us: 1_700_000_000_000_001,
        record: %{
          "text" => "re: you",
          "reply" => %{
            "parent" => %{"uri" => "at://#{@us}/app.bsky.feed.post/orig", "cid" => "bafy0"},
            "root" => %{"uri" => "at://#{@us}/app.bsky.feed.post/orig", "cid" => "bafy0"}
          }
        }
      })

    # The cursor is written by a cast, so wait for it to land.
    assert wait_until(fn -> AtMcp.Inbound.cursor(inbound) == 1_700_000_000_000_001 end)

    assert :ok = AtMcp.Inbound.untrack(inbound, @us)
    Process.sleep(50)
    refute Process.whereis(js_name)
    # The cursor outlives the stream it came from.
    assert AtMcp.Inbound.cursor(inbound) == 1_700_000_000_000_001

    assert :ok = AtMcp.Inbound.track(inbound, @us)
    assert_receive {:inbound_js_started, resume_opts}, 1_000
    assert resume_opts[:cursor] == 1_700_000_000_000_001
  end

  test "Inbound start_link honors explicit recovery cursor", %{store: store} do
    name = :"inbound_pt_#{System.unique_integer([:positive])}"
    js_name = :"inbound_pt_js_#{System.unique_integer([:positive])}"

    {:ok, inbound} =
      AtMcp.Inbound.start_link(
        name: name,
        store: store,
        enabled: true,
        stream: FakeStream,
        stream_name: js_name,
        cursor: 42
      )

    assert AtMcp.Inbound.cursor(inbound) == 42
    assert :ok = AtMcp.Inbound.track(inbound, @us)
    assert_receive {:inbound_js_started, opts}, 1_000
    assert opts[:cursor] == 42
  end

  test "full outbox pauses stream and resumes only after durable acceptance", %{store: _store} do
    dir = Path.join(System.tmp_dir!(), "at_mcp-pause-#{System.unique_integer([:positive])}")

    store =
      start_supervised!(
        {AtMcp.Inbound.Store, name: nil, state_dir: dir, max_pending: 1, retry_ms: 10},
        id: :pause_store
      )

    on_exit(fn -> File.rm_rf!(dir) end)
    js_name = :"pause_js_#{System.unique_integer([:positive])}"

    inbound =
      start_supervised!(
        {AtMcp.Inbound,
         name: nil, store: store, enabled: true, stream: FakeStream, stream_name: js_name}
      )

    AtMcp.Inbound.track(inbound, @us)
    assert_receive {:inbound_js_started, _}

    make_event = fn n ->
      %{
        type: :commit,
        did: @other,
        collection: "app.bsky.feed.post",
        rkey: "pause-#{n}",
        time_us: n,
        record: %{"reply" => %{"parent" => %{"uri" => "at://#{@us}/app.bsky.feed.post/orig"}}}
      }
    end

    AtMcp.Inbound.inject(inbound, make_event.(1))
    assert wait_until(fn -> AtMcp.Inbound.cursor(inbound) == 1 end)
    AtMcp.Inbound.inject(inbound, make_event.(2))
    assert wait_until(fn -> Process.whereis(js_name) == nil end)
    AtMcp.Inbound.inject(inbound, make_event.(3))
    assert AtMcp.Inbound.cursor(inbound) == 1
    assert AtMcp.Inbound.Store.status(store).cursor == 1
    parent = self()
    AtMcp.Deliver.set_callback(fn e -> send(parent, {:resumed_delivery, e.time_us}) end)
    assert_receive {:resumed_delivery, 1}, 1_000
    assert_receive {:resumed_delivery, 2}, 2_000
    assert_receive {:inbound_js_started, opts}, 2_000
    assert opts[:cursor] == 2
    # The disconnected stream will replay 3; it was not acknowledged or queued
    # while full. Inject its replay through the same consumer entry point.
    AtMcp.Inbound.inject(inbound, make_event.(3))
    assert_receive {:resumed_delivery, 3}, 1_000
    assert AtMcp.Inbound.cursor(inbound) == 3
  end

  test "unmatched stream checkpoint survives an Inbound restart", %{store: store} do
    inbound =
      start_supervised!(
        {AtMcp.Inbound, name: nil, store: store, enabled: false, checkpoint_ms: 10}
      )

    AtMcp.Inbound.inject(inbound, %{type: :commit, did: @other, time_us: 9988, record: %{}})
    assert wait_until(fn -> AtMcp.Inbound.Store.status(store).cursor == 9988 end)
    stop_supervised!(AtMcp.Inbound)
    inbound = start_supervised!({AtMcp.Inbound, name: nil, store: store, enabled: false})
    assert AtMcp.Inbound.cursor(inbound) == 9988
  end

  test "tracked ownership releases last DID only after every registrar stops", %{store: store} do
    js_name = :"owned_js_#{System.unique_integer([:positive])}"

    inbound =
      start_supervised!(
        {AtMcp.Inbound,
         name: nil, store: store, enabled: true, stream: FakeStream, stream_name: js_name}
      )

    owner_a = spawn(fn -> Process.sleep(:infinity) end)
    owner_b = spawn(fn -> Process.sleep(:infinity) end)
    AtMcp.Inbound.track(inbound, @us, %{owner: owner_a})
    AtMcp.Inbound.track(inbound, @us, %{owner: owner_b})
    assert_receive {:inbound_js_started, _}
    Process.exit(owner_a, :kill)
    Process.sleep(20)
    assert AtMcp.Inbound.tracked_dids(inbound) == [@us]
    assert Process.whereis(js_name)
    Process.exit(owner_b, :kill)
    assert wait_until(fn -> AtMcp.Inbound.tracked_dids(inbound) == [] end)
    refute Process.whereis(js_name)
  end

  # Same derivation as the notifications collector, so a host parses one shape
  # whichever collector fired. The Jetstream commit carries no handle, so author
  # stays a DID here rather than being resolved with a per-event network call.
  test "Jetstream reply carries the thread root and its parent", %{store: store} do
    event =
      deliver_commit(store, "js_reply", %{
        collection: "app.bsky.feed.post",
        record: %{
          "text" => "re: you",
          "reply" => %{
            "parent" => %{"uri" => "at://#{@us}/app.bsky.feed.post/mid", "cid" => "bafymid"},
            "root" => %{"uri" => "at://#{@us}/app.bsky.feed.post/root", "cid" => "bafyroot"}
          }
        }
      })

    assert event.kind == :inbound_reply
    assert event.thread_root_uri == "at://#{@us}/app.bsky.feed.post/root"
    assert event.thread_parent_uri == "at://#{@us}/app.bsky.feed.post/mid"
    assert event.text == "re: you"
    assert event.author_did == @other
    assert event.matched_did == @us
    assert event.uri == "at://#{@other}/app.bsky.feed.post/js_reply"
    assert event.reply_root_uri == "at://#{@us}/app.bsky.feed.post/root"
    assert event.reply_parent_uri == "at://#{@us}/app.bsky.feed.post/mid"
  end

  test "Jetstream top-level mention is its own thread root and has no parent", %{store: store} do
    event =
      deliver_commit(store, "js_mention", %{
        collection: "app.bsky.feed.post",
        record: %{
          "text" => "@us hello",
          "facets" => [
            %{"features" => [%{"$type" => "app.bsky.richtext.facet#mention", "did" => @us}]}
          ]
        }
      })

    assert event.kind == :inbound_mention
    assert event.thread_root_uri == event.uri
    refute Map.has_key?(event, :thread_parent_uri)
    assert event.text == "@us hello"
  end

  # A record may declare a parent and no root; AtMcp.Inbound.Match accepts it as a
  # reply, because it matches on either ref. Rooting such a post at itself would
  # name a thread that cannot contain the parent it also publishes.
  test "Jetstream reply declaring only a parent is rooted at that parent", %{store: store} do
    event =
      deliver_commit(store, "js_noroot", %{
        collection: "app.bsky.feed.post",
        record: %{
          "text" => "re: you",
          "reply" => %{
            "parent" => %{"uri" => "at://#{@us}/app.bsky.feed.post/mid", "cid" => "bafymid"}
          }
        }
      })

    assert event.kind == :inbound_reply
    assert event.thread_root_uri == "at://#{@us}/app.bsky.feed.post/mid"
    assert event.thread_parent_uri == "at://#{@us}/app.bsky.feed.post/mid"
    refute event.thread_root_uri == event.uri
    refute Map.has_key?(event, :reply_root_uri)
  end

  # A record naming itself as its own parent declares an ancestor it cannot have.
  test "Jetstream reply naming itself as its parent publishes no parent", %{store: store} do
    self_uri = "at://#{@other}/app.bsky.feed.post/js_cycle"

    event =
      deliver_commit(store, "js_cycle", %{
        collection: "app.bsky.feed.post",
        record: %{
          "text" => "loop",
          "reply" => %{
            "parent" => %{"uri" => self_uri, "cid" => "bafyc"},
            "root" => %{"uri" => "at://#{@us}/app.bsky.feed.post/root", "cid" => "bafyr"}
          }
        }
      })

    assert event.uri == self_uri
    refute Map.has_key?(event, :thread_parent_uri)
    assert event.thread_root_uri == "at://#{@us}/app.bsky.feed.post/root"
    # The unresolved record-level name still reports what the record declared.
    assert event.reply_parent_uri == self_uri
  end

  test "Jetstream reply naming itself as its root falls back to the parent", %{store: store} do
    self_uri = "at://#{@other}/app.bsky.feed.post/js_selfroot"

    event =
      deliver_commit(store, "js_selfroot", %{
        collection: "app.bsky.feed.post",
        record: %{
          "text" => "loop",
          "reply" => %{
            "parent" => %{"uri" => "at://#{@us}/app.bsky.feed.post/mid", "cid" => "bafym"},
            "root" => %{"uri" => self_uri, "cid" => "bafys"}
          }
        }
      })

    assert event.uri == self_uri
    assert event.thread_root_uri == "at://#{@us}/app.bsky.feed.post/mid"
  end

  test "Jetstream like publishes no thread root or parent, and names its subject", %{store: store} do
    event =
      deliver_commit(store, "js_like", %{
        collection: "app.bsky.feed.like",
        record: %{"subject" => %{"uri" => "at://#{@us}/app.bsky.feed.post/orig", "cid" => "c"}}
      })

    assert event.kind == :inbound_like
    refute Map.has_key?(event, :thread_root_uri)
    refute Map.has_key?(event, :thread_parent_uri)
    # docs/operations.md sends a host to subject_uri for a like; both collectors
    # have to publish it, or that instruction is false for this one.
    assert event.subject_uri == "at://#{@us}/app.bsky.feed.post/orig"
  end

  test "Jetstream repost publishes its subject and no thread", %{store: store} do
    event =
      deliver_commit(store, "js_repost", %{
        collection: "app.bsky.feed.repost",
        record: %{"subject" => %{"uri" => "at://#{@us}/app.bsky.feed.post/orig", "cid" => "c"}}
      })

    assert event.kind == :inbound_repost
    assert event.subject_uri == "at://#{@us}/app.bsky.feed.post/orig"
    refute Map.has_key?(event, :thread_root_uri)
  end

  # A quote that is itself a reply is posted into someone else's thread, so the
  # thread root does not name the quoted post. subject_uri is the only pointer.
  test "Jetstream quote inside another thread names the quoted post as its subject", %{
    store: store
  } do
    event =
      deliver_commit(store, "js_quotereply", %{
        collection: "app.bsky.feed.post",
        record: %{
          "text" => "look at this",
          "embed" => %{
            "$type" => "app.bsky.embed.record",
            "record" => %{"uri" => "at://#{@us}/app.bsky.feed.post/mine", "cid" => "bafyq"}
          },
          "reply" => %{
            "parent" => %{"uri" => "at://did:plc:stranger/app.bsky.feed.post/p", "cid" => "p"},
            "root" => %{"uri" => "at://did:plc:stranger/app.bsky.feed.post/r", "cid" => "r"}
          }
        }
      })

    assert :quote in event.reasons
    assert event.thread_root_uri == "at://did:plc:stranger/app.bsky.feed.post/r"
    assert event.subject_uri == "at://#{@us}/app.bsky.feed.post/mine"
  end

  # Echoing the account's own commits is on by default, and such an event is a
  # post with no thread context. The doc says so; this pins it.
  test "own-repo echo commit publishes no thread root or parent", %{store: store} do
    event =
      deliver_commit(store, "js_own", %{
        author: @us,
        collection: "app.bsky.feed.post",
        record: %{"text" => "my own post"}
      })

    assert event.kind == :own_repo_commit
    assert event.reasons == [:own_repo]
    refute Map.has_key?(event, :thread_root_uri)
    refute Map.has_key?(event, :thread_parent_uri)
  end

  defp deliver_commit(store, rkey, %{collection: collection, record: record} = opts) do
    author = Map.get(opts, :author, @other)
    name = :"inbound_#{rkey}_#{System.unique_integer([:positive])}"
    js_name = :"inbound_js_#{rkey}_#{System.unique_integer([:positive])}"

    inbound =
      start_supervised!(
        {AtMcp.Inbound,
         name: nil, store: store, enabled: true, stream: FakeStream, stream_name: js_name},
        id: name
      )

    parent = self()
    AtMcp.Deliver.set_callback(fn event -> send(parent, {:deliver, event}) end)
    assert :ok = AtMcp.Inbound.track(inbound, @us)
    assert_receive {:inbound_js_started, _}, 1_000

    :ok =
      AtMcp.Inbound.inject(inbound, %{
        type: :commit,
        did: author,
        collection: collection,
        rkey: rkey,
        operation: :create,
        cid: "bafy#{rkey}",
        time_us: System.unique_integer([:positive]),
        record: record
      })

    assert_receive {:deliver, event}, 1_000
    event
  end

  defp wait_until(fun, attempts \\ 20) do
    cond do
      fun.() ->
        true

      attempts <= 0 ->
        false

      true ->
        Process.sleep(25)
        wait_until(fun, attempts - 1)
    end
  end
end
