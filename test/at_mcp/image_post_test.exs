defmodule AtMcp.ImagePostTest do
  use ExUnit.Case, async: false

  # A PDS that records what it is sent and answers uploads and record writes.
  defmodule PDS do
    import Plug.Conn
    def init(opts), do: opts

    def call(conn, opts) do
      {:ok, body, conn} = read_body(conn, length: 100_000_000)
      Agent.update(opts[:calls], &(&1 ++ [{conn.request_path, body}]))

      response =
        case conn.request_path do
          "/xrpc/com.atproto.server.createSession" ->
            %{accessJwt: "access", refreshJwt: "refresh", did: opts[:did], handle: "img.invalid"}

          "/xrpc/com.atproto.repo.uploadBlob" ->
            %{
              blob: %{
                "$type" => "blob",
                "ref" => %{"$link" => "bafkrei#{byte_size(body)}"},
                "mimeType" => "image/png",
                "size" => byte_size(body)
              }
            }

          "/xrpc/com.atproto.repo.createRecord" ->
            %{uri: "at://#{opts[:did]}/app.bsky.feed.post/1", cid: "bafyrecord"}
        end

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(response))
    end
  end

  # Read independently of `AtMcp.Network`: the post the lexicon allows.
  defp lexicon_image_limits do
    defs =
      [Application.app_dir(:at_mcp, "priv"), "lexicons", "app", "bsky", "embed", "images.json"]
      |> Path.join()
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("defs")

    {get_in(defs, ["main", "properties", "images", "maxLength"]),
     get_in(defs, ["image", "properties", "image", "maxSize"])}
  end

  test "a post with as many images as the lexicon allows, each at its largest, is published through the MCP endpoint" do
    {count, size} = lexicon_image_limits()
    assert count == 4

    id = "images-#{System.unique_integer([:positive])}"
    did = "did:plc:#{id}"
    calls = start_supervised!({Agent, fn -> [] end})

    start_supervised!(
      Plug.Cowboy.child_spec(
        scheme: :http,
        plug: {PDS, calls: calls, did: did},
        options: [port: 0, ip: {127, 0, 0, 1}, ref: :image_pds]
      )
    )

    {:ok, _} =
      AtMcp.Identities.start_identity(
        id: id,
        handle: "img.invalid",
        password: "disposable-password",
        service: "http://127.0.0.1:#{:ranch.get_port(:image_pds)}",
        listen_enabled: false,
        notifications_enabled: false
      )

    on_exit(fn -> AtMcp.Identities.stop_identity(id) end)

    images =
      for n <- 1..count do
        %{
          "data" => Base.encode64(:binary.copy(<<n>>, size)),
          "mime_type" => "image/png",
          "alt" => "image #{n}"
        }
      end

    # Ordinary JSON-RPC over HTTP, as any MCP client sends it.
    response =
      Req.post!(AtMcp.Test.Grant.url(),
        headers: AtMcp.Test.Grant.session!(AtMcp.Test.Grant.token(id)),
        retry: false,
        receive_timeout: 60_000,
        json: %{
          jsonrpc: "2.0",
          id: 2,
          method: "tools/call",
          params: %{
            name: "post",
            arguments: %{"text" => String.duplicate("a", 300), "images" => images}
          }
        }
      )

    assert response.status == 200, inspect(response.body)
    refute response.body["result"]["isError"], inspect(response.body)

    sent = Agent.get(calls, & &1)
    uploads = for {"/xrpc/com.atproto.repo.uploadBlob", body} <- sent, do: body
    assert Enum.map(uploads, &byte_size/1) == List.duplicate(size, count)
    assert uploads == for(n <- 1..count, do: :binary.copy(<<n>>, size))

    [record] = for {"/xrpc/com.atproto.repo.createRecord", body} <- sent, do: Jason.decode!(body)
    embedded = record["record"]["embed"]["images"]
    assert Enum.map(embedded, & &1["alt"]) == for(n <- 1..count, do: "image #{n}")
  end

  test "a body larger than the largest post is still refused before it is read" do
    id = "too-large-#{System.unique_integer([:positive])}"

    {:ok, _} =
      AtMcp.Identities.start_identity(
        id: id,
        listen_enabled: false,
        backend: AtMcp.Test.MockBackend,
        backend_state: %{did: "did:plc:#{id}"}
      )

    on_exit(fn -> AtMcp.Identities.stop_identity(id) end)

    response =
      Req.post!(AtMcp.Test.Grant.url(),
        headers:
          AtMcp.Test.Grant.session!(AtMcp.Test.Grant.token(id)) ++
            [{"content-type", "application/json"}],
        retry: false,
        body: :binary.copy(" ", AtMcp.MCP.HTTP.body_limit() + 1)
      )

    assert response.status == 413
  end
end
