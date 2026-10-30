defmodule Mix.Tasks.AtMcp.ToolsDoc do
  @shortdoc "Write docs/tools.md from the tools the MCP server declares"
  @moduledoc """
  Writes `docs/tools.md`, the list of every MCP tool, from what
  `AtMcp.MCP.Server` declares: each tool's name, the first sentence of its
  description, whether it counts against the write quota (its
  `at_mcp/publicWrite` annotation) and the smallest grant scope that reaches it
  (`AtMcp.Grants.permits_scope?/2`).

      mix at_mcp.tools_doc

  `test/at_mcp/tool_surface_test.exs` fails when the file differs from what
  this task would write, so a change to a tool comes with the regenerated file.
  """

  use Mix.Task

  @path "docs/tools.md"

  @doc "Where the file lives, relative to the project root."
  def path, do: @path

  @impl Mix.Task
  def run(_args) do
    if Mix.Project.config()[:app] != :at_mcp,
      do: Mix.raise("mix at_mcp.tools_doc writes at_mcp's own docs/tools.md; run it in at_mcp")

    Mix.Task.run("compile")
    File.write!(@path, render())
    Mix.shell().info("wrote #{@path}")
  end

  @doc "The file's contents, from the tools the server declares."
  def render do
    {:ok, tools, nil, :state} = AtMcp.MCP.Server.handle_list_tools(nil, :state)
    tools = Enum.sort_by(tools, & &1.name)
    {reads, writes} = Enum.split_with(tools, &(&1.annotations[:readOnlyHint] == true))

    """
    # Tools

    <!-- `mix at_mcp.tools_doc` writes this file from the tools the server
    declares. Do not edit it by hand: `mix check` fails when it is out of date. -->

    at_mcp offers #{length(tools)} tools, #{length(reads)} for reading and \
    #{length(writes)} for writing. Each row gives the first sentence of the \
    tool's description. The agent's MCP client shows it the full description \
    and the arguments.

    A client gets the default set, the #{length(AtMcp.MCP.ToolSet.default())} \
    tools marked "default" below, unless its grant was issued with \
    `--tools full` or the service sets `AT_MCP_TOOLS=full` \
    ([operations.md](operations.md#offer-a-client-every-tool)). Then it gets \
    every tool its scope allows and its network serves.

    A client running `at_mcp-stdio` can call every tool. A client of a \
    long-running service holds a grant, and the grant's scope limits its \
    tools: `read` allows the reads, `write` adds the writes marked `write`, \
    and `manage` allows everything \
    ([operations.md](operations.md#limit-a-clients-tools)).

    ## Reads

    Reads return readable text, so a model gets the same result in every \
    host. A program that parses results can pass `"format": "json"` to get \
    the full summary as structured content and as JSON text. Issuing its \
    grant with `--format json` makes json the default instead. \
    `identity_status` and `get_unread_count`, which report the connection's \
    own state, always return their structured content, with its JSON as the \
    text.

    A page of posts is at most #{AtMcp.Reading.page_chars()} characters of \
    text. When a page would be longer, at_mcp returns fewer posts, says how \
    many it dropped, and returns a cursor that starts with them. A page asked \
    for as JSON keeps every post up to `limit`. With `"detail": "brief"`, each \
    post gets one line: the author, the time, the first line of the text, the \
    counts and the uri. `get_posts` returns a post in full.

    at_mcp remembers how far the account has read in the timeline, each list \
    feed, each author feed and the notifications. A read of one of these with \
    `"since": "last_read"` returns only the items newer than that point, \
    newest first, and says how many are new. It then moves the point to the \
    newest item it returned.

    - Every client of the account shares these positions, and they survive a \
    restart.
    - When more new items wait below the first page, the position moves after \
    the agent follows the cursor down to the old position, so the agent \
    doesn't skip any item.
    - A read with a time as `since` leaves the position alone. A read without \
    `since` moves it only when it passes `"mark_read": true`.
    - Before the first read of the notifications with `last_read`, their \
    position is where the account last marked them seen, as the app shows \
    them unread.
    - Custom feeds have no read position, because each feed's generator \
    decides the order of its own posts.

    | Tool | Set | What it does |
    | --- | --- | --- |
    #{Enum.map_join(reads, "\n", &"| `#{&1.name}` | #{set(&1.name)} | #{summary(&1)} |")}

    ## Writes

    Writes marked "yes" under "Publishes" count against the account's write \
    quota. Other tools leave the quota alone.

    | Tool | Set | Publishes | Scope | What it does |
    | --- | --- | --- | --- | --- |
    #{Enum.map_join(writes, "\n", &write_row/1)}
    """
  end

  defp write_row(tool) do
    publishes = if tool.annotations[:"at_mcp/publicWrite"] == true, do: "yes", else: ""

    "| `#{tool.name}` | #{set(tool.name)} | #{publishes} | #{scope(tool.name)} | #{summary(tool)} |"
  end

  defp set(name), do: if(name in AtMcp.MCP.ToolSet.default(), do: "default", else: "full")

  defp scope(name),
    do: Enum.find([:read, :write, :manage], &AtMcp.Grants.permits_scope?(&1, name))

  # The first sentence: up to the first period followed by a space, outside
  # parentheses. A first sentence that runs past a colon into a long list
  # stops at the colon.
  defp summary(tool) do
    sentence = tool.description |> String.replace(~r/\s+/, " ") |> first_sentence()

    sentence =
      case String.split(sentence, ": ", parts: 2) do
        [head, _rest] when byte_size(sentence) > 200 -> head <> "."
        _ -> sentence
      end

    String.replace(sentence, "|", "\\|")
  end

  defp first_sentence(text), do: first_sentence(text, 0, "")

  defp first_sentence("", _depth, acc), do: acc
  defp first_sentence(". " <> _, 0, acc), do: acc <> "."
  defp first_sentence("(" <> rest, depth, acc), do: first_sentence(rest, depth + 1, acc <> "(")

  defp first_sentence(")" <> rest, depth, acc),
    do: first_sentence(rest, max(depth - 1, 0), acc <> ")")

  defp first_sentence(<<c::utf8, rest::binary>>, depth, acc),
    do: first_sentence(rest, depth, acc <> <<c::utf8>>)
end
