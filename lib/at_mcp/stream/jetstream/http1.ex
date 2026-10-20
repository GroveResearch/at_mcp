defmodule AtMcp.Stream.Jetstream.HTTP1 do
  @moduledoc """
  ProtoRune's gun transport, made to speak HTTP/1.1.

  ProtoRune 0.6's `ProtoRune.Firehose.Transport.Gun` opens its TLS connection
  with gun's default protocols, so ALPN settles on HTTP/2 wherever the server
  offers it. Jetstream's public instances do, and answer a WebSocket upgrade
  over HTTP/2 with 400: the collector reconnects forever and never receives an
  event. A WebSocket is an HTTP/1.1 upgrade, so this transport opens the
  connection with `protocols: [:http]` and hands everything after the upgrade
  to ProtoRune's module, whose connection struct it returns.

  Retires when AtMcp moves to ProtoRune 0.7, whose Mint transport asks for
  HTTP/1.1 itself (decisions.md, Dependencies).

  Options: `:timeout` (connect and upgrade, default 5 s) and `:tls_opts`
  (passed to gun, for a test server's certificate).
  """

  @behaviour ProtoRune.Firehose.Transport

  alias ProtoRune.Firehose.Transport.Gun

  @impl true
  def connect(url, opts) do
    uri = URI.parse(url)
    timeout = Keyword.get(opts, :timeout, 5_000)
    secure? = uri.scheme != "ws"
    port = uri.port || if(secure?, do: 443, else: 80)
    path = if uri.query, do: "#{uri.path}?#{uri.query}", else: uri.path

    gun_opts = %{retry: 0, connect_timeout: timeout, protocols: [:http]}

    gun_opts =
      if secure?,
        do: Map.merge(gun_opts, %{transport: :tls, tls_opts: Keyword.get(opts, :tls_opts, [])}),
        else: gun_opts

    with {:ok, pid} <- :gun.open(String.to_charlist(uri.host), port, gun_opts) do
      case upgrade(pid, path, timeout) do
        {:ok, conn} ->
          {:ok, conn}

        {:error, _} = error ->
          :gun.close(pid)
          error
      end
    end
  end

  defp upgrade(pid, path, timeout) do
    with {:ok, _protocol} <- :gun.await_up(pid, timeout) do
      monitor_ref = Process.monitor(pid)
      stream_ref = :gun.ws_upgrade(pid, path)

      receive do
        {:gun_upgrade, ^pid, ^stream_ref, ["websocket"], _headers} ->
          {:ok, %Gun{pid: pid, stream_ref: stream_ref, monitor_ref: monitor_ref}}

        {:gun_response, ^pid, ^stream_ref, _fin, status, _headers} ->
          Process.demonitor(monitor_ref, [:flush])
          {:error, {:ws_upgrade_failed, status}}

        {:gun_error, ^pid, ^stream_ref, reason} ->
          Process.demonitor(monitor_ref, [:flush])
          {:error, reason}

        {:gun_error, ^pid, reason} ->
          Process.demonitor(monitor_ref, [:flush])
          {:error, reason}

        {:DOWN, ^monitor_ref, :process, ^pid, reason} ->
          {:error, reason}
      after
        timeout ->
          Process.demonitor(monitor_ref, [:flush])
          {:error, :timeout}
      end
    end
  end

  @impl true
  defdelegate stream(conn, message), to: Gun

  @impl true
  defdelegate close(conn), to: Gun
end
