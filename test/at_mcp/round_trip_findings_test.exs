defmodule AtMcp.RoundTripFindingsTest do
  @moduledoc """
  What the end-to-end round trips against the reference PDS and AppView found
  (#110 to #113), held here on a fake PDS so `mix test` catches a regression
  without that network: a like, repost, follow or block is written once and
  undone whole; a deleted record reads as not found; a `seen_at` that does not
  parse is refused; and a reply the thread's rule excludes is refused before
  anything is written.
  """
  use ExUnit.Case, async: false

  alias AtMcp.Test.FakePDS

  @me "did:plc:self"
  @post "at://did:plc:other/app.bsky.feed.post/p"
  @other_post "at://did:plc:other/app.bsky.feed.post/q"

  defp pds(records \\ %{}, answers \\ %{}) do
    {session, pds} = FakePDS.start(records: records, answers: answers)

    effects =
      start_supervised!(
        {AtMcp.Effects,
         backend: AtMcp.Effects.ProtoRune,
         backend_state: session,
         write_quota: AtMcp.Test.QuotaFixture.quota(10)},
        id: make_ref()
      )

    %{effects: effects, pds: pds, state: %{effects: effects}}
  end

  defp call(state, name, arguments) do
    {:ok, result, ^state} = AtMcp.MCP.Server.handle_call_tool(name, arguments, state)
    result
  end

  defp writes(pds),
    do:
      Enum.filter(
        FakePDS.methods(pds),
        &(&1 in [
            "com.atproto.repo.createRecord",
            "com.atproto.repo.deleteRecord",
            "com.atproto.repo.applyWrites"
          ])
      )

  defp like(subject), do: %{"subject" => %{"uri" => subject, "cid" => "bafysubject"}}

  describe "like, repost, follow and block are written once (#110)" do
    test "a post already liked or reposted answers the record it has, and nothing is sent or counted" do
      viewer = %{
        "like" => "at://#{@me}/app.bsky.feed.like/l1",
        "repost" => "at://#{@me}/app.bsky.feed.repost/r1"
      }

      %{effects: effects, pds: pds} =
        pds(%{}, %{
          "app.bsky.feed.getPosts" => {200, %{posts: [%{uri: @post, viewer: viewer}]}}
        })

      assert {:ok, %{uri: "at://did:plc:self/app.bsky.feed.like/l1", unchanged: true}} =
               AtMcp.Effects.like(effects, @post, "bafysubject")

      assert {:ok, %{uri: "at://did:plc:self/app.bsky.feed.repost/r1", unchanged: true}} =
               AtMcp.Effects.repost(effects, @post, "bafysubject")

      assert writes(pds) == []
      assert AtMcp.Effects.quota_status(effects).used == 0
    end

    test "a post not liked yet is liked" do
      %{effects: effects, pds: pds} =
        pds(%{}, %{"app.bsky.feed.getPosts" => {200, %{posts: [%{uri: @post, viewer: %{}}]}}})

      assert {:ok, result} = AtMcp.Effects.like(effects, @post, "bafysubject")
      refute result[:unchanged]
      assert writes(pds) == ["com.atproto.repo.createRecord"]
    end

    test "an account already followed or blocked answers the record it has, and nothing is sent" do
      viewer = %{
        "following" => "at://#{@me}/app.bsky.graph.follow/f1",
        "blocking" => "at://#{@me}/app.bsky.graph.block/b1"
      }

      %{effects: effects, pds: pds} =
        pds(%{}, %{
          "app.bsky.actor.getProfile" => {200, %{did: "did:plc:other", viewer: viewer}}
        })

      assert {:ok, %{uri: "at://did:plc:self/app.bsky.graph.follow/f1", unchanged: true}} =
               AtMcp.Effects.follow(effects, "did:plc:other")

      assert {:ok, %{uri: "at://did:plc:self/app.bsky.graph.block/b1", unchanged: true}} =
               AtMcp.Effects.block(effects, "did:plc:other")

      assert writes(pds) == []
    end

    test "unlike deletes every like of the same subject, in one commit, and names each" do
      first = "at://#{@me}/app.bsky.feed.like/a"
      second = "at://#{@me}/app.bsky.feed.like/b"
      elsewhere = "at://#{@me}/app.bsky.feed.like/c"

      %{pds: pds, state: state} =
        pds(%{first => like(@post), second => like(@post), elsewhere => like(@other_post)})

      result = call(state, "unlike", %{"uri" => second})
      refute result[:isError], inspect(result)
      assert %{"deleted" => [^second, ^first]} = result.structuredContent
      assert writes(pds) == ["com.atproto.repo.applyWrites"]
      assert FakePDS.record(pds, first) == nil
      assert FakePDS.record(pds, second) == nil
      assert FakePDS.record(pds, elsewhere)
    end

    test "unfollow deletes every follow of the same account" do
      first = "at://#{@me}/app.bsky.graph.follow/a"
      second = "at://#{@me}/app.bsky.graph.follow/b"

      %{effects: effects, pds: pds} =
        pds(%{
          first => %{"subject" => "did:plc:other"},
          second => %{"subject" => "did:plc:other"}
        })

      assert {:ok, %{deleted: [^first, ^second]}} = AtMcp.Effects.unfollow(effects, first)
      assert FakePDS.record(pds, second) == nil
    end

    test "an undo of a record that is not there deletes nothing and says so" do
      %{effects: effects, pds: pds} = pds()
      gone = "at://#{@me}/app.bsky.feed.like/gone"

      assert {:ok, %{deleted: [], unchanged: true}} = AtMcp.Effects.unlike(effects, gone)
      assert writes(pds) == []
    end
  end

  describe "a deleted record reads as not found (#111)" do
    test "get_record, get_list and get_starter_pack name the uri and say it does not exist" do
      list = "at://#{@me}/app.bsky.graph.list/l"
      pack = "at://#{@me}/app.bsky.graph.starterpack/s"

      %{state: state} =
        pds(%{}, %{
          "app.bsky.graph.getList" =>
            {400, %{error: "InvalidRequest", message: "List not found"}},
          "app.bsky.graph.getStarterPack" =>
            {400, %{error: "InvalidRequest", message: "Starter pack not found"}}
        })

      for {name, args, uri} <- [
            {"get_record", %{"uri" => "at://#{@me}/app.bsky.feed.post/gone"},
             "at://#{@me}/app.bsky.feed.post/gone"},
            {"get_list", %{"uri" => list}, list},
            {"get_starter_pack", %{"uri" => pack}, pack}
          ] do
        result = call(state, name, args)
        assert result.isError
        assert %{code: "not_found", uri: ^uri} = result.structuredContent
        assert hd(result.content).text =~ "deleted, or never existed"
      end
    end

    test "any other refusal keeps its own code" do
      %{state: state} =
        pds(%{}, %{
          "app.bsky.graph.getList" => {400, %{error: "InvalidRequest", message: "Bad list uri"}}
        })

      result = call(state, "get_list", %{"uri" => "at://#{@me}/app.bsky.graph.list/l"})
      assert %{code: "upstream_rejected"} = result.structuredContent
    end
  end

  describe "update_seen (#112)" do
    test "a seen_at that does not parse is refused, naming it, and nothing is sent" do
      %{pds: pds, state: state} = pds()
      result = call(state, "update_seen", %{"seen_at" => "yesterday"})

      assert result.isError

      assert %{code: "invalid_arguments", problems: [%{path: "seen_at"}]} =
               result.structuredContent

      assert FakePDS.methods(pds) == []
    end

    test "a seen_at that parses is sent as given" do
      %{pds: pds, state: state} = pds()
      refute call(state, "update_seen", %{"seen_at" => "2026-01-01T12:00:00Z"})[:isError]

      assert [%{body: %{"seenAt" => "2026-01-01T12:00:00Z"}}] =
               FakePDS.sent(pds, "app.bsky.notification.updateSeen")
    end
  end

  describe "reply (#113)" do
    defp thread(reply_disabled) do
      pds(%{@post => %{"text" => "gated"}}, %{
        "app.bsky.feed.getPosts" =>
          {200, %{posts: [%{uri: @post, viewer: %{replyDisabled: reply_disabled}}]}}
      })
    end

    test "a reply the thread's rule excludes is refused, naming the gate, and nothing is written or counted" do
      %{effects: effects, pds: pds, state: state} = thread(true)
      result = call(state, "reply", %{"uri" => @post, "text" => "replying anyway"})

      assert result.isError
      assert %{code: "reply_disabled", uri: @post} = result.structuredContent
      assert hd(result.content).text =~ "reply rule"
      assert writes(pds) == []
      assert AtMcp.Effects.quota_status(effects).used == 0
    end

    test "a reply the rule allows is written" do
      %{pds: pds, state: state} = thread(false)
      refute call(state, "reply", %{"uri" => @post, "text" => "allowed"})[:isError]
      assert writes(pds) == ["com.atproto.repo.createRecord"]
    end
  end
end
