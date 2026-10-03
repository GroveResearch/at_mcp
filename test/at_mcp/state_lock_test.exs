defmodule AtMcp.StateLockTest do
  use ExUnit.Case, async: false
  @moduletag :tmp_dir

  # Each owner holds an OS port independently of the test process. ExUnit's
  # supervisor invokes terminate/2 even when an assertion fails, so every cold
  # BEAM is reaped before the temporary state directories are removed.
  defmodule Peer do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
    def command(peer, command), do: GenServer.call(peer, command, 15_000)

    @impl true
    def init(opts) do
      paths = :code.get_path() |> Enum.flat_map(&["-pa", to_string(&1)])
      script = Path.expand("../support/state_lock_peer.exs", __DIR__)

      env =
        System.get_env()
        |> Map.keys()
        |> Enum.filter(&String.starts_with?(&1, ["BLUESKY_", "AT_MCP_"]))
        |> Enum.map(&{String.to_charlist(&1), false})

      port =
        Port.open({:spawn_executable, System.find_executable("elixir")}, [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          {:line, 65_536},
          args: paths ++ [script, opts[:inbound], opts[:quota]],
          env: [{~c"MIX_ENV", ~c"test"} | env]
        ])

      state = %{port: port, os_pid: port |> Port.info(:os_pid) |> elem(1)}

      case response(port) do
        {:ok, "ready"} ->
          {:ok, state}

        error ->
          reap(state)
          {:stop, {:peer_start_failed, error}}
      end
    end

    @impl true
    def handle_call(:kill, _from, state) do
      result = reap(state)
      {:reply, result, %{state | port: nil}}
    end

    def handle_call(command, _from, state) when is_binary(command) do
      Port.command(state.port, command <> "\n")
      {:reply, response(state.port), state}
    end

    @impl true
    def terminate(_reason, state), do: reap(state)

    defp reap(%{port: nil}), do: :ok

    defp reap(%{port: port, os_pid: pid}) do
      if Port.info(port) do
        System.cmd("kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)

        receive do
          {^port, {:exit_status, _status}} -> :ok
        after
          5_000 ->
            Port.close(port)
            {:error, :peer_did_not_exit}
        end
      else
        :ok
      end
    end

    defp response(port), do: response(port, "", [], System.monotonic_time(:millisecond) + 12_000)

    defp response(port, fragment, output, deadline) do
      receive do
        {^port, {:data, {:noeol, data}}} ->
          response(port, fragment <> data, output, deadline)

        {^port, {:data, {:eol, data}}} ->
          line = fragment <> data

          case line do
            "RESULT:" <> json ->
              case Jason.decode(json) do
                {:ok, %{"result" => result}} -> {:ok, result}
                _ -> {:error, {:invalid_peer_response, line}}
              end

            _ ->
              response(port, "", [line | output], deadline)
          end

        {^port, {:exit_status, status}} ->
          {:error, {:peer_exited, status, Enum.reverse(output)}}
      after
        max(deadline - System.monotonic_time(:millisecond), 0) ->
          {:error, {:peer_timeout, Enum.reverse(output)}}
      end
    end
  end

  @tag timeout: 120_000
  test "cold BEAMs preserve exclusive durable ownership through crashes and application restarts",
       %{tmp_dir: root} do
    on_exit(fn -> File.rm_rf!(root) end)
    a = peer(root, "a", "quota")
    assert_started(a)
    b = peer(root, "a", "other-quota")
    assert_held(b)
    c = peer(root, "c", "quota")
    assert_held(c)

    # Failure to acquire the second lock releases the first new directory.
    rollback = peer(root, "c", "rollback-quota")
    assert_started(rollback)
    assert {:ok, ":ok"} = Peer.command(rollback, "stop")
    assert {:ok, "{:error, :state_writers_running}"} = Peer.command(a, "release")
    assert_held(b)
    assert {:ok, ":ok"} = Peer.command(a, "stop")
    assert Process.alive?(a)
    assert_started(b)
    assert :ok = Peer.command(b, :kill)
    assert_started(a)
    assert {:ok, ":ok"} = Peer.command(a, "stop")

    # The acquiring Erlang process may die; persistent ownership is VM-wide.
    d = peer(root, "retained", "retained-quota")
    assert {:ok, result} = Peer.command(d, "acquire_child")
    assert String.starts_with?(result, "{:ok,")
    e = peer(root, "retained", "e-quota")
    assert_held(e)
    assert {:ok, ":ok"} = Peer.command(d, "release")
    assert_started(e)
    assert {:ok, ":ok"} = Peer.command(e, "stop")

    # Killing only the root does not make the directory available to another
    # VM; application restart can reclaim it after all previous writers exit.
    f = peer(root, "raw", "raw-quota")
    assert {:ok, ":ok"} = Peer.command(f, "raw_start")
    assert {:ok, "{:error, :state_runtime_already_running}"} = Peer.command(f, "acquire")
    assert {:ok, ":ok"} = Peer.command(f, "kill_root")
    g = peer(root, "raw", "g-quota")
    assert_held(g)
    assert_started(f)
    assert {:ok, ":ok"} = Peer.command(f, "stop")
    assert_started(g)
    assert {:ok, ":ok"} = Peer.command(g, "stop")
  end

  defp peer(root, inbound, quota) do
    start_supervised!(%{
      id: make_ref(),
      start:
        {Peer, :start_link,
         [
           [
             inbound: Path.join(root, inbound),
             quota: Path.join(root, quota)
           ]
         ]},
      restart: :temporary,
      shutdown: 20_000
    })
  end

  defp assert_started(peer) do
    assert {:ok, result} = Peer.command(peer, "start")
    assert String.starts_with?(result, "{:ok,"), result
  end

  defp assert_held(peer) do
    assert {:ok, result} = Peer.command(peer, "start")
    assert result =~ "state_directory_in_use", result
  end
end
