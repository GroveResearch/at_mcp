defmodule AtMcp.ReadingTest do
  @moduledoc """
  What a model reads for posts: the result's text content. The structured
  content beside it is for programs and keeps every field.
  """
  use ExUnit.Case, async: false

  alias AtMcp.Summary

  @fixture Path.expand("../fixtures/fieldnote-post.json", __DIR__)

  setup do
    old = Application.get_env(:at_mcp, :network)
    Application.put_env(:at_mcp, :network, :delve)

    on_exit(fn ->
      if old,
        do: Application.put_env(:at_mcp, :network, old),
        else: Application.delete_env(:at_mcp, :network)
    end)

    %{post: Jason.decode!(File.read!(@fixture))}
  end

  defp read(result) do
    assert {:ok, %{content: [%{type: "text", text: text}], structuredContent: data}, :state} =
             result

    {text, data}
  end

  test "a post reads as who wrote it, when, what it answers, what it says, and how to act on it",
       %{post: post} do
    page = %{count: 1, items: [Summary.extract(:post, post)], cursor: "c2"}
    {text, data} = read(AtMcp.MCP.Tools.respond({:ok, page}, :state, :posts))

    assert text =~ "Fieldnote · AI (@fieldnote.delve.town)"
    assert text =~ post["record"]["createdAt"]
    assert text =~ "replying to #{post["record"]["reply"]["parent"]["uri"]}"
    # The link the author shortened is read at its full destination.
    assert text =~ "<https://delve.town/profile/fieldnote.delve.town/post/3mwsmr4x3nk2m>"
    assert text =~ "[quoting @fieldnote.delve.town, #{post["embed"]["record"]["uri"]}:"
    # `reply` takes the uri; `like` and `repost` take the uri and the cid.
    assert text =~ "uri: #{post["uri"]}"
    assert text =~ "cid: #{post["cid"]}"
    assert text =~ "pass cursor: c2"

    refute text =~ "null"
    refute text =~ "author_did"
    refute text =~ ~s("raw_text")

    # A program still gets every field, as the output schema declares them.
    [item] = data["items"]
    assert item["raw_text"] == post["record"]["text"]
    assert item["author_did"] == post["author"]["did"]
    assert item["created_at"] == post["record"]["createdAt"]
    assert item["reply_to"] == post["record"]["reply"]["parent"]["uri"]
    assert Map.has_key?(item, "web_url") and Map.has_key?(item, "facets")
  end

  test "a reply notification reads as the reply; a like is one line naming the post it is about",
       %{post: post} do
    reply =
      post
      |> Map.merge(%{"reason" => "reply", "isRead" => false, "indexedAt" => post["indexedAt"]})
      |> Map.put("reasonSubject", post["record"]["reply"]["parent"]["uri"])

    like = %{
      "reason" => "like",
      "uri" => "at://did:plc:liker/app.bsky.feed.like/1",
      "cid" => "bafylike",
      "author" => %{"handle" => "liker.test", "did" => "did:plc:liker"},
      "reasonSubject" => "at://did:plc:self/app.bsky.feed.post/mine",
      "record" => %{"subject" => %{"uri" => "at://did:plc:self/app.bsky.feed.post/mine"}},
      "isRead" => true,
      "indexedAt" => "2026-10-01T00:00:00.000Z"
    }

    page = %{
      count: 2,
      items: [Summary.extract(:notification, reply), Summary.extract(:notification, like)],
      cursor: nil
    }

    {text, data} = read(AtMcp.MCP.Tools.respond({:ok, page}, :state, :notifications))
    [first, second] = String.split(text, "\n\n[2] ")

    assert first =~ "[1] reply from @fieldnote.delve.town · #{post["indexedAt"]} · unread"
    assert first =~ "replying to #{post["record"]["reply"]["parent"]["uri"]}"
    assert first =~ "uri: #{post["uri"]} · cid: #{post["cid"]}"

    assert second ==
             "like from @liker.test · 2026-10-01T00:00:00.000Z · on at://did:plc:self/app.bsky.feed.post/mine"

    refute text =~ "null"
    assert Enum.map(data["items"], & &1["uri"]) == [post["uri"], like["uri"]]
  end

  test "get_thread_chain reads as a conversation, not as JSON" do
    {:ok, effects} =
      AtMcp.Test.QuotaFixture.start_effects(backend: AtMcp.Test.MockBackend, quota_limit: 10)

    assert {:ok, _} = AtMcp.Effects.login(effects)
    state = %{effects: effects}
    uri = "at://did:plc:mock/app.bsky.feed.post/2"

    assert {:ok, %{content: [%{text: text}], structuredContent: data}, ^state} =
             AtMcp.MCP.Server.handle_call_tool("get_thread_chain", %{"uri" => uri}, state)

    assert text =~ "A conversation of 2 posts, oldest first."
    assert text =~ "[1] Alice (@alice.bsky.social) · 2026-09-15T00:00:00.000Z\nthe first post"

    assert text =~
             "[2] Alice (@alice.bsky.social) · 2026-09-15T00:01:00.000Z · replying to at://did:plc:mock/app.bsky.feed.post/root"

    assert text =~ "uri: #{uri} · cid: bafyTHREADCID"
    refute text =~ "null"
    refute text =~ "{"

    assert data["chain_truncated"] == false
    assert Enum.map(data["chain"], & &1["author_did"]) == ["did:plc:alice", "did:plc:alice"]
  end

  test "a chain cut short says how to read further up" do
    chain = %{
      "chain" => [%{"uri" => "at://a/p/1", "unresolved" => true}, %{"uri" => "at://a/p/2"}],
      "chain_truncated" => true,
      "chain_omitted" => 3,
      "chain_before" => "at://a/p/0",
      "replies" => [],
      "replies_omitted" => 0
    }

    text = AtMcp.Reading.chain(chain)
    assert text =~ "3 earlier posts are not shown."
    assert text =~ "call get_thread_chain again with before: at://a/p/0"
    assert text =~ "[1] The post at://a/p/1 was not read."
  end
end
