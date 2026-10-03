defmodule AtMcp.AccountsTest do
  use ExUnit.Case, async: false
  alias AtMcp.{Accounts, Effects, Identities}
  alias AtMcp.Inbound.Store

  defmodule RejectLogin do
    def login(_), do: {:error, :fixture_rejected}
  end

  # A write that reports its arrival and waits, which is what a write whose
  # service has not answered looks like from AtMcp's side.
  defmodule SlowWrite do
    def prepare_post(session, _text, opts), do: resolve_references(session, opts)

    def resolve_references(_session, opts), do: {:ok, opts}

    def post(session, text, _opts) do
      send(session.test, {:writing, text, self()})

      receive do
        :release -> {:ok, %{uri: "at://#{session.did}/app.bsky.feed.post/1", cid: "bafy"}}
      end
    end
  end

  test "an identity whose Effects child is absent returns a runtime error and is not ready" do
    id = unique()
    did = "did:plc:#{id}"
    start!(id, did)
    supervisor = AtMcp.Identity.whereis(id)

    {child_id, _, _, _} =
      Enum.find(Supervisor.which_children(supervisor), fn {_, _, _, modules} ->
        AtMcp.Effects in modules
      end)

    assert :ok = Supervisor.terminate_child(supervisor, child_id)
    assert {:error, :account_runtime_unavailable} = Identities.start_identity(opts(id, did))
    refute AtMcp.Identity.whereis(id)
    assert {:error, :account_disconnected} = Store.ready(id)
  end

  test "disconnect fences active delivery, keeps accepted events, and covers all DID aliases" do
    id = unique()
    did = "did:plc:#{id}"
    ids = [id, id <> "-alias"]
    Enum.each(ids, &start!(&1, did))
    other = unique()
    start!(other, "did:plc:#{other}")
    parent = self()

    AtMcp.Deliver.set_callback(did, fn _ ->
      send(parent, {:delivering, self()})

      receive do
        :never -> :ok
      end
    end)

    on_exit(fn -> AtMcp.Deliver.clear_callback(did) end)
    event = %{matched_did: did, uri: "at://#{did}/post/1"}
    assert {:ok, [_]} = Store.accept([event])
    assert_receive {:delivering, worker}, 2_000
    assert :ok = Accounts.disconnect(id)
    refute Process.alive?(worker)

    Enum.each(ids, fn alias_id ->
      refute AtMcp.Identity.whereis(alias_id)
      assert {:error, :account_disconnected} = Store.ready(alias_id)
    end)

    assert AtMcp.Identity.whereis(other)
    assert {:ok, _} = Effects.get_profile(AtMcp.Identity.effects_name(other), "did:plc:#{other}")

    AtMcp.Deliver.set_callback(did, fn _ ->
      send(parent, :retained_delivered)
      :ok
    end)

    refute_receive :retained_delivered, 100
    assert {:ok, _} = Accounts.reconnect(id)
    assert_receive :retained_delivered, 2_000
    refute_receive :retained_delivered, 100
    Enum.each(ids, fn alias_id -> assert AtMcp.Identity.whereis(alias_id) end)
  end

  test "durable disable survives store and lifecycle owner restart; dynamic accounts must be configured again" do
    id = unique()
    start!(id, "did:plc:#{id}")
    assert :ok = Accounts.disconnect(id)
    assert :ok = Supervisor.terminate_child(AtMcp.Supervisor, Store)
    assert {:ok, _} = Supervisor.restart_child(AtMcp.Supervisor, Store)
    assert {:error, :account_disconnected} = Store.ready(id)
    assert :ok = Supervisor.terminate_child(AtMcp.Supervisor, Accounts)
    assert {:ok, _} = Supervisor.restart_child(AtMcp.Supervisor, Accounts)
    assert {:error, :configuration_required} = Accounts.reconnect(id)
    refute AtMcp.Identity.whereis(id)
    assert {:error, :account_disconnected} = Identities.start_identity(opts(id, "did:plc:#{id}"))
    assert {:ok, _} = Accounts.reconnect(id)
  end

  test "failed authentication keeps account disconnected, and disabled IDs work before login" do
    id = unique()
    start!(id, "did:plc:#{id}")
    assert :ok = Accounts.disconnect(id)

    bad =
      opts(id, "did:plc:#{id}")
      |> Keyword.delete(:backend_state)
      |> Keyword.put(:backend, RejectLogin)

    assert {:error, :account_disconnected} = Identities.start_identity(bad)
    assert {:error, {:authentication_failed, :fixture_rejected}} = Accounts.reconnect(id)
    assert {:error, :account_disconnected} = Store.ready(id)
    refute AtMcp.Identity.whereis(id)
    blank = unique()

    assert {:ok, _} =
             Identities.start_identity(id: blank, listen_enabled: false)

    on_exit(fn -> Identities.stop_identity(blank) end)
    assert :ok = Accounts.disconnect(blank)
    assert Store.accounts()[blank] == %{did: nil, disabled: true}
    assert {:error, {:authentication_failed, :not_connected}} = Accounts.reconnect(blank)
  end

  test "a write waiting behind another cannot pass an acknowledged disconnect" do
    id = unique()
    did = "did:plc:#{id}"

    assert {:ok, _} =
             Identities.start_identity(
               id: id,
               listen_enabled: false,
               backend: SlowWrite,
               backend_state: %{did: did, test: self()}
             )

    on_exit(fn -> Identities.stop_identity(id) end)
    effects = AtMcp.Identity.effects_name(id)

    first = Task.async(fn -> Effects.post(effects, "first") end)
    assert_receive {:writing, "first", _held}, 2_000
    waiting = Task.async(fn -> Effects.post(effects, "waiting") end)
    Process.sleep(50)

    assert :ok = Accounts.disconnect(id)
    assert {:error, :account_disconnected} = Store.ready(id)

    assert {:error, {:write_outcome_unknown, _}} = Task.await(first)
    assert {:error, :account_runtime_unavailable} = Task.await(waiting)
    refute_received {:writing, "waiting", _}
  end

  test "status shows an account whose delivery is stalled, why, and since when" do
    id = unique()
    did = "did:plc:#{id}"
    start!(id, did)
    parent = self()
    before = System.system_time(:second)

    AtMcp.Deliver.set_callback(did, fn _ ->
      send(parent, :refused)
      {:error, {:http_status, 503}}
    end)

    assert {:ok, [_]} = Store.accept([%{matched_did: did, uri: "at://#{did}/post/stalled"}])
    assert_receive :refused, 2_000

    assert eventually(fn -> row(id).delivery != nil end)
    %{delivery: delivery} = row(id)
    assert delivery.state == "stalled"
    assert delivery.reason =~ "503"
    assert delivery.pending == 1
    assert {:ok, since, 0} = DateTime.from_iso8601(delivery.since)
    assert DateTime.to_unix(since) >= before

    # The operator's command prints it as JSON.
    assert {:ok, rows} = Accounts.status()
    assert Jason.encode!(rows) =~ ~s("state":"stalled")

    AtMcp.Deliver.set_callback(did, fn _ -> :ok end)
    assert eventually(fn -> row(id).delivery == nil end, 400)
  end

  test "owner restart finishes a committed disconnect before its identity was stopped" do
    id = unique()
    did = "did:plc:#{id}"

    assert {:ok, _} =
             Identities.start_identity(
               opts(id, did)
               |> Keyword.put(:listen_enabled, true)
               |> Keyword.put(:did_poll_ms, 10)
             )

    on_exit(fn -> Identities.stop_identity(id) end)
    assert eventually(fn -> did in AtMcp.Inbound.tracked_dids() end)
    # The durable half of Disconnect has happened, but Accounts crashed before shutdown.
    assert {:ok, [^id]} = Store.account({:disconnect, id})
    assert AtMcp.Identity.whereis(id)
    assert :ok = Supervisor.terminate_child(AtMcp.Supervisor, Accounts)
    assert {:ok, _} = Supervisor.restart_child(AtMcp.Supervisor, Accounts)
    assert {:ok, _} = Accounts.status()
    assert eventually(fn -> is_nil(AtMcp.Identity.whereis(id)) end)
    assert eventually(fn -> did not in AtMcp.Inbound.tracked_dids() end)
    assert {:error, :configuration_required} = Accounts.reconnect(id)
  end

  test "missing lifecycle owner fails closed for tools and delivery without losing other runtime" do
    id = unique()
    did = "did:plc:#{id}"
    start!(id, did)
    effects = AtMcp.Identity.effects_name(id)
    parent = self()

    AtMcp.Deliver.set_callback(did, fn _ ->
      send(parent, :owner_recovered_delivery)
      :ok
    end)

    assert :ok = Supervisor.terminate_child(AtMcp.Supervisor, Accounts)

    try do
      assert {:error, :account_control_unavailable} = Effects.get_profile(effects, did)
      assert {:error, :account_control_unavailable} = Accounts.reconnect(id)
      assert {:ok, [_]} = Store.accept([%{matched_did: did, uri: "at://#{did}/post/owner"}])
      refute_receive :owner_recovered_delivery, 100
    after
      assert {:ok, _} = Supervisor.restart_child(AtMcp.Supervisor, Accounts)
    end

    assert_receive :owner_recovered_delivery, 2_000
    assert {:ok, _} = Effects.get_profile(effects, did)
  end

  @tag :tmp_dir
  test "fresh VM keeps the outbox and a disconnected account disconnected", %{tmp_dir: dir} do
    common = """
    Application.load(:at_mcp)
    Application.put_env(:at_mcp, :inbound_state_dir, #{inspect(dir)})
    {:ok, _} = Application.ensure_all_started(:at_mcp)
    """

    first =
      common <>
        """
        {:ok, _} = AtMcp.Identities.start_identity(id: "cold-account", listen_enabled: false,
          backend: AtMcp.Test.MockBackend, handle: "fixture", password: "fixture-password-not-store", backend_state: %{did: "did:plc:cold-account", mock: true})
        :ok = AtMcp.Accounts.disconnect("cold-account")
        {:ok, [_]} = AtMcp.Inbound.Store.accept([%{matched_did: "did:plc:cold-account", uri: "at://cold/account/1"}])
        System.halt(0)
        """

    second =
      common <>
        """
        nil = AtMcp.Identity.whereis("cold-account")
        {:error, :configuration_required} = AtMcp.Accounts.reconnect("cold-account")
        %{pending: 1} = AtMcp.Inbound.Store.status()
        %{disabled: true} = AtMcp.Inbound.Store.accounts()["cold-account"]
        IO.puts("cold-disconnect-retained")
        """

    env =
      for key <- [
            "BLUESKY_HANDLE",
            "BLUESKY_APP_PASSWORD",
            "BLUESKY_HANDLE_2",
            "BLUESKY_APP_PASSWORD_2",
            "AT_MCP_HOST_TOKEN",
            "AT_MCP_HOST_TOKEN_FILE",
            "AT_MCP_DELIVERY_URL"
          ],
          do: {key, nil}

    {output, code} =
      System.cmd("mix", ["run", "--no-start", "-e", first],
        env: [{"MIX_ENV", "test"} | env],
        stderr_to_stdout: true
      )

    assert code == 0, output

    {output, code} =
      System.cmd("mix", ["run", "--no-start", "-e", second],
        env: [{"MIX_ENV", "test"} | env],
        stderr_to_stdout: true
      )

    assert code == 0, output
    assert output =~ "cold-disconnect-retained"

    assert :nomatch =
             :binary.match(
               File.read!(Path.join(dir, "inbound.term")),
               "fixture-password-not-store"
             )
  end

  @tag :tmp_dir
  test "cold boot with configured bridge preserves an intentional disconnect of every account", %{
    tmp_dir: dir
  } do
    common = """
    Application.load(:at_mcp)
    Application.put_env(:at_mcp, :inbound_state_dir, #{inspect(dir)})
    """

    first =
      common <>
        """
        {:ok, _} = Application.ensure_all_started(:at_mcp)
        {:ok, _} = AtMcp.Identities.start_identity(id: "default", listen_enabled: false,
          backend: AtMcp.Test.MockBackend, backend_state: %{did: "did:plc:bridge-disconnected", mock: true})
        :ok = AtMcp.Accounts.disconnect("default")
        System.halt(0)
        """

    second =
      common <>
        """
        Application.put_env(:at_mcp, :jetstream_enabled, true)
        {:ok, _} = Application.ensure_all_started(:at_mcp)
        nil = AtMcp.Identity.whereis("default")
        [] = AtMcp.Inbound.tracked_dids()
        true = is_function(AtMcp.Deliver.callback(), 1)
        # An account the runtime knows and has not started does not block the
        # bridge either: whether it runs is the account owner's business.
        :ok = AtMcp.Inbound.Store.account({:register, "unready-enabled"})
        :ok = AtMcp.Deliver.HTTPBridge.maybe_attach_from_env!()
        {:ok, _} = AtMcp.Inbound.Store.account({:disconnect, "unready-enabled"})
        Application.put_env(:at_mcp, :jetstream_enabled, false)
        {:error, {:delivery_bridge_unready, [:no_inbound_collector]}} = AtMcp.Deliver.HTTPBridge.maybe_attach_from_env!()
        Application.put_env(:at_mcp, :jetstream_enabled, true)
        callback = AtMcp.Deliver.callback()
        {:error, :account_disconnected} = AtMcp.Identities.start_identity(id: "default",
        listen_enabled: false, backend: AtMcp.Test.MockBackend, backend_state: %{did: "did:plc:bridge-disconnected", mock: true})
        {:ok, _} = AtMcp.Accounts.reconnect("default")
        true = callback == AtMcp.Deliver.callback()
        {:ok, _} = AtMcp.Effects.get_profile(AtMcp.Identity.effects_name("default"), "did:plc:bridge-disconnected")
        IO.puts("disconnected-bridge-booted")
        """

    env =
      for key <- [
            "BLUESKY_HANDLE",
            "BLUESKY_APP_PASSWORD",
            "BLUESKY_HANDLE_2",
            "BLUESKY_APP_PASSWORD_2",
            "AT_MCP_HOST_TOKEN",
            "AT_MCP_HOST_TOKEN_FILE",
            "AT_MCP_DELIVERY_URL",
            "AT_MCP_DELIVERY_TOKEN_FILE",
            "AT_MCP_JETSTREAM"
          ],
          do: {key, nil}

    {output, code} =
      System.cmd("mix", ["run", "--no-start", "-e", first],
        env: [{"MIX_ENV", "test"} | env],
        stderr_to_stdout: true
      )

    assert code == 0, output

    bridge_env = [
      {"AT_MCP_DELIVERY_URL", "http://127.0.0.1:9/inbound"},
      {"AT_MCP_DELIVERY_TOKEN", "fixture"}
      | Enum.reject(env, fn {key, _} -> key == "AT_MCP_DELIVERY_URL" end)
    ]

    {output, code} =
      System.cmd("mix", ["run", "--no-start", "-e", second],
        env: [{"MIX_ENV", "test"} | bridge_env],
        stderr_to_stdout: true
      )

    assert code == 0, output
    assert output =~ "disconnected-bridge-booted"
  end

  defp start!(id, did) do
    assert {:ok, _} = Identities.start_identity(opts(id, did))

    on_exit(fn ->
      Identities.stop_identity(id)
      AtMcp.Deliver.clear_callback(did)
    end)
  end

  defp opts(id, did),
    do: [
      id: id,
      listen_enabled: false,
      backend: AtMcp.Test.MockBackend,
      backend_state: %{did: did, mock: true}
    ]

  defp unique, do: "lifecycle-#{System.unique_integer([:positive])}"

  defp row(id) do
    {:ok, rows} = Accounts.status()
    Enum.find(rows, &(&1.id == id))
  end

  defp eventually(fun, n \\ 100)
  defp eventually(_, 0), do: false

  defp eventually(fun, n) do
    if fun.(),
      do: true,
      else:
        (
          Process.sleep(10)
          eventually(fun, n - 1)
        )
  end
end
