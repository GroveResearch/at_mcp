defmodule AtMcp.FeedContextTest do
  @moduledoc """
  What a feed says about a post beside the post: why it is in the feed (a
  repost or a pin) and who a reply answers, read through the backend's feed
  read as a model and a program receive them.

  test/fixtures/appview-feed-items.json is eight items of a recorded public
  `getAuthorFeed` response, with identities, text and URLs replaced and keys
  and value types kept. Avatars, verification, link-card sources and the
  embeds of reply parents are trimmed. The recording has no pin and no deleted
  or blocked parent, so those cases change a recorded item as the lexicon
  defines them.
  """
  use ExUnit.Case, async: false

  alias AtMcp.Effects.ProtoRune, as: Backend

  @fixture Path.expand("../fixtures/appview-feed-items.json", __DIR__)

  defmodule HTTP do
    def request(:get, _url, _opts) do
      feed = Application.fetch_env!(:at_mcp, :feed_context_test_feed)
      {:ok, %{status: 200, headers: [], body: Jason.encode!(%{"feed" => feed})}}
    end
  end

  setup do
    previous = Application.get_env(:proto_rune, :http_client)
    network = Application.get_env(:at_mcp, :network)
    Application.put_env(:proto_rune, :http_client, HTTP)
    Application.put_env(:at_mcp, :network, :bluesky)

    on_exit(fn ->
      restore(:proto_rune, :http_client, previous)
      restore(:at_mcp, :network, network)
      Application.delete_env(:at_mcp, :feed_context_test_feed)
    end)

    %{feed: @fixture |> File.read!() |> Jason.decode!() |> Map.fetch!("feed")}
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)

  # The feed read as the tool returns it: the text a model reads and the
  # structured content a program reads, checked against the tool's schema.
  defp read(items) do
    Application.put_env(:at_mcp, :feed_context_test_feed, items)
    {:ok, page} = Backend.get_author_feed(session(), "account1.example.test", [])

    assert {:ok, %{content: [%{type: "text", text: text}], structuredContent: data}, :state} =
             AtMcp.MCP.Tools.respond({:ok, page}, :state, :posts)

    schema = AtMcp.MCP.Server.__output_schemas__()["get_author_feed"]
    assert AtMcp.Test.Schema.valid?(data, schema)

    {text, data["items"]}
  end

  defp reposted(feed), do: Enum.find(feed, &match?(%{"reason" => _}, &1))

  defp reply_by(feed, parent),
    do: Enum.find(feed, &(&1["reply"]["parent"]["author"]["handle"] == parent))

  test "a repost says who reposted it and when, above the original author's post", %{feed: feed} do
    item = reposted(feed)
    by = item["reason"]["by"]
    {text, [summary]} = read([item])

    assert summary["reason"] == %{
             "type" => "repost",
             "by" => by["handle"],
             "by_did" => by["did"],
             "by_display_name" => by["displayName"],
             "at" => item["reason"]["indexedAt"],
             "uri" => item["reason"]["uri"]
           }

    # The post is still the original author's.
    assert summary["author"] == item["post"]["author"]["handle"]

    assert text =~
             "[1] Reposted by \"#{by["displayName"]}\" (@#{by["handle"]}) · #{item["reason"]["indexedAt"]}\n" <>
               "\"#{item["post"]["author"]["displayName"]}\" (@#{item["post"]["author"]["handle"]}) · " <>
               item["post"]["indexedAt"] <> "\n"
  end

  test "a pinned post says so above it", %{feed: feed} do
    item = feed |> reposted() |> Map.put("reason", %{"$type" => "app.bsky.feed.defs#reasonPin"})
    {text, [summary]} = read([item])

    assert summary["reason"]["type"] == "pin"

    assert text =~
             ~r/\A1 post\.\n\n\[1\] Pinned\n[^\n]+ · #{item["post"]["indexedAt"]}\n/
  end

  test "a reply says whose post it answers, and whose thread when the root is someone else's",
       %{feed: feed} do
    # Recorded: a reply to account24, in a thread account1 started.
    item = reply_by(feed, "account24.example.test")
    parent = item["reply"]["parent"]
    root = item["reply"]["root"]
    assert root["author"]["did"] != parent["author"]["did"]

    {text, [summary]} = read([item])

    assert summary["reply_parent"] == %{
             "status" => "available",
             "uri" => parent["uri"],
             "web_url" => AtMcp.WebLink.record(parent["uri"], parent["author"]["handle"]),
             "author" => parent["author"]["handle"],
             "author_did" => parent["author"]["did"],
             "display_name" => parent["author"]["displayName"]
           }

    assert summary["reply_root"]["author_did"] == root["author"]["did"]

    assert text =~
             " · replying to @account24.example.test (#{parent["uri"]}) in a thread by @#{root["author"]["handle"]}\n"

    # A reply in a thread its parent's author started names the parent only.
    item = reply_by(feed, "account14.example.test")
    {text, _} = read([item])

    assert text =~
             " · replying to @account14.example.test (#{item["reply"]["parent"]["uri"]})\n"
  end

  test "a reason or parent view this version does not know is said as such", %{feed: feed} do
    item =
      feed
      |> reposted()
      |> Map.put("reason", %{"$type" => "app.bsky.feed.defs#reasonSomethingNew"})

    {text, [summary]} = read([item])

    assert summary["reason"] ==
             %{"type" => "app.bsky.feed.defs#reasonSomethingNew"}
             |> Map.merge(Map.new(~w(by by_did by_display_name at uri), &{&1, nil}))

    assert text =~ "[1] In this feed because: app.bsky.feed.defs#reasonSomethingNew\n"

    item = reply_by(feed, "account14.example.test")
    uri = item["reply"]["parent"]["uri"]

    unknown =
      put_in(item, ["reply", "parent"], %{
        "$type" => "app.bsky.feed.defs#somethingNewPost",
        "uri" => uri,
        "author" => %{"did" => "did:plc:x", "handle" => "x.test"}
      })

    {text, [summary]} = read([unknown])
    assert summary["reply_parent"]["status"] == "unsupported"
    # Whose post it was is unknown; whose thread it is in is still said.
    assert text =~ " · replying to #{uri} in a thread by @account14.example.test\n"
  end

  test "a reply to a deleted or blocked post says that, with the uri it answers", %{feed: feed} do
    item = reply_by(feed, "account14.example.test")
    uri = item["reply"]["parent"]["uri"]

    deleted =
      put_in(item, ["reply", "parent"], %{
        "$type" => "app.bsky.feed.defs#notFoundPost",
        "uri" => uri,
        "notFound" => true
      })

    {text, [summary]} = read([deleted])
    assert summary["reply_parent"]["status"] == "not_found"
    assert text =~ " · replying to a deleted or missing post (#{uri})"

    blocked =
      put_in(item, ["reply", "parent"], %{
        "$type" => "app.bsky.feed.defs#blockedPost",
        "uri" => uri,
        "blocked" => true,
        "author" => %{"did" => "did:plc:blocked"}
      })

    {text, [summary]} = read([blocked])
    assert summary["reply_parent"]["status"] == "blocked"
    assert summary["reply_parent"]["author_did"] == "did:plc:blocked"
    assert text =~ " · replying to a post hidden by a block (#{uri})"
  end

  # Nothing is said that the feed did not say: a feed item without a reason or
  # reply context reads exactly as the post does on its own.
  test "a feed item with no reason or reply context reads as the bare post", %{feed: feed} do
    for item <- feed do
      bare = Map.drop(item, ["reason", "reply"])
      {in_feed, [summary]} = read([bare])
      {alone, _} = read([item["post"]])

      assert in_feed == alone

      assert {summary["reason"], summary["reply_parent"], summary["reply_root"]} ==
               {nil, nil, nil}
    end
  end

  defp session,
    do: %ProtoRune.Atproto.Session{
      did: "did:plc:reader",
      handle: "reader.test",
      access_jwt: "reader",
      refresh_jwt: "unused",
      service_url: "https://pds.invalid/xrpc"
    }
end
