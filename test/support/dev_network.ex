defmodule AtMcp.Test.DevNetwork do
  @moduledoc """
  Upstream's reference AT Protocol network, running on localhost for the
  end-to-end suite (`test/e2e`).

  `start/0` runs `test/support/dev_network.mjs` under Node: `@atproto/dev-env`'s
  TestNetwork, which is a PLC directory, a PDS, an AppView, bsync and ozone,
  with two accounts (`self` and `other`) and a feed generator `other`
  publishes. It answers once the network is ready, with where everything is.
  `sync/1` waits until the AppView has indexed every write the PDS has
  sequenced, so a read after it sees the write without guessing at a delay.
  Stopping this process stops the network; so does this VM exiting, because
  the script stops when its stdin closes.

  It needs `AT_MCP_E2E_DEV_ENV` (a built atproto `packages/dev-env`),
  `DB_POSTGRES_URL` and `REDIS_HOST`; scripts/e2e.sh provides them.
  """
  use GenServer

  @script Path.expand("dev_network.mjs", __DIR__)
  @ready_timeout 180_000
  @sync_timeout 30_000

  @doc "Start the network; returns `{pid, info}` once it is ready."
  def start do
    for name <- ~w(AT_MCP_E2E_DEV_ENV DB_POSTGRES_URL REDIS_HOST),
        System.get_env(name) in [nil, ""] do
      raise "the end-to-end suite needs #{name}; run it with scripts/e2e.sh"
    end

    pid = ExUnit.Callbacks.start_supervised!({__MODULE__, []}, id: __MODULE__)
    {pid, GenServer.call(pid, :info, @ready_timeout)}
  end

  @doc "Wait until the AppView has indexed everything the PDS has sequenced."
  def sync(pid), do: GenServer.call(pid, :sync, @sync_timeout + 1_000)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(_opts) do
    node = System.find_executable("node") || raise "node is not on PATH"

    port =
      Port.open({:spawn_executable, node}, [
        :binary,
        :exit_status,
        {:line, 1_000_000},
        args: [@script]
      ])

    Process.flag(:trap_exit, true)
    {:ok, %{port: port, info: nil, waiting: [], buffer: ""}}
  end

  @impl true
  def handle_call(:info, _from, %{info: info} = state) when info != nil,
    do: {:reply, info, state}

  def handle_call(:info, from, state),
    do: {:noreply, %{state | waiting: state.waiting ++ [{:info, from}]}}

  def handle_call(:sync, from, state) do
    Port.command(state.port, "sync\n")
    {:noreply, %{state | waiting: state.waiting ++ [{:sync, from}]}}
  end

  @impl true
  def handle_info({port, {:data, {:noeol, chunk}}}, %{port: port} = state),
    do: {:noreply, %{state | buffer: state.buffer <> chunk}}

  def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state) do
    line = state.buffer <> line
    state = %{state | buffer: ""}

    case Jason.decode(line) do
      {:ok, %{"ready" => info}} ->
        {infos, rest} = Enum.split_with(state.waiting, &match?({:info, _}, &1))
        Enum.each(infos, fn {:info, from} -> GenServer.reply(from, info) end)
        {:noreply, %{state | info: info, waiting: rest}}

      {:ok, %{"synced" => true}} ->
        reply_first(state, :sync, :ok)

      {:ok, %{"error" => error}} ->
        reply_first(state, :sync, {:error, error})

      _ ->
        # Anything else a service printed to stdout.
        {:noreply, state}
    end
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state),
    do: {:stop, {:dev_network_exited, status}, state}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{port: port}) do
    # Ask the script to stop every service, and wait for it to say so.
    if Port.info(port) do
      Port.command(port, "close\n")

      receive do
        {^port, {:exit_status, _}} -> :ok
      after
        30_000 -> Port.close(port)
      end
    end

    :ok
  end

  defp reply_first(state, kind, reply) do
    case Enum.split_with(state.waiting, &match?({^kind, _}, &1)) do
      {[{^kind, from} | others], rest} ->
        GenServer.reply(from, reply)
        {:noreply, %{state | waiting: others ++ rest}}

      {[], _} ->
        {:noreply, state}
    end
  end
end
