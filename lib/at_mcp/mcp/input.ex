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
  (one second, set in `config/config.exs`). The check itself takes microseconds, but the validator
  loads one module per schema keyword the first time that keyword is checked.
  In interactive code loading (`mix run`, `mix test`) that load happens inside
  the deadline, and on a loaded machine it can miss it: a correct call is then
  refused as `input_validation_unavailable`, or a correct result logged as
  unvalidated. A release started with `bin/at_mcp start` is in embedded mode
  and has every module loaded already, but `at_mcp-stdio` and
  `at_mcp-connect` run through `bin/at_mcp eval`, which loads code
  interactively, so they paid it too. Loading them at application start covers
  every way AtMcp is started. `Float` is listed because the validator calls it
  when it checks a number against `integer`. Retires when ExMCP's deadline no
  longer counts code loading.
  """
  def load_validator do
    Code.ensure_all_loaded!([Float | Application.spec(:ex_json_schema, :modules)])
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

  # Optional strings whose empty value is an instruction, not a blank: each
  # tool's description says so ("an empty description removes it").
  @empty_means %{
    "update_profile" => ["display_name", "description", "pronouns", "website"],
    "update_list" => ["description"],
    "update_starter_pack" => ["description"]
  }

  @doc """
  The arguments with every optional value filled in with nothing taken out,
  before they are validated or reach a handler. Models fill every optional
  field they are offered, with `""`, `null` and objects of those, for options
  they are not using; read as values, such an object is an image that cannot
  be read or a link card with no link, and the whole call is refused.

  Absent here: an optional `null` or blank string (except those in
  `@empty_means`); an object with nothing left in it, or with a required field
  given blank (a link card whose url is ""); an image with neither `data` nor
  `path`; and a list each of whose items was absent. A list given as `[]` is
  kept: `reply_rule: []` is nobody and `links: []` removes them all. Inside an
  object an empty list is absent too. A required argument is never taken out,
  so validation still names it.
  """
  def drop_empty(name, arguments, %ExJsonSchema.Schema.Root{schema: schema}),
    do: drop_empty(name, arguments, schema)

  def drop_empty(name, arguments, schema) when is_map(arguments) and is_map(schema) do
    keep = Map.get(@empty_means, name, [])
    required = Map.get(schema, "required", [])
    properties = Map.get(schema, "properties", %{})

    Enum.reduce(arguments, arguments, fn {key, value}, acc ->
      field = to_string(key)

      cond do
        # Optional basic fields historically treat null as omitted, not a clear.
        name == "update_profile" and field in ["display_name", "description"] and is_nil(value) ->
          Map.delete(acc, key)

        field in required or field in keep or value == [] ->
          acc

        true ->
          case emptied(value, Map.get(properties, field, %{})) do
            :absent -> Map.delete(acc, key)
            value -> Map.put(acc, key, value)
          end
      end
    end)
  end

  def drop_empty(_name, arguments, _schema), do: arguments

  # A value with its empty parts taken out, or `:absent` when nothing is left.
  defp emptied(nil, _schema), do: :absent
  defp emptied([], _schema), do: :absent

  defp emptied(value, _schema) when is_binary(value),
    do: if(String.trim(value) == "", do: :absent, else: value)

  defp emptied(map, schema) when is_map(map) do
    properties = Map.get(schema, "properties", %{})

    kept =
      for {key, value} <- map,
          (value = emptied(value, Map.get(properties, to_string(key), %{}))) != :absent,
          into: %{},
          do: {key, value}

    given = Enum.map(Map.keys(kept), &to_string/1)
    blank = map |> Map.keys() |> Enum.map(&to_string/1) |> Enum.reject(&(&1 in given))
    image? = Map.has_key?(properties, "data") and Map.has_key?(properties, "path")

    cond do
      kept == %{} -> :absent
      Enum.any?(Map.get(schema, "required", []), &(&1 in blank)) -> :absent
      image? and "data" not in given and "path" not in given -> :absent
      true -> kept
    end
  end

  # Only an object can be absent from a list: a list of strings is the tool's
  # to read or refuse.
  defp emptied(list, schema) when is_list(list) do
    items = Map.get(schema, "items", %{})

    list
    |> Enum.map(fn item -> if is_map(item), do: emptied(item, items), else: item end)
    |> Enum.reject(&(&1 == :absent))
    |> case do
      [] -> :absent
      list -> list
    end
  end

  defp emptied(value, _schema), do: value

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

  def note_ignored(result, paths) do
    them = if match?([_], paths), do: "it", else: "them"

    note(
      result,
      :ignored,
      paths,
      "ignored: #{Enum.join(paths, ", ")} (this tool does not take #{them}; nothing was done with #{them})"
    )
  end

  @doc """
  A result that also carries `value` under `key` in the structured content
  (and in its JSON text, which carries the same values), and `line` as a last
  line of text. The call itself is unchanged.
  """
  def note({:ok, %{content: content} = response, state}, key, value, line)
      when is_list(content) do
    structured = Map.get(response, :structuredContent)

    content =
      Enum.map(content, fn
        %{type: "text", text: text} = item when is_map(structured) ->
          if Jason.decode(text) == {:ok, SchemaPolicy.json_compatible(structured)},
            do: %{
              item
              | text: Jason.encode!(Map.put(Jason.decode!(text), Atom.to_string(key), value))
            },
            else: item

        item ->
          item
      end)

    response =
      response
      |> Map.put(:content, content ++ [%{type: "text", text: line}])
      |> then(fn r ->
        if is_map(structured),
          do: Map.put(r, :structuredContent, put_key(structured, key, value)),
          else: r
      end)

    {:ok, response, state}
  end

  def note(result, _key, _value, _line), do: result

  defp put_key(map, key, value) do
    if Enum.any?(Map.keys(map), &is_atom/1),
      do: Map.put(map, key, value),
      else: Map.put(map, Atom.to_string(key), value)
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
