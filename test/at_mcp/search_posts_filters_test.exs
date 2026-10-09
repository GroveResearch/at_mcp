defmodule AtMcp.SearchPostsFiltersTest do
  @moduledoc """
  `search_posts` narrows by the search method's own parameters. A filter that
  is omitted or empty is not sent; a sort other than latest or top is refused
  before a session is taken.
  """
  use ExUnit.Case, async: true

  test "author, mentions, sort, since, until and lang reach the mock backend" do
    {:ok, effects} = AtMcp.Test.QuotaFixture.start_effects(backend: AtMcp.Test.MockBackend)
    assert {:ok, _} = AtMcp.Effects.login(effects)

    assert {:ok, page} =
             AtMcp.Effects.search_posts(effects, "at_mcp",
               author: "writer.example",
               mentions: "reader.example",
               sort: "latest",
               since: "2026-09-01T00:00:00Z",
               until: "2026-10-01T00:00:00Z",
               lang: "en"
             )

    assert page.query == "at_mcp"
    assert page.author == "writer.example"
    assert page.mentions == "reader.example"
    assert page.sort == "latest"
    assert page.since == "2026-09-01T00:00:00Z"
    assert page.until == "2026-10-01T00:00:00Z"
    assert page.lang == "en"
  end

  test "empty optional filters are omitted rather than sent as empty strings" do
    {:ok, effects} = AtMcp.Test.QuotaFixture.start_effects(backend: AtMcp.Test.MockBackend)
    assert {:ok, _} = AtMcp.Effects.login(effects)

    assert {:ok, page} =
             AtMcp.Effects.search_posts(effects, "at_mcp", author: "", sort: "  ", lang: nil)

    assert page.query == "at_mcp"
    assert page.author == nil
    assert page.sort == nil
    assert page.lang == nil
  end

  test "a sort that is not latest or top is refused before the backend is called" do
    {:ok, effects} = AtMcp.Test.QuotaFixture.start_effects(backend: AtMcp.Test.MockBackend)
    assert {:ok, _} = AtMcp.Effects.login(effects)

    assert {:error, :invalid_search_sort} =
             AtMcp.Effects.search_posts(effects, "at_mcp", sort: "popular")

    state = %{effects: effects}

    assert {:ok, %{isError: true, structuredContent: %{code: code}}, ^state} =
             AtMcp.MCP.Server.handle_call_tool(
               "search_posts",
               %{"query" => "at_mcp", "sort" => "popular"},
               state
             )

    # The declared enum refuses it as invalid_arguments; Effects still
    # classifies a bad sort if a caller bypasses the tool schema.
    assert code in ["invalid_arguments", "invalid_search_sort"]
  end

  test "the MCP tool strips a leading @ from author and mentions" do
    {:ok, effects} = AtMcp.Test.QuotaFixture.start_effects(backend: AtMcp.Test.MockBackend)
    assert {:ok, _} = AtMcp.Effects.login(effects)
    state = %{effects: effects}

    assert {:ok, result, ^state} =
             AtMcp.MCP.Server.handle_call_tool(
               "search_posts",
               %{
                 "query" => "at_mcp",
                 "author" => "@writer.example",
                 "mentions" => "@reader.example",
                 "sort" => "top"
               },
               state
             )

    refute result[:isError]
    assert result.structuredContent["author"] == "writer.example"
    assert result.structuredContent["mentions"] == "reader.example"
    assert result.structuredContent["sort"] == "top"
  end

  test "search_posts still requires only query" do
    {:ok, tools, nil, :state} = AtMcp.MCP.Server.handle_list_tools(nil, :state)
    tool = Enum.find(tools, &(&1.name == "search_posts"))
    required = Enum.map(tool.inputSchema[:required] || [], &to_string/1)
    assert required == ["query"]

    for arg <- ["author", "mentions", "sort", "since", "until", "lang"] do
      assert Map.has_key?(tool.inputSchema[:properties], String.to_atom(arg)) or
               Map.has_key?(tool.inputSchema[:properties], arg),
             "#{arg} is not declared"
    end
  end
end
