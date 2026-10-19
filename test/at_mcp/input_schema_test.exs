defmodule AtMcp.InputSchemaTest do
  @moduledoc """
  The input schemas as a client receives them from `tools/list`: JSON, after
  encoding. A client validates its arguments against these before it calls,
  so a schema that cannot be satisfied refuses every call before it is sent.
  """
  use ExUnit.Case, async: false

  @png "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgAAACAAFUok9dAAAAAElFTkSuQmCC"

  # Records what the tools hand the backend, and answers like a service would.
  defmodule Backend do
    def prepare_post(_session, _text, opts), do: {:ok, opts}
    def resolve_references(_session, opts), do: {:ok, opts}

    def post(session, text, opts \\ []) do
      send(session.test, {:post, text, opts})
      {:ok, %{uri: "at://did:plc:fixture/app.bsky.feed.post/1", cid: "bafypost", text: text}}
    end

    def update_profile(session, updates) do
      send(session.test, {:update_profile, updates})
      {:ok, %{ok: true, action: :update_profile, uri: "at://did:plc:fixture/self"}}
    end
  end

  defp published do
    {:ok, tools, nil, :state} = AtMcp.MCP.Server.handle_list_tools(nil, :state)
    tools |> Jason.encode!() |> Jason.decode!() |> Map.new(&{&1["name"], &1["inputSchema"]})
  end

  defp state do
    effects =
      start_supervised!(
        {AtMcp.Effects,
         write_quota: AtMcp.Test.QuotaFixture.quota(100),
         backend: Backend,
         backend_state: %{did: "did:plc:fixture", test: self()}},
        id: make_ref()
      )

    %{effects: effects}
  end

  # Every object schema inside a schema, with the path that reaches it.
  defp objects(schema, path) when is_map(schema) do
    own =
      if Map.has_key?(schema, "properties") or Map.has_key?(schema, "required"),
        do: [{path, schema}],
        else: []

    nested =
      Enum.flat_map(schema, fn
        {"properties", props} -> Enum.flat_map(props, fn {k, v} -> objects(v, path ++ [k]) end)
        {"items", items} -> objects(items, path ++ ["[]"])
        {key, list} when key in ~w(anyOf oneOf allOf) -> Enum.flat_map(list, &objects(&1, path))
        _ -> []
      end)

    own ++ nested
  end

  defp objects(_, _), do: []

  test "no tool's schema requires a key it does not define" do
    undefined =
      for {name, schema} <- published(),
          {path, object} <- objects(schema, [name]),
          key <- Map.get(object, "required", []),
          not Map.has_key?(Map.get(object, "properties", %{}), key),
          do: {Enum.join(path, "."), key}

    assert undefined == []
  end

  test "an image's MIME type may be spelled mime_type or mimeType in every tool that takes one" do
    schemas = Map.new(published(), fn {name, s} -> {name, ExJsonSchema.Schema.resolve(s)} end)
    image = &%{"data" => @png, &1 => "image/png"}

    for key <- ["mime_type", "mimeType"] do
      for {tool, args} <- [
            {"update_profile", %{"avatar" => image.(key)}},
            {"update_profile", %{"banner" => %{"path" => "b.png", key => "image/png"}}},
            {"post", %{"text" => "t", "images" => [Map.put(image.(key), "alt", "a dot")]}},
            {"reply",
             %{"uri" => "at://x", "text" => "t", "images" => [Map.put(image.(key), "alt", "a")]}}
          ] do
        assert ExJsonSchema.Validator.validate(schemas[tool], args) == :ok,
               "#{tool} #{inspect(args)}"
      end
    end
  end

  test "mimeType reaches the backend as the image's MIME type" do
    state = state()

    assert {:ok, result, _} =
             AtMcp.MCP.Server.handle_call_tool(
               "update_profile",
               %{"avatar" => %{"data" => @png, "mimeType" => "image/png"}},
               state
             )

    refute result[:isError]
    assert_received {:update_profile, updates}
    assert %{mime_type: "image/png", data: <<0x89, "PNG", _::binary>>} = updates[:avatar]

    images = [%{"data" => @png, "mimeType" => "image/png", "alt" => "a dot"}]

    assert {:ok, result, _} =
             AtMcp.MCP.Server.handle_call_tool(
               "post",
               %{"text" => "t", "images" => images},
               state
             )

    refute result[:isError]
    assert_received {:post, "t", opts}
    assert [%{mime_type: "image/png", alt: "a dot"}] = opts[:images]
  end

  # Neither MIME type is required by the schema: an `anyOf` requiring one of
  # them led some models to leave the type out of every call. The tool
  # refuses instead, before anything is sent.
  test "an image with no MIME type, or two that differ, is refused and nothing is sent" do
    state = state()

    for avatar <- [
          %{"data" => @png},
          %{"data" => @png, "mime_type" => "image/png", "mimeType" => "image/jpeg"}
        ] do
      assert {:ok, %{isError: true} = result, _} =
               AtMcp.MCP.Server.handle_call_tool("update_profile", %{"avatar" => avatar}, state)

      assert result.structuredContent.code == "invalid_image"
      [%{text: text}] = result.content
      assert text =~ "mimeType"
    end

    images = [%{"data" => @png, "alt" => "a dot"}]

    assert {:ok, %{isError: true} = result, _} =
             AtMcp.MCP.Server.handle_call_tool(
               "post",
               %{"text" => "t", "images" => images},
               state
             )

    assert result.structuredContent.code == "invalid_image"
    refute_received {:update_profile, _}
    refute_received {:post, _, _}
  end

  test "a refused call names the argument that failed" do
    args = %{"text" => "t", "images" => [%{"data" => @png, "mime_type" => "image/png"}]}

    assert {:ok, %{isError: true} = result, :state} =
             AtMcp.MCP.Server.handle_call_tool("post", args, :state)

    assert %{code: "invalid_arguments", problems: [%{path: "images/0", message: message}]} =
             result.structuredContent

    assert message =~ "alt"
    [%{text: text}] = result.content
    assert text =~ "No operation was attempted"
    assert text =~ "images/0: " <> message
  end

  test "every failure is named, up to five" do
    args = %{"text" => 1, "langs" => Enum.to_list(1..7)}

    assert {:ok, %{isError: true} = result, :state} =
             AtMcp.MCP.Server.handle_call_tool("post", args, :state)

    problems = result.structuredContent.problems
    assert length(problems) == 5
    assert Enum.all?(problems, &(&1.path == "text" or String.starts_with?(&1.path, "langs/")))
    [%{text: text}] = result.content
    assert text =~ "(3 more)"
  end

  test "arguments a tool does not take are named in its result, which otherwise stands" do
    args = %{
      "text" => "hello",
      "embed" => %{"uri" => "at://x"},
      "facets" => [],
      "images" => [%{"data" => @png, "mime_type" => "image/png", "alt" => "a", "caption" => "c"}],
      "_meta" => %{"progressToken" => 1}
    }

    assert {:ok, result, _} = AtMcp.MCP.Server.handle_call_tool("post", args, state())
    refute result[:isError]
    assert_received {:post, "hello", _opts}

    ignored = ["embed", "facets", "images/0/caption"]
    assert result.structuredContent["ignored"] == ignored
    assert result.structuredContent["uri"] == "at://did:plc:fixture/app.bsky.feed.post/1"

    [%{text: json}, %{text: line}] = result.content
    assert Jason.decode!(json) == result.structuredContent

    assert line ==
             "ignored: embed, facets, images/0/caption (this tool does not take them; nothing was done with them)"

    {:ok, tools, nil, :state} = AtMcp.MCP.Server.handle_list_tools(nil, :state)
    output = Enum.find(tools, &(&1.name == "post")).outputSchema
    assert AtMcp.Test.Schema.valid?(result.structuredContent, output)
  end

  test "a call with only the arguments a tool takes says nothing about ignoring" do
    assert {:ok, result, _} =
             AtMcp.MCP.Server.handle_call_tool("post", %{"text" => "hi"}, state())

    refute Map.has_key?(result.structuredContent, "ignored")
    assert [%{text: _}] = result.content
  end

  # Each argument check runs under a 100 ms deadline. Loading a keyword's
  # validator module on its first use, inside that deadline, is what made
  # correct calls fail as input_validation_unavailable on a loaded machine.
  test "the schema validator is loaded before any argument is checked" do
    modules = [Float | Application.spec(:ex_json_schema, :modules)]
    assert Enum.reject(modules, &:code.is_loaded/1) == []
  end
end
