defmodule AtMcp.Reading.Text do
  @moduledoc """
  The only pieces `AtMcp.Reading` makes its text from.

  A piece is `{:safe, iodata}`, and only this module makes one. Each value
  from a result goes through exactly one renderer:

  - `literal/1`, `shown/1`, `nonempty/1`: free text someone else wrote (a
    name, a title, a description, a quoted post's text, alt text), as one
    double-quoted literal on one line: `"`, backslash, line breaks, other
    control characters and bidirectional controls are escaped. `shown/1` and
    `nonempty/1` first read whitespace runs as one space.
  - `fence/1`: a post's own text, every line of it after `> `, which no line
    AtMcp writes starts with.
  - `ident/1`: an identifier (a DID, handle, AT URI, CID, NSID, cursor, label
    value, or a word the service chose from a set): bare when every character
    is one an identifier uses and none of AtMcp's own punctuation, otherwise a
    literal.
  - `url/1`: a web address, every byte outside RFC 3986's unreserved and
    reserved characters percent-encoded, and `(`, `)`, `[`, `]` and `'` too, so
    it cannot close a bracket or hold a space or a look-alike blank.
  - `time/1`: an ISO 8601 timestamp bare, anything else a literal.
  - `int/1`: an integer.
  - `~L"..."`: AtMcp's own words. An uppercase sigil takes no interpolation,
    so a constant is all it can hold.

  `cat/1` and `join/2` put pieces together. A raw string given to either is
  refused in the test environment (`:strict_reading` in config/test.exs), so
  a test that reaches it fails; anywhere else it is read as a literal, so a
  slip can quote what should have been bare but never prints someone's words
  as AtMcp's. `test/at_mcp/reading_text_test.exs` fails if `AtMcp.Reading`
  interpolates a string or makes a `{:safe, _}` piece itself.
  """

  @strict Application.compile_env(:at_mcp, :strict_reading, false)

  @separators %{
    line: "\n",
    blank: "\n\n",
    dot: " · ",
    space: " ",
    comma: ", ",
    semi: "; ",
    dash: " — ",
    period: ".",
    none: ""
  }

  @doc "AtMcp's own words: a compile-time constant, which cannot interpolate."
  defmacro sigil_L({:<<>>, _meta, [text]}, []) when is_binary(text),
    do: Macro.escape({:safe, text})

  @doc "Pieces one after another; nil is nothing."
  def cat(parts) when is_list(parts), do: {:safe, parts |> Enum.map(&piece/1) |> body()}

  @doc "Pieces that say something, nil and empty left out, between separators."
  def join(parts, separator) when is_list(parts) do
    sep = Map.fetch!(@separators, separator)

    {:safe,
     parts
     |> Enum.map(&piece/1)
     |> Enum.reject(&(is_nil(&1) or empty?(&1)))
     |> Enum.map(fn {:safe, io} -> io end)
     |> Enum.intersperse(sep)}
  end

  @doc "Whether a piece says nothing."
  def empty?(nil), do: true
  def empty?({:safe, io}), do: IO.iodata_length(io) == 0

  @doc "The text, for the reader; nil stays nil."
  def to_text(nil), do: nil
  def to_text({:safe, io}), do: IO.iodata_to_binary(io)

  @doc "A whole number."
  def int(n) when is_integer(n), do: {:safe, Integer.to_string(n)}

  @doc "`1 post`, `3 posts`: the words are AtMcp's own."
  def count(1, {:safe, _} = one, _many), do: cat([int(1), ~L" ", one])
  def count(n, _one, {:safe, _} = many) when is_integer(n), do: cat([int(n), ~L" ", many])

  @doc "Free text on one line as given, quoted and escaped; nil for none."
  def literal(text) when is_binary(text) do
    {:safe,
     text
     |> Jason.encode!(escape: :javascript_safe)
     |> String.replace(~r/[\x{0085}\x{200E}\x{200F}\x{202A}-\x{202E}\x{2066}-\x{2069}]/u, fn c ->
       <<code::utf8>> = c
       "\\u" <> String.pad_leading(Integer.to_string(code, 16), 4, "0")
     end)}
  end

  def literal(_text), do: nil

  @doc "Free text with its whitespace runs read as one space, as a literal."
  def shown(text) when is_binary(text), do: literal(one_line(text))
  def shown(_text), do: nil

  @doc "As `shown/1`, nil also for nothing but whitespace."
  def nonempty(text) do
    case one_line(text) do
      text when text not in [nil, ""] -> literal(text)
      _ -> nil
    end
  end

  @doc "A post's text, every line after `> `; nil for none."
  def fence(text) when is_binary(text) and text != "" do
    {:safe, text |> String.split(~r/\R/u) |> Enum.map(&["> ", &1]) |> Enum.intersperse("\n")}
  end

  def fence(_text), do: nil

  @ident ~r/\A[A-Za-z0-9._:~%#\/+=@!,$&*;?-]{1,8192}\z/

  @doc "An identifier bare when it is only an identifier's characters, else a literal."
  def ident(value) when is_binary(value) do
    if Regex.match?(@ident, value), do: {:safe, value}, else: literal(value)
  end

  def ident(_value), do: nil

  @url_bytes ~c"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~:/?#@!$&*+,;=%"

  @doc "A web address with every byte that could end or break it percent-encoded."
  def url(value) when is_binary(value) and value != "" do
    {:safe,
     for <<byte <- value>>, into: "" do
       if byte in @url_bytes,
         do: <<byte>>,
         else: "%" <> String.pad_leading(Integer.to_string(byte, 16), 2, "0")
     end}
  end

  def url(_value), do: nil

  @doc "A timestamp bare when it is one, else a literal."
  def time(at) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, _at, _offset} -> {:safe, at}
      _ -> literal(at)
    end
  end

  def time(_at), do: nil

  @doc "A string's whitespace runs as one space, trimmed. A value, not a piece."
  def one_line(text) when is_binary(text),
    do: text |> String.replace(~r/\s+/u, " ") |> String.trim()

  def one_line(_text), do: nil

  defp piece(nil), do: nil
  defp piece({:safe, _io} = piece), do: piece

  defp piece(raw) when is_binary(raw) do
    if @strict,
      do: raise(ArgumentError, "a raw string reached a reading: #{inspect(raw)}"),
      else: literal(raw)
  end

  defp body(pieces), do: for({:safe, io} <- pieces, do: io)
end
