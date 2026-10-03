defmodule AtMcp.AccountBindingTest do
  @moduledoc """
  `x-kite-account-did` confirms and never selects.

  The header is checked against the account the grant resolved to, so a host
  configured with a stale DID is refused rather than served the wrong identity,
  and a caller that sends a DID it likes gets nothing for it.
  """
  use ExUnit.Case, async: false

  alias AtMcp.Test.Grant

  test "a DID the grant does not name is refused, whatever the caller sends" do
    start("bound", expected_did: "did:plc:bound")
    start("other", expected_did: "did:plc:other")

    bound = Grant.token("bound")

    assert status(bound, "did:plc:bound") == 200
    assert refused(bound, "did:plc:other") == %{"error" => "account_identity_mismatch"}

    # Nor does the header reach the other identity when the grant's own account
    # is not running: the credential is resolved first, and it names one account.
    assert refused(Grant.token("absent"), "did:plc:other") == %{"error" => "account_unavailable"}
  end

  test "an account with no fixed identity cannot be claimed as a bound one" do
    start("unbound", [])

    # No expected_did, so there is nothing a presented DID can be confirmed
    # against. An unconfirmable claim is refused rather than waved through.
    assert refused(Grant.token("unbound"), "did:plc:unbound") ==
             %{"error" => "account_identity_mismatch"}

    # Presenting nothing is fine; the grant already said which identity this is.
    assert status(Grant.token("unbound"), nil) == 200
  end

  test "a malformed binding header is refused before any account is reached" do
    start("malformed", expected_did: "did:plc:malformed")
    token = Grant.token("malformed")

    response =
      Req.post!(Grant.url(),
        headers: Grant.headers(token) ++ [{"x-kite-account-did", ""}],
        json: status_request(),
        retry: false
      )

    assert response.status == 400
    assert response.body == %{"error" => "invalid_account_binding"}
  end

  test "an identity whose owner is gone is unavailable, not mismatched" do
    # Registered so the endpoint finds an Effects name, but nothing answers it.
    # An endpoint that reported this as an identity mismatch would send an
    # operator to fix a descriptor that is correct.
    ghost =
      spawn(fn ->
        {:ok, _} =
          Registry.register(AtMcp.Identity.Registry, "ghost", %{
            effects: {:via, Registry, {AtMcp.Identity.Registry, {:effects, "ghost"}}}
          })

        receive do: (:stop -> :ok)
      end)

    on_exit(fn -> if Process.alive?(ghost), do: send(ghost, :stop) end)
    assert eventually(fn -> AtMcp.Identity.effects_name("ghost") != nil end)

    assert refused(Grant.token("ghost"), "did:plc:ghost") ==
             %{"error" => "account_unavailable"}
  end

  defp start(id, extra) do
    {:ok, _} =
      AtMcp.Identities.start_identity(
        [
          id: id,
          listen_enabled: false,
          backend: AtMcp.Test.MockBackend,
          backend_state: %{did: "did:plc:#{id}", mock: true}
        ] ++ extra
      )

    on_exit(fn -> AtMcp.Identities.stop_identity(id) end)
  end

  defp status(token, did) do
    Req.post!(Grant.url(),
      headers: Grant.session!(token) ++ binding_header(did),
      json: status_request(),
      retry: false
    ).status
  end

  defp refused(token, did) do
    Req.post!(Grant.url(),
      headers: Grant.headers(token) ++ binding_header(did),
      json: status_request(),
      retry: false
    ).body
  end

  defp binding_header(nil), do: []
  defp binding_header(did), do: [{"x-kite-account-did", did}]

  defp status_request,
    do: %{
      jsonrpc: "2.0",
      id: System.unique_integer([:positive]),
      method: "tools/call",
      params: %{name: "identity_status", arguments: %{}}
    }

  defp eventually(fun, attempts \\ 50)
  defp eventually(_, 0), do: false

  defp eventually(fun, n),
    do:
      if(fun.(),
        do: true,
        else:
          (
            Process.sleep(10)
            eventually(fun, n - 1)
          )
      )
end
