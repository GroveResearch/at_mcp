defmodule AtMcp.WriteOutcomeTest do
  use ExUnit.Case, async: false

  defmodule Backend do
    # References are read before the write quota is charged; nothing here
    # refers to another record.
    def prepare_post(%{mode: :prepare_auth_refused}, _text, _opts),
      do: {:error, AtMcp.Effects.Failure.new(:auth_refused, status: 401)}

    def prepare_post(session, _text, opts) do
      Agent.update(session.ledger, &Map.update!(&1, :preparations, fn n -> n + 1 end))
      resolve_references(session, opts)
    end

    def resolve_references(_state, opts), do: {:ok, opts}

    def post(session, text, _opts \\ []), do: perform(session, text)
    def update_seen(session, _seen), do: perform(session, "seen")

    def login(_opts), do: {:error, AtMcp.Effects.Failure.new(:auth_refused)}

    def refresh(%{mode: :auth_refused_permanently} = session) do
      Agent.update(session.ledger, &Map.update!(&1, :refreshes, fn n -> n + 1 end))
      {:error, AtMcp.Effects.Failure.new(:auth_refused, detail: :refresh_refused)}
    end

    def refresh(session) do
      Agent.update(session.ledger, &Map.update!(&1, :refreshes, fn n -> n + 1 end))
      {:ok, %{session | mode: :success}}
    end

    defp perform(session, text) do
      Agent.update(session.ledger, &Map.update!(&1, :attempts, fn n -> n + 1 end))

      if session.mode in [:auth_refused, :auth_refused_permanently] do
        # The backend declares the credential was refused; AtMcp may recover once.
        {:error, AtMcp.Effects.Failure.new(:auth_refused, status: 400, detail: :expired_token)}
      else
        # The independently retained remote record exists before its response is
        # lost. Repeating this operation would create another record.
        Agent.update(
          session.ledger,
          &Map.update!(&1, :records, fn records -> records ++ [text] end)
        )

        case session.mode do
          :output_timeout ->
            # The input check has already succeeded. Force only the later
            # output check to time out, after this write was recorded.
            Application.put_env(:ex_mcp, :json_schema, validation_timeout_ms: 0)
            {:ok, %{uri: "at://did:plc:fixture/app.bsky.feed.post/1"}}

          :success ->
            {:ok, %{uri: "at://did:plc:fixture/app.bsky.feed.post/1"}}

          :malformed ->
            {:ok, %{uri: 42}}

          :timeout ->
            {:error, %Req.TransportError{reason: :timeout}}

          :exit ->
            exit(:connection_closed)

          :exception ->
            raise "private backend detail"

          :expired_text ->
            {:error, "response deadline expired"}

          :proxy ->
            {:error, AtMcp.Effects.Failure.new(:indeterminate, status: 503)}

          :proxy_401 ->
            {:error, %{http_status: 401, message: "proxy says expired"}}
        end
      end
    end
  end

  # update_seen is documented as not counting against the write quota. Its recovery retry must not
  # take one either, or marking notifications seen would spend an account's
  # writes and be refused once they ran out.
  test "a credential that cannot be renewed is reported as such, not as a bad request" do
    {effects, _ledger} = fixture(:auth_refused_permanently)

    assert {:error, :account_authentication_failed} = AtMcp.Effects.post(effects, "after logout")
    refute AtMcp.Effects.logged_in?(effects)

    assert {:ok,
            %{
              isError: true,
              structuredContent: %{code: "account_authentication_failed"},
              content: [%{text: text}]
            }, :state} = AtMcp.MCP.Tools.respond({:error, :account_authentication_failed}, :state)

    assert text =~ "logged out"
    assert text =~ "Nothing was applied"
    refute text =~ "Check the request"
  end

  test "marking notifications seen stays outside the write quota through session recovery" do
    dir = Path.join(System.tmp_dir!(), "at_mcp-seen-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)

    quota = start_supervised!({AtMcp.WriteQuota, name: nil, state_dir: dir, limit: 2})
    {effects, ledger} = fixture(:auth_refused, write_quota: quota)

    assert {:ok, _} = AtMcp.Effects.update_seen(effects)
    assert %{attempts: 2, refreshes: 1} = Agent.get(ledger, & &1)
    assert %{used: 0} = AtMcp.WriteQuota.status(quota, "did:plc:fixture")
    assert AtMcp.Effects.quota_status(effects).used == 0
  end

  # The write quota is used up before the fixture exists, so the credential is still
  # refused when update_seen runs and the retry after recovery is the thing
  # under test. Exhausting it with a post instead would leave the session
  # recovered, and update_seen would never reach a retry at all.
  test "an exhausted write quota still permits marking notifications seen through recovery" do
    dir = Path.join(System.tmp_dir!(), "at_mcp-seen-full-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)

    quota = start_supervised!({AtMcp.WriteQuota, name: nil, state_dir: dir, limit: 1})
    assert :ok = AtMcp.WriteQuota.reserve(quota, "did:plc:fixture")

    assert {:error, {:write_quota_exhausted, _}} =
             AtMcp.WriteQuota.reserve(quota, "did:plc:fixture")

    {effects, ledger} = fixture(:auth_refused, write_quota: quota)

    assert {:ok, _} = AtMcp.Effects.update_seen(effects)
    # Refused once, recovered, retried — with no slot to spend on either attempt.
    assert %{attempts: 2, refreshes: 1} = Agent.get(ledger, & &1)
    assert %{used: 1} = AtMcp.WriteQuota.status(quota, "did:plc:fixture")
  end

  test "the retry after recovery takes its own write quota slot" do
    dir = Path.join(System.tmp_dir!(), "at_mcp-retry-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)

    quota = start_supervised!({AtMcp.WriteQuota, name: nil, state_dir: dir, limit: 2})
    {effects, ledger} = fixture(:auth_refused, write_quota: quota)

    # One refused dispatch plus its retry is two attempts, so it is two slots.
    assert {:ok, %{uri: _}} = AtMcp.Effects.post(effects, "authorized after refresh")
    assert %{attempts: 2, refreshes: 1} = Agent.get(ledger, & &1)
    assert %{used: 2} = AtMcp.WriteQuota.status(quota, "did:plc:fixture")
  end

  test "a retry that would exceed the write quota is refused, not dispatched" do
    dir = Path.join(System.tmp_dir!(), "at_mcp-retry-cap-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)

    quota = start_supervised!({AtMcp.WriteQuota, name: nil, state_dir: dir, limit: 1})
    {effects, ledger} = fixture(:auth_refused, write_quota: quota)

    assert {:error, {:write_quota_exhausted, _}} = AtMcp.Effects.post(effects, "one slot only")
    # The refused dispatch happened; the retry did not, because there was no slot.
    assert %{attempts: 1, records: []} = Agent.get(ledger, & &1)
    assert %{used: 1} = AtMcp.WriteQuota.status(quota, "did:plc:fixture")
  end

  test "committed writes with lost responses stay unknown without retry or leaking backend details" do
    for mode <- [:timeout, :exit, :exception, :expired_text, :proxy, :proxy_401] do
      {effects, ledger} = fixture(mode)

      assert {:error, {:write_outcome_unknown, _}} =
               result = AtMcp.Effects.post(effects, "one record")

      assert %{attempts: 1, refreshes: 0, records: ["one record"]} = Agent.get(ledger, & &1)
      assert AtMcp.Effects.quota_status(effects).used == 1

      assert {:ok, %{isError: true, content: [%{text: message}]}, :state} =
               AtMcp.MCP.Tools.respond(result, :state)

      assert message =~ "may have completed"
      assert message =~ "Inspect the account"
      assert message =~ "did not retry"
      refute message =~ "private backend detail"
    end
  end

  test "refusing an account that is not ready reaches no backend and does not claim an ambiguous write" do
    {effects, ledger} = fixture(:success, write_quota: :unavailable_quota_fixture)
    assert {:error, :write_quota_unavailable} = AtMcp.Effects.post(effects, "not sent")
    assert %{attempts: 0, records: []} = Agent.get(ledger, & &1)
    assert {:error, :write_quota_unavailable} = AtMcp.Effects.quota_status(effects)
  end

  test "authentication refused during post preparation recovers before the only quota debit" do
    {effects, ledger} = fixture(:prepare_auth_refused)
    assert {:ok, %{uri: _}} = AtMcp.Effects.post(effects, "after preparation refresh")

    assert %{attempts: 1, refreshes: 1, records: ["after preparation refresh"]} =
             Agent.get(ledger, & &1)

    assert AtMcp.Effects.quota_status(effects).used == 1
  end

  test "explicit authentication refusal still refreshes once before the only committed record" do
    {effects, ledger} = fixture(:auth_refused)
    assert {:ok, %{uri: _}} = AtMcp.Effects.post(effects, "authorized after refresh")

    assert %{attempts: 2, refreshes: 1, records: ["authorized after refresh"]} =
             Agent.get(ledger, & &1)

    # Two dispatches reached the backend, so two slots were taken. Counting the
    # retry as free let a recovering account spend more than its write quota.
    assert AtMcp.Effects.quota_status(effects).used == 2
  end

  test "marking notifications seen also preserves uncertain write outcomes" do
    {effects, ledger} = fixture(:timeout)
    assert {:error, {:write_outcome_unknown, _}} = AtMcp.Effects.update_seen(effects)
    assert %{attempts: 1, records: ["seen"]} = Agent.get(ledger, & &1)
    assert AtMcp.Effects.quota_status(effects).used == 0
  end

  test "invalid input never reaches preparation or spends write quota" do
    {effects, ledger} = fixture(:success)
    state = %{effects: effects}

    for arguments <- [
          %{},
          %{"text" => 42},
          %{text: :not_a_string},
          %{"text" => "valid-looking", :text => 42},
          %{text: "not sent", langs: [42]}
        ] do
      assert {:ok, %{isError: true, structuredContent: %{code: "invalid_arguments"}}, ^state} =
               AtMcp.MCP.Server.handle_call_tool("post", arguments, state)
    end

    assert %{attempts: 0, preparations: 0, records: []} = Agent.get(ledger, & &1)
    assert AtMcp.Effects.quota_status(effects).used == 0

    assert {:ok, result, ^state} =
             AtMcp.MCP.Server.handle_call_tool("post", %{text: "once"}, state)

    refute result[:isError]
    assert %{attempts: 1, records: ["once"]} = Agent.get(ledger, & &1)
  end

  test "input validation timeout refuses before a write rather than claiming an unknown outcome" do
    previous = Application.fetch_env(:ex_mcp, :json_schema)
    Application.put_env(:ex_mcp, :json_schema, validation_timeout_ms: 0)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:ex_mcp, :json_schema, value)
        :error -> Application.delete_env(:ex_mcp, :json_schema)
      end
    end)

    {effects, ledger} = fixture(:success)

    assert {:ok, %{isError: true, structuredContent: %{code: "input_validation_unavailable"}}, _} =
             AtMcp.MCP.Server.handle_call_tool("post", %{text: "not sent"}, %{effects: effects})

    assert %{attempts: 0, preparations: 0, records: []} = Agent.get(ledger, & &1)
    assert AtMcp.Effects.quota_status(effects).used == 0
  end

  # ExMCP validates a tool's output against its schema after the tool has run,
  # under a deadline (100ms by default) that a loaded machine can miss on
  # correct output. A zero deadline misses it every time. The post has landed by
  # then, so the caller must get its result: an error would invite a retry that
  # posts twice.
  test "a completed post returns its result when output validation misses its deadline" do
    previous = Application.fetch_env(:ex_mcp, :json_schema)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:ex_mcp, :json_schema, value)
        :error -> Application.delete_env(:ex_mcp, :json_schema)
      end
    end)

    {effects, ledger} = fixture(:output_timeout)
    state = %{effects: effects}

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        send(self(), AtMcp.MCP.Server.handle_call_tool("post", %{"text" => "once"}, state))
      end)

    assert_received {:ok, result, ^state}
    refute result[:isError], inspect(result)
    assert result.structuredContent["uri"] == "at://did:plc:fixture/app.bsky.feed.post/1"
    assert log =~ "unvalidated"
    assert %{attempts: 1, records: ["once"]} = Agent.get(ledger, & &1)
  end

  test "output schema defects are diagnosed without changing a completed write's outcome" do
    {effects, ledger} = fixture(:malformed)
    state = %{effects: effects}

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        send(
          self(),
          AtMcp.MCP.Server.handle_call_tool("post", %{"text" => "private post"}, state)
        )
      end)

    assert_received {:ok, result, ^state}
    refute result[:isError]
    assert result.structuredContent["uri"] == 42
    assert log =~ "output schema mismatch"
    refute log =~ "private post"
    assert %{attempts: 1, records: ["private post"]} = Agent.get(ledger, & &1)
  end

  defp fixture(mode, opts \\ []) do
    ledger =
      start_supervised!(
        {Agent, fn -> %{attempts: 0, preparations: 0, records: [], refreshes: 0} end},
        id: make_ref()
      )

    effects =
      start_supervised!(
        {AtMcp.Effects,
         Keyword.merge(
           [
             write_quota: AtMcp.Test.QuotaFixture.quota(100),
             backend: Backend,
             backend_state: %{did: "did:plc:fixture", ledger: ledger, mode: mode}
           ],
           opts
         )},
        id: make_ref()
      )

    {effects, ledger}
  end
end
