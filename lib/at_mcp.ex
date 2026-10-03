defmodule AtMcp do
  @moduledoc """
  An agent's own AT Protocol account: sessions, tools and durable account policy.

  The same interface serves Bluesky (`app.bsky.*`) and Delvetown
  (`town.delve.*`), selected by `AtMcp.Network`. Accounts keep their own PDS
  and DID; selecting a network changes the application namespace, not identity.
  AtMcp does not expose arbitrary AT Protocol applications.

  Start with the [account walkthrough](readme.html) for an MCP client or the
  [embedding guide](embedding.html) for an Elixir application. These explain
  installation and first use; the modules below describe the programming API.

  An embedded host configures `:boot_from_env` to `false` before application
  startup, supplies accounts through `AtMcp.Identities.start_identity/1`, and
  calls `AtMcp.Effects`. `AtMcp.Accounts.disconnect/1` persists an explicit
  stop; `AtMcp.Accounts.reconnect/1` logs in and resumes it. The host must supply
  dynamic account configurations again after its runtime restarts.

  A standalone stdio process owns one account for one client. A shared service
  owns named accounts behind one loopback MCP endpoint; each client's grant
  selects its account and scope. Optional incoming collection and durable
  delivery belong to AtMcp; routing, conversations and agent turns belong to
  the receiving application.
  """

  @doc "Configured MCP HTTP port for the shared endpoint; this does not test whether it is listening."
  def mcp_port do
    Application.get_env(:at_mcp, :mcp_port, 4400)
  end
end
