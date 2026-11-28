defmodule AtMcp.MCP.GrantAttempts do
  @moduledoc """
  A limit on failed grant presentations at the MCP endpoint, for an endpoint
  a TLS proxy exposes to a hosted agent's servers: after
  `AT_MCP_GRANT_FAILURES_PER_MINUTE` failures (10 by default) from one
  source within a minute, that source's failed presentations are answered
  429 until the minute is out. A request that presents no credential at all
  doesn't count.

  The source is the connecting address; for a request that arrives on
  loopback with `X-Forwarded-For` (the proxy on the same machine), the
  first address it names. The proxy must set that header itself, replacing
  what a client sent. An IPv6 source counts by its /64. A valid grant is
  always served: only failures are counted and refused. Sources whose
  minute is out are dropped as failures are counted.
  """
  use GenServer

  @table __MODULE__
  @window_ms 60_000

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, write_concurrency: true])
    {:ok, nil}
  end

  @doc "Whether `source` may present a grant now: `:ok`, or `{:wait, seconds}`."
  def check(source) do
    now = now()

    case table?() && :ets.lookup(@table, source) do
      [{^source, count, since}] when now - since < @window_ms ->
        if count >= limit(), do: {:wait, div(@window_ms - (now - since) + 999, 1000)}, else: :ok

      _ ->
        :ok
    end
  end

  @doc "Counts one failed presentation from `source`, and drops windows past."
  def failed(source) do
    if table?() do
      now = now()
      # Sources whose minute is out are forgotten, so the table holds only
      # the sources failing now.
      :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", now - @window_ms}], [true]}])

      case :ets.lookup(@table, source) do
        [{^source, count, since}] when now - since < @window_ms ->
          :ets.insert(@table, {source, count + 1, since})

        _ ->
          :ets.insert(@table, {source, 1, now})
      end
    end

    :ok
  end

  @doc "The source a request counts against (see the moduledoc)."
  def source(%Plug.Conn{remote_ip: ip} = conn) do
    forwarded = Plug.Conn.get_req_header(conn, "x-forwarded-for")

    address =
      case {loopback?(ip), forwarded} do
        {true, [value | _]} -> value |> String.split(",") |> hd() |> String.trim()
        _ -> ip |> :inet.ntoa() |> to_string()
      end

    prefix(address)
  end

  # An IPv6 client usually holds a whole /64, and could rotate within it:
  # counted by its /64.
  defp prefix(address) do
    case :inet.parse_address(String.to_charlist(address)) do
      {:ok, {a, b, c, d, _, _, _, _}} ->
        ({a, b, c, d, 0, 0, 0, 0} |> :inet.ntoa() |> to_string()) <> "/64"

      _ ->
        address
    end
  end

  defp loopback?({127, _, _, _}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback?(_ip), do: false

  defp limit, do: Application.get_env(:at_mcp, :grant_failures_per_minute) || 10
  defp table?, do: :ets.whereis(@table) != :undefined
  defp now, do: System.monotonic_time(:millisecond)
end
