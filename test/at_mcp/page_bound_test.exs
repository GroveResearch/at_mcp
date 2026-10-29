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

    # A generator that ignores `limit`: the AppView cuts its 50 posts to the
    # limit and passes the generator's cursor on unchanged.
    cursor =
      if method == "getFeed" and String.ends_with?(query["feed"] || "", "/greedy"),
        do: Integer.to_string(from + 50),
        else: cursor

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

    text =
      "Post #{n}. " <>
        String.duplicate("A sentence of a long post. ", 75) <>
        String.duplicate("a", Application.get_env(:at_mcp, :page_bound_test_pad, 0))

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
      Application.delete_env(:at_mcp, :page_bound_test_pad)
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

      [_, kept, left] =
        Regex.run(
          ~r/^(\d+) \w+\. (\d+) more \w+ did not fit in 40000 characters/,
          text
        )

      assert String.to_integer(kept) + String.to_integer(left) == 50, name

      # Asked for JSON, which programs page by count, the page is whole.
      page = call(ctx.state, name, Map.put(args, "format", "json")).structuredContent
      assert length(page["items"]) == 50, name
      refute Map.has_key?(page, "left_out")
    end
  end

  test "a page read with since fits the bound with its header, which is counted inside it", ctx do
    # Pad the posts as far as 13 of them still read whole without since, which
    # is within a few characters of the bound.
    read = fn pad, args ->
      Application.put_env(:at_mcp, :page_bound_test_pad, pad)
      text(call(ctx.state, "get_timeline", Map.put(args, "limit", 13)))
    end

    pad = Enum.find(200..0//-1, &(read.(&1, %{}) =~ ~r/^13 posts\. For the next page/))
    plain = read.(pad, %{})
    assert String.length(plain) in (AtMcp.Reading.page_chars() - 60)..AtMcp.Reading.page_chars()
    assert plain =~ ~r/^13 posts\./

    # Every post is new since 2020, and the header says so and gives the
    # cursor for the rest: the page is cut to make room for it.
    since = read.(pad, %{"since" => "2020-01-01T00:00:00Z"})
    assert since =~ " new since "
    assert String.length(since) <= AtMcp.Reading.page_chars(), "read #{String.length(since)}"
    assert since =~ ~r/^12 posts\. 60 new since [^.]+\. 1 more post did not fit/
  end

  test "a feed whose generator ignores limit is not cut, so no post is skipped", ctx do
    text =
      text(
        call(ctx.state, "get_feed", %{
          "feed" => "at://did:plc:gen/town.delve.feed.generator/greedy",
          "limit" => 50
        })
      )

    # The second read's cursor would skip from the cut to post 50, so the
    # first page is read whole, saying it is longer than the bound.
    assert text =~
             "50 posts. This page is longer than 40000 characters."

    assert text =~ "uri: #{uri(49)}"
    assert text =~ "pass cursor: 50"
    refute text =~ "did not fit"
  end

  test "the cursor of a page cut short continues from its first post left out", ctx do
    first = text(call(ctx.state, "get_timeline", %{"limit" => 50}))
    [_, shown, cursor] = Regex.run(~r/^(\d+) posts\..*pass cursor: (\S+)/, first)
    shown = String.to_integer(shown)
    assert shown < 50, "the page was not cut"
    assert first =~ "uri: #{uri(shown - 1)}"
    refute first =~ "uri: #{uri(shown)}"

    next =
      call(ctx.state, "get_timeline", %{
        "limit" => 50,
        "cursor" => cursor,
        "format" => "json"
      }).structuredContent

    assert hd(next["items"])["uri"] == uri(shown)
  end

  test "a page within the bound is read whole, as the service sent it", ctx do
    page = call(ctx.state, "get_timeline", %{"limit" => 5, "format" => "json"}).structuredContent
    assert length(page["items"]) == 5
    refute Map.has_key?(page, "left_out")
    assert page["cursor"] == "5"
    refute text(call(ctx.state, "get_timeline", %{"limit" => 5})) =~ "did not fit"
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
    assert header =~ "15 posts, one line each. Pass a uri to get_posts to read the whole post."
    assert length(lines) == 15

    for {line, n} <- Enum.with_index(lines) do
      assert line =~ ~r/^\[#{n + 1}\] @fieldnote\.example\.test · /
      assert String.ends_with?(line, uri(n))
      # The first line of the text, shortened, and saying so outside the quotes.
      assert line =~ ~s|"Post #{n}. A sentence of a long post.|
      assert line =~ ~s|" (continues)|
    end

    assert String.length(brief) * 5 < String.length(full)
  end
end
