defmodule AtMcp.StateLock do
  @moduledoc false

  # A lock tied to a restartable Erlang process could release before the other
  # writers stop. Retain the resource across those process failures; application
  # shutdown releases it after its supervision tree, and OS exit always does.
  def acquire_all(dirs) do
    dirs = dirs |> Enum.map(&Path.expand/1) |> Enum.uniq() |> Enum.sort()

    Enum.reduce_while(dirs, {:ok, []}, fn dir, {:ok, acquired} ->
      case acquire(dir) do
        {:ok, dir} ->
          {:cont, {:ok, [dir | acquired]}}

        error ->
          Enum.each(acquired, &release/1)
          {:halt, error}
      end
    end)
  end

  def acquire(dir) do
    dir = Path.expand(dir)
    key = {__MODULE__, dir}

    case :persistent_term.get(key, nil) do
      nil ->
        with :ok <- File.mkdir_p(dir),
             :ok <- File.chmod(dir, 0o700),
             {:ok, handle} <-
               AtMcp.NativeLock.flock(Path.join(dir, ".owner.lock"),
                 wait: false,
                 monitor_owner: false
               ) do
          :persistent_term.put(key, handle)
          {:ok, dir}
        else
          {:error, :eagain} -> {:error, :state_directory_in_use}
          _ -> {:error, :state_directory_unavailable}
        end

      _handle ->
        if Enum.any?(
             [AtMcp.Supervisor, AtMcp.Inbound.Store, AtMcp.WriteQuota],
             &Process.whereis/1
           ),
           do: {:error, :state_runtime_already_running},
           else: {:ok, dir}
    end
  end

  def release(dir) do
    if Enum.any?([AtMcp.Inbound.Store, AtMcp.WriteQuota], &Process.whereis/1) do
      # An abnormal shutdown may still have live children. Keep ownership until
      # they have gone or this VM exits, rather than letting another VM write.
      {:error, :state_writers_running}
    else
      key = {__MODULE__, Path.expand(dir)}

      case :persistent_term.get(key, nil) do
        nil ->
          :ok

        handle ->
          # Never leave a closed handle published if shutdown is interrupted.
          :persistent_term.erase(key)
          :ok = AtMcp.NativeLock.unflock(handle)
          :ok
      end
    end
  end
end
