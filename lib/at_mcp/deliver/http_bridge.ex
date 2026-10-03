defmodule AtMcp.Deliver.HTTPBridge do
  @moduledoc """
  Cross-process HTTP delivery to a durable consumer.

  Enable with:

      export AT_MCP_DELIVERY_URL=http://127.0.0.1:4420/inbound
      export AT_MCP_DELIVERY_TOKEN_FILE="/absolute/private/path/consumer-token"
      # or AT_MCP_DELIVERY_TOKEN=...

  Registers a global `AtMcp.Deliver` callback that JSON-POSTs listen events.
  The receiver owns routing and must persist acceptance before returning 2xx.
  All other responses and transport failures leave the event in AtMcp's durable
  outbox for retry. Redirects are not acceptance and are never followed.
  The bridge sends the original matched DID and record URI, not an agent/session
  destination. Receivers must deduplicate that source fact across retries.

  ## What attaching requires

  A collector: account notification polling (the default) or the opt-in
  Jetstream stream. A delivery URL with neither is a configuration that can
  never deliver anything, so the application refuses to start on it rather
  than running silently.

  It does not require a logged-in identity. Whether an account is running is
  the account owner's business — `AtMcp.Accounts` retries a login the PDS did
  not answer and holds a disconnected one — so the callback is attached either
  way, and the outbox holds events until there is something to collect and
  deliver. The host may be offline too: failed HTTP delivery stays on disk for
  retry.

  ## Time limits

  Each POST ends inside the store's delivery deadline (`AtMcp.Deliver.timeout_ms/0`):
  waiting for a pooled connection, connecting and the whole response are each
  bounded, and their sum is below the deadline, so a slow consumer comes back
  as the bridge's own error instead of a killed delivery. Deliveries for
  different accounts run concurrently and share one connection pool per
  consumer origin (50 connections); a delivery that finds the pool exhausted
  fails after the pool timeout and is retried.
  """

  require Logger

  # A pooled connection is free within milliseconds unless 50 other accounts'
  # deliveries hold them all, and then waiting longer does not help.
  @pool_timeout_ms 1_000
  # Enough for a TCP and TLS handshake to a consumer across the internet.
  @connect_timeout_ms 2_000
  # How long a consumer has to persist the event and answer.
  @response_timeout_ms 5_000

  if @pool_timeout_ms + @connect_timeout_ms + @response_timeout_ms >= AtMcp.Deliver.timeout_ms() do
    raise CompileError,
      description: "HTTPBridge time limits must sum to less than AtMcp.Deliver.timeout_ms/0"
  end

  @doc """
  Install the Deliver callback when a delivery URL is configured.

  Returns `:ok`, `:skipped` when no URL is set, or
  `{:error, {:delivery_bridge_unready, [:no_inbound_collector]}}`.
  """
  def maybe_attach_from_env! do
    case System.get_env("AT_MCP_DELIVERY_URL") do
      url when is_binary(url) and url != "" ->
        if collecting?() do
          :ok = AtMcp.Deliver.set_callback(callback(url))
          Logger.info("AtMcp.Deliver.HTTPBridge attached → #{url}")
          :ok
        else
          error = {:error, {:delivery_bridge_unready, [:no_inbound_collector]}}
          Logger.error("AtMcp.Deliver.HTTPBridge refuse attach (fail-closed): #{inspect(error)}")
          error
        end

      _ ->
        :skipped
    end
  end

  # Inbound has two collectors, and either one is enough to attach. Jetstream is
  # Bluesky's; the notification poll goes through the account's own PDS and works
  # on any network, so a network without a firehose runs on the poll alone.
  defp collecting?, do: jetstream_enabled?() or notifications_enabled?()

  defp notifications_enabled? do
    case System.get_env("AT_MCP_NOTIFICATIONS") do
      "1" -> true
      "true" -> true
      "0" -> false
      "false" -> false
      _ -> Application.get_env(:at_mcp, :notifications_enabled, true)
    end
  end

  defp jetstream_enabled? do
    case System.get_env("AT_MCP_JETSTREAM") do
      "0" -> false
      "false" -> false
      "1" -> true
      "true" -> true
      _ -> Application.get_env(:at_mcp, :jetstream_enabled, false)
    end
  end

  @doc """
  The delivery callback registered for a durable HTTP consumer.

  The credential is read per delivery rather than captured here. Capturing it at
  attach meant a rotated receiver token 401ed every delivery until AtMcp restarted,
  and because nothing evicts a pending event, the outbox filled and collection
  paused.
  """
  def callback(url, opts \\ []) when is_binary(url) do
    fn event -> post_inbound(url, access_token(), event, opts) end
  end

  @doc false
  def access_token do
    cond do
      t = System.get_env("AT_MCP_DELIVERY_TOKEN") ->
        String.trim(t)

      path = System.get_env("AT_MCP_DELIVERY_TOKEN_FILE") ->
        path |> File.read!() |> String.trim()

      true ->
        ""
    end
  end

  @doc false
  def post_inbound(url, token, event, opts \\ []) when is_map(event) do
    # Which network this happened on. A host cannot derive it — a DID does not say
    # where it lives — and without it an inhabitant on delve.town is told it is on
    # Bluesky.
    event = Map.put(event, :network, %{name: AtMcp.Network.name(), label: AtMcp.Network.label()})

    body = Jason.encode!(stringify_keys(event))

    headers =
      [{"content-type", "application/json"}] ++
        if(token == "", do: [], else: [{"authorization", "Bearer " <> token}])

    response_timeout = Keyword.get(opts, :receive_timeout, @response_timeout_ms)

    case Req.post(url,
           body: body,
           headers: headers,
           finch: [
             pool_timeout: @pool_timeout_ms,
             conn_opts: [transport_opts: [timeout: @connect_timeout_ms]]
           ],
           receive_timeout: response_timeout,
           request_timeout: response_timeout,
           retry: false,
           redirect: false
         ) do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      {:ok, %{status: status}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e ->
      {:error, {:bridge_exception, Exception.message(e)}}
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), stringify_value(v)}
      {k, v} -> {k, stringify_value(v)}
    end)
  end

  defp stringify_value(v) when is_map(v), do: stringify_keys(v)
  defp stringify_value(v) when is_list(v), do: Enum.map(v, &stringify_value/1)
  defp stringify_value(v) when is_boolean(v) or is_nil(v), do: v
  defp stringify_value(v) when is_atom(v), do: Atom.to_string(v)
  defp stringify_value(v), do: v
end
