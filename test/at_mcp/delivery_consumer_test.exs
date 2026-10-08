defmodule AtMcp.DeliveryConsumerTest do
  use ExUnit.Case, async: false

  test "delivery configuration attaches when a collector is enabled" do
    on_exit(fn -> AtMcp.Deliver.clear_callback() end)

    AtMcp.Test.Settings.put(
      delivery: [url: "http://127.0.0.1:9/inbound", token: "fixture"],
      notifications_enabled: true
    )

    assert :ok = AtMcp.Deliver.HTTPBridge.maybe_attach_from_env!()
    assert is_function(AtMcp.Deliver.callback(), 1)
  end

  defmodule RedirectReceiver do
    use Plug.Router
    plug(:match)
    plug(:dispatch)

    post "/inbound" do
      conn |> Plug.Conn.put_resp_header("location", "/other") |> Plug.Conn.send_resp(302, "moved")
    end

    match "/other" do
      send(
        conn.private.owner,
        {:redirect_target_called, Plug.Conn.get_req_header(conn, "authorization")}
      )

      Plug.Conn.send_resp(conn, 200, "unrelated page")
    end

    def init(owner), do: owner
    def call(conn, owner), do: super(Plug.Conn.put_private(conn, :owner, owner), [])
  end

  test "a redirected endpoint is not durable acceptance" do
    ref = make_ref()

    start_supervised!(
      {Plug.Cowboy,
       scheme: :http,
       plug: {RedirectReceiver, self()},
       options: [ip: {127, 0, 0, 1}, port: 0, ref: ref]}
    )

    port = :ranch.get_port(ref)

    assert {:error, {:http_status, 302}} =
             AtMcp.Deliver.HTTPBridge.post_inbound(
               "http://127.0.0.1:#{port}/inbound",
               "fixture",
               %{matched_did: "did:plc:me", uri: "at://author/post/1"}
             )

    refute_receive {:redirect_target_called, _}
  end

  # A consumer that either never answers (`:hold`) or accepts (`:accept`). It
  # reports each request it reads, tagged with the mode it was in, so a late
  # report from a held request cannot be mistaken for the accepted one.
  defmodule Receiver do
    @behaviour Plug
    def init(agent), do: agent

    def call(conn, agent) do
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      %{owner: owner, mode: mode} = Agent.get(agent, & &1)

      send(
        owner,
        {:received, mode, Jason.decode!(body), Plug.Conn.get_req_header(conn, "authorization")}
      )

      case mode do
        # Never answers; the handler dies when the client closes the connection
        # or the server stops.
        :hold -> Process.sleep(:infinity)
        :accept -> Plug.Conn.send_resp(conn, 204, "")
      end
    end
  end

  # Nothing here waits on a timer to pass. The consumer never answers the first
  # attempt, so the bridge's 20 ms response limit always ends it, whether or not
  # the request reached the handler before the client gave up; the test waits
  # for the store to record that failure. The first store's backoff is an hour,
  # so it makes no second attempt. The restarted store reads a clock past that
  # backoff, so it delivers at once, and the bridge's own response limit
  # replaces the 20 ms one, so the accepting consumer is not raced.
  @tag :tmp_dir
  test "HTTP timeout retains original event across store restart until consumer accepts", %{
    tmp_dir: dir
  } do
    owner = self()
    agent = start_supervised!({Agent, fn -> %{owner: owner, mode: :hold} end})
    ref = make_ref()

    start_supervised!(
      {Plug.Cowboy,
       scheme: :http, plug: {Receiver, agent}, options: [ip: {127, 0, 0, 1}, port: 0, ref: ref]}
    )

    url = "http://127.0.0.1:#{:ranch.get_port(ref)}/inbound"
    AtMcp.Deliver.clear_callback(:all)

    AtMcp.Deliver.set_callback(fn event ->
      AtMcp.Deliver.HTTPBridge.post_inbound(url, "consumer-secret", event, receive_timeout: 20)
    end)

    on_exit(fn -> AtMcp.Deliver.clear_callback() end)

    event = %{
      source: :notifications,
      matched_did: "did:plc:resident",
      uri: "at://did:plc:author/app.bsky.feed.post/1",
      subject_uri: "at://did:plc:resident/app.bsky.feed.post/parent",
      reason: "reply",
      text: "hello"
    }

    backoff = :timer.hours(1)

    store =
      start_supervised!(
        {AtMcp.Inbound.Store, name: nil, state_dir: dir, retry_ms: backoff, max_retry_ms: backoff}
      )

    assert {:ok, [_]} = AtMcp.Inbound.Store.accept(store, [event])

    assert_eventually(fn ->
      match?(%{attempts: 1}, AtMcp.Inbound.Store.stalls(store)[event.matched_did])
    end)

    assert AtMcp.Inbound.Store.stalls(store)[event.matched_did].reason =~ "timeout"
    assert AtMcp.Inbound.Store.status(store).pending == 1
    assert AtMcp.Inbound.Store.status(store).receipts == 0
    stop_supervised!(AtMcp.Inbound.Store)

    Agent.update(agent, &%{&1 | mode: :accept})

    AtMcp.Deliver.set_callback(fn event ->
      AtMcp.Deliver.HTTPBridge.post_inbound(url, "consumer-secret", event)
    end)

    later = fn -> System.system_time(:millisecond) + backoff end

    store =
      start_supervised!(
        {AtMcp.Inbound.Store, name: nil, state_dir: dir, retry_ms: backoff, clock: later}
      )

    # Bounds how long a broken build waits; a working one answers in milliseconds.
    assert_receive {:received, :accept, payload, ["Bearer consumer-secret"]}, 5_000

    assert payload ==
             event
             |> Map.new(fn {key, value} -> {to_string(key), to_string(value)} end)
             |> Map.put("network", %{"name" => "bluesky", "label" => "Bluesky"})

    assert_eventually(fn -> AtMcp.Inbound.Store.status(store).pending == 0 end)
    assert AtMcp.Inbound.Store.status(store).receipts == 1
    assert {:ok, []} = AtMcp.Inbound.Store.accept(store, [event])
  end

  # Polls a store's state instead of sleeping for a guessed interval. The bound
  # (500 x 10 ms) only limits how long a broken build waits; a working one
  # returns as soon as the state changes.
  defp assert_eventually(fun, remaining \\ 500)

  defp assert_eventually(fun, remaining) when remaining > 0 do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(10)
          assert_eventually(fun, remaining - 1)
        )
  end

  defp assert_eventually(_, 0), do: flunk("delivery did not reach expected state")
end
