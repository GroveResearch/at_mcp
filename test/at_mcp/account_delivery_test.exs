defmodule AtMcp.AccountDeliveryTest do
  @moduledoc """
  Per-account delivery destinations over real HTTP, against local receivers.

  Two accounts share one service. Each test names what the operator does
  (`at_mcp-accounts delivery`, `reload`, a restart) and checks what each
  receiver was actually sent.
  """
  use ExUnit.Case, async: false
  alias AtMcp.{Accounts, AccountConfig, AccountSetup, Identity, Identities}
  alias AtMcp.Inbound.Store

  # Receivers and the accounts' PDS. `/r/ok-*` accepts, `/r/err-*` answers 500,
  # `/r/hang-*` answers after the bridge's response timeout. Every request is
  # reported to the process registered as `:account_delivery_test`, which is the
  # test process here and the test's VM when a child VM is delivering.
  defmodule Stub do
    use Plug.Router
    plug(Plug.Parsers, parsers: [:json], json_decoder: Jason)
    plug(:match)
    plug(:dispatch)

    post "/r/:receiver" do
      auth = conn |> Plug.Conn.get_req_header("authorization") |> List.first()

      send(
        :account_delivery_test,
        {:received, receiver, auth, conn.body_params["matched_did"], conn.body_params["uri"],
         System.monotonic_time(:millisecond)}
      )

      cond do
        String.starts_with?(receiver, "hang") -> Process.sleep(8_000)
        true -> :ok
      end

      send_resp(conn, if(String.starts_with?(receiver, "err"), do: 500, else: 204), "")
    end

    post "/xrpc/com.atproto.server.createSession" do
      handle = conn.body_params["identifier"]

      body = %{
        did: "did:plc:" <> handle,
        handle: handle,
        accessJwt: "fixture",
        refreshJwt: "fixture"
      }

      conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(body))
    end
  end

  setup do
    Process.register(self(), :account_delivery_test)
    unique = Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)
    root = Path.join(System.tmp_dir!(), "at_mcp-delivery-" <> unique)
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    File.chmod!(root, 0o700)
    ref = :"#{__MODULE__}.HTTP"
    start_supervised!({Plug.Cowboy, scheme: :http, plug: Stub, options: [port: 0, ref: ref]})
    base = "http://127.0.0.1:#{:ranch.get_port(ref)}"
    prefix = "dlv" <> String.replace(unique, ~r/[^a-zA-Z0-9]/, "x")
    [alice, bob] = for name <- ~w(alice bob), do: row(prefix <> name, base)
    file = Path.join(root, "accounts.json")
    Enum.each([alice, bob], &({:ok, _} = AccountConfig.add(file, &1)))

    tokens =
      Map.new(~w(alice bob), fn name ->
        path = Path.join(root, "#{name}-token")
        File.write!(path, "#{name}-receiver-token")
        File.chmod!(path, 0o600)
        {name, path}
      end)

    %{root: root, accounts_file: file, base: base, alice: alice, bob: bob, tokens: tokens}
  end

  describe "in one running service" do
    setup %{accounts_file: file, alice: alice, bob: bob} = ctx do
      on_exit(fn ->
        for row <- [alice, bob], do: Identities.stop_identity(row["id"])
        restart_accounts!()
      end)

      AtMcp.Test.Settings.put(accounts_file: file, notifications_enabled: true)
      restart_accounts!()
      assert eventually(fn -> Enum.all?([alice, bob], &(Store.ready(&1["id"]) == :ok)) end)

      # A host callback left over from the single-consumer mode must never be
      # used once accounts have destinations.
      AtMcp.Deliver.set_callback(fn event -> send(:account_delivery_test, {:fallback, event}) end)
      on_exit(fn -> AtMcp.Deliver.clear_callback() end)
      ctx
    end

    test "each account's receiver gets only that account's events, in order", ctx do
      route!(ctx, ctx.alice, "ok-alice", "alice")
      route!(ctx, ctx.bob, "ok-bob", "bob")
      assert {:ok, _} = Accounts.reload()

      events =
        for i <- 1..4, row <- [ctx.alice, ctx.bob], do: notification(row, "a#{i}")

      assert {:ok, accepted} = Store.accept(events)
      assert length(accepted) == 8

      received = collect(8, 5_000)
      refute_receive {:received, _, _, _, _, _}, 300
      refute_received {:fallback, _}

      for {row, receiver, token} <- [
            {ctx.alice, "ok-alice", "Bearer alice-receiver-token"},
            {ctx.bob, "ok-bob", "Bearer bob-receiver-token"}
          ] do
        mine = Enum.filter(received, &(&1.receiver == receiver))
        assert Enum.all?(mine, &(&1.did == row["did"] and &1.auth == token))
        assert Enum.map(mine, & &1.uri) == for(i <- 1..4, do: uri(row, "a#{i}"))
      end

      assert eventually(fn -> pending_for(ctx) == [] end)
    end

    for {mode, alice_url} <- [refused: nil, server_error: "err-alice", timeout: "hang-alice"] do
      test "Alice's receiver #{mode} does not hold up Bob's deliveries", ctx do
        alice_url = target(ctx, unquote(alice_url))

        route_url!(ctx, ctx.alice, alice_url, "alice")
        route!(ctx, ctx.bob, "ok-bob", "bob")
        assert {:ok, _} = Accounts.reload()

        # Alice's first event goes in first, so her lane is failing (or her
        # request is hanging) while every one of Bob's is delivered.
        assert {:ok, [_]} = Store.accept([notification(ctx.alice, "stuck")])
        if unquote(mode) != :refused, do: assert_receive({:received, _, _, _, _, _}, 2_000)
        started = System.monotonic_time(:millisecond)
        bob_events = for i <- 1..3, do: notification(ctx.bob, "b#{i}")
        assert {:ok, _} = Store.accept(bob_events ++ [notification(ctx.alice, "behind")])

        bob = for _ <- 1..3, do: next_from("ok-bob", 2_000)
        assert Enum.map(bob, & &1.uri) == Enum.map(bob_events, & &1.uri)
        # Normal delivery to a local receiver is milliseconds; Alice's failure
        # mode (a 1 s retry backoff, a 5 s response timeout) must not show up.
        assert List.last(bob).at - started < 900

        # Bob's lane empties; both of Alice's events are still held.
        assert eventually(fn ->
                 not Enum.any?(pending_uris(), &(&1 in Enum.map(bob_events, fn e -> e.uri end)))
               end)

        pending = pending_uris()
        assert uri(ctx.alice, "stuck") in pending and uri(ctx.alice, "behind") in pending
        refute_received {:fallback, _}
      end
    end

    test "a destination saved with the setup command applies on reload, without a restart",
         ctx do
      route_url!(ctx, ctx.alice, closed_port_url(), "alice")
      route!(ctx, ctx.bob, "ok-bob", "bob")
      assert {:ok, _} = Accounts.reload()
      bob_pid = Identity.whereis(ctx.bob["id"])
      queued = for i <- 1..3, do: notification(ctx.alice, "q#{i}")
      assert {:ok, _} = Store.accept(queued)
      assert eventually(fn -> Store.stalls()[ctx.alice["did"]] != nil end)

      route!(ctx, ctx.alice, "ok-alice-new", "alice")
      assert {:ok, _} = Accounts.reload()

      moved = collect(3, 5_000)
      assert Enum.map(moved, & &1.receiver) == List.duplicate("ok-alice-new", 3)
      assert Enum.map(moved, & &1.uri) == Enum.map(queued, & &1.uri)
      assert Enum.all?(moved, &(&1.auth == "Bearer alice-receiver-token"))
      assert eventually(fn -> pending_for(ctx) == [] end)

      # Bob's account was not reconnected by Alice's change and still delivers.
      assert Identity.whereis(ctx.bob["id"]) == bob_pid
      assert {:ok, _} = Store.accept([notification(ctx.bob, "after")])
      assert [%{receiver: "ok-bob"}] = collect(1, 2_000)
      refute_receive {:received, _, _, _, _, _}, 300
    end

    test "a token file that is empty, missing or not one header value is refused, never sent or logged",
         ctx do
      route!(ctx, ctx.alice, "ok-alice", "alice")
      route!(ctx, ctx.bob, "ok-bob", "bob")
      assert {:ok, _} = Accounts.reload()
      path = ctx.tokens["alice"]

      for {contents, reason} <- [
            {"", :delivery_token_empty},
            {"secret-sentinel\nsecond-line", :delivery_token_invalid},
            {nil, {:delivery_token_unreadable, :enoent}}
          ] do
        if contents, do: File.write!(path, contents), else: File.rm!(path)

        log =
          ExUnit.CaptureLog.capture_log(fn ->
            assert {:error, ^reason} = AtMcp.Deliver.deliver(notification(ctx.alice, "t"))
          end)

        refute log =~ "secret-sentinel"
        refute_receive {:received, _, _, _, _, _}, 100
      end
    end
  end

  # A restart is a new VM reading the same accounts file and state directory,
  # as the service manager restarts the release.
  test "a destination changed while the service is down gets the queued work after restart, once",
       ctx do
    dir = Path.join(ctx.root, "state")
    route!(ctx, ctx.alice, "err-alice-old", "alice")
    route!(ctx, ctx.bob, "ok-bob", "bob")
    alice_events = for i <- 1..3, do: notification(ctx.alice, "r#{i}")
    bob_event = notification(ctx.bob, "r1")

    run!(ctx.accounts_file, dir, """
    {:ok, [_, _, _, _]} = AtMcp.Inbound.Store.accept(#{inspect(alice_events ++ [bob_event])})
    wait.(fn ->
      AtMcp.Inbound.Store.status().pending == 3 and
        AtMcp.Inbound.Store.stalls()[#{inspect(ctx.alice["did"])}] != nil
    end)
    """)

    first = drain_mailbox()
    assert [%{uri: uri}] = Enum.filter(first, &(&1.receiver == "ok-bob"))
    assert uri == bob_event.uri
    old = Enum.filter(first, &(&1.receiver == "err-alice-old"))
    assert old != [] and Enum.all?(old, &(&1.uri == hd(alice_events).uri))

    # The operator moves Alice's receiver while the service is stopped.
    route!(ctx, ctx.alice, "ok-alice-new", "alice")

    run!(ctx.accounts_file, dir, """
    wait.(fn -> AtMcp.Inbound.Store.status().pending == 0 end)
    """)

    second = drain_mailbox()

    assert Enum.map(second, &{&1.receiver, &1.uri}) ==
             Enum.map(alice_events, &{"ok-alice-new", &1.uri})

    assert Enum.all?(second, &(&1.auth == "Bearer alice-receiver-token"))
  end

  defp run!(file, dir, body) do
    script = """
    Application.load(:at_mcp)
    Application.put_env(:at_mcp, :accounts_file, #{inspect(file)}, persistent: true)
    Application.put_env(:at_mcp, :inbound_state_dir, #{inspect(dir)}, persistent: true)
    Application.put_env(:at_mcp, :notifications_enabled, true, persistent: true)
    Application.put_env(:at_mcp, :start_mcp, false, persistent: true)
    Application.put_env(:at_mcp, :control_port, nil, persistent: true)
    {:ok, _} = Application.ensure_all_started(:at_mcp)
    wait = fn check ->
      Enum.reduce_while(1..1000, nil, fn _, _ ->
        if check.(), do: {:halt, :ok}, else: (Process.sleep(10); {:cont, nil})
      end) || raise "condition not reached"
    end
    #{body}
    :ok = Application.stop(:at_mcp)
    IO.puts("phase-done")
    """

    env =
      for key <- ~w(AT_MCP_ACCOUNTS_FILE AT_MCP_DELIVERY_URL AT_MCP_DELIVERY_TOKEN
                    AT_MCP_DELIVERY_TOKEN_FILE AT_MCP_JETSTREAM),
          do: {key, nil}

    # The child's receivers and PDS are this VM's stub, reached over HTTP.
    {output, status} =
      System.cmd("mix", ["run", "--no-start", "-e", script],
        env: [{"MIX_ENV", "test"} | env],
        stderr_to_stdout: true
      )

    assert status == 0 and output =~ "phase-done", output
  end

  defp route!(ctx, row, receiver, token),
    do: route_url!(ctx, row, ctx.base <> "/r/" <> receiver, token)

  # Through the operator's command, as docs/operations.md says to.
  defp route_url!(ctx, row, url, token) do
    assert {:ok, %{account: account}} =
             AccountSetup.execute([
               "--file",
               ctx.accounts_file,
               "delivery",
               row["id"],
               "--url",
               url,
               "--token-file",
               ctx.tokens[token]
             ])

    refute inspect(account) =~ "receiver-token"
  end

  defp target(_ctx, nil), do: closed_port_url()
  defp target(ctx, receiver), do: ctx.base <> "/r/" <> receiver

  defp closed_port_url do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    "http://127.0.0.1:#{port}/r/refused"
  end

  defp collect(0, _timeout), do: []

  defp collect(n, timeout) do
    receive do
      {:received, receiver, auth, did, uri, at} ->
        [%{receiver: receiver, auth: auth, did: did, uri: uri, at: at} | collect(n - 1, timeout)]
    after
      timeout -> flunk("expected #{n} more deliveries")
    end
  end

  defp next_from(receiver, timeout) do
    receive do
      {:received, ^receiver, auth, did, uri, at} ->
        %{receiver: receiver, auth: auth, did: did, uri: uri, at: at}
    after
      timeout -> flunk("expected a delivery to #{receiver}")
    end
  end

  defp drain_mailbox do
    receive do
      {:received, receiver, auth, did, uri, at} ->
        [%{receiver: receiver, auth: auth, did: did, uri: uri, at: at} | drain_mailbox()]
    after
      0 -> []
    end
  end

  # This test's events still held. The store is the test VM's, shared with
  # other tests' accounts.
  defp pending_for(ctx),
    do: Enum.filter(pending_uris(), &String.contains?(&1, [ctx.alice["id"], ctx.bob["id"]]))

  defp pending_uris,
    do: for({_, entry} <- :sys.get_state(Store).data.pending, do: entry.event.uri)

  defp notification(row, suffix),
    do: %{
      source: :notifications,
      matched_did: row["did"],
      uri: uri(row, suffix),
      kind: :inbound_notification
    }

  defp uri(row, suffix), do: "at://did:plc:author/app.bsky.feed.post/#{row["id"]}-#{suffix}"

  defp row(id, service),
    do: %{
      "id" => id,
      "handle" => id,
      "did" => "did:plc:" <> id,
      "password" => "fixture",
      "service" => service
    }

  defp restart_accounts! do
    :ok = Supervisor.terminate_child(AtMcp.Supervisor, Accounts)
    {:ok, _} = Supervisor.restart_child(AtMcp.Supervisor, Accounts)
  end

  defp eventually(fun, attempts \\ 300)
  defp eventually(_, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end
end
