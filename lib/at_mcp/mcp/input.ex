defmodule AtMcp.MCP.Input do
  @moduledoc false
  alias ExMCP.Content.SchemaPolicy

  # ExMCP 1.5's DSL normalizes argument keys/defaults but does not validate
  # inputSchema before calling the handler. Use that same declaration here;
  # remove this boundary when the dependency provides pre-handler validation.
  # Unlike output checks, an input timeout is safe to refuse: no handler ran.
  def validate(arguments, schema) do
    result =
      with {:ok, data} <- json_keys(arguments), do: SchemaPolicy.validate(data, schema)

    case result do
      :ok ->
        :ok

      {:error, errors} when is_list(errors) or errors == :duplicate_keys ->
        {:error,
         refusal(
           "invalid_arguments",
           "Arguments do not match this tool's input schema. Check its required fields, types and limits, then try again. No operation was attempted."
         )}

      {:error, _reason} ->
        {:error,
         refusal(
           "input_validation_unavailable",
           "Input validation could not finish. No operation was attempted; you may try again."
         )}
    end
  end

  # Direct Elixir callers may use atom keys, but values must retain their
  # types: accepting an atom as a string here would pass an unchecked value
  # to the handler, which receives the original arguments.
  defp json_keys(map) when is_map(map) do
    Enum.reduce_while(map, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      key = if is_atom(key), do: Atom.to_string(key), else: key

      with false <- Map.has_key?(acc, key), {:ok, value} <- json_keys(value) do
        {:cont, {:ok, Map.put(acc, key, value)}}
      else
        true -> {:halt, {:error, :duplicate_keys}}
        error -> {:halt, error}
      end
    end)
  end

  defp json_keys(list) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn item, {:ok, acc} ->
      case json_keys(item) do
        {:ok, item} -> {:cont, {:ok, [item | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      error -> error
    end
  end

  defp json_keys(value), do: {:ok, value}

  defp refusal(code, message) do
    ExMCP.Server.DSL.Result.error(message)
    |> Map.put(:structuredContent, %{code: code})
  end
end
