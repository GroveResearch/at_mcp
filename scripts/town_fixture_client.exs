# A single call from the disposable native Town test fixture. Invoke with
# MIX_ENV=test mix run scripts/town_fixture_client.exs and send one JSON object
# on stdin, then close stdin. The Node fixture must spawn asynchronously so
# its PDS/AppView event loop can keep serving requests.
#
# Required: pdsUrl, appviewUrl, appviewDid, did, accessJwt, action.
# Actions: get_own_profile; update_profile (updates); follow/block (subject);
# unfollow/unblock (uri). URLs must be loopback. No account is created here.
# The last stdout line beginning TOWN_FIXTURE_RESULT= is the JSON result.

defmodule TownFixtureClient do
  alias AtMcp.Effects.ProtoRune, as: Backend

  def run(input) do
    pds = loopback!(Map.fetch!(input, "pdsUrl"))
    appview = loopback!(Map.fetch!(input, "appviewUrl"))
    Application.put_env(:at_mcp, :network, :delve)

    Application.put_env(:at_mcp, :appview,
      service: Map.fetch!(input, "appviewDid") <> "#bsky_appview",
      url: xrpc(appview)
    )

    session = %ProtoRune.Atproto.Session{
      did: Map.fetch!(input, "did"),
      handle: Map.get(input, "handle", Map.fetch!(input, "did")),
      access_jwt: Map.fetch!(input, "accessJwt"),
      refresh_jwt: "fixture-does-not-refresh",
      service_url: xrpc(pds)
    }

    case Map.fetch!(input, "action") do
      "get_own_profile" -> Backend.get_own_profile(session)
      "update_profile" -> Backend.update_profile(session, updates(Map.fetch!(input, "updates")))
      "follow" -> Backend.follow(session, Map.fetch!(input, "subject"))
      "block" -> Backend.block(session, Map.fetch!(input, "subject"))
      "unfollow" -> remove(session, :unfollow, Map.fetch!(input, "uri"))
      "unblock" -> remove(session, :unblock, Map.fetch!(input, "uri"))
    end
  end

  defp remove(session, action, uri) do
    case Backend.prepare_undo(session, action, uri) do
      {:ok, {:unchanged, result}} -> {:ok, result}
      {:ok, prepared} -> Backend.undo(session, prepared)
      error -> error
    end
  end

  defp updates(input) do
    keys = %{
      "display_name" => :display_name,
      "description" => :description,
      "pronouns" => :pronouns,
      "website" => :website,
      "avatar" => :avatar,
      "banner" => :banner
    }

    Enum.map(input, fn {key, value} ->
      field = Map.fetch!(keys, key)

      if field in [:avatar, :banner] do
        {field,
         %{
           data: Base.decode64!(Map.fetch!(value, "data")),
           mime_type: Map.fetch!(value, "mime_type")
         }}
      else
        {field, value}
      end
    end)
  end

  defp loopback!(url) do
    uri = URI.parse(url)
    true = uri.scheme == "http" and uri.host in ["127.0.0.1", "localhost", "::1"]
    url
  end

  defp xrpc(url) do
    url = String.trim_trailing(url, "/")
    if String.ends_with?(url, "/xrpc"), do: url, else: url <> "/xrpc"
  end

  def result({:ok, value}), do: %{ok: true, value: value}

  def result({:error, %AtMcp.Effects.Failure{} = error}),
    do: %{ok: false, error: %{kind: error.kind, message: error.message}}

  def result({:error, _}), do: %{ok: false, error: %{kind: :unclassified}}
end

input = IO.read(:stdio, :eof) |> Jason.decode!()
result = input |> TownFixtureClient.run() |> TownFixtureClient.result()
IO.puts("TOWN_FIXTURE_RESULT=" <> Jason.encode!(result))
