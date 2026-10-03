defmodule AtMcp.SharedHTTPQuotaTest do
  use ExUnit.Case, async: false
  @moduletag :tmp_dir

  test "ordinary HTTP clients share the default quota across account and quota restarts" do
    id = "shared-http-#{System.unique_integer([:positive])}"
    did = "did:plc:#{id}"
    {:ok, _} = AtMcp.Identities.start_identity(identity(id, did))
    on_exit(fn -> AtMcp.Identities.stop_identity(id) end)
    first = connect(id)
    second = connect(id)
    quota = status(first)["write_quota"]
    assert quota["used"] == 0
    assert quota["limit"] == 16

    results =
      1..20
      |> Task.async_stream(
        fn n ->
          call(if(rem(n, 2) == 0, do: first, else: second), "post", %{"text" => "fixture"})
        end,
        max_concurrency: 8
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &(not &1.error)) == 16
    assert Enum.count(results, &(&1.error and &1.text =~ "quota exhausted; resets at")) == 4
    assert status(first)["write_quota"]["used"] == 16
    assert status(second)["write_quota"]["used"] == 16
    :ok = AtMcp.Accounts.disconnect(id)
    {:ok, _} = AtMcp.Accounts.reconnect(id)
    reconnected = connect(id)
    assert status(reconnected)["write_quota"]["used"] == 16
    assert call(reconnected, "post", %{"text" => "still exhausted"}).error

    # A real supervised quota-process restart reloads the same durable ledger.
    :ok = Supervisor.terminate_child(AtMcp.Supervisor, AtMcp.WriteQuota)
    {:ok, _} = Supervisor.restart_child(AtMcp.Supervisor, AtMcp.WriteQuota)
    assert status(reconnected)["write_quota"]["used"] == 16
    assert call(reconnected, "post", %{"text" => "still exhausted after reload"}).error
  end

  test "explicit quota configuration renews an HTTP account without operator resets", %{
    tmp_dir: dir
  } do
    clock = start_supervised!({Agent, fn -> 100 end})

    quota =
      start_supervised!(
        {AtMcp.WriteQuota,
         name: nil,
         state_dir: dir,
         limit: 1,
         window_seconds: 10,
         clock: fn -> Agent.get(clock, & &1) end}
      )

    id = "renew-http-#{System.unique_integer([:positive])}"
    opts = identity(id, "did:plc:#{id}")
    {:ok, _} = AtMcp.Identities.start_identity(Keyword.put(opts, :write_quota, quota))
    on_exit(fn -> AtMcp.Identities.stop_identity(id) end)
    client = connect(id)
    refute call(client, "post", %{"text" => "first window"}).error
    result = call(client, "post", %{"text" => "exhausted"})
    assert result.error
    assert result.text =~ "1970-01-01T00:01:50Z"
    Agent.update(clock, fn _ -> 110 end)
    refute call(client, "post", %{"text" => "next window"}).error

    assert status(client)["write_quota"] == %{
             "used" => 1,
             "limit" => 1,
             "window_seconds" => 10,
             "resets_at" => "1970-01-01T00:02:00Z"
           }
  end

  test "obsolete host environment cannot change account quota ownership" do
    previous = System.get_env("AT_MCP_HOST_TOKEN")
    previous_file = System.get_env("AT_MCP_HOST_TOKEN_FILE")
    System.delete_env("AT_MCP_HOST_TOKEN_FILE")
    System.put_env("AT_MCP_HOST_TOKEN", String.duplicate("h", 40))

    on_exit(fn ->
      if previous,
        do: System.put_env("AT_MCP_HOST_TOKEN", previous),
        else: System.delete_env("AT_MCP_HOST_TOKEN")

      if previous_file,
        do: System.put_env("AT_MCP_HOST_TOKEN_FILE", previous_file),
        else: System.delete_env("AT_MCP_HOST_TOKEN_FILE")
    end)

    id = "managed-default-#{System.unique_integer([:positive])}"

    {:ok, _} =
      AtMcp.Identities.start_identity(
        id: id,
        listen_enabled: false,
        backend: AtMcp.Test.MockBackend,
        backend_state: %{did: "did:plc:#{id}"}
      )

    on_exit(fn -> AtMcp.Identities.stop_identity(id) end)
    effects = AtMcp.Identity.effects_name(id)
    assert %{used: 0, limit: 16} = AtMcp.Effects.quota_status(effects)
    assert {:ok, _} = AtMcp.Effects.post(effects, "uses account quota")
    assert %{used: 1} = AtMcp.Effects.quota_status(effects)
  end

  defp identity(id, did) do
    [
      id: id,
      listen_enabled: false,
      backend: AtMcp.Test.MockBackend,
      backend_state: %{did: did}
    ]
  end

  # Each connection holds its own grant for the same account. One account, one
  # write quota: what is shared is the account's quota, not the credential.
  defp connect(id) do
    {client, _token} = AtMcp.Test.Grant.client(id)
    client
  end

  defp status(client), do: call(client, "identity_status", %{}).text |> Jason.decode!()

  defp call(client, name, arguments) do
    assert {:ok, result} = ExMCP.Client.call_tool(client, name, arguments, format: :map)
    content = Map.get(result, "content") || Map.fetch!(result, :content)

    %{
      error: Map.get(result, "isError") || Map.get(result, :isError) || false,
      text:
        Enum.map_join(content, fn item -> Map.get(item, "text") || Map.fetch!(item, :text) end)
    }
  end
end
