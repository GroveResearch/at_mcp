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

    # The unspecced suggestion and trend reads take fewer, as their lexicons
    # say (`AtMcp.Effects.short_page_max/0`).
    short = AtMcp.Effects.short_page_max()

    for {name, limit} <- paged do
      max = if name in ["get_suggested_starter_packs", "get_trends"], do: short, else: max
      assert limit.minimum == min, name
      assert limit.maximum == max, name
      assert limit.default == min(default, max), name
      assert limit.description =~ "(#{min}-#{max})", name
    end
  end

  test "the unspecced suggestion and trend reads take what their lexicons allow" do
    for nsid <- [
          "app.bsky.unspecced.getSuggestedStarterPacks",
          "app.bsky.unspecced.getOnboardingSuggestedStarterPacks",
          "app.bsky.unspecced.getSuggestedFeeds",
          "app.bsky.unspecced.getTrends",
          "app.bsky.unspecced.getTrendingTopics"
        ] do
      limit =
        (Path.join(["test/fixtures/lexicons" | String.split(nsid, ".")]) <> ".json")
        |> File.read!()
        |> Jason.decode!()
        |> get_in(["defs", "main", "parameters", "properties", "limit"])

      assert limit["maximum"] == AtMcp.Effects.short_page_max(), nsid
    end
  end

  test "every batch tool states the batch limit the account enforces", %{tools: tools} do
    max = AtMcp.Effects.max_batch()

    # Batch reads. `create_starter_pack` also takes `actors`, bounded by the
    # commit that writes them, not by this limit.
    batches =
      for {name, tool} <- tools,
          tool.annotations[:readOnlyHint] == true,
          {param, %{type: "array"} = schema} <- tool.inputSchema.properties,
          param in [:uris, :actors, :others],
          do: {name, tool, schema}

    assert Enum.map(batches, &elem(&1, 0)) |> Enum.sort() ==
             ["get_feed_info", "get_labelers", "get_posts", "get_profiles", "get_relationships"]

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
    %{depth: max_depth, breadth: max_breadth, views: %{linear: linear, tree: tree}} =
      AtMcp.Effects.ProtoRune.thread_shape()

    assert tools["get_thread"].description =~
             "#{linear.depth} levels of replies, every direct reply and #{linear.breadth} reply per post below them"

    assert tools["get_thread"].description =~ "#{tree.depth} levels and #{tree.breadth} per post"
    assert tools["get_thread"].inputSchema.properties.depth.maximum == max_depth
    assert tools["get_thread"].inputSchema.properties.breadth.maximum == max_breadth
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
