defmodule AtMcp.RichTextTest do
  use ExUnit.Case, async: false

  defmodule PDS do
    import Plug.Conn
    def init(opts), do: opts

    def call(conn, calls) do
      conn = fetch_query_params(conn)
      {:ok, raw, conn} = read_body(conn)
      body = if raw == "", do: nil, else: Jason.decode!(raw)

      Agent.update(
        calls,
        &(&1 ++
            [
              %{
                path: conn.request_path,
                query: conn.query_params,
                body: body,
                headers: conn.req_headers
              }
            ])
      )

      {status, result} =
        case conn.request_path do
          "/xrpc/com.atproto.identity.resolveHandle" ->
            case conn.query_params["handle"] do
              "alice.test" -> {200, %{did: "did:plc:alice"}}
              _ -> {400, %{error: "InvalidRequest", message: "private upstream diagnostic"}}
            end

          "/xrpc/com.atproto.repo.getRecord" ->
            {200,
             %{
               uri: "at://did:plc:parent/app.bsky.feed.post/parent",
               cid: "parent-cid",
               value: %{
                 text: "parent",
                 reply: %{
                   root: %{uri: "at://did:plc:root/app.bsky.feed.post/root", cid: "root-cid"}
                 }
               }
             }}

          "/xrpc/com.atproto.repo.createRecord" ->
            {200, %{uri: "at://did:plc:owner/app.bsky.feed.post/new", cid: "new-cid"}}
        end

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(result))
    end
  end

  setup do
    calls = start_supervised!({Agent, fn -> [] end})
    ref = __MODULE__.HTTP

    start_supervised!(
      {Plug.Cowboy,
       scheme: :http, plug: {PDS, calls}, options: [port: 0, ip: {127, 0, 0, 1}, ref: ref]}
    )

    session = %ProtoRune.Atproto.Session{
      did: "did:plc:owner",
      handle: "owner.test",
      access_jwt: "private-access",
      refresh_jwt: "private-refresh",
      service_url: "http://127.0.0.1:#{:ranch.get_port(ref)}/xrpc"
    }

    %{calls: calls, session: session}
  end

  test "ordinary post sends byte-indexed facets without changing text or exposing credentials", %{
    calls: calls,
    session: session
  } do
    text = "🪁 café @alice.test @ALICE.test https://example.com/a_(b). #日本語!"
    assert {:ok, result} = AtMcp.Effects.ProtoRune.post(session, text)
    assert result.text == text
    refute Map.has_key?(result, :unresolved_mentions)
    requests = Agent.get(calls, & &1)
    assert Enum.count(requests, &String.ends_with?(&1.path, "resolveHandle")) == 1
    record = List.last(requests).body["record"]
    assert record["text"] == text

    assert Enum.map(record["facets"], &slice(text, &1)) == [
             "@alice.test",
             "@ALICE.test",
             "https://example.com/a_(b)",
             "#日本語"
           ]

    assert hd(record["facets"])["index"]["byteStart"] == byte_size("🪁 café ")

    assert hd(record["facets"])["features"] == [
             %{"$type" => "app.bsky.richtext.facet#mention", "did" => "did:plc:alice"}
           ]

    refute Jason.encode!(result) =~ "private"
    resolver = hd(requests)
    refute Enum.any?(resolver.headers, fn {key, _} -> key == "authorization" end)
    assert List.last(requests).body["repo"] == "did:plc:owner"
  end

  test "reply retains root and parent while unresolved mentions remain explicit plain text", %{
    calls: calls,
    session: session
  } do
    text = "@missing.test @missing.test hi @alice.test"

    assert {:ok, result} =
             AtMcp.Effects.ProtoRune.post(session, text,
               reply: "at://did:plc:parent/app.bsky.feed.post/parent"
             )

    assert result.unresolved_mentions == ["missing.test"]
    assert result.warning =~ "plain text, without mention facets"
    refute Jason.encode!(result) =~ "private"
    requests = Agent.get(calls, & &1)
    assert Enum.count(requests, &String.ends_with?(&1.path, "resolveHandle")) == 2
    record = List.last(requests).body["record"]
    assert record["text"] == text
    assert Enum.map(record["facets"], &slice(text, &1)) == ["@alice.test"]

    assert record["reply"] == %{
             "root" => %{
               "uri" => "at://did:plc:root/app.bsky.feed.post/root",
               "cid" => "root-cid"
             },
             "parent" => %{
               "uri" => "at://did:plc:parent/app.bsky.feed.post/parent",
               "cid" => "parent-cid"
             }
           }
  end

  test "token boundaries avoid email and URL fragments; invalid hashtags remain plain", %{
    session: session
  } do
    text = "mail@alice.test https://example.com/#tag #123 #valid #" <> String.duplicate("a", 65)

    {record, []} =
      AtMcp.RichText.build(text, session, resolve: fn _ -> flunk("email must not resolve") end)

    assert record.text == text

    assert Enum.map(record.facets, fn facet ->
             binary_part(
               text,
               facet.index.byte_start,
               facet.index.byte_end - facet.index.byte_start
             )
           end) == ["https://example.com/#tag", "#valid"]
  end

  test "hashtags exceeding the lexicon byte limit remain unchanged plain text", %{
    session: session
  } do
    tag = "a" <> String.duplicate("\u0301", 400)
    assert String.length(tag) == 1
    assert byte_size(tag) > 640
    text = "hello #" <> tag
    {record, []} = AtMcp.RichText.build(text, session)
    assert record == %{text: text, facets: []}
  end

  test "resolver exceptions and malformed DIDs cannot fabricate mention facets", %{
    session: session
  } do
    for resolver <- [fn _ -> raise "private resolver detail" end, fn _ -> {:ok, "not-a-did"} end] do
      {record, ["alice.test"]} = AtMcp.RichText.build("@alice.test", session, resolve: resolver)
      assert record == %{text: "@alice.test", facets: []}
    end
  end

  defp slice(text, facet) do
    index = facet["index"]
    binary_part(text, index["byteStart"], index["byteEnd"] - index["byteStart"])
  end
end
