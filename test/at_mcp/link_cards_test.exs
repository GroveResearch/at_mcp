defmodule AtMcp.LinkCardsTest do
  @moduledoc """
  A link card is looked up as the app's composer looks one up: from the
  network's card service, whose image becomes the card's thumbnail
  (`AtMcp.LinkCards`). These run the real backend against a fake PDS and a
  card service on localhost, and check the record that reaches the wire.
  """
  use ExUnit.Case, async: false

  alias AtMcp.Test.FakePDS

  # One pixel: what the card service serves as a page's image.
  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
       )

  defmodule CardService do
    @moduledoc false
    # A card service like Bluesky's: `/v1/extract?url=` answers a page's title,
    # description and an image it serves itself at `/v1/image?url=`.
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      conn = fetch_query_params(conn)
      Agent.update(opts[:calls], &(&1 ++ [conn]))
      base = "http://127.0.0.1:#{conn.port}"

      case {conn.request_path, conn.query_params["url"]} do
        {"/v1/extract", "https://example.com/slow"} -> drip(conn, extract("", base))
        {"/v1/extract", url} -> json(conn, extract(url, base))
        {"/v1/image", "big"} -> image(conn, :binary.copy("x", 1_000_001))
        {"/v1/image", _} -> image(conn, opts[:png])
      end
    end

    defp extract("https://example.com/broken", _base), do: %{error: "failed to fetch"}

    defp extract("https://example.com/plain", _base),
      do: %{error: "", title: "Plain", description: "", image: ""}

    defp extract("https://example.com/big", base),
      do: %{error: "", title: "Big", description: "", image: base <> "/v1/image?url=big"}

    defp extract("https://example.com/elsewhere", _base),
      do: %{error: "", title: "Elsewhere", description: "", image: "https://other.example/a.png"}

    # The service's own host, on another port.
    defp extract("https://example.com/otherport", _base),
      do: %{error: "", title: "Other port", description: "", image: "http://127.0.0.1:1/v1/image"}

    defp extract("https://example.com/long", _base),
      do: %{
        error: "",
        title: String.duplicate("t", 400),
        description: String.duplicate("d", 1_500),
        image: ""
      }

    defp extract(_url, base),
      do: %{
        error: "",
        title: "A page",
        description: "What the page says about itself",
        image: base <> "/v1/image?url=page"
      }

    # A byte at a time, each 400 ms apart: every read gets its byte within any
    # timeout, and the whole answer takes far longer than a lookup may.
    defp drip(conn, body) do
      conn = send_chunked(conn, 200)

      body
      |> Jason.encode!()
      |> String.graphemes()
      |> Enum.reduce_while(conn, fn byte, conn ->
        Process.sleep(400)

        case chunk(conn, byte) do
          {:ok, conn} -> {:cont, conn}
          {:error, _} -> {:halt, conn}
        end
      end)
    end

    defp json(conn, body),
      do: conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(body))

    defp image(conn, bytes),
      do: conn |> put_resp_content_type("image/png") |> send_resp(200, bytes)
  end

  setup do
    calls = start_supervised!({Agent, fn -> [] end})
    ref = make_ref()

    start_supervised!(
      Plug.Cowboy.child_spec(
        scheme: :http,
        plug: {CardService, calls: calls, png: @png},
        options: [port: 0, ip: {127, 0, 0, 1}, ref: ref]
      )
    )

    service = "http://127.0.0.1:#{:ranch.get_port(ref)}/v1/extract"
    previous = Application.fetch_env(:at_mcp, :card_service)
    Application.put_env(:at_mcp, :card_service, service)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:at_mcp, :card_service, value)
        :error -> Application.delete_env(:at_mcp, :card_service)
      end
    end)

    {session, pds} = FakePDS.start()

    effects =
      start_supervised!(
        {AtMcp.Effects,
         backend: AtMcp.Effects.ProtoRune,
         backend_state: session,
         write_quota: AtMcp.Test.QuotaFixture.quota(20)},
        id: make_ref()
      )

    %{effects: effects, pds: pds, calls: calls}
  end

  defp written(pds) do
    [create] = FakePDS.sent(pds, "com.atproto.repo.createRecord")
    create.body["record"]
  end

  defp card(pds), do: get_in(written(pds), ["embed", "external"])

  defp looked_up(calls),
    do:
      for(
        conn <- Agent.get(calls, & &1),
        conn.request_path == "/v1/extract",
        do: conn.query_params["url"]
      )

  test "a link given only its url is looked up: title, description and the image as its thumbnail",
       %{effects: effects, pds: pds, calls: calls} do
    assert {:ok, result} =
             AtMcp.Effects.post(effects, "a page", link: %{url: "https://example.com/page"})

    assert %{
             "uri" => "https://example.com/page",
             "title" => "A page",
             "description" => "What the page says about itself",
             "thumb" => %{"mimeType" => "image/png"}
           } = card(pds)

    assert [%{body: @png}] = FakePDS.sent(pds, "com.atproto.repo.uploadBlob")
    assert result.link_card == %{url: "https://example.com/page", from: "card_service"}

    # Through the tool, the result reports the card within its declared schema.
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        {:ok, tool, _} =
          AtMcp.MCP.Server.handle_call_tool(
            "post",
            %{"text" => "by tool", "link" => %{"url" => "https://example.com/plain"}},
            %{effects: effects}
          )

        refute tool[:isError], hd(tool.content).text
        assert tool.structuredContent["link_card"]["from"] == "card_service"
      end)

    refute log =~ "unvalidated"

    # Nothing of the account's reaches the card service.
    for conn <- Agent.get(calls, & &1),
        do: refute(Enum.any?(conn.req_headers, fn {key, _} -> key == "authorization" end))
  end

  test "a card whose title or description the caller wrote is written as given, with no lookup",
       %{effects: effects, pds: pds, calls: calls} do
    assert {:ok, result} =
             AtMcp.Effects.post(effects, "mine",
               link: %{url: "https://example.com/page", title: "My own title"}
             )

    assert %{"title" => "My own title", "description" => ""} = card(pds)
    refute Map.has_key?(card(pds), "thumb")
    assert looked_up(calls) == []
    assert result.link_card.from == "given"
  end

  test "a post with no card, images or quote gets one for the first link in its text",
       %{effects: effects, pds: pds, calls: calls} do
    assert {:ok, result} =
             AtMcp.Effects.post(
               effects,
               "first https://example.com/page then https://example.com/plain"
             )

    assert %{"uri" => "https://example.com/page", "title" => "A page"} = card(pds)
    assert looked_up(calls) == ["https://example.com/page"]
    assert result.link_card == %{url: "https://example.com/page", from: "text"}
  end

  test "no card is added for a link in text published without facets",
       %{effects: effects, pds: pds, calls: calls} do
    assert {:ok, result} =
             AtMcp.Effects.post(effects, "quoted: https://example.com/page", facets: :none)

    refute Map.has_key?(written(pds), "embed")
    refute Map.has_key?(result, :link_card)
    assert looked_up(calls) == []
  end

  test "a lookup that fails gives the card with only its url, and says why",
       %{effects: effects, pds: pds} do
    assert {:ok, result} =
             AtMcp.Effects.post(effects, "x", link: %{url: "https://example.com/broken"})

    assert %{"uri" => "https://example.com/broken", "title" => "", "description" => ""} =
             card(pds)

    assert result.link_card.from == "card_service"
    assert result.link_card.note =~ "only the link"
    assert result.link_card.note =~ "failed to fetch"
  end

  test "an image over the lexicon's limit, or one the service does not serve, is left off" do
    for {url, says} <- [
          {"https://example.com/big", "over 1000000 bytes"},
          {"https://example.com/elsewhere", "does not serve"},
          {"https://example.com/otherport", "does not serve"}
        ] do
      {session, pds} = FakePDS.start()

      effects =
        start_supervised!(
          {AtMcp.Effects,
           backend: AtMcp.Effects.ProtoRune,
           backend_state: session,
           write_quota: AtMcp.Test.QuotaFixture.quota(5)},
          id: make_ref()
        )

      assert {:ok, result} = AtMcp.Effects.post(effects, "x", link: %{url: url})
      assert %{"title" => title} = card(pds)
      assert title != ""
      refute Map.has_key?(card(pds), "thumb")
      assert FakePDS.sent(pds, "com.atproto.repo.uploadBlob") == []
      assert result.link_card.note =~ says
    end
  end

  test "a card service that answers a byte at a time gives up at the lookup's budget, and the post is sent",
       %{effects: effects, pds: pds} do
    started = System.monotonic_time(:millisecond)

    assert {:ok, result} =
             AtMcp.Effects.post(effects, "slow", link: %{url: "https://example.com/slow"})

    elapsed = System.monotonic_time(:millisecond) - started
    assert elapsed < AtMcp.LinkCards.lookup_ms() + 1_500, "took #{elapsed} ms"
    assert %{"uri" => "https://example.com/slow", "title" => ""} = card(pds)
    assert result.link_card.note =~ "did not answer within #{AtMcp.LinkCards.lookup_ms()} ms"
  end

  test "a page's title and description are cut to 300 and 1000 characters",
       %{effects: effects, pds: pds} do
    assert {:ok, _} = AtMcp.Effects.post(effects, "x", link: %{url: "https://example.com/long"})
    assert String.length(card(pds)["title"]) == 300
    assert String.length(card(pds)["description"]) == 1_000
  end

  test "a link into the app before an outside link leaves the card to the outside one, as the app does",
       %{effects: effects, pds: pds, calls: calls} do
    assert {:ok, result} =
             AtMcp.Effects.post(
               effects,
               "see https://bsky.app/profile/a.test/post/3k22222222222 and https://example.com/page"
             )

    assert %{"uri" => "https://example.com/page"} = card(pds)
    assert looked_up(calls) == ["https://example.com/page"]
    assert result.link_card.from == "text"
  end

  test "a link into the app or to an image is not looked up, as the app does not",
       %{effects: effects, calls: calls} do
    for url <- [
          "https://bsky.app/profile/someone.example/post/3k22222222222",
          "https://example.com/a.png"
        ] do
      assert {:ok, result} = AtMcp.Effects.post(effects, "x", link: %{url: url})
      assert result.link_card.from == "url_only"
      assert result.link_card.note =~ "only the link"
    end

    assert looked_up(calls) == []
  end

  test "a network with no card service looks nothing up: the card is the caller's",
       %{effects: effects, pds: pds, calls: calls} do
    Application.put_env(:at_mcp, :card_service, nil)

    assert {:ok, result} =
             AtMcp.Effects.post(effects, "see https://example.com/page",
               link: %{url: "https://example.com/page"}
             )

    assert %{"uri" => "https://example.com/page", "title" => ""} = card(pds)
    assert result.link_card.from == "url_only"
    assert result.link_card.note =~ "Pass the link's title and description"
    assert looked_up(calls) == []
  end

  test "Bluesky's card service is cardyb, as the app's; delve.town looks none up" do
    previous = Application.fetch_env(:at_mcp, :card_service)
    Application.delete_env(:at_mcp, :card_service)

    try do
      for {network, service} <- [
            bluesky: "https://cardyb.bsky.app/v1/extract",
            delve: nil
          ] do
        Application.put_env(:at_mcp, :network, network)
        assert AtMcp.Network.card_service() == service
      end
    after
      Application.delete_env(:at_mcp, :network)
      {:ok, value} = previous
      Application.put_env(:at_mcp, :card_service, value)
    end
  end
end
