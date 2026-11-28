defmodule AtMcp.Spaces.StateHome do
  @moduledoc """
  Each account's binding to the principal whose state space holds its notes
  (`agent-state-spaces.json` in the state folder, by DID): the principal
  last confirmed for it (`AtMcp.Spaces.principal_of/1`, private), or the
  account itself when it governs itself. While the account's identity
  can't be read, the binding holds, so a passing outage neither sends notes
  elsewhere nor stops them.
  """

  @doc false
  def path,
    do:
      Application.get_env(:at_mcp, :state_home_path) ||
        Path.join(AtMcp.Inbound.Store.default_dir(), "agent-state-spaces.json")

  @doc "The principal bound for `did` (itself, when it governs itself), or nil."
  def principal(did) when is_binary(did) do
    case AtMcp.PrivateFile.read(path()) do
      {:ok, contents} -> get_in(decode(contents), [did, "principal"])
      _ -> nil
    end
  end

  @doc "Binds `did` to `principal`."
  def bind(did, principal) when is_binary(did) and is_binary(principal) do
    if principal(did) == principal do
      :ok
    else
      now = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

      AtMcp.PrivateFile.mutate(path(), fn current ->
        data = Map.put(decode(current), did, %{"principal" => principal, "at" => now})
        {:ok, Jason.encode!(%{"version" => 1, "accounts" => data}), :ok}
      end)
    end
  end

  defp decode(contents) when is_binary(contents) do
    case Jason.decode(contents) do
      {:ok, %{"accounts" => %{} = accounts}} -> accounts
      _ -> %{}
    end
  end

  defp decode(_missing), do: %{}
end
