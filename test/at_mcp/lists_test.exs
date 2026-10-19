defmodule AtMcp.ListsTest do
  @moduledoc """
  Lists and starter packs (#89).

  The first part calls the tools through the MCP surface over the mock
  backend: what each refuses before anything is sent, and what a model reads.
  The second runs the real backend against a fake PDS on delve.town's
  namespace and checks what reached the wire and how the answer is read.
  """
  use ExUnit.Case, async: false

  alias AtMcp.Test.FakePDS

  defp mock do
    {:ok, effects} =
      AtMcp.Test.QuotaFixture.start_effects(
        backend: AtMcp.Test.MockBackend,
        backend_state: %{mock: true, did: "did:plc:mock", handle: "mock.test"},
        quota_limit: 1
      )

    %{effects: effects}
  end

  defp call(state, name, arguments) do
    {:ok, result, ^state} = AtMcp.MCP.Server.handle_call_tool(name, arguments, state)
    result
  end

  defp refused(result, path) do
    assert result.isError, inspect(result)
    assert %{code: "invalid_arguments", problems: [%{path: ^path}]} = result.structuredContent
    assert hd(result.content).text =~ "Nothing was sent"
    hd(result.content).text
  end

  @list "at://did:plc:mock/app.bsky.graph.list/l1"
  @pack "at://did:plc:mock/app.bsky.graph.starterpack/p1"

  describe "through the tools, over the mock backend" do
    test "get_starter_packs takes exactly one of actor, query and contains" do
      state = mock()

      assert refused(call(state, "get_starter_packs", %{}), "query") =~ "gave none"

      assert refused(
               call(state, "get_starter_packs", %{"actor" => "a.test", "query" => "q"}),
               "query"
             ) =~
               "gave actor and query"

      for args <- [%{"actor" => "a.test"}, %{"query" => "q"}, %{"contains" => "a.test"}] do
        refute call(state, "get_starter_packs", args)[:isError], inspect(args)
      end
    end

    test "get_lists with contains reads this account's own lists, so another actor is refused" do
      state = mock()

      assert refused(
               call(state, "get_lists", %{"actor" => "a.test", "contains" => "b.test"}),
               "actor"
             ) =~
               "leave actor out"

      for actor <- [nil, "mock.test", "did:plc:mock"] do
        args = Map.reject(%{"actor" => actor, "contains" => "b.test"}, &is_nil(elem(&1, 1)))
        result = call(state, "get_lists", args)
        assert %{"contains" => "b.test"} = result.structuredContent
        assert hd(result.content).text =~ "Does not contain the account"
      end

      # Without contains, the account itself is read when no actor is given.
      assert %{"actor" => "did:plc:mock", "purposes" => ["modlist"]} =
               call(state, "get_lists", %{"purpose" => "moderation"}).structuredContent
    end

    test "reads are text a model reads, with every uri a write tool takes" do
      state = mock()

      list = hd(call(state, "get_list", %{"uri" => @list}).content).text
      assert list =~ ~s(List "Mock list" · curate list · 1 account · by @mock.test)
      assert list =~ "uri: #{@list}"
      assert list =~ "[1] Alice (@alice.test)"
      assert list =~ "item: at://did:plc:mock/app.bsky.graph.listitem/i1"

      pack = hd(call(state, "get_starter_pack", %{"uri" => @pack}).content).text
      assert pack =~ ~s(Starter pack "Mock pack" · by @mock.test · 1 account)
      assert pack =~ ~s(Feeds: "F" · by @mock.test · at://did:plc:mock/app.bsky.feed.generator/f)
      assert pack =~ "Some of its accounts: Alice (@alice.test)"
      assert pack =~ "list: #{@list} (get_list reads every account)"
      assert pack =~ "uri: #{@pack}"

      packs = hd(call(state, "get_starter_packs", %{"contains" => "a.test"}).content).text
      assert packs =~ "1 starter pack."
      assert packs =~ "Does not contain the account"
    end
  end

  describe "on the wire" do
    setup do
      Application.put_env(:at_mcp, :network, :delve)
      on_exit(fn -> Application.delete_env(:at_mcp, :network) end)
      :ok
    end

    @mine "at://did:plc:self/town.delve.graph.list/l1"
    @alice "did:plc:alice"

    defp pds(answers) do
      {session, pds} = FakePDS.start(answers: answers)

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

    test "reads ask this network's methods, with the purpose the service takes" do
      %{effects: effects, pds: pds} =
        pds(%{
          "town.delve.graph.getLists" => {200, %{lists: []}},
          "town.delve.graph.getListsWithMembership" => {200, %{listsWithMembership: []}},
          "town.delve.graph.searchStarterPacksV2" => {200, %{starterPacks: []}},
          "town.delve.graph.getStarterPacksWithMembership" =>
            {200, %{starterPacksWithMembership: []}},
          "town.delve.graph.getActorStarterPacks" => {200, %{starterPacks: []}}
        })

      assert {:ok, %{count: 0}} = AtMcp.Effects.get_lists(effects, purpose: "curate")
      assert {:ok, %{count: 0}} = AtMcp.Effects.get_lists(effects, contains: "alice.test")
      assert {:ok, _} = AtMcp.Effects.get_starter_packs(effects, query: "agents")
      assert {:ok, _} = AtMcp.Effects.get_starter_packs(effects, contains: "alice.test")
      assert {:ok, _} = AtMcp.Effects.get_starter_packs(effects, actor: "alice.test")

      assert [%{query: %{"actor" => "did:plc:self", "purposes" => "curatelist"}}] =
               FakePDS.sent(pds, "town.delve.graph.getLists")

      assert [%{query: %{"actor" => "alice.test"}}] =
               FakePDS.sent(pds, "town.delve.graph.getListsWithMembership")

      assert [%{query: %{"q" => "agents"}}] =
               FakePDS.sent(pds, "town.delve.graph.searchStarterPacksV2")

      assert [_] = FakePDS.sent(pds, "town.delve.graph.getStarterPacksWithMembership")
      assert [_] = FakePDS.sent(pds, "town.delve.graph.getActorStarterPacks")
    end

    test "a list with its members reads as summaries, the purpose in the tools' words" do
      %{effects: effects} =
        pds(%{
          "town.delve.graph.getList" =>
            {200,
             %{
               list: %{
                 uri: @mine,
                 cid: "bafyl",
                 name: "Friends",
                 purpose: "town.delve.graph.defs#modlist",
                 creator: %{did: "did:plc:self", handle: "self.example"},
                 listItemCount: 1,
                 viewer: %{muted: true}
               },
               items: [
                 %{
                   uri: "at://did:plc:self/town.delve.graph.listitem/i1",
                   subject: %{did: @alice, handle: "alice.test", viewer: %{muted: true}}
                 }
               ],
               cursor: "next"
             }}
        })

      assert {:ok, page} = AtMcp.Effects.get_list(effects, @mine)
      assert %{purpose: "moderation", item_count: 1, viewer: %{muted: true}} = page.list

      assert [%{item_uri: "at://did:plc:self/town.delve.graph.listitem/i1", did: @alice} = member] =
               page.items

      assert member.viewer.muted == true
      assert page.cursor == "next"
    end
  end
end
