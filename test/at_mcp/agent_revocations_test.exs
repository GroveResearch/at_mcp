defmodule AtMcp.Spaces.AgentRevocationsTest do
  @moduledoc """
  No agent's password is kept: an earlier file of them is removed at start,
  keeping only which agents were revoked.
  """
  use ExUnit.Case, async: false
  alias AtMcp.Spaces.AgentRevocations

  setup do
    old = Path.join(AtMcp.Inbound.Store.default_dir(), "agent-passwords.json")
    on_exit(fn -> File.rm(old) end)
    %{old: old}
  end

  test "the kept passwords go, and a revoked agent stays marked", ctx do
    File.mkdir_p!(Path.dirname(ctx.old))

    File.write!(
      ctx.old,
      Jason.encode!(%{
        version: 1,
        principals: %{
          "did:plc:p" => %{
            "did:plc:revoked" => %{password: "secret-one", stale: true},
            "did:plc:running" => %{password: "secret-two"}
          }
        }
      })
    )

    assert :ok = AgentRevocations.migrate()
    refute File.exists?(ctx.old)
    assert AgentRevocations.revoked?("did:plc:p", "did:plc:revoked")
    refute AgentRevocations.revoked?("did:plc:p", "did:plc:running")
    refute File.read!(AgentRevocations.path()) =~ "secret"

    AgentRevocations.clear("did:plc:p", "did:plc:revoked")
    refute AgentRevocations.revoked?("did:plc:p", "did:plc:revoked")
    # Nothing to do the next time.
    assert :ok = AgentRevocations.migrate()
  end
end
