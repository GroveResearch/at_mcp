defmodule AtMcp.SpacesHelperExitTest do
  @moduledoc """
  A helper that dies while calls wait for it. A call already in the helper
  GenServer's mailbox when the helper's process dies meets a closed port
  before the GenServer reads the exit: it is answered, never crashed, and a
  write is never sent twice.
  """
  use ExUnit.Case, async: false

  alias AtMcp.Effects.Failure
  alias AtMcp.Spaces.Helper

  @fake Path.expand("../support/fake_spaces_helper.mjs", __DIR__)

  setup do
    # Nothing else calls the helper meanwhile (InboxTokens' pass, say).
    :ok = Supervisor.terminate_child(AtMcp.Supervisor, AtMcp.Spaces.InboxTokens)
    :ok = Supervisor.terminate_child(AtMcp.Supervisor, Helper)

    on_exit(fn ->
      {:ok, _} = Supervisor.restart_child(AtMcp.Supervisor, Helper)
      {:ok, _} = Supervisor.restart_child(AtMcp.Supervisor, AtMcp.Spaces.InboxTokens)
    end)

    log = Path.join(System.tmp_dir!(), "helper-exit-#{System.unique_integer([:positive])}.log")
    System.put_env("FAKE_LOG", log)

    on_exit(fn ->
      System.delete_env("FAKE_LOG")
      File.rm(log)
    end)

    {:ok, pid} = Helper.start_link(enabled: true, script: @fake)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    %{pid: pid, log: log}
  end

  defp calls(log, method) do
    case File.read(log) do
      {:ok, text} ->
        text
        |> String.split("\n", trim: true)
        |> Enum.count(&(Jason.decode!(&1)["method"] == method))

      _ ->
        0
    end
  end

  defp queued(pid, n) do
    Enum.find_value(1..200, fn _ ->
      if elem(Process.info(pid, :message_queue_len), 1) >= n, do: true, else: Process.sleep(5)
    end)
  end

  test "calls queued as the helper dies are answered by its successor", ctx do
    assert {:ok, _} = Helper.call("oauth.status", %{did: "did:plc:x"})
    os_pid = Helper.os_pid()

    # Both calls wait in the mailbox while the helper is killed, so the
    # GenServer reaches them before the helper's exit.
    :sys.suspend(ctx.pid)
    read = Task.async(fn -> Helper.call("oauth.status", %{did: "did:plc:x"}) end)
    write = Task.async(fn -> Helper.call("space.create", %{type: "t.e.s.t", skey: "once"}) end)
    assert queued(ctx.pid, 2)
    {_, 0} = System.cmd("kill", ["-9", to_string(os_pid)])
    Process.sleep(300)
    :sys.resume(ctx.pid)

    assert {:ok, %{"held" => true}} = Task.await(read)

    # Usually the port has closed by now, nothing reached the dead helper, and
    # the write goes to the new one, once. On a loaded machine the port may
    # still be open: the write is then sent to the dead helper and answered
    # as exited, its outcome unknown. Either way it is answered, and sent at
    # most once.
    case Task.await(write) do
      {:ok, %{"space" => _}} ->
        assert calls(ctx.log, "space.create") == 1

      {:error, %Failure{kind: :indeterminate, detail: :spaces_helper_exited}} ->
        assert calls(ctx.log, "space.create") in [0, 1]
    end

    assert Process.alive?(ctx.pid)
    assert Helper.os_pid() not in [nil, os_pid]
  end

  test "a call whose helper GenServer stops is answered: exited, outcome unknown", ctx do
    # The GenServer stops mid-call (a restart): the caller is told, in
    # AtMcp's terms.
    Process.unlink(ctx.pid)
    :sys.suspend(ctx.pid)
    task = Task.async(fn -> Helper.call("oauth.status", %{did: "did:plc:x"}, timeout: 5_000) end)
    assert queued(ctx.pid, 1)
    Process.exit(ctx.pid, :kill)

    assert {:error, %Failure{kind: :indeterminate, detail: :spaces_helper_exited}} =
             Task.await(task)
  end
end
