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

    assert {:ok, %{action: :like}} = AtMcp.Effects.like(effects, "at://u", "cid")
    assert {:ok, %{action: :follow}} = AtMcp.Effects.follow(effects, "alice.example")
    assert AtMcp.Effects.quota_status(effects).used == 1
  end

  test "a post, a reply and a repost are refused with no writes left" do
    effects = exhausted()

    assert {:error, {:write_quota_exhausted, _}} = AtMcp.Effects.post(effects, "one more")

    assert {:error, {:write_quota_exhausted, _}} =
             AtMcp.Effects.reply(effects, "at://did:plc:x/app.bsky.feed.post/1", "one more")

    assert {:error, {:write_quota_exhausted, _}} = AtMcp.Effects.repost(effects, "at://u", "cid")
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
    "reply" => %{"uri" => "at://did:plc:x/app.bsky.feed.post/1", "text" => "t"},
    "like" => %{"uri" => "at://u", "cid" => "c"},
    "unlike" => %{"uri" => "at://l"},
    "repost" => %{"uri" => "at://u", "cid" => "c"},
    "unrepost" => %{"uri" => "at://r"},
    "follow" => %{"actor" => "alice.example"},
    "unfollow" => %{"uri" => "at://f"},
    "block" => %{"actor" => "alice.example"},
    "unblock" => %{"uri" => "at://b"},
    "mute" => %{"actor" => "alice.example"},
    "unmute" => %{"actor" => "alice.example"},
    "delete_post" => %{"uri" => "at://p"},
    "update_profile" => %{"display_name" => "n"},
    "update_seen" => %{}
  }

  test "every mutating tool's description and annotation say what the quota does to it" do
    {:ok, tools, nil, :state} = AtMcp.MCP.Server.handle_list_tools(nil, :state)
    writes = Enum.reject(tools, &(&1.annotations[:readOnlyHint] == true))

    assert Enum.sort(Enum.map(writes, & &1.name)) == Enum.sort(Map.keys(@arguments))

    for tool <- writes do
      counts? = AtMcp.Effects.counts_against_quota?(String.to_existing_atom(tool.name))
      sentence = AtMcp.MCP.DSL.quota_sentence(counts?)

      assert tool.description =~ sentence, "#{tool.name}: #{tool.description}"
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
