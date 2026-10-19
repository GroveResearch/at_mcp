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

    assert text =~ "Example Notes · AI (@fieldnote.example.test)"
    assert text =~ post["record"]["createdAt"]
    assert text =~ "replying to #{post["record"]["reply"]["parent"]["uri"]}"
    # The link the author shortened is read at its full destination.
    assert text =~ "<https://delve.town/profile/fieldnote.example.test/post/3kfixtureqo2a>"

    assert text =~
             "[quoting Example Notes · AI (@fieldnote.example.test), #{post["embed"]["record"]["uri"]}:"

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

  test "a post's counts and labels read as one short line each, labels by value",
       %{post: post} do
    did = post["author"]["did"]

    post =
      post
      |> Map.merge(%{"likeCount" => 12, "repostCount" => 1, "replyCount" => 5, "quoteCount" => 0})
      |> Map.put("labels", [%{"src" => "did:plc:labeler", "val" => "graphic-media"}])
      |> put_in(["author", "labels"], [%{"src" => did, "val" => "bot"}])

    page = %{count: 1, items: [Summary.extract(:post, post)], cursor: nil}
    {text, data} = read(AtMcp.MCP.Tools.respond({:ok, page}, :state, :posts))

    # A program reads the same values, as the output schema declares them.
    [item] = data["items"]
    assert {item["like_count"], item["quote_count"]} == {12, 0}
    # A label carries only the keys the service sent: no null neg or exp.
    assert [%{"val" => "bot", "src" => ^did} = label] = item["author_labels"]
    assert Map.keys(label) |> Enum.sort() == ["src", "val"]
    {:ok, tools, nil, :state} = AtMcp.MCP.Server.handle_list_tools(nil, :state)
    schema = Enum.find(tools, &(&1.name == "get_posts")).outputSchema
    assert AtMcp.Test.Schema.valid?(data, schema)
    assert schema["properties"]["items"]["items"]["properties"]["author_labels"]

    assert text =~
             "\n12 likes · 1 repost · 5 replies\n" <>
               "Labels: graphic-media; author: bot (self)\n" <>
               "uri: #{post["uri"]}"
  end

  test "a post nobody engaged with has no counts line; labels that say nothing are left out",
       %{post: post} do
    did = post["author"]["did"]
    zeros = %{"likeCount" => 0, "repostCount" => 0, "replyCount" => 0, "quoteCount" => 0}

    read = fn post ->
      page = %{count: 1, items: [Summary.extract(:post, post)], cursor: nil}
      {text, data} = read(AtMcp.MCP.Tools.respond({:ok, page}, :state, :posts))
      {text, hd(data["items"])}
    end

    {text, item} = read.(Map.merge(post, zeros))
    assert text == elem(read.(Map.drop(post, Map.keys(zeros))), 0)
    assert {item["like_count"], item["reply_count"]} == {0, 0}

    labels = [
      # The same value from a labeler and from the author: once, as the author's.
      %{"src" => "did:plc:labeler", "val" => "bot"},
      %{"src" => did, "val" => "bot"},
      %{"src" => "did:plc:labeler", "val" => "spam", "exp" => "2020-01-01T00:00:00Z"},
      %{"src" => "did:plc:labeler", "val" => "rude", "exp" => "2999-01-01T00:00:00Z"},
      %{"src" => "did:plc:labeler", "val" => "nudity"},
      %{"src" => "did:plc:labeler", "val" => "nudity", "neg" => true},
      %{"src" => did, "val" => "!no-unauthenticated"}
    ]

    {text, item} = read.(post |> Map.merge(zeros) |> put_in(["author", "labels"], labels))
    assert text =~ "\nLabels: author: bot (self), rude\nuri: "
    refute text =~ ~r/spam|nudity|no-unauthenticated|likes/
    # The structured content keeps every label the service sent.
    assert length(item["author_labels"]) == length(labels)
    assert %{"exp" => "2020-01-01T00:00:00Z"} = Enum.at(item["author_labels"], 2)
  end

  # A response without counts or labels — a placeholder, an older service —
  # reads exactly as it did before they were read at all.
  test "a post the service sent without counts or labels reads as before" do
    post = %{
      "uri" => "at://did:plc:a/app.bsky.feed.post/1",
      "cid" => "bafy1",
      "author" => %{"handle" => "a.test", "did" => "did:plc:a"},
      "record" => %{"text" => "hello", "createdAt" => "2026-10-01T00:00:00.000Z"}
    }

    assert AtMcp.Reading.posts(%{
             "items" => [post |> then(&Summary.extract(:post, &1)) |> json()]
           }) ==
             "1 post.\n\n[1] @a.test · 2026-10-01T00:00:00.000Z\nhello\n" <>
               "uri: at://did:plc:a/app.bsky.feed.post/1 · cid: bafy1"

    # An empty label list is no labels, not a heading with nothing under it.
    labelled = post |> Map.put("labels", []) |> put_in(["author", "labels"], [])

    refute AtMcp.Reading.posts(%{
             "items" => [labelled |> then(&Summary.extract(:post, &1)) |> json()]
           }) =~ "labels"
  end

  test "a block or mute with the author is said in words; following is not" do
    post = %{
      "uri" => "at://did:plc:a/app.bsky.feed.post/1",
      "cid" => "bafy1",
      "author" => %{
        "handle" => "a.test",
        "did" => "did:plc:a",
        "viewer" => %{"blockedBy" => true, "muted" => true, "following" => nil}
      },
      "record" => %{"text" => "hello", "createdAt" => "2026-10-01T00:00:00.000Z"},
      "viewer" => %{"replyDisabled" => true, "embeddingDisabled" => true}
    }

    read = fn post ->
      AtMcp.Reading.posts(%{"items" => [post |> then(&Summary.extract(:post, &1)) |> json()]})
    end

    assert read.(post) ==
             "1 post.\n\n[1] @a.test · 2026-10-01T00:00:00.000Z\nhello\n" <>
               "They blocked you · You muted them · You cannot reply to this post · You cannot quote this post\n" <>
               "uri: at://did:plc:a/app.bsky.feed.post/1 · cid: bafy1"

    blocking =
      put_in(post, ["author", "viewer"], %{"blocking" => "at://did:plc:me/app.bsky.graph.block/1"})

    assert read.(blocking) =~
             "\nYou blocked them · You cannot reply to this post · You cannot quote this post\n"

    # The ordinary case reads exactly as a post with no viewer state at all.
    ordinary =
      post
      |> put_in(["author", "viewer"], %{
        "following" => "at://did:plc:me/app.bsky.graph.follow/1",
        "followedBy" => "at://did:plc:a/app.bsky.graph.follow/2",
        "blockedBy" => false,
        "muted" => false
      })
      |> Map.put("viewer", %{
        "replyDisabled" => false,
        "embeddingDisabled" => false,
        "threadMuted" => false
      })

    assert read.(ordinary) ==
             read.(
               post
               |> Map.delete("viewer")
               |> Map.update!("author", &Map.delete(&1, "viewer"))
             )
  end

  defp json(summary), do: summary |> Jason.encode!() |> Jason.decode!()

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

    # A notification names its author as a post does.
    assert first =~
             "[1] reply from Example Notes · AI (@fieldnote.example.test) · #{post["indexedAt"]} · unread"

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

  # One post, as the AppView sends it wherever it appears: by a verified
  # account that is live, labelled, gated, from an author this account muted.
  # Built when a test runs, in the types of the network it sets.
  defp shown,
    do: %{
      "uri" => "at://did:plc:a/app.bsky.feed.post/1",
      "cid" => "bafy1",
      "author" => %{
        "handle" => "a.test",
        "did" => "did:plc:a",
        "displayName" => "Ada",
        "labels" => [%{"src" => "did:plc:a", "val" => "bot"}],
        "viewer" => %{"muted" => true},
        "verification" => %{"verifiedStatus" => "valid", "trustedVerifierStatus" => "none"},
        "status" => %{
          "status" => "app.bsky.actor.status#live",
          "isActive" => true,
          "embed" => %{"external" => %{"uri" => "https://stream.example/a", "title" => "On air"}}
        }
      },
      "labels" => [%{"src" => "did:plc:labeler", "val" => "graphic-media"}],
      "record" => %{"text" => "hello", "createdAt" => "2026-10-01T00:00:00.000Z"},
      "viewer" => %{"replyDisabled" => true},
      "threadgate" => %{
        "record" => %{
          "allow" => [
            %{"$type" => AtMcp.Network.type(:mention_rule)},
            %{
              "$type" => AtMcp.Network.type(:list_rule),
              "list" => "at://did:plc:a/app.bsky.graph.list/f"
            }
          ]
        },
        "lists" => [%{"uri" => "at://did:plc:a/app.bsky.graph.list/f", "name" => "Friends"}]
      }
    }

  test "a post says what the app shows beside the author's name, and who may reply" do
    text = AtMcp.Reading.posts(%{"items" => [json(Summary.extract(:post, shown()))]})

    assert text ==
             "1 post.\n\n[1] Ada (@a.test, verified, live) · 2026-10-01T00:00:00.000Z\nhello\n" <>
               "Labels: graphic-media; author: bot (self)\n" <>
               "You muted them · You cannot reply to this post\n" <>
               ~s(Who can reply: people mentioned, members of "Friends" at://did:plc:a/app.bsky.graph.list/f\n) <>
               "uri: at://did:plc:a/app.bsky.feed.post/1 · cid: bafy1"

    # Everyone may reply: no line, as for a post with no gate on it.
    open = put_in(shown(), ["threadgate", "record"], %{})
    refute AtMcp.Reading.posts(%{"items" => [json(Summary.extract(:post, open))]}) =~ "Who can"

    nobody = put_in(shown(), ["threadgate", "record", "allow"], [])

    assert AtMcp.Reading.posts(%{"items" => [json(Summary.extract(:post, nobody))]}) =~
             "\nWho can reply: nobody\n"
  end

  # The same post reads with the same facts in the same words whichever read
  # shows it: a page of posts, a conversation, a notification, or a quote.
  test "a post reads the same in a feed, a chain, a notification and a quote" do
    name = "Ada (@a.test, verified, live)"
    labels = "Labels: graphic-media; author: bot (self)"

    feed = AtMcp.Reading.posts(%{"items" => [json(Summary.extract(:post, shown()))]})

    chain =
      AtMcp.Reading.chain(%{
        "chain" => [json(Summary.extract(:chain_post, shown()))],
        "replies" => []
      })

    notification =
      AtMcp.Reading.notifications(%{
        "items" => [
          json(
            Summary.extract(
              :notification,
              Map.merge(shown(), %{"reason" => "mention", "indexedAt" => "2026-10-01T00:00:01Z"})
            )
          )
        ]
      })

    quoting =
      %{
        "uri" => "at://did:plc:b/app.bsky.feed.post/2",
        "author" => %{"handle" => "b.test", "did" => "did:plc:b"},
        "record" => %{"text" => "look", "createdAt" => "2026-10-01T00:00:02.000Z"},
        "embed" => %{
          "$type" => AtMcp.Network.type(:embed_record) <> "#view",
          "record" =>
            Map.merge(shown(), %{
              "$type" => AtMcp.Network.type(:embed_record) <> "#viewRecord",
              "value" => Map.put(shown()["record"], "$type", AtMcp.Network.collection(:post))
            })
        }
      }

    quote = AtMcp.Reading.posts(%{"items" => [json(Summary.extract(:post, quoting))]})

    for text <- [feed, chain, notification] do
      assert text =~ name
      assert text =~ "\n" <> labels <> "\n"
      assert text =~ "You muted them"
    end

    # The chain carries the post's own viewer, as get_posts does.
    assert chain =~ "You muted them · You cannot reply to this post"

    assert quote =~
             "[quoting #{name}, at://did:plc:a/app.bsky.feed.post/1: hello · #{labels} · You muted them]"
  end

  test "a notification names its author as a post does, and a follow says what is known of who it is from" do
    follow = %{
      "reason" => "starterpack-joined",
      "uri" => "at://did:plc:a/app.bsky.graph.follow/1",
      "author" => shown()["author"],
      "reasonSubject" => "at://did:plc:me/app.bsky.graph.starterpack/p",
      "starterPack" => %{
        "uri" => "at://did:plc:me/app.bsky.graph.starterpack/p",
        "record" => %{"name" => "Agents"}
      },
      "record" => %{},
      "isRead" => true,
      "indexedAt" => "2026-10-01T00:00:00.000Z"
    }

    assert AtMcp.Reading.notifications(%{
             "items" => [json(Summary.extract(:notification, follow))]
           }) ==
             "1 notification.\n\n[1] starterpack-joined from Ada (@a.test, verified, live) · " <>
               "2026-10-01T00:00:00.000Z · on at://did:plc:me/app.bsky.graph.starterpack/p · " <>
               ~s(through the starter pack "Agents" at://did:plc:me/app.bsky.graph.starterpack/p · ) <>
               "Labels: author: bot (self) · You muted them"
  end

  @profile %{
    "did" => "did:plc:a",
    "handle" => "a.test",
    "displayName" => "Ada",
    "pronouns" => "she/her",
    "description" => "Writes about kites.\nAnd wind.",
    "website" => "https://a.example",
    "links" => [%{"url" => "https://a.example/blog", "title" => "Blog"}],
    "followersCount" => 10,
    "followsCount" => 1,
    "postsCount" => 0,
    "createdAt" => "2024-01-02T03:04:05.000Z",
    "associated" => %{"lists" => 2, "feedgens" => 0, "starterPacks" => 1, "labeler" => true},
    "pinnedPost" => %{"uri" => "at://did:plc:a/app.bsky.feed.post/1", "cid" => "bafy1"},
    "verification" => %{
      "verifiedStatus" => "valid",
      "trustedVerifierStatus" => "valid",
      "verifications" => [
        %{"issuer" => "did:plc:v", "issuerHandle" => "v.test", "isValid" => true}
      ]
    },
    "status" => %{
      "status" => "app.bsky.actor.status#live",
      "isActive" => true,
      "expiresAt" => "2026-10-01T01:00:00.000Z",
      "embed" => %{"external" => %{"uri" => "https://stream.example/a", "title" => "On air"}}
    },
    "labels" => [%{"src" => "did:plc:a", "val" => "bot"}],
    "joinedViaStarterPack" => %{
      "uri" => "at://did:plc:k/app.bsky.graph.starterpack/p",
      "record" => %{"name" => "Agents"},
      "creator" => %{"handle" => "k.test"}
    },
    "viewer" => %{
      "followedBy" => "at://did:plc:a/app.bsky.graph.follow/1",
      "knownFollowers" => %{
        "count" => 4,
        "followers" => [%{"did" => "did:plc:k", "handle" => "k.test", "displayName" => "Kit"}]
      }
    }
  }

  test "a profile reads as the app's profile page heads it, not as JSON" do
    assert {:ok, %{content: [%{text: text}], structuredContent: data}, :state} =
             AtMcp.MCP.Tools.respond(
               {:ok, Summary.extract(:profile, @profile)},
               :state,
               :profile
             )

    assert text ==
             """
             Profile Ada (@a.test, verified, trusted verifier, live) · she/her · runs a labeler
             Follows you
             Writes about kites.
             And wind.
             10 followers · 1 following · joined 2024-01-02T03:04:05.000Z
             Made: 2 lists · 1 starter pack
             Website: https://a.example
             Links: Blog (https://a.example/blog)
             Pinned post: at://did:plc:a/app.bsky.feed.post/1
             Live: On air https://stream.example/a until 2026-10-01T01:00:00.000Z
             Verified by: @v.test
             Labels: bot (self)
             Followed by Kit (@k.test) and 3 others
             Joined through the starter pack "Agents" by @k.test at://did:plc:k/app.bsky.graph.starterpack/p
             did: did:plc:a\
             """

    assert data["pinned_post"] == "at://did:plc:a/app.bsky.feed.post/1"
    {:ok, tools, nil, :state} = AtMcp.MCP.Server.handle_list_tools(nil, :state)
    schema = Enum.find(tools, &(&1.name == "get_profile")).outputSchema
    assert AtMcp.Test.Schema.valid?(data, schema)
  end

  test "a page of accounts reads each as one short block" do
    page = %{
      count: 2,
      items: [
        Summary.extract(:profile, Map.delete(@profile, "viewer")),
        Summary.extract(:profile, %{"did" => "did:plc:b", "handle" => "b.test"})
      ],
      cursor: "c3"
    }

    {text, _data} = read(AtMcp.MCP.Tools.respond({:ok, page}, :state, :profiles))

    assert text =~ "2 accounts. For the next page, pass cursor: c3"

    assert text =~
             "\n[1] Ada (@a.test, verified, trusted verifier, live) · she/her · runs a labeler\n"

    # A page's description is on one line, as the app's account lists show it.
    assert text =~ "\nWrites about kites. And wind.\n"
    assert String.ends_with?(text, "\n\n[2] @b.test\ndid: did:plc:b")
    refute text =~ "null"
  end
end
