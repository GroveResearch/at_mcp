defmodule AtMcp.AccountConfigTest do
  use ExUnit.Case, async: true
  alias AtMcp.AccountConfig, as: Config
  import Bitwise

  setup do
    root = Path.join(System.tmp_dir!(), "at_mcp-config-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, path: Path.join([root, "private", "accounts.json"])}
  end

  defp account(n),
    do: %{
      "id" => "account-#{n}",
      "handle" => "account#{n}.test",
      "did" => "did:plc:account#{n}",
      "password" => "sentinel-secret",
      "service" => "https://pds.test"
    }

  test "first through third use same private persistence flow", %{path: path, root: root} do
    mode = File.stat!(root).mode
    assert Config.load(path) == {:ok, []}
    for n <- 1..3, do: assert(Config.add(path, account(n)) == {:ok, account(n)})
    assert Config.load(path) == {:ok, Enum.map(1..3, &account/1)}
    assert (File.stat!(path).mode &&& 0o777) == 0o600
    assert (File.stat!(Path.dirname(path)).mode &&& 0o777) == 0o700
    assert File.stat!(root).mode == mode
  end

  test "duplicates never overwrite", %{path: path} do
    assert {:ok, _} = Config.add(path, account(1))
    original = File.read!(path)

    for {field, error} <- [{"id", :duplicate_id}, {"did", :duplicate_did}] do
      assert {:error, ^error} = Config.add(path, Map.put(account(2), field, account(1)[field]))
      assert File.read!(path) == original
    end

    assert {:ok, _} = Config.add(path, account(2))
  end

  test "invalid input fails before creation; loopback PDS supported", %{path: path} do
    for {field, value} <- [
          {"id", "../bad"},
          {"did", "bad"},
          {"password", ""},
          {"service", "http://public.test"},
          {"service", "https://user:secret@pds.test"},
          {"backend", "Elixir.Unsafe"}
        ] do
      config = Map.put(account(1), field, value)
      assert Config.validate(config) == {:error, :invalid_account}
      assert Config.add(path, config) == {:error, :invalid_account}
    end

    refute File.exists?(path)

    for service <- ["http://localhost:8080", "http://127.0.0.1:8080", "http://[::1]:8080"],
        do: assert(Config.validate(Map.put(account(1), "service", service)) == :ok)
  end

  # An account carries no MCP port: one endpoint serves the installation. A file
  # that still holds the field on disk is read with the key dropped rather than
  # refused as corrupt, which would lose an operator their accounts; the next
  # write leaves it out.
  test "a file that still carries per-account ports loads without them", %{path: path} do
    File.mkdir_p!(Path.dirname(path))

    legacy = Map.put(account(1), "mcp_port", 4400)
    File.write!(path, Jason.encode!(%{version: 1, accounts: [legacy]}))
    File.chmod!(path, 0o600)

    assert Config.load(path) == {:ok, [account(1)]}

    assert {:ok, _} = Config.add(path, account(2))
    refute File.read!(path) =~ "mcp_port"

    # And a port is not quietly accepted on the way in: the config's key set is
    # closed, so a caller still passing one is told so rather than having it
    # dropped.
    assert Config.validate(legacy) == {:error, :invalid_account}
  end

  test "corrupt config preserved", %{path: path} do
    File.mkdir_p!(Path.dirname(path))

    for data <- [
          "sentinel-secret broken JSON",
          Jason.encode!(%{version: 2, accounts: []}),
          Jason.encode!(%{version: 1, accounts: [account(1), account(1)]}),
          Jason.encode!(%{version: 1, accounts: [%{"id" => "missing"}]})
        ] do
      File.write!(path, data)
      File.chmod!(path, 0o600)
      assert Config.load(path) == {:error, :config_corrupt}
      assert Config.add(path, account(2)) == {:error, :config_corrupt}
      assert File.read!(path) == data
    end
  end

  test "insecure files and symlinks rejected", %{path: path, root: root} do
    assert {:ok, _} = Config.add(path, account(1))
    original = File.read!(path)
    File.chmod!(path, 0o644)
    assert Config.load(path) == {:error, :config_insecure}
    assert Config.add(path, account(2)) == {:error, :config_insecure}
    File.chmod!(path, 0o600)
    link = Path.join(root, "link.json")
    File.ln_s!(path, link)
    assert Config.load(link) == {:error, :config_symlink}
    assert Config.add(link, account(2)) == {:error, :config_symlink}
    assert File.read!(path) == original
    assert File.lstat!(link).type == :symlink
  end

  test "busy lock preserves existing data", %{path: path} do
    assert {:ok, _} = Config.add(path, account(1))
    {:ok, lock} = AtMcp.NativeLock.flock(path <> ".lock", wait: false, monitor_owner: false)

    try do
      assert Config.add(path, account(2)) == {:error, :config_busy}
      assert Config.load(path) == {:ok, [account(1)]}
    after
      AtMcp.NativeLock.unflock(lock)
    end

    assert {:ok, _} = Config.add(path, account(2))
  end
end
