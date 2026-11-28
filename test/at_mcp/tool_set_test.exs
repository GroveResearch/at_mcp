defmodule AtMcp.ToolSetTest do
  @moduledoc """
  A session is offered the default tool set unless its grant or the
  environment asks for the full one (`AtMcp.MCP.ToolSet`), and every
  published tool answers a call whichever set was listed.
  """
  use ExUnit.Case, async: false

  alias AtMcp.Test.Grant

  # The default `tools/list`, in characters of JSON, on each network: with
  # 46 tools, 49,483 on Delvetown, and 50,014 on Bluesky, which leaves out
  # get_policy. 0.2.18 listed every tool with its output schema in 994,426.
  # A host that loads tool definitions into the model's context pays this
  # on every request; raise it only for a tool or argument agents use.
  # 2026-11-28: +100 for get_notifications' include_group_posts, which an
  # agent needs to see the group posts the list now leaves out.
  @default_bound 51_100
  # With the five note tools, get_group_invites and accept_group_invite,
  # where Spaces work (delve.town with the Spaces helper running): 54,632. Models given no
  # private place refused to write a private note publicly and had nowhere
  # else to put it, and without the invites never learned a group asked
  # them in.
  @default_with_notes_bound 55_000
  # Every tool, for a client that asks for the full set: about 118,000 on
  # Delvetown and 120,800 on Bluesky, with the notes, groups, principal and
  # identity tools, and founding and running a group (create_group,
  # invite_to_group, the join requests: about 4,600), of which only the
  # notes and the invites are in the default set. Agents start
  # communities too, so the founding tools count against the full set's
  # room, not the default's.
  @full_bound 125_000

  setup do
    previous = Application.fetch_env(:at_mcp, :tool_set)
    network = Application.fetch_env(:at_mcp, :network)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:at_mcp, :tool_set, value)
        :error -> Application.delete_env(:at_mcp, :tool_set)
      end

      case network do
        {:ok, value} -> Application.put_env(:at_mcp, :network, value)
        :error -> Application.delete_env(:at_mcp, :network)
      end
    end)
  end

  defp listed(state) do
    {:ok, tools, nil, _} = AtMcp.MCP.Server.handle_list_tools(nil, state)
    tools
  end

  defp names(tools), do: tools |> Enum.map(& &1.name) |> Enum.sort()

  # Every published tool the session's network serves, and those of `wanted`.
  defp served, do: names(AtMcp.MCP.Served.offered(listed(:state)))
  defp served(wanted), do: Enum.sort(wanted) -- (names(listed(:state)) -- served())

  test "a session is offered the default set, and it fits the bound on each network" do
    for network <- AtMcp.Network.names() do
      Application.put_env(:at_mcp, :network, network)
      tools = listed(%{})

      # get_policy is listed where the network publishes policies to read.
      default = AtMcp.MCP.ToolSet.default()

      expected =
        if AtMcp.Network.publishes_policies?(network),
          do: default,
          else: default -- ["get_policy"]

      assert names(tools) == Enum.sort(expected), "#{network}"
      assert "get_post_images" in names(tools) and "pin_post" in names(tools)

      size = String.length(Jason.encode!(%{tools: tools}))
      assert size <= @default_bound, "the default tools/list on #{network} is #{size} characters"

      full = String.length(Jason.encode!(%{tools: listed(%{tools: "full"})}))
      assert full <= @full_bound, "the full tools/list on #{network} is #{full} characters"
    end
  end

  test "the full set, asked for by the session or the environment, offers every tool" do
    every = served()
    assert length(every) > length(AtMcp.MCP.ToolSet.default())

    full = listed(%{tools: "full"})
    assert names(full) == every

    Application.put_env(:at_mcp, :tool_set, :full)
    assert names(listed(%{})) == every

    # A grant's own set wins over the environment's.
    assert names(listed(%{tools: "default"})) == served(AtMcp.MCP.ToolSet.default())
  end

  # A model reads the descriptions in a new session, with no earlier version
  # to compare against.
  test "no tool or argument is described against an earlier version" do
    for tool <- listed(%{tools: "full"}) do
      texts =
        [tool.description] ++
          for {_name, property} <- tool.inputSchema.properties,
              do: property[:description] || property["description"] || ""

      for text <- texts, do: refute(text =~ "as before", "#{tool.name}: #{text}")
    end

    search = Enum.find(listed(%{tools: "full"}), &(&1.name == "search_posts"))
    since = search.inputSchema.properties[:since] || search.inputSchema.properties["since"]
    assert (since[:description] || since["description"]) =~ "not last_read"
  end

  test "no tool's output schema is listed" do
    for tool <- listed(%{tools: "full"}), do: refute(Map.has_key?(tool, :outputSchema), tool.name)
  end

  # Most hosts let a model call only the tools listed to it, so what a
  # result points to must be on the list.
  test "a put_record refusal says whether this connection lists the tools that write the record" do
    refusal = fn state ->
      {:ok, result, _} =
        AtMcp.MCP.Tools.respond(
          {:error,
           {:own_collection, "app.bsky.graph.list", ~w(create_list update_list delete_list)}},
          state
        )

      assert result.isError
      assert result.structuredContent.code == "invalid_arguments"
      assert result.structuredContent.retry == "no"
      hd(result.content).text
    end

    default = refusal.(%{})
    assert default =~ "create_list, update_list, delete_list"
    assert default =~ "this connection does not list those tools"
    refute default =~ "use those tools instead"

    full = refusal.(%{tools: "full"})
    assert full =~ "use those tools instead."
    refute full =~ "does not list"

    # Tools the default set holds are named as usable.
    {:ok, liked, _} =
      AtMcp.MCP.Tools.respond(
        {:error, {:own_collection, "app.bsky.feed.like", ~w(like unlike)}},
        %{}
      )

    assert hd(liked.content).text =~ "use those tools instead."
  end

  test "a feed item points to feed_feedback only when the session lists it" do
    page =
      {:ok,
       %{
         count: 1,
         items: [
           %{
             uri: "at://did:plc:a/app.bsky.feed.post/3kp2222222222",
             text: "hello",
             feed_context: "t-gliders",
             req_id: "r1"
           }
         ]
       }}

    reading = fn state ->
      {:ok, result, _} = AtMcp.MCP.Tools.respond(page, state, :posts)
      hd(result.content).text
    end

    refute reading.(%{}) =~ "feed_feedback"
    assert reading.(%{tools: "full"}) =~ ~s(For feed_feedback: feed_context: "t-gliders")
  end

  test "every tool in the default set is declared" do
    every = names(listed(:state))
    for name <- AtMcp.MCP.ToolSet.default(), do: assert(name in every, name)
  end

  describe "over the shared endpoint" do
    setup do
      id = "tool_set_#{System.unique_integer([:positive])}"

      {:ok, _} =
        AtMcp.Identities.start_identity(
          id: id,
          listen_enabled: false,
          backend: AtMcp.Test.MockBackend,
          backend_state: %{did: "did:plc:toolset", mock: true}
        )

      on_exit(fn -> AtMcp.Identities.stop_identity(id) end)
      %{id: id}
    end

    defp rpc(headers, method, params) do
      body = %{
        jsonrpc: "2.0",
        id: System.unique_integer([:positive]),
        method: method,
        params: params
      }

      response = Req.post!(Grant.url(), headers: headers, json: body, retry: false)
      assert response.status == 200
      response.body["result"]
    end

    defp listed_names(headers),
      do:
        headers
        |> rpc("tools/list", %{})
        |> Map.fetch!("tools")
        |> Enum.map(& &1["name"])
        |> Enum.sort()

    test "a grant is offered the default set, and one issued with tools full every tool", %{
      id: id
    } do
      default = Grant.session!(Grant.token(id, :manage))
      full = Grant.session!(Grant.token(id, :manage, tools: "full"))

      assert listed_names(default) == served(AtMcp.MCP.ToolSet.default())
      assert listed_names(full) == served()
    end

    test "a tool left out of the default set still answers a call", %{id: id} do
      headers = Grant.session!(Grant.token(id, :manage))
      refute "get_preferences" in listed_names(headers)

      result = rpc(headers, "tools/call", %{name: "get_preferences", arguments: %{}})
      refute result["isError"], inspect(result)
    end
  end

  test "a grant names only a known tool set" do
    path =
      Path.join(
        System.tmp_dir!(),
        "at_mcp-tool-set-grants-#{System.unique_integer([:positive])}.json"
      )

    on_exit(fn -> File.rm(path) end)

    assert {:error, :invalid_tools} = AtMcp.Grants.issue("acct", tools: "most", path: path)

    assert {:ok, %{token: token, tools: "full"}} =
             AtMcp.Grants.issue("acct", tools: "full", path: path)

    assert {:ok, %{tools: "full"}} = AtMcp.Grants.request(token, path: path)
  end

  test "where Spaces work, the default set holds the note tools and the group invites" do
    Application.put_env(:at_mcp, :network, :delve)
    refute AtMcp.MCP.ToolSet.notes?()
    refute "create_note" in names(listed(%{}))

    :ok = Supervisor.terminate_child(AtMcp.Supervisor, AtMcp.Spaces.Helper)

    {:ok, helper} =
      AtMcp.Spaces.Helper.start_link(
        script: Path.expand("../support/fake_spaces_helper.mjs", __DIR__),
        enabled: true
      )

    on_exit(fn ->
      # Linked to the test, the helper may already be stopping with it.
      try do
        GenServer.stop(helper)
      catch
        :exit, _ -> :ok
      end

      Supervisor.restart_child(AtMcp.Supervisor, AtMcp.Spaces.Helper)
    end)

    assert AtMcp.MCP.ToolSet.notes?()
    tools = listed(%{})
    assert Enum.all?(AtMcp.MCP.ToolSet.notes(), &(&1 in names(tools)))
    assert "get_group_invites" in names(tools)
    assert "accept_group_invite" in names(tools)
    assert AtMcp.MCP.ToolSet.offers?(%{}, "create_note")

    size = String.length(Jason.encode!(%{tools: tools}))

    assert size <= @default_with_notes_bound,
           "the default tools/list with notes is #{size} characters"

    # Bluesky has no town spaces, so no notes.
    Application.put_env(:at_mcp, :network, :bluesky)
    refute "create_note" in names(listed(%{}))
  end

  test "a session on the default set is told what the full set adds, where the town tools exist" do
    init = fn state ->
      {:ok, result, _} =
        AtMcp.MCP.Server.handle_initialize(
          %{
            "protocolVersion" => "2025-06-18",
            "capabilities" => %{},
            "clientInfo" => %{"name" => "t", "version" => "1"}
          },
          state
        )

      result["instructions"]
    end

    Application.put_env(:at_mcp, :network, :delve)
    assert init.(%{}) =~ "need the full tool set (AT_MCP_TOOLS=full); ask the person running you"
    assert init.(%{tools: "full"}) == nil

    Application.put_env(:at_mcp, :network, :bluesky)
    assert init.(%{}) == nil
  end

  test "a group's posts are said to be private to it where they are written and read" do
    {:ok, tools, nil, _} = AtMcp.MCP.Server.handle_list_tools(nil, %{tools: "full"})
    by_name = Map.new(tools, &{&1.name, &1})

    assert by_name["get_space_feed"].description =~
             "private to them: don't repost or quote them publicly"

    assert inspect(by_name["post"].inputSchema[:properties][:space]) =~
             "private to its members: don't repost them publicly"
  end
end
