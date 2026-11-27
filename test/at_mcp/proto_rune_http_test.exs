defmodule AtMcp.ProtoRuneHTTPTest do
  @moduledoc """
  A request carrying a DPoP proof is sent once: Req's retry of a 5xx GET
  would send the same proof again, which a server refuses as replayed. A
  bearer request keeps Req's retries.
  """
  use ExUnit.Case, async: false

  defmodule Flaky do
    # Answers 502 to the first request, 200 after.
    use Plug.Router
    plug(:match)
    plug(:dispatch)

    get "/xrpc/x" do
      n = :counters.get(:persistent_term.get(__MODULE__), 1)
      :counters.add(:persistent_term.get(__MODULE__), 1, 1)

      send(
        :persistent_term.get({__MODULE__, :owner}),
        {:seen, Plug.Conn.get_req_header(conn, "dpop")}
      )

      if n == 0, do: send_resp(conn, 502, "{}"), else: send_resp(conn, 200, "{}")
    end
  end

  setup do
    :persistent_term.put(Flaky, :counters.new(1, []))
    :persistent_term.put({Flaky, :owner}, self())
    {:ok, _} = Plug.Cowboy.http(Flaky, [], port: 0, ref: :flaky_http)
    on_exit(fn -> Plug.Cowboy.shutdown(:flaky_http) end)
    %{url: "http://localhost:#{:ranch.get_port(:flaky_http)}/xrpc/x"}
  end

  test "a DPoP request is not sent again after a 502", %{url: url} do
    assert {:ok, %{status: 502}} =
             AtMcp.ProtoRuneHTTP.request(:get, url,
               headers: [{"authorization", "DPoP t"}, {"dpop", "proof-1"}]
             )

    assert_received {:seen, ["proof-1"]}
    refute_receive {:seen, _}, 1_500
  end

  test "a bearer request is retried as Req retries it", %{url: url} do
    assert {:ok, %{status: 200}} =
             AtMcp.ProtoRuneHTTP.request(:get, url, headers: [{"authorization", "Bearer t"}])

    assert_received {:seen, []}
    assert_received {:seen, []}
  end
end
