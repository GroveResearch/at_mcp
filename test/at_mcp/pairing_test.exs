defmodule AtMcp.PairingTest do
  use ExUnit.Case, async: false

  alias AtMcp.Effects.Failure

  @service "https://pds.example"
  @pds_did "did:web:pds.example"
  @principal "did:plc:principal"
  @agent "did:plc:agent"
  @plc "https://plc.example"

  setup do
    dir = Path.join(System.tmp_dir!(), "at_mcp-pairing-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    previous = Application.get_env(:at_mcp, :keys_dir)
    previous_plc = Application.get_env(:at_mcp, :plc_url)
    Application.put_env(:at_mcp, :keys_dir, Path.join(dir, "keys"))
    Application.put_env(:at_mcp, :plc_url, @plc)

    on_exit(fn ->
      restore(:keys_dir, previous)
      restore(:plc_url, previous_plc)
      File.rm_rf!(dir)
    end)

    %{path: Path.join(dir, "accounts.json")}
  end

  defp restore(key, nil), do: Application.delete_env(:at_mcp, key)
  defp restore(key, value), do: Application.put_env(:at_mcp, key, value)

  # A clock that moves only when the flow sleeps, a helper whose key is
  # unknown until `known_after` sign-in attempts, and a directory with the
  # ident.link pair.
  defp fakes(opts \\ []) do
    test = self()
    {:ok, clock} = Agent.start_link(fn -> 0 end)
    {:ok, tries} = Agent.start_link(fn -> 0 end)
    known_after = Keyword.get(opts, :known_after, 2)
    endorsed = Keyword.get(opts, :endorsed, true)
    login_error = Keyword.get(opts, :login_error, "key_refused")
    limited = Keyword.get(opts, :limited, 0)

    helper = fn
      "key.generate", %{keyFile: file} ->
        File.mkdir_p!(Path.dirname(file))
        File.write!(file, ~s({"kty":"EC"}))
        File.chmod!(file, 0o600)
        {:ok, %{"didKey" => "did:key:zDnaeNew", "jkt" => "jkt"}}

      "key.public", %{keyFile: file} ->
        send(test, {:public, file})
        {:ok, %{"didKey" => "did:key:zDnaeNew", "jkt" => "jkt"}}

      "key.prove", params ->
        n = System.unique_integer([:positive])
        send(test, {:proved, params})
        {:ok, %{"proof" => "proof-#{n}"}}

      "oauth.login", params ->
        send(test, {:login, params})
        n = Agent.get_and_update(tries, &{&1 + 1, &1 + 1})

        cond do
          n <= limited -> {:error, Failure.new(:refused, detail: "rate_limited", message: "429")}
          n > known_after -> {:ok, %{"did" => @agent}}
          true -> {:error, Failure.new(:refused, detail: login_error, message: "refused")}
        end

      "oauth.logout", _ ->
        {:ok, %{}}
    end

    get_json = fn
      @service <> "/xrpc/com.atproto.server.describeServer" ->
        {:ok, %{"did" => @pds_did, "availableUserDomains" => [".example"]}}

      @service <> "/xrpc/com.atproto.identity.resolveHandle?handle=boss.example" ->
        {:ok, %{"did" => @principal}}

      @plc <> "/" <> @agent ->
        {:ok,
         %{"alsoKnownAs" => ["at://scout.example", "https://ident.link/agent-of/" <> @principal]}}

      @plc <> "/" <> @principal ->
        {:ok, %{"service" => [%{"id" => "#atproto_pds", "serviceEndpoint" => @service}]}}

      @service <> "/xrpc/com.atproto.repo.getRecord?" <> _ ->
        if endorsed,
          do: {:ok, %{"value" => %{"agent" => @agent}}},
          else: {:error, {:http, 400}}

      _ ->
        {:error, :not_found}
    end

    %{
      helper: helper,
      get_json: get_json,
      say: &send(test, {:said, &1}),
      sleep: fn ms -> Agent.update(clock, &(&1 + ms)) end,
      now_ms: fn -> Agent.get(clock, & &1) end
    }
  end

  test "setup prints a link bound to the principal and the handle, signs in by key alone, and saves the agent",
       %{path: path} do
    assert {:ok, result} =
             AtMcp.AccountSetup.execute(
               [
                 "--file",
                 path,
                 "setup",
                 "scout",
                 "--principal",
                 "boss.example",
                 "--service",
                 @service
               ],
               pairing: fakes()
             )

    assert_received {:proved, proof}

    assert %{
             iss: @principal,
             sub: "scout.example",
             aud: @pds_did,
             lxm: "town.delve.agent.createAgent"
           } =
             Map.take(proof, [:iss, :sub, :aud, :lxm])

    assert_received {:said, "Open this link" <> _}
    assert_received {:said, "https://" <> _ = link}
    %URI{path: "/agents/new", fragment: fragment} = URI.parse(link)

    assert %{
             "v" => "1",
             "key" => "did:key:zDnaeNew",
             "handle" => "scout.example",
             "principal" => @principal,
             "proof" => "proof-" <> _
           } = URI.decode_query(fragment)

    # The sign-in names no account: the PDS finds it by the key.
    assert_received {:login, %{account: @service}}

    assert result.account["did"] == @agent
    assert result.account["handle"] == "scout.example"
    assert result.principal_confirmed
    key_file = AtMcp.Spaces.key_path(@agent)
    assert result.key_file == key_file
    assert File.stat!(key_file).mode |> Bitwise.band(0o777) == 0o600
    {:ok, [saved]} = AtMcp.AccountConfig.load(path)
    assert saved["key_file"] == key_file
    refute Map.has_key?(saved, "password")
    # No pending key is left behind.
    assert Path.wildcard(Path.join(AtMcp.Spaces.keys_dir(), "login-pending-*")) == []
  end

  test "a link is replaced every 4 minutes while setup waits" do
    deps = fakes(known_after: 25)

    assert {:ok, _} =
             AtMcp.Pairing.setup(
               %{
                 principal: @principal,
                 name: "scout",
                 handle: nil,
                 service: @service,
                 key_file: Path.join(AtMcp.Spaces.keys_dir(), "k.json"),
                 scope: "atproto",
                 web_origin: "https://web.example",
                 wait_ms: 30 * 60_000
               },
               deps
             )

    # 25 refusals at 20 s each is 500 s: links at 0, 240 and 480 s.
    msgs = drain()
    proofs = for {:proved, p} <- msgs, do: p
    assert length(proofs) == 3
    # Within the PDS's limit of 30 signed authorizes per 5 minutes per address.
    logins = for {:login, _} <- msgs, do: 1
    assert length(logins) == 26
  end

  test "a setup that runs out of time keeps its key; the same command resumes with it and first looks for the account",
       %{path: path} do
    args = ["--file", path, "setup", "scout", "--principal", @principal, "--service", @service]

    assert {:error, :pairing_unsettled} =
             AtMcp.AccountSetup.execute(args ++ ["--wait-minutes", "1"],
               pairing: fakes(known_after: 1_000)
             )

    assert {:ok, []} = AtMcp.AccountConfig.load(path)
    assert [pending_key] = Path.wildcard(Path.join(AtMcp.Spaces.keys_dir(), "login-pending-*"))
    drain()

    # The principal created the agent after at_mcp stopped waiting (or the
    # answer was lost): the resumed run signs in with the kept key at once,
    # before printing any link.
    assert {:ok, %{account: %{"did" => @agent}}} =
             AtMcp.AccountSetup.execute(args, pairing: fakes(known_after: 0))

    msgs = drain()
    assert {:public, ^pending_key} = Enum.find(msgs, &match?({:public, _}, &1))
    refute Enum.any?(msgs, &match?({:proved, _}, &1))
    assert Path.wildcard(Path.join(AtMcp.Spaces.keys_dir(), "login-pending-*")) == []
    assert Path.wildcard(Path.join(AtMcp.Spaces.keys_dir(), "pairing-*")) == []
  end

  test "a pending pairing for other details is refused, and --cancel discards it", %{path: path} do
    args = ["--file", path, "setup", "scout", "--principal", @principal, "--service", @service]

    assert {:error, :pairing_unsettled} =
             AtMcp.AccountSetup.execute(args ++ ["--wait-minutes", "1"],
               pairing: fakes(known_after: 1_000)
             )

    assert {:error, :pairing_pending} =
             AtMcp.AccountSetup.execute(
               [
                 "--file",
                 path,
                 "setup",
                 "scout",
                 "--principal",
                 "did:plc:other",
                 "--service",
                 @service
               ],
               pairing: fakes()
             )

    assert {:ok, %{cancelled: "scout"}} =
             AtMcp.AccountSetup.execute(["--file", path, "setup", "scout", "--cancel"],
               pairing: fakes()
             )

    assert Path.wildcard(Path.join(AtMcp.Spaces.keys_dir(), "login-pending-*")) == []

    assert {:error, :no_pending_pairing} =
             AtMcp.AccountSetup.execute(["--file", path, "setup", "scout", "--cancel"],
               pairing: fakes()
             )
  end

  test "repair works on a machine that has only the agent's DID, and saves the account", %{
    path: path
  } do
    base = fakes()

    get_json = fn
      @plc <> "/" <> @agent ->
        {:ok,
         %{
           "alsoKnownAs" => ["at://scout.example", "https://ident.link/agent-of/" <> @principal],
           "service" => [%{"id" => "#atproto_pds", "serviceEndpoint" => @service}]
         }}

      url ->
        base.get_json.(url)
    end

    assert {:ok, %{account: account, key_file: key_file, fingerprint: fp}} =
             AtMcp.AccountSetup.execute(["--file", path, "repair", "scout", "--did", @agent],
               pairing: %{base | get_json: get_json}
             )

    assert account == %{
             "id" => "scout",
             "did" => @agent,
             "handle" => "scout.example",
             "service" => @service
           }

    assert key_file == AtMcp.Spaces.key_path(@agent)
    assert fp =~ ~r/\A[A-Z2-7]{4}-[A-Z2-7]{4}\z/
    assert_received {:proved, %{lxm: "town.delve.agent.enrollKey", sub: @agent, iss: @principal}}
    {:ok, [saved]} = AtMcp.AccountConfig.load(path)
    assert saved["key_file"] == key_file
  end

  test "the key fingerprint is the one the web page computes from the link's key" do
    # SHA-256 of the did:key's UTF-8, base32 (RFC 4648, no padding), first 8, as XXXX-XXXX.
    key = "did:key:zDnaeVRuQyji7mCyNohpPwZ5TK54U1"

    <<a::binary-size(4), b::binary-size(4), _::binary>> =
      Base.encode32(:crypto.hash(:sha256, key))

    assert AtMcp.Pairing.fingerprint(key) == a <> "-" <> b
    # The same value JavaScript gets (WebCrypto SHA-256, then base32): pinned.
    assert AtMcp.Pairing.fingerprint(key) == "JLHC-WPLV"
  end

  test "a PDS that doesn't offer sign-in by key is refused before any link, and the key goes", %{
    path: path
  } do
    assert {:error, %Failure{detail: "signed_authorize_unsupported"}} =
             AtMcp.AccountSetup.execute(
               [
                 "--file",
                 path,
                 "setup",
                 "scout",
                 "--principal",
                 @principal,
                 "--service",
                 @service
               ],
               pairing: fakes(login_error: "signed_authorize_unsupported")
             )

    refute Enum.any?(drain(), &match?({:proved, _}, &1))
    assert Path.wildcard(Path.join(AtMcp.Spaces.keys_dir(), "login-pending-*")) == []
    assert Path.wildcard(Path.join(AtMcp.Spaces.keys_dir(), "pairing-*")) == []
  end

  test "a preview that names an account stops setup at once" do
    assert {:error, {:before_link, %Failure{detail: "preview_mismatch"}}} =
             AtMcp.Pairing.setup(
               %{
                 principal: @principal,
                 name: "scout",
                 handle: nil,
                 service: @service,
                 key_file: Path.join(AtMcp.Spaces.keys_dir(), "k2.json"),
                 scope: "atproto",
                 web_origin: "https://web.example"
               },
               fakes(login_error: "preview_mismatch")
             )

    assert length(for({:login, _} <- drain(), do: 1)) == 1
  end

  test "an agent the principal hasn't endorsed is saved, and says so", %{path: path} do
    assert {:ok, %{principal_confirmed: false, next: next}} =
             AtMcp.AccountSetup.execute(
               [
                 "--file",
                 path,
                 "setup",
                 "scout",
                 "--principal",
                 @principal,
                 "--service",
                 @service
               ],
               pairing: fakes(endorsed: false)
             )

    assert next =~ "endorsement"
  end

  test "a name that can't start a handle is refused before any key is made", %{path: path} do
    assert {:error, :invalid_agent_name} =
             AtMcp.AccountSetup.execute(
               ["--file", path, "setup", "my_agent", "--principal", @principal],
               pairing: fakes()
             )

    refute_received {:proved, _}
  end

  test "repair binds the proof to the agent's DID and the confirmed principal, then replaces the key",
       %{path: path} do
    {:ok, _} =
      AtMcp.AccountSetup.execute(
        ["--file", path, "setup", "scout", "--principal", @principal, "--service", @service],
        pairing: fakes()
      )

    key_file = AtMcp.Spaces.key_path(@agent)
    File.write!(key_file, "old")
    drain()

    assert {:ok, %{key_file: ^key_file}} =
             AtMcp.AccountSetup.execute(["--file", path, "repair", "scout"], pairing: fakes())

    assert_received {:proved, proof}
    assert %{iss: @principal, sub: @agent, lxm: "town.delve.agent.enrollKey"} = proof
    assert_received {:said, "https://" <> _ = link}
    assert URI.parse(link).path == "/agents/#{@agent}/start"
    # The sign-in is as the agent, with the new key.
    assert_received {:login, %{account: @agent, keyFile: "/" <> _ = new_key}}
    assert new_key != key_file
    refute File.read!(key_file) == "old"
  end

  test "a principal's handle the PDS can't resolve is looked up at the AppView" do
    base = fakes()
    appview = AtMcp.Network.appview_url() |> String.trim_trailing("/xrpc")

    get_json = fn
      ^appview <> "/xrpc/com.atproto.identity.resolveHandle?handle=far.elsewhere" ->
        {:ok, %{"did" => @principal}}

      url ->
        base.get_json.(url)
    end

    assert {:ok, %{principal: @principal}} =
             AtMcp.Pairing.setup(
               %{
                 principal: "far.elsewhere",
                 name: "scout",
                 handle: nil,
                 service: @service,
                 key_file: Path.join(AtMcp.Spaces.keys_dir(), "k3.json"),
                 scope: "atproto",
                 web_origin: "https://web.example"
               },
               %{base | get_json: get_json}
             )
  end

  test "setup takes the name as --name too, as the storybook shows it", %{path: path} do
    assert {:ok, %{account: %{"id" => "wren", "handle" => "wren.example"}}} =
             AtMcp.AccountSetup.execute(
               [
                 "--file",
                 path,
                 "setup",
                 "--principal",
                 @principal,
                 "--name",
                 "wren",
                 "--service",
                 @service
               ],
               pairing: fakes()
             )
  end

  test "a 429 from the PDS backs off, 60 s doubling to 5 minutes, then polling goes on every 20 s" do
    test = self()
    deps = fakes(limited: 4, known_after: 5)

    deps = %{
      deps
      | sleep: fn ms ->
          send(test, {:slept, ms})
          deps.sleep.(ms)
        end
    }

    assert {:ok, %{did: @agent}} =
             AtMcp.Pairing.repair(
               %{
                 did: @agent,
                 principal: @principal,
                 service: @service,
                 key_file: Path.join(AtMcp.Spaces.keys_dir(), "k4.json"),
                 scope: "atproto",
                 web_origin: "https://web.example"
               },
               deps
             )

    msgs = drain()
    sleeps = for {:slept, ms} <- msgs, do: ms
    assert sleeps == [60_000, 120_000, 240_000, 300_000, 20_000]
    assert Enum.any?(msgs, &match?({:said, "Delvetown is limiting sign-ins" <> _}, &1))
  end

  defp drain(acc \\ []) do
    receive do
      msg -> drain([msg | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
