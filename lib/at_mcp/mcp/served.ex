defmodule AtMcp.MCP.Served do
  @moduledoc """
  What a session is offered of the tools and arguments that need a method
  this network's deployment does not serve (`AtMcp.Endpoints.deployments/0`).

  An agent offered `grouped` on a network that answers it with 501 took the
  refusal to mean it had no notifications (dwell#455). So `tools/list` leaves
  out an argument whose method the network does not serve, and a tool whose
  every method it does not serve. A call that names one anyway is still
  accepted and refused before anything is sent, as before: leaving something
  out of a list does not unpublish it (`test/at_mcp/tool_surface_test.exs`).
  """

  # Each tool, or one of its arguments, and the methods (suffixes of the
  # network's namespace) it needs. A tool is left out when the network serves
  # none of them; an argument, when it does not serve its one.
  @needs %{
    {"get_notifications", "grouped"} => ["notification.getGroupedNotifications"],
    {"update_profile", "links"} => ["actor.link"],
    {"get_trends", nil} => ["unspecced.getTrends", "unspecced.getTrendingTopics"],
    {"feed_feedback", nil} => ["feed.sendInteractions"]
  }

  @doc "The needs above, for tests: `%{{tool, argument | nil} => [suffix]}`."
  def needs, do: @needs

  @doc "`tools` as `network` serves them."
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

  defp served?(network, key) do
    case Map.fetch(@needs, key) do
      {:ok, suffixes} ->
        Enum.any?(suffixes, &is_nil(AtMcp.Endpoints.not_served(network, "app.bsky." <> &1)))

      :error ->
        true
    end
  end
end
