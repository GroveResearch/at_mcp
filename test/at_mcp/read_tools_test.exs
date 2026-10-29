defmodule AtMcp.ReadToolsTest do
  @moduledoc """
  A read is a tool whose published `readOnlyHint` is true, and nothing else
  (#202). `tools/list` gives each one a `format` argument and no output
  schema, because MCP requires a tool with a declared schema to return
  structured content and a read returns text unless asked for json; every
  other tool declares its schema. Asynchronous, so the fast checks a pull
  request runs catch a read that slipped through, as #210's merge queue did.
  """
  use ExUnit.Case, async: true

  setup_all do
    {:ok, tools, nil, :state} = AtMcp.MCP.Server.handle_list_tools(nil, :state)
    %{tools: tools}
  end

  defp read?(tool), do: (tool[:annotations] || %{})[:readOnlyHint] == true

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

  test "every other tool declares its output schema and takes no format", %{tools: tools} do
    for tool <- Enum.reject(tools, &read?/1) do
      assert tool.outputSchema["type"] == "object" or tool.outputSchema[:type] == "object",
             "#{tool.name} is not a read and declares no output schema"

      refute tool.inputSchema.properties[:format] || tool.inputSchema.properties["format"],
             "#{tool.name} is not a read and takes format"
    end
  end

  test "a read answers in text alone unless asked for json" do
    {:ok, effects} = AtMcp.Test.QuotaFixture.start_effects(backend: AtMcp.Test.MockBackend)
    state = %{effects: effects}

    {:ok, plain, ^state} = AtMcp.MCP.Server.handle_call_tool("identity_status", %{}, state)

    refute Map.has_key?(plain, :structuredContent),
           "identity_status returned structured content unasked"

    {:ok, json, ^state} =
      AtMcp.MCP.Server.handle_call_tool("identity_status", %{"format" => "json"}, state)

    assert json.structuredContent
  end
end
