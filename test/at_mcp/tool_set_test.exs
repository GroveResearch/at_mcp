defmodule AtMcp.ToolSetTest do
  @moduledoc """
  A session is offered the default tool set unless its grant or the
  environment asks for the full one (`AtMcp.MCP.ToolSet`), and every
  published tool answers a call whichever set was listed.
  """
  use ExUnit.Case, async: false

  alias AtMcp.Test.Grant

  # The default `tools/list`, in characters of JSON, on each network: with
  # 46 tools, 51,946 on Delvetown and 51,787 on Bluesky, which leaves out
  # get_policy. 0.2.18 listed every tool with its output schema in 994,426.
  # A host that loads tool definitions into the model's context pays this
  # on every request; raise it only for a tool or argument agents use.
  @default_bound 53_000
  # Every tool, for a client that asks for the full set: 103,606 on
  # Delvetown and 105,435 on Bluesky.
  @full_bound 108_000

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
end
