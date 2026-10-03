# Cold disposable BEAM. No account configs, listeners, delivery or external calls.
Application.load(:at_mcp)
[inbound, quota] = System.argv()
Application.put_env(:at_mcp, :boot_from_env, false)
Application.put_env(:at_mcp, :inbound_state_dir, inbound)
Application.put_env(:at_mcp, :write_quota, state_dir: quota)
Application.put_env(:at_mcp, :jetstream_enabled, false)
Application.put_env(:at_mcp, :notifications_enabled, false)
Application.put_env(:at_mcp, :start_mcp, false)
Logger.configure(level: :emergency)
for app <- Application.spec(:at_mcp, :applications), do: Application.ensure_all_started(app)

defmodule StateLockPeer do
  def wait_dead(0), do: raise("writers survived root shutdown")

  def wait_dead(n) do
    if Enum.any?([AtMcp.Supervisor, AtMcp.Inbound.Store, AtMcp.WriteQuota], &Process.whereis/1) do
      Process.sleep(10)
      wait_dead(n - 1)
    end
  end

  def command("start", _dir), do: Application.ensure_all_started(:at_mcp)
  def command("stop", _dir), do: Application.stop(:at_mcp)

  def command("raw_start", _dir) do
    {:ok, pid, _dirs} = AtMcp.Application.start(:normal, [])
    Process.unlink(pid)
    :ok
  end

  def command("kill_root", _dir) do
    Process.exit(Process.whereis(AtMcp.Supervisor), :kill)
    wait_dead(300)
    :ok
  end

  def command("release", dir), do: AtMcp.StateLock.release(dir)
  def command("acquire", dir), do: AtMcp.StateLock.acquire(dir)

  def command("acquire_child", dir) do
    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        result = AtMcp.StateLock.acquire(dir)
        send(parent, {:acquired, result})
      end)

    receive do
      {:acquired, result} ->
        receive do
          {:DOWN, ^ref, :process, ^pid, :normal} -> result
        end
    end
  end

  def loop(dir) do
    case IO.read(:stdio, :line) do
      :eof ->
        :ok

      line ->
        result = command(String.trim(line), dir)
        IO.puts("RESULT:" <> Jason.encode!(%{result: inspect(result)}))
        loop(dir)
    end
  end
end

IO.puts("RESULT:" <> Jason.encode!(%{result: "ready"}))
StateLockPeer.loop(inbound)
