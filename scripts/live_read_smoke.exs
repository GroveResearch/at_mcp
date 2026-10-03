# MIX_ENV=test mix run --no-start scripts/live_read_smoke.exs
# Supply BLUESKY_HANDLE/BLUESKY_APP_PASSWORD (and _2) in the environment.
# No records are written, notifications are not marked seen, no host is nudged.
for suffix <- ["", "_2"] do
  handle = System.fetch_env!("BLUESKY_HANDLE" <> suffix)
  password = System.fetch_env!("BLUESKY_APP_PASSWORD" <> suffix)

  {:ok, effects} =
    AtMcp.Effects.start_link(
      handle: handle,
      password: password,
      write_quota: :read_probe_no_write_quota
    )

  {:ok, _} = AtMcp.Effects.login(effects)
  did = AtMcp.Effects.session_did(effects)

  check = fn name, result ->
    case result do
      {:ok, _} ->
        IO.puts("PASS #{handle} #{name}")

      {:error, reason} ->
        raise "#{handle} #{name} failed: #{AtMcp.MCP.Tools.format_reason(reason)}"
    end
  end

  check.("profile", AtMcp.Effects.get_profile(effects, did))
  check.("profiles", AtMcp.Effects.get_profiles(effects, [did]))
  check.("notifications", AtMcp.Effects.get_notifications(effects, limit: 3))
  check.("unread_count", AtMcp.Effects.get_unread_count(effects))
  check.("timeline", AtMcp.Effects.get_timeline(effects, limit: 3))
  {:ok, feed} = AtMcp.Effects.get_author_feed(effects, did, limit: 3)
  check.("author_feed", {:ok, feed})
  check.("search_actors", AtMcp.Effects.search_actors(effects, handle, limit: 3))
  check.("search_posts", AtMcp.Effects.search_posts(effects, "from:#{handle}", limit: 3))

  case Map.get(feed, :items, []) do
    [%{uri: uri} | _] ->
      check.("posts", AtMcp.Effects.get_posts(effects, [uri]))
      check.("thread", AtMcp.Effects.get_thread(effects, uri))

      # A unit test cannot prove the deployed AppView honours `parentHeight`
      # 1000; a service capping it lower looks exactly like a short thread.
      # What is checkable live is that the chain ends at the post asked for and
      # says whether it reached the root.
      case AtMcp.Effects.get_thread_chain(effects, uri) do
        {:ok, %{chain: chain, chain_truncated: truncated} = summary} = ok ->
          check.("thread_chain", ok)
          last = List.last(chain)

          IO.puts(
            "INFO #{handle} thread_chain length=#{length(chain)} truncated=#{truncated} " <>
              "root=#{summary.root_uri} ends_at_requested=#{last && last.uri == uri}"
          )

        other ->
          check.("thread_chain", other)
      end

    [] ->
      IO.puts("SKIP #{handle} posts/thread: account has no posts")
  end

  # Force an invalid access token, leaving the real refresh token untouched.
  Agent.update(effects, fn state ->
    %{
      state
      | backend_state: Map.put(state.backend_state, :access_jwt, "invalid-cutover-access-token")
    }
  end)

  check.("live_token_recovery", AtMcp.Effects.get_profile(effects, did))

  IO.puts(
    "PASS #{handle} final_did=#{AtMcp.Effects.session_did(effects)} login_count=#{AtMcp.Effects.login_count(effects)}"
  )

  Agent.stop(effects)
end
