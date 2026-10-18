defmodule AtMcp.InputSchemaTest do
  @moduledoc """
  The input schemas as a client receives them from `tools/list`: JSON, after
  encoding. A client validates its arguments against these before it calls,
  so a schema that cannot be satisfied refuses every call before it is sent.
  """
  use ExUnit.Case, async: true

  @png "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgAAACAAFUok9dAAAAAElFTkSuQmCC"

  defp published do
    {:ok, tools, nil, :state} = AtMcp.MCP.Server.handle_list_tools(nil, :state)
    tools |> Jason.encode!() |> Jason.decode!() |> Map.new(&{&1["name"], &1["inputSchema"]})
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

  test "a correctly shaped update_profile call satisfies the published schema" do
    schema = published() |> Map.fetch!("update_profile") |> ExJsonSchema.Schema.resolve()

    for args <- [
          %{"avatar" => %{"data" => @png, "mime_type" => "image/png"}},
          %{"banner" => %{"path" => "banner.jpg", "mime_type" => "image/jpeg"}},
          %{
            "display_name" => "café 🪁",
            "avatar" => %{"data" => @png, "mime_type" => "image/png"},
            "banner" => %{"data" => @png, "mime_type" => "image/png"}
          }
        ] do
      assert ExJsonSchema.Validator.validate(schema, args) == :ok, inspect(args)
    end
  end

  test "a refused call names the argument that failed" do
    # `mimeType` is the blob's field in the AT Protocol data model; this tool
    # takes the image and its MIME type and builds the blob, so its argument
    # is `mime_type`, like every other argument here.
    args = %{"avatar" => %{"data" => @png, "mimeType" => "image/png"}}

    assert {:ok, %{isError: true} = result, :state} =
             AtMcp.MCP.Server.handle_call_tool("update_profile", args, :state)

    assert %{code: "invalid_arguments", problems: [%{path: "avatar", message: message}]} =
             result.structuredContent

    assert message =~ "mime_type"
    [%{text: text}] = result.content
    assert text =~ "No operation was attempted"
    assert text =~ "avatar: " <> message
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
end
