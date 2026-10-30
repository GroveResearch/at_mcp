defmodule AtMcp.ServedTest do
  @moduledoc """
  On Delvetown, `tools/list` leaves out the tools and arguments the town does
  not serve (`AtMcp.MCP.Served`). On Bluesky it lists all of them.
  `preferences_test.exs` checks that a call to a left-out argument is still
  refused.
  """
  use ExUnit.Case, async: false

  setup do
    previous = Application.fetch_env(:at_mcp, :network)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:at_mcp, :network, value)
        :error -> Application.delete_env(:at_mcp, :network)
      end
    end)
  end

  defp listed(network) do
    Application.put_env(:at_mcp, :network, network)
    {:ok, tools, nil, _} = AtMcp.MCP.Server.handle_list_tools(nil, %{tools: "full"})
    Map.new(tools, &{&1.name, &1})
  end

  defp arguments(tool), do: tool.inputSchema.properties |> Map.keys() |> Enum.map(&to_string/1)

  test "on Delvetown, get_notifications does not offer grouped, and nothing the town does not serve is listed" do
    town = listed(:delve)

    refute "grouped" in arguments(town["get_notifications"])
    # feed picks a tab of the grouped notifications, and the description's
    # sentence about grouped reads goes with the argument.
    refute "feed" in arguments(town["get_notifications"])
    refute town["get_notifications"].description =~ "grouped"
    assert town["get_notifications"].description =~ "pass reasons"
    assert "reasons" in arguments(town["get_notifications"])
    refute "links" in arguments(town["update_profile"])
    refute Map.has_key?(town, "get_trends")
    refute Map.has_key?(town, "feed_feedback")
    assert Map.has_key?(town, "get_policy")
  end

  test "get_policy is left out where the network publishes no policy pages" do
    refute Map.has_key?(listed(:bluesky), "get_policy")
  end

  test "on Bluesky, which serves them, they are all offered" do
    bluesky = listed(:bluesky)

    assert "grouped" in arguments(bluesky["get_notifications"])
    assert "feed" in arguments(bluesky["get_notifications"])

    assert bluesky["get_notifications"].description =~
             AtMcp.MCP.Served.described({"get_notifications", "grouped"})

    assert "links" in arguments(bluesky["update_profile"])
    assert Map.has_key?(bluesky, "get_trends")
    assert Map.has_key?(bluesky, "feed_feedback")
  end

  test "every need names a declared tool and argument" do
    all = listed(:bluesky)

    for {{tool, argument}, _} <- AtMcp.MCP.Served.needs() do
      assert Map.has_key?(all, tool), tool
      if argument, do: assert(argument in arguments(all[tool]), "#{tool}(#{argument})")
    end
  end
end
