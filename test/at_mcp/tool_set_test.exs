defmodule AtMcp.ToolSetTest do
  @moduledoc """
  A session is offered the default tool set unless its grant or the
  environment asks for the full one (`AtMcp.MCP.ToolSet`), and every
  published tool answers a call whichever set was listed.
  """
  use ExUnit.Case, async: false

  alias AtMcp.Test.Grant

  # The default `tools/list`, in bytes of JSON: 41,700 when this was set
  # (43 tools), from 994,426 for every tool with its output schema; 49,482
  # once reads took `detail` (#212), `get_thread` `depth` and `breadth`
  # (#214), and the feeds `since` and `mark_read` (#216). A host that loads
  # tool definitions into the model's context pays this on every request;
  # raise it only for a tool or argument agents use.
  @default_bound 52_000
  # Every tool, for a client that asks for the full set: 96,719 when set,
  # 105,329 with those arguments.
  @full_bound 110_000

  setup do
    previous = Application.fetch_env(:at_mcp, :tool_set)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:at_mcp, :tool_set, value)
        :error -> Application.delete_env(:at_mcp, :tool_set)
      end
    end)
  end

  defp listed(state) do
    {:ok, tools, nil, _} = AtMcp.MCP.Server.handle_list_tools(nil, state)
    tools
  end

  defp names(tools), do: tools |> Enum.map(& &1.name) |> Enum.sort()

  test "a session is offered the default set, and it fits the bound" do
    tools = listed(%{})

    assert names(tools) == Enum.sort(AtMcp.MCP.ToolSet.default())
    size = byte_size(Jason.encode!(%{tools: tools}))
    assert size <= @default_bound, "the default tools/list is #{size} bytes"
  end

  test "the full set, asked for by the session or the environment, offers every tool" do
    every = names(listed(:state))
    assert length(every) > length(AtMcp.MCP.ToolSet.default())

    full = listed(%{tools: "full"})
    assert names(full) == every
    assert byte_size(Jason.encode!(%{tools: full})) <= @full_bound

    Application.put_env(:at_mcp, :tool_set, :full)
    assert names(listed(%{})) == every

    # A grant's own set wins over the environment's.
    assert names(listed(%{tools: "default"})) == Enum.sort(AtMcp.MCP.ToolSet.default())
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

      assert listed_names(default) == Enum.sort(AtMcp.MCP.ToolSet.default())
      assert listed_names(full) == names(listed(:state))
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
