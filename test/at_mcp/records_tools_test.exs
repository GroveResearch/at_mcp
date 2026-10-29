defmodule AtMcp.RecordsToolsTest do
  @moduledoc """
  `put_record` and `delete_record` write records of applications at_mcp has no
  tool for. What they refuse is refused before anything is read or sent, and
  before the write quota is charged. The round trip against the reference PDS
  is in test/e2e/round_trip_test.exs.
  """
  use ExUnit.Case, async: true

  setup do
    {:ok, effects} =
      AtMcp.Test.QuotaFixture.start_effects(backend: AtMcp.Test.MockBackend, quota_limit: 5)

    {:ok, _} = AtMcp.Effects.login(effects)
    %{state: %{effects: effects}, effects: effects}
  end

  defp call(state, name, arguments) do
    {:ok, result, ^state} = AtMcp.MCP.Server.handle_call_tool(name, arguments, state)
    result
  end

  test "a collection at_mcp writes with its own tools is refused, naming them", %{
    state: state,
    effects: effects
  } do
    for {collection, tool} <- [
          {"app.bsky.feed.post", "delete_post"},
          {"app.bsky.feed.like", "unlike"},
          {"app.bsky.graph.follow", "follow"},
          {"app.bsky.actor.profile", "update_profile"},
          {"app.bsky.graph.listitem", "add_to_list"},
          {"app.bsky.feed.threadgate", "set_post_interactions"},
          {"town.delve.feed.post", "post"}
        ] do
      for {name, args} <- [
            {"put_record", %{"collection" => collection, "record" => %{"text" => "x"}}},
            {"delete_record", %{"collection" => collection, "rkey" => "self"}}
          ] do
        result = call(state, name, args)
        assert result.isError, "#{name} #{collection}"
        assert result.structuredContent.code == "invalid_arguments"

        assert hd(result.content).text =~ tool,
               "#{name} #{collection}: #{hd(result.content).text}"
      end
    end

    assert AtMcp.Effects.quota_status(effects).used == 0
  end

  test "a record whose $type is another collection, or a malformed collection or key, is refused",
       %{state: state, effects: effects} do
    for args <- [
          %{
            "collection" => "sh.tangled.repo.issue",
            "record" => %{"$type" => "sh.tangled.repo.pull"}
          },
          %{"collection" => "not an nsid", "record" => %{}},
          %{"collection" => "sh.tangled", "record" => %{}},
          %{"collection" => "sh.tangled.repo.issue", "rkey" => "a/b", "record" => %{}},
          %{"collection" => "sh.tangled.repo.issue", "cid" => "bafy", "record" => %{}}
        ] do
      result = call(state, "put_record", args)
      assert result.isError, inspect(args)
      assert result.structuredContent.code == "invalid_arguments", inspect(result)
    end

    assert AtMcp.Effects.quota_status(effects).used == 0
  end

  test "the record reaches the backend with its keys as given and $type added" do
    {:ok, effects} =
      AtMcp.Test.QuotaFixture.start_effects(
        backend: AtMcp.Test.MockBackend,
        backend_state: %{mock: true, did: "did:plc:mock", test_pid: self()},
        logged_in: true
      )

    state = %{effects: effects}
    record = %{"title" => "t", "snake_case" => 1, "camelCase" => %{"nested_key" => true}}

    result =
      call(state, "put_record", %{"collection" => "sh.tangled.repo.issue", "record" => record})

    refute result[:isError], inspect(result)
    assert_received {:record_write, {:put, "sh.tangled.repo.issue", nil, sent, nil}}
    assert sent == Map.put(record, "$type", "sh.tangled.repo.issue")
    assert AtMcp.Effects.quota_status(effects).used == 1
  end

  test "put_record says whether the account's server checked the record against its lexicon" do
    {session, pds} = AtMcp.Test.FakePDS.start()

    effects =
      start_supervised!(
        {AtMcp.Effects,
         backend: AtMcp.Effects.ProtoRune,
         backend_state: session,
         write_quota: AtMcp.Test.QuotaFixture.quota(5)},
        id: make_ref()
      )

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        result =
          call(%{effects: effects}, "put_record", %{
            "collection" => "sh.tangled.repo.issue",
            "record" => %{"repo" => "did:plc:examplerepo", "title" => "t"}
          })

        refute result[:isError], hd(result.content).text
        assert result.structuredContent["validation_status"] == "unknown"
      end)

    refute log =~ "unvalidated"
    assert [_] = AtMcp.Test.FakePDS.sent(pds, "com.atproto.repo.createRecord")
  end

  # Tangled's issue lexicon, copied under test/fixtures/lexicons, names the
  # repository by its DID.
  test "the README's put_record example is a record Tangled's issue lexicon accepts" do
    readme = File.read!(Path.expand("../../README.md", __DIR__))

    [_, json] =
      Regex.run(
        ~r/To file an issue on a Tangled repository, an agent calls:\s+```json\n(.*?)```/s,
        readme
      )

    assert %{"collection" => "sh.tangled.repo.issue", "record" => record} = Jason.decode!(json)
    assert AtMcp.Test.Lexicon.problems(record, "sh.tangled.repo.issue") == []
  end
end
