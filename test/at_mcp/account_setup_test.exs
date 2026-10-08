defmodule AtMcp.AccountSetupTest do
  use ExUnit.Case, async: false

  setup do
    dir = Path.join(System.tmp_dir!(), "at_mcp-setup-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    %{path: Path.join(dir, "accounts.json")}
  end

  test "three named accounts survive reload and produce credential-free attachments", %{
    path: path
  } do
    for name <- ["grug", "gregory", "reader"] do
      assert {:ok, %{account: account}} =
               AtMcp.AccountSetup.execute(
                 ["--file", path, "add", name, "--handle", name <> ".test"],
                 password: fn -> "private-password" end,
                 login: fn handle, "private-password", [service: "https://bsky.social"] ->
                   {:ok, %{did: "did:plc:" <> name, handle: handle}}
                 end
               )

      assert account["did"] == "did:plc:" <> name
      refute Map.has_key?(account, "password")
    end

    assert {:ok, %{accounts: accounts}} = AtMcp.AccountSetup.execute(["--file", path, "list"])
    refute Enum.any?(accounts, &Map.has_key?(&1, "mcp_port"))
    refute Jason.encode!(accounts) =~ "private-password"

    # The endpoint every identity is reached through, read off the bound
    # listener rather than from the code that generates descriptors.
    endpoint = "http://127.0.0.1:#{:ranch.get_port(:at_mcp_http)}/mcp"
    grants = AtMcp.Grants.path_for(path)

    assert {:ok, result} = AtMcp.AccountSetup.execute(["--file", path, "connection", "reader"])

    assert %{
             name: "at_mcp-reader",
             type: "http",
             url: ^endpoint,
             headers: [
               %{name: "authorization", value: "Bearer " <> reader_token},
               %{name: "x-kite-account-did", value: "did:plc:reader"}
             ]
           } = result.mcp

    # Same URL, different identity: what distinguishes the two attachments is
    # the credential, which is the whole point of there being one endpoint.
    assert {:ok, other} = AtMcp.AccountSetup.execute(["--file", path, "connection", "grug"])
    assert other.mcp.url == endpoint
    assert [%{name: "authorization", value: "Bearer " <> grug_token} | _] = other.mcp.headers

    assert AtMcp.Grants.resolve(reader_token, path: grants) == {:ok, "reader"}
    assert AtMcp.Grants.resolve(grug_token, path: grants) == {:ok, "grug"}
    refute reader_token == grug_token

    # The token is in the descriptor and nowhere else: the file keeps a digest,
    # so a grants file somebody reads does not hand them a credential.
    refute File.read!(grants) =~ reader_token

    refute Jason.encode!(result) =~ "private-password"

    assert {:ok, stdio} =
             AtMcp.AccountSetup.execute(
               ["--file", path, "connection", "reader", "--transport", "stdio"],
               release_root: "/opt/at_mcp"
             )

    assert %{
             name: "at_mcp-reader",
             command: "/opt/at_mcp/bin/at_mcp-connect",
             args: ["--url", ^endpoint, "--did", "did:plc:reader"],
             env: %{"AT_MCP_GRANT" => stdio_token}
           } = stdio.mcp

    # Not in argv, where every process on the machine could read it.
    refute Enum.any?(stdio.mcp.args, &(&1 =~ stdio_token))
    assert AtMcp.Grants.resolve(stdio_token, path: grants) == {:ok, "reader"}

    refute Jason.encode!(stdio.mcp) =~ "private-password"
    refute Jason.encode!(stdio.mcp) =~ path
    assert Process.whereis(AtMcp.Accounts)
    # Setup changed only configuration, not the already-running runtime.
    refute "reader" in AtMcp.Identities.list_ids()
  end

  # A release unpacked as the README says, under AT_MCP/releases beside
  # AT_MCP/current, is named through `current`: an old release's directory is
  # deleted sooner or later, and a host configuration naming it would stop
  # working.
  test "a stdio descriptor names the installation's current release", %{path: path} do
    at_mcp = Path.join(Path.dirname(path), "at_mcp")
    release = Path.join(at_mcp, "releases/at_mcp-v0.1.0-aaaaaaa")
    File.mkdir_p!(release)
    File.ln_s!("releases/at_mcp-v0.1.0-aaaaaaa", Path.join(at_mcp, "current"))

    assert {:ok, _} =
             AtMcp.AccountSetup.execute(
               ["--file", path, "add", "reader", "--handle", "reader.test"],
               password: fn -> "private-password" end,
               login: fn handle, _, _ -> {:ok, %{did: "did:plc:reader", handle: handle}} end
             )

    connection = fn release ->
      {:ok, stdio} =
        AtMcp.AccountSetup.execute(
          ["--file", path, "connection", "reader", "--transport", "stdio"],
          release_root: release
        )

      stdio.mcp.command
    end

    assert connection.(release) == Path.join(at_mcp, "current/bin/at_mcp-connect")
    # Anywhere else, such as a build directory, the release's own path.
    assert connection.(Path.join(at_mcp, "loose")) ==
             Path.join(at_mcp, "loose/bin/at_mcp-connect")
  end

  test "failed login saves nothing and never exposes backend details", %{path: path} do
    assert {:error, :authentication_failed} =
             AtMcp.AccountSetup.execute(
               ["--file", path, "add", "alice", "--handle", "alice.test"],
               password: fn -> "private-password" end,
               login: fn _, _, _ -> {:error, %{password: "private-password"}} end
             )

    refute File.exists?(path)
  end

  test "duplicate name does not ask for another password or log in", %{path: path} do
    args = ["--file", path, "add", "alice", "--handle", "alice.test"]

    assert {:ok, _} =
             AtMcp.AccountSetup.execute(args,
               password: fn -> "private-password" end,
               login: fn _, _, _ -> {:ok, %{did: "did:plc:alice"}} end
             )

    before = File.read!(path)

    assert {:error, :duplicate_id} =
             AtMcp.AccountSetup.execute(args,
               password: fn -> flunk("must not request credentials") end
             )

    assert File.read!(path) == before
  end

  test "named configuration keeps its own authorization and supports three accounts",
       %{path: path} do
    AtMcp.Test.Settings.put(boot_from_env: true)

    for name <- ["alice", "bob", "carol"] do
      assert {:ok, _} =
               AtMcp.AccountConfig.add(path, %{
                 "id" => name,
                 "handle" => name <> ".test",
                 "did" => "did:plc:" <> name,
                 "password" => "private-password",
                 "service" => "https://pds.example"
               })
    end

    AtMcp.Test.Settings.put(accounts_file: path)
    specs = AtMcp.Identities.env_identity_specs()
    assert Enum.map(specs, & &1[:id]) == ["alice", "bob", "carol"]
    assert Enum.all?(specs, &(&1[:expected_did] == "did:plc:" <> &1[:id]))
    refute Enum.any?(specs, &Keyword.has_key?(&1, :host_token))

    # A file that does not exist yet is an installation still being set up. A
    # file that disappeared under a running service is a different thing, and
    # reload still refuses it rather than reading it as no accounts.
    AtMcp.Test.Settings.put(accounts_file: path <> ".missing")
    assert AtMcp.Identities.env_identity_specs() == []
    assert {:error, :config_missing} = AtMcp.Identities.named_identity_specs(path <> ".missing")

    Application.put_env(:at_mcp, :boot_from_env, false)
    assert AtMcp.Identities.env_identity_specs() == []
  end

  @tag :tmp_dir
  test "an installation configured by account variables migrates itself into the accounts file",
       %{
         tmp_dir: dir
       } do
    path = Path.join(dir, "accounts.json")

    AtMcp.Test.Settings.put(
      env_accounts: [
        default: [
          service: "https://pds.example",
          handle: "grug.test",
          password: "app-password"
        ],
        second: [handle: "second.test", password: "app-password-2"]
      ]
    )

    login = fn handle, _password, _opts -> {:ok, %{did: "did:plc:" <> handle, handle: handle}} end
    assert :ok = AtMcp.AccountSetup.bootstrap_from_env(path, login: login)
    assert {:ok, accounts} = AtMcp.AccountConfig.load(path)

    # The ids are the ones that installation already had, so `default` still
    # names the same account. The port is the installation's one endpoint now,
    # not an account's, so it is not migrated onto either of them.
    assert Enum.map(accounts, & &1["id"]) == ["default", "second"]
    refute Enum.any?(accounts, &Map.has_key?(&1, "mcp_port"))
    assert Enum.map(accounts, & &1["did"]) == ["did:plc:grug.test", "did:plc:second.test"]
    assert Enum.map(accounts, & &1["service"]) == ["https://pds.example", "https://bsky.social"]

    # It happens once. With a file present the environment is never read again,
    # so which accounts exist cannot change underneath an installation.
    AtMcp.Test.Settings.put(env_accounts: [default: [handle: "someone.else", password: "x"]])

    assert :ok =
             AtMcp.AccountSetup.bootstrap_from_env(path,
               login: fn _, _, _ -> flunk("an existing file must not be migrated over") end
             )

    assert {:ok, ^accounts} = AtMcp.AccountConfig.load(path)
  end

  @tag :tmp_dir
  test "a migration that cannot log in leaves no half-written configuration", %{tmp_dir: dir} do
    path = Path.join(dir, "accounts.json")

    AtMcp.Test.Settings.put(
      env_accounts: [default: [handle: "grug.test", password: "wrong-password"]]
    )

    assert {:error, :authentication_failed} =
             AtMcp.AccountSetup.bootstrap_from_env(path, login: fn _, _, _ -> {:error, :nope} end)

    refute File.exists?(path)
  end
end
