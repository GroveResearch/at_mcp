defmodule AtMcp.Spaces.AgentPasswords do
  @moduledoc """
  The passwords of a principal's agents, which the PDS gives once, when it
  creates the agent (`createAgent`): kept in the state folder,
  `agent-passwords.json`, private to this user, by principal and agent DID.
  No tool returns them. The principal uses an agent's password for what the
  agent's account needs it for (its email, deactivation, app passwords),
  outside the agent's own key.
  """

  @doc false
  def path, do: Path.join(AtMcp.Inbound.Store.default_dir(), "agent-passwords.json")

  @doc "Keeps `password` for `principal`'s agent `agent`, replacing an earlier one."
  def put(principal, agent, password)
      when is_binary(principal) and is_binary(agent) and is_binary(password) do
    now = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    AtMcp.PrivateFile.mutate(path(), fn current ->
      data = decode(current)
      mine = Map.get(data, principal, %{})
      mine = Map.put(mine, agent, %{"password" => password, "at" => now})
      {:ok, Jason.encode!(%{"version" => 1, "principals" => Map.put(data, principal, mine)}), :ok}
    end)
  end

  @doc "The password kept for `principal`'s agent `agent`, or `:error`."
  def get(principal, agent) do
    with {:ok, contents} <- AtMcp.PrivateFile.read(path()),
         %{"password" => password} <- get_in(decode(contents), [principal, agent]) do
      {:ok, password}
    else
      _ -> :error
    end
  end

  defp decode(contents) when is_binary(contents) do
    case Jason.decode(contents) do
      {:ok, %{"principals" => %{} = principals}} -> principals
      _ -> %{}
    end
  end

  defp decode(_missing), do: %{}
end
