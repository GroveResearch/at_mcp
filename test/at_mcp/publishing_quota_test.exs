defmodule AtMcp.PublishingQuotaTest do
  @moduledoc """
  The write quota bounds what an account publishes: a post, a reply and a
  repost. A like, a follow and every other mutation go out with no writes left,
  and each tool's description says which of the two it is.
  """
  use ExUnit.Case, async: true

  # A quota of one, spent by a post, so every case below runs with none left.
  defp exhausted do
    {:ok, effects} =
      AtMcp.Test.QuotaFixture.start_effects(backend: AtMcp.Test.MockBackend, quota_limit: 1)

    assert {:ok, _} = AtMcp.Effects.login(effects)
    assert {:ok, _} = AtMcp.Effects.post(effects, "spends the only write")
    assert %{used: 1, limit: 1} = AtMcp.Effects.quota_status(effects)
    effects
  end

  test "a like and a follow go out with no writes left and spend nothing" do
    effects = exhausted()

    assert {:ok, %{action: :like}} =
             AtMcp.Effects.like(
               effects,
               "at://did:plc:mock/app.bsky.feed.post/3k22222222222",
               "cid"
             )

    assert {:ok, %{action: :follow}} = AtMcp.Effects.follow(effects, "alice.example")
    assert AtMcp.Effects.quota_status(effects).used == 1
  end

  test "a post, a reply and a repost are refused with no writes left" do
    effects = exhausted()

    assert {:error, {:write_quota_exhausted, _}} = AtMcp.Effects.post(effects, "one more")

    assert {:error, {:write_quota_exhausted, _}} =
             AtMcp.Effects.reply(
               effects,
               "at://did:plc:x/app.bsky.feed.post/3k22222222222",
               "one more"
             )

    assert {:error, {:write_quota_exhausted, _}} =
             AtMcp.Effects.repost(
               effects,
               "at://did:plc:x/app.bsky.feed.post/3k22222222222",
               "cid"
             )

    assert AtMcp.Effects.quota_status(effects).used == 1
  end

  test "only publishing counts" do
    assert AtMcp.Effects.publishing() == [:post, :reply, :repost]
  end

  # Every mutating tool, called through the MCP surface with no writes left:
  # the tools that the classification says publish are refused, the rest are
  # not, and each description carries the sentence the classification gives it.
  @arguments %{
    "post" => %{"text" => "t"},
    "reply" => %{"uri" => "at://did:plc:x/app.bsky.feed.post/3k22222222222", "text" => "t"},
    "like" => %{"uri" => "at://u", "cid" => "c"},
    "unlike" => %{"uri" => "at://l"},
    "repost" => %{"uri" => "at://did:plc:x/app.bsky.feed.post/3k22222222222", "cid" => "c"},
    "unrepost" => %{"uri" => "at://r"},
    "follow" => %{"actor" => "alice.example"},
    "unfollow" => %{"uri" => "at://f"},
    "block" => %{"actor" => "alice.example"},
    "unblock" => %{"uri" => "at://b"},
    "mute" => %{"actor" => "alice.example"},
    "unmute" => %{"actor" => "alice.example"},
    "delete_post" => %{"uri" => "at://p"},
    "update_profile" => %{"display_name" => "n"},
    "update_seen" => %{},
    "create_list" => %{"name" => "n", "purpose" => "curate"},
    "update_list" => %{"uri" => "at://did:plc:mock/app.bsky.graph.list/l", "name" => "n"},
    "delete_list" => %{"uri" => "at://did:plc:mock/app.bsky.graph.list/l"},
    "add_to_list" => %{"list" => "at://did:plc:mock/app.bsky.graph.list/l", "actor" => "a.test"},
    "remove_from_list" => %{
      "list" => "at://did:plc:mock/app.bsky.graph.list/l",
      "actor" => "a.test"
    },
    "create_starter_pack" => %{"name" => "n"},
    "update_starter_pack" => %{
      "uri" => "at://did:plc:mock/app.bsky.graph.starterpack/p",
      "name" => "n"
    },
    "delete_starter_pack" => %{"uri" => "at://did:plc:mock/app.bsky.graph.starterpack/p"},
    "set_list_opt_out" => %{
      "list" => "at://did:plc:x/app.bsky.graph.starterpack/p",
      "opted_out" => true
    },
    "pin_post" => %{"uri" => "at://did:plc:mock/app.bsky.feed.post/3k22222222222"},
    "unpin_post" => %{},
    "mute_thread" => %{"uri" => "at://did:plc:x/app.bsky.feed.post/3k22222222222"},
    "unmute_thread" => %{"uri" => "at://did:plc:x/app.bsky.feed.post/3k22222222222"},
    "bookmark" => %{"uri" => "at://did:plc:x/app.bsky.feed.post/3k22222222222"},
    "unbookmark" => %{"uri" => "at://did:plc:x/app.bsky.feed.post/3k22222222222"},
    "save_draft" => %{"text" => "later"},
    "delete_draft" => %{"id" => "3mockdraft"},
    "set_post_interactions" => %{"uri" => "at://did:plc:mock/app.bsky.feed.post/3k22222222222"},
    "hide_reply" => %{"uri" => "at://did:plc:x/app.bsky.feed.post/3k22222222222"},
    "unhide_reply" => %{"uri" => "at://did:plc:x/app.bsky.feed.post/3k22222222222"},
    "detach_quote" => %{"uri" => "at://did:plc:x/app.bsky.feed.post/3k22222222222"},
    "reattach_quote" => %{"uri" => "at://did:plc:x/app.bsky.feed.post/3k22222222222"},
    "save_feed" => %{"uri" => "at://did:plc:x/app.bsky.feed.generator/f", "pinned" => true},
    "unsave_feed" => %{"uri" => "at://did:plc:x/app.bsky.feed.generator/f"},
    "set_status" => %{
      "kind" => "live",
      "url" => "https://twitch.tv/x",
      "duration_minutes" => 30
    },
    "feed_feedback" => %{
      "feed" => "at://did:plc:x/app.bsky.feed.generator/f",
      "uri" => "at://did:plc:x/app.bsky.feed.post/3k22222222222",
      "kind" => "show_less"
    },
    "set_preference" => %{"kind" => "home_feed", "hide_reposts" => true},
    "set_notification_setting" => %{"reason" => "like", "push" => false},
    "subscribe_to_activity" => %{"actor" => "alice.example", "posts" => true, "replies" => false},
    "report" => %{"subject" => "alice.example", "reason" => "spam"},
    "mute_word" => %{"value" => "spoilers"},
    "unmute_word" => %{"value" => "spoilers"},
    "mute_list" => %{"uri" => "at://did:plc:x/app.bsky.graph.list/l"},
    "unmute_list" => %{"uri" => "at://did:plc:x/app.bsky.graph.list/l"},
    "block_list" => %{"uri" => "at://did:plc:x/app.bsky.graph.list/l"},
    "unblock_list" => %{"uri" => "at://did:plc:x/app.bsky.graph.list/l"},
    "subscribe_labeler" => %{"actor" => "labeler.example"},
    "unsubscribe_labeler" => %{"actor" => "labeler.example"},
    "set_label_visibility" => %{"label" => "porn", "visibility" => "hide"}
  }

  test "every mutating tool's description and annotation say what the quota does to it" do
    {:ok, tools, nil, :state} = AtMcp.MCP.Server.handle_list_tools(nil, :state)
    writes = Enum.reject(tools, &(&1.annotations[:readOnlyHint] == true))

    assert Enum.sort(Enum.map(writes, & &1.name)) == Enum.sort(Map.keys(@arguments))

    for tool <- writes do
      counts? = AtMcp.Effects.counts_against_quota?(String.to_existing_atom(tool.name))
      sentence = AtMcp.MCP.DSL.quota_sentence(counts?)

      assert tool.description =~ sentence, "#{tool.name}: #{tool.description}"
      assert tool.annotations[:"at_mcp/publicWrite"] == counts?, tool.name
      # The annotation's earlier name, kept until the release after next.
      assert tool.annotations[:"kite/publicWrite"] == counts?, tool.name
    end

    assert AtMcp.MCP.DSL.quota_sentence(true) =~ "Counts against"
    assert AtMcp.MCP.DSL.quota_sentence(false) =~ "Does not count against"
  end

  test "every mutating tool is refused at no writes left exactly when it publishes" do
    effects = exhausted()
    state = %{effects: effects}

    for {name, arguments} <- @arguments do
      {:ok, result, ^state} = AtMcp.MCP.Server.handle_call_tool(name, arguments, state)

      refused? =
        result[:isError] == true and
          get_in(result, [:structuredContent, :code]) == "write_quota_exhausted"

      assert refused? == AtMcp.Effects.counts_against_quota?(String.to_atom(name)),
             "#{name}: #{inspect(result)}"
    end

    assert AtMcp.Effects.quota_status(effects).used == 1
  end
end
