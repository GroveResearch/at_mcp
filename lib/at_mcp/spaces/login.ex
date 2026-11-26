defmodule AtMcp.Spaces.Login do
  @moduledoc """
  An account's OAuth session, approved by its own login key, as a proto_rune
  session every tool can use.

  The Spaces helper holds the session and its refresh token. This module asks
  it for the current access token and the session's DPoP key
  (`oauth.credentials`) and builds a `ProtoRune.Atproto.OAuth.Session`, which
  signs each request with a DPoP proof and retries once on a new DPoP nonce.

  - **Expiry:** the session keeps the expiry the helper gave. `expiring?/1`
    is true from #{30} seconds before it, and `AtMcp.Effects` then gets a
    fresh session before the next call, so no access token is used past
    that expiry.
  - **Refused tokens:** a request refused as an invalid token is an
    `auth_refused` failure, which `AtMcp.Effects` recovers by `refresh/1`
    (a forced refresh in the helper) and retries once.
  - **Re-login:** a loopback client's session lasts two weeks. When the
    helper cannot refresh it, it logs in again with the account's key, and
    says so in the log. Only a refusal of the key itself (a principal
    revoked the agent or replaced its key) ends in `auth_refused`, with a
    message saying so.
  """

  alias AtMcp.Effects.Failure
  alias AtMcp.Spaces.Helper
  alias ProtoRune.Atproto.OAuth.Session

  @margin_seconds 30

  @doc "Logs in with `opts[:key_file]` (and `:handle`, `:expected_did` or `:did`)."
  def login(opts) do
    did = opts[:did] || opts[:expected_did]

    # By DID when it is known: it resolves through the PLC directory, with no
    # handle lookup to go wrong.
    relogin = %{
      account: did || opts[:handle],
      keyFile: opts[:key_file],
      scope: opts[:scope] || AtMcp.Spaces.scope_for(did, opts[:service])
    }

    result =
      if is_binary(did) do
        Helper.call("oauth.credentials", %{did: did, relogin: relogin})
      else
        with {:ok, %{"did" => did}} <- Helper.call("oauth.login", relogin),
             do: Helper.call("oauth.credentials", %{did: did})
      end

    with {:ok, creds} <- result, do: {:ok, session(creds, opts[:handle])}
  end

  @doc "A fresh session for `stale`'s account: the helper refreshes first."
  def refresh(%Session{did: did, handle: handle}) do
    with {:ok, creds} <- credentials(did, refresh: true), do: {:ok, session(creds, handle)}
  end

  @doc """
  The helper's credentials for `did`, with the account's key to log in again
  if the session is lost, when the accounts file names one.
  """
  def credentials(did, opts \\ []) do
    params = %{did: did, refresh: Keyword.get(opts, :refresh, false)}

    params =
      case relogin_for(did) do
        nil -> params
        relogin -> Map.put(params, :relogin, relogin)
      end

    Helper.call("oauth.credentials", params)
  end

  defp relogin_for(did) do
    case AtMcp.AccountConfig.with_key(did) do
      {:ok, account} ->
        %{
          account: did,
          keyFile: account["key_file"],
          scope: AtMcp.Spaces.scope_for(did, account["service"])
        }

      _ ->
        path = AtMcp.Spaces.key_path(did)

        if File.exists?(path),
          do: %{account: did, keyFile: path, scope: AtMcp.Spaces.scope_for(did)},
          else: nil
    end
  end

  @doc "Whether `session` is an OAuth session at or near its expiry."
  def expiring?(%Session{expires_at: at}) when is_integer(at),
    do: System.system_time(:second) >= at - @margin_seconds

  def expiring?(_session), do: false

  @doc false
  def session(creds, handle) do
    jwk = creds["dpopJwk"]

    %Session{
      did: creds["did"],
      handle: handle,
      access_token: creds["accessToken"],
      token_type: "DPoP",
      scope: creds["scope"],
      expires_at: expires_at(creds["expiresAt"]),
      service_url: creds["serviceUrl"],
      issuer: creds["issuer"],
      dpop_key: Base.url_decode64!(jwk["d"], padding: false),
      dpop_jwk: Map.take(jwk, ["kty", "crv", "x", "y"])
    }
  end

  defp expires_at(nil), do: nil

  defp expires_at(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, at, _} -> DateTime.to_unix(at)
      _ -> nil
    end
  end

  @doc false
  def unknown_failure(reason), do: Failure.new(:indeterminate, message: inspect(reason))
end
