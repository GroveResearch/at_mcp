defmodule AtMcp.EffectsTest do
  use ExUnit.Case, async: true

  # One session per Effects process.
  test "login once; multiple verbs share the same session" do
    {:ok, effects} =
      AtMcp.Test.QuotaFixture.start_effects(
        backend: AtMcp.Test.MockBackend,
        quota_limit: 3
      )

    assert {:ok, %{status: :connected, login_count: 1}} = AtMcp.Effects.login(effects)
    assert AtMcp.Effects.login_count(effects) == 1

    assert {:ok, %{count: 1}} = AtMcp.Effects.list_notifications(effects)

    assert {:ok, %{cid: "bafyTHREADCID"}} =
             AtMcp.Effects.get_thread(effects, "at://did:plc:x/app.bsky.feed.post/1")

    # A second login reuses the session rather than counting again.
    assert {:ok, %{status: :already_connected, login_count: 1}} = AtMcp.Effects.login(effects)
    assert AtMcp.Effects.login_count(effects) == 1
  end

  test "new read verbs are callable via mock backend" do
    {:ok, effects} =
      AtMcp.Test.QuotaFixture.start_effects(backend: AtMcp.Test.MockBackend, quota_limit: 5)

    assert {:ok, _} = AtMcp.Effects.login(effects)

    assert {:ok, %{handle: "alice.bsky.social"}} =
             AtMcp.Effects.get_profile(effects, "alice.bsky.social")

    assert {:ok, %{count: 2}} = AtMcp.Effects.get_profiles(effects, ["a", "b"])

    assert {:ok, %{count: 1}} =
             AtMcp.Effects.get_posts(effects, ["at://did:plc:x/app.bsky.feed.post/1"])

    assert {:ok, %{query: "elixir"}} = AtMcp.Effects.search_posts(effects, "elixir")
    assert {:ok, %{query: "alice"}} = AtMcp.Effects.search_actors(effects, "alice")
    assert {:ok, %{count: 1}} = AtMcp.Effects.get_unread_count(effects)
    assert {:ok, %{count: 0}} = AtMcp.Effects.get_timeline(effects)

    assert {:ok, %{actor: "bob.bsky.social"}} =
             AtMcp.Effects.get_author_feed(effects, "bob.bsky.social")
  end

  test "new write verbs are callable and only a repost counts against the write quota" do
    {:ok, effects} =
      AtMcp.Test.QuotaFixture.start_effects(backend: AtMcp.Test.MockBackend, quota_limit: 20)

    assert {:ok, _} = AtMcp.Effects.login(effects)

    assert {:ok, %{action: :like}} = AtMcp.Effects.like(effects, "at://u", "cid1")
    assert {:ok, %{action: :unlike}} = AtMcp.Effects.unlike(effects, "at://like")
    assert {:ok, %{action: :repost}} = AtMcp.Effects.repost(effects, "at://u", "cid1")
    assert {:ok, %{action: :unrepost}} = AtMcp.Effects.unrepost(effects, "at://rp")
    assert {:ok, %{action: :follow}} = AtMcp.Effects.follow(effects, "alice.bsky.social")
    assert {:ok, %{action: :unfollow}} = AtMcp.Effects.unfollow(effects, "at://follow")
    assert {:ok, %{action: :block}} = AtMcp.Effects.block(effects, "spam.bsky.social")
    assert {:ok, %{action: :unblock}} = AtMcp.Effects.unblock(effects, "at://block")
    assert {:ok, %{action: :mute}} = AtMcp.Effects.mute(effects, "noisy.bsky.social")
    assert {:ok, %{action: :unmute}} = AtMcp.Effects.unmute(effects, "noisy.bsky.social")
    assert {:ok, %{action: :delete_post}} = AtMcp.Effects.delete_post(effects, "at://post")

    assert {:ok, %{action: :update_profile}} =
             AtMcp.Effects.update_profile(effects, display_name: "Grug", description: "rocks")

    assert AtMcp.Effects.quota_status(effects).used == 1
  end

  test "flatten_query repeats list keys so URI.encode_query does not raise" do
    flat =
      AtMcp.ATProto.flatten_query(%{
        uris: ["at://did:plc:a/app.bsky.feed.post/1", "at://did:plc:b/app.bsky.feed.post/2"],
        actor: "alice.bsky.social"
      })

    encoded = URI.encode_query(flat)
    uri_params = encoded |> String.split("&") |> Enum.filter(&String.starts_with?(&1, "uris="))
    assert length(uri_params) == 2
    assert encoded =~ "actor=alice.bsky.social"
  end

  test "expired token refreshes the session and retries the verb" do
    {:ok, effects} =
      AtMcp.Test.QuotaFixture.start_effects(backend: AtMcp.Test.MockBackend, quota_limit: 5)

    assert {:ok, _} = AtMcp.Effects.login(effects)
    assert 1 = AtMcp.Effects.login_count(effects)

    :sys.replace_state(effects, fn s ->
      error = AtMcp.Effects.Failure.new(:auth_refused, status: 400, detail: :expired_token)
      %{s | backend_state: Map.put(s.backend_state, :profile_error, error)}
    end)

    assert {:ok, %{handle: "alice.bsky.social"}} =
             AtMcp.Effects.get_profile(effects, "alice.bsky.social")

    state = :sys.get_state(effects)
    assert state.backend_state.refreshed
    refute Map.has_key?(state.backend_state, :profile_error)
    # A refresh is not a new login.
    assert AtMcp.Effects.login_count(effects) == 1
  end

  test "failed refresh falls back to re-login" do
    {:ok, effects} =
      AtMcp.Test.QuotaFixture.start_effects(backend: AtMcp.Test.MockBackend, quota_limit: 5)

    assert {:ok, _} = AtMcp.Effects.login(effects)

    :sys.replace_state(effects, fn s ->
      error = AtMcp.Effects.Failure.new(:auth_refused, status: 400, detail: :expired_token)

      %{
        s
        | backend_state:
            s.backend_state
            |> Map.put(:profile_error, error)
            |> Map.put(:refresh_fails, true)
      }
    end)

    assert {:ok, %{handle: "bob.bsky.social"}} =
             AtMcp.Effects.get_profile(effects, "bob.bsky.social")

    assert AtMcp.Effects.login_count(effects) == 2
  end

  test "updateSeen is declared with a string wire type (proto_rune 0.5.3 cannot send a DateTime)" do
    Code.ensure_loaded!(AtMcp.ATProto)
    assert function_exported?(AtMcp.ATProto, :update_seen, 2)

    proc =
      ProtoRune.XRPC.Procedure.new(AtMcp.Network.nsid("notification.updateSeen"),
        from: %{seen_at: {:required, :string}}
      )

    iso = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    assert {:ok, %{body: %{seen_at: ^iso}}} =
             ProtoRune.XRPC.Procedure.put_body(proc, %{seen_at: iso})

    assert %{seenAt: ^iso} = ProtoRune.Case.camelize_enum(%{seen_at: iso})
  end
end
