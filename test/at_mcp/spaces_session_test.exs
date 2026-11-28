defmodule AtMcp.SpacesSessionTest do
  @moduledoc """
  An account with a login key and no app password: its OAuth session comes
  from the Spaces helper (`AtMcp.Spaces.Login`), and every request carries
  the helper's current access token, signed with the session's DPoP key.

  The helper is `test/support/fake_spaces_helper.mjs`, which speaks the
  helper's protocol; the network is a stub HTTP client that records each
  request's `Authorization`.
  """
  use ExUnit.Case, async: false

  @fake Path.expand("../support/fake_spaces_helper.mjs", __DIR__)

  # The helper's session names this stand-in PDS as its service, for the
  # agent routes (`PDS` below); every other request goes to the HTTP stub.
  setup_all do
    {:ok, _} = Plug.Cowboy.http(__MODULE__.PDS, [], port: 0, ref: :spaces_principal_pds)
    on_exit(fn -> Plug.Cowboy.shutdown(:spaces_principal_pds) end)
    %{fake_service: "http://localhost:#{:ranch.get_port(:spaces_principal_pds)}"}
  end

  defmodule HTTP do
    def request(method, url, opts) do
      headers = Map.new(Keyword.get(opts, :headers, []), fn {k, v} -> {String.downcase(k), v} end)
      owner = Application.fetch_env!(:at_mcp, :spaces_session_test_owner)
      send(owner, {:request, method, url, headers["authorization"], headers["dpop"]})

      refused = Application.get_env(:at_mcp, :spaces_session_test_refuse)

      case headers["authorization"] do
        "DPoP " <> ^refused ->
          {:ok,
           %{
             status: 401,
             headers: [{"www-authenticate", "DPoP error=\"invalid_token\""}],
             body: Jason.encode!(%{error: "invalid_token", message: "token rotated"})
           }}

        _sent ->
          body =
            cond do
              String.ends_with?(url, ".notification.registerSpace") ->
                # A list of answers is taken one per call, the last staying.
                case Application.get_env(
                       :at_mcp,
                       :spaces_session_test_register_status,
                       "registered"
                     ) do
                  [answer | rest] ->
                    if rest != [],
                      do: Application.put_env(:at_mcp, :spaces_session_test_register_status, rest)

                    answer

                  status ->
                    %{status: status}
                end

              String.contains?(url, "com.atproto.server.getServiceAuth") ->
                %{token: "aaa.bbb.ccc"}

              String.contains?(url, "notification.listNotifications") ->
                %{notifications: []}

              String.contains?(url, "actor.getProfiles") ->
                %{
                  profiles: [
                    %{did: "did:plc:friend", handle: "friend.test", displayName: "A Friend"}
                  ]
                }

              true ->
                %{count: 3}
            end

          {:ok, %{status: 200, headers: [], body: Jason.encode!(body)}}
      end
    end
  end

  setup ctx do
    if is_nil(System.find_executable("node")), do: raise("these tests need node on the path")

    log = Path.join(System.tmp_dir!(), "fake-helper-#{System.unique_integer([:positive])}.log")
    System.put_env("FAKE_LOG", log)
    System.put_env("FAKE_DID", "did:plc:oauthagent")
    # The account is an agent of did:plc:principal, as its DID document
    # would say (agent-of): its notes are in its state space there.
    :persistent_term.put(
      {AtMcp.Spaces, :principal_of, "did:plc:oauthagent"},
      {:ok, "did:plc:principal"}
    )

    on_exit(fn -> :persistent_term.erase({AtMcp.Spaces, :principal_of, "did:plc:oauthagent"}) end)
    home = Path.join(System.tmp_dir!(), "state-home-#{System.unique_integer([:positive])}.json")
    Application.put_env(:at_mcp, :state_home_path, home)

    on_exit(fn ->
      File.rm(home)
      Application.delete_env(:at_mcp, :state_home_path)
    end)

    die = Path.join(System.tmp_dir!(), "fake-die-#{System.unique_integer([:positive])}")
    System.put_env("FAKE_DIE", die)
    fixture = Path.join(System.tmp_dir!(), "fake-fixture-#{System.unique_integer([:positive])}")
    System.put_env("FAKE_FIXTURE", fixture)

    on_exit(fn ->
      File.rm(fixture)
      System.delete_env("FAKE_FIXTURE")
    end)

    if service = Map.get(ctx, :fake_service), do: System.put_env("FAKE_SERVICE", service)

    previous_http = Application.get_env(:proto_rune, :http_client)
    Application.put_env(:proto_rune, :http_client, HTTP)
    Application.put_env(:at_mcp, :spaces_session_test_owner, self())

    # The application's helper is replaced by the fake for this test.
    :ok = Supervisor.terminate_child(AtMcp.Supervisor, AtMcp.Spaces.Helper)

    {:ok, helper} =
      AtMcp.Spaces.Helper.start_link(
        script: @fake,
        enabled: true,
        inbox_readers: Map.get(ctx, :inbox_readers, []),
        state_dir:
          Path.join(System.tmp_dir!(), "fake-helper-state-#{System.unique_integer([:positive])}")
      )

    on_exit(fn ->
      # Linked to the test, the helper may already be stopping with it.
      try do
        GenServer.stop(helper)
      catch
        :exit, _ -> :ok
      end

      {:ok, _} = Supervisor.restart_child(AtMcp.Supervisor, AtMcp.Spaces.Helper)

      if previous_http,
        do: Application.put_env(:proto_rune, :http_client, previous_http),
        else: Application.delete_env(:proto_rune, :http_client)

      Application.delete_env(:at_mcp, :spaces_session_test_owner)
      Application.delete_env(:at_mcp, :spaces_session_test_refuse)
      System.delete_env("FAKE_LOG")
      System.delete_env("FAKE_DIE")
      System.delete_env("FAKE_SERVICE")
      File.rm(log)
    end)

    {:ok, effects} =
      AtMcp.Test.QuotaFixture.start_effects(
        backend: AtMcp.Effects.ProtoRune,
        handle: "agent.test",
        key_file: "/keys/agent.json",
        expected_did: "did:plc:oauthagent"
      )

    %{effects: effects, log: log, fixture: fixture}
  end

  defp calls(log) do
    log |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
  end

  # The next request for the unread count; the preferences read the first
  # application read makes (for the labelers it asks for) is skipped.
  defp next_request do
    assert_receive {:request, _method, url, authorization, dpop}, 5_000

    if String.contains?(url, "getUnreadCount"),
      do: {url, authorization, dpop},
      else: next_request()
  end

  test "a token at its expiry is never sent: the call waits for the helper's fresh one, and the next call keeps it",
       ctx do
    assert {:ok, _} = AtMcp.Effects.login(ctx.effects)

    # The first token expires inside AtMcp's margin: it is refreshed before
    # any request goes out.
    assert {:ok, _} = AtMcp.Effects.get_unread_count(ctx.effects)
    {_url, auth, dpop} = next_request()
    assert auth == "DPoP tok-2"
    assert is_binary(dpop)

    assert {:ok, _} = AtMcp.Effects.get_unread_count(ctx.effects)
    {_url, auth, _} = next_request()
    assert auth == "DPoP tok-2"

    refute_received {:request, _, _, "DPoP tok-1", _}

    asked = calls(ctx.log)

    assert Enum.count(asked, &(&1["method"] == "oauth.credentials" and &1["params"]["refresh"])) ==
             1

    # AtMcp gave the helper the account's key to log in again with, and
    # never anything else of it.
    [login | _] = Enum.filter(asked, &(&1["method"] == "oauth.credentials"))
    assert login["params"]["relogin"]["keyFile"] == "/keys/agent.json"
  end

  test "a token the server refuses mid-session is refreshed once and the call retried with the new one",
       ctx do
    assert {:ok, _} = AtMcp.Effects.login(ctx.effects)
    assert {:ok, _} = AtMcp.Effects.get_unread_count(ctx.effects)
    {_, "DPoP tok-2", _} = next_request()

    # The helper refreshed elsewhere (another call, or the server rotated
    # it): the server now refuses tok-2.
    Application.put_env(:at_mcp, :spaces_session_test_refuse, "tok-2")

    assert {:ok, _} = AtMcp.Effects.get_unread_count(ctx.effects)
    {_, "DPoP tok-2", _} = next_request()
    {_, "DPoP tok-3", _} = next_request()

    assert {:ok, _} = AtMcp.Effects.get_unread_count(ctx.effects)
    {_, "DPoP tok-3", _} = next_request()
  end

  describe "the Spaces tools, through the helper" do
    setup do
      previous = Application.get_env(:at_mcp, :network)
      Application.put_env(:at_mcp, :network, :delve)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:at_mcp, :network, previous),
          else: Application.delete_env(:at_mcp, :network)
      end)
    end

    test "an agent's note is written in its state space, under its principal, and says it is not encrypted",
         ctx do
      assert {:ok, _} = AtMcp.Effects.login(ctx.effects)

      assert {:ok, note} =
               AtMcp.Effects.spaces(ctx.effects, :create_note, [%{text: "remember", tags: ["a"]}])

      assert note.text == "remember"
      assert note.readable_by =~ "not encrypted"
      assert note.readable_by =~ "its principal"

      [written] = Enum.filter(calls(ctx.log), &(&1["method"] == "space.records.create"))

      assert written["params"]["space"] ==
               "at:space/did:plc:principal/town.delve.space.agent/did:plc:oauthagent"

      # The agent makes no space of its own: its principal holds it.
      refute "space.create" in Enum.map(calls(ctx.log), & &1["method"])

      # Notes do not spend the write quota.
      assert AtMcp.Effects.quota_status(ctx.effects).used == 0
    end

    test "an account with no principal keeps its state in a space of its own, made at its first note",
         ctx do
      assert {:ok, _} = AtMcp.Effects.login(ctx.effects)
      :persistent_term.put({AtMcp.Spaces, :principal_of, "did:plc:oauthagent"}, :none)
      own = "at:space/did:plc:oauthagent/town.delve.space.agent/did:plc:oauthagent"

      # The fake helper says no such space for one the account hasn't made.
      assert {:ok, note} = AtMcp.Effects.spaces(ctx.effects, :create_note, [%{text: "mine"}])
      assert note.uri =~ own

      writes = Enum.filter(calls(ctx.log), &(&1["method"] == "space.records.create"))
      assert Enum.all?(writes, &(&1["params"]["space"] == own))
    end

    # Each refused before anything is sent, as the note lexicon
    # (town.delve.notes.note) would refuse the record.
    test "a note's fields are held to the note lexicon's limits", ctx do
      assert {:ok, _} = AtMcp.Effects.login(ctx.effects)
      long = fn n -> String.duplicate("a", n) end

      for {fields, field, says} <- [
            {%{text: long.(30_001)}, "text", "at most 30000 characters"},
            {%{text: "x", title: long.(301)}, "title", "at most 300 characters"},
            {%{text: "x", tags: Enum.map(1..17, &"t#{&1}")}, "tags", "at most 16 tags"},
            {%{text: "x", tags: [long.(65)]}, "tags", "at most 64 characters"},
            {%{text: "x", tags: [String.duplicate("é", 64) <> String.duplicate("🌱", 1)]}, "tags",
             "at most 64 characters"},
            {%{text: "x", tags: [7]}, "tags", "each tag is text"}
          ] do
        assert {:error, %AtMcp.Effects.Failure{detail: :invalid_argument, message: message}} =
                 AtMcp.Effects.spaces(ctx.effects, :create_note, [fields])

        assert message =~ field <> " "
        assert message =~ says
      end

      refute "space.records.create" in Enum.map(calls(ctx.log), & &1["method"])

      # At the limits, the note is written.
      assert {:ok, _} =
               AtMcp.Effects.spaces(ctx.effects, :create_note, [
                 %{text: "x", title: long.(300), tags: Enum.map(1..16, fn _ -> long.(64) end)}
               ])
    end

    test "a listed note has its rkey and its URI, so it can be updated after", ctx do
      assert {:ok, _} = AtMcp.Effects.login(ctx.effects)

      assert {:ok, created} =
               AtMcp.Effects.spaces(ctx.effects, :create_note, [%{text: "remember"}])

      assert {:ok, %{notes: [listed]}} =
               AtMcp.Effects.spaces(ctx.effects, :list_notes, [nil, nil])

      assert listed.rkey == created.rkey and is_binary(listed.rkey)

      assert listed.uri ==
               "at:space/did:plc:principal/town.delve.space.agent/did:plc:oauthagent/did:plc:oauthagent/town.delve.notes.note/" <>
                 listed.rkey
    end

    test "a space this account can't reach is said to be no such space, with the account's own",
         ctx do
      assert {:ok, _} = AtMcp.Effects.login(ctx.effects)
      elsewhere = "at:space/did:plc:someone/town.delve.space.feed/general"

      assert {:error,
              %AtMcp.Effects.Failure{kind: :refused, detail: :no_such_space, message: message}} =
               AtMcp.Effects.spaces(ctx.effects, :space_feed, [elsewhere, nil])

      assert message =~ "No such space, or not one this account can read or write: #{elsewhere}"
      assert message =~ "at:space/did:plc:principal/town.delve.space.agent/did:plc:oauthagent"
      refute message =~ "scope"
    end

    test "post with a space posts there: a town post, refused before a slot when it can't go, and counted",
         ctx do
      assert {:ok, _} = AtMcp.Effects.login(ctx.effects)
      space = "at:space/did:plc:group/town.delve.space.feed/general"

      assert {:error, _} = AtMcp.Effects.post(ctx.effects, "   ", space: space)

      assert {:error,
              %AtMcp.Effects.Failure{
                kind: :refused,
                message: "images can't go on a post in a space" <> _
              }} =
               AtMcp.Effects.post(ctx.effects, "with a picture", space: space, images: [%{}])

      assert {:error, _} = AtMcp.Effects.post(ctx.effects, "hi", space: "at://not/a/space")

      # An invite record is not a space: refused, saying how to join.
      invite =
        "at:space/did:plc:oauthagent/org.atgrp.inbox/self/did:plc:group/org.atgrp.invite/3kinv"

      assert {:error, %AtMcp.Effects.Failure{kind: :refused, message: msg}} =
               AtMcp.Effects.post(ctx.effects, "hello", space: invite)

      assert msg =~ "is a group invite"
      assert msg =~ "accept_group_invite with group did:plc:group"
      assert AtMcp.Effects.quota_status(ctx.effects).used == 0

      assert {:ok, %{uri: uri, space: ^space}} =
               AtMcp.Effects.post(ctx.effects, "hello group", space: space)

      assert uri =~ "town.delve.feed.post"

      [write] = Enum.filter(calls(ctx.log), &(&1["method"] == "space.records.create"))
      assert write["params"]["space"] == space
      assert write["params"]["collection"] == "town.delve.feed.post"
      assert write["params"]["record"]["text"] == "hello group"
      assert AtMcp.Effects.quota_status(ctx.effects).used == 1
    end
  end

  describe "an inbox without a standing reader" do
    setup do
      previous = Application.get_env(:at_mcp, :network)
      Application.put_env(:at_mcp, :network, :delve)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:at_mcp, :network, previous),
          else: Application.delete_env(:at_mcp, :network)
      end)
    end

    test "an inbox's token is handed to the town AppView, and no inbox means nothing is sent",
         ctx do
      assert {:ok, _} = AtMcp.Effects.login(ctx.effects)

      # No inbox yet: nothing to vouch for, and nothing is made.
      assert {:error, %AtMcp.Effects.Failure{detail: "SpaceNotFound"}} =
               AtMcp.Effects.spaces(ctx.effects, :vouch_inbox, [])

      refute_received {:request, :post, _, _, _}

      session =
        AtMcp.Spaces.Login.session(
          elem(AtMcp.Spaces.Login.credentials("did:plc:oauthagent"), 1),
          "agent.test"
        )

      # The inbox, with no reader: no notice, and nothing registered.
      # Made without the reader: said once, with what it costs.
      assert {:ok, space, "off", notice} = AtMcp.Spaces.ensure_inbox(session)
      assert notice =~ "up to about 8 minutes"

      assert {:ok, %{status: "registered", space: ^space}} =
               AtMcp.Effects.spaces(ctx.effects, :vouch_inbox, [])

      assert_receive {:request, :post, url, _, _}, 5_000
      assert url =~ "town.delve.notification.registerSpace"

      asked = calls(ctx.log) |> Enum.map(& &1["method"])
      assert "space.delegationToken" in asked
    end

    test "without the reader, a token goes over at most every 8 minutes, and the account is told once what that costs",
         ctx do
      assert AtMcp.Spaces.InboxTokens.token_ms() == 8 * 60_000
      assert {:ok, _} = AtMcp.Effects.login(ctx.effects)
      alias AtMcp.Spaces.InboxTokens
      accounts = [{:agent, ctx.effects}]
      tokens = fn -> Enum.count(calls(ctx.log), &(&1["method"] == "space.delegationToken")) end

      # Made without the reader: a token at once, and the notice is owed.
      {%{agent: :tokens}, state} = InboxTokens.vouch_all(InboxTokens.initial(), accounts)
      assert tokens.() == 1
      notice = AtMcp.Spaces.take_notice("did:plc:oauthagent")
      assert notice =~ "up to about 8 minutes"
      assert notice =~ "AT_MCP_TOWN_INBOX_READER=false"

      # Passes within 8 minutes send none.
      {%{agent: :tokens}, state} = InboxTokens.vouch_all(state, accounts)
      assert tokens.() == 1

      # 8 minutes on, the next.
      state = update_in(state.modes.agent.token_at, &(&1 - InboxTokens.token_ms()))
      {_, state} = InboxTokens.vouch_all(state, accounts)
      assert tokens.() == 2

      # A session established anew gets one at once, once.
      state = %{state | renewed: MapSet.put(state.renewed, "did:plc:oauthagent")}
      {_, state} = InboxTokens.vouch_all(state, accounts)
      assert tokens.() == 3
      {_, _state} = InboxTokens.vouch_all(state, accounts)
      assert tokens.() == 3
    end
  end

  describe "an inbox the town AppView reads" do
    @describetag inbox_readers: ["did:web:api.delve.town"]

    setup do
      previous = Application.get_env(:at_mcp, :network)
      Application.put_env(:at_mcp, :network, :delve)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:at_mcp, :network, previous),
          else: Application.delete_env(:at_mcp, :network)
      end)
    end

    test "is registered with the AppView, so its invites reach the notifications", ctx do
      Application.put_env(:at_mcp, :group_host, "http://group-host.invalid")
      on_exit(fn -> Application.delete_env(:at_mcp, :group_host) end)
      assert {:ok, _} = AtMcp.Effects.login(ctx.effects)

      session =
        AtMcp.Spaces.Login.session(
          elem(AtMcp.Spaces.Login.credentials("did:plc:oauthagent"), 1),
          "agent.test"
        )

      # InboxTokens makes the inbox when AtMcp starts.
      assert {:ok, %{notifications: "registered"}} = AtMcp.Spaces.prepare_inbox(session)
      assert_receive {:request, :post, url, "DPoP tok-" <> _, _}, 5_000
      assert url =~ "town.delve.notification.registerSpace"

      # Its notice waits for the account's next read that can say it.
      assert {:ok, _space, "registered", nil} = AtMcp.Spaces.ensure_inbox(session)
      notice = AtMcp.Spaces.take_notice("did:plc:oauthagent")
      assert AtMcp.Spaces.take_notice("did:plc:oauthagent") == nil
      # Said in plain words, with the way to turn it off.
      assert notice =~ "town's AppView is now a listed reader of this account's invite inbox"
      assert notice =~ "To remove it, take the AppView off the inbox's members"
      assert notice =~ "AT_MCP_TOWN_INBOX_READER=false"
    end
  end

  defp delve(_ctx) do
    previous = Application.get_env(:at_mcp, :network)
    Application.put_env(:at_mcp, :network, :delve)

    ExUnit.Callbacks.on_exit(fn ->
      if previous,
        do: Application.put_env(:at_mcp, :network, previous),
        else: Application.delete_env(:at_mcp, :network)
    end)
  end

  defp session_of do
    AtMcp.Spaces.Login.session(
      elem(AtMcp.Spaces.Login.credentials("did:plc:oauthagent"), 1),
      "agent.test"
    )
  end

  # How many registerSpace calls reached the AppView since the last look.
  defp receive_all_registers(n) do
    receive do
      {:request, :post, url, _, _} ->
        if url =~ "notification.registerSpace",
          do: receive_all_registers(n + 1),
          else: receive_all_registers(n)
    after
      200 -> n
    end
  end

  test "notes go to the one principal whose endorsement its repository proves; a lookup that fails keeps the binding, or writes nothing",
       ctx do
    Application.put_env(:at_mcp, :plc_url, ctx.fake_service <> "/plc")
    previous = Application.get_env(:at_mcp, :network)
    Application.put_env(:at_mcp, :network, :delve)

    on_exit(fn ->
      Application.delete_env(:at_mcp, :plc_url)
      Application.delete_env(:at_mcp, :spaces_session_test_agent_of)

      if previous,
        do: Application.put_env(:at_mcp, :network, previous),
        else: Application.delete_env(:at_mcp, :network)
    end)

    assert {:ok, _} = AtMcp.Effects.login(ctx.effects)
    agent = "did:plc:oauthagent"
    key = {AtMcp.Spaces, :principal_of, agent}
    # Resolved for real here, not pinned as in the other tests.
    :persistent_term.erase(key)

    verify = fn by ->
      File.write!(ctx.fixture, Jason.encode!(%{verify: by}))
    end

    names = fn principals ->
      Application.put_env(:at_mcp, :spaces_session_test_agent_of, %{agent => principals})
      :persistent_term.erase(key)
    end

    writes = fn ->
      for %{"method" => "space.records.create", "params" => p} <- calls(ctx.log), do: p["space"]
    end

    note = fn -> AtMcp.Effects.spaces(ctx.effects, :create_note, [%{text: "remember"}]) end

    # Two claimed, one proved: the proved one.
    names.(["did:plc:claims", "did:plc:real"])

    verify.(%{
      "did:plc:claims" => %{found: false},
      "did:plc:real" => %{found: true, record: %{agent: agent}}
    })

    _ = note.()
    assert List.last(writes.()) == AtMcp.Spaces.agent_space_uri("did:plc:real", agent)
    assert AtMcp.Spaces.StateHome.principal(agent) == "did:plc:real"

    # The directory unreachable: the binding holds, and the failure isn't kept.
    Application.put_env(:at_mcp, :plc_url, "http://127.0.0.1:9/plc")
    :persistent_term.erase(key)
    _ = note.()
    assert List.last(writes.()) == AtMcp.Spaces.agent_space_uri("did:plc:real", agent)

    # With no binding either, nothing is written, and it says why: never the
    # account's own space instead.
    File.rm(Application.get_env(:at_mcp, :state_home_path))
    :persistent_term.erase(key)
    count = length(writes.())

    assert {:error, %AtMcp.Effects.Failure{detail: :principal_unavailable}} = note.()
    assert length(writes.()) == count
    assert :persistent_term.get(key, nil) == nil

    Application.put_env(:at_mcp, :plc_url, ctx.fake_service <> "/plc")

    # Two proved: a conflict, said, and nothing written.
    names.(["did:plc:real", "did:plc:also"])

    verify.(%{
      "did:plc:real" => %{found: true, record: %{agent: agent}},
      "did:plc:also" => %{found: true, record: %{agent: agent}}
    })

    assert {:error, %AtMcp.Effects.Failure{detail: :principal_conflict}} = note.()

    # Claimed, none proved: refused, not sent to its own space.
    names.(["did:plc:claims"])
    verify.(%{"did:plc:claims" => "ProofInvalid"})
    assert {:error, %AtMcp.Effects.Failure{detail: :principal_unconfirmed}} = note.()
    assert length(writes.()) == count

    # None claimed: it governs itself.
    names.([])
    _ = note.()
    assert AtMcp.Spaces.StateHome.principal(agent) == agent
  end

  test "after a hand-off the agent copies its own records to its new principal's space, clears the old, then moves its binding",
       ctx do
    Application.put_env(:at_mcp, :plc_url, ctx.fake_service <> "/plc")
    previous = Application.get_env(:at_mcp, :network)
    Application.put_env(:at_mcp, :network, :delve)

    on_exit(fn ->
      Application.delete_env(:at_mcp, :plc_url)
      Application.delete_env(:at_mcp, :spaces_session_test_agent_of)

      if previous,
        do: Application.put_env(:at_mcp, :network, previous),
        else: Application.delete_env(:at_mcp, :network)
    end)

    assert {:ok, _} = AtMcp.Effects.login(ctx.effects)
    agent = "did:plc:oauthagent"
    old = AtMcp.Spaces.agent_space_uri("did:plc:oldp", agent)
    new = AtMcp.Spaces.agent_space_uri("did:plc:newp", agent)

    # Bound to its old principal; its identity now names the new one, whose
    # endorsement its repository proves.
    AtMcp.Spaces.StateHome.bind(agent, "did:plc:oldp")
    Application.put_env(:at_mcp, :spaces_session_test_agent_of, %{agent => ["did:plc:newp"]})

    note = fn rkey, repo ->
      %{
        "repo" => repo,
        "collection" => "town.delve.notes.note",
        "rkey" => rkey,
        "valid" => true,
        "record" => %{"$type" => "town.delve.notes.note", "text" => "remember #{rkey}"}
      }
    end

    fixture = fn existing ->
      File.write!(
        ctx.fixture,
        Jason.encode!(%{
          existing: existing,
          verify: %{"did:plc:newp" => %{found: true, record: %{agent: agent}}},
          all: %{old => [note.("3k1", agent), note.("3k2", agent), note.("3kp", "did:plc:oldp")]}
        })
      )
    end

    of = fn method -> for %{"method" => ^method, "params" => p} <- calls(ctx.log), do: p end

    # The new principal hasn't made its space yet: nothing copied or
    # cleared, and the binding stays, to try again.
    fixture.([old])

    assert {:ok, %{principal: "did:plc:newp"}} =
             AtMcp.Effects.spaces(ctx.effects, :carry_agent_state, [])

    assert of.("space.records.put") == [] and of.("space.records.clear") == []
    assert AtMcp.Spaces.StateHome.principal(agent) == "did:plc:oldp"

    # Made: its own two records copied under their keys (not its old
    # principal's), the old space cleared of them, and the binding moved.
    fixture.([old, new])

    assert {:ok, %{principal: "did:plc:newp"}} =
             AtMcp.Effects.spaces(ctx.effects, :carry_agent_state, [])

    assert [first, second] = of.("space.records.put")
    assert first["space"] == new and first["rkey"] == "3k1"
    assert second["record"]["text"] == "remember 3k2"
    assert [%{"space" => ^old}] = of.("space.records.clear")
    assert AtMcp.Spaces.StateHome.principal(agent) == "did:plc:newp"

    # Done once; new notes go to the new space.
    assert {:ok, _} = AtMcp.Effects.spaces(ctx.effects, :carry_agent_state, [])
    assert length(of.("space.records.put")) == 2
    _ = AtMcp.Effects.spaces(ctx.effects, :create_note, [%{text: "after"}])
    assert List.last(of.("space.records.create"))["space"] == new
  end

  test "an endorsement is confirmed only as the principal's repository proves it, and a lookup that fails isn't a no",
       ctx do
    Application.put_env(:at_mcp, :plc_url, ctx.fake_service <> "/plc")
    on_exit(fn -> Application.delete_env(:at_mcp, :plc_url) end)
    assert {:ok, _} = AtMcp.Effects.login(ctx.effects)

    # What the helper's check of getRecord's proof answers, by principal.
    File.write!(
      ctx.fixture,
      Jason.encode!(%{
        verify: %{
          "did:plc:good" => %{found: true, record: %{agent: "did:plc:agent"}},
          "did:plc:other" => %{found: true, record: %{agent: "did:plc:someone"}},
          "did:plc:none" => %{found: false},
          "did:plc:forged" => "ProofInvalid"
        }
      })
    )

    s = session_of()
    assert AtMcp.Spaces.endorsement(s, "did:plc:good", "did:plc:agent") == "confirmed"
    assert AtMcp.Spaces.endorsement(s, "did:plc:other", "did:plc:agent") == "not_endorsed"
    assert AtMcp.Spaces.endorsement(s, "did:plc:none", "did:plc:agent") == "not_endorsed"
    assert AtMcp.Spaces.endorsement(s, "did:plc:forged", "did:plc:agent") == "proof_invalid"
    assert AtMcp.Spaces.endorsement(s, "did:plc:gone", "did:plc:agent") == "unavailable"

    # Checked at the principal's PDS, against the key its DID document names.
    [check | _] = Enum.filter(calls(ctx.log), &(&1["method"] == "record.verify"))

    assert check["params"] == %{
             "pds" => "https://pds.test",
             "did" => "did:plc:good",
             "collection" => "link.ident.endorsement",
             "rkey" => "did:plc:agent",
             "signingKey" => "did:key:zQ3shKey"
           }
  end

  defmodule GroupHost do
    # A stand-in group host: its DID, an app's request to sign in as a group
    # (the group the member may approve it for), and the approval.
    use Plug.Router
    plug(:match)
    plug(Plug.Parsers, parsers: [:json], json_decoder: Jason)
    plug(:dispatch)

    get("/xrpc/com.atproto.server.describeServer",
      do: json(conn, %{did: "did:web:groups.test", availableUserDomains: [".groups.test"]})
    )

    get "/xrpc/org.atgrp.internal.getAuthorization" do
      case Application.get_env(:at_mcp, :spaces_session_test_authorization) do
        %{} = asked -> json(conn, asked)
        nil -> json(conn, default_authorization())
      end
    end

    defp default_authorization do
      %{
        client: %{clientId: "https://app.example/client.json", name: "Example app"},
        requested: [%{scope: "atproto"}, %{scope: "include:org.atgrp.authManageAdmin"}],
        groups: [
          %{
            did: "did:plc:group",
            handle: "g.groups.test",
            roles: [],
            granted: [%{scope: "atproto"}, %{scope: "include:org.atgrp.authParticipate"}],
            withheld: [%{scope: "include:org.atgrp.authManageAdmin"}]
          }
        ]
      }
    end

    post "/xrpc/org.atgrp.internal.approveAuthorization" do
      send(
        Application.fetch_env!(:at_mcp, :spaces_session_test_owner),
        {:approved, conn.body_params}
      )

      json(conn, %{redirectUrl: "http://127.0.0.1/callback?code=c&state=s&iss=x"})
    end

    get("/xrpc/org.atgrp.internal.getActorInvites",
      do:
        json(conn, %{
          invites: [
            %{
              group: %{did: "did:plc:group", handle: "g.groups.test", displayName: "G"},
              message: "join us",
              createdAt: "2026-11-26T00:00:00.000Z"
            }
          ]
        })
    )

    # The group's members matching q: the AppView among them unless a test
    # says it isn't a member.
    get "/xrpc/org.atgrp.internal.listMembers" do
      conn = Plug.Conn.fetch_query_params(conn)
      member? = Application.get_env(:at_mcp, :spaces_session_test_appview_member, true)
      # As group-host 0.6 lists them: objects.
      roles =
        Application.get_env(:at_mcp, :spaces_session_test_roles, ["member", "admin"])
        |> Enum.map(&%{role: &1})

      found = if member?, do: [%{actor: %{did: conn.query_params["q"]}, roles: roles}], else: []
      json(conn, %{members: found})
    end

    get("/xrpc/org.atgrp.internal.getActorGroups",
      do:
        json(conn, %{groups: [%{did: "did:plc:group", handle: "g.groups.test", displayName: "G"}]})
    )

    get "/xrpc/org.atgrp.internal.getGroup" do
      json(conn, %{
        group: %{
          did: "did:plc:group",
          handle: "g.groups.test",
          displayName: "G",
          description: "A group",
          # The policy the last createGroup asked for, or what a test says
          # the host ended up with.
          joinPolicy:
            Application.get_env(:at_mcp, :spaces_session_test_policy) ||
              Application.get_env(:at_mcp, :spaces_session_test_founded_policy),
          viewer: %{member: true, accepted: true}
        },
        spaces: [
          %{uri: "at:space/did:plc:group/org.atgrp.members/self", spaceType: "org.atgrp.members"},
          %{
            uri: "at:space/did:plc:group/town.delve.space.feed/general",
            spaceType: "town.delve.space.feed"
          }
        ]
      })
    end

    post "/xrpc/org.atgrp.internal.createGroup" do
      send(
        Application.fetch_env!(:at_mcp, :spaces_session_test_owner),
        {:created, conn.body_params}
      )

      Application.put_env(
        :at_mcp,
        :spaces_session_test_founded_policy,
        conn.body_params["joinPolicy"]
      )

      case Application.get_env(:at_mcp, :spaces_session_test_create) do
        {status, error, message} ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(status, Jason.encode!(%{error: error, message: message}))

        nil ->
          json(conn, %{
            did: "did:plc:newgroup",
            meta: "at:space/did:plc:newgroup/org.atgrp.meta/self",
            members: "at:space/did:plc:newgroup/org.atgrp.members/self"
          })
      end
    end

    get "/xrpc/org.atgrp.listJoinRequests" do
      json(conn, %{
        requests: [
          %{member: "did:plc:friend", createdAt: "2026-11-27T00:00:00Z", message: "hello"},
          %{member: "did:web:api.delve.town", createdAt: "2026-11-27T00:00:01Z"}
        ]
      })
    end

    post "/xrpc/org.atgrp.denyJoinRequest" do
      send(
        Application.fetch_env!(:at_mcp, :spaces_session_test_owner),
        {:denied, conn.body_params}
      )

      json(conn, %{})
    end

    post "/xrpc/org.atgrp.leaveGroup" do
      json(conn, %{})
    end

    post "/xrpc/org.atgrp.requestJoin" do
      send(
        Application.fetch_env!(:at_mcp, :spaces_session_test_owner),
        {:joined, conn.body_params}
      )

      case Application.get_env(:at_mcp, :spaces_session_test_join, "admitted") do
        "admitted" ->
          json(conn, %{status: "admitted", membership: %{uri: "at:space/x", cid: "c"}})

        status ->
          json(conn, %{status: status, request: %{uri: "at:space/r", cid: "c"}})
      end
    end

    post "/xrpc/org.atgrp.internal.declineAuthorization" do
      send(
        Application.fetch_env!(:at_mcp, :spaces_session_test_owner),
        {:declined, conn.body_params}
      )

      json(conn, %{redirectUrl: "http://127.0.0.1/callback?error=access_denied&state=s&iss=x"})
    end

    defp json(conn, body),
      do: conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(body))
  end

  describe "an account's invite inbox, made when AtMcp starts" do
    @describetag inbox_readers: ["did:web:api.delve.town"]

    setup do
      previous = Application.get_env(:at_mcp, :network)
      Application.put_env(:at_mcp, :network, :delve)
      {:ok, _} = Plug.Cowboy.http(GroupHost, [], port: 0, ref: :inbox_group_host)

      Application.put_env(
        :at_mcp,
        :group_host,
        "http://localhost:#{:ranch.get_port(:inbox_group_host)}"
      )

      on_exit(fn ->
        Plug.Cowboy.shutdown(:inbox_group_host)
        Application.delete_env(:at_mcp, :group_host)

        if previous,
          do: Application.put_env(:at_mcp, :network, previous),
          else: Application.delete_env(:at_mcp, :network)
      end)
    end

    test "a missing inbox is made with its reader and registered, and its notice waits for get_group_invites",
         ctx do
      assert {:ok, _} = AtMcp.Effects.login(ctx.effects)

      # No inbox, so no group could invite this account yet. get_group_invites
      # is a read: it makes nothing, still lists the group host's invites,
      # and says the inbox comes shortly.
      assert {:error, %AtMcp.Effects.Failure{detail: "SpaceNotFound"}} =
               AtMcp.Effects.spaces(ctx.effects, :vouch_inbox, [])

      assert {:ok, before} = AtMcp.Effects.spaces(ctx.effects, :list_group_invites, [])
      assert before.inbox == nil
      assert before.inbox_note =~ "will be created shortly"
      assert [%{group: %{did: "did:plc:group"}}] = before.invites
      refute "inbox.ensure" in Enum.map(calls(ctx.log), & &1["method"])
      assert AtMcp.Effects.quota_status(ctx.effects).used == 0

      # InboxTokens' first pass for the account makes it.
      assert :ok = AtMcp.Spaces.InboxTokens.prepare(ctx.effects)
      assert_receive {:request, :post, url, _, _}, 5_000
      assert url =~ "town.delve.notification.registerSpace"
      assert "inbox.ensure" in Enum.map(calls(ctx.log), & &1["method"])

      # And tokens for it follow, as the second path.
      assert {:ok, %{status: _}} = AtMcp.Effects.spaces(ctx.effects, :vouch_inbox, [])

      # The account hears of its reader the first time it looks, in
      # get_notifications or get_group_invites, and once.
      assert {:ok, %{notice: notice}} = AtMcp.Effects.list_notifications(ctx.effects)
      assert notice =~ "listed reader of this account's invite inbox"
      assert {:ok, page} = AtMcp.Effects.list_notifications(ctx.effects)
      refute Map.has_key?(page, :notice)
      :persistent_term.put({AtMcp.Spaces, :owed_notice, "did:plc:oauthagent"}, notice)
      assert {:ok, %{notice: notice}} = AtMcp.Effects.spaces(ctx.effects, :list_group_invites, [])
      assert notice =~ "listed reader of this account's invite inbox"
      assert {:ok, again} = AtMcp.Effects.spaces(ctx.effects, :list_group_invites, [])
      refute Map.has_key?(again, :notice)
      assert again.notifications == "registered"
      refute Map.has_key?(again, :inbox_note)
    end

    test "an inbox the AppView reads as a listed member is registered at start, on a new session and every 30 minutes, with no tokens",
         ctx do
      assert {:ok, _} = AtMcp.Effects.login(ctx.effects)
      alias AtMcp.Spaces.InboxTokens
      on_exit(fn -> Application.delete_env(:at_mcp, :spaces_session_test_register_status) end)
      accounts = [{:agent, ctx.effects}]
      tokens = fn -> Enum.count(calls(ctx.log), &(&1["method"] == "space.delegationToken")) end
      drain = fn -> receive_all_registers(0) end

      # The first pass makes the inbox with its reader and registers it (and
      # the account's group's members space: the stand-in group host has one).
      {last, state} = InboxTokens.vouch_all(InboxTokens.initial(), accounts)
      assert last == %{agent: :reader}
      assert drain.() == 2
      assert tokens.() == 0

      # Passes within the keep-alive send nothing.
      {last, state} = InboxTokens.vouch_all(state, accounts)
      assert last == %{agent: :reader}
      assert drain.() == 0

      # A session established anew registers it again, without a token.
      state = %{state | renewed: MapSet.put(state.renewed, "did:plc:oauthagent")}
      {last, state} = InboxTokens.vouch_all(state, accounts)
      assert last == %{agent: "registered"}
      assert drain.() == 2

      # So does the keep-alive, 30 minutes on.
      state = put_in(state.modes.agent.at, state.modes.agent.at - InboxTokens.keepalive_ms())
      {%{agent: "registered"}, state} = InboxTokens.vouch_all(state, accounts)
      assert drain.() == 1
      assert tokens.() == 0

      # An AppView that won't read it as a member: a token at once, then at
      # most every 8 minutes, whatever it answers.
      Application.put_env(:at_mcp, :spaces_session_test_register_status, "disabled")
      state = put_in(state.modes.agent.at, state.modes.agent.at - InboxTokens.keepalive_ms())
      {_, state} = InboxTokens.vouch_all(state, accounts)
      assert tokens.() == 1
      {_, state} = InboxTokens.vouch_all(state, accounts)
      assert tokens.() == 1
      state = update_in(state.modes.agent.token_at, &(&1 - InboxTokens.token_ms()))
      {_, _state} = InboxTokens.vouch_all(state, accounts)
      assert tokens.() == 2
    end

    test "an inbox whose owner removed the AppView gets tokens, and the reader isn't added again",
         ctx do
      assert {:ok, _} = AtMcp.Effects.login(ctx.effects)
      alias AtMcp.Spaces.InboxTokens
      accounts = [{:agent, ctx.effects}]
      tokens = fn -> Enum.count(calls(ctx.log), &(&1["method"] == "space.delegationToken")) end

      {%{agent: :reader}, _} = InboxTokens.vouch_all(InboxTokens.initial(), accounts)

      # The owner takes the AppView off its inbox; at_mcp starts again.
      {:ok, _} =
        AtMcp.Spaces.Helper.call("space.members.remove", %{
          did: "did:plc:oauthagent",
          space: "at:space/did:plc:oauthagent/org.atgrp.inbox/self",
          members: ["did:web:api.delve.town"]
        })

      {%{agent: :tokens}, state} = InboxTokens.vouch_all(InboxTokens.initial(), accounts)
      assert tokens.() == 1
      {%{agent: :tokens}, _} = InboxTokens.vouch_all(state, accounts)
      assert tokens.() == 1

      # Not added back.
      session =
        AtMcp.Spaces.Login.session(
          elem(AtMcp.Spaces.Login.credentials("did:plc:oauthagent"), 1),
          "agent.test"
        )

      assert {:ok, _space, "off", nil} = AtMcp.Spaces.ensure_inbox(session)
    end

    test "a group with the AppView as a member is registered once, with no tokens; one without gets tokens at most every 8 minutes",
         ctx do
      assert {:ok, _} = AtMcp.Effects.login(ctx.effects)
      alias AtMcp.Spaces.InboxTokens
      on_exit(fn -> Application.delete_env(:at_mcp, :spaces_session_test_appview_member) end)
      accounts = [{:agent, ctx.effects}]

      group_tokens = fn ->
        Enum.count(
          calls(ctx.log),
          &(&1["method"] == "space.delegationToken" and &1["params"]["space"] =~ "did:plc:group")
        )
      end

      # The AppView is a member: the members space is registered at the
      # first pass (beside the inbox), then nothing.
      {_, state} = InboxTokens.vouch_all(InboxTokens.initial(), accounts)
      assert receive_all_registers(0) == 2
      assert group_tokens.() == 0
      {_, state} = InboxTokens.vouch_all(state, accounts)
      assert receive_all_registers(0) == 0

      # A new session registers it again.
      state = %{state | renewed: MapSet.put(state.renewed, "did:plc:oauthagent")}
      {_, _state} = InboxTokens.vouch_all(state, accounts)
      assert receive_all_registers(0) == 2
      assert group_tokens.() == 0

      # A group without the AppView: a token for its members space and its
      # feed at once, then none within 8 minutes, then the next.
      Application.put_env(:at_mcp, :spaces_session_test_appview_member, false)
      {_, state} = InboxTokens.vouch_all(InboxTokens.initial(), accounts)
      assert group_tokens.() == 2
      {_, state} = InboxTokens.vouch_all(state, accounts)
      assert group_tokens.() == 2

      state =
        update_in(
          state.groups.agent.groups["did:plc:group"].token_at,
          &(&1 - InboxTokens.token_ms())
        )

      {_, _state} = InboxTokens.vouch_all(state, accounts)
      assert group_tokens.() == 4
    end

    test "an inbox grant the AppView asks for is approved with the account's key, then registered again",
         ctx do
      assert {:ok, _} = AtMcp.Effects.login(ctx.effects)
      on_exit(fn -> Application.delete_env(:at_mcp, :spaces_session_test_register_status) end)

      Application.put_env(:at_mcp, :spaces_session_test_register_status, [
        %{
          status: "grantNeeded",
          requestUri: "urn:req:inbox",
          authorizationUrl:
            "https://pds.invalid/oauth/authorize?client_id=x&request_uri=urn:req:inbox"
        },
        %{status: "registered"}
      ])

      # The account's login key, which approves it.
      key = AtMcp.Spaces.key_path("did:plc:oauthagent")
      File.mkdir_p!(Path.dirname(key))
      File.write!(key, "{}")
      on_exit(fn -> File.rm(key) end)

      assert {:ok, %{notifications: "registered"}} = AtMcp.Spaces.prepare_inbox(session_of())
      assert receive_all_registers(0) == 2

      [approve] = Enum.filter(calls(ctx.log), &(&1["method"] == "oauth.approveFor"))

      assert %{
               "account" => "did:plc:oauthagent",
               "clientId" => "https://api.delve.town/oauth/client-metadata.json",
               "scope" => "atproto space:org.atgrp.inbox?authority=self&action=read",
               "authorizationUrl" =>
                 "https://pds.invalid/oauth/authorize?client_id=x&request_uri=urn:req:inbox"
             } = approve["params"]
    end

    test "grantNeeded is registered all the same: an approval that fails leaves the token's registration standing",
         ctx do
      assert {:ok, _} = AtMcp.Effects.login(ctx.effects)
      on_exit(fn -> Application.delete_env(:at_mcp, :spaces_session_test_register_status) end)

      # No login key here, so the inbox grant can't be approved.
      File.rm(AtMcp.Spaces.key_path("did:plc:oauthagent"))

      Application.put_env(:at_mcp, :spaces_session_test_register_status, [
        %{
          status: "grantNeeded",
          requestUri: "urn:req:inbox",
          authorizationUrl:
            "https://pds.invalid/oauth/authorize?client_id=x&request_uri=urn:req:inbox"
        }
      ])

      assert {:ok, %{notifications: "grantNeeded"}} = AtMcp.Spaces.prepare_inbox(session_of())
      assert {:ok, %{status: "grantNeeded"}} = AtMcp.Spaces.vouch_inbox(session_of())
      assert receive_all_registers(0) == 2
      assert Enum.filter(calls(ctx.log), &(&1["method"] == "oauth.approveFor")) == []
    end

    test "a group grant is approved as a member only when it is the AppView asking for read alone",
         ctx do
      assert {:ok, _} = AtMcp.Effects.login(ctx.effects)

      on_exit(fn ->
        Application.delete_env(:at_mcp, :spaces_session_test_register_status)
        Application.delete_env(:at_mcp, :spaces_session_test_authorization)
      end)

      appview = AtMcp.Spaces.appview_client_id()
      need = %{status: "grantNeeded", requestUri: "urn:req:group"}
      register = fn -> AtMcp.Effects.spaces(ctx.effects, :group_spaces, [[register: true]]) end

      # Another app, or the AppView asking for more than read: nothing approved.
      for asked <- [
            %{
              client: %{clientId: "https://other.example/client.json"},
              requested: [%{scope: "atproto"}]
            },
            %{
              client: %{clientId: appview},
              requested: [%{scope: "atproto"}, %{scope: "include:org.atgrp.authManageAdmin"}]
            },
            # Read beside a write: a substring check took it for read.
            %{
              client: %{clientId: appview},
              requested: [
                %{scope: "atproto"},
                %{scope: "space:town.delve.space.feed?authority=self&action=read&action=create"}
              ]
            },
            # No action at all is read, create, update and delete.
            %{
              client: %{clientId: appview},
              requested: [%{scope: "atproto"}, %{scope: "space:town.delve.space.feed"}]
            },
            # Another space type than the notifications read.
            %{
              client: %{clientId: appview},
              requested: [%{scope: "atproto"}, %{scope: "space:org.atgrp.meta?action=read"}]
            },
            # Asks for read, but the host would grant more.
            %{
              client: %{clientId: appview},
              requested: [
                %{scope: "atproto"},
                %{scope: "space:org.atgrp.members?authority=self&action=read"}
              ],
              groups: [
                %{
                  did: "did:plc:group",
                  granted: [
                    %{scope: "space:org.atgrp.members?authority=self&action=read&manage=update"}
                  ]
                }
              ]
            }
          ] do
        Application.put_env(:at_mcp, :spaces_session_test_register_status, [
          need,
          %{status: "registered"}
        ])

        Application.put_env(:at_mcp, :spaces_session_test_authorization, asked)
        _ = register.()
        refute_received {:approved, _}
      end

      # The AppView, for read alone: approved for the group.
      Application.put_env(:at_mcp, :spaces_session_test_register_status, [
        need,
        %{status: "registered"}
      ])

      Application.put_env(:at_mcp, :spaces_session_test_authorization, %{
        client: %{clientId: appview},
        requested: [
          %{scope: "atproto"},
          %{scope: "space:org.atgrp.members?authority=self&action=read"},
          %{scope: "space:town.delve.space.feed?authority=self&action=read"}
        ]
      })

      # A member who isn't an admin doesn't approve it in routine sync.
      Application.put_env(:at_mcp, :spaces_session_test_roles, ["member"])
      on_exit(fn -> Application.delete_env(:at_mcp, :spaces_session_test_roles) end)

      Application.put_env(:at_mcp, :spaces_session_test_register_status, [
        need,
        %{status: "registered"}
      ])

      _ = register.()
      refute_received {:approved, _}

      # An admin does.
      Application.delete_env(:at_mcp, :spaces_session_test_roles)

      Application.put_env(:at_mcp, :spaces_session_test_register_status, [
        need,
        %{status: "registered"}
      ])

      _ = register.()
      assert_received {:approved, %{"requestUri" => "urn:req:group", "group" => "did:plc:group"}}
    end

    test "an outside app signs in as the account only after its request was previewed, and gets exactly that",
         ctx do
      assert {:ok, _} = AtMcp.Effects.login(ctx.effects)
      key = AtMcp.Spaces.key_path("did:plc:oauthagent")
      File.mkdir_p!(Path.dirname(key))
      File.write!(key, "{}")
      on_exit(fn -> File.rm(key) end)
      url = "#{ctx.fake_service}/oauth/authorize?client_id=x&request_uri=urn:req:app"

      # Approving with no preview is refused.
      assert {:error, %AtMcp.Effects.Failure{detail: :not_previewed}} =
               AtMcp.Effects.spaces(ctx.effects, :approve_app_sign_in, [url, false])

      # An authorize URL elsewhere than the account's own PDS isn't taken.
      assert {:error, %AtMcp.Effects.Failure{message: elsewhere}} =
               AtMcp.Effects.spaces(ctx.effects, :preview_app_sign_in, [
                 "https://other.example/oauth/authorize?request_uri=x"
               ])

      assert elsewhere =~ "this account's own PDS"

      # Nor one asking to sign in as another account.
      assert {:error, %AtMcp.Effects.Failure{detail: :another_account}} =
               AtMcp.Effects.spaces(ctx.effects, :preview_app_sign_in, [
                 url <> "&hint=did:plc:someone"
               ])

      assert {:ok, preview} = AtMcp.Effects.spaces(ctx.effects, :preview_app_sign_in, [url])
      assert preview.app.client_id == "https://app.example/client-metadata.json"
      assert preview.redirect_url == "https://app.example/callback"

      assert "act as this account in full, as an app password does: post, follow, change its profile and settings, and read what it can read (not its email or other accounts)" in preview.granted_in_words

      assert "read in any such space it can reach town.delve.space.feed spaces" in preview.granted_in_words

      assert {:ok, approved} =
               AtMcp.Effects.spaces(ctx.effects, :approve_app_sign_in, [url, false])

      assert approved.approved and approved.callback_url =~ "https://app.example/callback?code="
      assert approved.note =~ "Hand callback_url back to the app"

      [signed] = Enum.filter(calls(ctx.log), &(&1["method"] == "oauth.approveApp"))

      assert %{
               "clientId" => "https://app.example/client-metadata.json",
               "scope" =>
                 "atproto transition:generic space:town.delve.space.feed?authority=*&action=read",
               "redirectUri" => "https://app.example/callback"
             } = signed["params"]

      # The preview is spent: approving again needs another.
      assert {:error, %AtMcp.Effects.Failure{detail: :not_previewed}} =
               AtMcp.Effects.spaces(ctx.effects, :approve_app_sign_in, [url, false])

      # Denied: nothing signed.
      assert {:ok, _} = AtMcp.Effects.spaces(ctx.effects, :preview_app_sign_in, [url])

      assert {:ok, %{denied: true, approved: false}} =
               AtMcp.Effects.spaces(ctx.effects, :approve_app_sign_in, [url, true])

      assert Enum.count(calls(ctx.log), &(&1["method"] == "oauth.approveApp")) == 1
    end

    test "a failed attempt to make an inbox is tried again soon, then less often, up to the pass" do
      every = AtMcp.Spaces.InboxTokens.every_ms()

      delays =
        Enum.scan(1..7, nil, fn _, prev ->
          AtMcp.Spaces.InboxTokens.next_delay(prev && %{delay: prev}, 5_000, every)
        end)

      assert delays == [5_000, 10_000, 20_000, 40_000, 80_000, 100_000, 100_000]
    end
  end

  describe "approve_group_app" do
    setup do
      {:ok, _} = Plug.Cowboy.http(GroupHost, [], port: 0, ref: :spaces_group_host)
      port = :ranch.get_port(:spaces_group_host)
      Application.put_env(:at_mcp, :group_host, "http://localhost:#{port}")

      on_exit(fn ->
        Plug.Cowboy.shutdown(:spaces_group_host)
        Application.delete_env(:at_mcp, :group_host)
      end)
    end

    test "a group is reached by its handle, and joining it answers its feeds; get_my_groups lists them",
         ctx do
      previous = Application.get_env(:at_mcp, :network)
      Application.put_env(:at_mcp, :network, :delve)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:at_mcp, :network, previous),
          else: Application.delete_env(:at_mcp, :network)
      end)

      assert {:ok, _} = AtMcp.Effects.login(ctx.effects)
      feed = "at:space/did:plc:group/town.delve.space.feed/general"

      assert {:ok, joined} =
               AtMcp.Effects.spaces(
                 ctx.effects,
                 :join_group,
                 ["did:plc:group"],
                 :accept_group_invite
               )

      assert joined["group"].feeds == [feed]
      assert joined["group"].description == "A group"
      assert_received {:joined, %{"group" => "did:plc:group"}}

      assert {:ok, %{groups: [group]}} = AtMcp.Effects.spaces(ctx.effects, :get_my_groups, [])
      assert group.did == "did:plc:group" and group.feeds == [feed]
    end

    test "a group's handle that does not resolve is found among the account's invites", ctx do
      previous = Application.get_env(:at_mcp, :network)
      Application.put_env(:at_mcp, :network, :delve)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:at_mcp, :network, previous),
          else: Application.delete_env(:at_mcp, :network)
      end)

      assert {:ok, _} = AtMcp.Effects.login(ctx.effects)

      # The stand-in PDS resolves no handle; the invite names this one.
      assert {:ok, _} =
               AtMcp.Effects.spaces(
                 ctx.effects,
                 :join_group,
                 ["@G.groups.test"],
                 :accept_group_invite
               )

      assert_received {:joined, %{"group" => "did:plc:group"}}

      assert {:error, %AtMcp.Effects.Failure{} = failure} =
               AtMcp.Effects.spaces(
                 ctx.effects,
                 :join_group,
                 ["nobody.groups.test"],
                 :accept_group_invite
               )

      assert inspect(failure) =~ "does not resolve"
    end

    test "an invite's group is named as the group host names it", ctx do
      assert {:ok, _} = AtMcp.Effects.login(ctx.effects)

      assert {:ok, named} =
               AtMcp.Effects.spaces(ctx.effects, :invite_groups, [["did:plc:group"]])

      assert named["did:plc:group"] == %{handle: "g.groups.test", display_name: "G"}
    end

    # Membership is two-sided: the member writes its confirmation in the
    # group's members space, which the roster counts.
    test "joining writes this account's confirmation in the group's members space; leaving removes it first",
         ctx do
      previous = Application.get_env(:at_mcp, :network)
      Application.put_env(:at_mcp, :network, :delve)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:at_mcp, :network, previous),
          else: Application.delete_env(:at_mcp, :network)
      end)

      assert {:ok, _} = AtMcp.Effects.login(ctx.effects)
      members = "at:space/did:plc:group/org.atgrp.members/self"

      assert {:ok, joined} =
               AtMcp.Effects.spaces(
                 ctx.effects,
                 :join_group,
                 ["did:plc:group"],
                 :accept_group_invite
               )

      assert joined["confirmed"] == true
      # As the group host counts it.
      assert joined["group"].confirmed == true
      [put] = Enum.filter(calls(ctx.log), &(&1["method"] == "space.records.put"))

      assert %{"space" => ^members, "collection" => "org.atgrp.confirmation", "rkey" => "self"} =
               put["params"]

      assert {:ok, _, _} = DateTime.from_iso8601(put["params"]["record"]["createdAt"])

      assert {:ok, left} = AtMcp.Effects.spaces(ctx.effects, :leave_group, ["did:plc:group"])
      assert left.confirmation_removed
      methods = Enum.map(calls(ctx.log), & &1["method"])
      assert "space.records.delete" in methods
      [del] = Enum.filter(calls(ctx.log), &(&1["method"] == "space.records.delete"))
      assert del["params"]["collection"] == "org.atgrp.confirmation"
    end

    # A confirmation is the member's own consent to appear in the roster: a
    # group can make someone a member who never asked.
    test "a membership this account never asked for gets no confirmation; one it asked for, admitted later, does",
         ctx do
      previous = Application.get_env(:at_mcp, :network)
      Application.put_env(:at_mcp, :network, :delve)
      File.rm(AtMcp.Spaces.asked_path())

      on_exit(fn ->
        Application.delete_env(:at_mcp, :spaces_session_test_join)
        File.rm(AtMcp.Spaces.asked_path())

        if previous,
          do: Application.put_env(:at_mcp, :network, previous),
          else: Application.delete_env(:at_mcp, :network)
      end)

      assert {:ok, _} = AtMcp.Effects.login(ctx.effects)
      alias AtMcp.Spaces.InboxTokens
      puts = fn -> Enum.count(calls(ctx.log), &(&1["method"] == "space.records.put")) end

      # The stand-in group host lists this account as a member of a group it
      # never asked to join: InboxTokens confirms nothing.
      {_, _} = InboxTokens.vouch_all(InboxTokens.initial(), [{:agent, ctx.effects}])
      assert puts.() == 0

      # It asks; the group decides later. Admitted, the next first sight of
      # the group confirms it, once.
      Application.put_env(:at_mcp, :spaces_session_test_join, "pending")

      assert {:ok, %{"status" => "pending"}} =
               AtMcp.Effects.spaces(ctx.effects, :join_group, ["did:plc:group"])

      assert puts.() == 0
      {_, state} = InboxTokens.vouch_all(InboxTokens.initial(), [{:agent, ctx.effects}])
      assert puts.() == 1
      {_, _} = InboxTokens.vouch_all(InboxTokens.initial(), [{:agent, ctx.effects}])
      assert puts.() == 1
      _ = state

      # And the account can confirm a group that added it, itself.
      assert {:ok, %{confirmed: true}} =
               AtMcp.Effects.spaces(
                 ctx.effects,
                 :confirm_group,
                 ["did:plc:group"],
                 :confirm_group_membership
               )

      assert puts.() == 2
    end

    test "create_group founds the group on the group host, makes its feed as the group, confirms the founder and asks the AppView in",
         ctx do
      delve(ctx)
      assert {:ok, _} = AtMcp.Effects.login(ctx.effects)

      assert {:ok, made} =
               AtMcp.Effects.spaces(ctx.effects, :create_group, [
                 %{
                   name: "Garden-Club",
                   display_name: "Garden Club",
                   description: "We grow",
                   join_policy: "invite"
                 }
               ])

      # createGroup with the handle under the host's domain.
      assert_received {:created, created}

      # Founded with the policy asked for, which the host then has.
      assert created == %{
               "handle" => "garden-club.groups.test",
               "displayName" => "Garden Club",
               "description" => "We grow",
               "joinPolicy" => "invite"
             }

      assert made.join_policy == "invite" and made.join_policy_confirmed

      assert made.group.did == "did:plc:newgroup" and made.role == "admin"
      assert made.feeds == ["at:space/did:plc:newgroup/town.delve.space.feed/general"]
      assert made.confirmed
      assert made.next =~ "invite_to_group (group: did:plc:newgroup)"
      assert made.notifications_member =~ "read grant"

      # Its feed, made as the group: members read and write, the bot reads.
      acts = Enum.filter(calls(ctx.log), &(&1["method"] == "group.act"))

      # The bot role first: the feed's policy names it.
      [role | _] = acts
      assert role["params"]["space"] == "at:space/did:plc:newgroup/org.atgrp.members/self"

      assert [%{"body" => %{"collection" => "org.atgrp.role", "rkey" => "bot"}}] =
               role["params"]["calls"]

      act = Enum.find(acts, &(&1["params"]["space"] =~ "town.delve.space.feed"))
      assert act["params"]["group"] == "did:plc:newgroup"
      assert act["params"]["space"] == "at:space/did:plc:newgroup/town.delve.space.feed/general"
      [%{"method" => "com.atproto.space.createSpace", "body" => space}] = act["params"]["calls"]

      assert space["policy"]["grants"] == [
               %{"role" => "member", "read" => true, "write" => true},
               %{"role" => "bot", "read" => true}
             ]

      # The founder's confirmation, since it asked.
      assert Enum.any?(
               calls(ctx.log),
               &(&1["method"] == "space.records.put" and
                   &1["params"]["space"] == "at:space/did:plc:newgroup/org.atgrp.members/self")
             )

      # The AppView is asked to read the members space, then admitted as a
      # bot member once its request is there (the stand-in lists one).
      assert_receive {:request, :post, url, _, _}, 5_000
      assert url =~ "notification.registerSpace"

      assert {:ok, _} = AtMcp.Spaces.add_notifications_member(session_of(), "did:plc:newgroup")

      admits =
        Enum.filter(
          calls(ctx.log),
          &(&1["method"] == "group.act" and &1["params"]["space"] =~ "org.atgrp.members")
        )

      writes =
        admits
        |> List.last()
        |> get_in(["params", "calls"])
        |> Enum.map(& &1["body"]["collection"])

      assert writes == ["org.atgrp.role", "org.atgrp.membership"]

      membership =
        admits |> List.last() |> get_in(["params", "calls"]) |> List.last() |> get_in(["body"])

      assert membership["rkey"] == "did:web:api.delve.town"
      assert membership["record"]["roles"] == ["member", "bot"]
    end

    test "create_group says when the group host has another join policy than the one asked for",
         ctx do
      delve(ctx)
      assert {:ok, _} = AtMcp.Effects.login(ctx.effects)
      Application.put_env(:at_mcp, :spaces_session_test_policy, "open")
      on_exit(fn -> Application.delete_env(:at_mcp, :spaces_session_test_policy) end)

      assert {:ok, made} =
               AtMcp.Effects.spaces(ctx.effects, :create_group, [
                 %{name: "closed", display_name: "Closed", join_policy: "invite"}
               ])

      assert made.join_policy == "open"
      refute made.join_policy_confirmed
      assert made.join_policy_note =~ "not invite"
    end

    test "create_group says plainly why a group wasn't made, and checks the name before sending anything",
         ctx do
      delve(ctx)
      assert {:ok, _} = AtMcp.Effects.login(ctx.effects)
      on_exit(fn -> Application.delete_env(:at_mcp, :spaces_session_test_create) end)

      create = fn name ->
        AtMcp.Effects.spaces(ctx.effects, :create_group, [%{name: name, display_name: "G"}])
      end

      assert {:error, %AtMcp.Effects.Failure{message: bad}} = create.("not a label")
      assert bad =~ "one label of letters, numbers and hyphens"
      refute_received {:created, _}

      for {answer, says} <- [
            {{400, "HandleTaken", "taken"}, "garden.groups.test is taken: choose another name."},
            {{403, "NotAllowed", "groups.example starts groups for its town's members"},
             "The group host refused (groups.example starts groups for its town's members). No group was made."},
            {{503, "FounderCheckUnavailable", "the AppView is down"},
             "No group was made; try again in a minute."}
          ] do
        Application.put_env(:at_mcp, :spaces_session_test_create, answer)
        assert {:error, %AtMcp.Effects.Failure{message: message}} = create.("garden")
        assert message =~ says
      end
    end

    test "invite_to_group writes the invite as the group into their inbox; join requests are listed, admitted and denied",
         ctx do
      delve(ctx)
      assert {:ok, _} = AtMcp.Effects.login(ctx.effects)

      assert {:ok, %{invited: "did:plc:friend", invite: invite}} =
               AtMcp.Effects.spaces(ctx.effects, :invite_to_group, [
                 "did:plc:group",
                 "did:plc:friend",
                 "join us"
               ])

      assert invite =~ "at:space/did:plc:friend/org.atgrp.inbox/self"
      act = calls(ctx.log) |> Enum.filter(&(&1["method"] == "group.act")) |> List.last()
      assert act["params"]["space"] == "at:space/did:plc:friend/org.atgrp.inbox/self"
      [%{"method" => "com.atproto.space.createRecord", "body" => body}] = act["params"]["calls"]
      assert body["collection"] == "org.atgrp.invite" and body["record"]["message"] == "join us"

      # The group host names the asker by DID alone; their profile names them.
      assert {:ok, %{requests: [%{"member" => "did:plc:friend", "actor" => actor} | _]}} =
               AtMcp.Effects.spaces(ctx.effects, :get_join_requests, ["did:plc:group"])

      assert actor["handle"] == "friend.test" and actor["displayName"] == "A Friend"

      assert {:ok, %{admitted: true}} =
               AtMcp.Effects.spaces(ctx.effects, :approve_join_request, [
                 "did:plc:group",
                 "did:plc:friend"
               ])

      act = calls(ctx.log) |> Enum.filter(&(&1["method"] == "group.act")) |> List.last()
      [%{"body" => admit}] = act["params"]["calls"]
      assert admit["collection"] == "org.atgrp.membership" and admit["rkey"] == "did:plc:friend"
      assert admit["record"]["roles"] == ["member"]

      assert {:ok, %{removed: true}} =
               AtMcp.Effects.spaces(ctx.effects, :remove_group_member, [
                 "did:plc:group",
                 "did:plc:friend"
               ])

      act = calls(ctx.log) |> Enum.filter(&(&1["method"] == "group.act")) |> List.last()
      [%{"method" => "com.atproto.space.deleteRecord", "body" => out}] = act["params"]["calls"]
      assert out["collection"] == "org.atgrp.membership" and out["rkey"] == "did:plc:friend"

      assert {:ok, %{denied: true}} =
               AtMcp.Effects.spaces(ctx.effects, :deny_join_request, [
                 "did:plc:group",
                 "did:plc:friend"
               ])

      assert_received {:denied, %{"group" => "did:plc:group", "member" => "did:plc:friend"}}
    end

    test "approves for the group the app asked for, by handle, or the only one offered", ctx do
      assert {:ok, _} = AtMcp.Effects.login(ctx.effects)
      assert {:ok, _} = AtMcp.Effects.spaces(ctx.effects, :preview_group_app, ["urn:req", nil])

      assert {:ok, %{group: "did:plc:group", approved: true}} =
               AtMcp.Effects.spaces(ctx.effects, :approve_group_app, ["urn:req", nil, true])

      # Each approval spends its preview.
      assert {:error, %AtMcp.Effects.Failure{detail: :not_previewed}} =
               AtMcp.Effects.spaces(ctx.effects, :approve_group_app, ["urn:req", nil, true])

      assert {:ok, _} = AtMcp.Effects.spaces(ctx.effects, :preview_group_app, ["urn:req", nil])

      assert {:ok, %{group: "did:plc:group"}} =
               AtMcp.Effects.spaces(ctx.effects, :approve_group_app, [
                 "urn:req",
                 "@g.groups.test",
                 true
               ])
    end

    test "says which app gets what in which group, approves only a group the request offers, and turns an app away",
         ctx do
      assert {:ok, _} = AtMcp.Effects.login(ctx.effects)

      # Not previewed: nothing is approved, and the refusal names no group.
      assert {:error, %AtMcp.Effects.Failure{kind: :refused, detail: :not_previewed, message: m}} =
               AtMcp.Effects.spaces(ctx.effects, :approve_group_app, [
                 "urn:req",
                 "did:plc:group",
                 true
               ])

      refute m =~ "did:plc:"
      refute_received {:approved, _}

      # A refusal names no group: it can't be used to find one's DID.
      assert {:error,
              %AtMcp.Effects.Failure{kind: :refused, detail: :group_not_offered, message: msg}} =
               AtMcp.Effects.spaces(ctx.effects, :preview_group_app, ["urn:req", "did:plc:other"])

      refute msg =~ "did:"
      refute msg =~ "g.groups.test"

      assert {:ok, preview} =
               AtMcp.Effects.spaces(ctx.effects, :preview_group_app, ["urn:req", nil])

      assert preview.previewed and preview.approved == false
      assert preview.granted == ["atproto", "include:org.atgrp.authParticipate"]
      refute_received {:approved, _}

      # Previewed for one group, not approved for another.
      assert {:error, %AtMcp.Effects.Failure{kind: :refused}} =
               AtMcp.Effects.spaces(ctx.effects, :approve_group_app, [
                 "urn:req",
                 "did:plc:other",
                 true
               ])

      assert {:ok, approved} =
               AtMcp.Effects.spaces(ctx.effects, :approve_group_app, [
                 "urn:req",
                 "did:plc:group",
                 true
               ])

      assert approved.approved and approved.redirect_url =~ "code=c"
      assert approved.app.client_id == "https://app.example/client.json"
      assert approved.group == "did:plc:group"
      assert approved.granted == ["atproto", "include:org.atgrp.authParticipate"]
      assert approved.withheld == ["include:org.atgrp.authManageAdmin"]
      assert_received {:approved, %{"requestUri" => "urn:req", "group" => "did:plc:group"}}

      assert {:ok, denied} =
               AtMcp.Effects.spaces(ctx.effects, :approve_group_app, [
                 "urn:req",
                 "did:plc:group",
                 false
               ])

      assert denied.approved == false and denied.redirect_url =~ "access_denied"
      assert_received {:declined, %{"requestUri" => "urn:req"}}
      refute_received {:approved, _}
    end
  end

  defmodule PDS do
    # A stand-in town PDS for the agent routes: its DID, and createAgent and
    # enrollKey, which echo what they were sent.
    use Plug.Router
    plug(:match)
    plug(Plug.Parsers, parsers: [:json], json_decoder: Jason)
    plug(:dispatch)

    get("/xrpc/com.atproto.server.describeServer", do: json(conn, %{did: "did:web:pds.test"}))

    # A stand-in PLC directory: each DID's document names this PDS and a
    # signing key; did:plc:gone has none.
    get "/plc/:did" do
      if did == "did:plc:gone" do
        send_resp(conn, 404, "not found")
      else
        agent_of = Application.get_env(:at_mcp, :spaces_session_test_agent_of, %{})[did] || []

        json(conn, %{
          id: did,
          alsoKnownAs:
            ["at://#{did}.test"] ++ Enum.map(agent_of, &"https://ident.link/agent-of/#{&1}"),
          verificationMethod: [
            %{id: "#{did}#atproto", type: "Multikey", publicKeyMultibase: "zQ3shKey"}
          ],
          service: [
            %{
              id: "#atproto_pds",
              type: "AtprotoPersonalDataServer",
              serviceEndpoint: "https://pds.test"
            }
          ]
        })
      end
    end

    post "/xrpc/town.delve.agent.createAgent" do
      send(
        Application.fetch_env!(:at_mcp, :spaces_session_test_owner),
        {:agent_route, :create, conn.body_params}
      )

      # As the PDS answers now: the agent's password, once, and whether it
      # wrote the principal's endorsement (only for a principal it hosts).
      json(conn, %{
        did: "did:plc:newagent",
        handle: conn.body_params["handle"],
        password: "agent-secret-once",
        endorsed: false
      })
    end

    # Signing in as the agent with its password, and its account methods.
    post "/xrpc/com.atproto.server.createSession" do
      send(
        Application.fetch_env!(:at_mcp, :spaces_session_test_owner),
        {:agent_session, conn.body_params}
      )

      if conn.body_params["password"] in ["agent-secret-once", "agent-secret-rotated"],
        do: json(conn, %{accessJwt: "agent-access", did: conn.body_params["identifier"]}),
        else:
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(
            401,
            Jason.encode!(%{
              error: "AuthenticationRequired",
              message: "Invalid identifier or password"
            })
          )
    end

    post "/xrpc/com.atproto.server.deactivateAccount" do
      send(
        Application.fetch_env!(:at_mcp, :spaces_session_test_owner),
        {:agent_account, :deactivate, get_req_header(conn, "authorization")}
      )

      json(conn, %{})
    end

    post "/xrpc/com.atproto.server.activateAccount" do
      # As the PDS: no input, and a body refused.
      if get_req_header(conn, "content-length") not in [[], ["0"]],
        do: raise("activateAccount was sent a body")

      send(
        Application.fetch_env!(:at_mcp, :spaces_session_test_owner),
        {:agent_account, :activate, get_req_header(conn, "authorization")}
      )

      json(conn, %{})
    end

    post "/xrpc/town.delve.agent.rotatePassword" do
      send(
        Application.fetch_env!(:at_mcp, :spaces_session_test_owner),
        {:agent_route, :rotate, conn.body_params}
      )

      json(conn, %{password: "agent-secret-rotated"})
    end

    post "/xrpc/town.delve.agent.revokeSessions" do
      send(
        Application.fetch_env!(:at_mcp, :spaces_session_test_owner),
        {:agent_route, :revoke, conn.body_params}
      )

      # As the PDS answers: what may outlive the revoke.
      json(conn, %{
        revocationCompleteAt: "2026-11-28T16:05:00.000Z",
        outstanding: [%{kind: "serviceAuth", expiresAt: "2026-11-28T16:05:00.000Z"}]
      })
    end

    post "/xrpc/town.delve.agent.deleteAgent" do
      send(
        Application.fetch_env!(:at_mcp, :spaces_session_test_owner),
        {:agent_route, :delete, conn.body_params}
      )

      json(conn, %{})
    end

    post "/xrpc/town.delve.agent.offerTransfer" do
      if Application.get_env(:at_mcp, :spaces_session_test_transfers_off) do
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          501,
          Jason.encode!(%{error: "MethodNotImplemented", message: "Method Not Implemented"})
        )
      else
        send(
          Application.fetch_env!(:at_mcp, :spaces_session_test_owner),
          {:agent_route, :offer, conn.body_params}
        )

        if conn.body_params["cancel"],
          do: json(conn, %{}),
          else: json(conn, %{expiresAt: "2026-12-05T00:00:00.000Z"})
      end
    end

    post "/xrpc/town.delve.agent.acceptTransfer" do
      send(
        Application.fetch_env!(:at_mcp, :spaces_session_test_owner),
        {:agent_route, :accept, conn.body_params}
      )

      json(conn, %{
        did: conn.body_params["did"],
        principal: "did:plc:oauthagent",
        password: "agent-secret-handed",
        endorsed: false,
        oldEndorsement:
          "at://did:plc:oldprincipal/link.ident.endorsement/#{conn.body_params["did"]}"
      })
    end

    get "/xrpc/town.delve.agent.listAgents" do
      json(conn, %{
        agents: [],
        offers: [
          %{
            did: "did:plc:offered",
            handle: "offered.test",
            from: "did:plc:oldprincipal",
            expiresAt: "2026-12-05T00:00:00.000Z"
          }
        ]
      })
    end

    post "/xrpc/town.delve.agent.enrollKey" do
      send(
        Application.fetch_env!(:at_mcp, :spaces_session_test_owner),
        {:agent_route, :enroll, conn.body_params}
      )

      json(conn, %{})
    end

    defp json(conn, body),
      do: conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(body))
  end

  describe "a principal" do
    setup ctx do
      previous = Application.get_env(:at_mcp, :network)
      Application.put_env(:at_mcp, :network, :delve)
      keys = Path.join(System.tmp_dir!(), "principal-keys-#{System.unique_integer([:positive])}")
      Application.put_env(:at_mcp, :keys_dir, keys)

      on_exit(fn ->
        File.rm_rf(keys)
        Application.delete_env(:at_mcp, :keys_dir)

        if previous,
          do: Application.put_env(:at_mcp, :network, previous),
          else: Application.delete_env(:at_mcp, :network)
      end)

      write_accounts = fn rotation ->
        account = %{
          "id" => "principal",
          "handle" => "agent.test",
          "did" => "did:plc:oauthagent",
          "service" => ctx.fake_service,
          "key_file" => "/keys/agent.json"
        }

        account = if rotation, do: Map.put(account, "rotation_key", rotation), else: account
        {:ok, _} = AtMcp.AccountConfig.load(AtMcp.AccountConfig.path())
        File.rm(AtMcp.AccountConfig.path())
        {:ok, _} = AtMcp.AccountConfig.add(AtMcp.AccountConfig.path(), account)
      end

      on_exit(fn -> File.rm(AtMcp.AccountConfig.path()) end)
      # A principal here is a person, not itself an agent.
      :persistent_term.put({AtMcp.Spaces, :principal_of, "did:plc:oauthagent"}, :none)
      %{write_accounts: write_accounts}
    end

    @rotation "did:key:zDnaeTiq1PdzvZXUaMdezchcMJQpBdH2VN4pgrrEhMCCbmwSb"

    test "asks for the agent routes by name for its PDS's service, and an account that isn't one doesn't",
         ctx do
      ctx.write_accounts.(nil)
      refute AtMcp.Spaces.scope_for("did:plc:oauthagent", ctx.fake_service) =~ "rpc:"

      ctx.write_accounts.(@rotation)
      scope = AtMcp.Spaces.scope_for("did:plc:oauthagent", ctx.fake_service)
      aud = URI.encode_www_form("did:web:pds.test#atproto_pds")

      for m <- ~w(createAgent enrollKey revokeSessions deleteAgent rotatePassword),
          do: assert(scope =~ "rpc:town.delve.agent.#{m}?aud=#{aud}")

      refute scope =~ "aud=*"
      assert scope =~ "transition:generic"
    end

    test "creates an agent with the configured public rotation key and the new key's proof, and holds no private rotation key",
         ctx do
      ctx.write_accounts.(nil)
      assert {:ok, _} = AtMcp.Effects.login(ctx.effects)

      assert {:error, %AtMcp.Effects.Failure{detail: :no_rotation_key, message: msg}} =
               AtMcp.Effects.spaces(ctx.effects, :create_agent, ["Helper.Test", "code"])

      assert msg =~ "at_mcp-accounts rotation-key"
      refute_received {:agent_route, _, _}

      ctx.write_accounts.(@rotation)

      for bare <- ["helper", "helper.", "@helper.test", "help er.test"] do
        assert {:error, %AtMcp.Effects.Failure{kind: :refused, message: msg}} =
                 AtMcp.Effects.spaces(ctx.effects, :create_agent, [bare, "code"])

        assert msg =~ "such as helper.delve.town"
      end

      refute_received {:agent_route, :create, _}

      assert {:ok, created} =
               AtMcp.Effects.spaces(ctx.effects, :create_agent, ["Helper.Test", "code"])

      assert created.rotation_key == @rotation
      assert created.next =~ "at_mcp-accounts add-agent NAME --did did:plc:newagent"

      assert_received {:agent_route, :create, body}
      assert body["recoveryKey"] == @rotation
      assert body["rotationKey"] == @rotation

      # The password the PDS gave once is kept nowhere, nor shown.
      refute inspect(created) =~ "agent-secret-once"
      assert created.password =~ "not kept"

      refute Enum.any?(
               Path.wildcard(Path.join(AtMcp.Inbound.Store.default_dir(), "**/*")),
               &(File.regular?(&1) and File.read!(&1) =~ "agent-secret-once")
             )

      # The agent's state space, made on this principal's PDS, with the agent
      # as a read/write member beside it.
      [made] = Enum.filter(calls(ctx.log), &(&1["method"] == "space.create"))

      assert %{
               "type" => "town.delve.space.agent",
               "skey" => "did:plc:newagent",
               "policy" => "member"
             } =
               made["params"]

      assert %{"did" => "did:plc:newagent", "read" => true, "write" => true} in made["params"][
               "members"
             ]

      assert created.agent_space ==
               "at:space/did:plc:oauthagent/town.delve.space.agent/did:plc:newagent"

      assert "proof:" <> bound = body["loginKeyProof"]

      assert Jason.decode!(bound) == %{
               "iss" => "did:plc:oauthagent",
               "sub" => "helper.test",
               "aud" => "did:web:pds.test",
               "lxm" => "town.delve.agent.createAgent"
             }

      # Only agents' login keys are in the key folder: no rotation key.
      refute Enum.any?(File.ls!(AtMcp.Spaces.keys_dir()), &String.contains?(&1, "rotation"))
    end

    test "an agent is offered to another principal, withdrawn, and one offered here is listed and accepted",
         ctx do
      ctx.write_accounts.(@rotation)
      assert {:ok, _} = AtMcp.Effects.login(ctx.effects)

      assert {:ok, %{to: "did:plc:next", expires_at: "2026-12-05T00:00:00.000Z", next: next}} =
               AtMcp.Effects.spaces(ctx.effects, :offer_agent_handoff, [
                 "did:plc:mine",
                 "did:plc:next",
                 nil
               ])

      assert next =~ "accept_agent_handoff" and next =~ "72 hours"
      assert_received {:agent_route, :offer, %{"did" => "did:plc:mine", "to" => "did:plc:next"}}

      assert {:ok, %{cancelled: true}} =
               AtMcp.Effects.spaces(ctx.effects, :offer_agent_handoff, [
                 "did:plc:mine",
                 nil,
                 true
               ])

      assert_received {:agent_route, :offer, %{"did" => "did:plc:mine", "cancel" => true}}

      assert {:ok, %{offers: [%{did: "did:plc:offered", from: "did:plc:oldprincipal"}]}} =
               AtMcp.Effects.spaces(ctx.effects, :get_agent_handoff_offers, [])

      assert {:ok, accepted} =
               AtMcp.Effects.spaces(ctx.effects, :accept_agent_handoff, ["did:plc:offered"])

      # With this account's public rotation key, as at creation.
      assert_received {:agent_route, :accept,
                       %{"did" => "did:plc:offered", "recoveryKey" => @rotation}}

      # The password the PDS gives once is kept nowhere, nor shown; the
      # agent, stopped by the accept, is re-keyed when started here.
      refute inspect(accepted) =~ "agent-secret-handed"
      assert accepted.next =~ "at_mcp-accounts repair NAME --principal"
      assert AtMcp.Spaces.AgentRevocations.revoked?("did:plc:oauthagent", "did:plc:offered")
      assert accepted.previous_principal == "did:plc:oldprincipal"

      # Its state space, made here with the agent as a member, for the agent
      # to carry its records into.
      [made] = Enum.filter(calls(ctx.log), &(&1["method"] == "space.create"))
      assert made["params"]["skey"] == "did:plc:offered"

      assert %{"did" => "did:plc:offered", "read" => true, "write" => true} in made["params"][
               "members"
             ]

      assert accepted.agent_space ==
               "at:space/did:plc:oauthagent/town.delve.space.agent/did:plc:offered"

      assert accepted.next =~
               "at:space/did:plc:oldprincipal/town.delve.space.agent/did:plc:offered"
    end

    test "the hand-off routes off at the PDS are said as such", ctx do
      ctx.write_accounts.(@rotation)
      assert {:ok, _} = AtMcp.Effects.login(ctx.effects)
      Application.put_env(:at_mcp, :spaces_session_test_transfers_off, true)
      on_exit(fn -> Application.delete_env(:at_mcp, :spaces_session_test_transfers_off) end)

      assert {:error, %AtMcp.Effects.Failure{kind: :refused, message: message}} =
               AtMcp.Effects.spaces(ctx.effects, :offer_agent_handoff, [
                 "did:plc:mine",
                 "did:plc:next",
                 nil
               ])

      assert message =~ "doesn't offer agent hand-offs"
    end

    test "revoking an agent's sessions says what the PDS says may outlive it, and what other services hold",
         ctx do
      ctx.write_accounts.(@rotation)
      assert {:ok, _} = AtMcp.Effects.login(ctx.effects)

      assert {:ok, revoked} =
               AtMcp.Effects.spaces(ctx.effects, :revoke_agent_sessions, ["did:plc:mine"])

      assert revoked.revoked == true
      assert revoked.revocation_complete_at == "2026-11-28T16:05:00.000Z"
      assert [%{"kind" => "serviceAuth"}] = revoked.outstanding
      assert revoked.elsewhere =~ "15 minutes"
    end

    test "an agent stops with a password the PDS gives for it then: deactivated, and its sessions revoked; started again, active with a new key",
         ctx do
      ctx.write_accounts.(@rotation)
      assert {:ok, _} = AtMcp.Effects.login(ctx.effects)
      assert {:ok, _} = AtMcp.Effects.spaces(ctx.effects, :create_agent, ["helper.test", "code"])

      assert {:ok, %{status: "deactivated", revoked: true}} =
               AtMcp.Effects.spaces(ctx.effects, :set_agent_status, [
                 "did:plc:newagent",
                 "deactivated"
               ])

      # Signed in with a fresh password, never the one from creation.
      assert_received {:agent_route, :rotate, %{"did" => "did:plc:newagent"}}

      assert_received {:agent_session,
                       %{"identifier" => "did:plc:newagent", "password" => "agent-secret-rotated"}}

      refute_received {:agent_session, %{"password" => "agent-secret-once"}}
      assert_received {:agent_account, :deactivate, ["Bearer agent-access"]}
      assert_received {:agent_route, :revoke, %{"did" => "did:plc:newagent"}}
      assert AtMcp.Spaces.AgentRevocations.revoked?("did:plc:oauthagent", "did:plc:newagent")

      assert {:ok, %{status: "active"} = started} =
               AtMcp.Effects.spaces(ctx.effects, :set_agent_status, ["did:plc:newagent", "active"])

      refute Map.has_key?(started, :revoked)
      # Revoking retired its login key: it gets a new one, which replaces
      # the old one in place, kept nowhere else.
      assert started.new_login_key == true
      assert_received {:agent_route, :enroll, %{"did" => "did:plc:newagent"}}
      assert_received {:agent_route, :rotate, %{"did" => "did:plc:newagent"}}
      assert_received {:agent_account, :activate, ["Bearer agent-access"]}
      refute AtMcp.Spaces.AgentRevocations.revoked?("did:plc:oauthagent", "did:plc:newagent")
      assert File.ls!(AtMcp.Spaces.keys_dir()) |> Enum.filter(&(&1 =~ "replaced")) == []
    end

    test "an agent created with no handle gets one from the PDS; its key's proof names the key itself",
         ctx do
      ctx.write_accounts.(@rotation)
      assert {:ok, _} = AtMcp.Effects.login(ctx.effects)

      assert {:ok, %{did: "did:plc:newagent", login_key: login_key}} =
               AtMcp.Effects.spaces(ctx.effects, :create_agent, [nil, "code"])

      assert_received {:agent_route, :create, body}
      refute Map.has_key?(body, "handle")
      assert "proof:" <> bound = body["loginKeyProof"]
      assert Jason.decode!(bound)["sub"] == login_key
    end

    test "an agent creates agents too, and makes their state spaces as their principal", ctx do
      ctx.write_accounts.(@rotation)
      assert {:ok, _} = AtMcp.Effects.login(ctx.effects)

      :persistent_term.put(
        {AtMcp.Spaces, :principal_of, "did:plc:oauthagent"},
        {:ok, "did:plc:principal"}
      )

      assert {:ok, %{did: "did:plc:newagent", agent_space: space}} =
               AtMcp.Effects.spaces(ctx.effects, :create_agent, ["helper.test", "code"])

      assert space == "at:space/did:plc:oauthagent/town.delve.space.agent/did:plc:newagent"
    end

    test "an account made a principal while its session runs logs in again for the agent routes",
         ctx do
      ctx.write_accounts.(nil)
      assert {:ok, _} = AtMcp.Effects.login(ctx.effects)

      # Now a principal: its session began without the agent routes.
      ctx.write_accounts.(@rotation)

      assert {:ok, %{did: "did:plc:newagent"}} =
               AtMcp.Effects.spaces(ctx.effects, :create_agent, ["helper.test", "code"])

      [login] = Enum.filter(calls(ctx.log), &(&1["method"] == "oauth.login"))
      assert login["params"]["scope"] =~ "rpc:town.delve.agent.createAgent?aud="
    end

    test "deletes an agent only with confirm, never this account itself, and retires its key",
         ctx do
      ctx.write_accounts.(@rotation)
      assert {:ok, _} = AtMcp.Effects.login(ctx.effects)
      key = AtMcp.Spaces.key_path("did:plc:someagent")
      File.write!(key, "{}")

      assert {:error, %AtMcp.Effects.Failure{kind: :refused}} =
               AtMcp.Effects.spaces(ctx.effects, :delete_agent, ["did:plc:someagent", false])

      assert {:error, %AtMcp.Effects.Failure{detail: :not_an_agent}} =
               AtMcp.Effects.spaces(ctx.effects, :delete_agent, ["did:plc:oauthagent", true])

      refute_received {:agent_route, :delete, _}

      assert {:ok, %{deleted: true}} =
               AtMcp.Effects.spaces(ctx.effects, :delete_agent, ["did:plc:someagent", true])

      assert_received {:agent_route, :delete, %{"did" => "did:plc:someagent"}}
      refute File.exists?(key)
    end

    test "enrolls a key for an agent with the key's proof, and refuses this account's own DID",
         ctx do
      ctx.write_accounts.(@rotation)
      assert {:ok, _} = AtMcp.Effects.login(ctx.effects)

      assert {:error, %AtMcp.Effects.Failure{detail: :not_an_agent}} =
               AtMcp.Effects.spaces(ctx.effects, :enroll_agent_key, ["did:plc:oauthagent"])

      refute_received {:agent_route, _, _}

      assert {:ok, %{enrolled: true}} =
               AtMcp.Effects.spaces(ctx.effects, :enroll_agent_key, ["did:plc:someagent"])

      assert_received {:agent_route, :enroll, body}
      assert "proof:" <> bound = body["loginKeyProof"]

      assert %{"sub" => "did:plc:someagent", "lxm" => "town.delve.agent.enrollKey"} =
               Jason.decode!(bound)
    end
  end

  describe "a helper that stops mid-call" do
    setup do
      previous = Application.get_env(:at_mcp, :network)
      Application.put_env(:at_mcp, :network, :delve)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:at_mcp, :network, previous),
          else: Application.delete_env(:at_mcp, :network)
      end)

      # The fake helper's next call of `method` kills it before it answers.
      %{die: fn method -> File.write!(System.get_env("FAKE_DIE"), method) end}
    end

    test "a read is answered by the helper started in its place", ctx do
      assert {:ok, _} = AtMcp.Effects.login(ctx.effects)
      ctx.die.("space.records.list")

      assert {:ok, %{notes: []}} = AtMcp.Effects.spaces(ctx.effects, :list_notes, [nil, nil])

      # Asked twice: once of the helper that stopped, once of its successor.
      lists = Enum.count(calls(ctx.log), &(&1["method"] == "space.records.list"))
      assert lists == 2
    end

    test "a write is not sent again: its outcome is unknown, and the caller is told", ctx do
      assert {:ok, _} = AtMcp.Effects.login(ctx.effects)
      ctx.die.("space.records.create")

      assert {:error, {:write_outcome_unknown, _}} =
               AtMcp.Effects.spaces(ctx.effects, :create_note, [%{text: "once"}])

      creates = Enum.count(calls(ctx.log), &(&1["method"] == "space.records.create"))
      assert creates == 1
    end
  end
end
