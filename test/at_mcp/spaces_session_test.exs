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
                %{status: "registered"}

              String.contains?(url, "com.atproto.server.getServiceAuth") ->
                %{token: "aaa.bbb.ccc"}

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

    %{effects: effects, log: log}
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

    test "a first note makes the personal space, then writes the note, and says it is not encrypted",
         ctx do
      assert {:ok, _} = AtMcp.Effects.login(ctx.effects)

      assert {:ok, note} =
               AtMcp.Effects.spaces(ctx.effects, :create_note, [%{text: "remember", tags: ["a"]}])

      assert note.text == "remember"
      assert note.readable_by =~ "not encrypted"

      asked =
        calls(ctx.log)
        |> Enum.map(& &1["method"])
        |> Enum.filter(&String.starts_with?(&1, "space."))

      assert asked == ["space.records.create", "space.create", "space.records.create"]

      # Notes do not spend the write quota.
      assert AtMcp.Effects.quota_status(ctx.effects).used == 0
    end

    test "a listed note has its rkey and its URI, so it can be updated after", ctx do
      assert {:ok, _} = AtMcp.Effects.login(ctx.effects)

      assert {:ok, created} =
               AtMcp.Effects.spaces(ctx.effects, :create_note, [%{text: "remember"}])

      assert {:ok, %{notes: [listed]}} =
               AtMcp.Effects.spaces(ctx.effects, :list_notes, [nil, nil])

      assert listed.rkey == created.rkey and is_binary(listed.rkey)

      assert listed.uri ==
               "at:space/did:plc:oauthagent/town.delve.space.personal/self/did:plc:oauthagent/town.delve.notes.note/" <>
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
      assert message =~ "at:space/did:plc:oauthagent/town.delve.space.personal/self"
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

      # The group host isn't there, so the call fails after the inbox step.
      _ = AtMcp.Effects.spaces(ctx.effects, :list_group_invites, [])

      assert_receive {:request, :post, url, "DPoP tok-" <> _, _}, 5_000
      assert url =~ "town.delve.notification.registerSpace"

      session =
        AtMcp.Spaces.Login.session(
          elem(AtMcp.Spaces.Login.credentials("did:plc:oauthagent"), 1),
          "agent.test"
        )

      assert {:ok, _space, "registered", notice} = AtMcp.Spaces.ensure_inbox(session)
      # Said in plain words, with the way to turn it off.
      assert notice =~ "town's AppView read the invites"
      assert notice =~ "AT_MCP_TOWN_INBOX_READER=false"
    end
  end

  defmodule GroupHost do
    # A stand-in group host: its DID, an app's request to sign in as a group
    # (the group the member may approve it for), and the approval.
    use Plug.Router
    plug(:match)
    plug(Plug.Parsers, parsers: [:json], json_decoder: Jason)
    plug(:dispatch)

    get("/xrpc/com.atproto.server.describeServer",
      do: json(conn, %{did: "did:web:groups.test"})
    )

    get "/xrpc/org.atgrp.internal.getAuthorization" do
      json(conn, %{
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
      })
    end

    post "/xrpc/org.atgrp.internal.approveAuthorization" do
      send(
        Application.fetch_env!(:at_mcp, :spaces_session_test_owner),
        {:approved, conn.body_params}
      )

      json(conn, %{redirectUrl: "http://127.0.0.1/callback?code=c&state=s&iss=x"})
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
          description: "A group"
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

    post "/xrpc/org.atgrp.requestJoin" do
      send(
        Application.fetch_env!(:at_mcp, :spaces_session_test_owner),
        {:joined, conn.body_params}
      )

      json(conn, %{status: "admitted", membership: %{uri: "at:space/x", cid: "c"}})
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

    test "approves for the group the app asked for, by handle, or the only one offered", ctx do
      assert {:ok, _} = AtMcp.Effects.login(ctx.effects)

      assert {:ok, %{group: "did:plc:group", approved: true}} =
               AtMcp.Effects.spaces(ctx.effects, :approve_group_app, ["urn:req", nil, true])

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

      assert {:error, %AtMcp.Effects.Failure{kind: :refused, detail: :group_not_offered}} =
               AtMcp.Effects.spaces(ctx.effects, :approve_group_app, [
                 "urn:req",
                 "did:plc:other",
                 true
               ])

      refute_received {:approved, _}

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

    post "/xrpc/town.delve.agent.createAgent" do
      send(
        Application.fetch_env!(:at_mcp, :spaces_session_test_owner),
        {:agent_route, :create, conn.body_params}
      )

      json(conn, %{did: "did:plc:newagent", handle: conn.body_params["handle"]})
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

      for m <- ~w(createAgent enrollKey revokeSessions setStatus deleteAgent listAgents),
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

      assert {:ok, created} =
               AtMcp.Effects.spaces(ctx.effects, :create_agent, ["Helper.Test", "code"])

      assert created.rotation_key == @rotation

      assert_received {:agent_route, :create, body}
      assert body["rotationKey"] == @rotation
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
end
