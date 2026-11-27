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

    helper = fn
      "key.generate", %{keyFile: file} ->
        File.mkdir_p!(Path.dirname(file))
        File.write!(file, ~s({"kty":"EC"}))
        File.chmod!(file, 0o600)
        {:ok, %{"didKey" => "did:key:zDnaeNew", "jkt" => "jkt"}}

      "key.prove", params ->
        n = System.unique_integer([:positive])
        send(test, {:proved, params})
        {:ok, %{"proof" => "proof-#{n}"}}

      "oauth.login", params ->
        send(test, {:login, params})
        n = Agent.get_and_update(tries, &{&1 + 1, &1 + 1})

        if n > known_after,
          do: {:ok, %{"did" => @agent}},
          else: {:error, Failure.new(:refused, detail: login_error, message: "refused")}

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
    deps = fakes(known_after: 100)

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

    # 100 refusals at 5 s each is 500 s: links at 0, 240 and 480 s.
    proofs = for {:proved, p} <- drain(), do: p
    assert length(proofs) == 3
  end

  test "setup gives up after the wait, saves nothing and leaves no key", %{path: path} do
    assert {:error, :pairing_timeout} =
             AtMcp.AccountSetup.execute(
               [
                 "--file",
                 path,
                 "setup",
                 "scout",
                 "--principal",
                 @principal,
                 "--service",
                 @service,
                 "--wait-minutes",
                 "1"
               ],
               pairing: fakes(known_after: 1_000)
             )

    assert {:ok, []} = AtMcp.AccountConfig.load(path)
    assert Path.wildcard(Path.join(AtMcp.Spaces.keys_dir(), "login-pending-*")) == []
  end

  test "a preview that names an account stops setup at once" do
    assert {:error, %Failure{detail: "preview_mismatch"}} =
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

  defp drain(acc \\ []) do
    receive do
      msg -> drain([msg | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
