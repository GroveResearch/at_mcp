defmodule AtMcp.PageBoundTest do
  @moduledoc """
  A page of posts a model can afford: no reading of a page passes
  `AtMcp.Reading.page_chars/0`, a page cut short says how many posts it left
  out and gives the cursor that continues from them, and `detail: "brief"`
  reads each post on one line.

  The service here is a stand-in that serves 60 long posts, made from a
  recorded Delvetown post (test/fixtures/fieldnote-post.json), honouring
  `limit` and `cursor` the way a feed does, for every read made of posts.
  """
  use ExUnit.Case, async: false

  @fixture Path.expand("../fixtures/fieldnote-post.json", __DIR__)
  @posts 60

  defmodule HTTP do
    def request(:get, url, _opts) do
      uri = URI.parse(url)
      query = URI.decode_query(uri.query || "")
      method = uri.path |> String.split(".") |> List.last()

      {:ok,
       %{status: 200, headers: [], body: Jason.encode!(AtMcp.PageBoundTest.body(method, query))}}
    end
  end

  # One page of the stand-in feed, in the shape `method` answers with.
  def body("getPreferences", _query), do: %{"preferences" => []}

  def body(method, query) do
    from = String.to_integer(query["cursor"] || "0")
    limit = String.to_integer(query["limit"] || "50")
    shown = Enum.map(from..(min(from + limit, @posts) - 1)//1, &post/1)
    cursor = if from + limit < @posts, do: Integer.to_string(from + limit)

    case method do
      m when m in ["searchPosts", "searchPostsV2", "getQuotes"] ->
        %{"posts" => shown}

      "getBookmarks" ->
        %{"bookmarks" => Enum.map(shown, &%{"createdAt" => &1["indexedAt"], "item" => &1})}

      _ ->
        %{"feed" => Enum.map(shown, &%{"post" => &1})}
    end
    |> Map.merge(if cursor, do: %{"cursor" => cursor}, else: %{})
  end

  # Post n: the recorded post with its own uri and about 2,000 characters.
  defp post(n) do
    post = @fixture |> File.read!() |> Jason.decode!()
    text = "Post #{n}. " <> String.duplicate("A sentence of a long post. ", 75)

    post
    |> Map.put("uri", uri(n))
    |> put_in(["record", "text"], text)
    |> put_in(["record", "facets"], [])
  end

  def uri(n),
    do:
      "at://did:plc:fixture0201/town.delve.feed.post/3kfixture#{String.pad_leading("#{n}", 4, "0")}"

  setup do
    previous = Application.get_env(:proto_rune, :http_client)
    network = Application.get_env(:at_mcp, :network)
    Application.put_env(:proto_rune, :http_client, HTTP)
    Application.put_env(:at_mcp, :network, :delve)

    on_exit(fn ->
      restore(:proto_rune, :http_client, previous)
      restore(:at_mcp, :network, network)
    end)

    {:ok, effects} =
      AtMcp.Test.QuotaFixture.start_effects(
        backend: AtMcp.Effects.ProtoRune,
        backend_state: %ProtoRune.Atproto.Session{
          did: "did:plc:self",
          handle: "self.test",
          access_jwt: "access",
          refresh_jwt: "refresh",
          service_url: "https://pds.invalid/xrpc"
        }
      )

    %{state: %{effects: effects}}
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)

  @reads [
    {"get_timeline", %{}},
    {"get_author_feed", %{"actor" => "fieldnote.example.test"}},
    {"get_feed", %{"feed" => "at://did:plc:gen/town.delve.feed.generator/hot"}},
    {"get_list_feed", %{"list" => "at://did:plc:list/town.delve.graph.list/friends"}},
    {"get_actor_likes", %{"actor" => "fieldnote.example.test"}},
    {"get_quotes", %{"uri" => "at://did:plc:fixture0201/town.delve.feed.post/3kfixtureqo2a"}},
    {"search_posts", %{"query" => "long"}},
    {"get_bookmarks", %{}}
  ]

  defp call(state, name, args) do
    {:ok, result, ^state} = AtMcp.MCP.Server.handle_call_tool(name, args, state)
    refute result[:isError], inspect(result)
    result
  end

  defp text(result), do: Enum.map_join(result.content, "\n", & &1.text)

  test "no page of posts reads longer than the bound, and a page cut short says so", ctx do
    for {name, args} <- @reads do
      # The most posts a page holds, each about 2,000 characters.
      args = Map.put(args, "limit", 50)
      text = text(call(ctx.state, name, args))

      assert String.length(text) <= AtMcp.Reading.page_chars(),
             "#{name} read #{String.length(text)} characters"

      assert text =~ ~r/(\d+) more on this page were left out to keep it under 40000 characters/,
             name

      page = call(ctx.state, name, Map.put(args, "format", "json")).structuredContent
      shown = length(page["items"])
      assert shown > 1 and shown < 50, "#{name} showed #{shown}"
      assert page["left_out"] == 50 - shown
      assert text =~ "#{50 - shown} more on this page were left out"
    end
  end

  test "the cursor of a page cut short continues from its first post left out", ctx do
    first =
      call(ctx.state, "get_timeline", %{"limit" => 50, "format" => "json"}).structuredContent

    shown = length(first["items"])
    assert shown < 50, "the page was not cut"
    assert List.last(first["items"])["uri"] == uri(shown - 1)

    next =
      call(ctx.state, "get_timeline", %{
        "limit" => 50,
        "cursor" => first["cursor"],
        "format" => "json"
      }).structuredContent

    assert hd(next["items"])["uri"] == uri(shown)
  end

  test "a page within the bound is read whole, as the service sent it", ctx do
    page = call(ctx.state, "get_timeline", %{"limit" => 5, "format" => "json"}).structuredContent
    assert length(page["items"]) == 5
    refute Map.has_key?(page, "left_out")
    assert page["cursor"] == "5"
    refute text(call(ctx.state, "get_timeline", %{"limit" => 5})) =~ "left out"
  end

  test "brief reads each post on one line, a small part of reading it whole", ctx do
    full = text(call(ctx.state, "get_author_feed", %{"actor" => "a.test", "limit" => 15}))

    brief =
      text(
        call(ctx.state, "get_author_feed", %{
          "actor" => "a.test",
          "limit" => 15,
          "detail" => "brief"
        })
      )

    [header | lines] = String.split(brief, "\n")
    assert header =~ "15 posts, one line each; get_posts reads them whole."
    assert length(lines) == 15

    for {line, n} <- Enum.with_index(lines) do
      assert line =~ ~r/^\[#{n + 1}\] @fieldnote\.example\.test · /
      assert String.ends_with?(line, uri(n))
      # The first line of the text, shortened, and saying so outside the quotes.
      assert line =~ ~s|"Post #{n}. A sentence of a long post.|
      assert line =~ ~s|" (more)|
    end

    assert String.length(brief) * 5 < String.length(full)
  end
end
