defmodule AtMcp.ReadingTextTest do
  @moduledoc """
  `AtMcp.Reading` builds its text only from `AtMcp.Reading.Text` pieces, so no
  value from a result reaches the text unless a renderer made it safe. These
  tests hold the module to that: it interpolates no string and makes no piece
  itself, and each renderer keeps what it renders inside its own token.
  """
  use ExUnit.Case, async: true

  import AtMcp.Reading.Text

  # The modules that write text a model reads.
  @sources for file <- ~w(reading.ex mcp/tools.ex mcp/web_links.ex),
               do: Path.expand("../../lib/at_mcp/" <> file, __DIR__)

  defp ast, do: for(source <- @sources, do: source |> File.read!() |> Code.string_to_quoted!())

  defp find(ast, pred) do
    {_, found} =
      Macro.prewalk(ast, [], fn node, acc ->
        if pred.(node), do: {node, [node | acc]}, else: {node, acc}
      end)

    found
  end

  test "AtMcp.Reading, AtMcp.MCP.Tools and AtMcp.MCP.WebLinks interpolate no string" do
    interpolations =
      find(ast(), fn
        {:<<>>, _, parts} ->
          Enum.any?(parts, &match?({:"::", _, [{{:., _, [Kernel, :to_string]}, _, _}, _]}, &1))

        _ ->
          false
      end)

    assert interpolations == [],
           "interpolated: #{Enum.map_join(interpolations, "; ", &Macro.to_string/1)}"
  end

  # A string Reading puts together itself (a capped description, a pattern)
  # is still a raw string, which the joiners refuse: only a renderer makes it
  # a piece.
  test "AtMcp.Reading, AtMcp.MCP.Tools and AtMcp.MCP.WebLinks make no piece themselves" do
    assert find(ast(), &(&1 == :safe)) == []
  end

  test "a raw string given to the joiners is refused under test" do
    assert_raise ArgumentError, fn -> cat(["raw"]) end
    assert_raise ArgumentError, fn -> join([~L"a", "raw"], :dot) end
  end

  test "an identifier is bare only when it is one; anything else is a literal" do
    for id <- [
          "did:plc:abc123",
          "alice.test",
          "at://did:plc:a/app.bsky.feed.post/3k",
          "app.bsky.feed.defs#reasonRepost",
          "!hide",
          "bafyreib2rxk3rh6kzwq",
          "1696000000000::bafy",
          "app.bsky.feed.post"
        ],
        do: assert(to_text(ident(id)) == id)

    assert to_text(ident("x\nYou bookmarked this")) == ~s("x\\nYou bookmarked this")
    assert to_text(ident("spam · set to hide")) == ~s("spam · set to hide")
    assert to_text(ident("a)]b")) == ~s|"a)]b"|
    # The joiners' separators: a value holding one is a literal.
    assert to_text(ident("porn,graphic-media")) == ~s("porn,graphic-media")
    assert to_text(ident("a.test;verified")) == ~s("a.test;verified")
  end

  test "a web address cannot close a bracket or hold a blank" do
    assert to_text(url("https://x.test/a?b=c#d")) == "https://x.test/a?b=c#d"

    assert to_text(url("https://x.test/)]\u3164You bookmarked\"<>\\'")) ==
             "https://x.test/%29%5D%E3%85%A4You%20bookmarked%22%3C%3E%5C%27"
  end

  test "a literal keeps its text on its line and its quotes closed" do
    assert to_text(literal("a\"b\\c\nd\u2028e\u0085f\u202Eg")) ==
             ~s("a\\"b\\\\c\\nd\\u2028e\\u0085f\\u202Eg")

    assert to_text(time("2026-10-01T00:00:00Z")) == "2026-10-01T00:00:00Z"
    assert to_text(time("2026 · archived")) == ~s("2026 · archived")
  end

  test "a fenced text has no line that does not start with the fence" do
    text = "a\nb\r\nc\rd\u2028e\u2029f\u0085g\vh\fi"
    lines = text |> fence() |> to_text() |> String.split(~r/\R/u)
    assert length(lines) == 9
    assert Enum.all?(lines, &String.starts_with?(&1, "> "))
  end
end
