defmodule AtMcp.GrantsTest do
  use ExUnit.Case, async: true
  alias AtMcp.Grants
  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    %{opts: [path: Path.join(dir, "accounts.grants.json")]}
  end

  test "a request reads the store once: the account and the scope come from the same row", ctx do
    {:ok, grant} = Grants.issue("alice", [scope: :write] ++ ctx.opts)

    assert {:ok, "alice", :write} = Grants.authorize(grant.token, ctx.opts)

    # A token the store does not name is refused before an account is chosen.
    assert Grants.authorize("at_mcp-nothing", ctx.opts) == {:error, :unknown_grant}
  end

  # An unreadable store is the case where answering "no such grant" says the
  # opposite of what is true, and sends an operator to reissue a credential that
  # already works. The endpoint turns this into 503, not 401.
  test "a store AtMcp cannot read is not a store with no grants in it", ctx do
    {:ok, grant} = Grants.issue("alice", ctx.opts)
    File.chmod!(ctx.opts[:path], 0o000)
    on_exit(fn -> File.chmod(ctx.opts[:path], 0o600) end)

    assert Grants.authorize(grant.token, ctx.opts) == {:error, :grants_unreadable}
    assert Grants.resolve(grant.token, ctx.opts) == {:error, :grants_unreadable}
  end

  test "an operator who no longer holds the token revokes it by the id issue returned", ctx do
    {:ok, one} = Grants.issue("alice", ctx.opts)
    {:ok, two} = Grants.issue("alice", ctx.opts)

    assert :ok = Grants.revoke_id(one.id, ctx.opts)
    assert Grants.authorize(one.token, ctx.opts) == {:error, :unknown_grant}
    assert {:ok, "alice", _} = Grants.authorize(two.token, ctx.opts)

    # Removing what is already gone is not the same as removing what never was:
    # an operator mistyping an id should hear about it.
    assert Grants.revoke_id(one.id, ctx.opts) == {:error, :unknown_grant}
  end

  test "removing an account takes its credentials with it and leaves every other", ctx do
    {:ok, a1} = Grants.issue("alice", ctx.opts)
    {:ok, a2} = Grants.issue("alice", [scope: :read] ++ ctx.opts)
    {:ok, bob} = Grants.issue("bob", ctx.opts)

    assert {:ok, 2} = Grants.revoke_account("alice", ctx.opts)

    for removed <- [a1, a2] do
      assert Grants.authorize(removed.token, ctx.opts) == {:error, :unknown_grant}
    end

    assert {:ok, "bob", _} = Grants.authorize(bob.token, ctx.opts)
  end

  test "listing grants hands back nothing that reconstructs or confirms a token", ctx do
    {:ok, grant} = Grants.issue("alice", [scope: :read] ++ ctx.opts)
    {:ok, [listed]} = Grants.list(ctx.opts)

    assert listed.account == "alice"
    assert listed.scope == :read
    assert listed.id == grant.id
    refute Map.has_key?(listed, :digest)
    refute Map.has_key?(listed, :token)

    # The stored digest is not the token, so a reader of the file cannot present it.
    refute File.read!(ctx.opts[:path]) =~ grant.token
  end
end
