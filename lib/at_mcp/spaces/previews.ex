defmodule AtMcp.Spaces.Previews do
  @moduledoc """
  What a preview showed, kept until its approval spends it, or for ten
  minutes: an outside app's sign-in (`preview_app_sign_in`) and an app's
  sign-in as a group (`preview_group_app`). An ETS table this process owns,
  swept each minute, so previews never approved don't pile up and taking one
  costs nothing beyond the table.
  """
  use GenServer

  @table __MODULE__
  @ttl_ms 600_000
  @sweep_ms 60_000

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "How long a preview lasts, in milliseconds."
  def ttl_ms, do: @ttl_ms

  @doc "Keeps what `key`'s preview showed."
  def put(key, value) do
    if table?(), do: :ets.insert(@table, {key, value, now()})
    :ok
  end

  @doc "What `key`'s preview showed, still within its time: `{:ok, value}`, `:expired` or `:none`."
  def peek(key) do
    case table?() && :ets.lookup(@table, key) do
      [{^key, value, at}] -> if now() - at <= @ttl_ms, do: {:ok, value}, else: :expired
      _ -> :none
    end
  end

  @doc "As `peek/1`, and the preview is spent."
  def take(key) do
    result = peek(key)
    if table?(), do: :ets.delete(@table, key)
    result
  end

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
    Process.send_after(self(), :sweep, @sweep_ms)
    {:ok, nil}
  end

  @impl true
  def handle_info(:sweep, state) do
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", now() - @ttl_ms}], [true]}])
    Process.send_after(self(), :sweep, @sweep_ms)
    {:noreply, state}
  end

  defp table?, do: :ets.whereis(@table) != :undefined
  defp now, do: System.monotonic_time(:millisecond)
end
