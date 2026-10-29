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
        cond do
          String.ends_with?(uri.path, ".actor.getPreferences") ->
            %{"preferences" => []}

          String.ends_with?(uri.path, ".notification.listNotifications") ->
            %{
              "notifications" =>
                Application.get_env(:at_mcp, :read_position_test_notifications, [])
            }

          true ->
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
    |> put_in(["record", "createdAt"], at)
    |> put_in(["record", "facets"], [])
  end

  # A reply to the account, written at `made` and indexed by the service at
  # `indexed`, as a notification.
  defp reply(n, made, indexed) do
    post = @fixture |> File.read!() |> Jason.decode!()

    %{
      "uri" => uri(n),
      "cid" => post["cid"],
      "author" => post["author"],
      "reason" => "reply",
      "record" => %{
        "$type" => "town.delve.feed.post",
        "text" => "Reply #{n}.",
        "createdAt" => made
      },
      "isRead" => false,
      "indexedAt" => indexed
    }
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
      Application.delete_env(:at_mcp, :read_position_test_notifications)
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
    assert page["since"] == post(2)["indexedAt"]

    # Posts 3 to 6 are not read yet, so the position has not moved past them.
    assert {:ok, %{at: at, pending: pending}} = ReadPositions.get(ctx.did, "timeline")
    assert at == post(2)["indexedAt"] and pending == post(9)["indexedAt"]

    text = text(ctx.state, %{"since" => "last_read", "limit" => 3, "mark_read" => false})
    assert text =~ "To get the rest of the new items, pass cursor: 3 with since: last_read"

    # The rest, by the cursor and the same since, back to where the account
    # had read; reaching it commits the newest post read.
    {rest, _} =
      timeline(ctx.state, %{"since" => "last_read", "cursor" => page["cursor"], "limit" => 50})

    assert uris(rest) == Enum.map(6..3//-1, &uri/1)

    assert ReadPositions.get(ctx.did, "timeline") ==
             {:ok, %{at: post(9)["indexedAt"], pending: nil}}
  end

  test "a page cut short and not followed loses nothing: the next read returns it all again",
       ctx do
    posted(2)
    timeline(ctx.state, %{"mark_read" => true})
    posted(9)

    {first, _} = timeline(ctx.state, %{"since" => "last_read", "limit" => 3})
    assert length(first["items"]) == 3

    # A new session, a dropped cursor: the same read from the top.
    {again, _} = timeline(ctx.state, %{"since" => "last_read"})
    assert uris(again) == Enum.map(9..3//-1, &uri/1)
    assert again["new_total"] == 7

    assert ReadPositions.get(ctx.did, "timeline") ==
             {:ok, %{at: post(9)["indexedAt"], pending: nil}}
  end

  test "a read since a time looks back without moving the shared position", ctx do
    posted(2)
    timeline(ctx.state, %{"mark_read" => true})
    posted(5)

    {page, _} = timeline(ctx.state, %{"since" => post(3)["indexedAt"]})
    assert uris(page) == Enum.map(5..4//-1, &uri/1)
    refute Map.has_key?(page, "read_position")

    # Not even when it asks to: a look-back is not a mark.
    {asked, _} = timeline(ctx.state, %{"since" => post(3)["indexedAt"], "mark_read" => true})
    refute Map.has_key?(asked, "read_position")

    assert ReadPositions.get(ctx.did, "timeline") ==
             {:ok, %{at: post(2)["indexedAt"], pending: nil}}
  end

  test "a read since a time still counts what is new when the positions cannot be loaded",
       ctx do
    posted(5)
    path = ReadPositions.path()
    saved = File.read(path)
    File.write!(path, "not json")
    File.chmod!(path, 0o600)

    on_exit(fn ->
      case saved do
        {:ok, bytes} -> File.write!(path, bytes)
        _ -> File.rm(path)
      end
    end)

    {page, _} = timeline(ctx.state, %{"since" => post(3)["indexedAt"]})
    assert uris(page) == Enum.map(5..4//-1, &uri/1)
    assert page["new_total"] == 2

    {page, _} = timeline(ctx.state, %{"since" => "last_read"})
    assert length(page["items"]) == 5
    assert page["since_unread"] == "config_corrupt"
    assert text(ctx.state, %{"since" => "last_read"}) =~ "(config_corrupt)"
  end

  test "a reply indexed after the position is new, though its author dated it earlier", ctx do
    notifications = fn args ->
      {:ok, result, _} =
        AtMcp.MCP.Server.handle_call_tool(
          "get_notifications",
          Map.put(args, "since", "last_read"),
          ctx.state
        )

      refute result[:isError], inspect(result)
      result.structuredContent
    end

    Application.put_env(:at_mcp, :read_position_test_notifications, [
      reply(1, "2026-10-29T10:01:00.000Z", "2026-10-29T10:01:00.000Z")
    ])

    assert notifications.(%{})["read_position"] == "2026-10-29T10:01:00.000Z"

    # Written at 10:00 on its author's server, reached the AppView at 10:05.
    late = reply(2, "2026-10-29T10:00:00.000Z", "2026-10-29T10:05:00.000Z")

    Application.put_env(:at_mcp, :read_position_test_notifications, [
      late,
      reply(1, "2026-10-29T10:01:00.000Z", "2026-10-29T10:01:00.000Z")
    ])

    page = notifications.(%{})
    assert Enum.map(page["items"], & &1["uri"]) == [uri(2)]
    assert page["new_total"] == 1
  end

  test "since last_read on an account that cannot log in is a plain refusal, not a crash" do
    {:ok, effects} = AtMcp.Test.QuotaFixture.start_effects(backend: AtMcp.Test.MockBackend)
    state = %{effects: effects}

    assert {:ok, %{isError: true} = result, ^state} =
             AtMcp.MCP.Server.handle_call_tool("get_timeline", %{"since" => "last_read"}, state)

    assert hd(result.content).text =~ "not connected"
  end

  test "since last_read before the account has a session reads, rather than failing" do
    # No session yet: the read logs in, then the position is read.
    {:ok, effects} =
      AtMcp.Test.QuotaFixture.start_effects(
        backend: AtMcp.Test.MockBackend,
        handle: "reader.test",
        password: "app-password"
      )

    assert AtMcp.Effects.account_did(effects) == nil
    state = %{effects: effects}

    assert {:ok, result, ^state} =
             AtMcp.MCP.Server.handle_call_tool("get_timeline", %{"since" => "last_read"}, state)

    refute result[:isError], inspect(result)
  end

  test "a read without since leaves the position, unless it asks to move it", ctx do
    posted(3)
    timeline(ctx.state, %{"mark_read" => true})
    posted(6)

    # An operator's or another client's plain read: the agent's new posts stay new.
    {plain, _} = timeline(ctx.state)
    assert length(plain["items"]) == 6
    refute Map.has_key?(plain, "read_position")

    assert ReadPositions.get(ctx.did, "timeline") ==
             {:ok, %{at: post(3)["indexedAt"], pending: nil}}

    assert text(ctx.state, %{"since" => "last_read", "mark_read" => false}) =~ "3 new since"
  end

  test "mark_read false leaves the position where it was", ctx do
    posted(3)
    timeline(ctx.state, %{"mark_read" => true})
    posted(6)
    {page, _} = timeline(ctx.state, %{"since" => "last_read", "mark_read" => false})
    assert length(page["items"]) == 3
    refute Map.has_key?(page, "read_position")

    assert ReadPositions.get(ctx.did, "timeline") ==
             {:ok, %{at: post(3)["indexedAt"], pending: nil}}
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

  test "a position moves only forward, and each feed keeps its own" do
    did = "did:plc:feeds#{System.unique_integer([:positive])}"
    timeline = ReadPositions.key(:timeline, nil)
    at = "2026-10-29T08:05:00.000Z"
    assert {:ok, %{at: ^at}} = ReadPositions.advance(did, timeline, at, true)
    assert {:ok, %{at: ^at}} = ReadPositions.advance(did, timeline, "2026-10-29T08:01:00Z", true)

    # Not reached: held as pending, and committed by the read that reaches it.
    later = "2026-10-29T09:00:00.000Z"
    assert {:ok, %{at: ^at, pending: ^later}} = ReadPositions.advance(did, timeline, later, false)

    assert {:ok, %{at: ^later, pending: nil}} =
             ReadPositions.advance(did, timeline, "2026-10-29T08:30:00Z", true)

    list = ReadPositions.key(:list_feed, "at://l")
    assert {:ok, %{at: nil, pending: nil}} = ReadPositions.get(did, list)
    assert ReadPositions.key(:author, "Alice.Test") == ReadPositions.key(:author, "alice.test")
  end
end
