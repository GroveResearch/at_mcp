defmodule AtMcp.Test.Keys do
  @moduledoc """
  Record keys for fixtures. A post's key is a TID (the post lexicon's `"key":
  "tid"`), and the tools refuse a post URI whose key cannot be one, so a
  fixture post needs a key that is.
  """

  @alphabet ~c"234567abcdefghijklmnopqrstuvwxyz"

  @doc """
  A TID that reads as `name`: `3k`, then `name` with each character outside
  the TID alphabet spelled as one inside it, padded with `2` to 13
  characters. The same name gives the same key.
  """
  def tid(name) when is_binary(name) do
    key = prefix(name)
    if byte_size(key) > 13, do: raise(ArgumentError, "#{name} is too long for a TID")
    String.pad_trailing(key, 13, "2")
  end

  @doc """
  A TID for the `n`th of a numbered run named `name`: `tid(name)`'s start,
  then `n` in the TID alphabet (where `2` is zero), so `number/2` reads it back.
  """
  def tid(name, n) when is_integer(n) and n >= 0 do
    key = prefix(name)
    digits = Integer.digits(n, 32) |> Enum.map(&Enum.at(@alphabet, &1)) |> to_string()
    width = 13 - byte_size(key)
    if byte_size(digits) > width, do: raise(ArgumentError, "#{n} is too large for #{name}")
    key <> String.pad_leading(digits, width, "2")
  end

  @doc "The `n` that `tid(name, n)` gave `key`."
  def number(key, name) do
    "3k" <> rest = key
    spelled = binary_part(prefix(name), 2, byte_size(prefix(name)) - 2)
    ^spelled <> digits = rest

    digits
    |> String.to_charlist()
    |> Enum.reduce(0, fn c, acc -> acc * 32 + Enum.find_index(@alphabet, &(&1 == c)) end)
  end

  defp prefix(name) do
    spelled =
      name
      |> to_string()
      |> String.downcase()
      |> String.to_charlist()
      |> Enum.map(fn c -> if c in @alphabet, do: c, else: Enum.at(@alphabet, rem(c, 32)) end)

    to_string(~c"3k" ++ spelled)
  end
end
