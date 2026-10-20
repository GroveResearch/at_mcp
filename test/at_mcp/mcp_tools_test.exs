defmodule AtMcp.MCP.ToolsTest do
  use ExUnit.Case, async: true

  alias AtMcp.Test.Schema

  require AtMcp.MCP.Schemas

  test "identity_status reports the account quota over mock effects" do
    {:ok, effects} =
      AtMcp.Test.QuotaFixture.start_effects(backend: AtMcp.Test.MockBackend, quota_limit: 3)

    assert {:ok, _} = AtMcp.Effects.login(effects)

    assert {:ok, %{action: :repost}} =
             AtMcp.Effects.repost(effects, "at://did:plc:x/app.bsky.feed.post/1", "cid")

    assert AtMcp.Effects.quota_status(effects).used == 1

    assert {:ok, status} = AtMcp.MCP.Tools.identity_status(effects)
    assert status.logged_in == true
    assert status.login_count == 1
    assert status.write_quota.limit == 3
  end

  test "identity_status reports the write quota reset as one ISO8601 time" do
    dir = Path.join(System.tmp_dir!(), "at_mcp-status-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)

    quota =
      start_supervised!(
        {AtMcp.WriteQuota,
         name: nil, state_dir: dir, limit: 4, window_seconds: 60, clock: fn -> 60 end}
      )

    {:ok, effects} =
      AtMcp.Test.QuotaFixture.start_effects(backend: AtMcp.Test.MockBackend, write_quota: quota)

    assert {:ok, _} = AtMcp.Effects.login(effects)

    # The configured limit and window, not the defaults.
    assert {:ok, %{write_quota: %{limit: 4, window_seconds: 60, resets_at: nil, used: 0}}} =
             AtMcp.MCP.Tools.identity_status(effects)

    assert {:ok, _} = AtMcp.Effects.repost(effects, "at://did:plc:x/app.bsky.feed.post/1", "cid")

    assert {:ok, %{write_quota: %{used: 1, resets_at: "1970-01-01T00:02:00Z"}}} =
             AtMcp.MCP.Tools.identity_status(effects)
  end

  test "respond formats errors for MCP" do
    state = %{effects: :unused}

    assert {:ok, %{isError: true, content: [%{text: text}]}, ^state} =
             AtMcp.MCP.Tools.respond({:error, :not_connected}, state)

    assert text =~ "not connected"

    assert {:ok, %{content: [%{text: text}], structuredContent: structured}, ^state} =
             AtMcp.MCP.Tools.respond({:ok, %{count: 1}}, state)

    assert text =~ "count"
    assert structured == %{"count" => 1}
  end

  test "quota and connection failures give stable codes alongside their guidance" do
    for {reason, code, guidance} <- [
          {:not_connected, "not_connected", "not connected"},
          {:write_quota_unavailable, "write_quota_unavailable", "writes remain paused"}
        ] do
      assert {:ok, %{isError: true, structuredContent: %{code: ^code}, content: [%{text: text}]},
              :state} = AtMcp.MCP.Tools.respond({:error, reason}, :state)

      assert text =~ guidance
    end

    assert {:ok,
            %{
              isError: true,
              structuredContent: %{
                code: "write_quota_exhausted",
                resets_at: "1970-01-01T00:02:00Z"
              },
              content: [%{text: text}]
            }, :state} =
             AtMcp.MCP.Tools.respond({:error, {:write_quota_exhausted, 120}}, :state)

    assert text =~ "1970-01-01T00:02:00Z"
  end

  test "a service failure reports what it said and whether retrying can help" do
    cases = [
      {400, "Profile not found", "upstream_rejected", "Check the request"},
      {429, "Rate Limit Exceeded", "upstream_rate_limited", "Wait before retrying"},
      {501, "Operation unavailable", "upstream_not_implemented", "not implemented"},
      {503, "Service Unavailable", "upstream_unavailable", "was not applied"}
    ]

    for {status, message, code, guidance} <- cases do
      kind = if status >= 500, do: :indeterminate, else: :refused
      upstream = AtMcp.Effects.Failure.new(kind, status: status, message: message)

      assert {:ok,
              %{
                isError: true,
                structuredContent: %{
                  code: ^code,
                  http_status: ^status,
                  upstream_message: ^message
                },
                content: [%{text: text}]
              }, :state} = AtMcp.MCP.Tools.respond({:error, upstream}, :state)

      assert text =~ message
      assert text =~ to_string(status)
      assert text =~ guidance
      refute text =~ "ProtoRune"
      refute text =~ "%"
    end
  end

  test "batch reads name their own limit before any request leaves the machine" do
    {:ok, effects} = AtMcp.Test.QuotaFixture.start_effects(backend: AtMcp.Test.MockBackend)
    assert {:ok, _} = AtMcp.Effects.login(effects)

    oversized = Enum.map(1..26, &"at://did:plc:mock/app.bsky.feed.post/#{&1}")
    assert {:error, :batch_too_large} = AtMcp.Effects.get_posts(effects, oversized)
    assert {:error, :batch_too_large} = AtMcp.Effects.get_profiles(effects, oversized)
    assert {:error, :empty_batch} = AtMcp.Effects.get_posts(effects, [])
    assert {:error, :empty_batch} = AtMcp.Effects.get_profiles(effects, [])

    assert {:ok, _} = AtMcp.Effects.get_posts(effects, Enum.take(oversized, 25))

    assert {:ok,
            %{
              isError: true,
              structuredContent: %{code: "batch_too_large"},
              content: [%{text: text}]
            }, :state} = AtMcp.MCP.Tools.respond({:error, :batch_too_large}, :state)

    assert text =~ "at most 25"
  end

  # Every tool, called the way a client calls it. Check the contract explicitly:
  # runtime validation diagnoses a mismatch but cannot undo a completed action.
  @calls [
    {"get_notifications", %{}},
    {"get_unread_count", %{}},
    {"get_timeline", %{}},
    {"get_author_feed", %{"actor" => "alice.test"}},
    {"get_thread", %{"uri" => "at://did:plc:mock/app.bsky.feed.post/1"}},
    {"get_thread_chain", %{"uri" => "at://did:plc:mock/app.bsky.feed.post/1"}},
    {"get_posts", %{"uris" => ["at://did:plc:mock/app.bsky.feed.post/1"]}},
    {"get_post_images", %{"uri" => "at://did:plc:mock/app.bsky.feed.post/1"}},
    {"get_profile", %{}},
    {"get_profiles", %{"actors" => ["alice.test"]}},
    {"search_posts", %{"query" => "at_mcp"}},
    {"search_actors", %{"query" => "at_mcp"}},
    {"get_followers", %{"actor" => "alice.test"}},
    {"get_follows", %{"actor" => "alice.test"}},
    {"get_known_followers", %{"actor" => "alice.test"}},
    {"get_suggested_follows", %{"actor" => "alice.test"}},
    {"get_blocks", %{}},
    {"get_mutes", %{}},
    {"get_relationships", %{"actor" => "alice.test", "others" => ["bob.test"]}},
    {"get_likes", %{"uri" => "at://did:plc:mock/app.bsky.feed.post/1"}},
    {"get_reposted_by", %{"uri" => "at://did:plc:mock/app.bsky.feed.post/1"}},
    {"get_quotes", %{"uri" => "at://did:plc:mock/app.bsky.feed.post/1"}},
    {"get_actor_likes", %{"actor" => "alice.test"}},
    {"get_feed", %{"feed" => "at://did:plc:mock/app.bsky.feed.generator/whats-hot"}},
    {"get_suggested_feeds", %{}},
    {"get_feed_info", %{"uris" => ["at://did:plc:mock/app.bsky.feed.generator/whats-hot"]}},
    {"get_actor_feeds", %{"actor" => "alice.test"}},
    {"search_feeds", %{"query" => "cats"}},
    {"get_suggested_starter_packs", %{"context" => "onboarding"}},
    {"get_trends", %{"kind" => "topics"}},
    {"get_record", %{"uri" => "at://did:plc:mock/app.bsky.feed.post/1"}},
    {"get_invite_codes", %{}},
    {"get_list_feed", %{"list" => "at://did:plc:mock/app.bsky.graph.list/friends"}},
    {"get_list", %{"uri" => "at://did:plc:mock/app.bsky.graph.list/friends"}},
    {"get_lists", %{"actor" => "alice.test", "purpose" => "curate"}},
    {"get_starter_pack", %{"uri" => "at://did:plc:mock/app.bsky.graph.starterpack/p1"}},
    {"get_starter_packs", %{"query" => "agents"}},
    {"create_list", %{"name" => "Friends", "purpose" => "curate"}},
    {"update_list",
     %{"uri" => "at://did:plc:mock/app.bsky.graph.list/friends", "name" => "Old friends"}},
    {"delete_list", %{"uri" => "at://did:plc:mock/app.bsky.graph.list/friends"}},
    {"add_to_list",
     %{"list" => "at://did:plc:mock/app.bsky.graph.list/friends", "actor" => "alice.test"}},
    {"remove_from_list",
     %{"list" => "at://did:plc:mock/app.bsky.graph.list/friends", "actor" => "alice.test"}},
    {"create_starter_pack", %{"name" => "Agents", "actors" => ["alice.test"]}},
    {"update_starter_pack",
     %{"uri" => "at://did:plc:mock/app.bsky.graph.starterpack/p1", "name" => "Agents too"}},
    {"delete_starter_pack", %{"uri" => "at://did:plc:mock/app.bsky.graph.starterpack/p1"}},
    {"set_list_opt_out",
     %{"list" => "at://did:plc:other/app.bsky.graph.starterpack/p1", "opted_out" => true}},
    {"post", %{"text" => "café 日本語 🪁"}},
    {"reply", %{"uri" => "at://did:plc:mock/app.bsky.feed.post/1", "text" => "reply"}},
    {"like", %{"uri" => "at://did:plc:mock/app.bsky.feed.post/1", "cid" => "bafyfixture"}},
    {"unlike", %{"uri" => "at://did:plc:mock/app.bsky.feed.like/1"}},
    {"repost", %{"uri" => "at://did:plc:mock/app.bsky.feed.post/1", "cid" => "bafyfixture"}},
    {"unrepost", %{"uri" => "at://did:plc:mock/app.bsky.feed.repost/1"}},
    {"follow", %{"actor" => "alice.test"}},
    {"unfollow", %{"uri" => "at://did:plc:mock/app.bsky.graph.follow/1"}},
    {"block", %{"actor" => "alice.test"}},
    {"unblock", %{"uri" => "at://did:plc:mock/app.bsky.graph.block/1"}},
    {"mute", %{"actor" => "alice.test"}},
    {"unmute", %{"actor" => "alice.test"}},
    {"delete_post", %{"uri" => "at://did:plc:mock/app.bsky.feed.post/1"}},
    {"update_profile",
     %{
       "display_name" => "AtMcp",
       "pronouns" => "it/its",
       "links" => [%{"url" => "https://example.com", "title" => "Home"}]
     }},
    {"update_seen", %{}},
    {"pin_post", %{"uri" => "at://did:plc:mock/app.bsky.feed.post/1"}},
    {"unpin_post", %{}},
    {"mute_thread", %{"uri" => "at://did:plc:mock/app.bsky.feed.post/1"}},
    {"unmute_thread", %{"uri" => "at://did:plc:mock/app.bsky.feed.post/1"}},
    {"bookmark", %{"uri" => "at://did:plc:mock/app.bsky.feed.post/1"}},
    {"unbookmark", %{"uri" => "at://did:plc:mock/app.bsky.feed.post/1"}},
    {"get_bookmarks", %{}},
    {"get_drafts", %{}},
    {"set_post_interactions", %{"uri" => "at://did:plc:mock/app.bsky.feed.post/1"}},
    {"hide_reply", %{"uri" => "at://did:plc:other/app.bsky.feed.post/reply"}},
    {"unhide_reply", %{"uri" => "at://did:plc:other/app.bsky.feed.post/reply"}},
    {"detach_quote", %{"uri" => "at://did:plc:other/app.bsky.feed.post/quote"}},
    {"reattach_quote", %{"uri" => "at://did:plc:other/app.bsky.feed.post/quote"}},
    {"save_feed", %{"uri" => "at://did:plc:mock/app.bsky.feed.generator/whats-hot"}},
    {"unsave_feed", %{"uri" => "at://did:plc:mock/app.bsky.feed.generator/whats-hot"}},
    {"set_status",
     %{"kind" => "live", "url" => "https://twitch.tv/mock", "duration_minutes" => 30}},
    {"feed_feedback",
     %{
       "feed" => "at://did:plc:mock/app.bsky.feed.generator/whats-hot",
       "uri" => "at://did:plc:mock/app.bsky.feed.post/1",
       "kind" => "show_more"
     }},
    {"save_draft", %{"text" => "later"}},
    {"delete_draft", %{"id" => "3mockdraft"}},
    {"get_preferences", %{}},
    {"set_preference", %{"kind" => "threads", "sort" => "oldest"}},
    {"get_notification_settings", %{}},
    {"set_notification_setting", %{"reason" => "like", "include" => "follows"}},
    {"subscribe_to_activity", %{"actor" => "alice.test", "posts" => true, "replies" => true}},
    {"get_activity_subscriptions", %{}},
    {"report",
     %{"subject" => "at://alice.test/app.bsky.feed.post/1", "reason" => "spam", "details" => "x"}},
    {"mute_word", %{"value" => "#spoilers", "duration" => "7d", "tags_only" => true}},
    {"unmute_word", %{"value" => "spoilers"}},
    {"mute_list", %{"uri" => "at://did:plc:alice/app.bsky.graph.list/l1"}},
    {"unmute_list", %{"uri" => "at://did:plc:alice/app.bsky.graph.list/l1"}},
    {"block_list", %{"uri" => "at://did:plc:alice/app.bsky.graph.list/l1"}},
    {"unblock_list", %{"uri" => "at://did:plc:alice/app.bsky.graph.list/l1"}},
    {"get_moderation_lists", %{"kind" => "blocked"}},
    {"get_labelers", %{"actors" => ["labeler.test"]}},
    {"subscribe_labeler", %{"actor" => "labeler.test"}},
    {"unsubscribe_labeler", %{"actor" => "labeler.test"}},
    {"set_label_visibility", %{"label" => "porn", "visibility" => "warn"}},
    {"get_membership", %{}},
    {"identity_status", %{}}
  ]

  @readings %{
    "get_notifications" => :notifications,
    "get_timeline" => :posts,
    "get_author_feed" => :posts,
    "get_posts" => :posts,
    "search_posts" => :posts,
    "get_quotes" => :posts,
    "get_actor_likes" => :posts,
    "get_feed" => :posts,
    "get_list_feed" => :posts,
    "get_thread" => :thread,
    "get_thread_chain" => :chain,
    "get_profile" => :profile,
    "get_profiles" => :profiles,
    "search_actors" => :profiles,
    "get_followers" => :profiles,
    "get_follows" => :profiles,
    "get_known_followers" => :profiles,
    "get_suggested_follows" => :profiles,
    "get_blocks" => :profiles,
    "get_mutes" => :profiles,
    "get_likes" => :profiles,
    "get_reposted_by" => :profiles,
    "get_list" => :list,
    "get_moderation_lists" => :lists,
    "get_labelers" => :labelers,
    "get_lists" => :lists,
    "get_starter_pack" => :starter_pack,
    "get_starter_packs" => :starter_packs,
    "get_bookmarks" => :bookmarks,
    "get_suggested_feeds" => :feeds,
    "get_feed_info" => :feeds,
    "get_actor_feeds" => :feeds,
    "search_feeds" => :feeds,
    "get_suggested_starter_packs" => :starter_packs,
    "get_trends" => :trends,
    "get_invite_codes" => :invite_codes,
    "get_preferences" => :preferences,
    "get_notification_settings" => :notification_settings,
    "get_activity_subscriptions" => :profiles
  }

  test "every tool returns structured content its declared schema accepts" do
    {:ok, effects} =
      AtMcp.Test.QuotaFixture.start_effects(backend: AtMcp.Test.MockBackend, quota_limit: 100)

    assert {:ok, _} = AtMcp.Effects.login(effects)
    state = %{effects: effects}

    {:ok, tools, nil, ^state} = AtMcp.MCP.Server.handle_list_tools(nil, state)

    assert Enum.map(tools, & &1.name) |> Enum.sort() ==
             @calls |> Enum.map(&elem(&1, 0)) |> Enum.sort()

    for {name, arguments} <- @calls do
      assert {:ok, result, ^state} = AtMcp.MCP.Server.handle_call_tool(name, arguments, state)
      refute result[:isError], "#{name}: #{inspect(result)}"

      schema = Enum.find(tools, &(&1.name == name)).outputSchema
      assert Schema.valid?(result.structuredContent, schema), "#{name} output schema"

      # What a model reads: the JSON of the structured content, or for a read
      # made of posts, `AtMcp.Reading`'s text of it and nothing else.
      text = Enum.find(result.content, &(&1.type == "text")).text

      case @readings[name] do
        nil ->
          assert result.structuredContent == Jason.decode!(text), "#{name} structured content"

        reading ->
          assert text == apply(AtMcp.Reading, reading, [result.structuredContent]), name
      end
    end
  end

  test "a declared schema rejects a shape from a different tool" do
    {:ok, tools, nil, :state} = AtMcp.MCP.Server.handle_list_tools(nil, :state)
    schema = fn name -> Enum.find(tools, &(&1.name == name)).outputSchema end

    page = %{"count" => 1, "items" => [%{"uri" => "at://did:plc:x/app.bsky.feed.post/1"}]}
    status = %{"logged_in" => true, "login_count" => 1}

    assert Schema.valid?(page, schema.("get_timeline"))
    assert Schema.valid?(status, schema.("identity_status"))
    refute Schema.valid?(status, schema.("get_timeline"))
    refute Schema.valid?(page, schema.("identity_status"))

    # A failure still validates, or a reported code would become a validation error.
    assert Schema.valid?(%{"code" => "account_disconnected"}, schema.("get_timeline"))
    assert Schema.valid?(%{"code" => "write_quota_exhausted"}, schema.("post"))
  end

  test "page schemas describe the records their own tool returns" do
    {:ok, tools, nil, :state} = AtMcp.MCP.Server.handle_list_tools(nil, :state)

    items = fn name ->
      Enum.find(tools, &(&1.name == name)).outputSchema["properties"]["items"]["items"][
        "properties"
      ]
    end

    for name <- [
          "get_timeline",
          "get_author_feed",
          "get_posts",
          "search_posts",
          "get_quotes",
          "get_actor_likes",
          "get_feed",
          "get_list_feed"
        ] do
      assert Map.has_key?(items.(name), "author_did"), "#{name} does not describe posts"
    end

    assert Map.has_key?(items.("get_suggested_feeds"), "creator_did")

    for name <- [
          "get_profiles",
          "search_actors",
          "get_followers",
          "get_follows",
          "get_known_followers",
          "get_suggested_follows",
          "get_blocks",
          "get_mutes",
          "get_likes",
          "get_reposted_by"
        ] do
      assert Map.has_key?(items.(name), "handle"), "#{name} does not describe profiles"
    end

    # A relationship is neither a post nor a profile: it is how two accounts
    # stand to each other, in both directions.
    assert Map.has_key?(items.("get_relationships"), "followed_by")

    # Notifications one at a time, or the groups the app shows.
    assert [one, group] =
             Enum.find(tools, &(&1.name == "get_notifications")).outputSchema["properties"][
               "items"
             ]["items"]["anyOf"]

    assert Map.has_key?(one["properties"], "reason")
    assert Map.has_key?(group["properties"], "actors")

    # A list's page is its members, and the list rides beside them; lists and
    # starter packs are neither posts nor profiles.
    assert Map.has_key?(items.("get_list"), "item_uri")
    assert Map.has_key?(items.("get_lists"), "purpose")
    assert Map.has_key?(items.("get_starter_packs"), "members_sample")
  end

  test "account failures give stable codes and a recovery action" do
    for {code, guidance} <- [
          account_disconnected: "Reconnect it through at_mcp's account controls",
          account_identity_changed: "Stop using this connection",
          account_runtime_unavailable: "inspect the account records",
          post_text_too_long: "300 Unicode graphemes and 3000 UTF-8 bytes",
          invalid_post_text: "valid UTF-8"
        ] do
      assert {:ok, %{isError: true, structuredContent: %{code: name}, content: [%{text: text}]},
              :state} =
               AtMcp.MCP.Tools.respond({:error, code}, :state)

      assert name == Atom.to_string(code)
      assert text =~ guidance
    end

    assert {:ok,
            %{
              isError: true,
              structuredContent: %{code: "write_outcome_unknown", outcome: "unknown"}
            } = result, :state} =
             AtMcp.MCP.Tools.respond(
               {:error, {:write_outcome_unknown, "private backend detail"}},
               :state
             )

    refute Jason.encode!(result) =~ "private backend detail"
  end

  test "a complete feed page retains Unicode posts, record references, and its continuation cursor" do
    state = %{effects: :unused}
    post_text = String.duplicate("🪁日本語é", 60)
    assert String.length(post_text) == 300

    items =
      Enum.map(1..20, fn n ->
        %{
          uri: "at://did:plc:example/app.bsky.feed.post/#{n}",
          cid: "bafyreipost#{n}",
          author: "colleague#{n}.example",
          text: post_text
        }
      end)

    page = %{count: 20, items: items, cursor: "2026-09-07T18:42:00.000Z::next-page"}
    assert String.length(Jason.encode!(page)) > 8_000

    assert {:ok, %{content: [%{text: text}], structuredContent: structured}, ^state} =
             AtMcp.MCP.Tools.respond({:ok, page}, state)

    assert {:ok, decoded} = Jason.decode(text)
    assert decoded == structured
    assert decoded["cursor"] == page.cursor
    assert decoded["count"] == 20
    assert Enum.map(decoded["items"], & &1["uri"]) == Enum.map(items, & &1.uri)
    assert Enum.map(decoded["items"], & &1["cid"]) == Enum.map(items, & &1.cid)
    assert Enum.all?(decoded["items"], &(&1["text"] == post_text))
  end

  test "long text is preserved and failure remains an MCP error rather than a success value" do
    state = %{effects: :unused}
    text = String.duplicate("A quoted line with a at_mcp 🪁.\n", 400)
    assert {:ok, ^text, ^state} = AtMcp.MCP.Tools.respond({:ok, text}, state)

    assert {:ok, %{isError: true, content: [%{type: "text", text: error}]}, ^state} =
             AtMcp.MCP.Tools.respond({:error, {:write_quota_exhausted, 1_788_800_000}}, state)

    assert error =~ "account write quota exhausted"
    assert error =~ DateTime.to_iso8601(DateTime.from_unix!(1_788_800_000))
  end

  # What a model reads is every tool's description, its parameter and result
  # descriptions, and the errors it is handed. A surface that names one network
  # on a server that runs on two, or has a second word for the write quota, is a
  # defect even when every call works. This holds the wording where a rename
  # cannot quietly undo it.
  test "nothing a model reads names one network or a second word for the write quota" do
    {:ok, tools, nil, :state} = AtMcp.MCP.Server.handle_list_tools(nil, :state)
    assert length(tools) > 20

    errors =
      [
        :not_connected,
        :account_disconnected,
        :invalid_post_text,
        :post_text_too_long,
        :write_quota_unavailable,
        {:referenced_record_unreadable, "at://did:plc:x/app.bsky.feed.post/1", :not_found},
        {:write_quota_exhausted, 1_788_800_000}
      ]
      |> Enum.map(fn reason ->
        {:ok, %{content: [%{text: text}]}, :state} =
          AtMcp.MCP.Tools.respond({:error, reason}, :state)

        text
      end)

    text =
      Enum.flat_map(tools, fn tool ->
        [tool.description | descriptions(tool.inputSchema) ++ descriptions(tool.outputSchema)]
      end) ++ errors

    for phrase <- ["Bluesky", "bluesky", "budget", "allowance"] do
      offenders = Enum.filter(text, &String.contains?(&1, phrase))
      assert offenders == [], "#{phrase} appears in: #{inspect(offenders)}"
    end
  end

  defp descriptions(schema) when is_map(schema) do
    own =
      Enum.flat_map(schema, fn
        {key, value} when key in [:description, "description"] and is_binary(value) -> [value]
        _ -> []
      end)

    own ++ Enum.flat_map(Map.values(schema), &descriptions/1)
  end

  defp descriptions(list) when is_list(list), do: Enum.flat_map(list, &descriptions/1)
  defp descriptions(_), do: []
end
