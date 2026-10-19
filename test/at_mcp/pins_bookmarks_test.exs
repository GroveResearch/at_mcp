defmodule AtMcp.PinsBookmarksTest do
  @moduledoc """
  Pinning a post, muting a thread and bookmarking (#88).

  The first half calls the tools through the MCP surface over the mock
  backend: what each refuses before anything is sent, and that none of them
  spends the write quota. The second half runs the real backend against a fake
  PDS and checks what reached the wire: the method names come from
  `AtMcp.Network`, a pin keeps every other field of the profile, and each
  record or procedure input matches its lexicon (`AtMcp.Test.Lexicon`).
  """
  use ExUnit.Case, async: false

  alias AtMcp.Test.FakePDS
  alias AtMcp.Test.Lexicon

  defp mock(backend_state \\ %{}) do
    {:ok, effects} =
      AtMcp.Test.QuotaFixture.start_effects(
        backend: AtMcp.Test.MockBackend,
        backend_state:
          Map.merge(%{mock: true, did: "did:plc:mock", handle: "mock.test"}, backend_state),
        quota_limit: 1
      )

    %{effects: effects}
  end

  defp call(state, name, arguments) do
    {:ok, result, ^state} = AtMcp.MCP.Server.handle_call_tool(name, arguments, state)
    result
  end

  describe "through the tools, over the mock backend" do
    test "pin_post refuses another account's post by naming the argument" do
      state = mock()
      result = call(state, "pin_post", %{"uri" => "at://did:plc:other/app.bsky.feed.post/1"})

      assert result.isError
      assert %{code: "invalid_arguments", problems: [%{path: "uri"}]} = result.structuredContent
      assert hd(result.content).text =~ "did:plc:other is another account"
      assert hd(result.content).text =~ "Nothing was sent"
    end

    test "pin_post takes this account's post by DID or by its handle" do
      state = mock()

      for repo <- ["did:plc:mock", "mock.test"] do
        uri = "at://#{repo}/app.bsky.feed.post/1"
        result = call(state, "pin_post", %{"uri" => uri})
        refute result[:isError], inspect(result)
        assert %{"action" => "pin_post", "subject_uri" => ^uri} = result.structuredContent
      end
    end

    test "unpin_post names the post it unpinned, so pin_post can put it back" do
      state = mock(%{pinned: "at://did:plc:mock/app.bsky.feed.post/old"})
      result = call(state, "unpin_post", %{})

      assert %{
               "action" => "unpin_post",
               "replaced_uri" => "at://did:plc:mock/app.bsky.feed.post/old"
             } =
               result.structuredContent
    end

    test "a uri that is not a post is refused for every tool that takes one" do
      state = mock()

      for name <- ~w(pin_post mute_thread unmute_thread bookmark unbookmark),
          uri <- ["at://did:plc:mock/app.bsky.feed.like/1", "not-a-uri"] do
        result = call(state, name, %{"uri" => uri})
        assert result.isError, name
        assert %{code: "invalid_arguments", problems: [%{path: "uri"}]} = result.structuredContent
      end
    end

    test "mute_thread mutes the thread's root, whichever post names it" do
      root = "at://did:plc:a/app.bsky.feed.post/root"
      state = mock(%{thread_root: root})

      result = call(state, "mute_thread", %{"uri" => "at://did:plc:b/app.bsky.feed.post/reply"})
      assert %{"action" => "mute_thread", "uri" => ^root} = result.structuredContent
    end

    test "get_bookmarks reads as posts, and a deleted bookmark keeps its place" do
      state = mock()
      result = call(state, "get_bookmarks", %{})
      text = hd(result.content).text

      assert text =~ "2 bookmarks."
      assert text =~ "[2] The post at://did:plc:gone/app.bsky.feed.post/1 is deleted or missing."
    end

    test "none of them spends the write quota" do
      %{effects: effects} = state = mock()
      assert {:ok, _} = AtMcp.Effects.post(effects, "spends the only write")
      uri = "at://did:plc:mock/app.bsky.feed.post/1"

      for {name, args} <- [
            {"pin_post", %{"uri" => uri}},
            {"unpin_post", %{}},
            {"mute_thread", %{"uri" => uri}},
            {"unmute_thread", %{"uri" => uri}},
            {"bookmark", %{"uri" => uri}},
            {"unbookmark", %{"uri" => uri}}
          ] do
        refute call(state, name, args)[:isError], name
      end

      assert AtMcp.Effects.quota_status(effects).used == 1
    end
  end

  describe "on the wire" do
    setup context do
      Application.put_env(:at_mcp, :network, context[:network] || :delve)
      on_exit(fn -> Application.delete_env(:at_mcp, :network) end)
      :ok
    end

    defp pds(records, answers \\ %{}) do
      {session, pds} = FakePDS.start(records: records, answers: answers)

      effects =
        start_supervised!(
          {AtMcp.Effects,
           backend: AtMcp.Effects.ProtoRune,
           backend_state: session,
           write_quota: AtMcp.Test.QuotaFixture.quota(10)},
          id: make_ref()
        )

      %{effects: effects, pds: pds}
    end

    @profile "at://did:plc:self/town.delve.actor.profile/self"
    @mine "at://did:plc:self/town.delve.feed.post/mine"
    @before "at://did:plc:self/town.delve.feed.post/before"

    defp profile(extra \\ %{}) do
      Map.merge(
        %{
          "$type" => "town.delve.actor.profile",
          "displayName" => "Self",
          "description" => "kept",
          "banner" => %{
            "$type" => "blob",
            "ref" => %{"$link" => "bafkreibanner"},
            "mimeType" => "image/jpeg",
            "size" => 9
          },
          "createdAt" => "2026-10-01T00:00:00.000Z"
        },
        extra
      )
    end

    defp post(text, extra \\ %{}),
      do:
        Map.merge(
          %{
            "$type" => "town.delve.feed.post",
            "text" => text,
            "createdAt" => "2026-10-01T00:00:00.000Z"
          },
          extra
        )

    test "pin_post writes the profile with a strong reference and keeps every other field" do
      %{effects: effects, pds: pds} =
        pds(%{
          @profile => profile(%{"pinnedPost" => %{"uri" => @before, "cid" => "bafyold"}}),
          @mine => post("pin me")
        })

      assert {:ok, result} = AtMcp.Effects.pin_post(effects, @mine)

      assert %{action: :pin_post, uri: @profile, subject_uri: @mine, replaced_uri: @before} =
               result

      [put] = FakePDS.sent(pds, "com.atproto.repo.putRecord")
      record = put.body["record"]
      assert put.body["collection"] == "town.delve.actor.profile"
      assert put.body["rkey"] == "self"

      assert record["pinnedPost"]["uri"] == @mine
      assert is_binary(record["pinnedPost"]["cid"])
      assert Map.drop(record, ["pinnedPost"]) == Map.drop(profile(), ["pinnedPost"])
      assert Lexicon.problems(record, "app.bsky.actor.profile") == []
    end

    test "unpin_post removes only the pin, and writes nothing when nothing is pinned" do
      %{effects: effects, pds: pds} =
        pds(%{@profile => profile(%{"pinnedPost" => %{"uri" => @before, "cid" => "bafyold"}})})

      assert {:ok, %{action: :unpin_post, replaced_uri: @before}} =
               AtMcp.Effects.unpin_post(effects)

      assert FakePDS.record(pds, @profile) == profile()
      assert Lexicon.problems(FakePDS.record(pds, @profile), "app.bsky.actor.profile") == []

      assert {:ok, %{action: :unpin_post, uri: nil, replaced_uri: nil}} =
               AtMcp.Effects.unpin_post(effects)

      assert length(FakePDS.sent(pds, "com.atproto.repo.putRecord")) == 1
    end

    test "pin_post refuses a post it cannot read, before writing anything" do
      %{effects: effects, pds: pds} = pds(%{@profile => profile()})

      assert {:error, {:referenced_record_unreadable, @mine}} =
               AtMcp.Effects.pin_post(effects, @mine)

      assert FakePDS.sent(pds, "com.atproto.repo.putRecord") == []
    end

    test "mute_thread sends the thread's root to the network's method" do
      root = "at://did:plc:other/town.delve.feed.post/root"
      reply = "at://did:plc:other/town.delve.feed.post/reply"
      ref = %{"uri" => root, "cid" => "bafyroot"}

      %{effects: effects, pds: pds} =
        pds(%{reply => post("a reply", %{"reply" => %{"root" => ref, "parent" => ref}})})

      assert {:ok, %{action: :mute_thread, uri: ^root}} =
               AtMcp.Effects.mute_thread(effects, reply)

      assert {:ok, %{action: :unmute_thread, uri: ^root}} =
               AtMcp.Effects.unmute_thread(effects, reply)

      [mute] = FakePDS.sent(pds, "town.delve.graph.muteThread")
      [unmute] = FakePDS.sent(pds, "town.delve.graph.unmuteThread")
      assert mute.body == %{"root" => root}
      assert Lexicon.problems(mute.body, "app.bsky.graph.muteThread") == []
      assert Lexicon.problems(unmute.body, "app.bsky.graph.unmuteThread") == []
    end

    @tag network: :bluesky
    test "bookmark sends the post's strong reference; unbookmark its uri" do
      uri = "at://did:plc:other/app.bsky.feed.post/1"
      %{effects: effects, pds: pds} = pds(%{uri => %{"text" => "save"}})

      assert {:ok, %{action: :bookmark, uri: ^uri}} = AtMcp.Effects.bookmark(effects, uri)
      assert {:ok, %{action: :unbookmark, uri: ^uri}} = AtMcp.Effects.unbookmark(effects, uri)

      [create] = FakePDS.sent(pds, "app.bsky.bookmark.createBookmark")
      [delete] = FakePDS.sent(pds, "app.bsky.bookmark.deleteBookmark")
      assert create.body["uri"] == uri and is_binary(create.body["cid"])
      assert Lexicon.problems(create.body, "app.bsky.bookmark.createBookmark") == []
      assert Lexicon.problems(delete.body, "app.bsky.bookmark.deleteBookmark") == []
    end

    # delve.town answers 501 for methods it does not serve. A 501 says the
    # method was not run, so the write is refused, not of unknown outcome.
    test "a service that does not implement bookmarks is reported as refusing them" do
      uri = "at://did:plc:other/town.delve.feed.post/1"

      %{effects: effects} =
        pds(%{uri => %{"text" => "save"}}, %{
          "town.delve.bookmark.createBookmark" =>
            {501, %{error: "MethodNotImplemented", message: "Method Not Implemented"}}
        })

      state = %{effects: effects}

      {:ok, result, ^state} =
        AtMcp.MCP.Server.handle_call_tool("bookmark", %{"uri" => uri}, state)

      assert result.isError
      assert result.structuredContent.code == "upstream_not_implemented"
      refute Map.has_key?(result.structuredContent, :outcome)
    end

    test "get_bookmarks reads posts and the placeholders of posts gone since" do
      gone = "at://did:plc:other/town.delve.feed.post/gone"
      kept = "at://did:plc:other/town.delve.feed.post/kept"

      bookmarks = %{
        bookmarks: [
          %{
            subject: %{uri: kept, cid: "bafykept"},
            createdAt: "2026-10-02T00:00:00.000Z",
            item: %{
              "$type" => "town.delve.feed.defs#postView",
              uri: kept,
              cid: "bafykept",
              author: %{did: "did:plc:other", handle: "other.example"},
              record: post("still here"),
              indexedAt: "2026-10-01T00:00:00.000Z"
            }
          },
          %{
            subject: %{uri: gone, cid: "bafygone"},
            createdAt: "2026-10-03T00:00:00.000Z",
            item: %{"$type" => "town.delve.feed.defs#notFoundPost", uri: gone, notFound: true}
          }
        ],
        cursor: "next"
      }

      %{effects: effects, pds: pds} =
        pds(%{}, %{"town.delve.bookmark.getBookmarks" => {200, bookmarks}})

      assert {:ok, %{count: 2, cursor: "next", items: [first, second]}} =
               AtMcp.Effects.get_bookmarks(effects, limit: 5)

      assert %{uri: ^kept, text: "still here", author: "other.example", not_found: false} = first
      assert first.bookmarked_at == "2026-10-02T00:00:00.000Z"
      assert %{uri: ^gone, not_found: true} = second
      assert [%{query: %{"limit" => "5"}}] = FakePDS.sent(pds, "town.delve.bookmark.getBookmarks")
    end
  end
end
