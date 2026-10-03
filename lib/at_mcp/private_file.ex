defmodule AtMcp.PrivateFile do
  @moduledoc """
  A private (0600) file that one process rewrites at a time.

  AtMcp keeps two of these — the accounts file and the grants file — and the
  mechanics are the same for both: refuse a file others can read, refuse a
  symlink pointed at something else, take an advisory lock for the whole
  read-modify-write, and rename a fresh temporary file into place so a crash
  never leaves a half-written credential store.

  Callers own the file's contents: this module moves bytes and never decodes
  them. Its error atoms are the ones `AtMcp.AccountConfig` already reports, so
  the vocabulary an operator sees does not change.
  """

  import Bitwise

  @type reason ::
          :config_missing
          | :config_insecure
          | :config_symlink
          | :config_unavailable
          | :config_busy

  @doc """
  Read the file's bytes, refusing anything that is not a private regular file.

  A missing file is `{:error, :config_missing}`. Whether that means "nothing
  configured yet" or "the file was deleted" is the caller's question.
  """
  @spec read(binary()) :: {:ok, binary()} | {:error, reason()}
  def read(path) when is_binary(path) do
    with :ok <- private?(path) do
      case File.read(path) do
        {:ok, contents} -> {:ok, contents}
        _ -> {:error, :config_unavailable}
      end
    end
  end

  @doc """
  Check that the file is a private regular file without reading it.

  `{:error, :config_missing}` when it is absent.
  """
  @spec private?(binary()) :: :ok | {:error, reason()}
  def private?(path) when is_binary(path) do
    case File.lstat(path) do
      {:error, :enoent} ->
        {:error, :config_missing}

      {:ok, %{type: :symlink}} ->
        {:error, :config_symlink}

      {:ok, %{type: :regular, mode: mode}} ->
        if (mode &&& 0o777) == 0o600, do: :ok, else: {:error, :config_insecure}

      _ ->
        {:error, :config_unavailable}
    end
  end

  @doc """
  Rewrite the file under an exclusive lock.

  `change` receives the current bytes, or `:missing` when there is no file yet,
  and returns `{:ok, bytes_to_write, result}` or `{:error, reason}`. The lock is
  held across the read and the write, so two concurrent callers cannot each base
  a rewrite on the same stale contents.

  `:config_busy` means another process holds the lock. This never waits: the
  callers are a CLI command and an HTTP request, and both would rather fail than
  hang.
  """
  @spec mutate(binary(), (binary() | :missing -> {:ok, binary(), term()} | {:error, term()})) ::
          {:ok, term()} | {:error, term()}
  def mutate(path, change) when is_binary(path) and is_function(change, 1) do
    lock = path <> ".lock"

    with :ok <- prepare_directory(Path.dirname(path)),
         :ok <- lockable(lock) do
      case AtMcp.NativeLock.flock(lock, wait: false, monitor_owner: false) do
        {:ok, held} ->
          try do
            with :ok <- File.chmod(lock, 0o600),
                 {:ok, current} <- current(path),
                 {:ok, next, result} <- change.(current),
                 :ok <- write(path, next) do
              {:ok, result}
            end
          after
            AtMcp.NativeLock.unflock(held)
          end

        {:error, :eagain} ->
          {:error, :config_busy}

        _ ->
          {:error, :config_unavailable}
      end
    end
  end

  defp current(path) do
    case read(path) do
      {:ok, contents} -> {:ok, contents}
      {:error, :config_missing} -> {:ok, :missing}
      error -> error
    end
  end

  # A lock path that is not a plain file is a sign the state directory is not
  # what this process thinks it is; a lock taken on it would prove nothing.
  defp lockable(path) do
    case File.lstat(path) do
      {:error, :enoent} -> :ok
      {:ok, %{type: :regular}} -> :ok
      _ -> {:error, :config_unavailable}
    end
  end

  @doc "Create the holding directory, private to this user, if it is absent."
  @spec prepare_directory(binary()) :: :ok | {:error, reason()}
  def prepare_directory(dir) do
    case File.stat(dir) do
      {:ok, %{type: :directory}} ->
        :ok

      {:error, :enoent} ->
        with :ok <- prepare_directory(Path.dirname(dir)),
             :ok <- File.mkdir(dir),
             :ok <- File.chmod(dir, 0o700) do
          :ok
        else
          _ -> {:error, :config_unavailable}
        end

      _ ->
        {:error, :config_unavailable}
    end
  end

  # Exclusive create, chmod before any content, fsync, then rename: a reader
  # either sees the previous file or the complete new one, and never a file with
  # default permissions holding a credential.
  defp write(path, contents) when is_binary(contents) do
    tmp =
      path <> "." <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false) <> ".tmp"

    try do
      with {:ok, file} <- :file.open(String.to_charlist(tmp), [:write, :binary, :exclusive, :raw]) do
        result =
          try do
            with :ok <- File.chmod(tmp, 0o600),
                 :ok <- :file.write(file, contents),
                 :ok <- :file.sync(file),
                 do: :ok
          after
            :file.close(file)
          end

        with :ok <- result, do: File.rename(tmp, path)
      end
    after
      File.rm(tmp)
    end
  end
end
