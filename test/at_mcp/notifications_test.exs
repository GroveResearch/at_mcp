defmodule AtMcp.NotificationsTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir
  @now DateTime.to_unix(~U[2026-09-13 18:00:00Z], :microsecond)
  @did "did:plc:paged"

  defmodule Backend do
    def login(_), do: {:ok, %{did: "did:plc:paged"}}

    def list_notifications(_, opts) do
      Agent.get(__MODULE__, fn %{pages: pages, owner: owner} ->
        send(owner, {:page, opts[:cursor]})
        Map.fetch!(pages, opts[:cursor])
      end)
    end

    def update_seen(_, datetime) do
      Agent.get(__MODULE__, fn %{owner: owner} -> send(owner, {:seen, datetime}) end)
      {:ok, %{ok: true}}
    end
  end

  setup %{tmp_dir: dir} do
    owner = self()

    start_supervised!(%{
      id: Backend,
      start:
        {Agent, :start_link, [fn -> %{owner: owner, pages: %{}, now: @now} end, [name: Backend]]}
    })

    effects = start_supervised!({AtMcp.Effects, backend: Backend})
    assert {:ok, _} = AtMcp.Effects.login(effects)
    store = start_supervised!({AtMcp.Inbound.Store, name: nil, state_dir: dir})
    AtMcp.Deliver.clear_callback()
    AtMcp.Deliver.clear_callback(:all)
    AtMcp.Deliver.clear_callback(@did)
    on_exit(fn -> AtMcp.Deliver.clear_callback(@did) end)
    %{effects: effects, store: store, dir: dir}
  end

  test "collects read notifications with subject context without marking the account seen", ctx do
    notification = item("reply", -10)
    pages(%{nil => page([notification])})
    parent = self()

    AtMcp.Deliver.set_callback(@did, fn event ->
      send(parent, {:delivered, event})
      :ok
    end)

    assert {:ok, _} = AtMcp.Listen.subscribe({:did, @did})
    poller = poller(ctx)
    send(poller, :poll)

    assert_receive {:delivered, event}, 2_000
    assert event.matched_did == @did
    assert event.source == :notifications
    assert event.reply_parent_uri == notification.reply_parent_uri
    assert event.subject_uri == notification.subject_uri
    assert event.indexed_at == notification.indexed_at
    assert_receive {:at_mcp_listen, ^event}
    refute_receive {:seen, _}

    send(poller, :poll)
    assert_receive {:page, nil}
    :sys.get_state(poller)
    refute_receive {:delivered, _}
  end

  test "first collection takes a recent window rather than waking the entire unread inbox", ctx do
    recent = Map.put(item("recent", -30), :is_read, false)
    ancient = Map.put(item("ancient", -86_400), :is_read, false)
    pages(%{nil => page([recent, ancient])})
    poller = poller(ctx)
    send(poller, :poll)
    assert_receive {:page, nil}, 2_000
    :sys.get_state(poller)
    assert AtMcp.Inbound.Store.status(ctx.store).pending == 1
    refute_receive {:seen, _}
  end

  test "continues through read pages to private watermark and stops before unrelated history",
       ctx do
    :ok = AtMcp.Inbound.Store.checkpoint_notifications(ctx.store, @did, @now - 600_000_000)

    pages(%{
      nil => page([item("first", -10)], "older"),
      "older" => page([item("second", -700)], "old"),
      "old" => page([item("ancient", -1000)], "must-not-fetch")
    })

    poller = poller(ctx)
    send(poller, :poll)
    assert_receive {:page, "old"}, 2_000
    :sys.get_state(poller)
    assert AtMcp.Inbound.Store.status(ctx.store).pending == 2
    assert AtMcp.Inbound.Store.notification_checkpoint(ctx.store, @did) == @now - 10_000_000
    refute_receive {:page, "must-not-fetch"}
    refute_receive {:seen, _}
  end

  # listNotifications pages newest first. A sweep is accepted as a whole, oldest
  # first, so a consumer sees a post before the reply that answers it.
  test "a sweep's notifications are delivered oldest first across its pages", ctx do
    :ok = AtMcp.Inbound.Store.checkpoint_notifications(ctx.store, @did, @now - 600_000_000)

    pages(%{
      nil => page([item("newest", -10), item("newer", -20)], "older"),
      "older" => page([item("older", -300), item("oldest", -400)])
    })

    parent = self()
    AtMcp.Deliver.set_callback(@did, fn event -> send(parent, {:delivered, event.text}) end)
    poller = poller(ctx)
    send(poller, :poll)

    delivered =
      for _ <- 1..4 do
        assert_receive {:delivered, text}, 2_000
        text
      end

    assert delivered == ["oldest", "older", "newer", "newest"]
  end

  test "empty page with continuation still fetches the next page", ctx do
    pages(%{nil => page([], "next"), "next" => page([item("next", -10)])})
    poller = poller(ctx)
    send(poller, :poll)
    assert_receive {:page, "next"}, 2_000
    :sys.get_state(poller)
    assert AtMcp.Inbound.Store.status(ctx.store).pending == 1
  end

  test "partial failure restarts from newest page without advancing or duplicating", ctx do
    boundary = @now - 600_000_000
    :ok = AtMcp.Inbound.Store.checkpoint_notifications(ctx.store, @did, boundary)
    pages(%{nil => page([item("first", -10)], "older"), "older" => {:error, :timeout}})
    poller = poller(ctx)
    send(poller, :poll)
    assert_receive {:page, "older"}, 2_000
    :sys.get_state(poller)
    assert AtMcp.Inbound.Store.notification_checkpoint(ctx.store, @did) == boundary
    # An incomplete sweep accepts nothing; the next one collects it again.
    assert AtMcp.Inbound.Store.status(ctx.store).pending == 0

    pages(%{nil => page([item("first", -10)], "older"), "older" => page([item("second", -500)])})
    send(poller, :poll)
    assert_receive {:page, "older"}, 2_000
    :sys.get_state(poller)
    assert AtMcp.Inbound.Store.status(ctx.store).pending == 2
    assert AtMcp.Inbound.Store.notification_checkpoint(ctx.store, @did) == @now - 10_000_000
  end

  test "initial network failure pins the boundary before a long outage", ctx do
    pages(%{nil => {:error, :timeout}})
    poller = poller(ctx)
    send(poller, :poll)
    assert_receive {:page, nil}, 2_000
    :sys.get_state(poller)
    assert AtMcp.Inbound.Store.notification_checkpoint(ctx.store, @did) == @now

    Agent.update(Backend, &%{&1 | now: @now + 3_600_000_000})
    pages(%{nil => page([item("during-outage", 60)])})
    stop_supervised!(AtMcp.Notifications)
    poller = poller(ctx)
    send(poller, :poll)
    assert_receive {:page, nil}, 2_000
    :sys.get_state(poller)
    assert AtMcp.Inbound.Store.status(ctx.store).pending == 1
  end

  test "restart uses durable boundary and overlap catches a late indexed item", ctx do
    pages(%{nil => page([item("first", 10)])})
    poller = poller(ctx)
    send(poller, :poll)
    assert_receive {:page, nil}, 2_000
    :sys.get_state(poller)
    stop_supervised!(AtMcp.Notifications)
    stop_supervised!(AtMcp.Inbound.Store)
    store = start_supervised!({AtMcp.Inbound.Store, name: nil, state_dir: ctx.dir})
    Agent.update(Backend, &%{&1 | now: @now + 3_600_000_000})
    pages(%{nil => page([item("first", 10), item("late", -120)])})
    poller = poller(%{ctx | store: store})
    send(poller, :poll)
    assert_receive {:page, nil}, 2_000
    :sys.get_state(poller)
    assert AtMcp.Inbound.Store.status(store).pending == 2
  end

  test "a sweep larger than the account's room accepts its oldest events and holds the checkpoint",
       ctx do
    stop_supervised!(AtMcp.Inbound.Store)

    store =
      start_supervised!({AtMcp.Inbound.Store, name: nil, state_dir: ctx.dir, max_pending: 50})

    boundary = @now - 600_000_000
    :ok = AtMcp.Inbound.Store.checkpoint_notifications(store, @did, boundary)
    items = for n <- 1..60, do: item("n#{n}", -n)
    pages(%{nil => page(items)})
    poller = poller(%{ctx | store: store})
    send(poller, :poll)
    assert_receive {:page, nil}, 2_000
    :sys.get_state(poller)
    assert AtMcp.Inbound.Store.status(store).pending == 50
    assert AtMcp.Inbound.Store.notification_checkpoint(store, @did) == boundary

    parent = self()
    AtMcp.Deliver.set_callback(@did, fn event -> send(parent, {:delivered, event.text}) end)
    assert_receive {:delivered, "n60"}, 2_000
  end

  test "full outbox does not advance an established checkpoint", ctx do
    stop_supervised!(AtMcp.Inbound.Store)

    store =
      start_supervised!({AtMcp.Inbound.Store, name: nil, state_dir: ctx.dir, max_pending: 0})

    boundary = @now - 600_000_000
    :ok = AtMcp.Inbound.Store.checkpoint_notifications(store, @did, boundary)
    pages(%{nil => page([item("full", -10)])})
    poller = poller(%{ctx | store: store})
    send(poller, :poll)
    assert_receive {:page, nil}, 2_000
    :sys.get_state(poller)
    assert AtMcp.Inbound.Store.status(store).pending == 0
    assert AtMcp.Inbound.Store.notification_checkpoint(store, @did) == boundary
    refute_receive {:seen, _}
  end

  test "malformed item cannot be silently skipped while checkpoint advances", ctx do
    boundary = @now - 600_000_000
    :ok = AtMcp.Inbound.Store.checkpoint_notifications(ctx.store, @did, boundary)
    pages(%{nil => page([Map.delete(item("broken", -10), :uri)])})
    poller = poller(ctx)
    send(poller, :poll)
    assert_receive {:page, nil}, 2_000
    :sys.get_state(poller)
    assert AtMcp.Inbound.Store.notification_checkpoint(ctx.store, @did) == boundary
    assert AtMcp.Inbound.Store.status(ctx.store).pending == 0
  end

  test "repeated pagination cursor cannot commit an incomplete sweep", ctx do
    boundary = @now - 600_000_000
    :ok = AtMcp.Inbound.Store.checkpoint_notifications(ctx.store, @did, boundary)

    pages(%{
      nil => page([item("first", -10)], "loop"),
      "loop" => page([item("second", -20)], "loop")
    })

    poller = poller(ctx)
    send(poller, :poll)
    assert_receive {:page, "loop"}, 2_000
    :sys.get_state(poller)
    assert AtMcp.Inbound.Store.notification_checkpoint(ctx.store, @did) == boundary
  end

  # A resident woken by a notification is given the thread to read, so every
  # notification publishes a thread root — including a top-level mention, whose
  # record declares no reply of its own.
  test "a reply notification carries the thread root, its parent, text and author", ctx do
    notification =
      Map.merge(item("reply1", -10), %{
        reason: "reply",
        reply_parent_uri: "at://did:plc:paged/app.bsky.feed.post/mid",
        reply_root_uri: "at://did:plc:paged/app.bsky.feed.post/root"
      })

    event = deliver_one(ctx, notification)

    assert event.thread_root_uri == "at://did:plc:paged/app.bsky.feed.post/root"
    assert event.thread_parent_uri == "at://did:plc:paged/app.bsky.feed.post/mid"
    assert event.text == "reply1"
    assert event.author == "alice.test"
    # The two inputs Dwell hashes into its source_id are untouched.
    assert event.uri == notification.uri
    assert event.matched_did == @did
    # The names that say "this record was a reply" keep their meaning.
    assert event.reply_root_uri == "at://did:plc:paged/app.bsky.feed.post/root"
    assert event.reply_parent_uri == "at://did:plc:paged/app.bsky.feed.post/mid"
  end

  test "a top-level mention is its own thread root and has no parent", ctx do
    notification =
      "mention1"
      |> item(-10)
      |> Map.drop([:reply_parent_uri, :reply_root_uri])
      |> Map.put(:reason, "mention")

    event = deliver_one(ctx, notification)

    assert event.thread_root_uri == notification.uri
    refute Map.has_key?(event, :thread_parent_uri)
    assert event.text == "mention1"
    assert event.author == "alice.test"
  end

  test "a top-level quote is its own thread root", ctx do
    notification =
      "quote1"
      |> item(-10)
      |> Map.drop([:reply_parent_uri, :reply_root_uri])
      |> Map.put(:reason, "quote")

    event = deliver_one(ctx, notification)
    assert event.thread_root_uri == notification.uri
  end

  # A like's uri is the like record, not a post. Publishing it as a thread root
  # would send the host to fetch a record that has no thread.
  test "a like notification publishes no thread root or parent", ctx do
    notification =
      Map.merge(item("like1", -10), %{
        reason: "like",
        uri: "at://did:plc:author/app.bsky.feed.like/like1"
      })

    event = deliver_one(ctx, notification)

    refute Map.has_key?(event, :thread_root_uri)
    refute Map.has_key?(event, :thread_parent_uri)
    assert event.subject_uri == "at://did:plc:paged/app.bsky.feed.post/parent"
  end

  # The same shape as the Jetstream path: a notification carrying a parent and no
  # root must not be rooted at itself, because the parent it also publishes is by
  # definition an ancestor that such a thread cannot contain.
  test "a reply notification declaring only a parent is rooted at that parent", ctx do
    notification =
      "noroot"
      |> item(-10)
      |> Map.merge(%{
        reason: "reply",
        reply_parent_uri: "at://did:plc:paged/app.bsky.feed.post/mid"
      })

    event = deliver_one(ctx, notification)

    assert event.thread_root_uri == "at://did:plc:paged/app.bsky.feed.post/mid"
    assert event.thread_parent_uri == "at://did:plc:paged/app.bsky.feed.post/mid"
    refute event.thread_root_uri == event.uri
  end

  # A reply that declared only a root: the root is the thread, and there is no
  # parent to publish. A host tells this apart from a top-level post by
  # thread_root_uri != uri, which is what docs/operations.md now states.
  test "a reply notification declaring only a root has a root and no parent", ctx do
    notification =
      "rootonly"
      |> item(-10)
      |> Map.drop([:reply_parent_uri])
      |> Map.merge(%{
        reason: "reply",
        reply_root_uri: "at://did:plc:paged/app.bsky.feed.post/root"
      })

    event = deliver_one(ctx, notification)

    assert event.thread_root_uri == "at://did:plc:paged/app.bsky.feed.post/root"
    refute event.thread_root_uri == event.uri
    refute Map.has_key?(event, :thread_parent_uri)
  end

  test "a reply notification naming itself as its parent publishes no parent", ctx do
    base = item("cycle", -10)

    notification =
      Map.merge(base, %{
        reason: "reply",
        reply_parent_uri: base.uri,
        reply_root_uri: base.uri
      })

    event = deliver_one(ctx, notification)

    refute Map.has_key?(event, :thread_parent_uri)
    assert event.thread_root_uri == base.uri
    # The unresolved record-level name still reports what the record declared.
    assert event.reply_parent_uri == base.uri
  end

  # A quote posted as a reply in someone else's thread: the thread root is that
  # thread, which need not mention the quoted post. subject_uri is the pointer.
  test "a quote notification inside another thread keeps the quoted post in subject_uri", ctx do
    notification =
      Map.merge(item("quotereply", -10), %{
        reason: "quote",
        subject_uri: "at://did:plc:paged/app.bsky.feed.post/mine",
        reply_parent_uri: "at://did:plc:stranger/app.bsky.feed.post/p",
        reply_root_uri: "at://did:plc:stranger/app.bsky.feed.post/r"
      })

    event = deliver_one(ctx, notification)

    assert event.thread_root_uri == "at://did:plc:stranger/app.bsky.feed.post/r"
    assert event.subject_uri == "at://did:plc:paged/app.bsky.feed.post/mine"
  end

  # Both collectors gate on AtMcp.Inbound.Match.post_reason?/1, so neither can
  # gain a post-bearing reason the other does not know about.
  test "both collectors gate thread context on the same reason list" do
    assert Enum.sort(AtMcp.Inbound.Match.post_reasons()) == [:mention, :quote, :reply]

    for reason <- ["mention", "reply", "quote"] do
      assert AtMcp.Inbound.Match.post_reason?(reason)
      assert AtMcp.Inbound.Match.post_reason?(String.to_existing_atom(reason))
    end

    for reason <- ["like", "repost"] do
      refute AtMcp.Inbound.Match.post_reason?(reason)
      refute AtMcp.Inbound.Match.post_reason?(String.to_existing_atom(reason))
    end

    refute AtMcp.Inbound.Match.post_reason?(:own_repo)
  end

  defp deliver_one(ctx, notification) do
    pages(%{nil => page([notification])})
    parent = self()

    AtMcp.Deliver.set_callback(@did, fn event ->
      send(parent, {:delivered, event})
      :ok
    end)

    poller = poller(ctx)
    send(poller, :poll)
    assert_receive {:delivered, event}, 2_000
    event
  end

  test "an enabled poller sweeps on the interval the operator set", ctx do
    on_exit(fn -> Application.delete_env(:at_mcp, :notifications_interval_ms) end)
    Application.put_env(:at_mcp, :notifications_interval_ms, 50)
    pages(%{nil => page([])})

    start_supervised!(
      {AtMcp.Notifications,
       name: nil,
       effects: ctx.effects,
       store: ctx.store,
       enabled: true,
       clock: fn -> Agent.get(Backend, & &1.now) end}
    )

    assert_receive {:page, nil}, 1_000
    assert_receive {:page, nil}, 1_000
  end

  defp pages(pages), do: Agent.update(Backend, &%{&1 | pages: pages})
  defp page(items, cursor \\ nil), do: {:ok, %{items: items, cursor: cursor}}

  defp poller(ctx) do
    start_supervised!(
      {AtMcp.Notifications,
       name: nil,
       effects: ctx.effects,
       store: ctx.store,
       enabled: false,
       clock: fn -> Agent.get(Backend, & &1.now) end}
    )
  end

  defp item(id, seconds) do
    %{
      reason: "reply",
      uri: "at://did:plc:author/app.bsky.feed.post/#{id}",
      indexed_at:
        DateTime.to_iso8601(DateTime.from_unix!(@now + seconds * 1_000_000, :microsecond)),
      is_read: true,
      author: "alice.test",
      author_did: "did:plc:author",
      text: id,
      subject_uri: "at://did:plc:paged/app.bsky.feed.post/parent",
      reply_parent_uri: "at://did:plc:paged/app.bsky.feed.post/parent"
    }
  end
end
