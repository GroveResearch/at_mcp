defmodule AtMcp.AccountsReloadTest do
  use ExUnit.Case, async: false
  alias AtMcp.{Accounts, AccountConfig, Identity, Identities}
  alias AtMcp.Inbound.Store

  defmodule PDS do
    use Plug.Router
    plug(Plug.Parsers, parsers: [:json], json_decoder: Jason)
    plug(:match)
    plug(:dispatch)

    post "/xrpc/com.atproto.server.createSession" do
      handle = conn.body_params["identifier"]

      if conn.body_params["password"] == "wait" do
        send(Process.whereis(AtMcp.AccountsReloadTest), {:pds_login, self(), handle})

        receive do
          :release_login -> :ok
        after
          5_000 -> :ok
        end
      end

      if conn.body_params["password"] == "bad" do
        send_resp(conn, 401, ~s({"error":"AuthenticationRequired"}))
      else
        body = %{
          did: "did:plc:" <> handle,
          handle: handle,
          accessJwt: "fixture",
          refreshJwt: "fixture"
        }

        conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(body))
      end
    end
  end

  setup do
    Process.register(self(), __MODULE__)
    root = Path.join(System.tmp_dir!(), "at_mcp-reload-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    file = Path.join(root, "accounts.json")
    ref = __MODULE__.HTTP
    start_supervised!({Plug.Cowboy, scheme: :http, plug: PDS, options: [port: 0, ref: ref]})
    service = "http://127.0.0.1:#{:ranch.get_port(ref)}"
    prefix = "reload#{System.unique_integer([:positive])}"

    rows =
      for suffix <- ["a", "b"], do: row(prefix <> suffix, service)

    Enum.each(rows, &AccountConfig.add(file, &1))
    # Registered first, so it runs after the setting is restored.
    on_exit(fn ->
      for suffix <- ~w(a b c), do: Identities.stop_identity(prefix <> suffix)
      restart_accounts!()
      File.rm_rf!(root)
    end)

    AtMcp.Test.Settings.put(accounts_file: file)
    restart_accounts!()

    assert {:ok, _} = Accounts.status()
    assert eventually(fn -> Enum.all?(rows, &(Store.ready(&1["id"]) == :ok)) end)
    %{config_file: file, rows: rows, prefix: prefix, service: service}
  end

  test "add and replace only affected owners, keep disconnected and removed accounts disconnected",
       %{
         config_file: file,
         rows: [a, b],
         prefix: prefix,
         service: service
       } do
    assert :ok = AtMcp.WriteQuota.reserve(a["did"])
    quota = AtMcp.WriteQuota.status(a["did"])
    a_pid = Identity.whereis(a["id"])
    b_pid = Identity.whereis(b["id"])
    assert is_pid(a_pid) and is_pid(b_pid)
    c = row(prefix <> "c", service)
    write(file, [a, b, c])
    assert {:ok, %{accounts: [%{id: id, status: "ready"}]}} = Accounts.reload()
    assert id == c["id"]
    assert Identity.whereis(a["id"]) == a_pid
    assert Identity.whereis(b["id"]) == b_pid
    changed_a = Map.put(a, "password", "replacement")
    write(file, [changed_a, b, c])
    assert {:ok, %{accounts: [%{status: "ready"}]}} = Accounts.reload()
    assert Identity.whereis(a["id"]) != a_pid
    assert Identity.whereis(b["id"]) == b_pid
    assert :ok = Accounts.disconnect(b["id"])
    changed_b = Map.put(b, "password", "replacement")
    write(file, [changed_a, changed_b, c])
    assert {:ok, %{accounts: [%{status: "disconnected"}]}} = Accounts.reload()
    refute Identity.whereis(b["id"])
    write(file, [changed_b, c])
    assert {:ok, %{removed: [removed]}} = Accounts.reload()
    assert removed == a["id"]
    refute Identity.whereis(removed)
    assert Store.accounts()[removed].disabled
    assert {:error, :configuration_required} = Accounts.reconnect(removed)
    write(file, [changed_a, changed_b, c])
    assert {:ok, %{accounts: [%{status: "disconnected"}]}} = Accounts.reload()
    refute Identity.whereis(removed)
    assert {:ok, _} = Accounts.reconnect(removed)
    assert Store.ready(removed) == :ok
    assert AtMcp.WriteQuota.status(a["did"]) == quota
    refute Identity.whereis(b["id"])
  end

  test "an invalid or missing whole file leaves every current owner untouched", %{
    config_file: file,
    rows: [a, b]
  } do
    owners = Enum.map([a, b], &Identity.whereis(&1["id"]))
    File.write!(file, "broken sentinel-secret")
    assert {:error, :config_corrupt} = Accounts.reload()
    assert Enum.map([a, b], &Identity.whereis(&1["id"])) == owners
    write(file, [Map.put(a, "did", "did:plc:different"), b])
    assert {:error, :account_identity_changed} = Accounts.reload()
    assert Enum.map([a, b], &Identity.whereis(&1["id"])) == owners
    write(file, [a, b])

    assert {:ok, %{unchanged: [_, _]}} = Accounts.reload()
    assert Enum.map([a, b], &Identity.whereis(&1["id"])) == owners

    File.rm!(file)
    assert {:error, :config_missing} = Accounts.reload()
    assert Enum.map([a, b], &Identity.whereis(&1["id"])) == owners
  end

  test "bad updated credentials leave old owner stopped and visibly unavailable", %{
    config_file: file,
    rows: [a, b]
  } do
    previous = Identity.whereis(a["id"])
    b_pid = Identity.whereis(b["id"])
    write(file, [Map.put(a, "password", "bad"), b])
    assert {:ok, %{accounts: [%{status: "unavailable"}]}} = Accounts.reload()
    refute Process.alive?(previous)
    refute Identity.whereis(a["id"])
    assert {:error, _} = Store.ready(a["id"])
    assert Identity.whereis(b["id"]) == b_pid
    assert {:ok, rows} = Accounts.status()
    assert Enum.find(rows, &(&1.id == a["id"])).configured
  end

  test "a live owner that cannot be stopped stays disconnected and is never reused", %{
    config_file: file,
    rows: [a, b]
  } do
    :ok = Identities.stop_identity(a["id"])

    {:ok, orphan} =
      Identity.start_link(
        id: a["id"],
        expected_did: a["did"],
        handle: a["handle"],
        password: a["password"],
        service: a["service"],
        listen_enabled: false
      )

    on_exit(fn -> if Process.alive?(orphan), do: Supervisor.stop(orphan) end)
    write(file, [Map.put(a, "password", "bad"), b])
    assert {:ok, %{accounts: [%{status: "unavailable"}], stop_failed: [id]}} = Accounts.reload()
    assert id == a["id"]
    assert Identity.whereis(id) == orphan
    assert {:error, _} = Store.ready(id)
    assert Store.accounts()[id].disabled
    assert {:ok, %{accounts: [%{status: "unavailable"}], stop_failed: [^id]}} = Accounts.reload()
    assert {:error, :account_runtime_unavailable} = Accounts.reconnect(id)
    assert Identity.whereis(id) == orphan
    assert {:error, _} = Store.ready(id)
    # Once the stale owner is actually gone, reconnect must try the saved bad
    # credentials, not recover the old session. Only a new good config can work.
    Supervisor.stop(orphan)
    assert {:error, _} = Accounts.reconnect(id)
    refute Identity.whereis(id)
    write(file, [Map.put(a, "password", "replacement"), b])
    assert {:ok, %{accounts: [%{status: "disconnected"}]}} = Accounts.reload()
    assert {:ok, fresh} = Accounts.reconnect(id)
    refute fresh == orphan
    assert Store.ready(id) == :ok
  end

  test "removing an account cancels an in-flight reload and late authentication cannot restore it",
       %{
         config_file: file,
         rows: [a, b]
       } do
    write(file, [Map.put(a, "password", "wait"), b])
    first_reload = Task.async(&Accounts.reload/0)
    assert_receive {:pds_login, pds, _}, 2_000

    write(file, [b])
    assert {:ok, %{removed: [removed]}} = Accounts.reload()
    assert removed == a["id"]
    send(pds, :release_login)
    assert {:error, :account_runtime_unavailable} = Task.await(first_reload)
    assert Store.accounts()[removed].disabled
    refute Identity.whereis(removed)
    assert {:error, :configuration_required} = Accounts.reconnect(removed)
    assert Store.ready(b["id"]) == :ok
  end

  test "start during a multi-account reload returns its identity PID, not the reload report", %{
    config_file: file,
    rows: [a, b]
  } do
    write(file, [Map.put(a, "password", "replacement"), Map.put(b, "password", "wait")])
    reload = Task.async(&Accounts.reload/0)
    assert_receive {:pds_login, pds, handle}, 2_000
    assert handle == b["handle"]
    assert :ok = Store.ready(a["id"])
    opts = :sys.get_state(Accounts).configs[a["id"]]
    start = Task.async(fn -> Identities.start_identity(opts) end)

    assert eventually(fn ->
             Enum.any?(:sys.get_state(Accounts).operations, fn {_, op} ->
               length(op.waiters) == 2
             end)
           end)

    send(pds, :release_login)
    assert {:ok, _} = Task.await(reload)
    assert {:ok, pid} = Task.await(start)
    assert is_pid(pid)
    assert pid == Identity.whereis(a["id"])
  end

  defp row(id, service),
    do: %{
      "id" => id,
      "handle" => id,
      "did" => "did:plc:" <> id,
      "password" => "fixture",
      "service" => service
    }

  defp write(file, accounts),
    do: File.write!(file, Jason.encode!(%{version: 1, accounts: accounts}))

  defp restart_accounts! do
    :ok = Supervisor.terminate_child(AtMcp.Supervisor, Accounts)
    {:ok, _} = Supervisor.restart_child(AtMcp.Supervisor, Accounts)
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(_, 0), do: false

  defp eventually(fun, attempts) do
    if fun.(),
      do: true,
      else:
        (
          Process.sleep(10)
          eventually(fun, attempts - 1)
        )
  end
end
