defmodule AtMcp.Test.Grant do
  @moduledoc """
  Grants for tests, against the one shared endpoint.

  Every test that talks to `/mcp` presents a credential, and this is the one
  place that issues one and the one place that revokes it. Tokens are issued
  through `AtMcp.Grants` rather than by writing the grants file, so a test cannot
  hold a credential the running endpoint would not accept.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  @doc "A grant token for `account`, revoked when the test ends."
  def token(account, scope \\ :manage) do
    {:ok, grant} = AtMcp.Grants.issue(account, scope: scope)
    on_exit(fn -> AtMcp.Grants.revoke(grant.token) end)
    grant.token
  end

  @doc "The shared endpoint's base URL, from the listener that is actually bound."
  def base, do: "http://127.0.0.1:#{:ranch.get_port(:at_mcp_http)}"

  @doc "The shared endpoint's MCP URL."
  def url, do: base() <> "/mcp"

  @doc "Request headers carrying one grant."
  def headers(token), do: [{"authorization", "Bearer " <> token}]

  @doc """
  Headers for an initialized Streamable HTTP session, with no ExMCP client.

  Ordinary JSON-RPC over ordinary HTTP, as an independent MCP client would do it:
  the grant in `Authorization`, and the session the `initialize` exchange hands
  back. Nothing AtMcp-specific, which is what makes a check written with it
  evidence about the wire rather than about this library.
  """
  def session(token) do
    headers = headers(token) ++ [{"accept", "application/json, text/event-stream"}]

    initialized =
      Req.post!(url(),
        headers: headers,
        retry: false,
        json: %{
          jsonrpc: "2.0",
          id: 1,
          method: "initialize",
          params: %{
            protocolVersion: "2025-06-18",
            capabilities: %{},
            clientInfo: %{name: "at_mcp-test-client", version: "1"}
          }
        }
      )

    case initialized.status do
      200 ->
        session =
          Enum.map(
            Req.Response.get_header(initialized, "mcp-session-id"),
            &{"mcp-session-id", &1}
          )

        headers = headers ++ session ++ [{"mcp-protocol-version", "2025-06-18"}]

        Req.post!(url(),
          headers: headers,
          retry: false,
          json: %{jsonrpc: "2.0", method: "notifications/initialized"}
        )

        {:ok, headers}

      status ->
        {:error, status, initialized.body}
    end
  end

  @doc "Session headers, failing the test if `initialize` was refused."
  def session!(token) do
    {:ok, headers} = session(token)
    headers
  end

  @doc """
  An MCP client attached to one identity through the shared endpoint.

  Returns `{client, token}`. Nothing about the address says which identity this
  is; the grant in the header does.
  """
  def client(account, scope \\ :manage) do
    token = token(account, scope)
    {:ok, client} = ExMCP.Client.connect(url(), headers: headers(token))

    on_exit(fn ->
      try do
        ExMCP.Client.disconnect(client)
      catch
        :exit, _ -> :ok
      end
    end)

    {client, token}
  end
end
