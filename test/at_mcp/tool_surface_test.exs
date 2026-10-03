defmodule AtMcp.ToolSurfaceTest do
  @moduledoc """
  AtMcp's MCP tool names and argument shapes are a public boundary: agents and
  hosts call them by name, and an upgrade must not break a caller that worked
  the day before.

  `test/support/tool_surface.json` is what has been published: each tool, the
  type of each argument, and which arguments are required. The rules:

    * a published tool or argument stays served;
    * an argument's type does not change, and no argument becomes required;
    * a rename declares the new name and keeps the old one, both served; the
      old one's entry in the file gains `"remove_after": "YYYY-MM-DD"`, and its
      description in `AtMcp.MCP.Server` says what replaced it and that date;
    * after that date the old entry and the old declaration are deleted
      together, and this test says so until they are;
    * a new tool or argument is added to the file when it is added to the
      server, which is how it becomes published.

  A removal date gives callers at least one release cycle to move; ninety days
  from the rename is the default.
  """
  use ExUnit.Case, async: true

  @published "test/support/tool_surface.json"

  defp served do
    {:ok, tools, nil, :state} = AtMcp.MCP.Server.handle_list_tools(nil, :state)

    Map.new(tools, fn tool ->
      props = tool.inputSchema[:properties] || %{}

      {tool.name,
       %{
         "description" => tool.description,
         "arguments" => Map.new(props, fn {k, v} -> {to_string(k), v[:type]} end),
         "required" => Enum.map(tool.inputSchema[:required] || [], &to_string/1)
       }}
    end)
  end

  defp published, do: @published |> File.read!() |> Jason.decode!() |> Map.fetch!("tools")

  defp expired?(%{"remove_after" => date}),
    do: Date.compare(Date.utc_today(), Date.from_iso8601!(date)) == :gt

  defp expired?(_), do: false

  test "every published tool and argument is still served, with its type, and nothing new is required" do
    served = served()

    for {name, tool} <- published(), not expired?(tool) do
      assert %{} = now = served[name],
             "#{name} is published and no longer served; see #{@published}"

      for {arg, type} <- tool["arguments"] do
        assert Map.has_key?(now["arguments"], arg),
               "#{name}(#{arg}) is published and no longer accepted"

        assert now["arguments"][arg] == type,
               "#{name}(#{arg}) was published as #{type} and is now #{now["arguments"][arg]}"
      end

      newly_required = now["required"] -- tool["required"]

      assert newly_required == [],
             "#{name} now requires #{inspect(newly_required)}, which callers do not send"
    end
  end

  test "everything served is published, so the next change is held to it" do
    published = published()

    for {name, tool} <- served() do
      assert %{"arguments" => args} = published[name],
             "#{name} is served and not in #{@published}"

      for {arg, _} <- tool["arguments"] do
        assert Map.has_key?(args, arg), "#{name}(#{arg}) is served and not in #{@published}"
      end
    end
  end

  test "an old name says what replaced it and when it goes, and goes on that date" do
    served = served()

    for {name, tool} <- published(), Map.has_key?(tool, "remove_after") do
      date = tool["remove_after"]

      if expired?(tool) do
        flunk(
          "#{name} was to be removed after #{date}: delete its declaration and its entry in #{@published}"
        )
      else
        assert served[name]["description"] =~ date,
               "#{name}'s description must name its removal date, #{date}"
      end
    end
  end
end
