defmodule Mix.Tasks.AtMcp.Server do
  @shortdoc "Start AtMcp HTTP MCP + Jetstream listen"
  @moduledoc """
  Starts the AtMcp application and keeps the VM alive.

      mix at_mcp.server

  Settings come from the environment; README.md, "Settings", lists them.
  """

  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")
    AtMcp.CLI.server()
  end
end
