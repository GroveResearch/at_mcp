defmodule AtMcp.AccountEditTest do
  use ExUnit.Case, async: true
  alias AtMcp.{AccountConfig, AccountSetup}
  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    path = Path.join(dir, "accounts.json")

    account = %{
      "id" => "owner",
      "did" => "did:plc:owner",
      "handle" => "old.test",
      "password" => "old-secret",
      "service" => "https://old.example"
    }

    {:ok, _} = AccountConfig.add(path, account)
    %{path: path, account: account}
  end

  test "credential update verifies the saved DID and redacts output", %{
    path: path
  } do
    assert {:ok, result} =
             AccountSetup.execute(["--file", path, "update", "owner"],
               password: fn -> "new-secret" end,
               login: fn "old.test", "new-secret", [service: "https://old.example"] ->
                 {:ok, %{did: "did:plc:owner", handle: "renamed.test"}}
               end
             )

    assert {:ok, [saved]} = AccountConfig.load(path)
    assert saved["password"] == "new-secret"
    assert saved["handle"] == "renamed.test"
    assert result.next =~ "running service is unchanged"
    refute Jason.encode!(result) =~ "secret"
    assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
  end

  test "wrong identity and failed authentication leave bytes unchanged", %{
    path: path,
    account: account
  } do
    {:ok, _} =
      AccountConfig.add(path, %{account | "id" => "other", "did" => "did:plc:other"})

    before = File.read!(path)

    for {login, expected} <- [
          {fn _, _, _ -> {:ok, %{did: "did:plc:impostor"}} end, :account_identity_changed},
          {fn _, _, _ -> {:error, %{password: "new-secret"}} end, :authentication_failed}
        ] do
      assert {:error, ^expected} =
               AccountSetup.execute(["--file", path, "update", "owner"],
                 password: fn -> "new-secret" end,
                 login: login
               )

      assert File.read!(path) == before
    end
  end

  test "explicit PDS changes retain account identity", %{path: path} do
    assert {:ok, _} =
             AccountSetup.execute(
               ["--file", path, "update", "owner", "--service", "https://new.example"],
               password: fn -> "new-secret" end,
               login: fn _, _, [service: "https://new.example"] ->
                 {:ok, %{did: "did:plc:owner"}}
               end
             )

    assert {:ok, [saved]} = AccountConfig.load(path)
    assert saved["service"] == "https://new.example"
  end

  # A grant names an account. One left behind for a removed account is a
  # credential that starts working again the moment the name is reused.
  test "removing an account revokes the grants that name it", %{path: path} do
    grants = AtMcp.Grants.path_for(path)
    {:ok, kept} = AtMcp.Grants.issue("other", scope: :read, path: grants)
    {:ok, _} = AtMcp.Grants.issue("owner", scope: :manage, path: grants)
    {:ok, _} = AtMcp.Grants.issue("owner", scope: :read, path: grants)

    assert {:ok, %{grants_revoked: 2}} = AccountSetup.execute(["--file", path, "remove", "owner"])

    assert {:ok, remaining} = AtMcp.Grants.list(path: grants)
    assert Enum.map(remaining, & &1.account) == ["other"]
    assert Enum.map(remaining, & &1.id) == [kept.id]
  end

  # `--file` names a configuration that is not the running installation's, so
  # the grant it issues must not land in the running installation's file.
  test "a grant follows the accounts file it was issued against", %{path: path} do
    assert {:ok, result} = AccountSetup.execute(["--file", path, "connection", "owner"])
    assert [%{name: "authorization", value: "Bearer " <> token} | _] = result.mcp.headers

    assert {:ok, [grant]} = AtMcp.Grants.list(path: AtMcp.Grants.path_for(path))
    assert grant.account == "owner"
    refute File.exists?(AtMcp.Grants.path())
    assert AtMcp.Grants.resolve(token) == {:error, :unknown_grant}
  end

  test "remove deletes only selected config and never claims runtime or PDS revocation", %{
    path: path,
    account: account
  } do
    {:ok, _} =
      AccountConfig.add(path, %{account | "id" => "other", "did" => "did:plc:other"})

    assert {:ok, result} = AccountSetup.execute(["--file", path, "remove", "owner"])
    assert result.removed
    assert result.next =~ "running service is unchanged"
    assert result.next =~ "does not revoke"
    refute Jason.encode!(result) =~ "old-secret"
    assert {:ok, [%{"id" => "other"}]} = AccountConfig.load(path)
    before = File.read!(path)
    assert {:error, :not_found} = AccountSetup.execute(["--file", path, "remove", "owner"])
    assert File.read!(path) == before
  end

  test "low-level replacement cannot rename or rebind a saved account", %{
    path: path,
    account: account
  } do
    before = File.read!(path)

    for replacement <- [%{account | "did" => "did:plc:other"}, %{account | "id" => "other"}] do
      assert {:error, :account_identity_changed} =
               AccountConfig.update(path, "owner", replacement)

      assert File.read!(path) == before
    end

    assert {:error, :not_found} = AccountConfig.update(path, "missing", account)
  end

  test "update and remove retain private-file and contention checks", %{
    path: path,
    account: account
  } do
    {:ok, lock} = AtMcp.NativeLock.flock(path <> ".lock", wait: false, monitor_owner: false)

    try do
      assert {:error, :config_busy} = AccountConfig.update(path, "owner", account)
      assert {:error, :config_busy} = AccountConfig.remove(path, "owner")
    after
      AtMcp.NativeLock.unflock(lock)
    end

    File.chmod!(path, 0o644)
    assert {:error, :config_insecure} = AccountConfig.update(path, "owner", account)
    assert {:error, :config_insecure} = AccountConfig.remove(path, "owner")
  end
end
