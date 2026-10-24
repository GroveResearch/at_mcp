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

  test "two accounts and an activation change select their own follow/block collections without changing Town posts" do
    {shared, pds} =
      FakePDS.start(
        answers: %{
          @state => [
            {200, %{activated: false}},
            {200, %{activated: false}},
            {200, %{activated: true}}
          ]
        }
      )

    {legacy, other} = FakePDS.start()
    assert {:ok, _} = Backend.follow(shared, "did:plc:other")
    assert {:ok, _} = Backend.block(shared, "did:plc:other")
    assert {:ok, _} = Backend.block(legacy, "did:plc:other")

    assert Enum.map(FakePDS.sent(pds, "com.atproto.repo.createRecord"), & &1.body["collection"]) ==
             ["town.delve.graph.follow", "app.bsky.graph.block"]

    assert [write] = FakePDS.sent(other, "com.atproto.repo.createRecord")
    assert write.body["collection"] == "town.delve.graph.block"
    assert AtMcp.Network.collection(:post) == "town.delve.feed.post"

    for write <- FakePDS.sent(pds, "com.atproto.repo.createRecord"),
        do: assert(write.body["collection"] == write.body["record"]["$type"])

    refute "town.delve.identity.activate" in FakePDS.methods(pds)
  end

  test "an uncertain identity write retains its acknowledged record for reconciliation without retry" do
    for operation <- [:follow, :block, :update_profile],
        confirmation <- [{200, %{activated: true}}, {503, %{error: "Unavailable"}}] do
      {session, pds} =
        FakePDS.start(
          records: @records,
          answers: %{@state => [{200, %{activated: false}}, confirmation]}
        )

      argument =
        if operation == :update_profile, do: [display_name: "Changed"], else: "did:plc:other"

      assert {:error,
              %AtMcp.Effects.Failure{
                kind: :indeterminate,
                detail: {:identity_authority_unconfirmed, %{uri: uri, cid: cid}}
              } = failure} = apply(Backend, operation, [session, argument])

      assert FakePDS.record(pds, uri) != nil
      assert cid == FakePDS.cid(uri)

      writes =
        FakePDS.sent(pds, "com.atproto.repo.createRecord") ++
          FakePDS.sent(pds, "com.atproto.repo.putRecord")

      assert [_] = writes
      refute "town.delve.identity.activate" in FakePDS.methods(pds)

      assert {:ok, result, :state} =
               AtMcp.MCP.Tools.respond({:error, {:write_outcome_unknown, failure}}, :state)

      assert %{
               code: "write_outcome_unknown",
               outcome: "unknown",
               written: %{uri: ^uri, cid: ^cid}
             } = result.structuredContent

      assert hd(result.content).text =~ uri
    end
  end

  test "unknown authority refuses to dispatch any identity write" do
    for answer <- [{200, %{}}, {503, %{error: "Unavailable", message: "later"}}] do
      {session, pds} = FakePDS.start(answers: %{@state => answer})
      assert {:error, _} = Backend.follow(session, "did:plc:other")
      assert {:error, _} = Backend.update_profile(session, display_name: "Unsafe")
      assert FakePDS.sent(pds, "com.atproto.repo.createRecord") == []
      assert FakePDS.sent(pds, "com.atproto.repo.putRecord") == []
      assert FakePDS.sent(pds, "com.atproto.repo.applyWrites") == []
    end
  end

  test "shared profile basics and Town banner land in one guarded commit with foreign keys and local adjuncts intact" do
    {session, pds} =
      FakePDS.start(records: @records, answers: %{@state => {200, %{activated: true}}})

    assert {:ok, %{uri: @shared}} =
             Backend.update_profile(session,
               display_name: "New",
               banner: %{data: "png", mime_type: "image/png"}
             )

    assert [%{body: body}] = FakePDS.sent(pds, "com.atproto.repo.applyWrites")
    assert is_binary(body["swapCommit"])

    assert Enum.map(body["writes"], & &1["collection"]) == [
             "app.bsky.actor.profile",
             "town.delve.actor.profile"
           ]

    assert FakePDS.record(pds, @shared)["displayName"] == "New"
    assert FakePDS.record(pds, @shared)["display_name"] == "foreign spelling"
    assert FakePDS.record(pds, @shared)["foreign_key"] == %{"nested_key" => 1}
    local = FakePDS.record(pds, @local)
    assert local["displayName"] == "Legacy"
    assert local["pinnedPost"] == @records[@local]["pinnedPost"]
    assert local["labels"] == @records[@local]["labels"]
    assert local["banner"]["mimeType"] == "image/png"
    refute Map.has_key?(FakePDS.record(pds, @shared), "banner")
  end

  test "unsupported shared profile links are refused before any write or upload" do
    {session, pds} = FakePDS.start(answers: %{@state => {200, %{activated: true}}})

    assert {:error, %{kind: :refused}} =
             Backend.update_profile(session, display_name: "New", links: [])

    assert FakePDS.sent(pds, "com.atproto.repo.applyWrites") == []
    assert FakePDS.sent(pds, "com.atproto.repo.uploadBlob") == []
  end

  test "a refused or uncertain combined profile write is never reported as success or retried" do
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
