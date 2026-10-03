defmodule AtMcp.AccountsConcurrencyTest do
  use ExUnit.Case, async: false
  alias AtMcp.{Accounts, Effects, Identities, Identity}
  alias AtMcp.Inbound.Store

  defmodule SlowLogin do
    def login(opts) do
      send(Process.whereis(AtMcp.AccountsConcurrencyTest), {:auth_entered, self(), opts[:handle]})

      receive do
        {:release_auth, did} -> {:ok, %{did: did, mock: true}}
      after
        5_000 -> {:error, :proof_timeout}
      end
    end
  end

  setup do
    await_name_released()
    Process.register(self(), __MODULE__)
    prefix = "auth-proof-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      # Stopping the identity is not enough. A login that failed leaves the
      # config pending in AtMcp.Accounts, which retries it with backoff; a retry
      # that fires after this test has finished starts another SlowLogin worker
      # that sends {:auth_entered, ...} to whichever test now holds this
      # module's name, or crashes on `send(nil, ...)` when no test does. The
      # durable disconnect is what tells the lifecycle owner to stop retrying.
      for suffix <- ~w(a b alias) do
        id = prefix <> suffix
        Accounts.disconnect(id)
        Identities.stop_identity(id)
      end
    end)

    %{a: prefix <> "a", b: prefix <> "b", alias_id: prefix <> "alias"}
  end

  # ExUnit starts the next test as soon as the previous test process reports its
  # result: `ExUnit.Runner.receive_test_reply/4` demonitors and returns on
  # `{pid, :test_finished, test}`, and nothing afterwards waits for that process
  # to exit (`ExUnit.OnExitHandler.run/2` only waits on the on_exit runner). The
  # previous test's registration can therefore still be in place here, which on
  # a loaded machine makes `Process.register/2` raise. Wait for the holder to go
  # down instead of racing it.
  defp await_name_released do
    case Process.whereis(__MODULE__) do
      nil ->
        :ok

      pid ->
        ref = Process.monitor(pid)

        receive do
          {:DOWN, ^ref, :process, ^pid, _} -> await_name_released()
        after
          5_000 ->
            Process.demonitor(ref, [:flush])
            flunk("#{inspect(pid)} still holds the name #{inspect(__MODULE__)}")
        end
    end
  end

  test "blocked authentication leaves status and an unrelated account disconnect responsive", %{
    a: a,
    b: b
  } do
    start_ready(b)
    authentication = start_slow(a)
    assert_receive {:auth_entered, worker, ^a}, 2_000
    refute worker == Process.whereis(Accounts)

    status = Task.async(&Accounts.status/0)
    assert {:ok, rows} = Task.await(status, 500)
    assert Enum.find(rows, &(&1.id == b)).ready
    assert {:ok, _} = Effects.get_profile(Identity.effects_name(b), "did:plc:#{b}")
    disconnect = Task.async(fn -> Accounts.disconnect(b) end)
    assert :ok == Task.await(disconnect, 500)
    assert {:error, :account_disconnected} == Store.ready(b)
    assert Task.yield(authentication, 0) == nil

    send(worker, {:release_auth, "did:plc:#{a}"})
    assert {:ok, _} = Task.await(authentication)
    assert :ok == Store.ready(a)
  end

  test "disconnect cancels pending authentication and a late result cannot reopen it", %{a: a} do
    authentication = start_slow(a)
    assert_receive {:auth_entered, worker, ^a}, 2_000
    monitor = Process.monitor(worker)
    assert :ok == Accounts.disconnect(a)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}
    send(worker, {:release_auth, "did:plc:#{a}"})
    assert {:error, :account_runtime_unavailable} = Task.await(authentication)
    assert Store.accounts()[a].disabled
    assert {:error, :account_disconnected} == Store.ready(a)
    refute Identity.whereis(a)
  end

  test "an alias discovered after another alias disconnects cannot reconnect it", %{a: a, b: b} do
    did = "did:plc:#{b}"
    start_ready(b)
    authentication = start_slow(a)
    assert_receive {:auth_entered, worker, ^a}, 2_000
    assert :ok == Accounts.disconnect(b)
    send(worker, {:release_auth, did})
    assert {:error, :account_runtime_unavailable} = Task.await(authentication)
    assert Store.accounts()[b].disabled
    assert {:error, :account_disconnected} == Store.ready(a)
    refute Identity.whereis(a)
    refute Identity.whereis(b)
  end

  test "known alias disconnect cancels a pending reconnect for the entire DID", %{a: a, b: b} do
    did = "did:plc:#{a}"
    start_ready(a, did)
    start_ready(b, did)
    assert :ok == Accounts.disconnect(a)
    assert {:error, :account_disconnected} = Identities.start_identity(slow_opts(a))
    reconnect = Task.async(fn -> Accounts.reconnect(a) end)
    assert_receive {:auth_entered, worker, ^a}, 2_000
    monitor = Process.monitor(worker)
    assert :ok == Accounts.disconnect(b)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}
    send(worker, {:release_auth, did})
    assert {:error, :account_runtime_unavailable} = Task.await(reconnect)

    for id <- [a, b] do
      assert Store.accounts()[id].disabled
      refute Identity.whereis(id)
    end
  end

  # The login belongs to the account's owner, not to the lifecycle owner that
  # asked for it, so it outlives a lifecycle-owner failure. What must not
  # survive is its effect: the result lands in an account that was disconnected
  # before the failure, and the restarted lifecycle owner stops it.
  test "a restarted lifecycle owner cannot accept an authentication started before it stopped",
       %{a: a} do
    authentication = start_slow(a)
    assert_receive {:auth_entered, worker, ^a}, 2_000
    # Simulate a committed disconnect immediately before lifecycle-owner failure.
    assert {:ok, [^a]} = Store.account({:disconnect, a})
    assert :ok = Supervisor.terminate_child(AtMcp.Supervisor, Accounts)
    assert {:error, _} = Task.await(authentication)
    assert {:ok, _} = Supervisor.restart_child(AtMcp.Supervisor, Accounts)
    send(worker, {:release_auth, "did:plc:#{a}"})
    assert {:error, :account_disconnected} == Store.ready(a)
    assert eventually(fn -> is_nil(Identity.whereis(a)) end)
    assert {:error, :configuration_required} = Accounts.reconnect(a)
  end

  test "replacement config cannot receive a cancelled login result", %{a: a} do
    authentication = start_slow(a)
    assert_receive {:auth_entered, worker, ^a}, 2_000
    monitor = Process.monitor(worker)

    assert {:ok, _} =
             Identities.start_identity(
               id: a,
               listen_enabled: false,
               backend: AtMcp.Test.MockBackend,
               backend_state: %{did: "did:plc:replacement", mock: true}
             )

    assert_receive {:DOWN, ^monitor, :process, ^worker, _}
    send(worker, {:release_auth, "did:plc:obsolete"})
    assert {:error, :account_runtime_unavailable} = Task.await(authentication)
    assert Effects.session_did(Identity.effects_name(a)) == "did:plc:replacement"
    assert Store.accounts()[a].did == "did:plc:replacement"
  end

  test "worker rollback preserves its launch fence for an unrelated newly discovered alias", %{
    a: a,
    b: b
  } do
    start_ready(b)
    authentication = start_slow(a)
    assert_receive {:auth_entered, _, ^a}, 2_000

    {token, _} =
      Enum.find(:sys.get_state(Accounts).operations, fn {_, op} -> MapSet.member?(op.ids, a) end)

    assert :ok = Accounts.disconnect(b)
    # Exercise the coordinator's commit boundary directly: a worker may roll
    # back one group without receiving authority over newer unrelated disconnects.
    assert {:ok, [^a]} =
             GenServer.call(Accounts, {:operation, token, {:account, {:disconnect, a}}})

    assert :superseded =
             GenServer.call(Accounts, {:operation, token, {:account, {:bind, a, "did:plc:#{b}"}}})

    assert Store.accounts()[a].did == nil
    assert :ok = Accounts.disconnect(a)
    assert {:error, _} = Task.await(authentication)
  end

  test "invalid reconnect configuration never leaves a disconnected identity startable", %{a: a} do
    start_ready(a)
    assert :ok = Accounts.disconnect(a)

    assert {:error, :account_disconnected} =
             Identities.start_identity(
               id: a,
               listen_enabled: false,
               host_token: "too-short"
             )

    assert {:error, :invalid_configuration} = Accounts.reconnect(a)
    refute Store.account({:can_start, a})
    assert Store.accounts()[a].disabled
    refute Identity.whereis(a)
  end

  test "replacing a disconnected account's configuration cancels old authentication without reconnecting it",
       %{a: a} do
    start_ready(a)
    assert :ok = Accounts.disconnect(a)
    assert {:error, :account_disconnected} = Identities.start_identity(slow_opts(a))
    reconnect = Task.async(fn -> Accounts.reconnect(a) end)
    assert_receive {:auth_entered, worker, ^a}, 2_000
    monitor = Process.monitor(worker)

    assert {:error, :account_disconnected} =
             Identities.start_identity(
               id: a,
               listen_enabled: false,
               backend: AtMcp.Test.MockBackend,
               backend_state: %{did: "did:plc:#{a}", mock: true}
             )

    assert_receive {:DOWN, ^monitor, :process, ^worker, _}
    send(worker, {:release_auth, "did:plc:#{a}"})
    assert {:error, :account_runtime_unavailable} = Task.await(reconnect)
    assert Store.accounts()[a].disabled
    assert eventually(fn -> is_nil(Identity.whereis(a)) end)
    assert {:ok, _} = Accounts.reconnect(a)
    assert :ok = Store.ready(a)
  end

  test "a policy-store outage aborts old work without discarding account configs", %{a: a, b: b} do
    start_ready(b)
    authentication = start_slow(a)
    assert_receive {:auth_entered, worker, ^a}, 2_000
    owner = Process.whereis(Accounts)
    assert :ok = Supervisor.terminate_child(AtMcp.Supervisor, Store)

    try do
      send(worker, {:release_auth, "did:plc:#{a}"})
      assert {:error, :account_control_unavailable} = Task.await(authentication)
      assert Process.whereis(Accounts) == owner
      assert {:error, :account_control_unavailable} = Accounts.status()
    after
      assert {:ok, _} = Supervisor.restart_child(AtMcp.Supervisor, Store)
    end

    assert eventually(fn -> Store.ready(a) == :ok and Store.ready(b) == :ok end)
    assert Process.whereis(Accounts) == owner
    assert {:ok, rows} = Accounts.status()
    assert Enum.all?(Enum.filter(rows, &(&1.id in [a, b])), & &1.configured)
  end

  test "overlapping cleanup and replacement claims both refuse mutation regardless of map order",
       %{a: a} do
    authentication = start_slow(a)
    assert_receive {:auth_entered, _, ^a}, 2_000

    {token, op} =
      Enum.find(:sys.get_state(Accounts).operations, fn {_, op} -> MapSet.member?(op.ids, a) end)

    cleanup_token = make_ref()
    cleanup = %{op | task: %{op.task | ref: make_ref()}, command: {:cleanup, [a]}}

    # Probe the coordinator's exclusion invariant independently of task timing.
    # A cleanup record must not mask another operation claiming the same ID.
    :sys.replace_state(Accounts, fn state -> put_in(state.operations[cleanup_token], cleanup) end)

    try do
      for ref <- [token, cleanup_token] do
        assert :superseded = GenServer.call(Accounts, {:operation, ref, {:claim, [a]}})
      end
    after
      :sys.replace_state(Accounts, fn state ->
        %{state | operations: Map.delete(state.operations, cleanup_token)}
      end)
    end

    assert :ok = Accounts.disconnect(a)
    assert {:error, _} = Task.await(authentication)
  end

  defp start_slow(id), do: Task.async(fn -> Identities.start_identity(slow_opts(id)) end)

  defp slow_opts(id),
    do: [
      id: id,
      listen_enabled: false,
      backend: SlowLogin,
      handle: id,
      password: "fixture"
    ]

  defp start_ready(id, did \\ nil) do
    assert {:ok, _} =
             Identities.start_identity(
               id: id,
               listen_enabled: false,
               backend: AtMcp.Test.MockBackend,
               backend_state: %{did: did || "did:plc:#{id}", mock: true}
             )
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(_, 0), do: false

  defp eventually(fun, attempts),
    do:
      if(fun.(),
        do: true,
        else:
          (
            Process.sleep(10)
            eventually(fun, attempts - 1)
          )
      )
end
