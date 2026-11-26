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
            if String.ends_with?(url, ".notification.registerSpace"),
              do: %{status: "registered"},
              else: %{count: 3}

          {:ok, %{status: 200, headers: [], body: Jason.encode!(body)}}
      end
    end
  end

  setup ctx do
    if is_nil(System.find_executable("node")), do: raise("these tests need node on the path")

    log = Path.join(System.tmp_dir!(), "fake-helper-#{System.unique_integer([:positive])}.log")
    System.put_env("FAKE_LOG", log)
    System.put_env("FAKE_DID", "did:plc:oauthagent")

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
      if Process.alive?(helper), do: GenServer.stop(helper)
      {:ok, _} = Supervisor.restart_child(AtMcp.Supervisor, AtMcp.Spaces.Helper)

      if previous_http,
        do: Application.put_env(:proto_rune, :http_client, previous_http),
        else: Application.delete_env(:proto_rune, :http_client)

      Application.delete_env(:at_mcp, :spaces_session_test_owner)
      Application.delete_env(:at_mcp, :spaces_session_test_refuse)
      System.delete_env("FAKE_LOG")
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

    test "a post in a group space is a town post, refused when empty, and spends a write", ctx do
      assert {:ok, _} = AtMcp.Effects.login(ctx.effects)
      space = "at:space/did:plc:group/town.delve.space.group/general"

      assert {:error, %AtMcp.Effects.Failure{kind: :refused}} =
               AtMcp.Effects.spaces(ctx.effects, :post_in_group, [space, "  "])

      assert {:ok, %{uri: uri}} =
               AtMcp.Effects.spaces(ctx.effects, :post_in_group, [space, "hello group"])

      assert uri =~ "town.delve.feed.post"

      [write] = Enum.filter(calls(ctx.log), &(&1["method"] == "space.records.create"))
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

      assert {:ok, _space, "registered"} = AtMcp.Spaces.ensure_inbox(session)
    end
  end
end
