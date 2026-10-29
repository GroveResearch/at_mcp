defmodule AtMcp.ValidationDeadlineTest do
  @moduledoc """
  A busy machine does not turn a tool call's argument check into a refusal.

  ExMCP checks arguments in a separate process under a deadline. Starving that
  process of the scheduler for 300 ms, as a loaded machine can, makes ExMCP's
  default 100 ms deadline miss. AtMcp's configured deadline still sees the
  check finish. The test takes the whole VM down to one scheduler while it
  runs, so it is not async.
  """
  use ExUnit.Case, async: false

  alias ExMCP.Content.SchemaPolicy

  @starved_ms 300

  test "the default 100 ms deadline misses when the scheduler is busy" do
    {:ok, schema} = SchemaPolicy.compile(%{"type" => "object"})

    assert {:error, {:schema_validation_timeout, 100}} =
             starved(fn -> SchemaPolicy.validate(%{}, schema, validation_timeout_ms: 100) end)
  end

  test "a tool call's arguments are still checked when the scheduler is busy" do
    assert {:ok, %{isError: true, structuredContent: %{code: "invalid_arguments"}}, _} =
             starved(fn ->
               AtMcp.MCP.Server.handle_call_tool(
                 "search_posts",
                 %{"query" => "at_mcp", "sort" => "popular"},
                 %{}
               )
             end)
  end

  # Runs `fun` while one high-priority process holds the only scheduler for
  # @starved_ms. This process is high priority too, so it reaches the check and
  # starts its deadline; the check's own process is normal priority and cannot
  # run until the busy one finishes.
  defp starved(fun) do
    schedulers = :erlang.system_flag(:schedulers_online, 1)
    priority = Process.flag(:priority, :high)

    try do
      me = self()

      Process.spawn(
        fn ->
          send(me, :busy)
          stop = System.monotonic_time(:millisecond) + @starved_ms
          spin(stop)
        end,
        priority: :high
      )

      assert_receive :busy
      fun.()
    after
      Process.flag(:priority, priority)
      :erlang.system_flag(:schedulers_online, schedulers)
    end
  end

  defp spin(stop) do
    if System.monotonic_time(:millisecond) < stop, do: spin(stop)
  end
end
