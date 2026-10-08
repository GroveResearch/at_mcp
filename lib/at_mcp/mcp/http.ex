defmodule AtMcp.MCP.HTTP do
  @moduledoc """
  One loopback MCP endpoint for every identity an installation holds.

  `Authorization: Bearer <grant>` resolves through `AtMcp.Grants` to exactly one
  account, and the grant's scope bounds how much of the tool surface the caller
  reaches. A grant issued for one identity cannot reach another, whatever the
  caller asks for.

  A request that presents no grant is refused with `401`; the credential, not
  the address, is what separates two clients.

  `x-kite-account-did` confirms and never selects. A host that was told a DID
  may assert it, and a grant naming a different account is refused with `409` —
  a binding check against a stale or mistyped configuration.

  `AtMcp.AccountConfig.descriptor/3` generates a client's configuration, carrying
  the shared URL and a grant together.

  ## Turns

  All clients share the durable account quota. Activity policy belongs to hosts.
  """
  @behaviour Plug
  import Plug.Conn

  # Room for everything in a request besides the post's images and text: alt
  # text, the other arguments and the JSON-RPC envelope.
  @envelope_bytes 1_000_000

  @doc """
  The largest request body the endpoint reads, in bytes.

  It is derived from the largest request a tool legitimately takes: a post
  with as many images as this network's lexicon allows, each at its largest,
  base64-encoded because JSON carries them as text, and the longest text the
  lexicon allows at its longest JSON encoding (six bytes per byte, `\\u0000`),
  plus `@envelope_bytes` for the rest. The body is read before ExMCP sees it so
  the tool name can be checked against the grant's scope, and handed on
  through `:raw_body` rather than read twice; ExMCP is given the same limit.
  """
  def body_limit do
    %{count: count, bytes: bytes} = AtMcp.Network.post_image_limits()
    %{bytes: text_bytes} = AtMcp.Network.post_limits()
    count * 4 * div(bytes + 2, 3) + 6 * text_bytes + @envelope_bytes
  end

  def init(opts) do
    port = Keyword.fetch!(opts, :port)
    body_limit = body_limit()

    %{
      port: port,
      body_limit: body_limit,
      mcp:
        ExMCP.HttpPlug.init(
          handler: AtMcp.MCP.Server,
          handler_opts: fn conn, _request ->
            [effects: conn.private.at_mcp_effects]
          end,
          server_info: AtMcp.MCP.Server.server_info(),
          handler_call_timeout: handler_call_timeout(),
          body_limit: body_limit,
          legacy_http_sse: false,
          cors_enabled: false,
          allowed_hosts: ["localhost", "127.0.0.1", "::1", "[::1]"],
          # `call/2` has already checked the Origin against the port this
          # request actually arrived on. See `same_origin/1`.
          allowed_origins: :any
        )
    }
  end

  # The handler's own work after the account answers: building the summary and
  # validating it against the tool's output schema, which ExMCP bounds at
  # 100 ms by default. Three seconds is room for a loaded machine.
  @result_margin_ms 3_000

  @doc """
  How long the endpoint waits for a tool call, in milliseconds.

  ExMCP abandons a call that outlives this and answers with a bare JSON-RPC
  error, which says nothing about a write it abandoned. Every account call has
  answered by `AtMcp.Effects.answered_within/0`, and the endpoint waits that
  long plus `@result_margin_ms` for the handler to turn the answer into a tool
  result, so every call is answered by AtMcp, in AtMcp's vocabulary, before
  ExMCP gives up on it.
  """
  def handler_call_timeout, do: AtMcp.Effects.answered_within() + @result_margin_ms

  def call(conn, opts) do
    with :ok <- same_origin(conn),
         {:ok, account, scope} <- grant(conn),
         {:ok, effects} <- effects(account),
         :ok <- confirmed_binding(conn, effects) do
      conn |> put_private(:at_mcp_effects, effects) |> authorize(scope, opts)
    else
      {:error, status, body} -> json(conn, status, body)
    end
  catch
    :exit, _ -> json(conn, 503, %{error: "account_unavailable"})
  end

  # AtMcp checks the Origin itself rather than handing ExMCP an allowlist, because
  # an allowlist is built when the plug is initialized — before the listener has
  # bound — so it is wrong by exactly the amount the configured port differs from
  # the real one, which is all of it when the port is ephemeral. `conn.port` is
  # the port this request actually arrived on.
  #
  # Only this endpoint's own loopback origin passes, which is what protects it
  # from a page in a browser on this machine reaching it.
  defp same_origin(conn) do
    case get_req_header(conn, "origin") do
      [] ->
        :ok

      [origin] ->
        uri = URI.parse(origin)

        if uri.scheme == "http" and uri.host in ["localhost", "127.0.0.1", "::1"] and
             uri.port == conn.port,
           do: :ok,
           else: {:error, 403, %{error: "origin_not_allowed"}}

      _ ->
        {:error, 403, %{error: "origin_not_allowed"}}
    end
  end

  # The credential, and nothing else, says which identity this is.
  defp grant(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] when token != "" ->
        case AtMcp.Grants.authorize(token) do
          {:ok, account, scope} -> {:ok, account, scope}
          {:error, :grants_unreadable} -> {:error, 503, %{error: "grants_unreadable"}}
          {:error, _} -> {:error, 401, %{error: "unknown_grant"}}
        end

      [] ->
        {:error, 401, %{error: "grant_required"}}

      _ ->
        {:error, 401, %{error: "invalid_credential"}}
    end
  end

  defp effects(account) do
    case AtMcp.Identity.effects_name(account) do
      nil -> {:error, 503, %{error: "account_unavailable"}}
      effects -> {:ok, effects}
    end
  end

  defp confirmed_binding(conn, effects) do
    case get_req_header(conn, "x-kite-account-did") do
      [] ->
        :ok

      [did] when did != "" ->
        if AtMcp.Effects.expected_did(effects) == did,
          do: :ok,
          else: {:error, 409, %{error: "account_identity_mismatch"}}

      _ ->
        {:error, 400, %{error: "invalid_account_binding"}}
    end
  end

  defp authorize(%{method: "POST"} = conn, scope, opts) do
    case read_body(conn, length: opts.body_limit, read_length: opts.body_limit) do
      {:ok, body, conn} ->
        case requested_tool(body) do
          {:ok, tool} ->
            if AtMcp.Grants.permits_scope?(scope, tool),
              do: dispatch(assign(conn, :raw_body, body), opts),
              else: json(conn, 403, %{error: "out_of_scope", tool: tool})

          :none ->
            dispatch(assign(conn, :raw_body, body), opts)
        end

      _ ->
        json(conn, 413, %{error: "request_too_large"})
    end
  end

  defp authorize(conn, _scope, opts), do: dispatch(conn, opts)

  # Only `tools/call` names a tool. Anything else — initialize, tools/list, a
  # notification, a body ExMCP will reject itself — carries no scope question,
  # and ExMCP stays the one place that decides whether a body is well formed.
  defp requested_tool(body) do
    case Jason.decode(body) do
      {:ok, %{"method" => "tools/call", "params" => %{"name" => name}}} when is_binary(name) ->
        {:ok, name}

      _ ->
        :none
    end
  end

  defp dispatch(conn, opts), do: ExMCP.HttpPlug.call(conn, opts.mcp)

  defp json(conn, 401, body) do
    conn
    |> put_resp_header("www-authenticate", ~s(Bearer realm="at_mcp"))
    |> put_resp_content_type("application/json")
    |> send_resp(401, Jason.encode!(body))
  end

  defp json(conn, status, body),
    do:
      conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(body))
end
