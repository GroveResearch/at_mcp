defmodule AtMcp.Response do
  @moduledoc """
  Read values out of an application response whose keys may be atoms or strings.

  Responses reach AtMcp decoded by different paths — a library's parsed structs,
  a Jetstream event, a raw JSON body — so the same field arrives as `:uri` or
  `"uri"` depending on how it got here. This is the one place that difference is
  handled.

  `false` is a value like any other. Reading with a chain of `||` fallbacks
  turns a `false` into a missing field, so these functions distinguish a key
  holding `false` from a key that is absent.
  """

  @doc """
  Fetch one key, accepting either spelling.

  Returns `{:ok, value}` for a key that is present with any value, including
  `nil` and `false`, and `:error` for a key that is absent.
  """
  def fetch(map, key) when is_map(map) do
    with :error <- Map.fetch(map, key),
         :error <- fetch_alternate(map, key) do
      :error
    end
  end

  def fetch(_map, _key), do: :error

  @doc "Walk a path of keys, returning nil if any step is missing."
  def dig(value, []), do: value

  def dig(map, [key | rest]) when is_map(map) do
    case fetch(map, key) do
      {:ok, value} -> dig(value, rest)
      :error -> nil
    end
  end

  def dig(_value, _path), do: nil

  defp fetch_alternate(map, key) when is_atom(key), do: Map.fetch(map, Atom.to_string(key))

  defp fetch_alternate(map, key) when is_binary(key) do
    Map.fetch(map, String.to_existing_atom(key))
  rescue
    # No atom by that name exists, so no key in this map can be it.
    ArgumentError -> :error
  end

  defp fetch_alternate(_map, _key), do: :error
end
