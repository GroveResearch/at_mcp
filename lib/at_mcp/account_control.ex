defmodule AtMcp.AccountControl do
  @moduledoc "Portable release client for the running account owner. Starts no AtMcp runtime."

  def main(args) do
    case execute(args) do
      {:ok, response} ->
        IO.puts(Jason.encode!(response))
        unless response["ok"], do: System.halt(1)

      {:error, reason} ->
        IO.puts(:stderr, message(reason))
        System.halt(1)
    end
  end

  @doc false
  def execute(args, dependencies \\ []) do
    with {:ok, action, id} <- parse(args),
         root when is_binary(root) <-
           Keyword.get(dependencies, :release_root, System.get_env("RELEASE_ROOT")) do
      command = Path.join([root, "bin", "at_mcp"])
      expression = "AtMcp.CLI.account(#{inspect(action)}, #{inspect(Base.encode64(id))})"
      rpc = Keyword.get(dependencies, :rpc, &System.cmd/3)

      case rpc.(command, ["rpc", expression], stderr_to_stdout: true) do
        {output, 0} -> decode(output)
        _ -> {:error, :unavailable}
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :release_required}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  defp parse([action]) when action in ["status", "reload"], do: {:ok, action, ""}

  defp parse([action, id]) when action in ["disconnect", "reconnect"] and id != "",
    do: {:ok, action, id}

  defp parse(_), do: {:error, :usage}

  defp decode(output) do
    responses =
      output
      |> String.split("\n")
      |> Enum.flat_map(fn line ->
        case Jason.decode(line) do
          {:ok, %{"ok" => ok} = response} when is_boolean(ok) -> [response]
          _ -> []
        end
      end)

    case responses do
      [response] -> {:ok, response}
      _ -> {:error, :invalid_response}
    end
  end

  defp message(:usage),
    do: "Usage: at_mcp-accounts status | reload | disconnect NAME | reconnect NAME"

  defp message(:release_required), do: "Run this command from a built AtMcp release."
  defp message(:invalid_response), do: "AtMcp returned an invalid account-control response."

  defp message(_),
    do: "Cannot reach the AtMcp service. Start this release's service and try again."
end
