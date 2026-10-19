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

      {:error, errors} when is_list(errors) ->
        {:error, invalid(Enum.map(errors, &problem/1))}

      {:error, :duplicate_keys} ->
        {:error, invalid([%{path: "", message: "An argument is given twice."}])}

      {:error, _reason} ->
        {:error,
         refusal(
           "input_validation_unavailable",
           "Input validation could not finish. No operation was attempted; you may try again."
         )}
    end
  end

  @doc """
  Load the JSON Schema validator's modules now, before any deadline counts.

  `SchemaPolicy.validate/3` runs each check under a wall-clock deadline
  (100 ms by default). The check itself takes microseconds, but the validator
  loads one module per schema keyword the first time that keyword is checked.
  In interactive code loading (`mix run`, `mix test`) that load happens inside
  the deadline, and on a loaded machine it can miss it: a correct call is then
  refused as `input_validation_unavailable`, or a correct result logged as
  unvalidated. A release boots in embedded mode, which loads every module at
  start, so it never paid this. Loading them at application start makes every
  mode behave like a release. Retires when ExMCP's deadline no longer counts
  code loading.
  """
  def load_validator do
    {:ok, modules} = :application.get_key(:ex_json_schema, :modules)
    Code.ensure_all_loaded!(modules)
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

  @doc """
  The paths of arguments the tool's schema does not define, such as `embed`
  or `images/0/caption`. They pass validation, since no schema here forbids
  extra keys, and no handler reads them, so a caller would otherwise believe
  they took effect.
  """
  def ignored(arguments, %ExJsonSchema.Schema.Root{schema: schema}),
    do: ignored(arguments, schema)

  def ignored(arguments, schema) when is_map(schema) do
    # `_meta` is MCP's own key, which some clients send among the arguments.
    case json_keys(arguments) do
      {:ok, data} -> data |> Map.delete("_meta") |> unknown(schema, [])
      _ -> []
    end
  end

  defp unknown(data, %{"properties" => properties} = schema, path) when is_map(data) do
    # Extra keys the schema itself governs are not ignored.
    governed? = Map.get(schema, "additionalProperties", true) not in [true, nil]

    data
    |> Enum.sort()
    |> Enum.flat_map(fn {key, value} ->
      case Map.fetch(properties, key) do
        {:ok, property} -> unknown(value, property, path ++ [key])
        :error when governed? -> []
        :error -> [Enum.join(path ++ [key], "/")]
      end
    end)
  end

  defp unknown(list, %{"items" => items}, path) when is_list(list) and is_map(items) do
    list
    |> Enum.with_index()
    |> Enum.flat_map(fn {value, i} -> unknown(value, items, path ++ [Integer.to_string(i)]) end)
  end

  defp unknown(_data, _schema, _path), do: []

  @doc """
  A result that also says which arguments were ignored: a line of text, and
  `ignored` in the structured content (and in its JSON text, which carries
  the same values). The call itself is unchanged.
  """
  def note_ignored(result, []), do: result

  def note_ignored({:ok, %{content: content} = response, state}, paths) when is_list(content) do
    line =
      "ignored: #{Enum.join(paths, ", ")} (this tool does not take #{if match?([_], paths), do: "it", else: "them"}; nothing was done with #{if match?([_], paths), do: "it", else: "them"})"

    structured = Map.get(response, :structuredContent)

    content =
      Enum.map(content, fn
        %{type: "text", text: text} = item when is_map(structured) ->
          if Jason.decode(text) == {:ok, SchemaPolicy.json_compatible(structured)},
            do: %{item | text: Jason.encode!(Map.put(Jason.decode!(text), "ignored", paths))},
            else: item

        item ->
          item
      end)

    response =
      response
      |> Map.put(:content, content ++ [%{type: "text", text: line}])
      |> then(fn r ->
        if is_map(structured),
          do: Map.put(r, :structuredContent, put_ignored(structured, paths)),
          else: r
      end)

    {:ok, response, state}
  end

  def note_ignored(result, _paths), do: result

  defp put_ignored(map, paths) do
    if Enum.any?(Map.keys(map), &is_atom/1),
      do: Map.put(map, :ignored, paths),
      else: Map.put(map, "ignored", paths)
  end

  # The refusal names each argument that failed and why, so a caller can
  # correct the call instead of guessing which field was wrong. The messages
  # describe the caller's own arguments and go back only to that caller.
  @shown 5

  defp invalid(problems) do
    shown = Enum.take(problems, @shown)
    more = length(problems) - length(shown)

    lines =
      Enum.map(shown, fn
        %{path: "", message: m} -> m
        %{path: p, message: m} -> "#{p}: #{m}"
      end) ++ if(more > 0, do: ["(#{more} more)"], else: [])

    message =
      "Arguments do not match this tool's input schema. No operation was attempted. Fix and try again:\n- " <>
        Enum.join(lines, "\n- ")

    refusal("invalid_arguments", message)
    |> put_in([:structuredContent, :problems], shown)
  end

  # ExJsonSchema reports `{message, "#/avatar"}`: the path becomes `avatar`,
  # and the arguments object itself is "".
  defp problem({message, "#" <> path}),
    do: %{path: String.trim_leading(path, "/"), message: message}

  defp problem({message, path}) when is_binary(path), do: %{path: path, message: message}
  defp problem(other), do: %{path: "", message: inspect(other)}

  defp refusal(code, message) do
    ExMCP.Server.DSL.Result.error(message)
    |> Map.put(:structuredContent, %{code: code})
  end
end
