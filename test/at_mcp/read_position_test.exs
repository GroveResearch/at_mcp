defmodule AtMcp.ReadPositionTest do
  @moduledoc """
  A held read position (#204): a read with `since: "last_read"` returns only
  what is newer than where the account last read that feed, the position
  moves as reads return items, it outlives the process that saved it, and
  every client of the account shares it.

  The service is a stand-in timeline, newest first, that the test posts to
  between reads, built from a recorded Delvetown post
  (test/fixtures/fieldnote-post.json).
  """
  use ExUnit.Case, async: false

  alias AtMcp.ReadPositions

  @fixture Path.expand("../fixtures/fieldnote-post.json", __DIR__)

  defmodule HTTP do
    def request(:get, url, _opts) do
      uri = URI.parse(url)
      query = URI.decode_query(uri.query || "")

      body =
        if String.ends_with?(uri.path, ".actor.getPreferences") do
          %{"preferences" => []}
        else
          send(Application.fetch_env!(:at_mcp, :read_position_test_owner), {:read, query})
          AtMcp.ReadPositionTest.page(query)
        end

      {:ok, %{status: 200, headers: [], body: Jason.encode!(body)}}
    end
  end

  # One page of the timeline as it stands, from the cursor (an index).
  def page(query) do
    posts = Application.get_env(:at_mcp, :read_position_test_posts, [])
    from = String.to_integer(query["cursor"] || "0")
    limit = String.to_integer(query["limit"] || "20")
    shown = posts |> Enum.drop(from) |> Enum.take(limit)
    cursor = if from + limit < length(posts), do: Integer.to_string(from + limit)

    Map.merge(
      %{"feed" => Enum.map(shown, &%{"post" => &1})},
      if(cursor, do: %{"cursor" => cursor}, else: %{})
    )
  end

  # Post n, posted n minutes after 08:00.
  defp post(n) do
    at = DateTime.add(~U[2026-10-29 08:00:00.000Z], n * 60) |> DateTime.to_iso8601()

    @fixture
    |> File.read!()
    |> Jason.decode!()
    |> Map.merge(%{"uri" => uri(n), "indexedAt" => at})
    |> put_in(["record", "text"], "Post #{n}.")
    |> put_in(["record", "facets"], [])
  end

  defp uri(n),
    do:
      "at://did:plc:fixture0201/town.delve.feed.post/3kfixture#{String.pad_leading("#{n}", 4, "0")}"

  # The timeline holds posts 1..n, newest first.
  defp posted(n),
    do: Application.put_env(:at_mcp, :read_position_test_posts, Enum.map(n..1//-1, &post/1))

  setup do
    previous = Application.get_env(:proto_rune, :http_client)
    network = Application.get_env(:at_mcp, :network)
    Application.put_env(:proto_rune, :http_client, HTTP)
    Application.put_env(:at_mcp, :network, :delve)
    Application.put_env(:at_mcp, :read_position_test_owner, self())

    on_exit(fn ->
      restore(:proto_rune, :http_client, previous)
      restore(:at_mcp, :network, network)
      Application.delete_env(:at_mcp, :read_position_test_posts)
      Application.delete_env(:at_mcp, :read_position_test_owner)
    end)

    did = "did:plc:reader#{System.unique_integer([:positive])}"
    %{did: did, state: client(did)}
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)

  # A client of the account: its own handler state over its own session.
  defp client(did) do
    {:ok, effects} =
      AtMcp.Test.QuotaFixture.start_effects(
        backend: AtMcp.Effects.ProtoRune,
        backend_state: %ProtoRune.Atproto.Session{
          did: did,
          handle: "reader.test",
          access_jwt: "access",
          refresh_jwt: "refresh",
          service_url: "https://pds.invalid/xrpc"
        }
      )

    %{effects: effects, format: "json"}
  end

  defp timeline(state, args \\ %{}) do
    {:ok, result, ^state} = AtMcp.MCP.Server.handle_call_tool("get_timeline", args, state)
    refute result[:isError], inspect(result)
    {result.structuredContent, Jason.decode!(hd(result.content).text)}
  end

  defp text(state, args) do
    state = Map.delete(state, :format)
    {:ok, result, ^state} = AtMcp.MCP.Server.handle_call_tool("get_timeline", args, state)
    hd(result.content).text
  end

  defp uris(page), do: Enum.map(page["items"], & &1["uri"])

  test "two reads in a row with since last_read return what is new, then nothing", ctx do
    posted(5)

    # No position yet: the newest page, which moves the position to post 5.
    {first, _} = timeline(ctx.state, %{"since" => "last_read"})
    assert uris(first) == Enum.map(5..1//-1, &uri/1)
    assert first["since"] == nil
    assert first["read_position"] == post(5)["indexedAt"]

    posted(8)
    assert text(ctx.state, %{"since" => "last_read", "mark_read" => false}) =~ "3 new since"

    {new, _} = timeline(ctx.state, %{"since" => "last_read"})
    assert uris(new) == Enum.map(8..6//-1, &uri/1)
    assert new["new_total"] == 3 and new["new_total_exact"]
    assert new["cursor"] == nil

    {none, _} = timeline(ctx.state, %{"since" => "last_read"})
    assert none["items"] == []
    assert none["new_total"] == 0

    assert text(ctx.state, %{"since" => "last_read"}) =~
             "0 posts. 0 new since #{post(8)["indexedAt"]}."
  end

  test "more new than a page holds: the page counts them all, and its cursor reads the rest",
       ctx do
    posted(2)
    timeline(ctx.state, %{"mark_read" => true})
    posted(9)

    {page, _} = timeline(ctx.state, %{"since" => "last_read", "limit" => 3})
    assert uris(page) == Enum.map(9..7//-1, &uri/1)
    assert page["new_total"] == 7 and page["new_total_exact"]
    since = post(2)["indexedAt"]
    assert page["since"] == since

    text = text(ctx.state, %{"since" => since, "limit" => 3, "mark_read" => false})
    assert text =~ "For the rest of the new ones, pass cursor: 3 and since: #{since}"

    # The rest, by the cursor and the time, to where the account had read.
    {rest, _} =
      timeline(ctx.state, %{"since" => since, "cursor" => page["cursor"], "limit" => 50})

    assert uris(rest) == Enum.map(6..3//-1, &uri/1)

    # Reading older items never moved the position back.
    assert {:ok, at} = ReadPositions.get(ctx.did, "timeline")
    assert at == post(9)["indexedAt"]
  end

  test "a read without since leaves the position, unless it asks to move it", ctx do
    posted(3)
    timeline(ctx.state, %{"mark_read" => true})
    posted(6)

    # An operator's or another client's plain read: the agent's new posts stay new.
    {plain, _} = timeline(ctx.state)
    assert length(plain["items"]) == 6
    refute Map.has_key?(plain, "read_position")
    assert ReadPositions.get(ctx.did, "timeline") == {:ok, post(3)["indexedAt"]}
    assert text(ctx.state, %{"since" => "last_read", "mark_read" => false}) =~ "3 new since"
  end

  test "mark_read false leaves the position where it was", ctx do
    posted(3)
    timeline(ctx.state, %{"mark_read" => true})
    posted(6)
    {page, _} = timeline(ctx.state, %{"since" => "last_read", "mark_read" => false})
    assert length(page["items"]) == 3
    refute Map.has_key?(page, "read_position")
    assert ReadPositions.get(ctx.did, "timeline") == {:ok, post(3)["indexedAt"]}
  end

  test "the position outlives the process that saved it, and every client of the account shares it",
       ctx do
    posted(4)
    timeline(ctx.state, %{"mark_read" => true})

    # Another client, with a session of its own and no memory of the first:
    # the position is on disk, in the state directory, and nowhere else.
    GenServer.stop(ctx.state.effects)
    other = client(ctx.did)
    posted(5)
    {page, _} = timeline(other, %{"since" => "last_read"})
    assert uris(page) == [uri(5)]

    assert {:ok, saved} = File.read(ReadPositions.path())
    assert saved =~ ctx.did

    # A different account's position is its own.
    {fresh, _} =
      timeline(client("did:plc:another#{System.unique_integer([:positive])}"), %{
        "since" => "last_read"
      })

    assert fresh["since"] == nil
  end

  test "a since that is neither last_read nor a time is refused before anything is read", ctx do
    {:ok, result, _} =
      AtMcp.MCP.Server.handle_call_tool("get_timeline", %{"since" => "yesterday"}, ctx.state)

    assert result.isError
    assert hd(result.content).text =~ "last_read or a time"
    refute_received {:read, _}
  end

  test "each feed keeps its own position, and a read of one leaves the others" do
    did = "did:plc:feeds#{System.unique_integer([:positive])}"
    at = "2026-10-29T08:05:00.000Z"
    assert {:ok, ^at} = ReadPositions.advance(did, ReadPositions.key(:timeline, nil), at)

    assert {:ok, ^at} =
             ReadPositions.advance(did, ReadPositions.key(:timeline, nil), "2026-10-29T08:01:00Z")

    assert {:ok, nil} = ReadPositions.get(did, ReadPositions.key(:feed, "at://f"))
    assert ReadPositions.key(:author, "Alice.Test") == ReadPositions.key(:author, "alice.test")
  end
end
