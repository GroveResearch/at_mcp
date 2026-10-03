defmodule AtMcp.Inbound.StoreTest do
  use ExUnit.Case, async: false
  alias AtMcp.Inbound.Store

  defmodule Receiver do
    use Plug.Router
    plug(:match)
    plug(:dispatch)

    post "/inbound" do
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      {status, owner} = Agent.get(conn.private.receiver, & &1)
      send(owner, {:http_delivery, Jason.decode!(body)})
      Plug.Conn.send_resp(conn, status, "accepted")
    end

    def init(opts), do: opts
    def call(conn, opts), do: super(Plug.Conn.put_private(conn, :receiver, opts[:receiver]), opts)
  end

  setup do
    AtMcp.Deliver.clear_callback()
    AtMcp.Deliver.clear_callback(:all)

    dir =
      Path.join(
        System.tmp_dir!(),
        "at_mcp-store-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    on_exit(fn ->
      AtMcp.Deliver.clear_callback()
      AtMcp.Deliver.clear_callback(:all)
      File.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  test "a stalled lane is reported with its reason and first failure, across a restart", %{
    dir: dir
  } do
    parent = self()

    AtMcp.Deliver.set_callback("did:plc:alice", fn _ ->
      send(parent, :refused)
      {:error, {:http_status, 422}}
    end)

    pid = store(dir)
    assert {:ok, _} = Store.accept(pid, [event(1), event(2)])
    assert_receive :refused, 1_000
    assert_receive :refused, 1_000

    %{"did:plc:alice" => stall} = Store.stalls(pid)
    assert stall.reason =~ "422"
    assert stall.pending == 2
    assert stall.attempts >= 2
    refute Map.has_key?(Store.stalls(pid), "did:plc:bob")

    stop_supervised!(Store)
    pid = store(dir)
    assert %{"did:plc:alice" => %{since_unix: since}} = Store.stalls(pid)
    assert since == stall.since_unix

    AtMcp.Deliver.set_callback("did:plc:alice", fn _ -> :ok end)
    assert eventually(fn -> Store.stalls(pid) == %{} end)
  end

  test "a stalled lane's reason keeps the consumer's answer's shape and none of its text", %{
    dir: dir
  } do
    parent = self()

    # A consumer's answer can carry what it was sent, or its own credentials.
    AtMcp.Deliver.set_callback("did:plc:alice", fn _ ->
      send(parent, :refused)

      {:error,
       {:rejected, "the post body", ~c"the post body as a charlist",
        %RuntimeError{message: "Bearer secret-token"}, authorization: "Bearer secret-token"}}
    end)

    pid = store(dir)
    assert {:ok, _} = Store.accept(pid, [event(1)])
    assert_receive :refused, 1_000

    %{"did:plc:alice" => %{reason: reason}} = Store.stalls(pid)
    assert reason =~ ":rejected"
    assert reason =~ "RuntimeError"
    refute reason =~ "post body"
    refute reason =~ "secret-token"
  end

  defp event(n, did \\ "did:plc:alice"),
    do: %{source: :inbound, matched_did: did, uri: "at://did:plc:author/app.bsky.feed.post/#{n}"}

  defp store(dir, opts \\ []) do
    start_supervised!(
      {Store, Keyword.merge([name: nil, state_dir: dir, retry_ms: 20, max_retry_ms: 40], opts)}
    )
  end

  test "HTTP outage remains on disk across process restart and retries to the correct DID", %{
    dir: dir
  } do
    owner = self()
    receiver = start_supervised!({Agent, fn -> {503, owner} end})
    ref = make_ref()

    start_supervised!(
      {Plug.Cowboy,
       scheme: :http, plug: {Receiver, receiver: receiver}, options: [port: 0, ref: ref]}
    )

    port = :ranch.get_port(ref)

    AtMcp.Deliver.set_callback(fn event ->
      AtMcp.Deliver.HTTPBridge.post_inbound("http://127.0.0.1:#{port}/inbound", "", event)
    end)

    AtMcp.Deliver.set_callback("did:plc:bob", fn e -> send(owner, {:bob, e}) end)
    pid = store(dir)
    assert {:ok, [_]} = Store.accept(pid, [event(1)], 100)
    # Every delivery says which network it happened on. A DID does not say where it
    # lives, so without this a host tells an inhabitant on one network it is on
    # another — and AtMcp is the only party that knows.
    assert_receive {:http_delivery,
                    %{
                      "matched_did" => "did:plc:alice",
                      "network" => %{"name" => "bluesky", "label" => "Bluesky"}
                    }},
                   1_000

    assert Store.status(pid).pending == 1
    stop_supervised!(Store)
    Agent.update(receiver, fn {_, owner} -> {200, owner} end)
    pid = store(dir)
    assert Store.status(pid).cursor == 100
    assert_receive {:http_delivery, %{"matched_did" => "did:plc:alice"}}, 1_000
    assert eventually(fn -> Store.status(pid).pending == 0 end)
    assert {:ok, []} = Store.accept(pid, [event(1)], 99)
    assert Store.status(pid).cursor == 100
    assert {:ok, [_]} = Store.accept(pid, [event(2, "did:plc:bob")], 101)
    assert_receive {:bob, %{matched_did: "did:plc:bob"}}, 1_000
    refute_receive {:http_delivery, %{"matched_did" => "did:plc:bob"}}
  end

  test "missing callback, exceptions and timeouts retain work without blocking acceptance", %{
    dir: dir
  } do
    owner = self()
    pid = store(dir, timeout_ms: 30)
    assert {:ok, [_]} = Store.accept(pid, [event(1)], 1)
    Process.sleep(30)
    assert Store.status(pid).pending == 1
    AtMcp.Deliver.set_callback(fn _ -> raise "outage" end)
    Process.sleep(50)
    assert Store.status(pid).pending == 1

    AtMcp.Deliver.set_callback(fn _ ->
      send(owner, :started)
      Process.sleep(:infinity)
    end)

    assert_receive :started, 500
    assert {:ok, [_]} = Store.accept(pid, [event(2)], 2)
    assert Store.status(pid).cursor == 2
    AtMcp.Deliver.set_callback(fn e -> send(owner, {:accepted, e.uri}) end)
    assert eventually(fn -> Store.status(pid).pending == 0 end)
    assert_receive {:accepted, _}
    assert_receive {:accepted, _}
  end

  test "capacity never acknowledges overflow; receipts are bounded and backup shares dedupe", %{
    dir: dir
  } do
    pid = store(dir, max_pending: 1, max_receipts: 2)
    assert {:ok, [_]} = Store.accept(pid, [event(1)], 10)
    assert {:error, :full} = Store.accept(pid, [event(2)], 20)
    assert Store.status(pid).cursor == 10
    assert Store.status(pid).pending == 1
    AtMcp.Deliver.set_callback(fn _ -> :ok end)
    assert eventually(fn -> Store.status(pid).pending == 0 end)
    assert {:ok, []} = Store.accept(pid, [%{event(1) | source: :notifications}], 11)

    for n <- 2..4 do
      assert {:ok, [_]} = Store.accept(pid, [event(n)], n + 10)
      assert eventually(fn -> Store.status(pid).pending == 0 end)
    end

    assert Store.status(pid).receipts == 2
    assert File.stat!(Path.join(dir, "inbound.term")).size < 1_000
  end

  test "byte capacity rejects an oversized event without advancing cursor", %{dir: dir} do
    pid = store(dir, max_bytes: 1_000)

    assert {:error, :full} =
             Store.accept(pid, [Map.put(event(1), :text, String.duplicate("x", 2_000))], 100)

    assert %{cursor: nil, pending: 0} = Store.status(pid)
  end

  test "pending events, cursor and receipts survive a fresh VM, including abrupt halt", %{
    dir: dir
  } do
    paths = Path.wildcard(Path.expand("_build/test/lib/*/ebin"))
    args = Enum.flat_map(paths, &["-pa", &1])

    script = """
    {:ok, store} = AtMcp.Inbound.Store.start_link(name: nil, state_dir: #{inspect(dir)})
    {:ok, [_]} = AtMcp.Inbound.Store.accept(store, [%{source: :inbound, kind: :inbound_reply, matched_did: "did:plc:alice", uri: "at://author/post/1", text: "fresh VM"}], 12345)
    System.halt(0)
    """

    assert {_output, 0} =
             System.cmd(System.find_executable("elixir"), args ++ ["-e", script],
               stderr_to_stdout: true
             )

    script = """
    parent = self()
    AtMcp.Deliver.set_callback(fn event -> send(parent, {:event, event}); :ok end)
    {:ok, store} = AtMcp.Inbound.Store.start_link(name: nil, state_dir: #{inspect(dir)}, retry_ms: 1)
    %{cursor: 12345} = AtMcp.Inbound.Store.status(store)
    receive do
      {:event, %{text: "fresh VM", matched_did: "did:plc:alice"}} -> :ok
    after 2000 -> raise "pending event lost across VM halt"
    end
    Stream.repeatedly(fn -> AtMcp.Inbound.Store.status(store).pending end)
    |> Enum.reduce_while(nil, fn pending, _ ->
      if pending == 0, do: {:halt, :ok}, else: (Process.sleep(5); {:cont, nil})
    end)
    GenServer.stop(store)
    """

    assert {output, 0} =
             System.cmd(System.find_executable("elixir"), args ++ ["-e", script],
               stderr_to_stdout: true
             )

    refute output =~ "pending event lost"
    # Load the second VM's receipt in the test VM: replay must not wake again.
    pid = store(dir)
    assert %{cursor: 12345, pending: 0, receipts: 1} = Store.status(pid)

    assert {:ok, []} =
             Store.accept(pid, [%{matched_did: "did:plc:alice", uri: "at://author/post/1"}])
  end

  test "declared notification summary survives a cold VM without backend loading", %{dir: dir} do
    args = Path.wildcard(Path.expand("_build/test/lib/*/ebin")) |> Enum.flat_map(&["-pa", &1])

    writer = """
    summary = AtMcp.Summary.extract(:notification, %{
      "uri" => "at://author/post/summary", "reason" => "reply",
      "reasonSubject" => "at://owner/post/parent", "record" => %{"text" => "retained 🌱",
      "reply" => %{"parent" => %{"uri" => "at://owner/post/parent"},
                   "root" => %{"uri" => "at://owner/post/root"}}}
    }) |> Map.delete(:is_read) |> Map.merge(%{source: :notifications,
      kind: :inbound_notification, matched_did: "did:plc:alice", inbound?: true})
    # The thread refs come from the collectors' own derivation, so this event
    # carries every key a delivered notification carries, wherever it is
    # produced. A field that moves between modules must not change the outcome.
    event = Map.merge(summary, AtMcp.Inbound.Match.thread_refs(summary[:reason],
      summary[:reply_root_uri], summary[:reply_parent_uri], summary[:uri]))
    File.mkdir_p!(#{inspect(dir)})
    File.write!(#{inspect(Path.join(dir, "expected.json"))}, Jason.encode!(event))
    {:ok, store} = AtMcp.Inbound.Store.start_link(name: nil, state_dir: #{inspect(dir)})
    {:ok, [_]} = AtMcp.Inbound.Store.accept(store, [event])
    System.halt(0)
    """

    assert {_, 0} =
             System.cmd(System.find_executable("elixir"), args ++ ["-e", writer],
               stderr_to_stdout: true
             )

    # This process deliberately never loads the backend or constructs a summary.
    # Referring to summary atom keys here would hide the cold decoder defect.
    # The child writes its JSON to a file rather than stdout: with no locale in
    # the environment the child's tty encoding is latin1, and non-ASCII text
    # would come back escaped as a codepoint literal instead of UTF-8 bytes.
    delivered = Path.join(dir, "delivered.json")

    reader = """
    parent = self()
    AtMcp.Deliver.set_callback(fn event -> send(parent, {:delivered, event}); :ok end)
    {:ok, _} = AtMcp.Inbound.Store.start_link(name: nil, state_dir: #{inspect(dir)})
    receive do
      {:delivered, event} -> File.write!(#{inspect(delivered)}, Jason.encode!(event))
    after 2000 -> raise "notification lost"
    end
    """

    assert {_, 0} =
             System.cmd(System.find_executable("elixir"), args ++ ["-e", reader],
               stderr_to_stdout: true
             )

    assert Jason.decode!(File.read!(delivered)) ==
             Jason.decode!(File.read!(Path.join(dir, "expected.json")))
  end

  test "a cold VM restores a pending event whose keys no loaded module defines", %{dir: dir} do
    # The checkpoint is AtMcp's own file, so it is decoded as trusted input. The
    # regression this pins: a key like :thread_root_uri lives only in the
    # collector that produced it, and a fresh VM has not loaded that collector
    # when the store starts. :field_no_module_defines stands for any such key,
    # including one a later refactor moves somewhere the store does not preload.
    event = %{
      source: :notifications,
      kind: :inbound_notification,
      matched_did: "did:plc:alice",
      inbound?: true,
      uri: "at://author/post/cold",
      cid: "bafycold",
      author_did: "did:plc:author",
      reason: :reply,
      subject_uri: "at://owner/post/parent",
      reply_parent_uri: "at://owner/post/parent",
      reply_root_uri: "at://owner/post/root",
      thread_root_uri: "at://owner/post/root",
      indexed_at: "2026-09-19T00:00:00.000Z",
      text: "cold start 🌱",
      field_no_module_defines: :value_no_module_defines
    }

    File.mkdir_p!(dir)

    File.write!(
      Path.join(dir, "inbound.term"),
      :erlang.term_to_binary(%{
        version: 1,
        cursor: 4242,
        pending: %{"cold-key" => %{event: event, attempts: 3, due: 0}},
        receipts: [],
        accounts: %{},
        notifications: %{}
      })
    )

    args = Path.wildcard(Path.expand("_build/test/lib/*/ebin")) |> Enum.flat_map(&["-pa", &1])
    delivered = Path.join(dir, "cold-delivered.json")

    reader = """
    parent = self()
    AtMcp.Deliver.set_callback(fn event -> send(parent, {:delivered, event}); :ok end)
    {:ok, _} = AtMcp.Inbound.Store.start_link(name: nil, state_dir: #{inspect(dir)})
    receive do
      {:delivered, event} -> File.write!(#{inspect(delivered)}, Jason.encode!(event))
    after 5000 -> raise "pending event lost"
    end
    """

    assert {_, 0} =
             System.cmd(System.find_executable("elixir"), args ++ ["-e", reader],
               stderr_to_stdout: true
             )

    assert Jason.decode!(File.read!(delivered)) == Jason.decode!(Jason.encode!(event))
  end

  test "a consumer that blocks one account does not hold another account's delivery", %{
    dir: dir
  } do
    owner = self()

    AtMcp.Deliver.set_callback("did:plc:alice", fn _ ->
      send(owner, {:alice_started, self()})

      receive do
        :release -> :ok
      end
    end)

    AtMcp.Deliver.set_callback("did:plc:bob", fn e -> send(owner, {:bob, e.uri}) end)
    pid = store(dir)
    assert {:ok, [_]} = Store.accept(pid, [event(1)], 1)
    assert_receive {:alice_started, alice}, 1_000
    assert {:ok, [_]} = Store.accept(pid, [event(2, "did:plc:bob")], 2)
    assert_receive {:bob, _}, 1_000
    assert Process.alive?(alice)
    assert eventually(fn -> Store.status(pid).pending == 1 end)
    send(alice, :release)
    assert eventually(fn -> Store.status(pid).pending == 0 end)
  end

  test "one account's events arrive in acceptance order, and a retry holds the ones behind it", %{
    dir: dir
  } do
    owner = self()
    failed_once = start_supervised!({Agent, fn -> false end})
    first = event(1).uri

    AtMcp.Deliver.set_callback("did:plc:alice", fn e ->
      send(owner, {:attempt, e.uri})

      if e.uri == first and not Agent.get_and_update(failed_once, &{&1, true}),
        do: {:error, :consumer_unavailable},
        else: :ok
    end)

    pid = store(dir)
    assert {:ok, [_, _, _]} = Store.accept(pid, [event(1), event(2), event(3)], 1)
    assert eventually(fn -> Store.status(pid).pending == 0 end)
    assert attempts() == [first, first, event(2).uri, event(3).uri]
  end

  test "an account's delivery order survives a store restart", %{dir: dir} do
    owner = self()
    # Accepted in an order that is neither numeric nor the order of the
    # events' keys, so only a persisted acceptance order reproduces it.
    accepted = Enum.map([5, 3, 9, 1, 7], &event/1)

    # The first store holds its first delivery in flight until it stops, so
    # no event has failed and none carries a retry time that could order it.
    AtMcp.Deliver.set_callback("did:plc:alice", fn _ ->
      send(owner, :holding)

      receive do
        :never -> :ok
      end
    end)

    pid = store(dir)
    Enum.each(accepted, fn e -> assert {:ok, [_]} = Store.accept(pid, [e]) end)
    assert_receive :holding, 1_000
    assert Store.status(pid).pending == 5
    stop_supervised!(Store)

    AtMcp.Deliver.set_callback("did:plc:alice", fn e -> send(owner, {:attempt, e.uri}) end)
    pid = store(dir)
    assert eventually(fn -> Store.status(pid).pending == 0 end)
    assert attempts() == Enum.map(accepted, & &1.uri)
  end

  test "a state file written before acceptance order was recorded loads and delivers everything",
       %{dir: dir} do
    owner = self()
    # Keys that sort after any the store mints, so an event accepted after the
    # upgrade would come first if key order alone chose the next delivery.
    key = fn n -> <<0xFF, n, 0::240>> end
    legacy = fn n, did -> %{event: event(n, did), attempts: 0, due: 0} end

    File.mkdir_p!(dir)

    File.write!(
      Path.join(dir, "inbound.term"),
      :erlang.term_to_binary(%{
        version: 1,
        cursor: 77,
        pending: %{
          key.(1) => legacy.(1, "did:plc:alice"),
          key.(2) => legacy.(2, "did:plc:alice"),
          key.(3) => legacy.(3, "did:plc:alice"),
          key.(4) => legacy.(4, "did:plc:bob")
        },
        receipts: [],
        accounts: %{},
        notifications: %{}
      })
    )

    first = event(1).uri

    AtMcp.Deliver.set_callback("did:plc:alice", fn e ->
      send(owner, {:attempt, e.uri})

      if e.uri == first do
        send(owner, {:holding, self()})

        receive do
          :release -> :ok
        end
      end
    end)

    AtMcp.Deliver.set_callback("did:plc:bob", fn e -> send(owner, {:bob, e.uri}) end)
    pid = store(dir)
    assert_receive {:holding, worker}, 1_000
    assert {:ok, [_]} = Store.accept(pid, [event(10)], 78)
    send(worker, :release)
    assert eventually(fn -> Store.status(pid).pending == 0 end)
    assert_received {:bob, _}
    assert attempts() == Enum.map([1, 2, 3, 10], &event(&1).uri)
    assert Store.status(pid).cursor == 78
  end

  test "a full account refuses only batches that add to it", %{dir: dir} do
    owner = self()
    # A consumer that never accepts alice's first event holds her lane for good;
    # pending events are never evicted, so her lane fills.
    AtMcp.Deliver.set_callback("did:plc:alice", fn _ -> {:error, :refused} end)
    AtMcp.Deliver.set_callback("did:plc:bob", fn e -> send(owner, {:bob, e.uri}) end)
    pid = store(dir, max_pending: 3)
    assert {:ok, [_, _, _]} = Store.accept(pid, [event(1), event(2), event(3)], 1)
    assert {:error, :full} = Store.accept(pid, [event(4)], 2)
    assert {:ok, [_]} = Store.accept(pid, [event(9, "did:plc:bob")], 2)
    assert_receive {:bob, _}, 1_000
    # A batch that adds to the full lane is refused whole, cursor included.
    assert {:error, :full} = Store.accept(pid, [event(10, "did:plc:bob"), event(5)], 3)
    assert Store.status(pid).cursor == 2
  end

  test "an account full by bytes refuses only its own events", %{dir: dir} do
    owner = self()
    AtMcp.Deliver.set_callback("did:plc:alice", fn _ -> {:error, :refused} end)
    AtMcp.Deliver.set_callback("did:plc:bob", fn e -> send(owner, {:bob, e.uri}) end)
    pid = store(dir, max_lane_bytes: 2_000)
    large = fn n, did -> Map.put(event(n, did), :text, String.duplicate("x", 1_500)) end
    assert {:ok, [_]} = Store.accept(pid, [large.(1, "did:plc:alice")], 1)
    assert {:error, :full} = Store.accept(pid, [large.(2, "did:plc:alice")], 2)
    assert {:ok, [_]} = Store.accept(pid, [large.(3, "did:plc:bob")], 2)
    assert_receive {:bob, _}, 1_000
  end

  test "disconnect stops only the disconnected account's delivery; terminate stops the rest", %{
    dir: dir
  } do
    owner = self()
    pid = store(dir)

    for {id, did} <- [{"alice", "did:plc:alice"}, {"bob", "did:plc:bob"}] do
      assert :ok = GenServer.call(pid, {:account, {:register, id}})
      assert :ok = GenServer.call(pid, {:account, {:bind, id, did}})

      # The callback traps exits, so the link alone does not stop it when
      # the store does; only the store's own terminate kills it.
      AtMcp.Deliver.set_callback(did, fn _ ->
        Process.flag(:trap_exit, true)
        send(owner, {:started, did, self()})

        receive do
          :never -> :ok
        end
      end)
    end

    assert {:ok, [_, _]} = Store.accept(pid, [event(1), event(2, "did:plc:bob")], 1)
    assert_receive {:started, "did:plc:alice", alice}, 1_000
    assert_receive {:started, "did:plc:bob", bob}, 1_000
    assert {:ok, ["alice"]} = GenServer.call(pid, {:account, {:disconnect, "alice"}})
    refute Process.alive?(alice)
    assert Process.alive?(bob)
    assert Store.status(pid).pending == 2
    stop_supervised!(Store)
    refute Process.alive?(bob)
  end

  test "damaged state fails startup instead of silently losing the queue", %{dir: dir} do
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "inbound.term"), "damaged")
    assert {:error, _} = start_supervised({Store, name: nil, state_dir: dir})
  end

  test "a damaged acceptance order fails startup instead of guessing one", %{dir: dir} do
    File.mkdir_p!(dir)
    entry = fn n, seq -> %{event: event(n), attempts: 0, due: 0, seq: seq} end

    for pending <- [
          %{"a" => entry.(1, 0), "b" => entry.(2, 0)},
          %{"a" => entry.(1, -1)},
          %{"a" => entry.(1, "0")},
          %{"a" => %{attempts: 0, due: 0, seq: 0}}
        ] do
      data = %{version: 1, cursor: nil, pending: pending, receipts: [], next_seq: 1}
      File.write!(Path.join(dir, "inbound.term"), :erlang.term_to_binary(data))
      assert {:error, _} = start_supervised({Store, name: nil, state_dir: dir})
    end
  end

  # Every delivery attempt the callbacks reported, in the order they ran.
  defp attempts do
    receive do
      {:attempt, uri} -> [uri | attempts()]
    after
      0 -> []
    end
  end

  defp eventually(fun, attempts \\ 100) do
    cond do
      fun.() ->
        true

      attempts == 0 ->
        false

      true ->
        Process.sleep(10)
        eventually(fun, attempts - 1)
    end
  end
end
