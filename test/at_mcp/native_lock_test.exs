defmodule AtMcp.NativeLockTest do
  use ExUnit.Case, async: true

  setup_all do
    AtMcp.Test.NativeLockProbe.load!()
    :ok
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "flock-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir, path: Path.join(dir, "owner.lock")}
  end

  test "nonblocking contention and idempotent release", %{path: path} do
    assert {:ok, handle} = AtMcp.NativeLock.flock(path, wait: false)
    assert {:error, :eagain} = AtMcp.NativeLock.flock(path, wait: false)
    assert :ok = AtMcp.NativeLock.unflock(handle)
    assert :ok = AtMcp.NativeLock.unflock(handle)
    assert {:ok, next} = AtMcp.NativeLock.flock(path, wait: false)
    assert :ok = AtMcp.NativeLock.unflock(next)
  end

  test "UTF-8 long paths and embedded NUL validation", %{dir: dir, path: path} do
    assert {:error, :badpath} = AtMcp.NativeLock.flock(path <> <<0>> <> "suffix", wait: false)
    long = Path.join([dir, String.duplicate("a", 120), String.duplicate("b", 120)])
    File.mkdir_p!(long)
    path = Path.join(long, "café-🪁.lock")
    assert byte_size(path) > 255
    assert {:ok, handle} = AtMcp.NativeLock.flock(path, wait: false)
    assert File.exists?(path)
    assert :ok = AtMcp.NativeLock.unflock(handle)
  end

  test "owner death releases despite a retained reference", %{path: path} do
    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        {:ok, handle} = AtMcp.NativeLock.flock(path, wait: false)
        send(parent, {:held, handle})
        Process.sleep(:infinity)
      end)

    assert_receive {:held, retained}
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    assert {:ok, next} = acquire_after_down(path, 100)
    assert :ok = AtMcp.NativeLock.unflock(retained)
    assert {:error, :eagain} = AtMcp.NativeLock.flock(path, wait: false)
    assert :ok = AtMcp.NativeLock.unflock(next)
  end

  test "concurrent releases and owner death do not release a later lock", %{path: path} do
    for _ <- 1..100 do
      parent = self()

      {pid, ref} =
        spawn_monitor(fn ->
          {:ok, handle} = AtMcp.NativeLock.flock(path, wait: false)
          send(parent, {:held, handle})
          Process.sleep(:infinity)
        end)

      assert_receive {:held, handle}
      tasks = for _ <- 1..8, do: Task.async(fn -> AtMcp.NativeLock.unflock(handle) end)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
      assert Enum.all?(Task.await_many(tasks), &(&1 == :ok))
      {:ok, next} = acquire_after_down(path, 100)
      assert :ok = AtMcp.NativeLock.unflock(handle)
      assert {:error, :eagain} = AtMcp.NativeLock.flock(path, wait: false)
      :ok = AtMcp.NativeLock.unflock(next)
    end
  end

  test "retained resource ownership survives the acquiring process", %{path: path} do
    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        {:ok, handle} = AtMcp.NativeLock.flock(path, wait: false, monitor_owner: false)
        send(parent, {:held, handle})
      end)

    assert_receive {:held, handle}
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    assert {:error, :eagain} = AtMcp.NativeLock.flock(path, wait: false)
    assert :ok = AtMcp.NativeLock.unflock(handle)
    assert {:ok, next} = AtMcp.NativeLock.flock(path, wait: false)
    assert :ok = AtMcp.NativeLock.unflock(next)
  end

  test "lockfiles are private and their inode survives release", %{path: path} do
    {:ok, held} = AtMcp.NativeLock.flock(path, wait: false)
    before = File.stat!(path)
    assert Bitwise.band(before.mode, 0o777) == 0o600
    assert :ok = AtMcp.NativeLock.unflock(held)
    assert File.stat!(path).inode == before.inode
  end

  test "the native descriptor itself is close-on-exec", %{path: path} do
    {:ok, held} = AtMcp.NativeLock.flock(path, wait: false)

    try do
      assert AtMcp.Test.NativeLockProbe.close_on_exec?(path) == true
    after
      AtMcp.NativeLock.unflock(held)
    end
  end

  test "an exec child cannot retain a released lock", %{path: path, dir: dir} do
    {:ok, held} = AtMcp.NativeLock.flock(path, wait: false, monitor_owner: false)
    ready = Path.join(dir, "child-ready")

    child =
      Task.async(fn ->
        System.cmd("sh", ["-c", ~s(echo $$ > "$1"; exec sleep 30), "lock-child", ready])
      end)

    child_pid = await_child(ready, 500)

    try do
      assert {_, 0} = System.cmd("kill", ["-0", child_pid], stderr_to_stdout: true)
      assert :ok = AtMcp.NativeLock.unflock(held)
      assert {:ok, next} = AtMcp.NativeLock.flock(path, wait: false)
      assert :ok = AtMcp.NativeLock.unflock(next)
    after
      System.cmd("kill", ["-KILL", child_pid], stderr_to_stdout: true)
      Task.await(child)
    end
  end

  defp await_child(path, attempts) do
    case File.read(path) do
      {:ok, pid} when pid != "" ->
        String.trim(pid)

      _ when attempts > 0 ->
        Process.sleep(10)
        await_child(path, attempts - 1)

      _ ->
        flunk("exec child did not start")
    end
  end

  defp acquire_after_down(path, attempts) do
    case AtMcp.NativeLock.flock(path, wait: false) do
      {:error, :eagain} when attempts > 0 ->
        Process.sleep(1)
        acquire_after_down(path, attempts - 1)

      result ->
        result
    end
  end
end
