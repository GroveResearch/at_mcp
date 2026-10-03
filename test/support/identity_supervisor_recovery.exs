# Fresh BEAM: no live service, credential, listener or model calls.
[dir] = System.argv()
Application.load(:at_mcp)
Application.put_env(:at_mcp, :inbound_state_dir, dir)
Application.put_env(:at_mcp, :start_mcp, false)
Application.put_env(:at_mcp, :jetstream_enabled, false)
Application.put_env(:at_mcp, :notifications_enabled, false)
{:ok, _} = Application.ensure_all_started(:at_mcp)

defmodule RecoveryLogin do
  def login(_credentials) do
    {failed?, count} =
      Agent.get_and_update(__MODULE__, fn {failed?, n} -> {{failed?, n}, {failed?, n + 1}} end)

    if failed?,
      do: {:error, :temporary_login_outage},
      else: {:ok, %{did: "did:plc:retry", mock: true, login: count}}
  end
end

defmodule RecoveryCheck do
  def eventually(fun, n \\ 500)
  def eventually(_fun, 0), do: raise("recovery timed out")

  def eventually(fun, n) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(10)
          eventually(fun, n - 1)
        )
  end
end

alias AtMcp.{Accounts, Identities, Identity}
alias AtMcp.Inbound.Store
parent = self()

opts = fn id, did ->
  [
    id: id,
    listen_enabled: false,
    backend: AtMcp.Test.MockBackend,
    backend_state: %{did: did, mock: true}
  ]
end

{:ok, _} = Identities.start_identity(opts.("dynamic", "did:plc:dynamic"))
{:ok, disconnected_pid} = Identities.start_identity(opts.("disconnected", "did:plc:disconnected"))
{:ok, _} = Identities.start_identity(opts.("disconnected-alias", "did:plc:disconnected"))
:ok = Accounts.disconnect("disconnected")
{:ok, _} = Agent.start_link(fn -> {false, 0} end, name: RecoveryLogin)

{:ok, _} =
  Identities.start_identity(
    id: "retry",
    listen_enabled: false,
    backend: RecoveryLogin,
    handle: "fixture",
    password: "fixture"
  )

# A child init may be waiting on Store while its supervisor is busy. Store's
# owner reset must not synchronously enumerate that supervisor in return.
:ok = :sys.suspend(Identities)

try do
  reset = Task.async(fn -> Store.account(:reset_runtime) end)
  :ok = Task.await(reset, 500)
after
  :ok = :sys.resume(Identities)
end

owner = Process.whereis(Accounts)
old = Process.whereis(Identities)
Process.exit(old, :kill)

:ok =
  RecoveryCheck.eventually(fn ->
    Process.whereis(Identities) not in [nil, old] and
      Store.ready("dynamic") == :ok
  end)

true = Process.whereis(Accounts) == owner
nil = Identity.whereis("disconnected")
nil = Identity.whereis("disconnected-alias")
:ok = Store.ready("dynamic")

# A single permanently restarted Identity must also revalidate its generation.
{:ok, _} = Identities.start_identity(opts.("stopped", "did:plc:stopped"))
:ok = Identities.stop_identity("stopped")
previous_identity = Identity.whereis("dynamic")
:ok = :sys.suspend(Accounts)

try do
  Process.exit(previous_identity, :kill)

  :ok =
    RecoveryCheck.eventually(fn ->
      Identity.whereis("dynamic") not in [nil, previous_identity]
    end)

  {:error, :stale_identity_runtime} =
    Store.account({:enable, ["dynamic"], [{"dynamic", previous_identity}]})

  {:error, :account_disconnected} = Store.ready("dynamic")

  {:error, :stale_identity_runtime} =
    Store.account(
      {:enable, ["disconnected", "disconnected-alias"], [{"disconnected", disconnected_pid}]}
    )

  true = Store.accounts()["disconnected"].disabled
after
  :ok = :sys.resume(Accounts)
end

:ok = RecoveryCheck.eventually(fn -> Store.ready("dynamic") == :ok end)

nil = Identity.whereis("stopped")

# A prolonged outage must fail closed, then retry an authentication failure.
:ok = Supervisor.terminate_child(AtMcp.Supervisor, Identities)
{:error, :account_disconnected} = Store.ready("dynamic")
Agent.update(RecoveryLogin, fn {_, n} -> {true, n} end)

AtMcp.Deliver.set_callback("did:plc:retry", fn _ ->
  send(parent, :retry_delivered)
  :ok
end)

AtMcp.Deliver.set_callback("did:plc:disconnected", fn _ ->
  send(parent, :disconnected_delivered)
  :ok
end)

{:ok, [_]} = Store.accept([%{matched_did: "did:plc:retry", uri: "at://retry/post/1"}])

{:ok, [_]} =
  Store.accept([%{matched_did: "did:plc:disconnected", uri: "at://disconnected/post/1"}])

receive do
  :retry_delivered -> raise("delivery escaped supervisor outage")
after
  150 -> :ok
end

{true, before} = Agent.get(RecoveryLogin, & &1)
{:ok, _} = Supervisor.restart_child(AtMcp.Supervisor, Identities)
:ok = RecoveryCheck.eventually(fn -> elem(Agent.get(RecoveryLogin, & &1), 1) > before end)
{:error, :account_disconnected} = Store.ready("retry")

receive do
  :retry_delivered -> raise("delivery escaped failed authentication")
after
  200 -> :ok
end

{true, attempts} = Agent.get(RecoveryLogin, & &1)
# Backoff must not busy-loop credentials while unavailable.
true = attempts == before + 1
Agent.update(RecoveryLogin, fn {_, n} -> {false, n} end)
:ok = RecoveryCheck.eventually(fn -> Store.ready("retry") == :ok end)

receive do
  :retry_delivered -> :ok
after
  2_000 -> raise("retained delivery did not resume")
end

receive do
  :retry_delivered -> raise("duplicate delivery")
after
  100 -> :ok
end

receive do
  :disconnected_delivered -> raise("disabled alias resumed")
after
  100 -> :ok
end

%{pending: 1} = Store.status()
true = Store.accounts()["disconnected"].disabled
true = Store.accounts()["disconnected-alias"].disabled
true = Process.whereis(Accounts) == owner
# Owner death before bind/enable must not promote a merely registered child.
:ok = Store.account({:register, "partial"})
:ok = Store.account({:starting, "partial", true})

{:ok, _} =
  Identities.start_identity_runtime(id: "partial", listen_enabled: false)

{:error, :account_disconnected} = Store.ready("partial")
:ok = Supervisor.terminate_child(AtMcp.Supervisor, Accounts)
{:ok, _} = Supervisor.restart_child(AtMcp.Supervisor, Accounts)
{:ok, rows} = Accounts.status()
:ok = RecoveryCheck.eventually(fn -> is_nil(Identity.whereis("partial")) end)
{:error, :account_disconnected} = Store.ready("partial")
true = Enum.any?(rows, &(&1.id == "partial" and not &1.configured))
:ok = Store.ready("dynamic")
# Store recovery must revalidate dynamic live sessions even after configs were lost.
old_store = Process.whereis(Store)
Process.exit(old_store, :kill)

:ok =
  RecoveryCheck.eventually(fn ->
    Process.whereis(Store) not in [nil, old_store] and Store.ready("dynamic") == :ok
  end)

{:error, :account_disconnected} = Store.ready("disconnected")
%{pending: 1} = Store.status()
IO.puts("identity-supervisor-recovery-passed")
Application.stop(:at_mcp)
