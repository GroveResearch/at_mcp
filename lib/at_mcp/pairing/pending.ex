defmodule AtMcp.Pairing.Pending do
  @moduledoc """
  A pairing that has started and not yet settled: its login key and what it
  was for, kept in the key folder (0700) as `pairing-<NAME>.json` (0600)
  beside the key.

  A pairing's outcome can be unknown: the principal may have created the
  agent (or enrolled its key) after at_mcp stopped waiting, or a response
  may have been lost. So the key is kept until the outcome is settled: the
  key signs in to an account (the pairing is finished), or the operator
  cancels it (`--cancel`). Running the same command again resumes with the
  same key, and its first step is a sign-in, which finds the account if
  it exists. A pending pairing older than #{7} days is discarded when next
  looked at: its links expired long ago, and a principal who acted on one
  has an agent whose key `repair` can replace.
  """

  @max_age_s 7 * 86_400

  defp path(name), do: Path.join(AtMcp.Spaces.keys_dir(), "pairing-#{name}.json")

  @doc "The pending pairing for `name`, or `:none`. An expired one is discarded."
  def load(name) do
    with {:ok, body} <- File.read(path(name)),
         {:ok, %{"key_file" => key_file, "started_at" => started} = pending} <-
           Jason.decode(body),
         true <- File.regular?(key_file) do
      if System.os_time(:second) - started > @max_age_s do
        cancel(name)
        :none
      else
        {:ok, pending}
      end
    else
      {:error, :enoent} -> :none
      _ -> {:error, :pairing_state_unreadable}
    end
  end

  @doc "Records a new pairing for `name`; answers it, with the path its key goes to."
  def start(name, attrs) do
    pending =
      Map.merge(attrs, %{
        "key_file" =>
          Path.join(
            AtMcp.Spaces.keys_dir(),
            "login-pending-" <>
              Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false) <> ".json"
          ),
        "started_at" => System.os_time(:second)
      })

    file = path(name)

    with :ok <- File.write(file, Jason.encode!(pending), [:exclusive]),
         :ok <- File.chmod(file, 0o600) do
      {:ok, pending}
    else
      {:error, :eexist} -> {:error, :pairing_pending}
      {:error, _} -> {:error, :pairing_state_unreadable}
    end
  end

  @doc "The pairing is settled and its key moved: forget it."
  def finish(name) do
    _ = File.rm(path(name))
    :ok
  end

  @doc "The operator gives up on it: its key and record go."
  def cancel(name) do
    case File.read(path(name)) do
      {:ok, body} ->
        with {:ok, %{"key_file" => key_file}} <- Jason.decode(body), do: File.rm(key_file)
        File.rm(path(name))
        :ok

      {:error, :enoent} ->
        {:error, :no_pending_pairing}

      _ ->
        File.rm(path(name))
        :ok
    end
  end
end
