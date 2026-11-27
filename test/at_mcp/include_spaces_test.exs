defmodule AtMcp.IncludeSpacesTest do
  @moduledoc """
  The town AppView lists Spaces activity, and counts it unread, only for a
  client that passes `includeSpaces=true`: AtMcp passes it on every
  notifications read and unread count on delve.town, and nowhere else.
  """
  use ExUnit.Case, async: false

  defmodule HTTP do
    def request(:get, url, _opts) do
      send(Application.fetch_env!(:at_mcp, :include_spaces_owner), {:get, URI.parse(url)})

      body =
        cond do
          String.contains?(url, "getUnreadCount") -> %{count: 2}
          String.contains?(url, "getPreferences") -> %{preferences: []}
          true -> %{notifications: []}
        end

      {:ok, %{status: 200, headers: [], body: Jason.encode!(body)}}
    end
  end

  setup do
    previous =
      {Application.get_env(:proto_rune, :http_client), Application.get_env(:at_mcp, :network)}

    Application.put_env(:proto_rune, :http_client, HTTP)
    Application.put_env(:at_mcp, :include_spaces_owner, self())

    on_exit(fn ->
      {http, network} = previous

      if http,
        do: Application.put_env(:proto_rune, :http_client, http),
        else: Application.delete_env(:proto_rune, :http_client)

      if network,
        do: Application.put_env(:at_mcp, :network, network),
        else: Application.delete_env(:at_mcp, :network)

      Application.delete_env(:at_mcp, :include_spaces_owner)
    end)

    session = %ProtoRune.Atproto.Session{
      did: "did:plc:reader#{System.unique_integer([:positive])}",
      handle: "reader.test",
      access_jwt: "a",
      refresh_jwt: "r",
      service_url: "https://pds.invalid/xrpc"
    }

    %{session: session}
  end

  defp asked(method) do
    receive do
      {:get, %URI{path: path, query: query}} ->
        if String.ends_with?(path, method), do: URI.decode_query(query || ""), else: asked(method)
    after
      1_000 -> flunk("no #{method} request")
    end
  end

  test "on delve.town, notifications and the unread count ask for Spaces activity", ctx do
    Application.put_env(:at_mcp, :network, :delve)

    {:ok, _} = AtMcp.Effects.ProtoRune.list_notifications(ctx.session, limit: 5)
    assert asked("notification.listNotifications")["includeSpaces"] == "true"

    {:ok, _} = AtMcp.Effects.ProtoRune.get_unread_count(ctx.session)
    assert asked("notification.getUnreadCount")["includeSpaces"] == "true"
  end

  test "on Bluesky, which has no town spaces, they don't", ctx do
    Application.put_env(:at_mcp, :network, :bluesky)

    {:ok, _} = AtMcp.Effects.ProtoRune.list_notifications(ctx.session, limit: 5)
    refute Map.has_key?(asked("notification.listNotifications"), "includeSpaces")

    {:ok, _} = AtMcp.Effects.ProtoRune.get_unread_count(ctx.session)
    refute Map.has_key?(asked("notification.getUnreadCount"), "includeSpaces")
  end
end
