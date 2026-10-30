defmodule AtMcp.ReadToolsTest do
  @moduledoc """
  A read is a tool whose published `readOnlyHint` is true, and nothing else
  (#202). A read returns text unless asked for json, so each one takes a
  `format` argument. `tools/list` lists no output schema for any tool (#220),
  because MCP requires a tool with a listed schema to return structured
  content. Every other tool keeps an output schema that checks its results.
  The tests run asynchronously, so the fast checks a pull request runs catch a
  tool misclassified as a read.
  """
  use ExUnit.Case, async: true

  setup_all do
    {:ok, tools, nil, :state} = AtMcp.MCP.Server.handle_list_tools(nil, :state)
    %{tools: tools}
  end

  # A read that returns text unless asked for json: not the status tools
  # (`AtMcp.MCP.DSL.status/0`), which always return their structured content.
  defp read?(tool),
    do:
      (tool[:annotations] || %{})[:readOnlyHint] == true and
        tool.name not in AtMcp.MCP.DSL.status()

  test "every tool whose readOnlyHint is true declares no output schema and takes format",
       %{tools: tools} do
    reads = Enum.filter(tools, &read?/1)
    assert reads != []

    for tool <- reads do
      refute Map.has_key?(tool, :outputSchema),
             "#{tool.name} is a read and declares an output schema"

      assert tool.inputSchema.properties[:format] || tool.inputSchema.properties["format"],
             "#{tool.name} is a read and takes no format"
    end
  end

  # No tool lists its output schema (`AtMcp.MCP.DSL.handle_list_tools/2`), but
  # every write keeps one, which checks each of its results.
  test "every other tool has an output schema that checks its result, and takes no format",
       %{tools: tools} do
    schemas = AtMcp.MCP.Server.__output_schemas__()

    for tool <- Enum.reject(tools, &read?/1) do
      refute Map.has_key?(tool, :outputSchema), "#{tool.name} lists an output schema"
      schema = Map.fetch!(schemas, tool.name)

      assert schema["type"] == "object" or schema[:type] == "object",
             "#{tool.name} is not a read and has no output schema"

      unless tool.name in AtMcp.MCP.DSL.status() do
        refute tool.inputSchema.properties[:format] || tool.inputSchema.properties["format"],
               "#{tool.name} is not a read and takes format"
      end
    end
  end

  test "a read answers in text alone unless asked for json" do
    {:ok, effects} = AtMcp.Test.QuotaFixture.start_effects(backend: AtMcp.Test.MockBackend)
    state = %{effects: effects}
    assert {:ok, _} = AtMcp.Effects.login(effects)

    {:ok, plain, ^state} = AtMcp.MCP.Server.handle_call_tool("get_timeline", %{}, state)

    refute Map.has_key?(plain, :structuredContent),
           "get_timeline returned structured content unasked"

    {:ok, json, ^state} =
      AtMcp.MCP.Server.handle_call_tool("get_timeline", %{"format" => "json"}, state)

    assert json.structuredContent
  end

  # A host confirms which account a connection acts as from identity_status's
  # structured content, as it did in 0.2, so the status tools keep it, with
  # their JSON as the text, whatever format says.
  test "the status tools always return their structured content, with its JSON as the text",
       %{tools: tools} do
    {:ok, effects} = AtMcp.Test.QuotaFixture.start_effects(backend: AtMcp.Test.MockBackend)
    state = %{effects: effects}
    assert {:ok, _} = AtMcp.Effects.login(effects)

    for name <- AtMcp.MCP.DSL.status() do
      tool = Enum.find(tools, &(&1.name == name))
      assert tool.annotations[:readOnlyHint] == true
      assert tool.inputSchema.properties[:format] || tool.inputSchema.properties["format"]

      for arguments <- [%{}, %{"format" => "text"}, %{"format" => "json"}] do
        {:ok, result, ^state} = AtMcp.MCP.Server.handle_call_tool(name, arguments, state)
        refute result[:isError], "#{name}: #{inspect(result)}"
        assert is_map(result.structuredContent), "#{name} returned no structured content"
        text = Enum.find(result.content, &(&1.type == "text")).text
        assert Jason.decode!(text) == result.structuredContent, "#{name} text is not its JSON"
      end
    end

    {:ok, status, ^state} = AtMcp.MCP.Server.handle_call_tool("identity_status", %{}, state)
    assert is_binary(status.structuredContent["did"])
  end
end
