defmodule AtMcp.ATProto.ServiceAuth do
  @moduledoc """
  Opt-in direct application GETs using a fresh, method-bound service token.

  The home session authorizes issuance only. The AppView receives only the
  returned service token, at the fixed endpoint paired with Network's audience.
  Tokens are not persisted or reused. Procedures never enter this module.
  This does not prove that an arbitrary provider permits token issuance.
  """
  alias AtMcp.ATProto.DSL
  alias AtMcp.Effects.Failure
  alias AtMcp.Network
  alias ProtoRune.Session
  alias ProtoRune.XRPC.Query

  def query(session, method, schema, params) do
    query = Query.new(method, from: schema, base_url: Network.appview_url())

    with {:ok, query} <- Query.add_params(query, params) do
      execute(session, query)
    end
  end

  @doc false
  def execute(session, query) do
    query = %{query | base_url: Network.appview_url()}

    with {:ok, token} <- issue(session, query.method),
         {:ok, body} <- get(to_string(query), %{"authorization" => "Bearer " <> token}, :appview) do
      {:ok, ProtoRune.Case.snakelize_enum(body)}
    end
  end

  defp issue(session, method) do
    url = Path.join(DSL.base_url(session), "com.atproto.server.getServiceAuth")
    params = %{aud: Network.appview_service(), lxm: method, exp: System.system_time(:second) + 60}

    with {:ok, headers, _session} <- Session.authorization_headers(session, "GET", url),
         {:ok, body} <- get(url <> "?" <> URI.encode_query(params), headers) do
      case body do
        %{"token" => token} when is_binary(token) ->
          home_credential =
            Enum.any?(headers, fn {key, value} ->
              String.downcase(to_string(key)) == "authorization" and value == "Bearer " <> token
            end)

          if not home_credential and byte_size(token) <= 16_384 and
               Regex.match?(~r/\A[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\z/, token) do
            {:ok, token}
          else
            refused("Home PDS returned an invalid service token; no AppView request was sent.")
          end

        _ ->
          refused("Home PDS did not return a service token; no AppView request was sent.")
      end
    end
  end

  # XRPC.Client cannot disable redirects per request, and HTTPClient consumes
  # :retry before passing options to Req. Use the existing Req dependency here
  # so neither credential can follow a redirect or trigger an implicit retry.
  defp get(url, headers, destination \\ :home) do
    options = [url: url, headers: headers, redirect: false, retry: false]

    case Req.get(options) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        {:ok, body}

      {:ok, %{status: status}} when status in 300..399 ->
        refused("Service-auth routing refused a redirect; no redirected request was sent.")

      {:ok, %{status: status} = response} when status >= 400 ->
        body = if is_map(response.body), do: response.body, else: %{}
        body = Map.put_new(body, "error", "ServiceAuthHttpError")
        error = ProtoRune.XRPC.Error.from(%{response | body: body})

        context =
          if destination == :home,
            do: "Home PDS service-token issuance failed",
            else: "Direct AppView read failed"

        error = %{error | message: context <> ": " <> (error.message || to_string(error.reason))}

        if destination == :appview do
          {:error,
           Failure.new(if(status < 500, do: :refused, else: :indeterminate),
             status: status,
             message: error.message,
             detail: error.reason
           )}
        else
          {:error, error}
        end

      {:ok, _} ->
        refused("Service-auth routing received an invalid response.")

      {:error, error} ->
        {:error, error}
    end
  end

  defp refused(message), do: {:error, Failure.new(:refused, message: message)}
end
