defmodule AtMcp.MCP.SharedStdio do
  @moduledoc """
  Stdio tool connection to one identity of a running local AtMcp service.

  The identity is named by the grant in `AT_MCP_GRANT`, which is what the shared
  endpoint resolves. The `--did` argument is still checked against the identity
  the service actually serves, so a stale descriptor is refused rather than used;
  it selects nothing.
  """
  use ExMCP.Server.Handler

  @request_options [
    format: :map,
    retry_policy: false,
    http_stream_retry: :safe_only,
    retry_safe: false,
    max_mrtr_rounds: 0
  ]

  @doc "Serve standard streams until EOF, without starting or stopping the account owner."
  def run(url, expected_did, grant) do
    Logger.configure(level: :none)
    Process.flag(:trap_exit, true)

    with {:ok, _} <- Application.ensure_all_started(:ex_mcp),
         {:ok, client} <- connect(url, expected_did, grant) do
      try do
        case ExMCP.Server.Transport.start_server(
               __MODULE__,
               AtMcp.MCP.Server.server_info(),
               [],
               transport: :stdio,
               client: client
             ) do
          {:ok, server} ->
            receive do
              {:EXIT, ^server, :normal} ->
                :ok

              {:EXIT, ^server, _} ->
                fail()

              {:EXIT, ^client, _} ->
                GenServer.stop(server, :normal)
                fail()
            end

          _ ->
            fail()
        end
      after
        if Process.alive?(client), do: ExMCP.Client.stop(client)
      end
    else
      _ -> fail()
    end
  end

  defp fail do
    IO.puts(
      :stderr,
      "AtMcp shared connection unavailable. Check that the service is running, that AT_MCP_GRANT holds a current grant for this account, and that the account matches."
    )

    System.halt(1)
  end

  @doc false
  def connect(url, expected_did, grant) do
    with :ok <- validate_target(url, expected_did),
         :ok <- validate_grant(grant),
         {:ok, client} <-
           ExMCP.Client.start_link(
             transport: :http,
             url: url,
             headers: [
               {"authorization", "Bearer " <> grant},
               {"x-kite-account-did", expected_did}
             ],
             reconnect: false,
             retry_policy: [max_attempts: 1],
             conformance_mode: false
           ) do
      case request(client, "tools/call", %{"name" => "identity_status", "arguments" => %{}}) do
        {:ok, result} ->
          if identity?(result, expected_did) do
            {:ok, client}
          else
            ExMCP.Client.stop(client)
            {:error, :account_identity_mismatch}
          end

        _ ->
          ExMCP.Client.stop(client)
          {:error, :account_unavailable}
      end
    else
      # A target or grant this process can see is wrong is a configuration
      # problem, and saying "service unavailable" for it sends an operator to
      # restart something that is running.
      {:error, :invalid_connection} -> {:error, :invalid_connection}
      _ -> {:error, :account_unavailable}
    end
  end

  @doc false
  def validate_target(url, did) when is_binary(url) and is_binary(did) do
    uri = URI.parse(url)

    if uri.scheme == "http" and uri.host in ["127.0.0.1", "localhost", "::1"] and
         is_nil(uri.userinfo) and is_nil(uri.query) and is_nil(uri.fragment) and
         uri.path == "/mcp" and is_integer(uri.port) and uri.port in 1..65535 and
         String.valid?(did) and Regex.match?(~r/\Adid:[a-z0-9]+:[^\s]+\z/, did),
       do: :ok,
       else: {:error, :invalid_connection}
  rescue
    _ -> {:error, :invalid_connection}
  end

  def validate_target(_, _), do: {:error, :invalid_connection}

  @doc false
  def validate_grant(grant) when is_binary(grant) do
    # Refused here rather than on the wire, so a missing AT_MCP_GRANT reads as a
    # configuration problem instead of as an unavailable service.
    if String.trim(grant) != "" and String.valid?(grant) and
         not Regex.match?(~r/[^\x21-\x7e]/, grant),
       do: :ok,
       else: {:error, :invalid_connection}
  end

  def validate_grant(_), do: {:error, :invalid_connection}

  defp identity?(%{"content" => content} = result, did) do
    result["isError"] != true and
      Enum.any?(content, fn
        %{"type" => "text", "text" => text} ->
          case Jason.decode(text) do
            {:ok, %{"did" => ^did}} -> true
            _ -> false
          end

        _ ->
          false
      end)
  end

  defp identity?(_, _), do: false

  @impl true
  def init(opts), do: {:ok, %{client: Keyword.fetch!(opts, :client)}}

  # Modern server/discover reads these handler metadata callbacks, while
  # legacy initialize reads handle_initialize/2. Both expose tools only.
  @doc false
  def __server_capabilities__, do: %{tools: %{}}
  @doc false
  def __server_info__, do: AtMcp.MCP.Server.server_info()

  @impl true
  def handle_initialize(params, state) do
    {:ok,
     ExMCP.Protocol.Initialize.build_initialize_result(params, %{
       serverInfo: AtMcp.MCP.Server.server_info(),
       capabilities: %{tools: %{}}
     }), state}
  end

  @impl true
  def handle_list_tools(cursor, state) do
    params = if is_nil(cursor), do: %{}, else: %{"cursor" => cursor}

    case request(state.client, "tools/list", params) do
      {:ok, %{"tools" => tools} = result} -> {:ok, tools, result["nextCursor"], state}
      _ -> {:error, "AtMcp account service unavailable", state}
    end
  end

  @impl true
  def handle_call_tool(name, arguments, state) do
    case request(state.client, "tools/call", %{"name" => name, "arguments" => arguments}) do
      {:ok, result} ->
        {:ok, result, state}

      _ ->
        {:ok,
         %{
           isError: true,
           content: [
             %{
               type: "text",
               text:
                 "AtMcp could not confirm the upstream tool outcome. The operation may have completed. Inspect the account state before retrying a write."
             }
           ],
           structuredContent: %{code: "upstream_outcome_unknown", outcome: "unknown"}
         }, state}
    end
  end

  # One loopback HTTP round trip on top of the endpoint's own limit.
  @relay_margin_ms 5_000

  defp request(client, method, params) do
    # call_tool/4 has an independent header-mismatch retry. Use the pinned
    # client's request API to retain MCP framing without that tool reissue.
    # safe_only also forbids modern stream reissue for every tools/call.
    # The service answers every call before its endpoint gives up on it; this
    # relay waits `@relay_margin_ms` longer than that, so the answer it relays
    # is the service's own.
    timeout = AtMcp.MCP.HTTP.handler_call_timeout() + @relay_margin_ms

    ExMCP.Client.make_request(
      client,
      method,
      params,
      Keyword.put(@request_options, :timeout, timeout),
      timeout
    )
  rescue
    _ -> {:error, :upstream_unavailable}
  catch
    :exit, _ -> {:error, :upstream_unavailable}
  end
end
