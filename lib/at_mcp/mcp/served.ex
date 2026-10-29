defmodule AtMcp.MCP.Served do
  @moduledoc """
  Filters the tool list for the network a session is on.

  Some networks do not serve every method. `AtMcp.Endpoints.deployments/0`
  lists the methods each network leaves out. For a session on such a network,
  `offered/2` removes any argument that depends on an unserved method, and
  removes a tool when none of its methods are served. `get_policy` is offered
  where the network publishes policy pages.

  Offered an argument its network does not serve, an agent may call it, get
  the service's 501 and take that for an empty answer. A refused read of
  grouped notifications, for example, can look like no notifications at all.

  Leaving a tool or argument out of the list does not unpublish it
  (`test/at_mcp/tool_surface_test.exs`). If an agent calls one anyway, at_mcp
  accepts the call and refuses it before sending anything.
  """

  # Maps a tool, or one of a tool's arguments, to the methods it calls. Each
  # method is written as a suffix of `app.bsky`, the spelling
  # `AtMcp.Endpoints.not_served/2` expects on every network. `offered/2`
  # removes a tool when the network serves none of its methods, and removes an
  # argument when the network does not serve its method.
  @needs %{
    {"get_notifications", "grouped"} => ["notification.getGroupedNotifications"],
    {"update_profile", "links"} => ["actor.link"],
    {"get_trends", nil} => ["unspecced.getTrends", "unspecced.getTrendingTopics"],
    {"feed_feedback", nil} => ["feed.sendInteractions"]
  }

  @doc "The needs above, for tests: `%{{tool, argument | nil} => [suffix]}`."
  def needs, do: @needs

  @doc "Removes from `tools` the tools and arguments `network` does not serve."
  def offered(tools, network \\ AtMcp.Network.name()) do
    tools
    |> Enum.filter(&served?(network, {&1.name, nil}))
    |> Enum.map(&without_unserved_arguments(&1, network))
  end

  defp without_unserved_arguments(tool, network) do
    left_out =
      for {{name, argument}, _} <- @needs,
          name == tool.name and argument != nil and not served?(network, {name, argument}),
          do: argument

    if left_out == [] do
      tool
    else
      # The DSL keys properties by atom and lists required arguments as
      # strings; either spelling is dropped.
      drop = left_out ++ Enum.map(left_out, &String.to_atom/1)

      update_in(tool, [:inputSchema], fn schema ->
        schema
        |> Map.update(:properties, %{}, &Map.drop(&1, drop))
        |> Map.update(:required, [], &(&1 -- drop))
      end)
    end
  end

  # get_policy reads a network's published policy pages, and calls no method.
  defp served?(network, {"get_policy", nil}), do: AtMcp.Network.publishes_policies?(network)

  defp served?(network, key) do
    case Map.fetch(@needs, key) do
      {:ok, suffixes} ->
        Enum.any?(suffixes, &is_nil(AtMcp.Endpoints.not_served(network, "app.bsky." <> &1)))

      :error ->
        true
    end
  end
end
