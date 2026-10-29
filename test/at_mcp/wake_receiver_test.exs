defmodule AtMcp.WakeReceiverTest do
  @moduledoc """
  `examples/wake.py`, the example receiver in docs/delivery.md, run against
  at_mcp's own delivery client (`AtMcp.Deliver.HTTPBridge`): a burst of events
  becomes one run of the command, with a summary of what arrived.
  """
  use ExUnit.Case, async: true

  @script Path.expand("../../examples/wake.py", __DIR__)
  @quiet 0.4

  @moduletag skip:
               is_nil(System.find_executable("python3")) && "needs python3 for examples/wake.py"

  setup do
    dir = Path.join(System.tmp_dir!(), "at_mcp-wake-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    token_file = Path.join(dir, "token")
    File.write!(token_file, "wake-token\n")
    runs = Path.join(dir, "runs")

    port =
      Port.open({:spawn_executable, System.find_executable("python3")}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: [
          @script,
          "--port",
          "0",
          "--token-file",
          token_file,
          "--quiet",
          to_string(@quiet),
          "--pending",
          Path.join(dir, "pending.jsonl"),
          "--command",
          ~s(cat >> "#{runs}"; echo "--- $AT_MCP_WAKE_SUMMARY" | head -1 >> "#{runs}")
        ]
      ])

    on_exit(fn -> if info = Port.info(port), do: System.cmd("kill", ["#{info[:os_pid]}"]) end)

    url =
      receive do
        {^port, {:data, data}} ->
          [_, address] = Regex.run(~r{listening on (http://\S+)}, data)
          address
      after
        5_000 -> flunk("wake.py did not start")
      end

    %{url: url, runs: runs}
  end

  defp event(reason, n),
    do: %{
      source: "notifications",
      kind: "inbound_notification",
      matched_did: "did:plc:agent",
      reason: reason,
      uri: "at://did:plc:someone/app.bsky.feed.post/3k#{reason}#{n}",
      author: "someone.test",
      author_did: "did:plc:someone",
      text: "#{reason} number #{n}"
    }

  defp send_event(url, event, token \\ "wake-token"),
    do: AtMcp.Deliver.HTTPBridge.post_inbound(url, token, event)

  test "a burst wakes the command once, with a summary of what arrived", %{url: url, runs: runs} do
    assert :ok = send_event(url, event("reply", 1))
    assert :ok = send_event(url, event("mention", 2))
    # A like does not wake the agent; a repeat delivery is not counted twice.
    assert :ok = send_event(url, event("like", 3))
    assert :ok = send_event(url, event("reply", 1))
    assert :ok = send_event(url, event("quote", 4))

    Process.sleep(round(@quiet * 1000) + 1_200)
    output = File.read!(runs)

    assert [summary] = String.split(output, ~r/^--- .*$\n/m, trim: true)
    assert summary =~ "3 new notifications for your account since the last wake:"

    assert summary =~
             ~s{- reply from @someone.test: "reply number 1" (at://did:plc:someone/app.bsky.feed.post/3kreply1)}

    assert summary =~ "mention number 2"
    assert summary =~ "quote number 4"
    refute summary =~ "like number 3"

    # The same summary is in the command's environment.
    assert output =~ "--- 3 new notifications for your account since the last wake:"

    # Handed over, so a later event wakes the command for itself alone.
    assert :ok = send_event(url, event("reply", 5))
    Process.sleep(round(@quiet * 1000) + 1_200)
    assert [_, second] = String.split(File.read!(runs), ~r/^--- .*$\n/m, trim: true)
    assert second =~ "1 new notification for your account since the last wake:"
    assert second =~ "reply number 5"
  end

  # A wake that finds the command still running looks again after a quiet
  # period. Without that floor, once --max-wait had passed, the timer fired
  # again at once, over and over, until the run ended.
  test "a wake during a running command waits a quiet period before it looks again" do
    dir = Path.join(System.tmp_dir!(), "at_mcp-wake-busy-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    script = """
    import importlib.util, sys, time
    spec = importlib.util.spec_from_file_location("wake", sys.argv[1])
    wake = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(wake)
    args = wake.parse_args(["--command", "true", "--quiet", "5", "--max-wait", "1",
                            "--no-token", "--pending", sys.argv[2]])
    waker = wake.Waker(args)
    waker.events = [{"uri": "at://x", "reason": "reply"}]
    waker.first_at = time.monotonic() - 10
    waker.running.acquire()
    waker.wake()
    print(waker.timer.interval)
    waker.timer.cancel()
    """

    {out, 0} =
      System.cmd("python3", ["-I", "-c", script, @script, Path.join(dir, "pending.jsonl")])

    assert String.to_float(String.trim(out)) >= 5.0
  end

  test "a request without the token is refused and wakes nothing", %{url: url, runs: runs} do
    assert {:error, {:http_status, 401}} = send_event(url, event("reply", 1), "wrong")
    Process.sleep(round(@quiet * 1000) + 600)
    refute File.exists?(runs)
  end

  # `claude -p` can exit non-zero after it has replied, so a failed run is not
  # repeated with the same events: that would be a second reply.
  test "a run that exits non-zero is logged, and its events are not handed over again" do
    dir = Path.join(System.tmp_dir!(), "at_mcp-wake-fail-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    runs = Path.join(dir, "runs")
    pending = Path.join(dir, "pending.jsonl")

    port =
      Port.open({:spawn_executable, System.find_executable("python3")}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: [
          @script,
          "--port",
          "0",
          "--no-token",
          "--quiet",
          to_string(@quiet),
          "--pending",
          pending,
          "--command",
          ~s(cat >> "#{runs}"; echo "---" >> "#{runs}"; exit 1)
        ]
      ])

    on_exit(fn -> if info = Port.info(port), do: System.cmd("kill", ["#{info[:os_pid]}"]) end)
    url = listening(port)

    assert :ok = send_event(url, event("reply", 1), "unchecked")
    Process.sleep(round(@quiet * 1000) + 1_200)
    assert File.read!(pending) == ""

    assert :ok = send_event(url, event("reply", 2), "unchecked")
    Process.sleep(round(@quiet * 1000) + 1_200)

    assert [first, second] = String.split(File.read!(runs), "---\n", trim: true)
    assert first =~ "/3kreply1"
    refute second =~ "/3kreply1"
    assert second =~ "/3kreply2"

    assert drain(port) =~
             "wake: command exited 1 with 1 events; not handing them over again: " <>
               "at://did:plc:someone/app.bsky.feed.post/3kreply1"
  end

  test "it refuses to start without --token-file unless --no-token says so" do
    {out, status} =
      System.cmd("python3", ["-I", @script, "--command", "true", "--port", "0"],
        stderr_to_stdout: true
      )

    assert status == 2
    assert out =~ "one of the arguments --token-file --no-token is required"
  end

  test "the pending file defaults to an absolute path under the state directory" do
    script = """
    import importlib.util, os, sys
    spec = importlib.util.spec_from_file_location("wake", sys.argv[1])
    wake = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(wake)
    os.environ["XDG_STATE_HOME"] = "/srv/state"
    print(wake.parse_args(["--command", "true", "--no-token"]).pending)
    del os.environ["XDG_STATE_HOME"]
    os.environ["HOME"] = "/home/agent"
    print(wake.parse_args(["--command", "true", "--no-token"]).pending)
    print(wake.parse_args(["--command", "true", "--no-token", "--pending", "here.jsonl"]).pending)
    """

    {out, 0} = System.cmd("python3", ["-I", "-c", script, @script], cd: System.tmp_dir!())

    assert String.split(out, "\n", trim: true) == [
             "/srv/state/at_mcp/wake-pending.jsonl",
             "/home/agent/.local/state/at_mcp/wake-pending.jsonl",
             Path.join(Path.expand(System.tmp_dir!()), "here.jsonl")
           ]
  end

  defp listening(port) do
    receive do
      {^port, {:data, data}} ->
        case Regex.run(~r{listening on (http://\S+)}, data) do
          [_, address] -> address
          nil -> listening(port)
        end
    after
      5_000 -> flunk("wake.py did not start")
    end
  end

  defp drain(port, acc \\ "") do
    receive do
      {^port, {:data, data}} -> drain(port, acc <> data)
    after
      200 -> acc
    end
  end
end
