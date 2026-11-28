defmodule AtMcp.Spaces.AgentRevocations do
  @moduledoc """
  Which of a principal's agents had their sessions revoked since they last
  ran: `agent-revocations.json` in the state folder, by principal and agent
  DID. Revoking also retires the agent's login key, so an agent started
  again after one gets a new key (`AtMcp.Spaces.set_agent_status/3`).

  No password is kept. When the principal must sign in as its agent (to
  deactivate or activate its account), at_mcp asks the PDS for a fresh one
  (`rotatePassword`), uses it once and forgets it.

  Installations that kept agents' passwords (`agent-passwords.json`) have
  that file removed at start by `migrate/0`, keeping only which agents were
  revoked.
  """

  require Logger

  @doc false
  def path, do: Path.join(AtMcp.Inbound.Store.default_dir(), "agent-revocations.json")

  defp old_path, do: Path.join(AtMcp.Inbound.Store.default_dir(), "agent-passwords.json")

  @doc "Marks `principal`'s agent `agent` revoked."
  def mark(principal, agent) when is_binary(principal) and is_binary(agent),
    do: change(&put_in(&1, [Access.key(principal, %{}), agent], true))

  @doc "Clears the mark, once the agent has a new login key."
  def clear(principal, agent) when is_binary(principal) and is_binary(agent),
    do: change(&Map.update(&1, principal, %{}, fn mine -> Map.delete(mine, agent) end))

  @doc "Whether `principal`'s agent `agent` was revoked since it last had a new key."
  def revoked?(principal, agent) do
    case AtMcp.PrivateFile.read(path()) do
      {:ok, contents} -> get_in(decode(contents), [principal, agent]) == true
      _ -> false
    end
  end

  @doc """
  Removes the file of agents' passwords an earlier at_mcp kept, carrying
  over which agents were revoked. Run at start.
  """
  def migrate do
    # Read whatever its mode: a file of passwords readable by others is all
    # the more reason to remove it.
    case File.lstat(old_path()) do
      {:ok, %{type: :regular}} ->
        contents = File.read!(old_path())

        revoked =
          case Jason.decode(contents) do
            {:ok, %{"principals" => %{} = principals}} ->
              for {p, agents} <- principals,
                  is_map(agents),
                  {a, %{"stale" => true}} <- agents,
                  do: {p, a}

            _ ->
              []
          end

        Enum.each(revoked, fn {p, a} -> mark(p, a) end)
        File.rm(old_path())
        Logger.info("removed the kept agents' passwords (#{old_path()}); none are kept now")
        :ok

      _ ->
        :ok
    end
  end

  defp change(fun) do
    AtMcp.PrivateFile.mutate(path(), fn current ->
      {:ok, Jason.encode!(%{"version" => 1, "principals" => fun.(decode(current))}), :ok}
    end)
  end

  defp decode(contents) when is_binary(contents) do
    case Jason.decode(contents) do
      {:ok, %{"principals" => %{} = principals}} -> principals
      _ -> %{}
    end
  end

  defp decode(_missing), do: %{}
end
