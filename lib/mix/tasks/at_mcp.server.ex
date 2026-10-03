defmodule Mix.Tasks.AtMcp.Server do
  @shortdoc "Start AtMcp HTTP MCP + Jetstream listen"
  @moduledoc """
  Starts the AtMcp application and keeps the VM alive.

      mix at_mcp.server

  Port: `AT_MCP_PORT` (default 4400).
  Auth: `BLUESKY_HANDLE`, `BLUESKY_APP_PASSWORD`.
  """

  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")
    AtMcp.CLI.server()
  end
end
