defmodule AtMcp.NativeLock do
  @moduledoc """
  Application-owned advisory file locks for state and private-file mutation.

  Derived from flock_ex 0.1.0 (Apache-2.0); see licenses/flock_ex. State
  ownership retains an unmonitored resource until all writers have stopped.
  """

  @on_load :load_nif

  @doc false
  def load_nif do
    path = :filename.join(:code.priv_dir(:at_mcp), ~c"native_lock")
    :erlang.load_nif(path, 0)
  end

  @doc """
  Acquire a lock on `path`.
  Returns `{:ok, handle}` or `{:error, reason}`.

  Options:
  * `:exclusive` - if true, obtain an exclusive (`LOCK_EX`) lock (default: true),
  else obtain shared/read-only ('LOCK_SH') lock
  * `:wait` - if false, return immediately with `{:error, :eagain}`
  if lock cannot be immediately acquired. By default (`true`), wait for lock to become free
  * `:monitor_owner` - default `true` releases when the acquiring process dies.
  Set `false` for resource lifetime instead: callers must retain the handle and
  explicitly release it after all protected writers stop. BEAM exit always
  releases the OS lock.

  A monitored lock releases when its acquiring process dies. Any lock releases
  when the last retained handle is garbage collected, or when this OS process exits.

  However, cleanup of variables going out of scope doesn't happen until the next garbage collection
  cycle, so if you want to ensure the lock is released immediately, you should call `unflock/1`
  explicitly.
  """
  def flock(path, opts \\ []) when is_binary(path) and is_list(opts) do
    do_flock(path, opts)
  end

  defp do_flock(_path, _opts), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Release a previously acquired lock.
  """
  def unflock(_handle), do: :erlang.nif_error(:nif_not_loaded)
end
