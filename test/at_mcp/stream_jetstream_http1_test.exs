defmodule AtMcp.Stream.Jetstream.HTTP1Test do
  @moduledoc """
  A TLS server that offers HTTP/2 by ALPN, as Jetstream's public instances
  do, and serves a WebSocket only over HTTP/1.1. The transport must open the
  WebSocket and read a frame from it.
  """
  use ExUnit.Case, async: true

  alias AtMcp.Stream.Jetstream.HTTP1

  defmodule Socket do
    @moduledoc false
    def init(req, state), do: {:cowboy_websocket, req, state}
    def websocket_init(state), do: {[{:text, ~s({"kind":"hello"})}], state}
    def websocket_handle(_frame, state), do: {[], state}
    def websocket_info(_info, state), do: {[], state}
  end

  setup do
    # An EC key signed with SHA-256, which TLS 1.3 accepts.
    key = [key: {:namedCurve, :secp256r1}, digest: :sha256]

    %{server_config: server} =
      :public_key.pkix_test_data(%{
        server_chain: %{root: key, peer: key},
        client_chain: %{root: key, peer: key}
      })

    ref = :"jetstream_tls_#{System.unique_integer([:positive])}"
    dispatch = :cowboy_router.compile([{:_, [{"/subscribe", Socket, nil}]}])

    {:ok, _} =
      :cowboy.start_tls(
        ref,
        [port: 0, ip: {127, 0, 0, 1}, certs_keys: [%{cert: server[:cert], key: server[:key]}]],
        %{env: %{dispatch: dispatch}}
      )

    on_exit(fn -> :cowboy.stop_listener(ref) end)
    %{port: :ranch.get_port(ref)}
  end

  test "opens a WebSocket over HTTP/1.1 from a server that prefers HTTP/2", %{port: port} do
    url = "wss://127.0.0.1:#{port}/subscribe?wantedCollections=app.bsky.feed.post"

    assert {:ok, conn} = HTTP1.connect(url, tls_opts: [verify: :verify_none])
    # Over HTTP/1.1 the whole connection becomes the WebSocket.
    assert :gun.info(conn.pid).protocol == :ws

    frames =
      receive do
        message ->
          assert {:ok, _conn, frames} = HTTP1.stream(conn, message)
          frames
      after
        2_000 -> flunk("no frame")
      end

    assert frames == [{:text, ~s({"kind":"hello"})}]
    assert :ok = HTTP1.close(conn)
  end
end
