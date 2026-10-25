defmodule AtMcp.TownRelationshipsTest do
  use ExUnit.Case, async: false
  alias AtMcp.Effects.ProtoRune, as: Backend
  alias AtMcp.Test.FakePDS

  setup do
    previous = Application.fetch_env(:at_mcp, :network)
    Application.put_env(:at_mcp, :network, :delve)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:at_mcp, :network, value)
        :error -> Application.delete_env(:at_mcp, :network)
      end
    end)
  end

  test "shared Follow and Block work without an activation service" do
    {session, pds} =
      FakePDS.start(answers: %{"town.delve.identity.getState" => {503, %{error: "Unavailable"}}})

    for action <- [:follow, :block] do
      assert {:ok, result} = apply(Backend, action, [session, "did:plc:other"])
      assert result.uri =~ "/app.bsky.graph.#{action}/"
    end

    refute "town.delve.identity.getState" in FakePDS.methods(pds)
  end

  for {action, kind} <- [unfollow: :follow, unblock: :block] do
    test "#{action} removes all shared and legacy duplicates without AppView state" do
      kind = unquote(kind)

      uris =
        for ns <- ["app.bsky", "town.delve"],
            key <- ["one", "two"],
            do: "at://did:plc:self/#{ns}.graph.#{kind}/#{key}"

      other = "at://did:plc:self/app.bsky.graph.#{kind}/other"

      records =
        Map.new(uris, &{&1, %{"subject" => "did:plc:other"}})
        |> Map.put(other, %{"subject" => "did:plc:keep"})

      {session, pds} = FakePDS.start(records: records)

      assert {:ok, prepared} =
               Backend.prepare_undo(
                 session,
                 unquote(action),
                 "at://did:plc:self/app.bsky.graph.#{kind}/one"
               )

      assert Enum.sort(prepared.deleted) == Enum.sort(uris)
      assert Enum.all?(prepared.records, &is_binary(&1.cid))
      assert {:ok, _} = Backend.undo(session, prepared)
      for uri <- uris, do: assert(FakePDS.record(pds, uri) == nil)
      assert FakePDS.record(pds, other) == records[other]
      assert [%{body: body}] = FakePDS.sent(pds, "com.atproto.repo.applyWrites")
      assert body["swapCommit"] == prepared.commit
      refute "town.delve.actor.getProfile" in FakePDS.methods(pds)
    end
  end

  test "prepared removal refuses a changed root and preserves another account binding" do
    uri = "at://did:plc:self/town.delve.graph.follow/one"
    {session, pds} = FakePDS.start(records: %{uri => %{"subject" => "did:plc:other"}})
    assert {:ok, prepared} = Backend.prepare_undo(session, :unfollow, uri)

    assert {:error, %{kind: :refused}} =
             Backend.undo(%{session | did: "did:plc:another"}, prepared)

    assert FakePDS.sent(pds, "com.atproto.repo.applyWrites") == []
    assert {:ok, _} = Backend.follow(session, "did:plc:third")
    assert {:error, %{kind: :refused}} = Backend.undo(session, prepared)
    assert FakePDS.record(pds, uri) != nil
  end

  test "inventory traverses pages and refuses oversized atomic removal without partial deletion" do
    for count <- [105, 201] do
      records =
        Map.new(1..count, fn n ->
          {"at://did:plc:self/app.bsky.graph.follow/#{n}", %{"subject" => "did:plc:other"}}
        end)

      uri = "at://did:plc:self/app.bsky.graph.follow/1"
      {session, pds} = FakePDS.start(records: records)

      if count == 105 do
        assert {:ok, prepared} = Backend.prepare_undo(session, :unfollow, uri)
        assert length(prepared.records) == count
        assert {:ok, _} = Backend.undo(session, prepared)
      else
        assert {:error, %{kind: :refused, message: message}} =
                 Backend.prepare_undo(session, :unfollow, uri)

        assert message =~ "too many"
        assert FakePDS.sent(pds, "com.atproto.repo.applyWrites") == []
        for {key, value} <- records, do: assert(FakePDS.record(pds, key) == value)
      end
    end
  end

  test "unacknowledged removal retains its original prepared destinations and is sent once" do
    uri = "at://did:plc:self/town.delve.graph.block/one"

    {session, pds} =
      FakePDS.start(
        records: %{uri => %{"subject" => "did:plc:other"}},
        answers: %{"com.atproto.repo.applyWrites" => {503, %{error: "Unavailable"}}}
      )

    assert {:ok, prepared} = Backend.prepare_undo(session, :unblock, uri)
    assert {:error, %{kind: :indeterminate}} = Backend.undo(session, prepared)
    assert [%{body: body}] = FakePDS.sent(pds, "com.atproto.repo.applyWrites")
    assert body["repo"] == prepared.repo
    assert body["swapCommit"] == prepared.commit

    assert [%{"collection" => "town.delve.graph.block", "rkey" => "one"}] =
             Enum.map(body["writes"], &Map.take(&1, ["collection", "rkey"]))
  end
end
