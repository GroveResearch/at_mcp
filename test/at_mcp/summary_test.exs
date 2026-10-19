defmodule AtMcp.SummaryTest do
  use ExUnit.Case, async: true

  # Application responses in the shapes the AppView actually sends. These are
  # inputs, not a second copy of the declaration: each assertion compares two
  # things derived from `AtMcp.Summary`, so a field can never be described
  # without being read, or read without being described.
  # What the AppView sends beside an account's name: the verification check
  # and a live status.
  @verification %{"verifiedStatus" => "valid", "trustedVerifierStatus" => "none"}

  @live %{
    "uri" => "at://did:plc:author/app.bsky.actor.status/self",
    "cid" => "bafystatus",
    "status" => "app.bsky.actor.status#live",
    "isActive" => true,
    "isDisabled" => false,
    "expiresAt" => "2026-09-13T13:00:00.000Z",
    "labels" => [%{"src" => "did:plc:labeler", "val" => "spam"}],
    "embed" => %{
      "$type" => "app.bsky.embed.external#view",
      "external" => %{"uri" => "https://stream.example/live", "title" => "On air"}
    }
  }

  # A gate that lets the author's followers and one list's members reply.
  @gate %{
    "uri" => "at://did:plc:author/app.bsky.feed.threadgate/1",
    "record" => %{
      "$type" => "app.bsky.feed.threadgate",
      "allow" => [
        %{"$type" => "app.bsky.feed.threadgate#followerRule"},
        %{
          "$type" => "app.bsky.feed.threadgate#listRule",
          "list" => "at://did:plc:author/app.bsky.graph.list/friends"
        }
      ]
    },
    "lists" => [
      %{"uri" => "at://did:plc:author/app.bsky.graph.list/friends", "name" => "Friends"}
    ]
  }

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
        "viewer" => %{"muted" => false, "blockedBy" => true},
        "verification" => @verification,
        "status" => @live
      },
      "threadgate" => @gate,
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
        "viewer" => %{},
        "verification" => @verification,
        "status" => @live
      },
      "likeCount" => 0,
      "repostCount" => 0,
      "replyCount" => 0,
      "quoteCount" => 0,
      "labels" => [],
      "threadgate" => @gate,
      "viewer" => %{"replyDisabled" => true}
    },
    profile: %{
      "did" => "did:plc:author",
      "handle" => "author.test",
      "displayName" => "café 日本語 🪁",
      "description" => "a profile",
      "avatar" => "https://cdn.example/avatar.jpg",
      "banner" => "https://cdn.example/banner.jpg",
      "followersCount" => 3,
      "followsCount" => 2,
      "postsCount" => 1,
      "labels" => [%{"src" => "did:plc:author", "val" => "bot"}],
      "viewer" => %{
        "following" => "at://did:plc:viewer/app.bsky.graph.follow/1",
        "knownFollowers" => %{
          "count" => 3,
          "followers" => [%{"did" => "did:plc:k", "handle" => "k.test", "displayName" => "K"}]
        }
      },
      "pronouns" => "they/them",
      "website" => "https://author.example",
      "links" => [
        %{
          "uri" => "at://did:plc:author/app.bsky.actor.link/1",
          "cid" => "bafylink",
          "url" => "https://author.example/blog",
          "title" => "Blog"
        }
      ],
      "createdAt" => "2024-01-02T03:04:05.000Z",
      "pinnedPost" => %{"uri" => "at://did:plc:author/app.bsky.feed.post/1", "cid" => "bafypost"},
      "verification" =>
        Map.put(@verification, "verifications", [
          %{
            "issuer" => "did:plc:verifier",
            "issuerHandle" => "verifier.test",
            "issuerDisplayName" => "Verifier",
            "uri" => "at://did:plc:verifier/app.bsky.graph.verification/1",
            "isValid" => true,
            "createdAt" => "2025-01-01T00:00:00.000Z"
          }
        ]),
      "status" => @live,
      "associated" => %{
        "lists" => 2,
        "feedgens" => 1,
        "starterPacks" => 1,
        "labeler" => false,
        "chat" => %{"allowIncoming" => "following"}
      },
      "joinedViaStarterPack" => %{
        "uri" => "at://did:plc:k/app.bsky.graph.starterpack/p",
        "record" => %{"name" => "Agents"},
        "creator" => %{"did" => "did:plc:k", "handle" => "k.test"}
      }
    },
    generator: %{
      "uri" => "at://did:plc:author/app.bsky.feed.generator/hot",
      "cid" => "bafygen",
      "did" => "did:web:feeds.example",
      "displayName" => "What's hot",
      "description" => "posts the service currently surfaces",
      "avatar" => "https://cdn.example/feed.jpg",
      "creator" => %{"handle" => "author.test", "did" => "did:plc:author", "displayName" => "A"},
      "likeCount" => 12,
      "acceptsInteractions" => true,
      "labels" => [%{"val" => "spam", "src" => "did:plc:labeler"}],
      "indexedAt" => "2026-09-13T12:34:56.123Z",
      "viewer" => %{"like" => "at://did:plc:viewer/app.bsky.feed.like/1"}
    },
    trend: %{
      "topic" => "kites",
      "displayName" => "Kites",
      "description" => "kite season",
      "link" => "/search?q=kites",
      "startedAt" => "2026-10-18T00:00:00.000Z",
      "postCount" => 12,
      "status" => "hot",
      "category" => "sports",
      "actors" => [%{"did" => "did:plc:a", "handle" => "a.test", "displayName" => "A"}]
    },
    invite_code: %{
      "code" => "town-abcde",
      "available" => 1,
      "disabled" => false,
      "forAccount" => "did:plc:self",
      "createdBy" => "admin",
      "createdAt" => "2026-10-18T00:00:00.000Z",
      "uses" => [%{"usedBy" => "did:plc:b", "usedAt" => "2026-10-18T01:00:00.000Z"}]
    },
    draft: %{
      "id" => "3draft",
      "createdAt" => "2026-10-01T00:00:00.000Z",
      "updatedAt" => "2026-10-02T00:00:00.000Z",
      "draft" => %{
        "deviceName" => "phone",
        "posts" => [
          %{
            "text" => "café 日本語 🪁",
            "embedImages" => [%{"localRef" => %{"path" => "/1.jpg"}, "alt" => "a kite"}]
          }
        ]
      }
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
      "author" => %{
        "handle" => "author.test",
        "did" => "did:plc:author",
        "displayName" => "Author",
        "labels" => [%{"src" => "did:plc:author", "val" => "bot"}],
        "viewer" => %{"followedBy" => "at://did:plc:author/app.bsky.graph.follow/f"},
        "verification" => @verification,
        "status" => @live
      },
      "labels" => [%{"src" => "did:plc:labeler", "val" => "graphic-media"}],
      "starterPack" => %{
        "uri" => "at://did:plc:k/app.bsky.graph.starterpack/p",
        "record" => %{"name" => "Agents"},
        "creator" => %{"did" => "did:plc:k", "handle" => "k.test"}
      },
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
    },
    list: %{
      "uri" => "at://did:plc:author/app.bsky.graph.list/l",
      "cid" => "bafylist",
      "name" => "Friends",
      "purpose" => "app.bsky.graph.defs#curatelist",
      "description" => "people",
      "creator" => %{"handle" => "author.test", "did" => "did:plc:author", "displayName" => "A"},
      "listItemCount" => 2,
      "labels" => [%{"val" => "spam", "src" => "did:plc:labeler"}],
      "viewer" => %{"muted" => true}
    },
    list_member: %{
      "uri" => "at://did:plc:author/app.bsky.graph.listitem/i",
      "subject" => %{
        "did" => "did:plc:member",
        "handle" => "member.test",
        "displayName" => "M",
        "description" => "about me",
        "labels" => [%{"val" => "bot", "src" => "did:plc:member"}],
        "viewer" => %{"muted" => false}
      },
      "subjectOptedOut" => true
    },
    starter_pack: %{
      "uri" => "at://did:plc:author/app.bsky.graph.starterpack/p",
      "cid" => "bafypack",
      "record" => %{
        "name" => "Agents",
        "description" => "who to follow",
        "createdAt" => "2026-09-13T12:34:56.123Z",
        "list" => "at://did:plc:author/app.bsky.graph.list/l"
      },
      "creator" => %{"handle" => "author.test", "did" => "did:plc:author", "displayName" => "A"},
      "list" => %{
        "uri" => "at://did:plc:author/app.bsky.graph.list/l",
        "listItemCount" => 2,
        "viewer" => %{
          "referenceListOptOut" => "at://did:plc:viewer/app.bsky.graph.referencelistoptout/o"
        }
      },
      "joinedWeekCount" => 1,
      "joinedAllTimeCount" => 5,
      "feeds" => [
        %{
          "uri" => "at://did:plc:f/app.bsky.feed.generator/g",
          "displayName" => "G",
          "creator" => %{"handle" => "f.test"}
        }
      ],
      "listItemsSample" => [
        %{"subject" => %{"did" => "did:plc:m", "handle" => "m.test", "displayName" => "M"}}
      ],
      "labels" => [%{"val" => "spam", "src" => "did:plc:labeler"}]
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
                },
                "feedContext" => "t-kites",
                "reqId" => "req-1"
              })
          })
        else
          source
        end

      summary = AtMcp.Summary.extract(shape, source)
      described = AtMcp.Summary.properties(shape) |> Map.keys() |> MapSet.new()
      read = summary |> Map.keys() |> MapSet.new(&to_string/1)

      assert read == described, "#{shape} reads and describes different fields"

      # A post's media is images, a link card or a video, never more than one;
      # this response has images, and test/at_mcp/embed_test.exs reads the others.
      for {key, value} <- Map.drop(summary, [:viewer, :link, :video]) do
        refute is_nil(value), "#{shape}.#{key} is described but was not read from a full response"
      end
    end
  end

  # Every client shows a profile's avatar and banner once it is set; these URLs
  # are ones the service already hosts and already sent, not blobs to fetch.
  test "a profile summary carries the avatar and banner the service hosts" do
    profile = AtMcp.Summary.extract(:profile, Map.fetch!(@responses, :profile))

    assert profile.avatar == "https://cdn.example/avatar.jpg"
    assert profile.banner == "https://cdn.example/banner.jpg"

    none = AtMcp.Summary.extract(:profile, %{"handle" => "plain.test"})
    assert none.avatar == nil
    assert none.banner == nil
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
    assert AtMcp.Summary.extract(:profile, %{"avatar" => %{"ref" => "bafy"}}).avatar == nil
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

  # A chain element is a post like any other read; the chain is where an agent
  # decides whether to answer the last post, so it needs the post's viewer.
  test "a chain element carries the post's viewer state, as get_posts does" do
    post = Map.fetch!(@responses, :chain_post)

    assert AtMcp.Summary.extract(:chain_post, post).viewer == %{reply_disabled: true}

    assert AtMcp.Summary.properties(:chain_post)["viewer"] ==
             AtMcp.Summary.properties(:post)["viewer"]
  end

  test "a quoted post carries its labels, its author's labels and badges, and where the account stands with its author" do
    quoted = %{
      "$type" => "app.bsky.embed.record#viewRecord",
      "uri" => "at://did:plc:q/app.bsky.feed.post/q",
      "cid" => "bafyq",
      "author" => %{
        "did" => "did:plc:q",
        "handle" => "q.test",
        "labels" => [%{"src" => "did:plc:q", "val" => "bot"}],
        "viewer" => %{"muted" => true, "blockedBy" => false},
        "verification" => @verification,
        "status" => @live
      },
      "labels" => [%{"src" => "did:plc:labeler", "val" => "graphic-media", "cts" => "x"}],
      "value" => %{"$type" => "app.bsky.feed.post", "text" => "quoted"}
    }

    post =
      @responses.post
      |> Map.put("embed", %{"$type" => "app.bsky.embed.record#view", "record" => quoted})

    quote = AtMcp.Summary.extract(:post, post).quote

    assert quote.labels == [%{src: "did:plc:labeler", val: "graphic-media"}]
    assert quote.author_labels == [%{src: "did:plc:q", val: "bot"}]
    assert quote.author_viewer == %{muted: true, blocked_by: false}
    assert quote.author_verification == %{status: "valid", trusted_verifier: "none"}
    assert %{kind: "app.bsky.actor.status#live", active: true} = quote.author_status

    # Not told is not "no relationship": a quote without a viewer has none.
    bare =
      put_in(post, ["embed", "record", "author"], %{"did" => "did:plc:q", "handle" => "q.test"})

    assert AtMcp.Summary.extract(:post, bare).quote.author_viewer == nil

    quote_schema = AtMcp.Summary.properties(:post)["quote"]["properties"]

    assert quote_schema["author_viewer"]["properties"] ==
             AtMcp.Summary.properties(:post)["author_viewer"]["properties"]

    assert quote_schema["labels"]["items"] ==
             AtMcp.Summary.properties(:post)["labels"]["items"]
  end

  test "a notification carries its author's name, labels, badges and relationship, and the record's labels" do
    item = AtMcp.Summary.extract(:notification, Map.fetch!(@responses, :notification))

    assert item.display_name == "Author"
    assert item.labels == [%{src: "did:plc:labeler", val: "graphic-media"}]
    assert item.author_labels == [%{src: "did:plc:author", val: "bot"}]
    assert item.author_viewer == %{followed_by: "at://did:plc:author/app.bsky.graph.follow/f"}
    assert item.author_verification == %{status: "valid", trusted_verifier: "none"}
    assert item.starter_pack.name == "Agents"
  end

  test "a profile carries what the app's profile page shows" do
    profile = AtMcp.Summary.extract(:profile, Map.fetch!(@responses, :profile))

    assert profile.pronouns == "they/them"
    assert profile.website == "https://author.example"
    assert [%{url: "https://author.example/blog", title: "Blog"}] = profile.links
    assert profile.created_at == "2024-01-02T03:04:05.000Z"
    assert profile.pinned_post == "at://did:plc:author/app.bsky.feed.post/1"

    assert %{status: "valid", by: [%{issuer_handle: "verifier.test", valid: true}]} =
             profile.verification

    assert %{
             active: true,
             url: "https://stream.example/live",
             uri: "at://did:plc:author/app.bsky.actor.status/self",
             labels: [%{val: "spam"}]
           } = profile.status

    assert {profile.lists, profile.feeds, profile.starter_packs} == {2, 1, 1}
    assert profile.labeler == false
    assert profile.messages_from == "following"

    assert profile.joined_via == %{
             uri: "at://did:plc:k/app.bsky.graph.starterpack/p",
             name: "Agents",
             creator: "k.test"
           }

    assert %{count: 3, followers: [%{handle: "k.test"}]} = profile.known_followers

    # A follower list's basic view has none of these: each reads null.
    basic = AtMcp.Summary.extract(:profile, %{"did" => "did:plc:b", "handle" => "b.test"})

    assert Enum.all?(
             [basic.pinned_post, basic.verification, basic.status, basic.links],
             &is_nil/1
           )
  end

  test "who may reply is read from the gate on the post, in the words set_post_interactions takes" do
    rule = fn gate ->
      AtMcp.Summary.extract(:post, Map.put(@responses.post, "threadgate", gate)).reply_rule
    end

    assert rule.(@gate) == ["followers", "at://did:plc:author/app.bsky.graph.list/friends"]
    assert rule.(put_in(@gate, ["record", "allow"], [])) == []
    assert rule.(update_in(@gate, ["record"], &Map.delete(&1, "allow"))) == ["everyone"]
    # A reply carries no gate: its thread's is on the first post.
    assert AtMcp.Summary.extract(:post, Map.delete(@responses.post, "threadgate")).reply_rule ==
             nil

    assert AtMcp.Summary.extract(:post, @responses.post).reply_lists == [
             %{uri: "at://did:plc:author/app.bsky.graph.list/friends", name: "Friends"}
           ]
  end
end
