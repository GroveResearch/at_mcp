defmodule AtMcp.PostImagesTest do
  @moduledoc """
  `get_post_images` over the real MCP HTTP endpoint, against a stub AppView and
  a stub image host. The pictures an agent is shown are the bytes the host
  served, for the URLs the AppView returned for that post and no others; an
  image that cannot be shown is named by index with the reason.
  """
  use ExUnit.Case, async: false

  alias AtMcp.Test.Grant

  @red <<137, 80, 78, 71, 13, 10, 26, 10>> <> :crypto.strong_rand_bytes(200)
  @blue <<255, 216, 255, 224>> <> :crypto.strong_rand_bytes(300)
  @max_bytes 1_000
  @fetch_ms 500

  defmodule ImageHost do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      Agent.update(opts[:requests], &(&1 ++ [{conn.request_path, conn.req_headers}]))
      {type, body, wait} = served(conn.request_path)
      Process.sleep(wait)
      conn |> put_resp_content_type(type, nil) |> send_resp(200, body)
    end

    def served("/img/red"), do: {"image/png", AtMcp.PostImagesTest.red(), 0}
    def served("/img/blue"), do: {"image/jpeg", AtMcp.PostImagesTest.blue(), 0}
    def served("/img/page"), do: {"text/html", "<html>not a picture</html>", 0}
    def served("/img/big"), do: {"image/png", :binary.copy("x", 5_000), 0}
    def served("/img/slow"), do: {"image/png", "late", 2_000}
    def served(_), do: {"image/png", "never asked for", 0}
  end

  defmodule AppView do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      conn = fetch_query_params(conn)
      host = opts[:host]
      uri = conn.query_params["uris"]

      posts =
        if String.ends_with?(conn.request_path, "feed.getPosts"),
          do: List.wrap(AtMcp.PostImagesTest.post(uri, host)),
          else: []

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(%{posts: posts}))
    end
  end

  def red, do: @red
  def blue, do: @blue

  @two "at://did:plc:author/app.bsky.feed.post/two"
  @none "at://did:plc:author/app.bsky.feed.post/none"
  @mixed "at://did:plc:author/app.bsky.feed.post/mixed"
  @gone "at://did:plc:author/app.bsky.feed.post/gone"

  defp view(uri, embed) do
    %{
      uri: uri,
      cid: "bafypost",
      author: %{did: "did:plc:author", handle: "author.test"},
      record: %{"$type" => "app.bsky.feed.post", text: "look", createdAt: "2026-10-08T00:00:00Z"},
      embed: embed
    }
  end

  defp image(host, alt, path),
    do: %{alt: alt, thumb: host <> path <> "?thumb", fullsize: host <> path}

  def post(@two, host) do
    view(@two, %{
      "$type" => "app.bsky.embed.images#view",
      images: [image(host, "a red square", "/img/red"), image(host, "", "/img/blue")]
    })
  end

  def post(@none, _host), do: view(@none, nil)

  # Quoting a post that has its own picture, beside four of its own: one the
  # host answers with a web page, one too large, one too slow, and one the
  # AppView did not hydrate, so there is no URL to fetch.
  def post(@mixed, host) do
    view(@mixed, %{
      "$type" => "app.bsky.embed.recordWithMedia#view",
      media: %{
        "$type" => "app.bsky.embed.images#view",
        images: [
          image(host, "page", "/img/page"),
          image(host, "big", "/img/big"),
          image(host, "slow", "/img/slow"),
          %{alt: "raw", image: %{ref: %{"$link" => "bafyblob"}, mimeType: "image/png"}}
        ]
      },
      record: %{
        record: %{
          "$type" => "app.bsky.embed.record#viewRecord",
          uri: "at://did:plc:other/app.bsky.feed.post/quoted",
          author: %{did: "did:plc:other", handle: "other.test"},
          value: %{"$type" => "app.bsky.feed.post", text: "quoted"},
          embeds: [%{images: [image(host, "quoted", "/img/quoted")]}]
        }
      }
    })
  end

  def post(_uri, _host), do: nil

  setup do
    AtMcp.Test.Settings.put(post_images: [max_bytes: @max_bytes, fetch_ms: @fetch_ms])

    requests = start_supervised!({Agent, fn -> [] end}, id: :image_requests)
    host_ref = :"image_host_#{System.unique_integer([:positive])}"
    view_ref = :"appview_#{System.unique_integer([:positive])}"

    start_supervised!(
      Plug.Cowboy.child_spec(
        scheme: :http,
        plug: {ImageHost, requests: requests},
        options: [port: 0, ip: {127, 0, 0, 1}, ref: host_ref]
      ),
      id: host_ref
    )

    host = "http://127.0.0.1:#{:ranch.get_port(host_ref)}"

    start_supervised!(
      Plug.Cowboy.child_spec(
        scheme: :http,
        plug: {AppView, host: host},
        options: [port: 0, ip: {127, 0, 0, 1}, ref: view_ref]
      ),
      id: view_ref
    )

    id = "post_images_#{System.unique_integer([:positive])}"

    {:ok, _} =
      AtMcp.Identities.start_identity(
        id: id,
        listen_enabled: false,
        backend: AtMcp.Effects.ProtoRune,
        backend_state: %ProtoRune.Atproto.Session{
          access_jwt: "account-access-token",
          refresh_jwt: "refresh",
          did: "did:plc:self",
          handle: "self.test",
          service_url: "http://127.0.0.1:#{:ranch.get_port(view_ref)}/xrpc"
        },
        expected_did: "did:plc:self",
        write_quota: AtMcp.Test.QuotaFixture.quota(1)
      )

    on_exit(fn -> AtMcp.Identities.stop_identity(id) end)

    # A read-scope grant: the tool is a read and must be reachable as one.
    %{headers: Grant.session!(Grant.token(id, :read)), requests: requests}
  end

  defp call(headers, uri) do
    Req.post!(Grant.url(),
      headers: headers,
      retry: false,
      json: %{
        jsonrpc: "2.0",
        id: System.unique_integer([:positive]),
        method: "tools/call",
        params: %{name: "get_post_images", arguments: %{uri: uri}}
      }
    ).body["result"]
  end

  defp requested(requests), do: requests |> Agent.get(& &1) |> Enum.map(&elem(&1, 0))

  test "a post's two images arrive as image content after a text block, byte for byte", %{
    headers: headers,
    requests: requests
  } do
    result = call(headers, @two)

    refute result["isError"]
    assert [%{"type" => "text", "text" => text}, red, blue] = result["content"]
    assert Jason.decode!(text) == result["structuredContent"]

    assert %{"type" => "image", "mimeType" => "image/png"} = red
    assert Base.decode64!(red["data"]) == @red
    assert %{"type" => "image", "mimeType" => "image/jpeg"} = blue
    assert Base.decode64!(blue["data"]) == @blue

    assert %{
             "uri" => @two,
             "count" => 2,
             "images" => [
               %{"index" => 1, "alt" => "a red square", "status" => "attached"},
               %{"index" => 2, "alt" => "", "status" => "attached"}
             ]
           } = result["structuredContent"]

    # The full-size URLs, not the thumbnails, and nothing of the account's.
    assert Enum.sort(requested(requests)) == ["/img/blue", "/img/red"]

    for {_path, request_headers} <- Agent.get(requests, & &1) do
      refute List.keymember?(request_headers, "authorization", 0)
      refute inspect(request_headers) =~ "account-access-token"
    end
  end

  test "a post with no images says so and carries no image content", %{headers: headers} do
    result = call(headers, @none)

    refute result["isError"]
    assert [%{"type" => "text"}] = result["content"]
    assert %{"count" => 0, "images" => []} = result["structuredContent"]
  end

  test "each image that cannot be shown is named by index with its reason, within the bound", %{
    headers: headers,
    requests: requests
  } do
    {elapsed_us, result} = :timer.tc(fn -> call(headers, @mixed) end)

    refute result["isError"]
    assert [%{"type" => "text"}] = result["content"]

    assert [page, big, slow, raw] = result["structuredContent"]["images"]
    assert %{"index" => 1, "status" => "unavailable", "reason" => reason} = page
    assert reason =~ "text/html"
    assert %{"index" => 2, "status" => "unavailable", "reason" => reason} = big
    assert reason =~ "larger than #{@max_bytes} bytes"
    assert %{"index" => 3, "status" => "unavailable", "reason" => reason} = slow
    assert reason =~ "did not answer"
    assert %{"index" => 4, "status" => "unavailable", "alt" => "raw", "reason" => reason} = raw
    assert reason =~ "no full-size URL"

    # The slow host is cut off at the bound rather than waited for.
    assert elapsed_us < 1_500_000

    # Only URLs the AppView returned for this post: not the quoted post's
    # picture, and nothing built from the unhydrated image's CID.
    assert Enum.sort(requested(requests)) == ["/img/big", "/img/page", "/img/slow"]
  end

  test "a post the AppView does not return is reported and nothing is fetched", %{
    headers: headers,
    requests: requests
  } do
    result = call(headers, @gone)

    assert result["isError"]
    assert result["structuredContent"]["code"] == "post_not_found"
    assert requested(requests) == []
  end

  test "the tool is declared read-only" do
    {:ok, tools, nil, :state} = AtMcp.MCP.Server.handle_list_tools(nil, :state)
    tool = Enum.find(tools, &(&1.name == "get_post_images"))
    assert tool.annotations.readOnlyHint == true
    assert AtMcp.Grants.permits_scope?(:read, "get_post_images")
  end
end
