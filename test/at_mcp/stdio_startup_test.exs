defmodule AtMcp.StdioStartupTest do
  use ExUnit.Case, async: false

  @secret "AT_MCP_STARTUP_SENTINEL_MUST_NOT_APPEAR"

  defmodule RefusingPDS do
    import Plug.Conn
    def init(opts), do: opts

    def call(conn, owner) do
      {:ok, body, conn} = read_body(conn)
      send(owner, {:login_attempt, conn.request_path, Jason.decode!(body)})

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        401,
        Jason.encode!(%{
          error: "AuthenticationRequired",
          message: "AT_MCP_STARTUP_SENTINEL_MUST_NOT_APPEAR"
        })
      )
    end
  end

  @tag timeout: 120_000
  test "cold startup failures explain recovery without protocol output or secrets" do
    root =
      Path.join(System.tmp_dir!(), "at_mcp-startup-errors-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    ref = __MODULE__.HTTP

    start_supervised!(
      {Plug.Cowboy,
       scheme: :http,
       plug: {RefusingPDS, self()},
       options: [port: 0, ip: {127, 0, 0, 1}, ref: ref]}
    )

    env = %{
      "PATH" => System.fetch_env!("PATH"),
      "HOME" => root,
      "LANG" => "en_US.UTF-8",
      "AT_MCP_HANDLE" => "fixture.test",
      "AT_MCP_APP_PASSWORD" => @secret,
      "AT_MCP_SERVICE" => "http://127.0.0.1:#{:ranch.get_port(ref)}"
    }

    fails(
      root,
      "missing-handle",
      "AtMcp requires AT_MCP_HANDLE",
      Map.delete(env, "AT_MCP_HANDLE")
    )

    fails(
      root,
      "missing-password",
      "AtMcp requires AT_MCP_APP_PASSWORD",
      Map.delete(env, "AT_MCP_APP_PASSWORD")
    )

    collision = Path.join(root, "collision")
    File.mkdir_p!(collision)
    {:ok, lock} = AtMcp.NativeLock.flock(Path.join(collision, ".owner.lock"), wait: false)

    try do
      fails(root, "occupied-state", "Another AtMcp process owns", env, state: collision)
    after
      :ok = AtMcp.NativeLock.unflock(lock)
    end

    unavailable = Path.join(root, "unavailable")
    File.write!(unavailable, "a file cannot contain state")
    fails(root, "unavailable-state", "Check AT_MCP_STATE_DIR", env, state: unavailable)

    for filename <- ["inbound.term", "write-quota.json"] do
      damaged = Path.join(root, String.replace(filename, ".", "-"))
      File.mkdir_p!(damaged)
      path = Path.join(damaged, filename)
      File.write!(path, @secret)
      fails(root, "damaged-" <> filename, "restore a known-good backup", env, state: damaged)
      assert File.read!(path) == @secret
    end

    fails(
      root,
      "login-refused",
      "Check AT_MCP_HANDLE, AT_MCP_APP_PASSWORD, and AT_MCP_SERVICE",
      env
    )

    assert_received {:login_attempt, "/xrpc/com.atproto.server.createSession",
                     %{"password" => @secret}}

    fails(
      root,
      "dependency-refused",
      "AtMcp dependency at_mcp_startup_fixture could not start",
      env,
      prefix: """
      defmodule BrokenStartupDependency do
        def start(_, _), do: {:error, System.fetch_env!("AT_MCP_APP_PASSWORD")}
      end
      :ok = Application.load(:at_mcp)
      {:ok, spec} = :application.get_all_key(:at_mcp)
      :ok = Application.unload(:at_mcp)
      :ok = :application.load({:application, :at_mcp_startup_fixture,
        [description: ~c"fixture", vsn: ~c"0", modules: [], registered: [],
         applications: [:kernel, :stdlib], mod: {BrokenStartupDependency, []}]})
      :ok = :application.load({:application, :at_mcp,
        Keyword.update!(spec, :applications, &[:at_mcp_startup_fixture | &1])})
      """
    )
  end

  defp fails(root, name, expected, env, opts \\ []) do
    stderr = Path.join(root, name <> ".stderr")

    env =
      env
      |> Map.put("AT_MCP_STATE_DIR", Keyword.get(opts, :state, Path.join(root, name)))
      |> Map.put("TEST_STDERR", stderr)

    environment =
      Enum.map(System.get_env(), fn {key, _} -> {String.to_charlist(key), false} end) ++
        Enum.map(env, fn {key, value} -> {String.to_charlist(key), String.to_charlist(value)} end)

    paths = Enum.flat_map(:code.get_path(), fn path -> ["-pa", to_string(path)] end)

    code =
      Keyword.get(opts, :prefix, "") <>
        "\n" <> AtMcp.Test.Settings.from_environment() <> "AtMcp.Stdio.run()"

    # The shell only redirects independent streams and immediately execs the
    # cold VM. Arguments remain separate; no source or path is interpolated.
    port =
      Port.open({:spawn_executable, ~c"/bin/sh"}, [
        :binary,
        :exit_status,
        :use_stdio,
        args: [
          "-c",
          "exec \"$@\" </dev/null 2>\"$TEST_STDERR\"",
          "at_mcp-startup",
          System.find_executable("elixir") | paths ++ ["-e", code]
        ],
        env: environment
      ])

    {:os_pid, pid} = Port.info(port, :os_pid)

    try do
      {stdout, status} = collect(port, [], System.monotonic_time(:millisecond) + 20_000)
      assert status != 0, name
      assert stdout == "", name <> ": unexpected protocol output"
      error = File.read!(stderr)
      refute error =~ @secret, name <> ": secret leaked"
      assert error =~ expected, name <> ": missing recovery diagnostic"
    after
      if Port.info(port) do
        System.cmd("/bin/kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)
        Port.close(port)
      end
    end
  end

  defp collect(port, chunks, deadline) do
    receive do
      {^port, {:data, data}} ->
        collect(port, [data | chunks], deadline)

      {^port, {:exit_status, status}} ->
        {chunks |> Enum.reverse() |> IO.iodata_to_binary(), status}
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        flunk("cold startup did not terminate")
    end
  end
end
