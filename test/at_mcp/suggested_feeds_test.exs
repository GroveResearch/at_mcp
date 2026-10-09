defmodule AtMcp.SuggestedFeedsTest do
  @moduledoc """
  `get_suggested_feeds` is how a caller finds a custom feed without already
  holding its generator URI. The items are generators, not posts; each `uri`
  is what `get_feed` takes.
  """
  use ExUnit.Case, async: true

  alias AtMcp.Test.Schema

  test "a generator view is summarized with the uri get_feed takes" do
    summary =
      AtMcp.Summary.extract(:generator, %{
        "uri" => "at://did:plc:author/app.bsky.feed.generator/hot",
        "cid" => "bafygen",
        "did" => "did:web:feeds.example",
        "displayName" => "What's hot",
        "description" => "posts the service currently surfaces",
        "creator" => %{"handle" => "author.test", "did" => "did:plc:author"},
        "likeCount" => 12,
        "indexedAt" => "2026-09-13T12:34:56.123Z",
        "viewer" => %{"like" => "at://did:plc:viewer/app.bsky.feed.like/1"}
      })

    assert summary.uri == "at://did:plc:author/app.bsky.feed.generator/hot"
    assert summary.display_name == "What's hot"
    assert summary.creator == "author.test"
    assert summary.creator_did == "did:plc:author"
    assert summary.like_count == 12
    assert summary.viewer.like == "at://did:plc:viewer/app.bsky.feed.like/1"
  end

  test "the tool is a read: a read grant reaches it, and it spends no write quota" do
    {:ok, tools, nil, :state} = AtMcp.MCP.Server.handle_list_tools(nil, :state)
    tool = Enum.find(tools, &(&1.name == "get_suggested_feeds"))
    assert tool
    assert tool.annotations[:readOnlyHint] == true
    assert AtMcp.Grants.permits_scope?(:read, "get_suggested_feeds")
    refute AtMcp.Effects.counts_against_quota?(:get_suggested_feeds)
  end

  test "the MCP tool returns a page of generators its schema accepts" do
    {:ok, effects} = AtMcp.Test.QuotaFixture.start_effects(backend: AtMcp.Test.MockBackend)
    assert {:ok, _} = AtMcp.Effects.login(effects)
    state = %{effects: effects}

    {:ok, tools, nil, ^state} = AtMcp.MCP.Server.handle_list_tools(nil, state)
    schema = Enum.find(tools, &(&1.name == "get_suggested_feeds")).outputSchema

    assert {:ok, result, ^state} =
             AtMcp.MCP.Server.handle_call_tool("get_suggested_feeds", %{}, state)

    refute result[:isError]
    page = result.structuredContent
    assert Schema.valid?(page, schema)
    assert page["count"] == 1
    [item] = page["items"]
    assert item["uri"] =~ "feed.generator"
    assert item["creator_did"]
    assert item["display_name"]
  end
end
