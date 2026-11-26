defmodule AtMcp.ProtoRuneHTTP do
  @moduledoc """
  proto_rune's HTTP adapter for AtMcp: proto_rune's Req adapter, with Req's
  own retries turned off for a request that carries a DPoP proof.

  Req retries a GET that answered 408, 429 or 5xx, and it sends the same
  headers again. A DPoP proof is good for one request (its `jti`), so the
  account's server refuses the repeat as a replayed proof, and a passing 502
  became a refused credential. A DPoP request is sent once; its failure is
  classified as it is (`AtMcp.Effects.ProtoRune`), and a refused token is
  recovered by a fresh session and one more request with a new proof, as
  `AtMcp.Effects` recovers any refused credential. Requests with a bearer
  token (app passwords, service auth) keep Req's retries.

  Delete when proto_rune builds a fresh proof per attempt.
  """

  @behaviour ProtoRune.HTTPClient.Adapter

  @impl true
  def request(method, url, opts) do
    opts = if dpop?(opts), do: Keyword.put(opts, :retry, false), else: opts
    ProtoRune.HTTPClient.Adapters.Req.request(method, url, opts)
  end

  defp dpop?(opts) do
    Enum.any?(Keyword.get(opts, :headers, []), fn {name, _} ->
      String.downcase(to_string(name)) == "dpop"
    end)
  end
end
