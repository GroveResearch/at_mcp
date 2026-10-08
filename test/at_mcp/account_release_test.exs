defmodule AtMcp.AccountReleaseTest do
  use ExUnit.Case, async: false

  defmodule PDS do
    use Plug.Router
    plug(Plug.Parsers, parsers: [:json], json_decoder: Jason)
    plug(:match)
    plug(:dispatch)

    post "/xrpc/com.atproto.server.createSession" do
      name = conn.body_params["identifier"]

      passwords =
        Agent.get(AtMcp.AccountReleaseTest.Passwords, &Map.get(&1, name, ["fixture-secret"]))

      if conn.body_params["password"] in passwords do
        body =
          Jason.encode!(%{
            did: "did:plc:" <> name,
            handle: name,
            accessJwt: "fixture-access",
            refreshJwt: "fixture-refresh"
          })

        conn |> put_resp_content_type("application/json") |> send_resp(200, body)
      else
        send_resp(conn, 401, ~s({"error":"AuthenticationRequired"}))
      end
    end

    match(_, do: send_resp(conn, 404, "no fixture for this operation"))
  end

  @tag skip: is_nil(System.get_env("TEST_ACCOUNT_RELEASE"))
  @tag timeout: 180_000
  test "release account commands manage one daemon across live configuration changes" do
    release = System.fetch_env!("TEST_ACCOUNT_RELEASE") |> Path.expand()

    root =
      Path.join(System.tmp_dir!(), "at_mcp-account-release-#{System.unique_integer([:positive])}")

    file = Path.join(root, "accounts.json")
    on_exit(fn -> File.rm_rf!(root) end)

    start_supervised!(%{
      id: __MODULE__.Passwords,
      start:
        {Agent, :start_link,
         [
           fn -> %{"alice" => ["fixture-secret", "rotated-fixture-secret"]} end,
           [name: __MODULE__.Passwords]
         ]}
    })

    ref = __MODULE__.HTTP
    start_supervised!({Plug.Cowboy, scheme: :http, plug: PDS, options: [port: 0, ref: ref]})
    port = :ranch.get_port(ref)
    setup = Path.join(release, "bin/at_mcp-accounts")

    mcp_port = free_port()
    dist_port = free_port()
    # Where a port mapper would be asked for, and nothing listens: this test's
    # release sees a machine with no epmd, and this machine's own mappers are
    # never touched.
    epmd_port = free_port()
    endpoint_env = [{"AT_MCP_PORT", to_string(mcp_port)}]
    endpoint = "http://127.0.0.1:#{mcp_port}/mcp"

    for name <- ["alice", "bob", "carol"] do
      {output, status} =
        command(
          setup,
          [
            "--file",
            file,
            "add",
            name,
            "--handle",
            name,
            "--service",
            "http://127.0.0.1:#{port}",
            "--password-stdin"
          ],
          "fixture-secret\n",
          endpoint_env
        )

      assert status == 0, output
      assert Jason.decode!(output)["account"]["did"] == "did:plc:" <> name
      refute output =~ "fixture-secret"
    end

    {output, 0} = command(setup, ["--file", file, "connection", "carol"], "", endpoint_env)
    assert Jason.decode!(output)["mcp"]["url"] == endpoint

    {output, 0} =
      command(
        setup,
        ["--file", file, "connection", "carol", "--transport", "stdio"],
        "",
        endpoint_env
      )

    descriptor = Jason.decode!(output)["mcp"]
    assert descriptor["command"] == Path.join(release, "bin/at_mcp-connect")

    assert descriptor["args"] == [
             "--url",
             endpoint,
             "--did",
             "did:plc:carol"
           ]

    executable = Path.join(release, "bin/at_mcp")

    env =
      [
        {"AT_MCP_ACCOUNTS_FILE", file},
        {"AT_MCP_STATE_DIR", Path.join(root, "state")},
        {"AT_MCP_JETSTREAM", "0"},
        {"AT_MCP_NOTIFICATIONS", "0"},
        {"AT_MCP_ENV_FILE", nil},
        {"AT_MCP_DELIVERY_URL", nil},
        {"RELEASE_NODE", "at_mcp_account_test_#{System.unique_integer([:positive])}@127.0.0.1"},
        {"RELEASE_DISTRIBUTION", "name"},
        {"RELEASE_COOKIE", Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)},
        {"AT_MCP_DIST_PORT", to_string(dist_port)},
        {"ERL_EPMD_PORT", to_string(epmd_port)},
        {"ERL_EPMD_ADDRESS", nil},
        {"ELIXIR_ERL_OPTIONS", nil}
      ] ++ endpoint_env ++ authorization_environment()

    # A release without this change's rel/ files starts a port mapper at
    # ERL_EPMD_PORT. Registered first so it runs last, after the release has
    # stopped: a mapper refuses to stop while a node is registered with it.
    [epmd] = Path.wildcard(Path.join(release, "erts-*/bin/epmd"))
    on_exit(fn -> System.cmd(epmd, ["-port", to_string(epmd_port), "-kill"]) end)

    # Register cleanup before launch so a failed readiness or assertion still
    # stops this uniquely named release, never an installed AtMcp service.
    on_exit(fn -> System.cmd(executable, ["stop"], env: env, stderr_to_stdout: true) end)
    {output, code} = System.cmd(executable, ["daemon"], env: env, stderr_to_stdout: true)
    assert code == 0, output
    await_ready(executable, env, 30)
    pid = daemon_pid(executable, env)

    on_exit(fn ->
      System.cmd(executable, ["stop"], env: env, stderr_to_stdout: true)
      await_stopped(pid, 50)
    end)

    rows = control(setup, ["status"], env)["accounts"]
    assert Enum.sort(Enum.map(rows, & &1["id"])) == ["alice", "bob", "carol"]
    assert Enum.all?(rows, &(&1["running"] and &1["ready"]))

    # The service listens on loopback alone, and only at its distribution
    # port and its MCP endpoint.
    assert listening_sockets(executable, env) |> Enum.sort() ==
             Enum.sort([{"127.0.0.1", dist_port}, {"127.0.0.1", mcp_port}])

    # No port mapper was started, and none was needed to reach the node.
    assert {:error, :econnrefused} = :gen_tcp.connect(~c"127.0.0.1", epmd_port, [], 1_000)

    # `remote` reaches it the same way `rpc` does.
    assert remote_output(executable, env, ~S[IO.puts("remote " <> System.pid())]) =~
             "remote #{pid}"

    assert daemon_pid(executable, env) == pid

    # A second installation of the same release, with its own port, node name,
    # endpoint, accounts and state, runs beside the first, and each one's
    # commands reach its own node.
    second_port = free_port()

    second_env =
      env
      |> List.keyreplace("AT_MCP_DIST_PORT", 0, {"AT_MCP_DIST_PORT", to_string(second_port)})
      |> List.keyreplace(
        "RELEASE_NODE",
        0,
        {"RELEASE_NODE", "at_mcp_account_second_#{System.unique_integer([:positive])}@127.0.0.1"}
      )
      |> List.keyreplace("AT_MCP_PORT", 0, {"AT_MCP_PORT", to_string(free_port())})
      |> List.keyreplace("AT_MCP_STATE_DIR", 0, {"AT_MCP_STATE_DIR", Path.join(root, "state-2")})
      |> List.keyreplace(
        "AT_MCP_ACCOUNTS_FILE",
        0,
        {"AT_MCP_ACCOUNTS_FILE", Path.join(root, "accounts-2.json")}
      )
      # `daemon` keeps its pipe and log under RELEASE_TMP, one per daemon.
      |> Kernel.++([{"RELEASE_TMP", Path.join(root, "tmp-2")}])

    on_exit(fn -> System.cmd(executable, ["stop"], env: second_env, stderr_to_stdout: true) end)
    {output, 0} = System.cmd(executable, ["daemon"], env: second_env, stderr_to_stdout: true)
    assert output == ""
    await_ready(executable, second_env, 50)
    second_pid = daemon_pid(executable, second_env)
    assert second_pid != pid
    assert daemon_pid(executable, env) == pid
    assert {"127.0.0.1", second_port} in listening_sockets(executable, second_env)
    {_, 0} = System.cmd(executable, ["stop"], env: second_env, stderr_to_stdout: true)
    await_stopped(second_pid, 50)
    assert daemon_pid(executable, env) == pid

    {output, 0} =
      command(
        setup,
        [
          "--file",
          file,
          "add",
          "dora",
          "--handle",
          "dora",
          "--service",
          "http://127.0.0.1:#{port}",
          "--password-stdin"
        ],
        "fixture-secret\n",
        env
      )

    refute output =~ "fixture-secret"
    refute Enum.any?(control(setup, ["status"], env)["accounts"], &(&1["id"] == "dora"))
    assert control(setup, ["reload"], env)["ok"]
    assert daemon_pid(executable, env) == pid
    assert row(setup, env, "dora")["ready"]

    assert control(setup, ["disconnect", "alice"], env)["ok"]

    {output, 0} =
      command(
        setup,
        ["--file", file, "update", "alice", "--password-stdin"],
        "rotated-fixture-secret\n",
        env
      )

    refute output =~ "fixture-secret"
    assert control(setup, ["reload"], env)["ok"]
    Agent.update(__MODULE__.Passwords, &Map.put(&1, "alice", ["rotated-fixture-secret"]))
    alice = row(setup, env, "alice")
    assert alice["disconnected"]
    refute alice["running"]
    refute alice["ready"]
    assert control(setup, ["reconnect", "alice"], env)["ok"]
    assert row(setup, env, "alice")["ready"]

    {output, 0} = command(setup, ["--file", file, "remove", "carol"], "", env)
    refute output =~ "fixture-secret"
    assert control(setup, ["reload"], env)["ok"]
    carol = row(setup, env, "carol")
    refute carol["configured"]
    refute carol["running"]
    refute carol["ready"]
    assert daemon_pid(executable, env) == pid
    assert row(setup, env, "bob")["ready"]

    {_output, 0} = System.cmd(executable, ["stop"], env: env, stderr_to_stdout: true)
    await_stopped(pid, 30)
    {output, status} = command(setup, ["status"], "", env)
    assert status != 0
    assert output =~ "Cannot reach the AtMcp service"
    refute output =~ "fixture-secret"
    refute output =~ "nodedown"
    refute output =~ "** ("
    {_, cookie} = List.keyfind(env, "RELEASE_COOKIE", 0)
    refute output =~ cookie
  end

  @tag skip: is_nil(System.get_env("TEST_ACCOUNT_RELEASE"))
  test "the distribution port is 4370 unless the environment file names another, and eval gets none" do
    release = System.fetch_env!("TEST_ACCOUNT_RELEASE") |> Path.expand()
    root = Path.join(System.tmp_dir!(), "at_mcp-dist-port-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    env_file = Path.join(root, "at_mcp.env")
    File.write!(env_file, "AT_MCP_DIST_PORT=4371\n")

    options = fn command, env ->
      [env_sh] = Path.wildcard(Path.join(release, "releases/*/env.sh"))

      {output, 0} =
        System.cmd("/bin/sh", ["-c", ~S[. "$0"; printf '%s' "${ELIXIR_ERL_OPTIONS:-}"], env_sh],
          env:
            [
              {"HOME", root},
              {"RELEASE_ROOT", release},
              {"RELEASE_NAME", "at_mcp"},
              {"RELEASE_COMMAND", command},
              {"RELEASE_COOKIE", "scratch-cookie"},
              {"AT_MCP_ENV_FILE", nil},
              {"AT_MCP_DIST_PORT", nil},
              {"ELIXIR_ERL_OPTIONS", nil}
            ] ++ env,
          stderr_to_stdout: true
        )

      output
    end

    for command <- ["start", "daemon", "rpc", "remote", "stop", "pid"] do
      assert options.(command, []) == "-kernel erl_epmd_node_listen_port 4370"

      assert options.(command, [{"AT_MCP_ENV_FILE", env_file}]) ==
               "-kernel erl_epmd_node_listen_port 4371"
    end

    # The first setting wins, so one inherited from another release's process
    # comes after this installation's own.
    assert options.("rpc", [{"ELIXIR_ERL_OPTIONS", "-kernel erl_epmd_node_listen_port 4380"}]) ==
             "-kernel erl_epmd_node_listen_port 4370 -kernel erl_epmd_node_listen_port 4380"

    assert options.("eval", [{"AT_MCP_ENV_FILE", env_file}]) == ""
  end

  defp control(setup, args, env) do
    {output, status} = command(setup, args, "", env)
    assert status == 0, output
    refute output =~ "fixture-secret"
    result = Jason.decode!(output)
    assert result["ok"], output
    result
  end

  defp row(setup, env, id),
    do: Enum.find(control(setup, ["status"], env)["accounts"], &(&1["id"] == id))

  # The address and port of every TCP socket the running release listens on.
  defp listening_sockets(executable, env) do
    expression = ~S"""
    for port <- Port.list(),
        Port.info(port, :name) == {:name, ~c"tcp_inet"},
        {:ok, flags} <- [:prim_inet.getstatus(port)],
        :listen in flags,
        {:ok, {ip, number}} when is_tuple(ip) <- [:inet.sockname(port)],
        do: IO.puts("listening #{:inet.ntoa(ip)} #{number}")
    """

    {output, 0} = System.cmd(executable, ["rpc", expression], env: env, stderr_to_stdout: true)

    sockets =
      for [_, ip, number] <- Regex.scan(~r/^listening (\S+) (\d+)$/m, output),
          do: {ip, String.to_integer(number)}

    assert sockets != [], output
    sockets
  end

  # A `remote` session's output once it has evaluated `input`. The session is
  # ended by stopping its own process: end of input in a remote shell halts
  # the node it is attached to, here the service.
  defp remote_output(executable, env, input) do
    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["remote"],
        env:
          Enum.map(env, fn {key, value} ->
            {String.to_charlist(key),
             if(is_nil(value), do: false, else: String.to_charlist(value))}
          end)
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    Port.command(port, input <> "\n")
    output = await_output(port, "", ~r/remote \d+\n/)
    System.cmd("kill", [to_string(os_pid)])
    assert_receive {^port, {:exit_status, _}}, 10_000
    output
  end

  defp await_output(port, output, pattern) do
    if output =~ pattern do
      output
    else
      receive do
        {^port, {:data, data}} -> await_output(port, output <> data, pattern)
        {^port, {:exit_status, status}} -> flunk("remote exited #{status}: " <> output)
      after
        20_000 -> flunk("remote printed nothing matching: " <> output)
      end
    end
  end

  defp daemon_pid(executable, env) do
    {output, 0} =
      System.cmd(executable, ["pid"], env: env, stderr_to_stdout: true)

    pid = String.trim(output)
    assert Regex.match?(~r/\A[0-9]+\z/, pid)
    pid
  end

  defp await_ready(_executable, _env, 0), do: flunk("disposable release did not become ready")

  defp await_ready(executable, env, attempts) do
    {output, code} =
      System.cmd(executable, ["rpc", "AtMcp.CLI.service_status()"],
        env: env,
        stderr_to_stdout: true
      )

    if code == 0 and output =~ ~s("ready":true) do
      :ok
    else
      Process.sleep(100)
      await_ready(executable, env, attempts - 1)
    end
  end

  defp await_stopped(pid, attempts) do
    case System.cmd("kill", ["-0", pid], stderr_to_stdout: true) do
      {_, code} when code != 0 ->
        :ok

      _ when attempts > 0 ->
        Process.sleep(100)
        await_stopped(pid, attempts - 1)

      _ ->
        flunk("disposable release did not stop")
    end
  end

  defp authorization_environment do
    System.get_env()
    |> Map.keys()
    |> Enum.filter(&(&1 in ["AT_MCP_HOST_TOKEN", "AT_MCP_HOST_TOKEN_FILE"]))
    |> Enum.map(&{&1, nil})
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  defp command(executable, args, input, env) do
    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: args,
        env:
          Enum.map([{"AT_MCP_ENV_FILE", nil} | env], fn {key, value} ->
            {String.to_charlist(key),
             if(is_nil(value), do: false, else: String.to_charlist(value))}
          end)
      ])

    if input != "", do: Port.command(port, input)
    collect(port, "")
  end

  defp collect(port, output) do
    receive do
      {^port, {:data, data}} -> collect(port, output <> data)
      {^port, {:exit_status, status}} -> {output, status}
    after
      20_000 ->
        Port.close(port)
        flunk("account release command did not finish")
    end
  end
end
