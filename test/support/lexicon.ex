defmodule AtMcp.Test.Lexicon do
  @moduledoc """
  Whether a record or a procedure's input matches its lexicon.

  The lexicons are copies under `test/fixtures/lexicons` (see the README
  there), written in the `app.bsky` namespace. A value built for another
  network carries that network's `$type`s, so each `$type` is read back into
  `app.bsky` before it is looked up: the namespaces differ by name, which is
  what `AtMcp.Network` maps.

  This checks the parts of the lexicon language AtMcp's records use: objects
  (required keys, and no key the lexicon does not declare), strings (length,
  graphemes, and the `at-uri`, `did` and `datetime` formats), integers, booleans,
  arrays (length and items), refs, closed unions and blobs. It returns the
  problems it found, each with the path to the value; `[]` means it matches.
  """

  @root Path.expand("../fixtures/lexicons", __DIR__)

  @doc "Problems with `value` as the record or procedure input `nsid` declares."
  def problems(value, nsid) do
    main = definition(nsid <> "#main")

    schema =
      case main do
        %{"type" => "record", "record" => record} -> record
        %{"type" => "procedure", "input" => %{"schema" => schema}} -> schema
        other -> other
      end

    check(value, schema, nsid, "")
  end

  defp check(value, %{"type" => "object"} = schema, nsid, path) when is_map(value) do
    properties = Map.get(schema, "properties", %{})
    keys = value |> Map.keys() |> Enum.map(&to_string/1)

    missing =
      for key <- Map.get(schema, "required", []), key not in keys, do: "#{path}/#{key}: required"

    undeclared =
      for key <- keys,
          key != "$type",
          not Map.has_key?(properties, key),
          do: "#{path}/#{key}: not in the lexicon"

    nested =
      for {key, item} <- value,
          property = properties[to_string(key)],
          property != nil,
          problem <- check(item, property, nsid, "#{path}/#{key}"),
          do: problem

    missing ++ undeclared ++ nested
  end

  defp check(value, %{"type" => "string"} = schema, _nsid, path) when is_binary(value) do
    [
      if(schema["maxLength"] && byte_size(value) > schema["maxLength"],
        do: "#{path}: longer than #{schema["maxLength"]} bytes"
      ),
      if(schema["maxGraphemes"] && String.length(value) > schema["maxGraphemes"],
        do: "#{path}: longer than #{schema["maxGraphemes"]} graphemes"
      ),
      format(value, schema["format"], path)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp check(value, %{"type" => "integer"}, _nsid, _path) when is_integer(value), do: []
  defp check(value, %{"type" => "boolean"}, _nsid, _path) when is_boolean(value), do: []

  defp check(value, %{"type" => "array"} = schema, nsid, path) when is_list(value) do
    length =
      [
        if(schema["maxLength"] && length(value) > schema["maxLength"],
          do: "#{path}: more than #{schema["maxLength"]} items"
        ),
        if(schema["minLength"] && length(value) < schema["minLength"],
          do: "#{path}: fewer than #{schema["minLength"]} items"
        )
      ]
      |> Enum.reject(&is_nil/1)

    items =
      value
      |> Enum.with_index()
      |> Enum.flat_map(fn {item, i} -> check(item, schema["items"], nsid, "#{path}/#{i}") end)

    length ++ items
  end

  defp check(value, %{"type" => "ref", "ref" => ref}, nsid, path),
    do: check(value, definition(qualify(ref, nsid)), owner(qualify(ref, nsid)), path)

  defp check(value, %{"type" => "union", "refs" => refs}, nsid, path) when is_map(value) do
    type = value |> Map.get("$type", Map.get(value, :"$type")) |> to_app_bsky()
    refs = Enum.map(refs, &qualify(&1, nsid))

    if type in refs or (type <> "#main") in refs do
      ref = if type in refs, do: type, else: type <> "#main"
      check(value, definition(ref), owner(ref), path)
    else
      ["#{path}: $type #{inspect(type)} is not one of #{Enum.join(refs, ", ")}"]
    end
  end

  defp check(%{} = value, %{"type" => "blob"}, _nsid, path) do
    if Map.get(value, "$type") == "blob" and is_map(value["ref"]) and is_binary(value["mimeType"]) and
         is_integer(value["size"]),
       do: [],
       else: ["#{path}: not a blob reference"]
  end

  defp check(_value, %{"type" => "unknown"}, _nsid, _path), do: []

  defp check(value, %{"type" => type}, _nsid, path),
    do: ["#{path}: #{inspect(value)} is not a #{type}"]

  defp format(value, "at-uri", path) do
    if String.starts_with?(value, "at://"), do: nil, else: "#{path}: not an AT URI"
  end

  defp format(value, "did", path) do
    if Regex.match?(~r/\Adid:[a-z]+:[A-Za-z0-9._:%-]+\z/, value),
      do: nil,
      else: "#{path}: not a DID"
  end

  defp format(value, "datetime", path) do
    case DateTime.from_iso8601(value) do
      {:ok, _, _} -> nil
      _ -> "#{path}: not an ISO 8601 datetime"
    end
  end

  defp format(_value, _format, _path), do: nil

  # `#rule` is in the lexicon being read; `nsid#rule` and `nsid` are not.
  defp qualify("#" <> name, nsid), do: owner(nsid) <> "#" <> name
  defp qualify(ref, _nsid), do: if(String.contains?(ref, "#"), do: ref, else: ref <> "#main")

  defp owner(ref), do: ref |> String.split("#") |> hd()

  defp to_app_bsky(type) when is_binary(type) do
    namespace = AtMcp.Network.namespace() <> "."

    if String.starts_with?(type, namespace),
      do: "app.bsky." <> String.replace_prefix(type, namespace, ""),
      else: type
  end

  defp to_app_bsky(type), do: inspect(type)

  defp definition(ref) do
    [nsid, name] =
      case String.split(ref, "#") do
        [nsid] -> [nsid, "main"]
        pair -> pair
      end

    path = Path.join(@root, String.replace(nsid, ".", "/") <> ".json")
    defs = path |> File.read!() |> Jason.decode!() |> Map.fetch!("defs")
    Map.fetch!(defs, name)
  end
end
