defmodule AtMcp.EffectsIdentityTest do
  use ExUnit.Case, async: true

  alias AtMcp.Effects

  defmodule Backend do
    def login(_opts), do: call(:login)
    def refresh(_session), do: call(:refresh)
    def get_profile(session, _actor), do: call({:read, session.did})
    # References are read before the write quota is charged; nothing here
    # refers to another record.
    def prepare_post(session, _text, opts), do: resolve_references(session, opts)

    def resolve_references(_state, opts), do: {:ok, opts}

    def post(session, _text, _opts \\ []), do: call({:write, session.did})

    defp call(operation) do
      Agent.get_and_update(fixture(), fn state ->
        key = if is_tuple(operation), do: elem(operation, 0), else: operation
        {Map.fetch!(state, key), Map.update!(state, :calls, &(&1 ++ [operation]))}
      end)
    end

    # Effects runs each call in a task of the account's owner, and the test
    # process started that owner, so the fixture is found on the test process:
    # the task's caller is the owner, and the owner's ancestor is the test.
    defp fixture do
      pids = [self() | Process.get(:"$callers", [])]

      Enum.find_value(
        pids ++ Enum.flat_map(pids, &ancestors/1),
        &dictionary(&1)[:identity_fixture]
      )
    end

    defp ancestors(pid), do: Enum.filter(dictionary(pid)[:"$ancestors"] || [], &is_pid/1)

    defp dictionary(pid) do
      case Process.info(pid, :dictionary) do
        {:dictionary, dictionary} -> dictionary
        nil -> []
      end
    end
  end

  setup do
    fixture =
      start_supervised!(
        {Agent,
         fn ->
           %{
             login: {:ok, %{did: "did:plc:other"}},
             refresh: {:ok, %{did: "did:plc:other"}},
             read: {:ok, %{}},
             write: {:ok, %{}},
             calls: []
           }
         end}
      )

    Process.put(:identity_fixture, fixture)
    %{fixture: fixture}
  end

  defp effects(opts \\ []) do
    {:ok, pid} =
      AtMcp.Test.QuotaFixture.start_effects(
        Keyword.merge(
          [
            backend: Backend,
            expected_did: "did:plc:owner",
            credential_mode: :explicit,
            handle: "owner.test",
            password: "fixture",
            write_quota: AtMcp.Test.QuotaFixture.quota(3)
          ],
          opts
        )
      )

    pid
  end

  defp rejected(pid) do
    refute Effects.logged_in?(pid)
    assert Effects.session_did(pid) == nil
    assert {:error, :account_identity_changed} = Effects.get_profile(pid, "owner.test")
    assert {:error, :account_identity_changed} = Effects.post(pid, "must not publish")
    assert Effects.expected_did(pid) == "did:plc:owner"
    assert AtMcp.Effects.quota_status(pid).limit == 3
  end

  test "login refuses a reassigned handle before any tool runs", %{fixture: fixture} do
    pid = effects()
    assert {:error, :account_identity_changed} = Effects.login(pid)
    rejected(pid)
    assert Agent.get(fixture, & &1.calls) == [:login]
    assert AtMcp.Effects.quota_status(pid).used == 0
  end

  test "explicit recovery accepts only the original DID without resetting policy", %{
    fixture: fixture
  } do
    Agent.update(fixture, &%{&1 | write: {:error, AtMcp.Effects.Failure.new(:auth_refused)}})
    pid = effects(backend_state: %{did: "did:plc:owner"})
    assert {:error, :account_identity_changed} = Effects.post(pid, "fixture")
    Agent.update(fixture, &%{&1 | login: {:ok, %{did: "did:plc:owner"}}, write: {:ok, %{}}})
    assert {:ok, _} = Effects.login(pid)
    assert Effects.session_did(pid) == "did:plc:owner"
    assert AtMcp.Effects.quota_status(pid).used == 1
    assert AtMcp.Effects.quota_status(pid).limit == 3
    assert {:ok, _} = Effects.post(pid, "fixture")
    assert AtMcp.Effects.quota_status(pid).used == 2
  end

  test "preloaded wrong or missing DID is never ready", %{fixture: fixture} do
    for session <- [%{did: "did:plc:other"}, %{}] do
      pid = effects(backend_state: session)
      rejected(pid)
    end

    assert Agent.get(fixture, & &1.calls) == []
  end

  test "cached session is checked again before the account is ready", %{fixture: fixture} do
    pid = effects(backend_state: %{did: "did:plc:owner"})
    :sys.replace_state(pid, &%{&1 | backend_state: %{did: "did:plc:other"}})
    assert {:error, :account_identity_changed} = Effects.login(pid)
    rejected(pid)
    assert Agent.get(fixture, & &1.calls) == []
  end

  test "refresh mismatch never retries a refused write on another account", %{fixture: fixture} do
    Agent.update(fixture, &%{&1 | write: {:error, AtMcp.Effects.Failure.new(:auth_refused)}})
    pid = effects(backend_state: %{did: "did:plc:owner"})
    assert {:error, :account_identity_changed} = Effects.post(pid, "fixture")
    rejected(pid)
    assert Agent.get(fixture, & &1.calls) == [{:write, "did:plc:owner"}, :refresh]
    quota = Effects.write_quota(pid)
    assert %{used: 1} = AtMcp.WriteQuota.status(quota, "did:plc:owner")
  end

  test "fallback login cannot change identity after an expired read", %{fixture: fixture} do
    Agent.update(
      fixture,
      &%{
        &1
        | read: {:error, AtMcp.Effects.Failure.new(:auth_refused)},
          refresh: {:error, AtMcp.Effects.Failure.new(:auth_refused)}
      }
    )

    pid = effects(backend_state: %{did: "did:plc:owner"})
    assert {:error, :account_identity_changed} = Effects.get_profile(pid, "owner.test")
    rejected(pid)
    assert Agent.get(fixture, & &1.calls) == [{:read, "did:plc:owner"}, :refresh, :login]
  end

  test "matching identity works and absent expected DID preserves compatibility", %{
    fixture: fixture
  } do
    pid = effects(backend_state: %{did: "did:plc:owner"})
    assert {:ok, _} = Effects.post(pid, "fixture")
    unbound = effects(expected_did: nil)
    assert {:ok, _} = Effects.login(unbound)
    assert {:ok, _} = Effects.post(unbound, "fixture")

    assert Agent.get(fixture, & &1.calls) == [
             {:write, "did:plc:owner"},
             :login,
             {:write, "did:plc:other"}
           ]
  end
end
