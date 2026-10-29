defmodule AtMcp.MCP.ToolSet do
  @moduledoc """
  Which tools `tools/list` offers a session: the default set, or the full set.

  Hosts that load tool definitions into the model's context pay for every
  listed tool on every request, and an agent offered a hundred tools chooses
  worse than one offered what it uses. So a session is offered a default set
  unless it asks for the full one: a grant issued with `--tools full`
  (`AtMcp.Grants`), or `AT_MCP_TOOLS=full` for `at_mcp-stdio` and for the
  grants of a service that sets it.

  The default set is what agents use: the forty tools Grove's residents on
  Delvetown are given (dwell's `templates/model-resident.toml`), and the
  records tools outside agents asked for.

  Leaving a tool out of the list does not unpublish it. `tools/call` accepts
  every published tool whichever set was listed, so a caller that already
  uses one keeps working (`test/at_mcp/tool_surface_test.exs`).
  """

  @default ~w(
    block delete_post follow get_actor_likes get_author_feed get_blocks get_feed
    get_followers get_follows get_known_followers get_likes get_list_feed get_mutes
    get_notifications get_posts get_profile get_profiles get_quotes get_relationships
    get_reposted_by get_suggested_follows get_thread get_thread_chain get_timeline
    get_unread_count identity_status like mute post reply repost search_actors
    search_posts unblock unfollow unlike unmute unrepost update_profile update_seen
    get_record put_record delete_record
  )

  @sets ["default", "full"]

  @doc "The tools the default set offers."
  def default, do: @default

  @doc "The sets a grant or `AT_MCP_TOOLS` can name."
  def sets, do: @sets

  @doc """
  The set a session is offered: its grant's, else the `:tool_set` the
  environment configured (`AT_MCP_TOOLS`), else the default.
  """
  def of(state) do
    case (is_map(state) && Map.get(state, :tools)) ||
           Application.get_env(:at_mcp, :tool_set) do
      set when set in [:full, "full"] -> "full"
      _ -> "default"
    end
  end

  @doc "`tools` as `set` offers them."
  def offered(tools, "full"), do: tools
  def offered(tools, "default"), do: Enum.filter(tools, &(&1.name in @default))
end
