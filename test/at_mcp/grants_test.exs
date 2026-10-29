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

  test "a grant may carry the format its reads answer in, read in the same lookup", ctx do
    {:ok, json} = Grants.issue("alice", [scope: :read, format: "json"] ++ ctx.opts)
    {:ok, plain} = Grants.issue("alice", ctx.opts)

    assert json.format == "json"

    assert {:ok, %{account: "alice", scope: :read, format: "json"}} =
             Grants.request(json.token, ctx.opts)

    assert {:ok, %{format: nil}} = Grants.request(plain.token, ctx.opts)
    assert {:ok, [%{format: "json"}, %{format: nil}]} = Grants.list(ctx.opts)

    assert Grants.issue("alice", [format: "yaml"] ++ ctx.opts) == {:error, :invalid_format}
  end

  test "a new grant's token starts with at_mcp-", ctx do
    {:ok, grant} = Grants.issue("alice", ctx.opts)
    assert "at_mcp-" <> rest = grant.token
    assert byte_size(rest) > 32
  end

  # Grants issued before the prefix changed start with `kite-`, and operators
  # still hold them. The store keeps only digests, so the prefix never matters.
  test "a grant issued under the earlier kite- prefix still authorizes", ctx do
    {:ok, _} = Grants.issue("alice", ctx.opts)
    path = ctx.opts[:path]
    old = "kite-" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    row = %{
      "id" => "earlier",
      "account" => "bob",
      "scope" => "read",
      "digest" => :crypto.hash(:sha256, old) |> Base.encode16(case: :lower),
      "issued_at" => "2026-09-11T00:00:00Z"
    }

    store = path |> File.read!() |> Jason.decode!() |> Map.update!("grants", &(&1 ++ [row]))
    File.write!(path, Jason.encode!(store))
    File.chmod!(path, 0o600)

    assert Grants.authorize(old, ctx.opts) == {:ok, "bob", :read}
    assert Grants.resolve(old, ctx.opts) == {:ok, "bob"}
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
