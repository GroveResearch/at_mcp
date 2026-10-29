defmodule AtMcp.MCP.ReadPagesTest do
  use ExUnit.Case, async: false

  alias AtMcp.Test.Schema

  defmodule FixtureHTTP do
    def request(:get, url, opts) do
      uri = URI.parse(url)
      query = URI.decode_query(uri.query || "")
      owner = Application.fetch_env!(:at_mcp, :read_pages_test_owner)
      send(owner, {:request, uri.path, query})

      # `URI.decode_query/1` keeps only the last value of a repeated key, so the
      # wire form is reported separately: it is the only place a repeated
      # `others=` is visible. The headers go with it because an unauthenticated
      # read returns records with no `viewer`, and `viewer` is what an agent
      # decides on.
      send(owner, {:wire, uri.path, uri.query, Keyword.get(opts, :headers, [])})

      body =
        cond do
          String.ends_with?(uri.path, "getUnreadCount") ->
            case Application.get_env(:at_mcp, :read_pages_test_shape) do
              # The AppView answered, but not with a count.
              :unrecognized -> %{"seenAt" => "1970-01-01T00:00:00Z"}
              _ -> %{"count" => 7}
            end

          Application.get_env(:at_mcp, :read_pages_test_shape) == :unrecognized ->
            # A page whose list arrived under a name AtMcp does not know.
            %{"records" => [], "cursor" => nil}

          String.ends_with?(uri.path, "getPostThreadV2") and
              Application.get_env(:at_mcp, :read_pages_test_shape) == :malformed_thread ->
            # Items whose `value` is not an object and whose depth is not a
            # number. Real responses do not look like this; a proxy's error
            # page decoded into the same slot does.
            %{
              thread: [
                %{uri: "at://x", depth: 0, value: "at://not-an-object"},
                %{uri: "at://y", depth: "one", value: %{post: "none"}}
              ],
              hasOtherReplies: "maybe"
            }

          String.ends_with?(uri.path, "getPostThreadV2") ->
            # getPostThreadV2's flat list: parents root first, the post, then
            # each reply followed by the replies under it.
            %{
              thread:
                [
                  %{
                    uri: "at://missing",
                    depth: -2,
                    value: %{"$type": "app.bsky.unspecced.defs#threadItemNotFound"}
                  },
                  # As V2 sends every parent: moreReplies 0, whatever its
                  # replies; its replyCount says how many it has.
                  thread_item(Map.put(post(-1), :replyCount, 3), -1),
                  thread_item(post(0), 0, moreReplies: 5),
                  %{
                    uri: "at://blocked",
                    depth: 1,
                    value: %{
                      "$type": "app.bsky.unspecced.defs#threadItemBlocked",
                      author: %{did: "did:plc:blocked"}
                    }
                  }
                ] ++
                  Enum.flat_map(2..20, fn n ->
                    [
                      thread_item(post(n), 1),
                      thread_item(post(n + 100), 2, moreReplies: 2)
                    ]
                  end),
              hasOtherReplies: false
            }

          String.ends_with?(uri.path, "getRelationships") ->
            # Read back off the wire, so a `others` list that was not encoded as
            # a repeated key cannot produce a complete answer here.
            %{
              actor: query["actor"],
              relationships:
                Enum.map(repeated(uri.query, "others"), fn other ->
                  %{
                    did: other,
                    following: "at://did:plc:reader/app.bsky.graph.follow/#{other}",
                    followedBy: nil,
                    notFound: false
                  }
                end)
            }

          true ->
            first = query["cursor"] == nil
            items = Enum.map(if(first, do: 1..30, else: 31..32), &post/1)

            key =
              cond do
                String.ends_with?(uri.path, "listNotifications") -> :notifications
                String.ends_with?(uri.path, "searchActors") -> :actors
                String.ends_with?(uri.path, "searchPostsV2") -> :posts
                String.ends_with?(uri.path, "getQuotes") -> :posts
                String.ends_with?(uri.path, "getFollowers") -> :followers
                String.ends_with?(uri.path, "getKnownFollowers") -> :followers
                String.ends_with?(uri.path, "getFollows") -> :follows
                String.ends_with?(uri.path, "getBlocks") -> :blocks
                String.ends_with?(uri.path, "getMutes") -> :mutes
                String.ends_with?(uri.path, "getSuggestedFollowsByActor") -> :suggestions
                String.ends_with?(uri.path, "getSuggestedFeeds") -> :feeds
                String.ends_with?(uri.path, "getRepostedBy") -> :repostedBy
                String.ends_with?(uri.path, "getLikes") -> :likes
                true -> :feed
              end

            profiles =
              Enum.map(
                items,
                &Map.merge(&1.author, %{
                  description: &1.record.text,
                  viewer: %{following: "at://did:plc:reader/app.bsky.graph.follow/#{&1.cid}"}
                })
              )

            values =
              case key do
                :feed ->
                  Enum.map(items, &%{post: &1})

                :notifications ->
                  Enum.map(items, fn item ->
                    Map.merge(item, %{
                      reason: "reply",
                      isRead: false,
                      indexedAt: "2026-09-13T12:34:56.123Z",
                      reasonSubject: "at://did:plc:parent/app.bsky.feed.post/p",
                      record:
                        Map.put(item.record, :reply, %{
                          parent: %{uri: "at://did:plc:parent/app.bsky.feed.post/p"},
                          root: %{uri: "at://did:plc:root/app.bsky.feed.post/r"}
                        })
                    })
                  end)

                :posts ->
                  items

                :feeds ->
                  Enum.map(if(first, do: 1..30, else: 31..32), &generator/1)

                # A like is a record about an account, not the account.
                :likes ->
                  Enum.map(profiles, &%{actor: &1, createdAt: "1970-01-01T00:00:00Z"})

                _profile_list ->
                  profiles
              end

            %{key => values, :cursor => if(first, do: "opaque/+next=page", else: nil)}
        end

      {:ok, %{status: 200, headers: [], body: Jason.encode!(body)}}
    end

    defp repeated(query, key) do
      (query || "")
      |> String.split("&")
      |> Enum.filter(&String.starts_with?(&1, key <> "="))
      |> Enum.map(&(&1 |> String.replace_prefix(key <> "=", "") |> URI.decode_www_form()))
    end

    defp thread_item(post, depth, fields \\ []) do
      %{
        uri: post.uri,
        depth: depth,
        value:
          Map.merge(
            %{
              "$type": "app.bsky.unspecced.defs#threadItemPost",
              post: post,
              moreParents: false,
              moreReplies: 0,
              opThread: false,
              hiddenByThreadgate: false,
              mutedByViewer: false
            },
            Map.new(fields)
          )
      }
    end

    defp post(n),
      do: %{
        uri: "at://did:plc:fixture/app.bsky.feed.post/#{n}",
        cid: "cid#{n}",
        record: %{text: String.duplicate("🪁日本語é", 60)},
        author: %{did: "did:plc:author#{n}", handle: "author#{n}.example"}
      }

    defp generator(n),
      do: %{
        uri: "at://did:plc:gen/app.bsky.feed.generator/feed#{n}",
        cid: "cid#{n}",
        did: "did:web:feed#{n}.example",
        displayName: "Feed #{n}",
        description: String.duplicate("🪁日本語é", 60),
        creator: %{did: "did:plc:author#{n}", handle: "author#{n}.example"},
        likeCount: n,
        indexedAt: "2026-09-13T12:34:56.123Z",
        viewer: %{like: "at://did:plc:reader/app.bsky.feed.like/cid#{n}"}
      }
  end

  setup do
    prior = Application.get_env(:proto_rune, :http_client)
    Application.put_env(:proto_rune, :http_client, FixtureHTTP)
    Application.put_env(:at_mcp, :read_pages_test_owner, self())

    on_exit(fn ->
      if prior,
        do: Application.put_env(:proto_rune, :http_client, prior),
        else: Application.delete_env(:proto_rune, :http_client)

      Application.delete_env(:at_mcp, :read_pages_test_owner)
    end)

    session = %ProtoRune.Atproto.Session{
      did: "did:plc:reader",
      handle: "reader.example",
      access_jwt: "fixture",
      refresh_jwt: "fixture",
      service_url: "https://pds.invalid/xrpc"
    }

    {:ok, _} =
      AtMcp.Identities.start_identity(
        id: "page-reader",
        listen_enabled: false,
        backend_state: session
      )

    on_exit(fn -> AtMcp.Identities.stop_identity("page-reader") end)
    {client, _token} = AtMcp.Test.Grant.client("page-reader")

    %{client: client, session: session}
  end

  test "notification collection sends repeated reasons and retains checkpoint and reply context",
       %{
         session: session
       } do
    assert {:ok, %{items: [item | _], cursor: "opaque/+next=page"}} =
             AtMcp.Effects.ProtoRune.list_notifications(session,
               limit: 30,
               reasons: ["mention", "reply", "quote"],
               cursor: nil
             )

    assert_receive {:wire, "/xrpc/app.bsky.notification.listNotifications", wire, headers}
    assert List.keyfind(headers, "authorization", 0) == {"authorization", "Bearer fixture"}
    pairs = URI.query_decoder(wire) |> Enum.to_list()

    assert Enum.filter(pairs, fn {key, _} -> key == "reasons" end) ==
             [{"reasons", "mention"}, {"reasons", "reply"}, {"reasons", "quote"}]

    assert {"limit", "30"} in pairs
    refute List.keymember?(pairs, "cursor", 0)

    assert item.uri == "at://did:plc:fixture/app.bsky.feed.post/1"
    assert item.cid == "cid1"
    assert item.indexed_at == "2026-09-13T12:34:56.123Z"
    assert item.subject_uri == "at://did:plc:parent/app.bsky.feed.post/p"
    assert item.reply_parent_uri == "at://did:plc:parent/app.bsky.feed.post/p"
    assert item.reply_root_uri == "at://did:plc:root/app.bsky.feed.post/r"
    assert item.author_did == "did:plc:author1"
    assert item.text == String.duplicate("🪁日本語é", 60)
    refute item.is_read
  end

  test "get_notifications passes reasons to the service's own filter, and leaves it off when none are given",
       %{client: client} do
    call(client, "get_notifications", %{"reasons" => ["reply", "quote"]})
    assert_receive {:wire, "/xrpc/app.bsky.notification.listNotifications", wire, _headers}

    assert URI.query_decoder(wire) |> Enum.filter(&(elem(&1, 0) == "reasons")) ==
             [{"reasons", "reply"}, {"reasons", "quote"}]

    call(client, "get_notifications", %{})
    assert_receive {:wire, "/xrpc/app.bsky.notification.listNotifications", wire, _headers}
    refute URI.query_decoder(wire) |> Enum.any?(&(elem(&1, 0) == "reasons"))

    # A reason the lexicon does not name is refused before anything is sent.
    assert {:ok, %{"isError" => true, "structuredContent" => %{"code" => "invalid_arguments"}}} =
             ExMCP.Client.call_tool(client, "get_notifications", %{"reasons" => ["likes"]},
               format: :map
             )

    refute_receive {:wire, "/xrpc/app.bsky.notification.listNotifications", _, _}
  end

  test "search_posts sends author, mentions, sort, since, until and lang on the wire, as searchPostsV2 names them",
       %{
         client: client
       } do
    result =
      call(client, "search_posts", %{
        "query" => "at_mcp",
        "author" => "@writer.example",
        "mentions" => "@reader.example",
        "sort" => "latest",
        "since" => "2026-09-01T00:00:00Z",
        "until" => "2026-10-01T00:00:00Z",
        "lang" => "en",
        "limit" => 30
      })

    assert result["count"] == 30
    assert_receive {:wire, "/xrpc/app.bsky.feed.searchPostsV2", wire, _headers}
    pairs = URI.query_decoder(wire) |> Enum.to_list()
    assert {"query", "at_mcp"} in pairs
    assert {"authors", "writer.example"} in pairs
    assert {"mentions", "reader.example"} in pairs
    # The first version said latest; this one says recent.
    assert {"sort", "recent"} in pairs
    assert {"since", "2026-09-01T00:00:00Z"} in pairs
    assert {"until", "2026-10-01T00:00:00Z"} in pairs
    assert {"languages", "en"} in pairs
    # As the first version searched: every post, not the recent window.
    assert {"allTime", "true"} in pairs
    refute List.keymember?(pairs, "cursor", 0)
    refute Enum.any?(pairs, fn {_key, value} -> String.contains?(value, "@") end)
  end

  test "ordinary MCP traverses complete remote pages without losing items or opaque cursors", %{
    client: client
  } do
    for {name, args, path} <- [
          {"get_notifications", %{}, "listNotifications"},
          {"get_timeline", %{}, "getTimeline"},
          {"get_author_feed", %{"actor" => "reader.example"}, "getAuthorFeed"},
          {"search_posts", %{"query" => "at_mcp"}, "searchPostsV2"},
          {"search_actors", %{"query" => "at_mcp"}, "searchActors"}
        ] do
      first = call(client, name, Map.put(args, "limit", 30))
      assert first["count"] == 30
      assert length(first["items"]) == 30
      assert first["cursor"] == "opaque/+next=page"
      assert_receive {:request, requested_path, %{"limit" => "30"} = query}
      assert String.ends_with?(requested_path, path)
      refute Map.has_key?(query, "cursor")
      second = call(client, name, Map.merge(args, %{"limit" => 30, "cursor" => first["cursor"]}))
      assert second["count"] == 2
      assert length(second["items"]) == 2

      assert_receive {:request, ^requested_path,
                      %{"cursor" => "opaque/+next=page", "limit" => "30"}}

      identities = Enum.map(first["items"] ++ second["items"], &(&1["uri"] || &1["did"]))
      assert length(Enum.uniq(identities)) == 32
    end
  end

  test "invalid page sizes fail before the backend is called", %{client: client} do
    for limit <- [0, 51] do
      assert {:ok, result} =
               ExMCP.Client.call_tool(client, "get_timeline", %{"limit" => limit}, format: :map)

      assert result["isError"] || result[:isError]
      refute_receive {:request, _, _}, 20
    end
  end

  test "embedded callers receive the same page validation before any request" do
    effects = AtMcp.Identity.effects_name("page-reader")

    assert {:error, "limit must be an integer between 1 and 50"} =
             AtMcp.Effects.get_timeline(effects, limit: "30")

    assert {:error, "cursor must be a string returned by the previous page"} =
             AtMcp.Effects.get_timeline(effects, cursor: 12)

    refute_receive {:request, _, _}, 20
  end

  test "thread context retains nesting and unavailable nodes and reports omitted siblings", %{
    client: client
  } do
    thread = call(client, "get_thread", %{"uri" => "at://did:plc:fixture/app.bsky.feed.post/0"})
    assert thread["uri"] == "at://did:plc:fixture/app.bsky.feed.post/0"
    assert thread["parent"]["parent"]["not_found"]
    assert thread["parent"]["parent"]["uri"] == "at://missing"
    assert hd(thread["replies"])["blocked"]
    assert hd(thread["replies"])["author_did"] == "did:plc:blocked"
    assert length(thread["replies"]) == 20
    assert thread["replies_omitted"] == 5
    assert get_in(Enum.at(thread["replies"], 1), ["replies", Access.at(0), "cid"]) == "cid102"

    # Replies the service did not send are counted, not reported as none.
    assert get_in(Enum.at(thread["replies"], 1), ["replies", Access.at(0), "replies_omitted"]) ==
             2

    # A parent's count leaves out the post shown under it.
    assert thread["parent"]["replies_omitted"] == 2
    assert thread["other_replies"] == false

    assert thread["context"] == %{
             "depth" => 10,
             "breadth" => 1,
             "sort" => "top",
             "view" => "linear"
           }

    assert_receive {:request, _, %{"below" => "10", "branchingFactor" => "1", "sort" => "top"}}
  end

  # An unreadable response is reported as unreadable. Summarizing it as a list of
  # the response's key names satisfies no declared schema and, arriving as a
  # success, reads as an empty result; reporting a response with no count as zero
  # unread states a number the service never said, and the one an agent is most
  # likely to act on by doing nothing.
  test "an unread count the service did not give is not reported as zero", %{client: client} do
    assert %{"count" => 7} = call(client, "get_unread_count", %{})

    Application.put_env(:at_mcp, :read_pages_test_shape, :unrecognized)
    on_exit(fn -> Application.delete_env(:at_mcp, :read_pages_test_shape) end)

    assert {:ok, result} =
             ExMCP.Client.call_tool(client, "get_unread_count", %{"format" => "json"},
               format: :map
             )

    assert result["isError"] || result[:isError]
    structured = result["structuredContent"] || result[:structuredContent]
    assert (structured["code"] || structured[:code]) == "response_unreadable"
  end

  test "a page in an unrecognized shape is reported as unknown, not as a result", %{
    client: client
  } do
    Application.put_env(:at_mcp, :read_pages_test_shape, :unrecognized)
    on_exit(fn -> Application.delete_env(:at_mcp, :read_pages_test_shape) end)

    for name <- ["get_timeline", "get_notifications", "search_actors", "get_unread_count"] do
      args = if name == "search_actors", do: %{"query" => "at_mcp"}, else: %{}
      args = Map.put(args, "format", "json")
      assert {:ok, result} = ExMCP.Client.call_tool(client, name, args, format: :map)

      assert result["isError"] || result[:isError],
             "#{name} reported an unreadable page as a result"

      structured = result["structuredContent"] || result[:structuredContent]
      schema = AtMcp.MCP.Server.__output_schemas__()[name]
      assert Schema.valid?(structured, schema), "#{name} returned #{inspect(structured)}"

      structured_code = structured["code"] || structured[:code]
      assert structured_code == "response_unreadable", "#{name} reported #{structured_code}"

      text = (result["content"] || result[:content]) |> Enum.map_join(&(&1["text"] || &1[:text]))
      refute text =~ "records", "#{name} published the response's keys"

      # The service answered and the request completed; AtMcp could not read the
      # answer. Telling an agent the request did not complete invites a retry
      # loop against a condition that is deterministic in AtMcp's own parser.
      refute text =~ "did not complete", "#{name} blames the service for a parse it owns"
      assert text =~ "Retrying will return the same result"
    end
  end

  # A thread node whose fields are the wrong type must not raise inside the
  # summarizer (`Enum.take/2` on a binary), which would reach an agent as a
  # crashed tool rather than as a result. Each field is read only when it has the
  # type the schema promises.
  test "a thread node with wrong-typed fields is summarized, not crashed on", %{client: client} do
    Application.put_env(:at_mcp, :read_pages_test_shape, :malformed_thread)
    on_exit(fn -> Application.delete_env(:at_mcp, :read_pages_test_shape) end)

    assert {:ok, result} =
             ExMCP.Client.call_tool(
               client,
               "get_thread",
               %{"uri" => "at://x", "format" => "json"},
               format: :map
             )

    refute result["isError"] || result[:isError]
    structured = result["structuredContent"] || result[:structuredContent]
    schema = AtMcp.MCP.Server.__output_schemas__()["get_thread"]
    assert Schema.valid?(structured, schema)

    assert structured["replies"] == []
    assert structured["not_found"] == false
  end

  # An account that can follow and be followed must also be able to ask who its
  # audience is and who responded to its writing. These reads reach the AppView
  # through the same backend, page shape and declared schemas as every other one.
  @audience_reads [
    {"get_followers", %{"actor" => "reader.example"}, "app.bsky.graph.getFollowers", :profile},
    {"get_follows", %{"actor" => "reader.example"}, "app.bsky.graph.getFollows", :profile},
    {"get_known_followers", %{"actor" => "a.example"}, "app.bsky.graph.getKnownFollowers",
     :profile},
    {"get_blocks", %{}, "app.bsky.graph.getBlocks", :profile},
    {"get_mutes", %{}, "app.bsky.graph.getMutes", :profile},
    {"get_likes", %{"uri" => "at://did:plc:fixture/app.bsky.feed.post/0"},
     "app.bsky.feed.getLikes", :profile},
    {"get_reposted_by", %{"uri" => "at://did:plc:fixture/app.bsky.feed.post/0"},
     "app.bsky.feed.getRepostedBy", :profile},
    {"get_quotes", %{"uri" => "at://did:plc:fixture/app.bsky.feed.post/0"},
     "app.bsky.feed.getQuotes", :post},
    {"get_actor_likes", %{"actor" => "reader.example"}, "app.bsky.feed.getActorLikes", :post},
    {"get_feed", %{"feed" => "at://did:plc:gen/app.bsky.feed.generator/hot"},
     "app.bsky.feed.getFeed", :post},
    {"get_suggested_feeds", %{}, "app.bsky.feed.getSuggestedFeeds", :generator},
    {"get_list_feed", %{"list" => "at://did:plc:list/app.bsky.graph.list/friends"},
     "app.bsky.feed.getListFeed", :post}
  ]

  test "graph, engagement and feed reads traverse complete pages like every other read", %{
    client: client
  } do
    for {name, args, path, kind} <- @audience_reads do
      first = call(client, name, Map.put(args, "limit", 30))
      assert first["count"] == 30, "#{name} did not return the page the service sent"
      assert first["cursor"] == "opaque/+next=page", "#{name} dropped the cursor"

      assert_receive {:request, requested_path, %{"limit" => "30"}}
      assert requested_path == "/xrpc/" <> path, "#{name} called #{requested_path}"

      second = call(client, name, Map.merge(args, %{"limit" => 30, "cursor" => first["cursor"]}))
      assert second["count"] == 2

      assert_receive {:request, ^requested_path,
                      %{"cursor" => "opaque/+next=page", "limit" => "30"}}

      items = first["items"] ++ second["items"]

      identity =
        case kind do
          :profile -> "handle"
          :post -> "uri"
          :generator -> "uri"
        end

      assert Enum.all?(items, &is_binary(&1[identity])),
             "#{name} did not summarize its items as #{kind}s"

      assert length(Enum.uniq(Enum.map(items, & &1[identity]))) == 32

      schema = AtMcp.MCP.Server.__output_schemas__()[name]
      assert Schema.valid?(first, schema), "#{name} returned #{inspect(first)}"
    end
  end

  # An unauthenticated read returns records with no `viewer` at all, and
  # `viewer` is the account's own relationship to what it is reading — the
  # decision input. A read that reached the service without the session would
  # still return a plausible page.
  test "audience reads carry the account's credential and keep the viewer relationship", %{
    client: client
  } do
    followers = call(client, "get_followers", %{"actor" => "reader.example", "limit" => 30})

    assert hd(followers["items"])["viewer"]["following"] ==
             "at://did:plc:reader/app.bsky.graph.follow/cid1"

    assert_receive {:wire, "/xrpc/app.bsky.graph.getFollowers", _query, headers}
    assert List.keyfind(headers, "authorization", 0) == {"authorization", "Bearer fixture"}
  end

  # `URI.encode_query/1` raises on a list value and has no way to express a
  # repeated key, so `others` cannot go through the declared-parameter path at
  # all. If it were sent as one value, the service would see one account.
  test "get_relationships asks about every account it was given", %{client: client} do
    others = ["did:plc:bob", "did:plc:carol", "did:plc:dave"]

    result =
      call(client, "get_relationships", %{"actor" => "reader.example", "others" => others})

    assert result["count"] == 3
    assert Enum.map(result["items"], & &1["did"]) == others
    assert hd(result["items"])["following"] =~ "app.bsky.graph.follow/did:plc:bob"
    assert hd(result["items"])["followed_by"] == nil
    refute hd(result["items"])["not_found"]

    assert_receive {:wire, "/xrpc/app.bsky.graph.getRelationships", wire, _headers}
    assert length(String.split(wire, "others=")) == 4
  end

  test "suggested follows are read from the service's own suggestions list", %{client: client} do
    result = call(client, "get_suggested_follows", %{"actor" => "reader.example"})
    assert result["count"] == 30
    assert hd(result["items"])["handle"] == "author1.example"
    assert_receive {:request, "/xrpc/app.bsky.graph.getSuggestedFollowsByActor", %{"actor" => _}}
  end

  test "suggested feeds are read from the service's generator list", %{client: client} do
    result = call(client, "get_suggested_feeds", %{"limit" => 30})
    assert result["count"] == 30
    feed = hd(result["items"])
    assert feed["uri"] == "at://did:plc:gen/app.bsky.feed.generator/feed1"
    assert feed["display_name"] == "Feed 1"
    assert feed["creator"] == "author1.example"
    assert feed["creator_did"] == "did:plc:author1"
    assert feed["like_count"] == 1
    assert feed["viewer"]["like"] == "at://did:plc:reader/app.bsky.feed.like/cid1"
    assert_receive {:request, "/xrpc/app.bsky.feed.getSuggestedFeeds", %{"limit" => "30"}}
  end

  # Peri keeps a key whose value is nil, and `URI.encode_query/1` then sends
  # `cursor=`. A service asked to continue from an empty cursor is entitled to
  # refuse, and nothing in a page's shape would reveal it.
  test "a read the caller gave no cursor sends no cursor at all", %{client: client} do
    call(client, "get_feed", %{"feed" => "at://did:plc:gen/app.bsky.feed.generator/hot"})
    assert_receive {:wire, "/xrpc/app.bsky.feed.getFeed", wire, _headers}
    refute wire =~ "cursor"
  end

  defp call(client, name, args) do
    args = Map.put(args, "format", "json")
    assert {:ok, result} = ExMCP.Client.call_tool(client, name, args, format: :map)
    refute result["isError"] || result[:isError]
    # These reads are about what a program gets: pages, cursors, nesting. A
    # model reads the text beside it (`AtMcp.ReadingTest`).
    result["structuredContent"] || result[:structuredContent]
  end
end
