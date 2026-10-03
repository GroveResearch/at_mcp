defmodule AtMcp.LimitsTest do
  @moduledoc """
  Each limit AtMcp enforces is declared once, where it is enforced, and every
  place that states it — a tool's input schema, its description, an error an
  agent reads — derives from that declaration. A copy written by hand is a copy
  that drifts: the tool would promise a limit the account does not apply.
  """
  use ExUnit.Case, async: true

  setup_all do
    {:ok, tools, nil, :state} = AtMcp.MCP.Server.handle_list_tools(nil, :state)
    %{tools: Map.new(tools, &{&1.name, &1})}
  end

  test "every paged tool states the page limits the account enforces", %{tools: tools} do
    %{min: min, max: max, default: default} = AtMcp.Effects.page_limits()

    paged =
      for {name, tool} <- tools, limit = tool.inputSchema.properties[:limit], do: {name, limit}

    assert length(paged) >= 16

    for {name, limit} <- paged do
      assert limit.minimum == min, name
      assert limit.maximum == max, name
      assert limit.default == default, name
      assert limit.description =~ "(#{min}-#{max})", name
    end
  end

  test "every batch tool states the batch limit the account enforces", %{tools: tools} do
    max = AtMcp.Effects.max_batch()

    batches =
      for {name, tool} <- tools,
          {param, %{type: "array"} = schema} <- tool.inputSchema.properties,
          param in [:uris, :actors, :others],
          do: {name, tool, schema}

    assert Enum.map(batches, &elem(&1, 0)) |> Enum.sort() ==
             ["get_posts", "get_profiles", "get_relationships"]

    for {name, tool, schema} <- batches do
      assert schema.maxItems == max, name
      assert schema.description =~ "at most #{max}", name
      assert tool.description =~ "1-#{max}", name
    end

    assert {:ok, %{content: [%{text: text}]}, :state} =
             AtMcp.MCP.Tools.respond({:error, :batch_too_large}, :state)

    assert text =~ "at most #{max}"
  end

  test "get_thread says the shape the backend reads", %{tools: tools} do
    %{parent_height: parents, depth: depth, replies: replies} =
      AtMcp.Effects.ProtoRune.thread_shape()

    assert tools["get_thread"].description =~
             "up to #{parents} parent levels and #{depth} reply levels, nested (#{replies} replies per node)"
  end

  # The numbers above are written once in lib/, in the module that enforces
  # them. Any other literal copy is the defect this file exists to catch.
  test "the page and batch limits are written once in lib/" do
    sources =
      for path <- Path.wildcard("lib/**/*.ex"), path != "lib/at_mcp/effects.ex", into: %{} do
        {path, File.read!(path)}
      end

    copies =
      for {path, source} <- sources,
          pattern <- [
            ~r/maximum: 50\b/,
            ~r/maxItems: 25\b/,
            ~r/\(1-50\)/,
            ~r/1-25\b/,
            ~r/at most 25\b/,
            ~r/Map\.get\(a, :limit, 20\)/,
            ~r/limit: 50\b/,
            ~r/@accept_chunk 50\b/,
            ~r/depth: 2, parentHeight: 2/
          ],
          Regex.match?(pattern, source),
          do: {path, pattern.source}

    assert copies == []
  end

  test "the endpoint's limit follows from the account's own answer time" do
    assert AtMcp.Effects.answered_within() > AtMcp.Effects.call_deadline()
    assert AtMcp.MCP.HTTP.handler_call_timeout() > AtMcp.Effects.answered_within()
  end
end
