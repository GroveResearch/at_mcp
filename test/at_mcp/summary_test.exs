defmodule AtMcp.SummaryTest do
  use ExUnit.Case, async: true

  # Application responses in the shapes the AppView actually sends. These are
  # inputs, not a second copy of the declaration: each assertion compares two
  # things derived from `AtMcp.Summary`, so a field can never be described
  # without being read, or read without being described.
  @responses %{
    membership: %{
      "enabled" => true,
      "membership" => %{
        "did" => "did:plc:member",
        "status" => "active",
        "suspended" => false,
        "revision" => 1,
        "joined" => true
      }
    },
    post: %{
      "uri" => "at://did:plc:author/app.bsky.feed.post/1",
      "cid" => "bafypost",
      "record" => %{
        "text" => "café 日本語 🪁",
        "createdAt" => "2026-09-13T12:30:00.000Z",
        "reply" => %{"parent" => %{"uri" => "at://did:plc:parent/app.bsky.feed.post/p"}}
      },
      "author" => %{
        "handle" => "author.test",
        "did" => "did:plc:author",
        "displayName" => "café 日本語 🪁",
        "labels" => [
          %{"src" => "did:plc:author", "val" => "bot", "cts" => "2026-09-01T00:00:00Z"}
        ],
        "viewer" => %{"muted" => false, "blockedBy" => true}
      },
      "likeCount" => 12,
      "repostCount" => 3,
      "replyCount" => 5,
      "quoteCount" => 1,
      "labels" => [%{"src" => "did:plc:labeler", "val" => "graphic-media"}],
      "embed" => %{
        "$type" => "app.bsky.embed.images#view",
        "images" => [
          %{
            "thumb" => "https://cdn.example/thumb.jpg",
            "fullsize" => "https://cdn.example/full.jpg",
            "alt" => "a at_mcp over the sea",
            "aspectRatio" => %{"width" => 2, "height" => 1}
          }
        ]
      },
      "viewer" => %{"like" => "at://did:plc:viewer/app.bsky.feed.like/1"}
    },
    chain_post: %{
      "uri" => "at://did:plc:author/app.bsky.feed.post/2",
      "cid" => "bafychain",
      "record" => %{
        "text" => "café 日本語 🪁",
        "createdAt" => "2026-09-13T12:30:00.000Z",
        "reply" => %{
          "parent" => %{"uri" => "at://did:plc:parent/app.bsky.feed.post/p"},
          "root" => %{"uri" => "at://did:plc:root/app.bsky.feed.post/r"}
        }
      },
      "author" => %{
        "handle" => "author.test",
        "did" => "did:plc:author",
        "displayName" => "café 日本語 🪁",
        "labels" => [],
        "viewer" => %{}
      },
      "likeCount" => 0,
      "repostCount" => 0,
      "replyCount" => 0,
      "quoteCount" => 0,
      "labels" => []
    },
    profile: %{
      "did" => "did:plc:author",
      "handle" => "author.test",
      "displayName" => "café 日本語 🪁",
      "description" => "a profile",
      "followersCount" => 3,
      "followsCount" => 2,
      "postsCount" => 1,
      "labels" => [%{"src" => "did:plc:author", "val" => "bot"}],
      "viewer" => %{"following" => "at://did:plc:viewer/app.bsky.graph.follow/1"}
    },
    generator: %{
      "uri" => "at://did:plc:author/app.bsky.feed.generator/hot",
      "cid" => "bafygen",
      "did" => "did:web:feeds.example",
      "displayName" => "What's hot",
      "description" => "posts the service currently surfaces",
      "creator" => %{"handle" => "author.test", "did" => "did:plc:author"},
      "likeCount" => 12,
      "indexedAt" => "2026-09-13T12:34:56.123Z",
      "viewer" => %{"like" => "at://did:plc:viewer/app.bsky.feed.like/1"}
    },
    relationship: %{
      "did" => "did:plc:other",
      "following" => "at://did:plc:viewer/app.bsky.graph.follow/1",
      "followedBy" => "at://did:plc:other/app.bsky.graph.follow/2",
      "notFound" => false
    },
    notification: %{
      "reason" => "mention",
      "uri" => "at://did:plc:author/app.bsky.feed.post/1",
      "author" => %{"handle" => "author.test", "did" => "did:plc:author"},
      "record" => %{
        "text" => "hello",
        "reply" => %{
          "parent" => %{"uri" => "at://did:plc:parent/app.bsky.feed.post/p"},
          "root" => %{"uri" => "at://did:plc:root/app.bsky.feed.post/r"}
        }
      },
      "cid" => "bafynotification",
      "indexedAt" => "2026-09-13T12:34:56.123Z",
      "reasonSubject" => "at://did:plc:parent/app.bsky.feed.post/p",
      "isRead" => false
    }
  }

  test "notification projection retains indexed time and the addressed thread separately from its URI" do
    item = AtMcp.Summary.extract(:notification, Map.fetch!(@responses, :notification))
    assert item.uri == "at://did:plc:author/app.bsky.feed.post/1"
    assert item.cid == "bafynotification"
    assert item.indexed_at == "2026-09-13T12:34:56.123Z"
    assert item.subject_uri == "at://did:plc:parent/app.bsky.feed.post/p"
    assert item.reply_parent_uri == "at://did:plc:parent/app.bsky.feed.post/p"
    assert item.reply_root_uri == "at://did:plc:root/app.bsky.feed.post/r"
  end

  test "each shape reads exactly the fields it describes" do
    for shape <- AtMcp.Summary.shapes() do
      source = Map.fetch!(@responses, shape)

      source =
        if shape in [:post, :chain_post, :notification] do
          Map.merge(source, %{
            "uri" => "at://author.test/app.bsky.feed.post/1",
            "embed" => %{
              "$type" => "app.bsky.embed.recordWithMedia#view",
              "record" => %{"record" => %{"uri" => "at://author.test/app.bsky.feed.post/q"}},
              "media" => @responses.post["embed"]
            },
            # What a feed item says beside the post, as the feed read passes it.
            "feed_context" =>
              AtMcp.Post.feed_context(%{
                "reason" => %{
                  "$type" => "app.bsky.feed.defs#reasonRepost",
                  "by" => %{"did" => "did:plc:r", "handle" => "r.test", "displayName" => "R"},
                  "uri" => "at://did:plc:r/app.bsky.feed.repost/1",
                  "indexedAt" => "2026-10-01T00:00:00Z"
                },
                "reply" => %{
                  "parent" => @responses.post,
                  "root" => @responses.post
                }
              })
          })
        else
          source
        end

      summary = AtMcp.Summary.extract(shape, source)
      described = AtMcp.Summary.properties(shape) |> Map.keys() |> MapSet.new()
      read = summary |> Map.keys() |> MapSet.new(&to_string/1)

      assert read == described, "#{shape} reads and describes different fields"

      for {key, value} <- Map.delete(summary, :viewer) do
        refute is_nil(value), "#{shape}.#{key} is described but was not read from a full response"
      end
    end
  end

  # The AppView sends these on every post and profile view. Without them an
  # agent counts a post's likes by listing every liker, and cannot tell that an
  # account labels itself a bot.
  test "a post keeps the service's counts and labels, and the author's labels, as sent" do
    post = AtMcp.Summary.extract(:post, @responses.post)

    assert {post.like_count, post.repost_count, post.reply_count, post.quote_count} ==
             {12, 3, 5, 1}

    assert post.labels == [%{val: "graphic-media", src: "did:plc:labeler"}]
    assert post.author_labels == [%{val: "bot", src: "did:plc:author"}]

    # Zero is a count the service gave; an absent count is one it did not.
    chain = AtMcp.Summary.extract(:chain_post, @responses.chain_post)
    assert {chain.like_count, chain.labels, chain.author_labels} == {0, [], []}

    bare = AtMcp.Summary.extract(:post, Map.drop(@responses.post, ["likeCount", "labels"]))
    assert {bare.like_count, bare.labels} == {nil, nil}

    profile = AtMcp.Summary.extract(:profile, @responses.profile)
    assert profile.labels == [%{val: "bot", src: "did:plc:author"}]
  end

  # An agent that cannot see a post has an image reads every picture on its
  # timeline as a post with no content. These URLs are ones the AppView already
  # hosts and already sent; nothing here fetches a blob.
  test "a post's images are read with their alt text and the AppView's URLs" do
    assert [image] = AtMcp.Summary.extract(:post, Map.fetch!(@responses, :post)).images

    assert image == %{
             alt: "a at_mcp over the sea",
             availability: "available",
             blob_cid: nil,
             mime_type: nil,
             size: nil,
             thumb: "https://cdn.example/thumb.jpg",
             fullsize: "https://cdn.example/full.jpg"
           }
  end

  # A quote post with a picture puts the images under `media`, not beside it.
  test "images on a quote post are read from where recordWithMedia puts them" do
    source = %{
      "embed" => %{
        "$type" => "app.bsky.embed.recordWithMedia#view",
        "record" => %{"record" => %{"uri" => "at://did:plc:other/app.bsky.feed.post/1"}},
        "media" => %{
          "$type" => "app.bsky.embed.images#view",
          "images" => [%{"alt" => "", "fullsize" => "https://cdn.example/q.jpg"}]
        }
      }
    }

    assert [%{alt: "", fullsize: "https://cdn.example/q.jpg", thumb: nil}] =
             AtMcp.Summary.extract(:post, source).images
  end

  # An embed AtMcp has no shape for — an external link card, a quoted record on
  # its own — is not a post with images, and is not reported as an empty list
  # either.
  test "a post with no images reads null rather than an empty list" do
    assert AtMcp.Summary.extract(:post, %{"uri" => "at://x/y/z"}).images == nil

    assert AtMcp.Summary.extract(:post, %{
             "embed" => %{"$type" => "app.bsky.embed.external#view", "external" => %{}}
           }).images == nil
  end

  test "one declaration reads atom, snake_case and camelCase responses" do
    for source <- [
          %{display_name: "café 🪁", followers_count: 3},
          %{"display_name" => "café 🪁", "followers_count" => 3},
          %{"displayName" => "café 🪁", "followersCount" => 3}
        ] do
      assert %{display_name: "café 🪁", followers: 3} = AtMcp.Summary.extract(:profile, source)
    end

    assert AtMcp.Summary.extract(:notification, %{"isRead" => true}).is_read == true

    assert AtMcp.Summary.extract(:notification, %{"author" => "author.test"}).author ==
             "author.test"
  end

  test "a value of another type reads as absent rather than contradicting the schema" do
    assert AtMcp.Summary.extract(:profile, %{"followersCount" => "3"}).followers == nil
    assert AtMcp.Summary.extract(:post, %{"uri" => %{"nested" => true}}).uri == nil

    assert AtMcp.Summary.extract(:notification, %{"author" => %{"did" => "did:plc:x"}}).author ==
             nil
  end

  # `is_read: false` means unread. Read through a chain of `||` fallbacks it
  # becomes nil, and an unread notification would claim it did not know.
  test "an unread notification reports false rather than an unknown state" do
    assert AtMcp.Summary.extract(:notification, %{"isRead" => false}).is_read == false
    assert AtMcp.Summary.extract(:notification, %{is_read: false}).is_read == false
    assert AtMcp.Summary.extract(:notification, %{}).is_read == nil
  end

  test "an absent viewer stays absent and an empty one stays empty" do
    refute Map.has_key?(AtMcp.Summary.extract(:post, %{"uri" => "at://x"}), :viewer)
    assert AtMcp.Summary.extract(:post, %{"viewer" => %{}}).viewer == %{}

    assert AtMcp.Summary.extract(:post, %{"viewer" => %{"like" => nil, "repost" => "bad"}}).viewer ==
             %{like: nil}

    refute Map.has_key?(
             AtMcp.Summary.extract(:post, %{"author" => %{"did" => "d"}}),
             :author_viewer
           )
  end

  # An agent asked whether a block stops it replying found no block flag in its
  # reads, though the AppView sends one on every profile and post author.
  test "block and mute state is kept as the service sent it, for a profile and a post's author" do
    list = %{"uri" => "at://did:plc:viewer/app.bsky.graph.list/mods", "name" => "mods"}

    full = %{
      "following" => "at://did:plc:viewer/app.bsky.graph.follow/1",
      "followedBy" => "at://did:plc:other/app.bsky.graph.follow/2",
      # Blocked only through a list, the AppView puts the list's own URI in
      # `blocking` (bsky views `blocking: viewer.blocking || blockingByList`):
      # it is not a block record, and `unblock` refuses it.
      "blocking" => list["uri"],
      "blockingByList" => list,
      "blockedBy" => true,
      "muted" => true,
      "mutedByList" => list
    }

    expected = %{
      following: "at://did:plc:viewer/app.bsky.graph.follow/1",
      followed_by: "at://did:plc:other/app.bsky.graph.follow/2",
      blocking: list["uri"],
      blocking_by_list: list["uri"],
      blocked_by: true,
      muted: true,
      muted_by_list: list["uri"]
    }

    assert AtMcp.Summary.extract(:profile, %{"viewer" => full}).viewer == expected

    post = %{
      "author" => %{"did" => "did:plc:other", "viewer" => full},
      "viewer" => %{"replyDisabled" => true, "embeddingDisabled" => true, "threadMuted" => false}
    }

    assert AtMcp.Summary.extract(:post, post).author_viewer == expected
    assert AtMcp.Summary.extract(:chain_post, post).author_viewer == expected

    assert AtMcp.Summary.extract(:post, post).viewer ==
             %{reply_disabled: true, embedding_disabled: true, thread_muted: false}

    # Every key read is a key the output schema declares, with the type it has.
    for {shape, key} <- [profile: "viewer", post: "author_viewer", chain_post: "author_viewer"] do
      declared = AtMcp.Summary.properties(shape)[key]["properties"]

      assert Map.keys(declared) |> Enum.sort() ==
               expected |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort()

      assert declared["blocked_by"]["type"] == ["boolean", "null"]
      assert declared["muted_by_list"]["type"] == ["string", "null"]
    end

    # false is an answer, not an absence; a wrong-typed value is dropped.
    assert AtMcp.Summary.extract(:profile, %{
             "viewer" => %{"blockedBy" => false, "muted" => "yes", "mutedByList" => "not a list"}
           }).viewer == %{blocked_by: false}
  end
end
