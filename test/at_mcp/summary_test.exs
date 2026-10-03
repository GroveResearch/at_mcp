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
      "record" => %{"text" => "café 日本語 🪁"},
      "author" => %{"handle" => "author.test", "did" => "did:plc:author"},
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
        "displayName" => "café 日本語 🪁"
      }
    },
    profile: %{
      "did" => "did:plc:author",
      "handle" => "author.test",
      "displayName" => "café 日本語 🪁",
      "description" => "a profile",
      "followersCount" => 3,
      "followsCount" => 2,
      "postsCount" => 1,
      "viewer" => %{"following" => "at://did:plc:viewer/app.bsky.graph.follow/1"}
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
            }
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
  end
end
