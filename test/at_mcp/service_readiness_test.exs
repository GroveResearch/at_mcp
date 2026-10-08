defmodule AtMcp.ServiceReadinessTest do
  use ExUnit.Case, async: false

  @tag :tmp_dir
  test "completed application startup is ready even with every account disconnected", %{
    tmp_dir: dir
  } do
    script =
      configured(dir) <>
        """
        Application.load(:at_mcp)
        Application.put_env(:at_mcp, :inbound_state_dir, #{inspect(dir)})
        {:ok, _} = Application.ensure_all_started(:at_mcp)
        first = ExUnit.CaptureIO.capture_io(fn -> AtMcp.CLI.service_status() end) |> Jason.decode!()
        true = first["ready"]
        :ok = Supervisor.terminate_child(AtMcp.Supervisor, AtMcp.WriteQuota)
        missing_quota = ExUnit.CaptureIO.capture_io(fn -> AtMcp.CLI.service_status() end) |> Jason.decode!()
        false = missing_quota["ready"]
        {:ok, _} = Supervisor.restart_child(AtMcp.Supervisor, AtMcp.WriteQuota)
        :ok = AtMcp.Accounts.disconnect("default")
        status = ExUnit.CaptureIO.capture_io(fn -> AtMcp.CLI.service_status() end) |> Jason.decode!()
        true = status["ready"]
        :ok = Application.stop(:at_mcp)
        stopped = ExUnit.CaptureIO.capture_io(fn -> AtMcp.CLI.service_status() end) |> Jason.decode!()
        false = stopped["ready"]
        IO.puts("ready-disconnected-stopped-verified")
        """

    assert run(script) =~ "ready-disconnected-stopped-verified"
  end

  @tag :tmp_dir
  test "an initialized account owner does not mean the application finished startup", %{
    tmp_dir: dir
  } do
    # The window is a PDS that takes a while to answer the boot login: the
    # owner exists as soon as the tree is up, and startup is not finished until
    # the configured account has been through it.
    script =
      configured(dir, 1_500) <>
        """
        Application.load(:at_mcp)
        Application.put_env(:at_mcp, :inbound_state_dir, #{inspect(dir)})
        boot = Task.async(fn -> Application.ensure_all_started(:at_mcp) end)
        Enum.reduce_while(1..200, nil, fn _, _ ->
          if Process.whereis(AtMcp.Accounts), do: {:halt, :ok}, else: (Process.sleep(5); {:cont, nil})
        end)
        true = is_pid(Process.whereis(AtMcp.Accounts))
        starting = ExUnit.CaptureIO.capture_io(fn -> AtMcp.CLI.service_status() end) |> Jason.decode!()
        false = starting["ready"]
        {:ok, _} = Task.await(boot, 10_000)
        finished = ExUnit.CaptureIO.capture_io(fn -> AtMcp.CLI.service_status() end) |> Jason.decode!()
        true = finished["ready"]
        IO.puts("owner-is-not-startup-verified")
        """

    assert run(script) =~ "owner-is-not-startup-verified"
  end

  @tag :tmp_dir
  test "a missing configured identity cannot report service readiness", %{tmp_dir: dir} do
    script =
      configured(dir) <>
        """
        Application.load(:at_mcp)
        Application.put_env(:at_mcp, :inbound_state_dir, #{inspect(dir)})
        {:ok, _} = Application.ensure_all_started(:at_mcp)
        true = is_pid(AtMcp.Identity.whereis("default"))
        :ok = AtMcp.Identities.stop_identity("default")
        [] = AtMcp.Identities.list_ids()
        true = is_pid(Process.whereis(AtMcp.Accounts))
        result = ExUnit.CaptureIO.capture_io(fn -> AtMcp.CLI.service_status() end) |> Jason.decode!()
        false = result["ready"]
        IO.puts("missing-configured-runtime-rejected")
        """

    assert run(script) =~ "missing-configured-runtime-rejected"
  end

  # An installation is configured one way: by its accounts file. Readiness is a
  # claim about the accounts that file names, so these boots need one.
  defp configured(dir, answer_after_ms \\ 0) do
    """
    {:ok, _} = Application.ensure_all_started(:plug_cowboy)

    defmodule ReadinessPDS do
      import Plug.Conn
      def init(opts), do: opts

      def call(conn, _) do
        {:ok, body, conn} = read_body(conn)
        handle = Jason.decode!(body)["identifier"]
        Process.sleep(#{answer_after_ms})

        body =
          Jason.encode!(%{
            did: "did:plc:" <> handle,
            handle: handle,
            accessJwt: "fixture",
            refreshJwt: "fixture"
          })

        conn |> put_resp_content_type("application/json") |> send_resp(200, body)
      end
    end

    {:ok, _} = Plug.Cowboy.http(ReadinessPDS, [], port: 0, ref: :readiness_pds)

    accounts = Path.join(#{inspect(dir)}, "accounts.json")

    File.write!(
      accounts,
      Jason.encode!(%{
        "version" => 1,
        "accounts" => [
          %{
            "id" => "default",
            "handle" => "default",
            "did" => "did:plc:default",
            "password" => "fixture-password",
            "service" => "http://127.0.0.1:" <> Integer.to_string(:ranch.get_port(:readiness_pds)),
            "mcp_port" => 4400
          }
        ]
      })
    )

    File.chmod!(accounts, 0o600)
    Application.put_env(:at_mcp, :accounts_file, accounts, persistent: true)
    """
  end

  defp run(script) do
    env =
      for key <- [
            "AT_MCP_ACCOUNTS_FILE",
            "AT_MCP_HANDLE",
            "AT_MCP_APP_PASSWORD",
            "AT_MCP_HANDLE_2",
            "AT_MCP_APP_PASSWORD_2",
            "AT_MCP_HOST_TOKEN",
            "AT_MCP_HOST_TOKEN_FILE",
            "AT_MCP_DELIVERY_URL",
            "AT_MCP_DELIVERY_TOKEN_FILE",
            "AT_MCP_JETSTREAM"
          ],
          do: {key, nil}

    {output, status} =
      System.cmd("mix", ["run", "--no-start", "-e", script],
        env: [{"MIX_ENV", "test"} | env],
        stderr_to_stdout: true
      )

    assert status == 0, output
    output
  end
end
