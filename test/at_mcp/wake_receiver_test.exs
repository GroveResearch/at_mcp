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
    assert summary =~ "3 new for your account:"

    assert summary =~
             ~s{- reply from @someone.test: "reply number 1" (at://did:plc:someone/app.bsky.feed.post/3kreply1)}

    assert summary =~ "mention number 2"
    assert summary =~ "quote number 4"
    refute summary =~ "like number 3"

    # The same summary is in the command's environment.
    assert output =~ "--- 3 new for your account:"

    # Handed over, so a later event wakes the command for itself alone.
    assert :ok = send_event(url, event("reply", 5))
    Process.sleep(round(@quiet * 1000) + 1_200)
    assert [_, second] = String.split(File.read!(runs), ~r/^--- .*$\n/m, trim: true)
    assert second =~ "1 new for your account:"
    assert second =~ "reply number 5"
  end

  test "a request without the token is refused and wakes nothing", %{url: url, runs: runs} do
    assert {:error, {:http_status, 401}} = send_event(url, event("reply", 1), "wrong")
    Process.sleep(round(@quiet * 1000) + 600)
    refute File.exists?(runs)
  end
end
