defmodule AtMcp.EndpointCoverageTest do
  @moduledoc """
  Every client endpoint and record type in the lexicons is a tool, waiting on an
  issue, not served here, or left out with a reason (`AtMcp.Endpoints`).

  `test/fixtures/lexicon_endpoints.txt` is the list, made by
  `scripts/list_lexicon_endpoints.py` from an atproto checkout. A lexicon added
  upstream fails the first test until the table says what at_mcp does with it.
  """
  use ExUnit.Case, async: true

  @list "test/fixtures/lexicon_endpoints.txt"

  defp listed do
    @list
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.reject(&String.starts_with?(&1, "#"))
    |> Enum.map(fn line -> line |> String.split(" ") |> hd() end)
  end

  defp covering(nsid) do
    for {pattern, _} <- AtMcp.Endpoints.entries(),
        AtMcp.Endpoints.covers?(pattern, nsid),
        do: pattern
  end

  test "every listed endpoint and record type is covered by exactly one entry" do
    problems =
      for nsid <- listed(), patterns = covering(nsid), length(patterns) != 1 do
        case patterns do
          [] -> "#{nsid}: no entry says what at_mcp does with it"
          many -> "#{nsid}: covered by #{Enum.join(many, ", ")}"
        end
      end

    assert problems == [], "In #{@list}:\n" <> Enum.join(problems, "\n")
  end

  test "every entry covers something in the list" do
    listed = listed()

    stale =
      for {pattern, _} <- AtMcp.Endpoints.entries(),
          not Enum.any?(listed, &AtMcp.Endpoints.covers?(pattern, &1)),
          do: pattern

    assert stale == [], "Entries that cover nothing in #{@list}: #{inspect(stale)}"
  end

  test "every entry is a served tool, an issue, or a reason" do
    {:ok, tools, nil, :state} = AtMcp.MCP.Server.handle_list_tools(nil, :state)
    served = MapSet.new(tools, & &1.name)

    bad =
      for {pattern, outcome} <- AtMcp.Endpoints.entries(),
          not valid?(outcome, served),
          do: {pattern, outcome}

    assert bad == [], "Entries naming no served tool, issue or reason: #{inspect(bad)}"
  end

  defp valid?({:tool, name}, served), do: MapSet.member?(served, name)
  defp valid?({:todo, issue}, _), do: is_integer(issue) and issue > 0

  defp valid?({kind, reason}, _) when kind in [:left_out, :not_served],
    do: is_binary(reason) and String.length(reason) > 10

  defp valid?(_, _), do: false
end
