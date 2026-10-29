defmodule AtMcp.ThreadTest do
  @moduledoc """
  `get_thread` reads a thread as the app does: `getPostThreadV2` with the
  account's thread sort and view, every parent, and the replies in the order
  the service gives for that sort, which is the order the app shows.

  test/fixtures/appview/thread_v2.json is a recorded public answer for a
  busy post with the app's default request (`sort: top`, `below: 10`,
  `branchingFactor: 1`), scrubbed by scripts/record_appview_fixtures.py with
  every item's depth kept. Its `top` order differs from `oldest`.
  """
  use ExUnit.Case, async: false

  @fixture Path.expand("../fixtures/appview/thread_v2.json", __DIR__)

  defmodule HTTP do
    def request(:get, url, _opts) do
      uri = URI.parse(url)
      query = URI.decode_query(uri.query || "")
      owner = Application.fetch_env!(:at_mcp, :thread_test_owner)

      body =
        cond do
          String.ends_with?(uri.path, ".actor.getPreferences") ->
            %{"preferences" => Application.get_env(:at_mcp, :thread_test_preferences, [])}

          String.ends_with?(uri.path, ".unspecced.getPostThreadV2") ->
            send(owner, {:thread, query})
            Application.fetch_env!(:at_mcp, :thread_test_body)

          true ->
            %{}
        end

      {:ok, %{status: 200, headers: [], body: Jason.encode!(body)}}
    end
  end

  setup do
    previous = Application.get_env(:proto_rune, :http_client)
    Application.put_env(:proto_rune, :http_client, HTTP)
    Application.put_env(:at_mcp, :thread_test_owner, self())
    recorded = @fixture |> File.read!() |> Jason.decode!()
    Application.put_env(:at_mcp, :thread_test_body, recorded)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:proto_rune, :http_client, previous),
        else: Application.delete_env(:proto_rune, :http_client)

      for key <- [:thread_test_owner, :thread_test_body, :thread_test_preferences],
          do: Application.delete_env(:at_mcp, key)
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

    anchor = Enum.find(recorded["thread"], &(&1["depth"] == 0))["uri"]
    %{state: %{effects: effects, format: "json"}, recorded: recorded, anchor: anchor}
  end

  defp read(state, args) do
    {:ok, result, ^state} = AtMcp.MCP.Server.handle_call_tool("get_thread", args, state)
    refute result[:isError], inspect(result)
    result.structuredContent
  end

  # Every post of the summary, parents first, then depth first below the post:
  # the order getPostThreadV2 lists them in.
  defp flat(node), do: up(node["parent"]) ++ [node["uri"]] ++ down(node)
  defp up(nil), do: []
  defp up(parent), do: up(parent["parent"]) ++ [parent["uri"]]
  defp down(node), do: Enum.flat_map(node["replies"], &[&1["uri"] | down(&1)])

  test "an account with no thread settings reads as the app's default view does", ctx do
    thread = read(ctx.state, %{"uri" => ctx.anchor})

    assert_receive {:thread, query}

    assert query == %{
             "anchor" => ctx.anchor,
             "above" => "true",
             "below" => "10",
             "branchingFactor" => "1",
             "sort" => "top"
           }

    assert thread["context"] == %{
             "depth" => 10,
             "breadth" => 1,
             "sort" => "top",
             "view" => "linear"
           }

    # The replies, and the replies under them, in the service's order for the
    # sort, which the app shows as it is.
    assert flat(thread) == Enum.map(ctx.recorded["thread"], & &1["uri"])

    direct = for item <- ctx.recorded["thread"], item["depth"] == 1, do: item["uri"]
    assert Enum.map(thread["replies"], & &1["uri"]) == direct
    assert thread["parent"]["uri"] == hd(ctx.recorded["thread"])["uri"]
  end

  test "the account's thread sort and tree view are read as the app reads them", ctx do
    Application.put_env(:at_mcp, :thread_test_preferences, [
      %{
        "$type" => "app.bsky.actor.defs#threadViewPref",
        "sort" => "newest",
        "lab_treeViewEnabled" => true
      }
    ])

    thread = read(ctx.state, %{"uri" => ctx.anchor})
    assert_receive {:thread, %{"sort" => "newest", "below" => "4", "branchingFactor" => "10"}}
    assert thread["context"]["view"] == "tree"
  end

  test "a larger depth reads deeper, and breadth more replies per post", ctx do
    read(ctx.state, %{"uri" => ctx.anchor, "depth" => 20, "breadth" => 5})
    assert_receive {:thread, %{"below" => "20", "branchingFactor" => "5"}}

    # The recording's deepest reply is four levels down, nested as it was.
    deepest = ctx.recorded["thread"] |> Enum.map(& &1["depth"]) |> Enum.max()
    assert deepest == 4

    thread = read(ctx.state, %{"uri" => ctx.anchor})

    levels = fn levels, node ->
      1 + Enum.max([0 | Enum.map(node["replies"], &levels.(levels, &1))])
    end

    assert levels.(levels, thread) - 1 == deepest
  end

  test "depth and breadth beyond what the service takes are refused before anything is sent",
       ctx do
    for args <- [%{"depth" => 21}, %{"breadth" => 101}, %{"depth" => -1}] do
      {:ok, result, _} =
        AtMcp.MCP.Server.handle_call_tool(
          "get_thread",
          Map.put(args, "uri", ctx.anchor),
          ctx.state
        )

      assert result.isError
      refute_received {:thread, _}
    end
  end

  test "what the service says about a reply reaches it: replies it did not send, and the author's run",
       ctx do
    thread = read(ctx.state, %{"uri" => ctx.anchor})
    [first | _] = thread["replies"]
    [recorded_first | _] = for item <- ctx.recorded["thread"], item["depth"] == 1, do: item
    assert first["replies_omitted"] == recorded_first["value"]["moreReplies"]

    # The root and the post continue the author's own run, which the app numbers.
    assert thread["parent"]["op_thread_index"] ==
             hd(ctx.recorded["thread"])["value"]["opThreadPostIndex"]

    assert thread["other_replies"] == ctx.recorded["hasOtherReplies"]

    {:ok, %{content: [%{text: text}]}, _} =
      AtMcp.MCP.Server.handle_call_tool(
        "get_thread",
        %{"uri" => ctx.anchor},
        Map.delete(ctx.state, :format)
      )

    assert text =~ "[this post]"
    assert text =~ "[reply 1]"
    assert text =~ "[reply 1.1.1]"

    if thread["other_replies"],
      do: assert(text =~ "The app leaves some replies out of this thread.")
  end
end
