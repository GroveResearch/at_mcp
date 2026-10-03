defmodule AtMcp.ExternalAccountTest do
  use ExUnit.Case, async: false

  test "application calls route through home PDS; preferences respect where the account lives" do
    previous = Application.get_env(:at_mcp, :network)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:at_mcp, :network, previous),
        else: Application.delete_env(:at_mcp, :network)
    end)

    Application.put_env(:at_mcp, :network, :delve)
    external = %ProtoRune.Atproto.Session{service_url: "https://external.example/xrpc"}
    hosted = %{external | service_url: "https://pds.delve.town/xrpc"}
    proxy = %{"atproto-proxy" => "did:web:api.delve.town#bsky_appview"}

    for suffix <- [
          "feed.getTimeline",
          "feed.getPosts",
          "graph.muteActor",
          "notification.updateSeen",
          "membership.getMembership"
        ] do
      assert AtMcp.Network.request_headers(AtMcp.Network.nsid(suffix), external) == proxy
      assert AtMcp.Network.request_headers(AtMcp.Network.nsid(suffix), hosted) == proxy
    end

    for suffix <- ["actor.getPreferences", "actor.putPreferences"] do
      assert AtMcp.Network.request_headers(AtMcp.Network.nsid(suffix), external) == proxy
      assert AtMcp.Network.request_headers(AtMcp.Network.nsid(suffix), hosted) == %{}
    end

    for method <- [
          "server.createSession",
          "server.refreshSession",
          "repo.createRecord",
          "repo.getRecord",
          "repo.uploadBlob",
          "identity.resolveHandle"
        ] do
      assert AtMcp.Network.request_headers("com.atproto." <> method, external) == %{}
    end

    Application.put_env(:at_mcp, :network, :bluesky)

    assert AtMcp.Network.request_headers("app.bsky.feed.getPosts", external) == %{
             "atproto-proxy" => "did:web:api.bsky.app#bsky_appview"
           }

    assert AtMcp.Network.request_headers("app.bsky.actor.getPreferences", external) == %{}
  end

  test "unsupported membership is a local refusal, not an invented service response" do
    previous = Application.get_env(:at_mcp, :network)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:at_mcp, :network, previous),
        else: Application.delete_env(:at_mcp, :network)
    end)

    Application.put_env(:at_mcp, :network, :bluesky)
    result = AtMcp.Effects.ProtoRune.get_membership(%ProtoRune.Atproto.Session{})

    assert {:ok,
            %{
              isError: true,
              structuredContent: %{code: "membership_not_supported"},
              content: [%{text: text}]
            }, :state} = AtMcp.MCP.Tools.respond(result, :state)

    assert text =~ "no request was sent"
  end

  @tag timeout: 90_000
  @tag skip: is_nil(System.get_env("MCP_CLIENT_PATH"))
  test "ordinary MCP client inhabits an admitted external identity through separate PDS and AppView" do
    paths = :code.get_path() |> Enum.flat_map(&["-pa", to_string(&1)])
    release = System.get_env("AT_MCP_ACCOUNT_RELEASE")

    {command, args} =
      if release,
        do: {Path.join(release, "bin/at_mcp-stdio"), []},
        else:
          {System.find_executable("elixir"),
           paths ++ ["-e", "Application.put_env(:at_mcp, :network, :delve); AtMcp.Stdio.run()"]}

    {output, code} =
      System.cmd("node", [Path.expand("../support/external_account_probe.mjs", __DIR__)],
        env: [{"AT_MCP_EXTERNAL_COMMAND", command}, {"AT_MCP_EXTERNAL_ARGS", Jason.encode!(args)}],
        stderr_to_stdout: true
      )

    assert code == 0, output
    assert output =~ ~s("unknown_write_not_retried":true)
  end
end
