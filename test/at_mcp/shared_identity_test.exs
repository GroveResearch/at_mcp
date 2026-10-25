defmodule AtMcp.SharedIdentityTest do
  use ExUnit.Case, async: false
  alias AtMcp.Effects.ProtoRune, as: Backend
  alias AtMcp.Test.FakePDS

  @state "town.delve.identity.getState"
  @shared "at://did:plc:self/app.bsky.actor.profile/self"
  @local "at://did:plc:self/town.delve.actor.profile/self"
  @records %{
    @shared => %{
      "$type" => "app.bsky.actor.profile",
      "displayName" => "Shared",
      "display_name" => "foreign spelling",
      "foreign_key" => %{"nested_key" => 1}
    },
    @local => %{
      "$type" => "town.delve.actor.profile",
      "displayName" => "Legacy",
      "pinnedPost" => %{"uri" => "at://did:plc:self/town.delve.feed.post/p", "cid" => "cid"},
      "labels" => %{"values" => [%{"val" => "bot"}]}
    }
  }

  setup do
    previous = Application.fetch_env(:at_mcp, :network)
    Application.put_env(:at_mcp, :network, :delve)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:at_mcp, :network, value)
        :error -> Application.delete_env(:at_mcp, :network)
      end
    end)

    :ok
  end

  test "two accounts use shared relationships regardless of activation changes" do
    {first, pds} =
      FakePDS.start(answers: %{@state => [{200, %{activated: false}}, {200, %{activated: true}}]})

    {second, other} = FakePDS.start()
    assert {:ok, _} = Backend.follow(first, "did:plc:other")
    assert {:ok, _} = Backend.block(first, "did:plc:other")
    assert {:ok, _} = Backend.block(second, "did:plc:other")

    assert Enum.map(FakePDS.sent(pds, "com.atproto.repo.createRecord"), & &1.body["collection"]) ==
             ["app.bsky.graph.follow", "app.bsky.graph.block"]

    assert [write] = FakePDS.sent(other, "com.atproto.repo.createRecord")
    assert write.body["collection"] == "app.bsky.graph.block"
    assert AtMcp.Network.collection(:post) == "town.delve.feed.post"
    assert FakePDS.sent(pds, @state) == []
    assert FakePDS.sent(other, @state) == []
  end

  test "an uncertain relationship write is sent once to the shared collection" do
    for operation <- [:follow, :block] do
      {session, pds} =
        FakePDS.start(
          answers: %{
            "com.atproto.repo.createRecord" => {503, %{error: "Unavailable"}},
            @state => {200, %{activated: false}}
          }
        )

      assert {:error, %{kind: :indeterminate}} =
               apply(Backend, operation, [session, "did:plc:other"])

      assert [write] = FakePDS.sent(pds, "com.atproto.repo.createRecord")
      assert write.body["collection"] == "app.bsky.graph.#{operation}"
      assert write.body["repo"] == session.did
      assert FakePDS.sent(pds, @state) == []
    end
  end

  test "an unreadable activation answer is unrelated to a shared relationship write" do
    for answer <- [{200, %{}}, {503, %{error: "Unavailable", message: "later"}}] do
      {session, pds} = FakePDS.start(answers: %{@state => answer})
      assert {:ok, _} = Backend.follow(session, "did:plc:other")
      assert {:ok, _} = Backend.block(session, "did:plc:other")
      assert length(FakePDS.sent(pds, "com.atproto.repo.createRecord")) == 2
      assert FakePDS.sent(pds, @state) == []
    end
  end

  test "partial Town Save retains displayed shared basics and Town metadata without editing shared profile" do
    {session, pds} =
      FakePDS.start(
        records: @records,
        answers: %{
          "town.delve.actor.getProfile" =>
            {200, %{profileSource: %{uri: @shared, cid: FakePDS.cid(@shared)}}}
        }
      )

    effects =
      start_supervised!(
        {AtMcp.Effects,
         backend: Backend, backend_state: session, write_quota: AtMcp.Test.QuotaFixture.quota(10)}
      )

    assert {:ok, %{value: displayed}} = AtMcp.Effects.get_own_profile(effects)
    assert displayed["displayName"] == "Shared"

    assert {:ok, %{uri: @local}} =
             AtMcp.Effects.update_profile(effects,
               description: "Town biography",
               banner: %{data: "png", mime_type: "image/png"}
             )

    assert [%{body: body}] = FakePDS.sent(pds, "com.atproto.repo.applyWrites")
    assert is_binary(body["swapCommit"])
    assert ["town.delve.actor.profile"] == Enum.map(body["writes"], & &1["collection"])
    assert FakePDS.record(pds, @shared) == @records[@shared]
    local = FakePDS.record(pds, @local)
    assert local["displayName"] == "Shared"
    assert local["description"] == "Town biography"
    assert local["presentation"] == true
    assert local["pinnedPost"] == @records[@local]["pinnedPost"]
    assert local["labels"] == @records[@local]["labels"]
    assert local["banner"]["mimeType"] == "image/png"
    refute Map.has_key?(local, "foreign_key")
    assert FakePDS.sent(pds, @state) == []
  end

  test "marked Town blanks and absent avatar are kept despite a newer shared profile" do
    records =
      Map.put(@records, @local, %{
        "$type" => "town.delve.actor.profile",
        "presentation" => true,
        "displayName" => "",
        "foreign_key" => 7
      })

    {session, pds} = FakePDS.start(records: records)
    assert {:ok, %{value: before}} = Backend.get_own_profile(session)
    assert before["displayName"] == ""
    assert {:ok, _} = Backend.update_profile(session, description: "")
    local = FakePDS.record(pds, @local)
    assert local["displayName"] == ""
    refute Map.has_key?(local, "description")
    refute Map.has_key?(local, "avatar")
    assert local["foreign_key"] == 7
    assert FakePDS.record(pds, @shared) == records[@shared]
    assert FakePDS.sent(pds, "town.delve.actor.getProfile") == []
  end

  test "the selected raw avatar and old Town presentation survive a partial edit" do
    avatar = %{
      "$type" => "blob",
      "ref" => %{"$link" => "original-avatar"},
      "mimeType" => "image/png",
      "size" => 3
    }

    records = put_in(@records, [@local, "avatar"], avatar)

    {session, pds} =
      FakePDS.start(
        records: records,
        answers: %{
          "town.delve.actor.getProfile" =>
            {200, %{profileSource: %{uri: @local, cid: FakePDS.cid(@local)}}}
        }
      )

    assert {:ok, _} = Backend.update_profile(session, description: "Edited")
    assert FakePDS.record(pds, @local)["avatar"] == avatar
    assert FakePDS.record(pds, @local)["displayName"] == "Legacy"
    assert FakePDS.record(pds, @shared) == records[@shared]
  end

  test "an absent displayed source does not revive stale unmarked Town basics" do
    {session, pds} =
      FakePDS.start(
        records: %{@local => @records[@local]},
        answers: %{
          "town.delve.actor.getProfile" => {200, %{did: "did:plc:self"}}
        }
      )

    assert {:ok, _} = Backend.update_profile(session, description: "First intentional Save")
    local = FakePDS.record(pds, @local)
    refute Map.has_key?(local, "displayName")
    assert local["presentation"] == true
    assert local["pinnedPost"] == @records[@local]["pinnedPost"]
  end

  test "a stale source CID refuses before upload or profile write" do
    {session, pds} =
      FakePDS.start(
        records: @records,
        answers: %{
          "town.delve.actor.getProfile" => {200, %{profileSource: %{uri: @shared, cid: "stale"}}}
        }
      )

    assert {:error, %{kind: :refused}} =
             Backend.update_profile(session, avatar: %{data: "png", mime_type: "image/png"})

    assert FakePDS.sent(pds, "com.atproto.repo.uploadBlob") == []
    assert FakePDS.sent(pds, "com.atproto.repo.applyWrites") == []
  end

  test "unsupported Town profile links are refused before any write or upload" do
    {session, pds} = FakePDS.start(answers: %{@state => {200, %{activated: true}}})

    assert {:error, %{kind: :refused}} =
             Backend.update_profile(session, display_name: "New", links: [])

    assert FakePDS.sent(pds, "com.atproto.repo.applyWrites") == []
    assert FakePDS.sent(pds, "com.atproto.repo.uploadBlob") == []
  end

  test "a refused or uncertain Town profile write is never reported as success or retried" do
    for {status, error, kind} <- [
          {400, "InvalidSwap", :refused},
          {503, "Unavailable", :indeterminate}
        ] do
      {session, pds} =
        FakePDS.start(
          records: @records,
          answers: %{
            @state => {200, %{activated: true}},
            "com.atproto.repo.applyWrites" =>
              {status, %{error: error, message: "not acknowledged"}}
          }
        )

      assert {:error, %{kind: ^kind}} = Backend.update_profile(session, display_name: "New")
      assert [_] = FakePDS.sent(pds, "com.atproto.repo.applyWrites")
      assert FakePDS.record(pds, @shared) == @records[@shared]
    end
  end

  test "Bluesky profile writes keep their existing path and do not ask Town for authority" do
    Application.put_env(:at_mcp, :network, :bluesky)
    {session, pds} = FakePDS.start(records: @records)
    assert {:ok, _} = Backend.update_profile(session, display_name: "New")
    assert [_] = FakePDS.sent(pds, "com.atproto.repo.putRecord")
    assert FakePDS.sent(pds, @state) == []
  end
end
