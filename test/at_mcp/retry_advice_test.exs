defmodule AtMcp.RetryAdviceTest do
  @moduledoc """
  Every error an agent reads ends with one sentence saying what it can do, and
  says the same in the structured result's `retry`: try again now (`now`),
  after a stated time (`after`, with `retry_after`), with an argument changed
  (`change_argument`, naming `argument`), not until the account has been read
  (`check_first`, for a write whose outcome is unknown), or not at all (`no`).
  """
  use ExUnit.Case, async: false

  alias AtMcp.Effects.Failure

  # The sentence each kind of advice ends with.
  @endings %{
    "now" =>
      ~r/(Trying again now is safe[^.]*\.( If this tool takes a limit[^.]*\.)?|(try|Call it) again now[^.]*\.)\z/,
    "after" => ~r/(Try again after \d{4}-\d\d-\d\dT[\d:]+Z|Wait about [^,]+, then try again)\.\z/,
    "change_argument" =>
      ~r/(and try again|before trying again[^.]*|call again with each part)\.\z/,
    "check_first" => ~r/Don't retry until you have read [^.]+\.\z/,
    "no" =>
      ~r/(Trying again will (not help|return the same result)[^.]*|Tell the account's operator about this error)\.\z/,
    "unknown" => ~r/can't say whether trying again will help\.\z/
  }

  defp respond(reason) do
    {:ok, %{isError: true, content: [%{text: text}], structuredContent: structured}, :state} =
      AtMcp.MCP.Tools.respond({:error, reason}, :state)

    assert structured.message == text
    assert text =~ Map.fetch!(@endings, structured.retry), "#{structured.retry}: #{text}"
    {text, structured}
  end

  test "each failure kind ends with the sentence its advice gives" do
    cases = [
      {Failure.new(:refused, status: 400, message: "Invalid cursor"), "change_argument"},
      {Failure.new(:auth_refused, status: 401, message: "Bad token"), "change_argument"},
      {Failure.new(:refused, status: 501, message: "Not here"), "no"},
      {Failure.new(:indeterminate, status: 503, message: "Down"), "after"},
      {Failure.new(:indeterminate, status: 429, message: "Slow down"), "after"},
      {Failure.new(:indeterminate, detail: :closed), "now"},
      {Failure.new(:refused, message: "invalid record"), "change_argument"},
      {{:some_unclassified_reason, 1}, "unknown"},
      {Failure.new(:unreadable, message: "An answer AtMcp could not read."), "no"},
      {{:write_outcome_unknown, Failure.new(:indeterminate, detail: :closed)}, "check_first"},
      {{:write_outcome_unknown, :call_deadline_exceeded}, "check_first"},
      {:call_deadline_exceeded, "now"},
      {{:call_deadline_exceeded, :sent}, "now"},
      {{:write_quota_exhausted, 120}, "after"},
      {{:invalid_argument, "limit", "must be at most 50"}, "change_argument"},
      {:not_connected, "no"},
      {:account_authentication_failed, "no"}
    ]

    for {reason, retry} <- cases do
      {_text, structured} = respond(reason)
      assert structured.retry == retry, inspect(reason)
    end
  end

  test "a wait at_mcp chose gives no retry_after, since the service gave no time" do
    for status <- [429, 503] do
      {text, structured} = respond(Failure.new(:indeterminate, status: status, message: "x"))
      assert structured.retry == "after"
      refute Map.has_key?(structured, :retry_after)
      assert text =~ ~r/Wait about (a|half a) minute, then try again\.\z/
    end
  end

  test "argument is only ever an argument's name" do
    for reason <- [
          :empty_batch,
          :batch_too_large,
          :invalid_search_filter,
          "limit must be an integer between 1 and 50",
          {:referenced_record_unreadable, "at://did:plc:x/app.bsky.feed.post/3k22222222222",
           :not_found},
          Failure.new(:refused, status: 400, message: "bad")
        ] do
      {_text, structured} = respond(reason)
      assert structured.retry == "change_argument", inspect(reason)
      refute Map.has_key?(structured, :argument), inspect(reason)
    end
  end

  test "advice to change an argument names it, and advice to wait states until when" do
    {text, structured} = respond({:invalid_argument, "limit", "must be at most 50"})
    assert structured.argument == "limit"
    assert text =~ ~r/Change limit and try again\.\z/

    {text, structured} = respond({:write_quota_exhausted, 120})
    assert structured.retry_after == "1970-01-01T00:02:00Z"
    assert text =~ ~r/Try again after 1970-01-01T00:02:00Z\.\z/
  end

  test "a refusal of the input schema names the argument to change" do
    state = %{effects: :unused}

    {:ok, result, ^state} =
      AtMcp.MCP.Server.handle_call_tool("search_posts", %{"query" => "x", "limit" => 500}, state)

    assert result.isError

    assert %{code: "invalid_arguments", retry: "change_argument", argument: "limit"} =
             result.structuredContent

    assert hd(result.content).text =~ ~r/Change limit and try again\.\z/
  end

  describe "a read stopped at the deadline" do
    defmodule SlowBackend do
      @moduledoc false
      # A login and a search that each take as long as the test says.

      def login(opts) do
        Process.sleep(Keyword.get(opts, :password) |> String.to_integer())
        {:ok, %{did: "did:plc:slow", search_ms: Keyword.fetch!(opts, :handle)}}
      end

      def refresh(state), do: {:ok, state}

      def search_posts(%{search_ms: ms}, _query, _opts) do
        Process.sleep(String.to_integer(ms))
        {:ok, %{count: 0, items: [], cursor: nil}}
      end
    end

    setup do
      previous = Application.fetch_env(:at_mcp, :call_deadline_ms)
      Application.put_env(:at_mcp, :call_deadline_ms, 300)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:at_mcp, :call_deadline_ms, value)
          :error -> Application.delete_env(:at_mcp, :call_deadline_ms)
        end
      end)
    end

    defp search(login_ms, search_ms) do
      {:ok, effects} =
        AtMcp.Test.QuotaFixture.start_effects(
          backend: SlowBackend,
          handle: Integer.to_string(search_ms),
          password: Integer.to_string(login_ms)
        )

      state = %{effects: effects}

      {:ok, result, ^state} =
        AtMcp.MCP.Server.handle_call_tool("search_posts", %{"query" => "x"}, state)

      result
    end

    test "says the request reached the service when it did" do
      result = search(0, 5_000)

      assert result.isError

      assert %{code: "call_deadline_exceeded", sent: true, retry: "now"} =
               result.structuredContent

      assert hd(result.content).text =~ "sent this read to the account's service"
    end

    test "says the request was never sent when it was waiting for the account's session" do
      result = search(5_000, 0)

      assert result.isError

      assert %{code: "call_deadline_exceeded", sent: false, retry: "now"} =
               result.structuredContent

      assert hd(result.content).text =~ "was not sent"
    end
  end

  test "a search the service fails reads as a failure, not as no results" do
    defmodule FailingSearch do
      @moduledoc false
      def login(_opts), do: {:ok, %{did: "did:plc:fails"}}
      def refresh(state), do: {:ok, state}

      def search_posts(_state, _query, _opts),
        do: {:error, AtMcp.Effects.Failure.new(:indeterminate, detail: :closed)}
    end

    {:ok, effects} = AtMcp.Test.QuotaFixture.start_effects(backend: FailingSearch)
    {:ok, _} = AtMcp.Effects.login(effects)
    state = %{effects: effects}

    {:ok, result, ^state} =
      AtMcp.MCP.Server.handle_call_tool("search_posts", %{"query" => "gliders"}, state)

    assert result.isError
    refute Map.has_key?(result.structuredContent, :items)
    refute Map.has_key?(result.structuredContent, :count)
    assert %{code: "upstream_failed", retry: "now"} = result.structuredContent
    text = hd(result.content).text
    assert text =~ "no results were read"
    refute text =~ ~r/no posts|0 posts/i
  end
end
