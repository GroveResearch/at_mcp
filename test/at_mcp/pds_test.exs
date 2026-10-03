defmodule AtMcp.PDSTest do
  use ExUnit.Case, async: false

  defmodule PDS do
    import Plug.Conn
    def init(opts), do: opts

    def call(conn, opts) do
      {:ok, body, conn} = read_body(conn)

      count =
        Agent.get_and_update(opts[:calls], fn calls ->
          entry = %{
            path: conn.request_path,
            body: body,
            auth: get_req_header(conn, "authorization")
          }

          {Enum.count(calls, &(&1.path == conn.request_path)) + 1, calls ++ [entry]}
        end)

      {status, response} =
        case conn.request_path do
          "/xrpc/com.atproto.server.createSession" ->
            {200,
             %{
               accessJwt: "access-#{count}",
               refreshJwt: "refresh-#{count}",
               did: opts[:did],
               handle: opts[:handle]
             }}

          "/xrpc/com.atproto.server.refreshSession" ->
            {401, %{error: "ExpiredToken", message: "Refresh token expired"}}

          "/xrpc/app.bsky.actor.getProfile" ->
            if get_req_header(conn, "authorization") == ["Bearer access-1"] do
              {401, %{error: "ExpiredToken", message: "Access token expired"}}
            else
              {200, %{did: opts[:did], handle: opts[:handle], displayName: "Other PDS"}}
            end
        end

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(response))
    end
  end

  test "each configured PDS owns login, account calls and re-login after refresh fails" do
    for id <- ["pds-a", "pds-b"] do
      calls = start_supervised!({Agent, fn -> [] end}, id: {:calls, id})
      ref = {:pds, id}

      start_supervised!(
        Plug.Cowboy.child_spec(
          scheme: :http,
          plug: {PDS, calls: calls, did: "did:plc:#{id}", handle: "#{id}.invalid"},
          options: [port: 0, ip: {127, 0, 0, 1}, ref: ref]
        ),
        id: ref
      )

      service = "http://127.0.0.1:#{:ranch.get_port(ref)}"

      assert {:ok, _} =
               AtMcp.Identities.start_identity(
                 id: id,
                 handle: "#{id}.invalid",
                 password: "disposable-password",
                 service: service,
                 listen_enabled: false,
                 notifications_enabled: false
               )

      on_exit(fn -> AtMcp.Identities.stop_identity(id) end)

      effects = AtMcp.Identity.effects_name(id)
      assert {:ok, profile} = AtMcp.Effects.get_profile(effects, "#{id}.invalid")
      assert profile.did == "did:plc:#{id}"
      assert AtMcp.Effects.login_count(effects) == 2

      requests = Agent.get(calls, & &1)

      assert Enum.map(requests, & &1.path) == [
               "/xrpc/com.atproto.server.createSession",
               "/xrpc/app.bsky.actor.getProfile",
               "/xrpc/com.atproto.server.refreshSession",
               "/xrpc/com.atproto.server.createSession",
               "/xrpc/app.bsky.actor.getProfile"
             ]

      assert Enum.at(requests, 2).body == ""
      assert Enum.at(requests, 2).auth == ["Bearer refresh-1"]

      for request <- Enum.filter(requests, &String.ends_with?(&1.path, "createSession")) do
        assert Jason.decode!(request.body) == %{
                 "identifier" => "#{id}.invalid",
                 "password" => "disposable-password"
               }
      end
    end
  end
end
