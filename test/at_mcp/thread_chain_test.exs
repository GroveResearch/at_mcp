defmodule AtMcp.ThreadChainTest do
  use ExUnit.Case, async: false

  alias AtMcp.Effects.ProtoRune, as: Backend

  @root "at://did:plc:rootauthor/app.bsky.feed.post/root"
  @upper "at://did:plc:other/app.bsky.feed.post/upper"
  @mid "at://did:plc:self/app.bsky.feed.post/mid"
  @leaf "at://did:plc:other/app.bsky.feed.post/leaf"
  @gone "at://did:plc:other/app.bsky.feed.post/gone"
  @blocked "at://did:plc:blockedauthor/app.bsky.feed.post/blocked"

  # Taller than the chain can carry, so the cut is visible: elements 0 (the
  # requested post) through 150 (the root).
  @tall_height 150

  # What the backend caps one chain at, read here as the claim the tests make
  # about it rather than as a number repeated in three places.
  @max_elements 100
  @walk_limit 4

  # 250 posts: three pages of the chain, the last one short.
  @page_height 249

  # More direct replies than one chain returns, so the cap and its count are
  # both visible.
  @reply_count 25

  @leaf_text "see example.com/a-very-long… and ask @alice.test"
  @leaf_link "https://example.com/a-very-long-path?ref=full"

  # An HTTP stub, not a PDS: the claims here are about what AtMcp sends and what
  # it makes of what comes back, and both are visible at this seam.
  defmodule HTTP do
    def request(:get, url, _opts) do
      uri = URI.parse(url)
      query = URI.decode_query(uri.query || "")
      send(Application.fetch_env!(:at_mcp, :thread_chain_test_owner), {:request, uri.path, query})

      body =
        AtMcp.ThreadChainTest.body(
          Application.fetch_env!(:at_mcp, :thread_chain_test_shape),
          query["uri"]
        )

      {:ok, %{status: 200, headers: [], body: Jason.encode!(body)}}
    end
  end

  setup do
    previous = Application.get_env(:proto_rune, :http_client)
    Application.put_env(:proto_rune, :http_client, HTTP)
    Application.put_env(:at_mcp, :thread_chain_test_owner, self())

    on_exit(fn ->
      if previous,
        do: Application.put_env(:proto_rune, :http_client, previous),
        else: Application.delete_env(:proto_rune, :http_client)

      Application.delete_env(:at_mcp, :thread_chain_test_owner)
      Application.delete_env(:at_mcp, :thread_chain_test_shape)
    end)

    :ok
  end

  # --- fixture bodies ---

  # root <- mid (this account) <- leaf (the requested post), with two direct
  # replies under the requested post.
  def body(:whole_thread, _uri) do
    %{
      "thread" => %{
        "post" => leaf_post(),
        "parent" => %{
          "post" => post(@mid, "did:plc:self", reply: {@root, @root}),
          "parent" => %{"post" => post(@root, "did:plc:rootauthor")}
        },
        "replies" => [
          %{"post" => post(reply_uri(1), "did:plc:replier", reply: {@root, @leaf})},
          %{"post" => post(reply_uri(2), "did:plc:replier", reply: {@root, @leaf})}
        ]
      }
    }
  end

  # The first response stops at an ancestor that still names a parent of its
  # own, the way a service capping `parentHeight` below the thread's height
  # answers. Only a second request can reach the root.
  def body(:taller_than_one_call, uri) do
    cond do
      uri == @leaf ->
        %{
          "thread" => %{
            "post" => leaf_post(),
            "parent" => %{"post" => post(@mid, "did:plc:self", reply: {@root, @upper})},
            "replies" => []
          }
        }

      uri == @upper ->
        %{
          "thread" => %{
            "post" => post(@upper, "did:plc:other", reply: {@root, @root}),
            "parent" => %{"post" => post(@root, "did:plc:rootauthor")}
          }
        }
    end
  end

  # A deleted parent: `notFoundPost` carries a uri and nothing else, so the
  # service's own chain ends there and the root is reachable only by the uri
  # the requested post names.
  def body(:missing_ancestors, uri) do
    cond do
      uri == @leaf ->
        %{
          "thread" => %{
            "post" => leaf_post(reply: {@root, @gone}),
            "parent" => %{
              "$type" => "app.bsky.feed.defs#notFoundPost",
              "uri" => @gone,
              "notFound" => true
            },
            "replies" => []
          }
        }

      uri == @root ->
        %{"thread" => %{"post" => post(@root, "did:plc:rootauthor")}}
    end
  end

  # A blocked parent: `blockedPost` carries a uri and an author and nothing
  # else. The chain keeps its place and the root is reached by the uri the
  # requested post names.
  def body(:blocked_ancestor, uri) do
    cond do
      uri == @leaf ->
        %{
          "thread" => %{
            "post" => leaf_post(reply: {@root, @blocked}),
            "parent" => %{
              "$type" => "app.bsky.feed.defs#blockedPost",
              "uri" => @blocked,
              "blocked" => true,
              "author" => %{"did" => "did:plc:blockedauthor"}
            },
            "replies" => []
          }
        }

      uri == @root ->
        %{"thread" => %{"post" => post(@root, "did:plc:rootauthor")}}
    end
  end

  # The root itself is the post that was deleted: the chain's first element is
  # the placeholder standing in for it.
  def body(:unreadable_root, _uri) do
    %{
      "thread" => %{
        "post" => leaf_post(reply: {@gone, @gone}),
        "parent" => %{
          "$type" => "app.bsky.feed.defs#notFoundPost",
          "uri" => @gone,
          "notFound" => true
        },
        "replies" => []
      }
    }
  end

  # A reply whose declared root is not the topmost ancestor: reading @mid
  # answers with the real root above it, so the head of the chain can never
  # equal the declared root and re-reading @mid can only repeat what is held.
  def body(:mis_rooted, uri) do
    cond do
      uri == @leaf ->
        %{
          "thread" => %{
            "post" => post(@leaf, "did:plc:other", reply: {@mid, @mid}),
            "replies" => []
          }
        }

      uri == @mid ->
        %{
          "thread" => %{
            "post" => post(@mid, "did:plc:self", reply: {@root, @root}),
            "parent" => %{"post" => post(@root, "did:plc:rootauthor")}
          }
        }
    end
  end

  # Two records naming each other as parent.
  def body(:parent_cycle, uri) do
    cond do
      uri == @leaf ->
        %{
          "thread" => %{
            "post" => post(@leaf, "did:plc:other", reply: {@root, @mid}),
            "replies" => []
          }
        }

      uri == @mid ->
        %{"thread" => %{"post" => post(@mid, "did:plc:self", reply: {@root, @leaf})}}
    end
  end

  # A `thread` object with no post and no uri in it: nothing about any post.
  def body(:thread_without_post, _uri), do: %{"thread" => %{}}

  # A conversation taller than the chain carries, root included.
  def body(:tall, _uri) do
    %{
      "thread" => %{
        "post" =>
          post(deep_uri(0), "did:plc:other", reply: {deep_uri(@tall_height), deep_uri(1)}),
        "parent" => tall_parent(1),
        "replies" => []
      }
    }
  end

  # The same height, with a declared root the response never contains: the
  # chain is already longer than it can carry, so climbing for more ancestors
  # would only read posts that are then dropped.
  def body(:tall_unrooted, _uri) do
    %{
      "thread" => %{
        "post" => post(deep_uri(0), "did:plc:other", reply: {@root, deep_uri(1)}),
        "parent" => unrooted_parent(1),
        "replies" => []
      }
    }
  end

  # The second read answers with an ancestor the chain already holds: @mid
  # names @leaf as its parent while @leaf names @mid as its. The uri asked for
  # was new; what came back was not.
  def body(:loop_back, uri) do
    cond do
      uri == @leaf ->
        %{
          "thread" => %{
            "post" => post(@leaf, "did:plc:other", reply: {@root, @mid}),
            "replies" => []
          }
        }

      uri == @mid ->
        %{
          "thread" => %{
            "post" => post(@mid, "did:plc:self", reply: {@root, @upper}),
            "parent" => %{"post" => post(@leaf, "did:plc:other", reply: {@root, @mid})}
          }
        }
    end
  end

  # Two calls, each answering with fewer elements than the chain carries and
  # summing to more than it does: the walk itself pushes the chain past the cap.
  def body(:two_call_ladder, uri) do
    cond do
      uri == step_uri(0) -> %{"thread" => Map.put(ladder(0, 59), "replies", [])}
      uri == step_uri(60) -> %{"thread" => ladder(60, 119)}
    end
  end

  # Every read makes progress and none of them reaches the declared root: the
  # form the walk limit exists for.
  def body(:never_reaches_root, uri) do
    n = uri |> Path.basename() |> String.replace("step", "") |> String.to_integer()

    %{
      "thread" => %{
        "post" => post(step_uri(n), "did:plc:other", reply: {@root, step_uri(n + 1)}),
        "replies" => []
      }
    }
  end

  # Two ranges no reader can honour: one past the end of the text, one cutting
  # a multi-byte character in half.
  def body(:facet_out_of_range, _uri) do
    {ellipsis, _} = :binary.match(@leaf_text, "…")

    facets = [
      range(0, byte_size(@leaf_text) + 40),
      range(ellipsis + 1, ellipsis + 2)
    ]

    %{
      "thread" => %{
        "post" => post(@leaf, "did:plc:other", text: @leaf_text, facets: facets),
        "replies" => []
      }
    }
  end

  # A conversation far taller than one chain carries, served the way a PDS
  # serves it: each request answers with the requested post and at most
  # @chain_parent_height ancestors above it. Reading the whole thing is only
  # possible by resuming from where the last page stopped.
  def body(:paged, uri) do
    n = page_index(uri)
    top = min(n + @max_elements - 1, @page_height)

    %{"thread" => Map.put(page_ladder(n, top), "replies", [])}
  end

  # More direct replies than one chain returns.
  def body(:many_replies, _uri) do
    %{
      "thread" => %{
        "post" => leaf_post(),
        "parent" => %{"post" => post(@root, "did:plc:rootauthor")},
        "replies" =>
          for i <- 1..@reply_count do
            %{"post" => post(reply_uri(i), "did:plc:replier", reply: {@root, @leaf})}
          end
      }
    }
  end

  def page_uri(n), do: "at://did:plc:other/app.bsky.feed.post/page#{n}"

  defp page_index(uri),
    do: uri |> Path.basename() |> String.replace("page", "") |> String.to_integer()

  # Index 0 is the requested post and @page_height is the root, so a parent
  # link counts upward.
  defp page_ladder(n, top) when n < top do
    %{
      "post" => page_post(n),
      "parent" => page_ladder(n + 1, top)
    }
  end

  defp page_ladder(n, _top), do: %{"post" => page_post(n)}

  defp page_post(@page_height),
    do: post(page_uri(@page_height), "did:plc:rootauthor")

  defp page_post(n),
    do: post(page_uri(n), "did:plc:other", reply: {page_uri(@page_height), page_uri(n + 1)})

  def deep_uri(n), do: "at://did:plc:other/app.bsky.feed.post/deep#{n}"
  def step_uri(n), do: "at://did:plc:other/app.bsky.feed.post/step#{n}"

  defp tall_parent(n) when n < @tall_height do
    %{
      "post" =>
        post(deep_uri(n), "did:plc:other", reply: {deep_uri(@tall_height), deep_uri(n + 1)}),
      "parent" => tall_parent(n + 1)
    }
  end

  defp tall_parent(n), do: %{"post" => post(deep_uri(n), "did:plc:rootauthor")}

  defp unrooted_parent(n) when n < @tall_height do
    %{
      "post" => post(deep_uri(n), "did:plc:other", reply: {@root, deep_uri(n + 1)}),
      "parent" => unrooted_parent(n + 1)
    }
  end

  defp unrooted_parent(n),
    do: %{"post" => post(deep_uri(n), "did:plc:other", reply: {@root, deep_uri(n + 1)})}

  defp ladder(n, top) when n < top do
    %{
      "post" => post(step_uri(n), "did:plc:other", reply: {@root, step_uri(n + 1)}),
      "parent" => ladder(n + 1, top)
    }
  end

  defp ladder(n, _top),
    do: %{"post" => post(step_uri(n), "did:plc:other", reply: {@root, step_uri(n + 1)})}

  defp range(start, stop) do
    %{
      "index" => %{"byteStart" => start, "byteEnd" => stop},
      "features" => [%{"$type" => "app.bsky.richtext.facet#link", "uri" => @leaf_link}]
    }
  end

  def reply_uri(n), do: "at://did:plc:replier/app.bsky.feed.post/reply#{n}"

  defp leaf_post(opts \\ []) do
    post(
      @leaf,
      "did:plc:other",
      Keyword.merge([text: @leaf_text, facets: leaf_facets(), reply: {@root, @mid}], opts)
    )
  end

  defp leaf_facets do
    [
      span("example.com/a-very-long…", %{
        "$type" => "app.bsky.richtext.facet#link",
        "uri" => @leaf_link
      }),
      span("@alice.test", %{
        "$type" => "app.bsky.richtext.facet#mention",
        "did" => "did:plc:alice"
      })
    ]
  end

  defp span(token, feature) do
    {start, length} = :binary.match(@leaf_text, token)
    %{"index" => %{"byteStart" => start, "byteEnd" => start + length}, "features" => [feature]}
  end

  defp post(uri, author_did, opts \\ []) do
    record =
      %{
        "text" => Keyword.get(opts, :text, "a post"),
        "createdAt" => "2026-09-15T00:00:00.000Z"
      }
      |> maybe_put("facets", Keyword.get(opts, :facets))
      |> maybe_put("reply", reply_ref(Keyword.get(opts, :reply)))

    %{
      "uri" => uri,
      "cid" => "cid-" <> Path.basename(uri),
      "author" => %{
        "did" => author_did,
        "handle" => String.replace(author_did, "did:plc:", "") <> ".test",
        "displayName" => "Display " <> String.replace(author_did, "did:plc:", "")
      },
      "record" => record
    }
  end

  defp reply_ref(nil), do: nil

  defp reply_ref({root, parent}),
    do: %{"root" => %{"uri" => root}, "parent" => %{"uri" => parent}}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp shape(name), do: Application.put_env(:at_mcp, :thread_chain_test_shape, name)

  # Every request the stub served, in order. The stub sends before it answers,
  # so by the time the call returns the mailbox holds all of them: a claim
  # about how many reads one tool call costs is checkable here.
  defp requested_uris(acc \\ []) do
    receive do
      {:request, _path, query} -> requested_uris([query["uri"] | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp session do
    %ProtoRune.Atproto.Session{
      did: "did:plc:self",
      handle: "self.test",
      access_jwt: "access",
      refresh_jwt: "refresh",
      service_url: "https://pds.invalid/xrpc"
    }
  end

  # --- claims ---

  test "the chain is ordered root first and its last element is the requested post" do
    shape(:whole_thread)
    assert {:ok, chain} = Backend.get_thread_chain(session(), @leaf)

    assert Enum.map(chain.chain, & &1.uri) == [@root, @mid, @leaf]
    assert List.last(chain.chain).uri == @leaf
    assert chain.root_uri == @root
    refute chain.chain_truncated
  end

  test "a thread taller than one API call still reaches the root" do
    shape(:taller_than_one_call)
    assert {:ok, chain} = Backend.get_thread_chain(session(), @leaf)

    assert Enum.map(chain.chain, & &1.uri) == [@root, @upper, @mid, @leaf]
    assert hd(chain.chain).uri == @root
    refute chain.chain_truncated

    assert_receive {:request, _path, %{"uri" => @leaf}}
    assert_receive {:request, _path, %{"uri" => @upper}}
  end

  test "the request asks for the ancestors the chain can carry, spelled as the lexicon does" do
    shape(:whole_thread)
    assert {:ok, _} = Backend.get_thread_chain(session(), @leaf)

    assert_receive {:request, path, query}
    assert String.ends_with?(path, "getPostThread")
    assert query["parentHeight"] == to_string(@max_elements)
    assert query["depth"] == "1"
  end

  test "link and mention facets are rendered into each element's text" do
    shape(:whole_thread)
    assert {:ok, chain} = Backend.get_thread_chain(session(), @leaf)

    leaf = List.last(chain.chain)
    assert leaf.text =~ @leaf_link
    assert leaf.text =~ "@alice.test"
    assert Enum.any?(leaf.facets, &(&1.type == "mention" and &1.did == "did:plc:alice"))
    assert Enum.any?(leaf.facets, &(&1.type == "link" and &1.uri == @leaf_link))
  end

  test "a facet whose byte range falls outside the text does not drop the post" do
    shape(:facet_out_of_range)
    assert {:ok, chain} = Backend.get_thread_chain(session(), @leaf)

    leaf = List.last(chain.chain)
    assert leaf.uri == @leaf
    assert leaf.text == @leaf_text
    assert leaf.facets == []
  end

  test "a deleted or blocked ancestor yields a placeholder element and does not drop the chain" do
    shape(:missing_ancestors)
    assert {:ok, chain} = Backend.get_thread_chain(session(), @leaf)

    assert Enum.map(chain.chain, & &1.uri) == [@root, @gone, @leaf]
    assert List.last(chain.chain).uri == @leaf

    placeholder = Enum.at(chain.chain, 1)
    assert placeholder.not_found
    assert is_nil(placeholder.author)
    assert is_nil(placeholder.text)

    # The root is read, not stood in for: a second request by the uri the
    # requested post names, whose answer is a post and not a placeholder.
    assert requested_uris() == [@leaf, @root]
    root = hd(chain.chain)
    refute root.unresolved
    refute root.not_found
    assert root.author == "rootauthor.test"
    assert root.created_at == "2026-09-15T00:00:00.000Z"

    # The chain reaches the root by the uri the requested post names, but how
    # many ancestors the unreadable one hid is not knowable from this read.
    assert chain.chain_truncated
  end

  test "a blocked ancestor is flagged as blocked, not as deleted, and keeps its place" do
    shape(:blocked_ancestor)
    assert {:ok, chain} = Backend.get_thread_chain(session(), @leaf)

    assert Enum.map(chain.chain, & &1.uri) == [@root, @blocked, @leaf]

    placeholder = Enum.at(chain.chain, 1)
    assert placeholder.blocked
    refute placeholder.not_found
    assert placeholder.author_did == "did:plc:blockedauthor"
    assert is_nil(placeholder.text)
    assert chain.chain_truncated
  end

  test "a chain whose first element could not be read is reported as truncated" do
    shape(:unreadable_root)
    assert {:ok, chain} = Backend.get_thread_chain(session(), @leaf)

    assert Enum.map(chain.chain, & &1.uri) == [@gone, @leaf]
    assert hd(chain.chain).not_found

    # The declared root is where the chain starts, so nothing further is read;
    # the flag answers whether the chain runs unbroken from the root, and one
    # of its elements could not be read.
    assert requested_uris() == [@leaf]
    assert chain.chain_truncated
  end

  test "a post whose declared root is not its topmost ancestor does not repeat the ancestors" do
    shape(:mis_rooted)
    assert {:ok, chain} = Backend.get_thread_chain(session(), @leaf)

    uris = Enum.map(chain.chain, & &1.uri)
    assert uris == [@root, @mid, @leaf]
    assert uris == Enum.uniq(uris)
    assert List.last(chain.chain).uri == @leaf

    # Reading @mid a second time could only prepend @root and @mid again, so
    # the walk stops instead of spending its remaining calls on it.
    assert requested_uris() == [@leaf, @mid]
    assert chain.root_uri == @mid
    assert chain.chain_truncated
  end

  test "records that name each other as parent do not produce a chain that repeats posts" do
    shape(:parent_cycle)
    assert {:ok, chain} = Backend.get_thread_chain(session(), @leaf)

    uris = Enum.map(chain.chain, & &1.uri)
    assert uris == [@mid, @leaf]
    assert uris == Enum.uniq(uris)
    assert requested_uris() == [@leaf, @mid]
    assert chain.chain_truncated
  end

  test "an answer that hands back a post the chain already holds is not prepended" do
    shape(:loop_back)
    assert {:ok, chain} = Backend.get_thread_chain(session(), @leaf)

    uris = Enum.map(chain.chain, & &1.uri)
    assert uris == Enum.uniq(uris)
    assert uris == [@leaf]
    assert requested_uris() == [@leaf, @mid]
    assert chain.chain_truncated
  end

  test "a thread object with no post in it is an unreadable answer, not five reads" do
    shape(:thread_without_post)

    assert {:error, %AtMcp.Effects.Failure{kind: :unreadable}} =
             Backend.get_thread_chain(session(), @leaf)

    assert requested_uris() == [@leaf]
  end

  test "a conversation taller than the chain keeps the posts nearest the requested one" do
    shape(:tall)
    requested = deep_uri(0)
    assert {:ok, chain} = Backend.get_thread_chain(session(), requested)

    total = @tall_height + 1
    assert length(chain.chain) == @max_elements
    assert chain.chain_omitted == total - @max_elements
    assert List.last(chain.chain).uri == requested
    assert hd(chain.chain).uri == deep_uri(@max_elements - 1)
    assert chain.chain_truncated

    # The cut is on the chain, not on the tool result's other fields.
    assert chain.root_uri == deep_uri(@tall_height)
  end

  test "a chain already at its cap does not spend more reads on ancestors it would drop" do
    shape(:tall_unrooted)
    assert {:ok, chain} = Backend.get_thread_chain(session(), deep_uri(0))

    assert length(chain.chain) == @max_elements
    assert chain.chain_truncated
    assert requested_uris() == [deep_uri(0)]
  end

  test "a chain the walk pushes past the cap is cut once, and the cut is counted" do
    shape(:two_call_ladder)
    assert {:ok, chain} = Backend.get_thread_chain(session(), step_uri(0))

    # 60 elements, then 60 more: neither answer is over the cap on its own.
    assert requested_uris() == [step_uri(0), step_uri(60)]
    assert length(chain.chain) == @max_elements
    assert chain.chain_omitted == 120 - @max_elements
    assert hd(chain.chain).uri == step_uri(@max_elements - 1)
    assert List.last(chain.chain).uri == step_uri(0)
    assert chain.chain_truncated
  end

  test "a walk that never reaches the root stops at the limit and names where it stopped" do
    shape(:never_reaches_root)
    assert {:ok, chain} = Backend.get_thread_chain(session(), step_uri(0))

    assert length(requested_uris()) == @walk_limit + 1
    assert length(chain.chain) == @walk_limit + 2

    head = hd(chain.chain)
    assert head.unresolved
    assert head.uri == step_uri(@walk_limit + 1)
    assert is_nil(head.text)
    assert List.last(chain.chain).uri == step_uri(0)
    assert chain.chain_truncated
  end

  test "a post by the calling identity is flagged and another author's is not" do
    shape(:whole_thread)
    assert {:ok, chain} = Backend.get_thread_chain(session(), @leaf)

    flags = Map.new(chain.chain, &{&1.uri, &1.is_self})
    assert flags == %{@root => false, @mid => true, @leaf => false}
  end

  test "the replies directly under the requested post are returned separately" do
    shape(:whole_thread)
    assert {:ok, chain} = Backend.get_thread_chain(session(), @leaf)

    assert Enum.map(chain.replies, & &1.uri) == [reply_uri(1), reply_uri(2)]
    assert chain.replies_omitted == 0

    chain_uris = Enum.map(chain.chain, & &1.uri)
    for reply <- chain.replies, do: refute(reply.uri in chain_uris)
  end

  test "a conversation taller than one chain is read in pages by resuming at chain_before" do
    shape(:paged)

    assert {:ok, first} = Backend.get_thread_chain(session(), page_uri(0))

    assert {:ok, second} =
             Backend.get_thread_chain(session(), page_uri(0), before: first.chain_before)

    assert {:ok, third} =
             Backend.get_thread_chain(session(), page_uri(0), before: second.chain_before)

    # Each page ends where the caller asked it to, and the next begins above it.
    assert List.last(first.chain).uri == page_uri(0)
    assert first.chain_before == page_uri(@max_elements)
    assert second.chain_before == page_uri(2 * @max_elements)

    # The last page reaches the root, so there is nothing left to resume from.
    assert is_nil(third.chain_before)
    refute third.chain_truncated
    assert hd(third.chain).uri == page_uri(@page_height)

    read = Enum.flat_map([third, second, first], &Enum.map(&1.chain, fn e -> e.uri end))

    assert read == Enum.map(@page_height..0//-1, &page_uri/1)
    assert read == Enum.uniq(read)
    assert length(read) == @page_height + 1
  end

  test "a page read from before carries no replies, so no post appears in two pages" do
    shape(:paged)

    assert {:ok, page} =
             Backend.get_thread_chain(session(), page_uri(0), before: page_uri(@max_elements))

    assert List.last(page.chain).uri == page_uri(@max_elements)
    assert page.replies == []
    assert page.replies_omitted == 0
  end

  test "a page read from before drops replies the service sent anyway" do
    # This shape answers with two replies whatever depth it is asked for, the
    # way a service free to send more than it was asked for would. Depth 0 is a
    # request; carrying no replies is the promise, so it is kept here.
    shape(:whole_thread)

    assert {:ok, page} = Backend.get_thread_chain(session(), @leaf, before: @leaf)

    assert page.replies == []
    assert page.replies_omitted == 0
  end

  test "a chain that reaches the root has nothing to resume from" do
    shape(:whole_thread)
    assert {:ok, chain} = Backend.get_thread_chain(session(), @leaf)
    assert is_nil(chain.chain_before)
  end

  test "a walk that stopped has nowhere to resume that is not already in the page" do
    shape(:never_reaches_root)
    assert {:ok, chain} = Backend.get_thread_chain(session(), step_uri(0))

    assert chain.chain_truncated

    # The uri reading stopped at is the head of this page. Naming it as the
    # place to resume would hand the caller that post twice: once as the
    # placeholder standing in for it, once as the post itself.
    assert hd(chain.chain).unresolved
    assert hd(chain.chain).uri == step_uri(@walk_limit + 1)
    assert is_nil(chain.chain_before)
  end

  test "chain_before never names a post the page already holds" do
    for shape <- [:parent_cycle, :loop_back, :mis_rooted, :never_reaches_root, :unreadable_root],
        requested = if(shape == :never_reaches_root, do: step_uri(0), else: @leaf) do
      shape(shape)
      assert {:ok, chain} = Backend.get_thread_chain(session(), requested)
      uris = Enum.map(chain.chain, & &1.uri)

      refute chain.chain_before in uris,
             "#{shape} offers #{inspect(chain.chain_before)}, which is already in the page"
    end
  end

  test "a walk that turned back on itself offers no cursor, so paging cannot loop" do
    shape(:parent_cycle)
    assert {:ok, chain} = Backend.get_thread_chain(session(), @leaf)

    # @leaf and @mid name each other as parent. The uri above the head is the
    # post the caller asked about, so reading from it would return this same
    # page, and the page after that, without end.
    assert Enum.map(chain.chain, & &1.uri) == [@mid, @leaf]
    assert hd(chain.chain).reply_to == @leaf
    assert chain.chain_truncated
    assert is_nil(chain.chain_before)
  end

  test "an answer that repeated a post the chain held offers no cursor either" do
    shape(:loop_back)
    assert {:ok, chain} = Backend.get_thread_chain(session(), @leaf)

    assert Enum.map(chain.chain, & &1.uri) == [@leaf]
    assert chain.chain_truncated
    assert is_nil(chain.chain_before)
  end

  test "a before that is not a string is answered, not crashed, and costs no read" do
    shape(:whole_thread)

    {:ok, effects} =
      AtMcp.Test.QuotaFixture.start_effects(
        backend: AtMcp.Effects.ProtoRune,
        backend_state: session()
      )

    assert {:error, :invalid_before} = AtMcp.Effects.get_thread_chain(effects, @leaf, before: 123)

    # And the backend refuses it too rather than raising, since a cursor comes
    # back from whoever was holding it.
    assert {:error, :invalid_before} = Backend.get_thread_chain(session(), @leaf, before: 123)

    # Refused before a session is taken, so it costs no read.
    assert requested_uris() == []

    assert {:ok, result, _state} =
             AtMcp.MCP.Server.handle_call_tool(
               "get_thread_chain",
               %{"uri" => @leaf, "before" => 123},
               %{effects: effects}
             )

    assert result[:isError]
    # MCP enforces its declared string type before the backend's cursor check.
    # Direct Effects/backend callers above retain their domain-specific error.
    assert result.structuredContent.code == "invalid_arguments"
    assert requested_uris() == []
  end

  test "the direct replies returned are capped and the rest are counted" do
    shape(:many_replies)
    assert {:ok, chain} = Backend.get_thread_chain(session(), @leaf)

    assert length(chain.replies) == 20
    assert chain.replies_omitted == @reply_count - 20
    assert Enum.map(chain.replies, & &1.uri) == Enum.map(1..20, &reply_uri/1)
  end

  test "the tool takes before, describes paging rather than a frozen number, and returns chain_before" do
    {:ok, tools, nil, :state} = AtMcp.MCP.Server.handle_list_tools(nil, :state)
    tool = Enum.find(tools, &(&1.name == "get_thread_chain"))

    assert Map.has_key?(tool.inputSchema.properties, :before)
    assert tool.outputSchema["properties"]["chain_before"]

    # A cap written into a description is frozen at compile time and goes stale
    # the moment the attribute moves; chain_before is what a caller acts on.
    refute tool.description =~ "100"
    assert tool.description =~ "chain_before"
  end

  test "the tool reads from before when given it" do
    shape(:paged)

    {:ok, effects} =
      AtMcp.Test.QuotaFixture.start_effects(
        backend: AtMcp.Effects.ProtoRune,
        backend_state: session()
      )

    state = %{effects: effects}

    assert {:ok, result, ^state} =
             AtMcp.MCP.Server.handle_call_tool(
               "get_thread_chain",
               %{"uri" => page_uri(0), "before" => page_uri(@max_elements)},
               state
             )

    refute result[:isError]
    structured = result.structuredContent
    assert List.last(structured["chain"])["uri"] == page_uri(@max_elements)
    assert structured["chain_before"] == page_uri(2 * @max_elements)
  end

  test "the thread chain is a read: a read-scope grant reaches it and no write allowance is spent" do
    assert AtMcp.Grants.permits_scope?(:read, "get_thread_chain")

    {:ok, effects} =
      AtMcp.Test.QuotaFixture.start_effects(backend: AtMcp.Test.MockBackend, quota_limit: 100)

    assert {:ok, _} = AtMcp.Effects.login(effects)
    used = AtMcp.Effects.quota_status(effects).used

    assert {:ok, %{chain: [_ | _]}} = AtMcp.Effects.get_thread_chain(effects, @leaf)
    assert AtMcp.Effects.quota_status(effects).used == used
  end
end
