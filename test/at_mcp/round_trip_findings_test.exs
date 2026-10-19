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
      like = "at://#{@me}/app.bsky.feed.like/l1"
      repost = "at://#{@me}/app.bsky.feed.repost/r1"

      %{effects: effects, pds: pds} =
        pds(%{like => like(@post), repost => like(@post)}, %{
          "app.bsky.feed.getPosts" =>
            {200, %{posts: [%{uri: @post, viewer: %{like: like, repost: repost}}]}}
        })

      assert {:ok, %{uri: ^like, unchanged: true}} =
               AtMcp.Effects.like(effects, @post, "bafysubject")

      assert {:ok, %{uri: ^repost, unchanged: true}} =
               AtMcp.Effects.repost(effects, @post, "bafysubject")

      assert writes(pds) == []
      assert AtMcp.Effects.quota_status(effects).used == 0
    end

    test "a like the AppView still names but the repository no longer holds, or holds for another subject, is written again" do
      gone = "at://#{@me}/app.bsky.feed.like/gone"
      other = "at://#{@me}/app.bsky.feed.like/other"

      for {named, records} <- [{gone, %{}}, {other, %{other => like(@other_post)}}] do
        %{effects: effects, pds: pds} =
          pds(records, %{
            "app.bsky.feed.getPosts" => {200, %{posts: [%{uri: @post, viewer: %{like: named}}]}}
          })

        assert {:ok, result} = AtMcp.Effects.like(effects, @post, "bafysubject")
        refute result[:unchanged]
        refute result.uri == named
        assert writes(pds) == ["com.atproto.repo.createRecord"]
      end
    end

    test "a post not liked yet is liked" do
      %{effects: effects, pds: pds} =
        pds(%{}, %{"app.bsky.feed.getPosts" => {200, %{posts: [%{uri: @post, viewer: %{}}]}}})

      assert {:ok, result} = AtMcp.Effects.like(effects, @post, "bafysubject")
      refute result[:unchanged]
      assert writes(pds) == ["com.atproto.repo.createRecord"]
    end

    test "a like or repost without a cid records the subject's current one from the same read" do
      %{pds: pds, state: state} =
        pds(%{}, %{
          "app.bsky.feed.getPosts" =>
            {200, %{posts: [%{uri: @post, cid: "bafycurrent", viewer: %{}}]}}
        })

      for tool <- ["like", "repost"] do
        result = call(state, tool, %{"uri" => @post})
        refute result[:isError]
        assert result.structuredContent["subject_cid"] == "bafycurrent"
      end

      assert [like, repost] = FakePDS.sent(pds, "com.atproto.repo.createRecord")
      assert like.body["record"]["subject"] == %{"uri" => @post, "cid" => "bafycurrent"}
      assert repost.body["record"]["subject"] == %{"uri" => @post, "cid" => "bafycurrent"}
      assert length(FakePDS.sent(pds, "app.bsky.feed.getPosts")) == 2
    end

    test "a cid that differs from the AppView's is checked against the record: refused naming the record's, or used when the record has it" do
      %{effects: effects, pds: pds, state: state} =
        pds(%{@post => %{"text" => "edited"}}, %{
          "app.bsky.feed.getPosts" =>
            {200, %{posts: [%{uri: @post, cid: "bafyappview", viewer: %{}}]}}
        })

      {:ok, %{cid: record_cid}} = AtMcp.Effects.get_record(effects, @post)
      refute record_cid == "bafyappview"

      result = call(state, "like", %{"uri" => @post, "cid" => "bafymiscopied"})
      assert result.isError

      assert %{code: "subject_cid_mismatch", cid: "bafymiscopied", current_cid: ^record_cid} =
               result.structuredContent

      assert hd(result.content).text =~ "the record's CID is #{record_cid}"
      assert writes(pds) == []

      # The AppView lags the record: the record's own CID is used as given.
      refute call(state, "like", %{"uri" => @post, "cid" => record_cid})[:isError]

      assert [%{body: %{"record" => %{"subject" => %{"cid" => ^record_cid}}}}] =
               FakePDS.sent(pds, "com.atproto.repo.createRecord")

      assert AtMcp.Effects.quota_status(effects).used == 0
    end

    test "a cid the AppView has is used without reading the record" do
      %{pds: pds, state: state} =
        pds(%{}, %{
          "app.bsky.feed.getPosts" =>
            {200, %{posts: [%{uri: @post, cid: "bafycurrent", viewer: %{}}]}}
        })

      refute call(state, "like", %{"uri" => @post, "cid" => "bafycurrent"})[:isError]
      assert writes(pds) == ["com.atproto.repo.createRecord"]
      assert FakePDS.sent(pds, "com.atproto.repo.getRecord") == []
    end

    test "without a cid, a subject the AppView has no view of is refused and nothing is sent" do
      %{pds: pds, state: state} = pds(%{}, %{"app.bsky.feed.getPosts" => {200, %{posts: []}}})

      result = call(state, "repost", %{"uri" => @post})
      assert result.isError
      assert %{code: "subject_cid_unknown", uri: @post} = result.structuredContent
      assert writes(pds) == []

      # A given cid cannot be checked there, and is used as given, as before.
      refute call(state, "repost", %{"uri" => @post, "cid" => "bafygiven"})[:isError]

      assert [%{body: %{"record" => %{"subject" => %{"cid" => "bafygiven"}}}}] =
               FakePDS.sent(pds, "com.atproto.repo.createRecord")
    end

    test "an account already followed or blocked answers the record it has, and nothing is sent" do
      follow = "at://#{@me}/app.bsky.graph.follow/f1"
      block = "at://#{@me}/app.bsky.graph.block/b1"

      %{effects: effects, pds: pds} =
        pds(
          %{follow => %{"subject" => "did:plc:other"}, block => %{"subject" => "did:plc:other"}},
          %{
            "app.bsky.actor.getProfile" =>
              {200, %{did: "did:plc:other", viewer: %{following: follow, blocking: block}}}
          }
        )

      assert {:ok, %{uri: ^follow, unchanged: true}} =
               AtMcp.Effects.follow(effects, "did:plc:other")

      assert {:ok, %{uri: ^block, unchanged: true}} =
               AtMcp.Effects.block(effects, "did:plc:other")

      assert writes(pds) == []
    end

    test "unlike deletes the like named and the one the AppView names for the same subject, in one commit" do
      named = "at://#{@me}/app.bsky.feed.like/a"
      viewed = "at://#{@me}/app.bsky.feed.like/b"
      elsewhere = "at://#{@me}/app.bsky.feed.like/c"

      %{pds: pds, state: state} =
        pds(%{named => like(@post), viewed => like(@post), elsewhere => like(@other_post)}, %{
          "app.bsky.feed.getPosts" => {200, %{posts: [%{uri: @post, viewer: %{like: viewed}}]}}
        })

      result = call(state, "unlike", %{"uri" => named})
      refute result[:isError], inspect(result)
      assert %{"deleted" => [^named, ^viewed]} = result.structuredContent
      assert writes(pds) == ["com.atproto.repo.applyWrites"]
      assert FakePDS.record(pds, named) == nil
      assert FakePDS.record(pds, viewed) == nil
      assert FakePDS.record(pds, elsewhere)
      # Nothing else of the collection is read.
      assert FakePDS.sent(pds, "com.atproto.repo.listRecords") == []
    end

    test "unfollow of the follow the AppView names deletes that one alone" do
      follow = "at://#{@me}/app.bsky.graph.follow/a"

      %{effects: effects, pds: pds} =
        pds(%{follow => %{"subject" => "did:plc:other"}}, %{
          "app.bsky.actor.getProfile" =>
            {200, %{did: "did:plc:other", viewer: %{following: follow}}}
        })

      assert {:ok, %{deleted: [^follow]}} = AtMcp.Effects.unfollow(effects, follow)
      assert writes(pds) == ["com.atproto.repo.deleteRecord"]
    end

    test "a record gone between the read and the commit: nothing was applied, and the result says so" do
      named = "at://#{@me}/app.bsky.feed.like/a"
      viewed = "at://#{@me}/app.bsky.feed.like/b"

      %{state: state} =
        pds(%{named => like(@post), viewed => like(@post)}, %{
          "app.bsky.feed.getPosts" => {200, %{posts: [%{uri: @post, viewer: %{like: viewed}}]}},
          "com.atproto.repo.applyWrites" =>
            {400, %{error: "RecordNotFound", message: "Could not find record"}}
        })

      result = call(state, "unlike", %{"uri" => named})
      assert result.isError
      assert hd(result.content).text =~ "nothing was applied"
    end

    test "an undo of a record that is not there deletes nothing and says it tells nothing about others" do
      %{effects: effects, pds: pds} = pds()
      gone = "at://#{@me}/app.bsky.feed.like/gone"

      assert {:ok, %{deleted: [], unchanged: true, note: note}} =
               AtMcp.Effects.unlike(effects, gone)

      assert note =~ "says nothing about other records of the same subject"
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
        assert hd(result.content).text =~ "deleted, taken down, or never existed"
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

    test "a parent the AppView rate-limits is not replied to, and nothing is written or counted" do
      %{effects: effects, pds: pds, state: state} =
        pds(%{@post => %{"text" => "gated"}}, %{
          "app.bsky.feed.getPosts" => {429, %{error: "RateLimitExceeded", message: "slow down"}}
        })

      result = call(state, "reply", %{"uri" => @post, "text" => "replying anyway"})
      assert result.isError
      assert %{code: "upstream_rate_limited"} = result.structuredContent
      assert hd(result.content).text =~ "reply rule"
      assert writes(pds) == []
      assert AtMcp.Effects.quota_status(effects).used == 0
    end

    test "a parent the AppView does not have is replied to" do
      %{pds: pds, state: state} =
        pds(%{@post => %{"text" => "not indexed"}}, %{
          "app.bsky.feed.getPosts" => {200, %{posts: []}}
        })

      refute call(state, "reply", %{"uri" => @post, "text" => "hello"})[:isError]
      assert writes(pds) == ["com.atproto.repo.createRecord"]
    end

    test "a reply the rule allows is written" do
      %{pds: pds, state: state} = thread(false)
      refute call(state, "reply", %{"uri" => @post, "text" => "allowed"})[:isError]
      assert writes(pds) == ["com.atproto.repo.createRecord"]
    end
  end
end
