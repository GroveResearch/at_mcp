defmodule AtMcp.EndpointCoverageTest do
  @moduledoc """
  Every client endpoint and record type in the lexicons is a tool, waiting on an
  issue, or left out with a reason (`AtMcp.Endpoints`).

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

  test "what a deployment does not serve is listed, is something a person does, and says why" do
    listed = listed()
    outcomes = Map.new(listed, &{&1, outcome(&1)})

    bad =
      for {network, patterns} <- AtMcp.Endpoints.deployments(),
          {pattern, evidence} <- patterns,
          covered = Enum.filter(listed, &AtMcp.Endpoints.covers?(pattern, &1)),
          covered == [] or not is_binary(evidence) or
            Enum.any?(covered, &match?({:left_out, _}, outcomes[&1])),
          do: {network, pattern}

    assert network_names_known?(), "deployments/0 names a network AtMcp.Network does not know"

    assert bad == [],
           "Deployment entries that cover nothing, cover a left-out endpoint, or give no evidence: #{inspect(bad)}"
  end

  defp outcome(nsid) do
    case Enum.find(AtMcp.Endpoints.entries(), fn {p, _} -> AtMcp.Endpoints.covers?(p, nsid) end) do
      {_, outcome} -> outcome
      nil -> nil
    end
  end

  defp network_names_known?,
    do: Enum.all?(Map.keys(AtMcp.Endpoints.deployments()), &(&1 in AtMcp.Network.names()))

  defp valid?({:tool, name}, served), do: MapSet.member?(served, name)
  defp valid?({:todo, issue}, _), do: is_integer(issue) and issue > 0

  defp valid?({:left_out, reason}, _), do: is_binary(reason) and String.length(reason) > 10

  defp valid?(_, _), do: false
end
