defmodule AtMcp.MediaFile do
  @moduledoc """
  An image file the server reads for a caller, so the caller does not have to
  copy the bytes into a tool call as base64.

  A model that writes an image out as base64 text writes it character by
  character, and a copy that goes wrong partway through is still valid base64:
  it posts a corrupted picture. Naming a file avoids that, but it means AtMcp
  reads files on its own host for whoever holds a grant, so it is fenced:

  - off unless `AT_MCP_MEDIA_DIR` (`media_dir:`) names a directory;
  - only a regular file inside that directory: a path that climbs out with
    `..`, or through a symbolic link that points outside it, is refused;
  - at most `AtMcp.Network.post_image_limits/0`'s bytes, the most one image on
    a post may have.

  A path is relative to the directory, or absolute and inside it as written.
  Every account a process serves reads the same directory.
  """

  @doc "The configured media directory, or nil when reading files is off."
  def dir do
    case Application.get_env(:at_mcp, :media_dir) do
      dir when is_binary(dir) and dir != "" -> Path.expand(dir)
      _ -> nil
    end
  end

  @doc "The most bytes one file may have."
  def max_bytes, do: AtMcp.Network.post_image_limits().bytes

  @doc """
  Read the file at `path`. Returns `{:ok, bytes}`, or `{:error, reason}` where
  reason is `:media_dir_unset`, `{:media_path_refused, path}` or
  `{:media_too_large, max_bytes}`. Nothing is read unless the file passes.
  """
  def read(path) when is_binary(path) do
    with {:ok, dir} <- configured(),
         {:ok, full} <- inside(dir, path),
         {:ok, %File.Stat{type: :regular, size: size}} <- File.stat(full),
         :ok <- within_limit(size),
         {:ok, bytes} <- read_at_most(full, max_bytes()),
         :ok <- within_limit(byte_size(bytes)) do
      {:ok, bytes}
    else
      {:error, {:media_too_large, _}} = error -> error
      {:error, :media_dir_unset} = error -> error
      _ -> {:error, {:media_path_refused, path}}
    end
  end

  def read(path), do: {:error, {:media_path_refused, inspect(path)}}

  defp configured do
    case dir() do
      nil -> {:error, :media_dir_unset}
      dir -> {:ok, dir}
    end
  end

  # `:filelib.safe_relative_path/2` refuses an absolute path, a `..` that climbs
  # above the directory, and a symbolic link inside it that points above it.
  defp inside(dir, path) do
    relative =
      if Path.type(path) == :absolute do
        expanded = Path.expand(path)

        case Path.relative_to(expanded, dir) do
          ^expanded -> :outside
          relative -> relative
        end
      else
        path
      end

    case relative != :outside and :filelib.safe_relative_path(relative, dir) do
      safe when is_binary(safe) or is_list(safe) -> {:ok, Path.join(dir, to_string(safe))}
      _ -> :error
    end
  end

  defp within_limit(size) do
    if size <= max_bytes(), do: :ok, else: {:error, {:media_too_large, max_bytes()}}
  end

  # The file may grow between the stat and the read; never read more than one
  # byte past the limit, so that is caught too.
  defp read_at_most(path, limit) do
    File.open(path, [:read, :binary], fn file ->
      case IO.binread(file, limit + 1) do
        bytes when is_binary(bytes) -> bytes
        _eof_or_error -> ""
      end
    end)
  end
end
