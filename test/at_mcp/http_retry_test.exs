defmodule AtMcp.HTTPRetryTest do
  use ExUnit.Case, async: false

  defmodule RateLimited do
    use Plug.Router
    plug(:match)
    plug(:dispatch)

    get "/notifications" do
      send(conn.private.owner, :http_attempt)

      conn
      |> put_resp_header("retry-after", "0")
      |> send_resp(429, "rate limited")
    end

    def init(owner), do: owner

    def call(conn, owner) do
      super(Plug.Conn.put_private(conn, :owner, owner), [])
    end
  end

  test "Req owns the retries for an account read through ProtoRune" do
    adapter = Application.get_env(:proto_rune, :http_client)
    Application.put_env(:proto_rune, :http_client, ProtoRune.HTTPClient.Adapters.Req)

    on_exit(fn ->
      if adapter,
        do: Application.put_env(:proto_rune, :http_client, adapter),
        else: Application.delete_env(:proto_rune, :http_client)
    end)

    start_supervised!(
      Plug.Cowboy.child_spec(
        scheme: :http,
        plug: {RateLimited, self()},
        options: [ip: {127, 0, 0, 1}, port: 0, ref: __MODULE__]
      )
    )

    port = :ranch.get_port(__MODULE__)

    assert {:ok, %{status: 429}} =
             ProtoRune.HTTPClient.request(:get, "http://127.0.0.1:#{port}/notifications",
               rate_limit: false,
               retry_log_level: false
             )

    # Count actual requests on the wire, including retries inside the adapter.
    # Req allows the initial GET and three retries. A second loop around Req
    # multiplies those retries while leaving the final 429 response unchanged.
    assert count_attempts() == 4
  end

  defp count_attempts(total \\ 0) do
    receive do
      :http_attempt -> count_attempts(total + 1)
    after
      0 -> total
    end
  end
end
