defmodule AtMcp.AccountOwnerTest do
  @moduledoc """
  One process owns each account and does its work.

  The owner runs every call in a task of its own, under the call's deadline.
  Writes go one at a time, in the order they arrived; reads do not wait behind
  them. A call the owner never started changed nothing, and a write it had sent
  when the owner stopped is an unknown outcome.
  """
  use ExUnit.Case, async: false

  @moduletag :tmp_dir
  @did "did:plc:owner"

  defmodule Backend do
    @moduledoc false
    # `hang` names the verbs that report their arrival to the test and wait to
    # be released, which is what a service that stopped answering looks like.

    # A login has no session to carry the test's state, so it reads a named one.
    def login(_opts) do
      arrive_and_wait(__MODULE__, :login, nil)
      {:ok, %{did: "did:plc:owner", test_state: __MODULE__}}
    end

    def refresh(session), do: {:ok, session}
    # `:outlive` makes the task survive its owner, which a task never does on
    # its own; it stands for a task the caller cannot see stop in time.
    def prepare_post(session, _text, opts), do: resolve_references(session, opts)

    def resolve_references(session, opts) do
      if Keyword.get(opts, :outlive) do
        Process.flag(:trap_exit, true)
        arrive_and_wait(session.test_state, :resolve_references, nil)
      end

      {:ok, opts}
    end

    def post(session, text, _opts) do
      arrive_and_wait(session.test_state, :post, text)
      {:ok, %{uri: "at://did:plc:owner/app.bsky.feed.post/#{text}", cid: "bafy"}}
    end

    def get_profile(session, actor) do
      arrive_and_wait(session.test_state, :get_profile, actor)
      {:ok, %{did: "did:plc:owner", handle: actor}}
    end

    def list_notifications(session, opts) do
      arrive_and_wait(session.test_state, :list_notifications, opts[:cursor])
      {:ok, %{items: [], cursor: nil}}
    end

    defp arrive_and_wait(test_state, verb, arg) do
      %{test: test, hang: hang} = Agent.get(test_state, & &1)
      send(test, {:arrived, verb, arg, self()})

      if verb in hang do
        receive do
          :release -> :ok
        after
          30_000 -> :ok
        end
      end
    end
  end

  setup do
    previous = Application.fetch_env(:at_mcp, :call_deadline_ms)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:at_mcp, :call_deadline_ms, value)
        :error -> Application.delete_env(:at_mcp, :call_deadline_ms)
      end
    end)
  end

  test "a read is answered while a write on the same account waits on its service" do
    deadline(5_000)
    effects = owner(hang: [:post])

    writer = Task.async(fn -> AtMcp.Effects.post(effects, "slow") end)
    assert_receive {:arrived, :post, "slow", held}, 2_000

    {elapsed, result} =
      :timer.tc(fn -> AtMcp.Effects.get_profile(effects, "me") end, :millisecond)

    assert {:ok, %{handle: "me"}} = result
    assert elapsed < 1_000

    send(held, :release)
    assert {:ok, _} = Task.await(writer, 5_000)
  end

  test "the notification poller does not hold the account while its service is slow",
       %{tmp_dir: dir} do
    deadline(5_000)
    effects = owner(hang: [:list_notifications])
    store = start_supervised!({AtMcp.Inbound.Store, name: nil, state_dir: dir})

    poller =
      start_supervised!(
        {AtMcp.Notifications, name: nil, effects: effects, store: store, enabled: false}
      )

    send(poller, :poll)
    assert_receive {:arrived, :list_notifications, nil, held}, 2_000

    {elapsed, result} =
      :timer.tc(fn -> AtMcp.Effects.post(effects, "meanwhile") end, :millisecond)

    assert {:ok, %{uri: _}} = result
    assert elapsed < 1_000
    send(held, :release)
  end

  test "writes are sent one at a time, in the order they arrived" do
    deadline(5_000)
    effects = owner(hang: [:post])

    first = Task.async(fn -> AtMcp.Effects.post(effects, "first") end)
    assert_receive {:arrived, :post, "first", held}, 2_000
    second = Task.async(fn -> AtMcp.Effects.post(effects, "second") end)
    # The two callers reach the account in the order they are started.
    Process.sleep(50)
    third = Task.async(fn -> AtMcp.Effects.post(effects, "third") end)

    refute_receive {:arrived, :post, _, _}, 200
    send(held, :release)
    assert_receive {:arrived, :post, "second", held}, 2_000
    refute_receive {:arrived, :post, _, _}, 200
    send(held, :release)
    assert_receive {:arrived, :post, "third", held}, 2_000
    send(held, :release)

    assert Enum.all?(Task.await_many([first, second, third], 5_000), &match?({:ok, _}, &1))
  end

  test "a write queued behind a slow write is not sent once its deadline passes" do
    deadline(10_000)
    effects = owner(hang: [:post])

    first = Task.async(fn -> AtMcp.Effects.post(effects, "slow") end)
    assert_receive {:arrived, :post, "slow", held}, 2_000

    deadline(300)
    assert {:error, :call_deadline_exceeded} = AtMcp.Effects.post(effects, "queued")

    send(held, :release)
    assert {:ok, _} = Task.await(first, 5_000)
    refute_receive {:arrived, :post, "queued", _}, 300
  end

  test "a write the owner had sent when it stopped is unknown, and its work stops with it" do
    deadline(10_000)
    effects = owner(hang: [:post])
    Process.unlink(effects)

    writer = Task.async(fn -> AtMcp.Effects.post(effects, "in flight") end)
    assert_receive {:arrived, :post, "in flight", held}, 2_000
    ref = Process.monitor(held)

    Process.exit(effects, :kill)

    assert_receive {:DOWN, ^ref, :process, ^held, _}, 1_000
    assert {:error, {:write_outcome_unknown, _}} = Task.await(writer, 2_000)
  end

  test "a caller that stops waiting is never told nothing changed about a write that is then sent" do
    deadline(300)
    effects = owner(hang: [])
    test = self()

    # The task passes its deadline check and is then held, standing for the
    # scheduler descheduling it; the owner is suspended so it cannot stop the
    # task at the deadline, and the caller gives up on its own.
    Application.put_env(:at_mcp, :effects_pause_before_dispatch, fn ->
      send(test, {:paused, self()})

      receive do
        :resume -> :ok
      end
    end)

    on_exit(fn -> Application.delete_env(:at_mcp, :effects_pause_before_dispatch) end)

    writer = Task.async(fn -> AtMcp.Effects.post(effects, "late") end)
    assert_receive {:paused, task}, 2_000
    :ok = :sys.suspend(effects)

    result = Task.await(writer, 5_000)
    send(task, :resume)
    sent? = receive do: ({:arrived, :post, "late", _} -> true), after: (500 -> false)
    :ok = :sys.resume(effects)

    if sent?, do: assert({:error, {:write_outcome_unknown, _}} = result)
  end

  test "the longest a caller waits is answered_within/0, and the endpoint waits longer" do
    deadline(300)
    effects = owner(hang: [:resolve_references])
    Process.unlink(effects)

    # The worst case: the owner cannot answer (suspended), stops just before
    # the caller's own wait runs out, and its task is not seen to stop.
    started = System.monotonic_time(:millisecond)
    writer = Task.async(fn -> AtMcp.Effects.post(effects, "outlives", outlive: true) end)
    assert_receive {:arrived, :resolve_references, _, held}, 2_000
    :ok = :sys.suspend(effects)
    Process.sleep(max(started + 300 + 1_000 - 100 - System.monotonic_time(:millisecond), 0))
    Process.exit(effects, :kill)

    assert {:error, {:write_outcome_unknown, _}} = Task.await(writer, 5_000)
    elapsed = System.monotonic_time(:millisecond) - started
    send(held, :release)

    assert elapsed > 300 + 1_000
    assert elapsed <= AtMcp.Effects.answered_within()
    assert AtMcp.MCP.HTTP.handler_call_timeout() > AtMcp.Effects.answered_within()
  end

  test "a write whose task is not seen to stop when its owner does is unknown" do
    deadline(10_000)
    effects = owner(hang: [:resolve_references])
    Process.unlink(effects)

    writer = Task.async(fn -> AtMcp.Effects.post(effects, "outlives", outlive: true) end)
    assert_receive {:arrived, :resolve_references, _, held}, 2_000

    Process.exit(effects, :kill)

    assert {:error, {:write_outcome_unknown, _}} = Task.await(writer, 3_000)
    send(held, :release)
  end

  test "a write still waiting for the account when its owner stops changed nothing" do
    deadline(10_000)
    effects = owner(hang: [:post])
    Process.unlink(effects)

    first = Task.async(fn -> AtMcp.Effects.post(effects, "in flight") end)
    assert_receive {:arrived, :post, "in flight", _held}, 2_000
    second = Task.async(fn -> AtMcp.Effects.post(effects, "waiting") end)
    Process.sleep(100)

    Process.exit(effects, :kill)

    assert {:error, {:write_outcome_unknown, _}} = Task.await(first, 2_000)
    assert {:error, :account_runtime_unavailable} = Task.await(second, 2_000)
    refute_received {:arrived, :post, "waiting", _}
  end

  test "a write whose caller has gone is not sent" do
    deadline(10_000)
    effects = owner(hang: [:post])

    first = Task.async(fn -> AtMcp.Effects.post(effects, "first") end)
    assert_receive {:arrived, :post, "first", held}, 2_000

    {caller, watch} = spawn_monitor(fn -> AtMcp.Effects.post(effects, "orphan") end)
    Process.sleep(100)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^watch, :process, ^caller, :killed}

    send(held, :release)
    assert {:ok, _} = Task.await(first, 5_000)
    refute_receive {:arrived, :post, "orphan", _}, 300
  end

  test "a task held up past its deadline does not send the write afterwards" do
    deadline(300)
    quota = AtMcp.Test.QuotaFixture.quota(100)
    effects = owner(hang: [], write_quota: quota)

    # The write waits on its quota reservation, and the owner cannot stop it,
    # so the task itself is the last thing between the deadline and a write.
    :ok = :sys.suspend(quota)
    writer = Task.async(fn -> AtMcp.Effects.post(effects, "late") end)
    assert eventually(fn -> Process.info(quota, :message_queue_len) |> elem(1) > 0 end)
    :ok = :sys.suspend(effects)

    assert {:error, :call_deadline_exceeded} = Task.await(writer, 3_000)

    :ok = :sys.resume(quota)
    refute_receive {:arrived, :post, "late", _}, 500
    :ok = :sys.resume(effects)
  end

  defmodule RefusedOnce do
    @moduledoc false
    # The first post is held until released and then refuses the credential;
    # a post on the refreshed session reports itself and succeeds.
    def refresh(session), do: {:ok, Map.put(session, :fresh, true)}
    def prepare_post(session, _text, opts), do: resolve_references(session, opts)

    def resolve_references(_session, opts), do: {:ok, opts}

    def post(%{fresh: true} = session, text, _opts) do
      send(session.test, {:arrived, :retry, text, self()})
      {:ok, %{uri: "at://did:plc:owner/app.bsky.feed.post/#{text}", cid: "bafy"}}
    end

    def post(session, text, _opts) do
      send(session.test, {:arrived, :post, text, self()})

      receive do
        :release -> :ok
      end

      {:error, AtMcp.Effects.Failure.new(:auth_refused)}
    end
  end

  test "a retry after session recovery is not sent once the deadline has passed" do
    deadline(300)

    effects =
      start_supervised!(
        {AtMcp.Effects,
         backend: RefusedOnce,
         write_quota: AtMcp.Test.QuotaFixture.quota(100),
         backend_state: %{did: @did, test: self()}},
        id: make_ref()
      )

    writer = Task.async(fn -> AtMcp.Effects.post(effects, "late") end)
    assert_receive {:arrived, :post, "late", held}, 2_000

    # The owner misses the deadline, so the task is the last thing between the
    # deadline and a second dispatch.
    :sys.replace_state(effects, fn state ->
      Enum.each(state.calls, fn {_id, call} -> Process.cancel_timer(call.timer) end)
      state
    end)

    Process.sleep(400)
    send(held, :release)

    refute_receive {:arrived, :retry, "late", _}, 500
    assert {:error, _} = Task.await(writer, 3_000)
  end

  test "an owner that stops normally stops its work" do
    deadline(10_000)
    effects = owner(hang: [:post])
    Process.unlink(effects)

    writer = Task.async(fn -> AtMcp.Effects.post(effects, "in flight") end)
    assert_receive {:arrived, :post, "in flight", held}, 2_000
    ref = Process.monitor(held)

    :ok = GenServer.stop(effects, :normal)

    assert_receive {:DOWN, ^ref, :process, ^held, _}, 1_000
    assert {:error, {:write_outcome_unknown, _}} = Task.await(writer, 2_000)
  end

  test "a login the service never answers is answered at the deadline" do
    deadline(300)

    test = self()

    start_supervised!(%{
      id: Backend,
      start: {Agent, :start_link, [fn -> %{test: test, hang: [:login]} end, [name: Backend]]}
    })

    effects =
      start_supervised!(
        {AtMcp.Effects,
         backend: Backend,
         handle: "owner.test",
         password: "disposable-password",
         write_quota: AtMcp.Test.QuotaFixture.quota(100)}
      )

    task = Task.async(fn -> AtMcp.Effects.authenticate(effects) end)
    assert_receive {:arrived, :login, _, _}, 2_000
    assert {:ok, {:error, :call_deadline_exceeded}} = Task.yield(task, 2_000)
  end

  defp deadline(ms), do: Application.put_env(:at_mcp, :call_deadline_ms, ms)

  defp eventually(fun, attempts \\ 100)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp owner(opts) do
    start_supervised!(
      {AtMcp.Effects,
       backend: Backend,
       write_quota:
         Keyword.get_lazy(opts, :write_quota, fn -> AtMcp.Test.QuotaFixture.quota(100) end),
       backend_state: %{did: @did, test_state: test_state(Keyword.fetch!(opts, :hang))}},
      id: make_ref()
    )
  end

  defp test_state(hang) do
    test = self()
    start_supervised!({Agent, fn -> %{test: test, hang: hang} end}, id: make_ref())
  end
end
