defmodule AtMcp.BackendFailureTest do
  use ExUnit.Case, async: false

  alias AtMcp.Effects.Failure
  alias AtMcp.Effects.ProtoRune, as: Backend

  # The adapter is the only place that knows what its client library's errors
  # mean, so this is where the translation is checked: through a real call, not
  # by calling a private function.
  defmodule HTTP do
    def request(_method, url, _opts) do
      case Application.fetch_env!(:at_mcp, :backend_failure_mode) do
        {:status, status, reason, message} ->
          {:ok,
           %Req.Response{
             status: status,
             headers: %{},
             body: Jason.encode!(%{"error" => reason, "message" => message})
           }}

        :transport ->
          {:error, %Req.TransportError{reason: :timeout}}

        :ok ->
          {:ok, %Req.Response{status: 200, headers: %{}, body: Jason.encode!(%{"did" => url})}}
      end
    end
  end

  setup do
    previous = Application.get_env(:proto_rune, :http_client)
    Application.put_env(:proto_rune, :http_client, HTTP)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:proto_rune, :http_client, previous),
        else: Application.delete_env(:proto_rune, :http_client)

      Application.delete_env(:at_mcp, :backend_failure_mode)
    end)

    %{
      session: %ProtoRune.Atproto.Session{
        did: "did:plc:fixture",
        handle: "fixture.test",
        access_jwt: "jwt",
        refresh_jwt: "unused",
        service_url: "https://pds.invalid/xrpc"
      }
    }
  end

  defp mode(value), do: Application.put_env(:at_mcp, :backend_failure_mode, value)

  test "a service rejection is a refusal: the action did not happen", ctx do
    mode({:status, 400, "InvalidRequest", "Profile not found"})

    assert {:error, %Failure{kind: :refused, status: 400, message: message}} =
             Backend.get_profile(ctx.session, "missing.test")

    assert message =~ "Profile not found"
  end

  test "a refused credential is distinguishable, so a session can be recovered", ctx do
    mode({:status, 401, "ExpiredToken", "Token has expired"})

    assert {:error, %Failure{kind: :auth_refused}} = Backend.get_profile(ctx.session, "a.test")
  end

  test "a service outage and a lost response are both indeterminate", ctx do
    mode({:status, 503, "InternalServerError", "unavailable"})

    assert {:error, %Failure{kind: :indeterminate, status: 503}} =
             Backend.get_profile(ctx.session, "a.test")

    mode(:transport)
    assert {:error, %Failure{kind: :indeterminate}} = Backend.get_profile(ctx.session, "a.test")
  end

  test "no client library term reaches a caller", ctx do
    for failing <- [
          {:status, 400, "InvalidRequest", "bad"},
          {:status, 500, "Boom", "boom"},
          :transport
        ] do
      mode(failing)
      assert {:error, %Failure{} = failure} = Backend.get_profile(ctx.session, "a.test")
      refute is_struct(failure.message)
      assert is_nil(failure.message) or is_binary(failure.message)
    end
  end
end
