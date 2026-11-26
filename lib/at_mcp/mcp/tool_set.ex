defmodule AtMcp.MCP.ToolSet do
  @moduledoc """
  Picks the tools `tools/list` offers a session: the default set or the full set.

  Many hosts put every listed tool's definition into the model's context on
  each request, so a session gets the default set unless it asks for the full
  one. It can ask in either of two ways:

    * a grant issued with `--tools full` (`AtMcp.Grants`);
    * `AT_MCP_TOOLS=full`, which covers `at_mcp-stdio` and every grant of a
      service that stores no set of its own.

  The default set holds the tools an agent on a social network uses most:
  reading, posting and replying, and choosing whom it follows, blocks and
  mutes. It adds `get_post_images`, so a model can look at the pictures in a
  post, `pin_post`, to choose the post its profile shows first, and
  `get_policy`, to read the rules of a network that publishes them. Where an
  account can keep private notes (`notes?/0`), it holds the note tools too. It also
  holds `get_record`, `put_record` and `delete_record` for other
  applications' records.

  `tools/call` accepts every published tool, listed or not, so a program that
  calls a tool by name works under either set
  (`test/at_mcp/tool_surface_test.exs`). Most hosts let a model call only the
  tools it was listed, so what a result points a model to should be in its
  set (`offers?/2`).
  """

  @default ~w(
    block delete_post follow get_actor_likes get_author_feed get_blocks get_feed
    get_followers get_follows get_known_followers get_likes get_list_feed get_mutes
    get_notifications get_posts get_profile get_profiles get_quotes get_relationships
    get_reposted_by get_suggested_follows get_thread get_thread_chain get_timeline
    get_unread_count identity_status like mute post reply repost search_actors
    search_posts unblock unfollow unlike unmute unrepost update_profile update_seen
    get_post_images pin_post get_policy
    get_record put_record delete_record
  )

  # The personal notes, and the group invites waiting for the account, in the
  # default set wherever Spaces work: on a network with town spaces, with the
  # Spaces helper running. Without the notes, an agent told to keep something
  # private has nowhere to put it but its public repository; without the
  # invites, it never learns a group asked it in.
  @notes ~w(create_note get_note get_notes update_note delete_note get_group_invites)

  @sets ["default", "full"]

  @doc "The tools the default set always offers."
  def default, do: @default

  @doc "The note tools and get_group_invites, which the default set offers where `notes?/0`."
  def notes, do: @notes

  @doc "Whether this installation's accounts can keep notes (town spaces, and the helper running)."
  def notes? do
    AtMcp.Network.spaces() != nil and AtMcp.Spaces.Helper.available() == :ok
  end

  defp default_names, do: if(notes?(), do: @default ++ @notes, else: @default)

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

  @doc "Filters tools down to those in set."
  def offered(tools, "full"), do: tools

  def offered(tools, "default") do
    names = default_names()
    Enum.filter(tools, &(&1.name in names))
  end

  @doc "Whether the set a session is offered (`of/1`) holds the tool `name`."
  def offers?(state, name), do: of(state) == "full" or name in default_names()
end
