defmodule AtMcp.SessionOwnershipTest do
  use ExUnit.Case, async: false

  defmodule Backend do
    def login(opts) do
      send(opts[:notify], :backend_login)
      Process.sleep(30)
      {:ok, %{did: "did:plc:single"}}
    end

    def get_profile(%{expired: true}, _), do: {:error, AtMcp.Effects.Failure.new(:auth_refused)}
    def get_profile(_, actor), do: {:ok, %{actor: actor}}

    def refresh(session) do
      send(session.observer, :backend_refresh)
      Process.sleep(30)
      {:ok, %{session | expired: false}}
    end
  end

  test "concurrent eager and tool logins perform one actual backend login" do
    effects = start_supervised!({AtMcp.Effects, backend: Backend})
    parent = self()

    results =
      1..8
      |> Task.async_stream(fn _ -> AtMcp.Effects.login(effects, notify: parent) end,
        max_concurrency: 8
      )
      |> Enum.to_list()

    assert Enum.all?(results, &match?({:ok, {:ok, _}}, &1))
    assert_receive :backend_login
    refute_receive :backend_login
    assert AtMcp.Effects.login_count(effects) == 1
  end

  test "concurrent expired reads refresh once and retain the fresh session" do
    effects =
      start_supervised!(
        {AtMcp.Effects,
         backend: Backend,
         backend_state: %{did: "did:plc:single", expired: true, observer: self()}}
      )

    results =
      1..8
      |> Task.async_stream(fn _ -> AtMcp.Effects.get_profile(effects, "me") end,
        max_concurrency: 8
      )
      |> Enum.to_list()

    assert Enum.all?(results, &match?({:ok, {:ok, _}}, &1))
    assert_receive :backend_refresh
    refute_receive :backend_refresh
  end

  test "an unconfigured identity never inherits the default account's credentials" do
    AtMcp.Test.Settings.put(
      env_accounts: [default: [handle: "default.invalid", password: "default-private-password"]]
    )

    {:ok, _} =
      AtMcp.Identities.start_identity(id: "unconfigured", listen_enabled: false)

    on_exit(fn -> AtMcp.Identities.stop_identity("unconfigured") end)
    effects = AtMcp.Identity.effects_name("unconfigured")
    refute AtMcp.Effects.credentials?(effects)
    assert {:error, :not_connected} = AtMcp.Effects.login(effects)
    assert {:error, :not_connected} = AtMcp.Effects.post(effects, "must not act as default")
  end
end
