defmodule AtMcp.WriteQuotaTest do
  use ExUnit.Case, async: false

  setup do
    dir = Path.join(System.tmp_dir!(), "at_mcp-quota-#{System.unique_integer([:positive])}")
    {:ok, clock} = Agent.start_link(fn -> 100 end)
    on_exit(fn -> File.rm_rf!(dir) end)

    opts = [
      name: nil,
      state_dir: dir,
      limit: 2,
      window_seconds: 10,
      clock: fn -> Agent.get(clock, & &1) end
    ]

    {:ok, quota} = AtMcp.WriteQuota.start_link(opts)
    {:ok, dir: dir, clock: clock, opts: opts, quota: quota}
  end

  test "independent clients of one DID share a durable window", %{
    quota: quota,
    opts: opts,
    clock: clock
  } do
    clients =
      for _ <- 1..2 do
        {:ok, effects} =
          AtMcp.Test.QuotaFixture.start_effects(
            backend: AtMcp.Test.MockBackend,
            backend_state: %{did: "did:plc:shared"},
            write_quota: quota
          )

        effects
      end

    results =
      1..12
      |> Task.async_stream(fn n -> AtMcp.Effects.post(Enum.at(clients, rem(n, 2)), "mock") end,
        max_concurrency: 12
      )
      |> Enum.to_list()

    assert Enum.count(results, &match?({:ok, {:ok, _}}, &1)) == 2
    assert Enum.count(results, &match?({:ok, {:error, {:write_quota_exhausted, 110}}}, &1)) == 10
    for effects <- clients, do: Agent.stop(effects)
    GenServer.stop(quota)
    {:ok, reopened} = AtMcp.WriteQuota.start_link(opts)

    assert {:error, {:write_quota_exhausted, 110}} =
             AtMcp.WriteQuota.reserve(reopened, "did:plc:shared")

    assert :ok = AtMcp.WriteQuota.reserve(reopened, "did:plc:other")
    Agent.update(clock, fn _ -> 99 end)

    assert {:error, {:write_quota_exhausted, 110}} =
             AtMcp.WriteQuota.reserve(reopened, "did:plc:shared")

    Agent.update(clock, fn _ -> 110 end)
    assert :ok = AtMcp.WriteQuota.reserve(reopened, "did:plc:shared")
    assert %{used: 1, resets_at_unix: 120} = AtMcp.WriteQuota.status(reopened, "did:plc:shared")
    GenServer.stop(reopened)
  end

  test "unavailable quota fails before reserving an Effects write", %{quota: quota} do
    {:ok, effects} =
      AtMcp.Test.QuotaFixture.start_effects(
        backend: AtMcp.Test.MockBackend,
        backend_state: %{did: "did:plc:closed"},
        write_quota: quota
      )

    GenServer.stop(quota)
    assert {:error, :write_quota_unavailable} = AtMcp.Effects.post(effects, "must not write")
    assert {:error, :write_quota_unavailable} = AtMcp.Effects.quota_status(effects)
    assert {:error, :write_quota_unavailable} = AtMcp.MCP.Tools.identity_status(effects)
  end

  defmodule RefusingBackend do
    # References are read before the write quota is charged; nothing here
    # refers to another record.
    def prepare_post(session, _text, opts), do: resolve_references(session, opts)

    def resolve_references(_state, opts), do: {:ok, opts}

    def post(_session, _text, _opts \\ []), do: {:error, :remote_refused}
  end

  test "remote failure counts against the write quota", %{quota: quota} do
    {:ok, effects} =
      AtMcp.Test.QuotaFixture.start_effects(
        backend: RefusingBackend,
        backend_state: %{did: "did:plc:refused"},
        write_quota: quota
      )

    assert {:error, {:write_outcome_unknown, :remote_refused}} =
             AtMcp.Effects.post(effects, "attempted")

    assert %{used: 1} = AtMcp.WriteQuota.status(quota, "did:plc:refused")
    GenServer.stop(quota)
  end

  test "an abrupt VM exit retains committed reservations", %{quota: quota, dir: dir, opts: opts} do
    GenServer.stop(quota)
    paths = for app <- [:at_mcp, :jason], do: Application.app_dir(app, "ebin")

    code =
      "{:ok, q} = AtMcp.WriteQuota.start_link(name: nil, state_dir: #{inspect(dir)}, limit: 2, window_seconds: 10, clock: fn -> 100 end); :ok = AtMcp.WriteQuota.reserve(q, \"did:plc:crash\"); :ok = AtMcp.WriteQuota.reserve(q, \"did:plc:crash\"); System.halt(0)"

    args = Enum.flat_map(paths, &["-pa", &1]) ++ ["-e", code]
    {output, result} = System.cmd(System.find_executable("elixir"), args, stderr_to_stdout: true)
    assert result == 0, output
    {:ok, reopened} = AtMcp.WriteQuota.start_link(opts)

    assert {:error, {:write_quota_exhausted, 110}} =
             AtMcp.WriteQuota.reserve(reopened, "did:plc:crash")

    GenServer.stop(reopened)
  end

  test "damaged quota state never resets an account's write quota", %{
    quota: quota,
    dir: dir,
    opts: opts
  } do
    GenServer.stop(quota)
    File.write!(Path.join(dir, "write-quota.json"), "broken")
    # init reads fail closed, rather than replacing lost counts with an empty map.
    assert_raise Jason.DecodeError, fn -> AtMcp.WriteQuota.init(opts) end
  end
end
