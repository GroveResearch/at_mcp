defmodule AtMcp.ListsTest do
  @moduledoc """
  Lists and starter packs (#89).

  The first part calls the tools through the MCP surface over the mock
  backend: what each refuses before anything is sent, and that none of them
  spends the write quota. The second runs the real backend against a fake PDS
  on delve.town's namespace and checks what reached the wire: each record
  matches its lexicon (`AtMcp.Test.Lexicon`), an edit keeps every field it
  does not change, and a deletion takes exactly the records it names.
  """
  use ExUnit.Case, async: false

  alias AtMcp.Test.FakePDS
  alias AtMcp.Test.Lexicon

  defp mock do
    {:ok, effects} =
      AtMcp.Test.QuotaFixture.start_effects(
        backend: AtMcp.Test.MockBackend,
        backend_state: %{mock: true, did: "did:plc:mock", handle: "mock.test"},
        quota_limit: 1
      )

    %{effects: effects}
  end

  # These tests are about what a program reads: a read's summary.
  defp call(state, name, arguments) do
    state = Map.put(state, :format, "json")
    {:ok, result, ^state} = AtMcp.MCP.Server.handle_call_tool(name, arguments, state)
    result
  end

  # What a model reads: a read's text, as it comes without format.
  defp text(state, name, arguments) do
    {:ok, result, ^state} = AtMcp.MCP.Server.handle_call_tool(name, arguments, state)
    hd(result.content).text
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
    test "a list or starter pack in another account's repository is refused by naming the argument" do
      state = mock()
      theirs = "at://did:plc:other/app.bsky.graph.list/l1"
      their_pack = "at://did:plc:other/app.bsky.graph.starterpack/p1"

      for {name, args, path} <- [
            {"update_list", %{"uri" => theirs, "name" => "n"}, "uri"},
            {"delete_list", %{"uri" => theirs}, "uri"},
            {"add_to_list", %{"list" => theirs, "actor" => "a.test"}, "list"},
            {"remove_from_list", %{"list" => their_pack, "actor" => "a.test"}, "list"},
            {"update_starter_pack", %{"uri" => their_pack, "name" => "n"}, "uri"},
            {"delete_starter_pack", %{"uri" => their_pack}, "uri"}
          ] do
        assert refused(call(state, name, args), path) =~ "did:plc:other is another account", name
      end
    end

    test "this account's list is taken by its DID or its handle" do
      state = mock()

      for repo <- ["did:plc:mock", "mock.test"] do
        result =
          call(state, "add_to_list", %{
            "list" => "at://#{repo}/app.bsky.graph.list/l1",
            "actor" => "@alice.test"
          })

        refute result[:isError], inspect(result)
        # The list is named in DID form, as the list item record names it.
        assert %{"list" => @list, "actor" => "did:plc:alice.test"} = result.structuredContent
      end
    end

    test "a uri of the wrong kind is refused for every tool that takes one" do
      state = mock()
      post = "at://did:plc:mock/app.bsky.feed.post/1"

      for {name, args, path} <- [
            {"update_list", %{"uri" => @pack, "name" => "n"}, "uri"},
            {"delete_list", %{"uri" => post}, "uri"},
            {"add_to_list", %{"list" => post, "actor" => "a.test"}, "list"},
            {"remove_from_list", %{"list" => "not-a-uri", "actor" => "a.test"}, "list"},
            {"update_starter_pack", %{"uri" => @list, "name" => "n"}, "uri"},
            {"delete_starter_pack", %{"uri" => @list}, "uri"},
            {"set_list_opt_out", %{"list" => post, "opted_out" => true}, "list"},
            {"create_starter_pack", %{"name" => "n", "feeds" => [post]}, "feeds"}
          ] do
        refused(call(state, name, args), path)
      end
    end

    test "a name or description longer than the lexicon allows is refused before anything is sent" do
      state = mock()

      assert refused(
               call(state, "create_list", %{
                 "name" => String.duplicate("x", 65),
                 "purpose" => "curate"
               }),
               "name"
             ) =~ "at most 64 bytes"

      refused(call(state, "create_list", %{"name" => "", "purpose" => "curate"}), "name")

      assert refused(
               call(state, "create_starter_pack", %{"name" => String.duplicate("é", 51)}),
               "name"
             ) =~ "at most 50 characters"

      assert refused(
               call(state, "update_list", %{
                 "uri" => @list,
                 "description" => String.duplicate("x", 301)
               }),
               "description"
             ) =~ "at most 300 characters"

      refused(call(state, "update_list", %{"uri" => @list}), "name")
    end

    test "a list avatar is a PNG or JPEG" do
      state = mock()

      result =
        call(state, "create_list", %{
          "name" => "n",
          "purpose" => "curate",
          "avatar" => %{"data" => Base.encode64("GIF89a"), "mime_type" => "image/gif"}
        })

      assert refused(result, "avatar") =~ "image/png or image/jpeg"
    end

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
        assert text(state, "get_lists", args) =~ "Does not contain the account"
      end

      # Without contains, the account itself is read when no actor is given.
      assert %{"actor" => "did:plc:mock", "purposes" => ["modlist"]} =
               call(state, "get_lists", %{"purpose" => "moderation"}).structuredContent
    end

    test "none of them spends the write quota" do
      %{effects: effects} = state = mock()
      assert {:ok, _} = AtMcp.Effects.post(effects, "spends the only write")

      for {name, args} <- [
            {"create_list", %{"name" => "n", "purpose" => "moderation"}},
            {"update_list", %{"uri" => @list, "description" => ""}},
            {"add_to_list", %{"list" => @pack, "actor" => "a.test"}},
            {"remove_from_list", %{"list" => @list, "actor" => "a.test"}},
            {"delete_list", %{"uri" => @list}},
            {"create_starter_pack", %{"name" => "n", "actors" => ["a.test"]}},
            {"update_starter_pack", %{"uri" => @pack, "feeds" => []}},
            {"delete_starter_pack", %{"uri" => @pack}},
            {"set_list_opt_out", %{"list" => @pack, "opted_out" => false}}
          ] do
        refute call(state, name, args)[:isError], name
      end

      assert AtMcp.Effects.quota_status(effects).used == 1
    end

    test "reads are text a model reads, with every uri a write tool takes" do
      state = mock()

      list = text(state, "get_list", %{"uri" => @list})
      assert list =~ ~s(List "Mock list" · curate list · 1 account · by @mock.test)
      assert list =~ "uri: #{@list}"
      assert list =~ ~s|[1] "Alice" (@alice.test)|
      assert list =~ "item: at://did:plc:mock/app.bsky.graph.listitem/i1"

      pack = text(state, "get_starter_pack", %{"uri" => @pack})
      assert pack =~ ~s(Starter pack "Mock pack" · by @mock.test · 1 account)
      assert pack =~ ~s(Feeds: "F" · by @mock.test · at://did:plc:mock/app.bsky.feed.generator/f)
      assert pack =~ ~s|Some of its accounts: "Alice" (@alice.test)|
      assert pack =~ "list: #{@list} (get_list reads every account)"
      assert pack =~ "uri: #{@pack}"

      packs = text(state, "get_starter_packs", %{"contains" => "a.test"})
      assert packs =~ "1 starter pack."
      assert packs =~ "Does not contain the account"
    end
  end

  test "the free-text limits are the lexicon's" do
    defs = fn nsid ->
      (Path.join(["test/fixtures/lexicons" | String.split(nsid, ".")]) <> ".json")
      |> File.read!()
      |> Jason.decode!()
      |> get_in(["defs", "main", "record", "properties"])
    end

    limits = AtMcp.Effects.text_limits()
    list = defs.("app.bsky.graph.list")
    pack = defs.("app.bsky.graph.starterpack")

    assert limits.list_name ==
             {list["name"]["minLength"], list["name"]["maxLength"], list["name"]["maxGraphemes"]}

    assert limits.pack_name ==
             {pack["name"]["minLength"], pack["name"]["maxLength"], pack["name"]["maxGraphemes"]}

    for description <- [list["description"], pack["description"]] do
      assert limits.description ==
               {0, description["maxLength"], description["maxGraphemes"]}
    end

    assert pack["feeds"]["maxLength"] == 3
  end

  describe "on the wire" do
    setup do
      Application.put_env(:at_mcp, :network, :delve)
      on_exit(fn -> Application.delete_env(:at_mcp, :network) end)
      :ok
    end

    @mine "at://did:plc:self/town.delve.graph.list/l1"
    @other_list "at://did:plc:self/town.delve.graph.list/l2"
    @pack_list "at://did:plc:self/town.delve.graph.list/pl"
    @my_pack "at://did:plc:self/town.delve.graph.starterpack/p1"
    @alice "did:plc:alice"

    @records %{
      @mine => %{
        "$type" => "town.delve.graph.list",
        "purpose" => "town.delve.graph.defs#curatelist",
        "name" => "Friends",
        "description" => "people @alice.test likes",
        "descriptionFacets" => [
          %{
            "index" => %{"byteStart" => 7, "byteEnd" => 18},
            "features" => [
              %{"$type" => "town.delve.richtext.facet#mention", "did" => "did:plc:alice"}
            ]
          }
        ],
        "createdAt" => "2026-10-01T00:00:00.000Z"
      },
      @other_list => %{
        "$type" => "town.delve.graph.list",
        "purpose" => "town.delve.graph.defs#modlist",
        "name" => "Spam",
        "createdAt" => "2026-10-01T00:00:00.000Z"
      },
      @pack_list => %{
        "$type" => "town.delve.graph.list",
        "purpose" => "town.delve.graph.defs#referencelist",
        "name" => "Agents",
        "createdAt" => "2026-10-01T00:00:00.000Z"
      },
      @my_pack => %{
        "$type" => "town.delve.graph.starterpack",
        "name" => "Agents",
        "list" => @pack_list,
        "feeds" => [%{"uri" => "at://did:plc:f/town.delve.feed.generator/a"}],
        "createdAt" => "2026-10-01T00:00:00.000Z"
      }
    }

    defp item(rkey, list, subject),
      do:
        {"at://did:plc:self/town.delve.graph.listitem/#{rkey}",
         %{
           "$type" => "town.delve.graph.listitem",
           "subject" => subject,
           "list" => list,
           "createdAt" => "2026-10-01T00:00:00.000Z"
         }}

    # The account's list items: two putting alice on the list (a duplicate the
    # AppView ignores), bob on it, alice on another list, two on the pack's.
    @items [
      {"i1", @mine, @alice},
      {"i2", @mine, "did:plc:bob"},
      {"i3", @other_list, @alice},
      {"i4", @mine, @alice},
      {"i5", @pack_list, @alice},
      {"i6", @pack_list, "did:plc:bob"}
    ]

    defp pds(answers \\ %{}, records \\ %{}) do
      items = Map.new(@items, fn {rkey, list, subject} -> item(rkey, list, subject) end)

      defaults = %{
        "com.atproto.identity.resolveHandle" => {200, %{did: @alice}}
      }

      {session, pds} =
        FakePDS.start(
          records: @records |> Map.merge(items) |> Map.merge(records),
          answers: Map.merge(defaults, answers)
        )

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

    # The one putRecord a call sent: it replaces only the record read, and the
    # record matches its lexicon.
    defp put(pds, uri) do
      assert [%{body: body}] = FakePDS.sent(pds, "com.atproto.repo.putRecord")
      assert body["swapRecord"] == FakePDS.cid(uri)
      nsid = String.replace_prefix(body["collection"], "town.delve.", "app.bsky.")
      assert Lexicon.problems(body["record"], nsid) == []
      body["record"]
    end

    # The one applyWrites a call sent: its input matches the lexicon, and so
    # does every record in it.
    defp committed(pds) do
      assert [%{body: body}] = FakePDS.sent(pds, "com.atproto.repo.applyWrites")
      assert body["repo"] == "did:plc:self"
      # The fake PDS refuses a swapCommit that is not its current commit.
      assert body["swapCommit"] == nil or is_binary(body["swapCommit"])
      assert Lexicon.problems(body, "com.atproto.repo.applyWrites") == []

      for %{"value" => value, "collection" => collection} <- body["writes"] do
        assert value["$type"] == collection
        nsid = String.replace_prefix(collection, "town.delve.", "app.bsky.")
        assert Lexicon.problems(value, nsid) == [], inspect(value)
      end

      body["writes"]
    end

    defp deleted(writes) do
      for %{"$type" => "com.atproto.repo.applyWrites#delete"} = w <- writes,
          do: "at://did:plc:self/#{w["collection"]}/#{w["rkey"]}"
    end

    test "create_list writes one list record of this network's purpose" do
      %{effects: effects, pds: pds} = pds()

      assert {:ok, result} =
               AtMcp.Effects.create_list(effects, %{
                 name: "Friends",
                 purpose: "curate",
                 description: "people"
               })

      assert [%{"$type" => "com.atproto.repo.applyWrites#create", "value" => list} = write] =
               committed(pds)

      assert %{
               "$type" => "town.delve.graph.list",
               "purpose" => "town.delve.graph.defs#curatelist",
               "name" => "Friends",
               "description" => "people"
             } = list

      assert result.uri == "at://did:plc:self/town.delve.graph.list/#{write["rkey"]}"
      assert result.purpose == "curate"
      assert is_binary(result.cid)
      assert FakePDS.record(pds, result.uri) == list
    end

    test "update_list keeps every field it does not change" do
      %{effects: effects, pds: pds} = pds()

      assert {:ok, %{uri: @mine}} =
               AtMcp.Effects.update_list(effects, @mine, %{name: "Old friends"})

      list = put(pds, @mine)
      assert list == Map.put(@records[@mine], "name", "Old friends")
      assert FakePDS.sent(pds, "com.atproto.repo.applyWrites") == []
    end

    test "a new description drops the facets that indexed the old one; an empty one removes both" do
      for {description, expected} <- [{"new words", "new words"}, {"", nil}] do
        %{effects: effects, pds: pds} = pds()
        assert {:ok, _} = AtMcp.Effects.update_list(effects, @mine, %{description: description})
        list = put(pds, @mine)

        assert list["description"] == expected
        refute Map.has_key?(list, "descriptionFacets")
        assert list["purpose"] == "town.delve.graph.defs#curatelist"
      end
    end

    test "delete_list deletes the list and its items, and nothing on another list" do
      %{effects: effects, pds: pds} = pds()

      assert {:ok, %{uri: @mine, deleted: deleted}} = AtMcp.Effects.delete_list(effects, @mine)

      items = for rkey <- ~w(i1 i2 i4), do: "at://did:plc:self/town.delve.graph.listitem/#{rkey}"
      assert deleted == items ++ [@mine]
      assert deleted(committed(pds)) == items ++ [@mine]
      assert FakePDS.record(pds, @mine) == nil
    end

    test "a list too large for one commit is deleted in commits of 200, the list itself last" do
      many = Map.new(1..250, &item("m#{&1}", @mine, "did:plc:m#{&1}"))
      %{effects: effects, pds: pds} = pds(%{}, many)

      assert {:ok, %{deleted: deleted}} = AtMcp.Effects.delete_list(effects, @mine)
      # The three in @items, and these.
      assert length(deleted) == 254

      assert [first, second] =
               for(
                 call <- FakePDS.sent(pds, "com.atproto.repo.applyWrites"),
                 do: call.body["writes"]
               )

      assert {length(first), length(second)} == {200, 54}
      assert List.last(deleted(second)) == @mine
    end

    test "delete_list refuses a starter pack's list, which goes with its pack" do
      %{effects: effects, pds: pds} = pds()

      assert {:error, {:invalid_argument, "uri", message}} =
               AtMcp.Effects.delete_list(effects, @pack_list)

      assert message =~ "delete_starter_pack"
      assert FakePDS.sent(pds, "com.atproto.repo.applyWrites") == []
    end

    test "a list that is not there is refused, and nothing is sent" do
      %{effects: effects, pds: pds} = pds()
      gone = "at://did:plc:self/town.delve.graph.list/gone"

      assert {:error, {:invalid_argument, "list", message}} =
               AtMcp.Effects.add_to_list(effects, gone, @alice)

      assert message =~ "no list at #{gone} could be read"
      assert FakePDS.sent(pds, "com.atproto.repo.applyWrites") == []
    end

    test "add_to_list resolves a handle and writes a list item naming the list" do
      %{effects: effects, pds: pds} = pds()
      new = "did:plc:carol"

      assert {:ok, result} = AtMcp.Effects.add_to_list(effects, @mine, new)
      assert [%{"value" => item, "rkey" => rkey}] = committed(pds)

      assert %{"$type" => "town.delve.graph.listitem", "subject" => ^new, "list" => @mine} = item
      assert result.uri == "at://did:plc:self/town.delve.graph.listitem/#{rkey}"
      assert %{list: @mine, actor: ^new} = result

      # By handle, through the starter pack: its list is the one written to.
      %{effects: effects, pds: pds} =
        pds(%{"com.atproto.identity.resolveHandle" => {200, %{did: new}}})

      assert {:ok, %{list: @pack_list, actor: ^new}} =
               AtMcp.Effects.add_to_list(effects, @my_pack, "carol.test")

      assert [%{"value" => %{"list" => @pack_list, "subject" => ^new}}] = committed(pds)
    end

    test "add_to_list leaves an account already on the list as it is" do
      %{effects: effects, pds: pds} = pds()

      assert {:ok, %{unchanged: true, uri: "at://did:plc:self/town.delve.graph.listitem/i1"}} =
               AtMcp.Effects.add_to_list(effects, @mine, "alice.test")

      assert FakePDS.sent(pds, "com.atproto.repo.applyWrites") == []
    end

    test "remove_from_list deletes every item that puts the account on that list" do
      %{effects: effects, pds: pds} = pds()

      assert {:ok, result} = AtMcp.Effects.remove_from_list(effects, @mine, "alice.test")

      items = for rkey <- ~w(i1 i4), do: "at://did:plc:self/town.delve.graph.listitem/#{rkey}"
      assert deleted(committed(pds)) == items
      assert %{uri: "at://did:plc:self/town.delve.graph.listitem/i1", deleted: ^items} = result
    end

    test "remove_from_list refuses an account that is not on the list, naming it" do
      %{effects: effects, pds: pds} = pds()

      assert {:error, {:invalid_argument, "actor", message}} =
               AtMcp.Effects.remove_from_list(effects, @other_list, "did:plc:bob")

      assert message =~ "did:plc:bob is not on the list"
      assert FakePDS.sent(pds, "com.atproto.repo.applyWrites") == []
    end

    test "create_starter_pack writes its list, the list's items and the pack in one commit" do
      %{effects: effects, pds: pds} = pds()
      feed = "at://did:plc:f/town.delve.feed.generator/a"

      assert {:ok, result} =
               AtMcp.Effects.create_starter_pack(effects, %{
                 name: "Agents",
                 description: "who to follow",
                 actors: ["alice.test", "did:plc:bob", "did:plc:bob"],
                 feeds: [feed]
               })

      assert [list, alice, bob, pack] = committed(pds)
      list_uri = "at://did:plc:self/town.delve.graph.list/#{list["rkey"]}"

      assert %{"purpose" => "town.delve.graph.defs#referencelist", "name" => "Agents"} =
               list["value"]

      assert [alice["value"]["subject"], bob["value"]["subject"]] == [@alice, "did:plc:bob"]
      assert alice["value"]["list"] == list_uri

      assert %{
               "$type" => "town.delve.graph.starterpack",
               "name" => "Agents",
               "description" => "who to follow",
               "list" => ^list_uri,
               "feeds" => [%{"uri" => ^feed}]
             } = pack["value"]

      assert result.uri == "at://did:plc:self/town.delve.graph.starterpack/#{pack["rkey"]}"
      assert result.list == list_uri
    end

    test "a starter pack's long name is cut to fit its list's, at a whole character" do
      %{effects: effects, pds: pds} = pds()
      name = String.duplicate("日本語の", 12) <> "本棚"

      assert {:ok, %{name: ^name}} = AtMcp.Effects.create_starter_pack(effects, %{name: name})

      # committed/1 checks both records against their lexicons.
      assert [list, pack] = committed(pds)
      assert pack["value"]["name"] == name
      assert byte_size(list["value"]["name"]) <= 64
      assert String.starts_with?(name, list["value"]["name"])
      assert String.length(list["value"]["name"]) == 21
    end

    test "add_to_list refuses a starter pack whose list is in another repository" do
      foreign = "at://did:plc:self/town.delve.graph.starterpack/foreign"

      %{effects: effects, pds: pds} =
        pds(%{}, %{
          foreign => %{
            "$type" => "town.delve.graph.starterpack",
            "name" => "Theirs",
            "list" => "at://did:plc:them/town.delve.graph.list/l",
            "createdAt" => "2026-10-01T00:00:00.000Z"
          }
        })

      assert {:error, {:invalid_argument, "list", message}} =
               AtMcp.Effects.add_to_list(effects, foreign, @alice)

      assert message =~ "another account's repository"
      assert FakePDS.sent(pds, "com.atproto.repo.applyWrites") == []
    end

    test "a write built from what it read names it, and is refused when it changed meanwhile" do
      %{effects: effects, pds: pds} = pds()
      assert {:ok, _} = AtMcp.Effects.delete_list(effects, @mine)

      assert [%{body: %{"swapCommit" => "bafy" <> _}}] =
               FakePDS.sent(pds, "com.atproto.repo.applyWrites")

      swap = {400, %{error: "InvalidSwap", message: "Commit was at bafyother"}}

      %{effects: effects} = pds(%{"com.atproto.repo.applyWrites" => swap})

      # A commit swap names no record: the repository moved, whatever moved it.
      for write <- [
            &AtMcp.Effects.delete_list(&1, @mine),
            &AtMcp.Effects.add_to_list(&1, @mine, "did:plc:carol")
          ] do
        assert {:error,
                %AtMcp.Effects.Failure{
                  kind: :refused,
                  detail: {:changed_meanwhile, "The account's repository"},
                  message: message
                }} = result = write.(effects)

        assert message =~ "The account's repository changed between reading it and writing it"
        assert message =~ "nothing was written"

        assert {:ok, %{isError: true, structuredContent: %{code: "changed_meanwhile"}}, :state} =
                 AtMcp.MCP.Tools.respond(result, :state)
      end

      # A record swap names the record.
      %{effects: effects} = pds(%{"com.atproto.repo.putRecord" => swap})

      assert {:error, %AtMcp.Effects.Failure{detail: {:changed_meanwhile, what}}} =
               AtMcp.Effects.update_starter_pack(effects, @my_pack, %{name: "Bots"})

      assert what == "The record at #{@my_pack}"
    end

    test "a deletion that stops between commits says what the landed ones deleted" do
      many = Map.new(1..250, &item("m#{&1}", @mine, "did:plc:m#{&1}"))
      boom = {500, %{error: "InternalServerError", message: "disk full"}}

      %{effects: effects, pds: pds} =
        pds(%{"com.atproto.repo.applyWrites" => [:default, boom]}, many)

      assert {:error,
              %AtMcp.Effects.Failure{
                kind: :refused,
                status: 500,
                detail: {:partially_written, deleted, _upstream},
                message: message
              }} = result = AtMcp.Effects.delete_list(effects, @mine)

      assert length(deleted) == 200
      refute @mine in deleted
      assert message =~ "1 of 2 commits landed"
      assert message =~ "Whether the next one landed is unknown (disk full)"

      # The second commit names the one the first made, so a change in between
      # stops it.
      assert [first, second] = FakePDS.sent(pds, "com.atproto.repo.applyWrites")
      assert is_binary(first.body["swapCommit"])
      assert second.body["swapCommit"] == FakePDS.commit(Agent.get(pds, & &1))
      refute second.body["swapCommit"] == first.body["swapCommit"]

      assert {:ok, %{isError: true, structuredContent: %{code: "partially_written"} = sc}, :state} =
               AtMcp.MCP.Tools.respond(result, :state)

      assert sc.deleted == deleted
    end

    test "a name too long for a list even by its first character is cut at a codepoint" do
      %{effects: effects, pds: pds} = pds()
      name = "e" <> String.duplicate("\u0301", 40)

      assert {:ok, _} = AtMcp.Effects.create_starter_pack(effects, %{name: name})
      assert [list, _pack] = committed(pds)

      assert list["value"]["name"] == "e" <> String.duplicate("\u0301", 31)
    end

    test "update_starter_pack keeps its list, and an empty feeds list removes the feeds" do
      %{effects: effects, pds: pds} = pds()

      assert {:ok, _} =
               AtMcp.Effects.update_starter_pack(effects, @my_pack, %{name: "Bots", feeds: []})

      pack = put(pds, @my_pack)

      assert pack == @records[@my_pack] |> Map.put("name", "Bots") |> Map.delete("feeds")
    end

    test "delete_starter_pack deletes the pack, its list and the list's items" do
      %{effects: effects, pds: pds} = pds()

      assert {:ok, %{deleted: deleted, list: @pack_list}} =
               AtMcp.Effects.delete_starter_pack(effects, @my_pack)

      # Items, then the list, then the pack.
      expected =
        for(rkey <- ~w(i5 i6), do: "at://did:plc:self/town.delve.graph.listitem/#{rkey}") ++
          [@pack_list, @my_pack]

      assert deleted == expected
      assert deleted(committed(pds)) == expected
    end

    @theirs "at://did:plc:them/town.delve.graph.starterpack/p"
    @their_list "at://did:plc:them/town.delve.graph.list/pl"

    defp pack_view(viewer, purpose \\ "town.delve.graph.defs#referencelist") do
      %{
        "town.delve.graph.getStarterPack" =>
          {200,
           %{
             starterPack: %{
               uri: @theirs,
               list: %{uri: @their_list, purpose: purpose, viewer: viewer}
             }
           }}
      }
    end

    test "set_list_opt_out writes an opt-out naming the pack's list, and deletes it again" do
      %{effects: effects, pds: pds} = pds(pack_view(%{}))

      assert {:ok, %{opted_out: true, list: @their_list, uri: uri}} =
               AtMcp.Effects.set_list_opt_out(effects, @theirs, true)

      assert [%{"value" => record, "rkey" => rkey}] = committed(pds)
      assert record["subject"] == @their_list
      assert record["$type"] == "town.delve.graph.referencelistoptout"
      assert uri == "at://did:plc:self/town.delve.graph.referencelistoptout/#{rkey}"

      # Asking again changes nothing, though the AppView has not caught up;
      # taking it back deletes every opt-out from that list.
      opt_out = fn rkey ->
        {"at://did:plc:self/town.delve.graph.referencelistoptout/#{rkey}",
         %{
           "$type" => "town.delve.graph.referencelistoptout",
           "subject" => @their_list,
           "createdAt" => "2026-10-01T00:00:00.000Z"
         }}
      end

      [{first, _}, {second, _}] = records = [opt_out.("o1"), opt_out.("o2")]

      elsewhere =
        {"at://did:plc:self/town.delve.graph.referencelistoptout/o3",
         %{
           "$type" => "town.delve.graph.referencelistoptout",
           "subject" => "at://did:plc:them/town.delve.graph.list/other",
           "createdAt" => "2026-10-01T00:00:00.000Z"
         }}

      %{effects: effects, pds: pds} = pds(pack_view(%{}), Map.new([elsewhere | records]))

      assert {:ok, %{unchanged: true, uri: ^first}} =
               AtMcp.Effects.set_list_opt_out(effects, @theirs, true)

      assert FakePDS.sent(pds, "com.atproto.repo.applyWrites") == []

      assert {:ok, %{opted_out: false, deleted: [^first, ^second]}} =
               AtMcp.Effects.set_list_opt_out(effects, @theirs, false)

      assert deleted(committed(pds)) == [first, second]
    end

    test "set_list_opt_out asks for a pack named with a handle by its DID form" do
      %{effects: effects, pds: pds} = pds(pack_view(%{}))

      assert {:ok, _} =
               AtMcp.Effects.set_list_opt_out(
                 effects,
                 "at://alice.test/town.delve.graph.starterpack/p",
                 true
               )

      assert [%{query: %{"starterPack" => "at://did:plc:alice/town.delve.graph.starterpack/p"}}] =
               FakePDS.sent(pds, "town.delve.graph.getStarterPack")
    end

    test "set_list_opt_out refuses a list that is not a starter pack's" do
      %{effects: effects, pds: pds} = pds(pack_view(%{}, "town.delve.graph.defs#curatelist"))

      assert {:error, {:invalid_argument, "list", message}} =
               AtMcp.Effects.set_list_opt_out(effects, @theirs, true)

      assert message =~ "is a curate list"
      assert FakePDS.sent(pds, "com.atproto.repo.applyWrites") == []
    end

    test "a list or starter pack named with a handle is asked for in DID form" do
      %{effects: effects, pds: pds} =
        pds(%{
          "com.atproto.identity.resolveHandle" => {200, %{did: @alice}},
          "town.delve.graph.getList" => {200, %{list: %{uri: "x"}, items: []}},
          "town.delve.graph.getStarterPack" => {200, %{starterPack: %{uri: "x"}}}
        })

      assert {:ok, _} =
               AtMcp.Effects.get_list(effects, "at://alice.test/town.delve.graph.list/l1")

      assert {:ok, _} =
               AtMcp.Effects.get_starter_pack(
                 effects,
                 "at://alice.test/town.delve.graph.starterpack/p1"
               )

      # This account's own handle needs no resolution.
      assert {:ok, _} =
               AtMcp.Effects.get_list(effects, "at://self.example/town.delve.graph.list/l2")

      assert [%{query: %{"handle" => "alice.test"}}, _] =
               FakePDS.sent(pds, "com.atproto.identity.resolveHandle")

      assert for(%{query: q} <- FakePDS.sent(pds, "town.delve.graph.getList"), do: q["list"]) == [
               "at://did:plc:alice/town.delve.graph.list/l1",
               "at://did:plc:self/town.delve.graph.list/l2"
             ]

      assert [%{query: %{"starterPack" => "at://did:plc:alice/town.delve.graph.starterpack/p1"}}] =
               FakePDS.sent(pds, "town.delve.graph.getStarterPack")
    end

    test "a list's feed named with a handle is asked for in DID form" do
      %{effects: effects, pds: pds} =
        pds(%{
          "com.atproto.identity.resolveHandle" => {200, %{did: @alice}},
          "town.delve.feed.getListFeed" => {200, %{feed: []}}
        })

      assert {:ok, _} =
               AtMcp.Effects.get_list_feed(effects, "at://alice.test/town.delve.graph.list/l1")

      assert [%{query: %{"list" => "at://did:plc:alice/town.delve.graph.list/l1"}}] =
               FakePDS.sent(pds, "town.delve.feed.getListFeed")
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
