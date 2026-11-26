defmodule AtMcp.UserAgent do
  @moduledoc """
  The `User-Agent` AtMcp sends: `at_mcp/<version>`, so the request logs of a
  PDS, an AppView or a group host show at_mcp use exactly. Every HTTP request
  AtMcp makes goes through Req, whose default options carry it
  (`install/0`, at boot), and the Spaces helper sends the same value
  (`AtMcp.Spaces.Helper`).
  """

  @doc "The value: `at_mcp/` and the running release's version."
  def value do
    case Application.spec(:at_mcp, :vsn) do
      nil -> "at_mcp/0.0.0-dev"
      vsn -> "at_mcp/" <> to_string(vsn)
    end
  end

  @doc "Makes it Req's default for every request in this node."
  def install do
    Req.default_options(user_agent: value())
    :ok
  end
end
