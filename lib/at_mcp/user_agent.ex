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

  @doc """
  Makes it Req's default for every request in this node, with the
  certificate authorities `AT_MCP_CA_FILE` names when it is set
  (`ca_options/0`).
  """
  def install do
    Req.default_options([user_agent: value()] ++ ca_options())
    :ok
  end

  @doc """
  Req's options for `AT_MCP_CA_FILE`: a PEM bundle of the certificate
  authorities to trust, in place of the system's, for a test network whose
  services have certificates of its own (a local proxy's root). Nothing in
  production needs it. The Spaces helper, a Node process, reads Node's
  `NODE_EXTRA_CA_CERTS` instead.
  """
  def ca_options do
    case Application.get_env(:at_mcp, :ca_file) do
      file when is_binary(file) and file != "" ->
        [connect_options: [transport_opts: [cacertfile: file]]]

      _ ->
        []
    end
  end
end
