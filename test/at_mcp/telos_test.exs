defmodule AtMcp.TelosTest do
  @moduledoc """
  Someone other than the author can run AtMcp, attach their agents, and give
  those agents identities to act as — without editing several files by hand or
  being told a DID out of band.

  Each test is one claim about that purpose. A claim that is not true yet is
  tagged `:goal` and excluded from `mix test`; making it true deletes the tag in
  the same commit. No claim is tagged today.
  """
  use ExUnit.Case, async: false

  setup do
    path = Path.join(System.tmp_dir!(), "at_mcp-telos-#{System.unique_integer([:positive])}.json")

    # A configured account that is not running: discovery has to describe an
    # installation an operator is still setting up, not only a healthy one.
    File.write!(
      path,
      JSON.encode!(%{
        "version" => 1,
        "accounts" => [
          %{
            "id" => "telos",
            "handle" => "telos.example",
            "did" => "did:plc:telos",
            "password" => "app-password",
            "service" => "https://pds.example"
          }
        ]
      })
    )

    # AtMcp refuses to read a credential file others can read.
    File.chmod!(path, 0o600)
    AtMcp.Test.Settings.put(accounts_file: path)

    on_exit(fn ->
      File.rm_rf!(path)
      File.rm_rf!(AtMcp.Grants.path_for(path))
      File.rm_rf!(AtMcp.Grants.path_for(path) <> ".lock")
    end)

    :ok
  end

  test "an operator can ask an installation which identities it holds" do
    assert %{status: 200, body: body} = get("/identities")
    assert %{"identities" => [identity]} = body
    assert identity["id"] == "telos"
    assert identity["did"] == "did:plc:telos"
    assert identity["handle"] == "telos.example"
  end

  test "the answer carries what a host needs to attach, so no DID is typed by hand" do
    assert %{status: 200, body: %{"identities" => [identity]}} = get("/identities")

    # The descriptor is the shape an MCP client already consumes, so a host can
    # use it without translating it.
    assert %{"name" => "at_mcp-telos", "type" => "http", "url" => url, "headers" => headers} =
             identity["descriptor"]

    # One endpoint for every identity, and the address the service is actually
    # listening on rather than the one it was configured with.
    assert url == "http://127.0.0.1:#{:ranch.get_port(:at_mcp_http)}/mcp"
    assert %{"name" => "x-kite-account-did", "value" => "did:plc:telos"} = hd(headers)

    # And no credential. Discovery is served to any local process; handing one a
    # grant for any identity on request would undo what the grant is for.
    refute Enum.any?(headers, &(&1["name"] == "authorization"))
    refute Jason.encode!(identity) =~ "Bearer"
  end

  # Discovery is asked during setup, which is exactly when an identity is not up
  # yet. An installation that only described healthy identities would be useless
  # for the case it is needed in.
  test "an identity the runtime has not loaded is still listed, and says so" do
    assert %{status: 200, body: %{"identities" => [identity]}} = get("/identities")

    assert identity["descriptor"]["url"] ==
             "http://127.0.0.1:#{:ranch.get_port(:at_mcp_http)}/mcp"

    # Absent, not stopped: only the first is fixed by a reload.
    assert identity["runtime"] == nil
  end

  # Reporting no identities because the file could not be read tells an operator
  # the opposite of what is true.
  test "a configuration that cannot be read is reported as unreadable, not as empty" do
    File.chmod!(AtMcp.AccountConfig.path(), 0o644)

    assert %{status: 503, body: body} = get("/identities")
    assert body["error"] == "configuration_unreadable"
    refute Map.has_key?(body, "identities")
  end

  # Reading the snapshot as the wrong shape reports every identity as unknown to
  # the runtime, which is indistinguishable from an installation that has not
  # started yet. Pin the shape the identity list joins against; the populated
  # case needs a loaded account and is covered against a running service.
  test "the runtime snapshot is the shape the identity list joins against" do
    assert {:ok, accounts} = AtMcp.Accounts.status()
    assert is_list(accounts)
  end

  test "no tool lets an agent enumerate the installation's identities" do
    {:ok, tools, nil, :state} = AtMcp.MCP.Server.handle_list_tools(nil, :state)
    names = Enum.map(tools, & &1.name)

    refute Enum.any?(names, &(&1 =~ "accounts" or &1 =~ "identities"))

    # identity_status answers for the one account the connection is bound to.
    assert "identity_status" in names
  end

  test "an identity's own MCP port does not serve identity discovery" do
    conn =
      AtMcp.MCP.HTTP.call(
        Plug.Test.conn(:get, "/identities"),
        AtMcp.MCP.HTTP.init(effects: :unused, port: 4499)
      )

    refute conn.status == 200
  end

  # An installation is configured by its accounts file alone. There is no
  # resource-server mode and no environment group that decides what a client
  # must present: a configured account always uses its account quota.
  test "an installation is configured one way" do
    refute Code.ensure_loaded?(AtMcp.MCP.OAuth)

    assert {:ok, _specs} =
             AtMcp.Identities.named_identity_specs(AtMcp.AccountConfig.path())
  end

  test "the network AtMcp talks to is a value, not a literal" do
    # town.delve.* is a complete rename of app.bsky.*: 165 NSIDs, one rule, no
    # orphans. The record limits differ, so `AtMcp.Network` reads them from each
    # network's lexicon rather than holding them as literals, which would refuse
    # posts far below the town network's limit. Bluesky is the default.
    assert AtMcp.Network.collection(:post) == "app.bsky.feed.post"
    assert %{graphemes: 300, bytes: 3_000} = AtMcp.Network.post_limits()

    Application.put_env(:at_mcp, :network, :delve)
    on_exit(fn -> Application.delete_env(:at_mcp, :network) end)

    assert AtMcp.Network.collection(:post) == "town.delve.feed.post"
    assert %{graphemes: 100_000, bytes: 500_000} = AtMcp.Network.post_limits()

    long = String.duplicate("a", 5_000)
    assert :ok = AtMcp.Effects.validate_post_text(long)
  end

  defp get(path) do
    port = :ranch.get_port(:at_mcp_control_http)
    Req.get!("http://127.0.0.1:#{port}#{path}", retry: false)
  end

  test "one endpoint serves every identity" do
    # One listener serves every identity, and what distinguishes two attachments
    # is the credential each presents — not the address, and not a header the
    # caller chose. `x-kite-account-did` confirms only.
    url = "http://127.0.0.1:#{:ranch.get_port(:at_mcp_http)}/mcp"

    for id <- ["one-endpoint-a", "one-endpoint-b"] do
      did = "did:plc:" <> id

      {:ok, _} =
        AtMcp.Identities.start_identity(
          id: id,
          listen_enabled: false,
          expected_did: did,
          backend: AtMcp.Test.MockBackend,
          backend_state: %{did: did, mock: true}
        )

      on_exit(fn -> AtMcp.Identities.stop_identity(id) end)

      headers = AtMcp.Test.Grant.session!(AtMcp.Test.Grant.token(id, :read))

      body =
        Req.post!(url,
          headers: headers ++ [{"x-kite-account-did", did}],
          json: %{
            jsonrpc: "2.0",
            id: System.unique_integer([:positive]),
            method: "tools/call",
            params: %{name: "identity_status", arguments: %{}}
          },
          retry: false
        ).body

      assert body["result"]["structuredContent"]["did"] == did,
             "#{id} was not served: #{inspect(body)}"
    end

    # Both were reached at the same address.
    assert url == AtMcp.Test.Grant.url()
  end

  test "AtMcp builds the records it posts" do
    # ProtoRune.Bsky.post/3 validates through Peri, which drops keys it does not
    # know without error: an embed passed to it arrives as {:ok, ...} with the
    # embed gone, and langs is stamped ["en"] unconditionally. AtMcp builds the
    # record itself, so media, quote posts and a post's own language are all
    # possible.
    record = AtMcp.ATProto.post_record(text: "a picture", images: [%{blob: :fake, alt: "alt"}])

    assert record["$type"] == "app.bsky.feed.post"
    assert record["embed"]["$type"] == "app.bsky.embed.images"
    assert [%{"alt" => "alt"}] = record["embed"]["images"]

    # A quote is a strong reference, so it carries the CID as well as the URI:
    # the builder is pure, and a reference it could weaken to a bare URI would
    # be one the service rejects. `AtMcp.Effects.ProtoRune` reads the CID off the
    # quoted record before calling this.
    quoted = %{uri: "at://did:plc:x/app.bsky.feed.post/1", cid: "bafyreiquoted"}
    quote_record = AtMcp.ATProto.post_record(text: "see this", quote: quoted)

    assert quote_record["embed"]["$type"] == "app.bsky.embed.record"
    assert quote_record["embed"]["record"] == %{"uri" => quoted.uri, "cid" => quoted.cid}

    refute AtMcp.ATProto.post_record(text: "unmarked")["langs"] == ["en"]
  end

  test "an agent acts only as the identity its credential names" do
    # A party contains agents trusted differently, so which identity a caller
    # acts as follows from the credential it presents, not from an address or a
    # header it picked. Grants are self-issued and validated by AtMcp: no
    # authorization server, no TLS, loopback only, and `Bearer` as the shape.
    {:ok, grant} = AtMcp.Grants.issue("telos", scope: :read)

    assert {:ok, "telos"} = AtMcp.Grants.resolve(grant.token)
    assert AtMcp.Grants.scope(grant.token) == :read

    # The credential names one identity. It cannot reach another, whatever the
    # caller asks for.
    {:ok, other} = AtMcp.Grants.issue("second", scope: :write)
    refute AtMcp.Grants.resolve(other.token) == {:ok, "telos"}

    # Scope follows what each tool declares about itself — AtMcp already sets
    # readOnlyHint and destructiveHint on every tool — rather than a list of
    # verbs kept in step by hand.
    assert AtMcp.Grants.permits?(grant.token, "get_timeline")
    refute AtMcp.Grants.permits?(grant.token, "post")
    assert AtMcp.Grants.permits?(other.token, "post")

    # Revocation is immediate and needs no restart; the accounts file already
    # reloads.
    :ok = AtMcp.Grants.revoke(grant.token)
    assert AtMcp.Grants.resolve(grant.token) == {:error, :unknown_grant}
  end
end
