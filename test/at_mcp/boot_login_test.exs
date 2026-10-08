defmodule AtMcp.BootLoginTest do
  use ExUnit.Case, async: false

  # A PDS that does not answer the boot login within the request timeout must
  # not fail the boot: a service under launchd would be restarted into the same
  # outage. These boots run in their own VM with the configuration a shared
  # installation has, an accounts file and a delivery URL, against a PDS fixture
  # whose answers the test chooses.

  @tag :tmp_dir
  test "a login the PDS does not answer keeps the application up and is retried until it succeeds",
       %{tmp_dir: dir} do
    script =
      fixture(dir, :timeout_once) <>
        """
        {:ok, _} = Application.ensure_all_started(:at_mcp)
        supervisor = Process.whereis(AtMcp.Supervisor)
        true = is_pid(supervisor)
        true = is_function(AtMcp.Deliver.callback(), 1)

        # Up, and honest about it: configured, not running, not ready.
        {:ok, [%{id: "grug", configured: true, running: false, ready: false}]} =
          AtMcp.Accounts.status()

        false = BootCheck.ready?()
        %{"running" => false} = BootCheck.identity("grug")["runtime"]
        1 = BootPDS.logins()

        :ok =
          BootCheck.eventually(supervisor, fn ->
            match?({:ok, [%{running: true, ready: true}]}, AtMcp.Accounts.status())
          end)

        true = BootCheck.ready?()
        %{"running" => true, "ready" => true} = BootCheck.identity("grug")["runtime"]
        2 = BootPDS.logins()
        IO.puts("boot-survived-unanswered-login")
        """

    output = run(script)
    assert output =~ "boot-survived-unanswered-login"
    assert output =~ "AtMcp account grug: login did not complete"
  end

  @tag :tmp_dir
  test "a refused credential keeps the application up, is reported, and is not retried",
       %{tmp_dir: dir} do
    script =
      fixture(dir, :refuse) <>
        """
        {:ok, _} = Application.ensure_all_started(:at_mcp)

        {:ok, [%{id: "grug", configured: true, running: false, ready: false}]} =
          AtMcp.Accounts.status()

        false = BootCheck.ready?()
        %{"running" => false} = BootCheck.identity("grug")["runtime"]
        1 = BootPDS.logins()
        # Past the first two windows a retried login would have used.
        Process.sleep(3_500)
        1 = BootPDS.logins()
        {:ok, [%{running: false}]} = AtMcp.Accounts.status()
        IO.puts("refused-login-reported-not-retried")
        """

    output = run(script)
    assert output =~ "refused-login-reported-not-retried"
    assert output =~ "AtMcp account grug: login refused"
  end

  defp fixture(dir, mode) do
    """
    {:ok, _} = Application.ensure_all_started(:plug_cowboy)

    defmodule BootPDS do
      import Plug.Conn
      def init(opts), do: opts

      def start(mode), do: Agent.start_link(fn -> %{mode: mode, logins: 0} end, name: __MODULE__)
      def logins, do: Agent.get(__MODULE__, & &1.logins)

      def call(conn, _) do
        {:ok, body, conn} = read_body(conn)
        handle = Jason.decode!(body)["identifier"]

        {mode, n} =
          Agent.get_and_update(__MODULE__, fn s ->
            {{s.mode, s.logins + 1}, %{s | logins: s.logins + 1}}
          end)

        case mode do
          :timeout_once when n == 1 ->
            # Never answered: the client gives up at its receive timeout, so
            # the first login is lost, not refused.
            Process.sleep(:infinity)

          :timeout_once ->
            session(conn, handle)

          :refuse ->
            body =
              Jason.encode!(%{
                error: "AuthenticationRequired",
                message: "Invalid identifier or password"
              })

            conn |> put_resp_content_type("application/json") |> send_resp(401, body)
        end
      end

      defp session(conn, handle) do
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

    defmodule BootCheck do
      def ready? do
        ExUnit.CaptureIO.capture_io(fn -> AtMcp.CLI.service_status() end)
        |> Jason.decode!()
        |> Map.fetch!("ready")
      end

      def identity(id) do
        port = :ranch.get_port(:at_mcp_control_http)
        %{"identities" => identities} = Req.get!("http://127.0.0.1:\#{port}/identities").body
        Enum.find(identities, &(&1["id"] == id))
      end

      # The application stays up the whole time; it is not restarted into shape.
      def eventually(supervisor, fun, n \\\\ 600)
      def eventually(_supervisor, _fun, 0), do: raise("did not happen in time")

      def eventually(supervisor, fun, n) do
        true = Process.whereis(AtMcp.Supervisor) == supervisor
        true = Enum.any?(Application.started_applications(), fn {app, _, _} -> app == :at_mcp end)

        if fun.() do
          :ok
        else
          Process.sleep(10)
          eventually(supervisor, fun, n - 1)
        end
      end
    end

    {:ok, _} = BootPDS.start(#{inspect(mode)})
    {:ok, _} = Plug.Cowboy.http(BootPDS, [], port: 0, ref: :boot_pds)
    accounts = Path.join(#{inspect(dir)}, "accounts.json")

    File.write!(
      accounts,
      Jason.encode!(%{
        "version" => 1,
        "accounts" => [
          %{
            "id" => "grug",
            "handle" => "grug",
            "did" => "did:plc:grug",
            "password" => "fixture-password",
            "service" => "http://127.0.0.1:" <> Integer.to_string(:ranch.get_port(:boot_pds))
          }
        ]
      })
    )

    File.chmod!(accounts, 0o600)
    Application.put_env(:at_mcp, :accounts_file, accounts, persistent: true)
    # A shared installation delivers to a host and collects notifications, so a
    # boot that survives the login must also survive the bridge attaching after it.
    Application.put_env(:at_mcp, :delivery, [url: "http://127.0.0.1:9/inbound", token: "fixture"],
      persistent: true
    )

    Application.put_env(:at_mcp, :notifications_enabled, true, persistent: true)
    # A request the PDS does not answer in time is a timeout at the client.
    # The unanswered login is never answered, so this bound only has to exceed
    # how long a loaded machine takes to carry an answered one. A bound near
    # the fixture's own handling time turns an answered login into a lost one.
    Application.put_env(:req, :default_options, receive_timeout: 2_000)
    Application.load(:at_mcp)
    Application.put_env(:at_mcp, :inbound_state_dir, #{inspect(dir)})
    """
  end

  defp run(script) do
    env =
      for key <- [
            "AT_MCP_ACCOUNTS_FILE",
            "AT_MCP_HANDLE",
            "AT_MCP_APP_PASSWORD",
            "AT_MCP_DELIVERY_URL",
            "AT_MCP_DELIVERY_TOKEN_FILE",
            "AT_MCP_JETSTREAM",
            "AT_MCP_NOTIFICATIONS",
            "AT_MCP_ENV_FILE"
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
