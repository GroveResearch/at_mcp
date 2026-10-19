defmodule AtMcp.E2E.RoundTripTest do
  @moduledoc """
  Every write tool against upstream's reference PDS and AppView (#107).

  The network is `@atproto/dev-env`'s TestNetwork on localhost
  (`AtMcp.Test.DevNetwork`), at the atproto commit the vendored lexicons come
  from. Two accounts are on it: `me`, the account AtMcp acts as, and `them`,
  another account, also driven through AtMcp, for what needs a second person:
  a post to like, a reply to hide, a quote to detach.

  Each test writes through a tool, reads the result back through the read
  tools as the AppView serves it, undoes the write, and reads again. Between a
  write and a read it waits until the AppView has indexed everything the PDS
  sequenced (`DevNetwork.sync/1`), so a read is never a guess at indexing lag.
  Where no read tool shows a write's effect, the test says so and reads the
  repository record (`get_record`) or, for preferences, the PDS directly.

  Run with scripts/e2e.sh, or `mix test --only e2e` with its environment; see
  docs/operations.md, "End-to-end round trips".
  """
  use ExUnit.Case, async: false

  alias AtMcp.Test.DevNetwork

  @moduletag :e2e
  @moduletag timeout: 300_000

  # A one-pixel PNG.
  @png "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="

  setup_all do
    {net, info} = DevNetwork.start()

    for {key, value} <- [
          network: :bluesky,
          # The network's moderation service is ozone's, as the PDS and the
          # AppView are configured with it.
          moderation_service: info["moderation"],
          appview: [
            service: info["appview_did"] <> "#bsky_appview",
            url: info["appview"] <> "/xrpc"
          ]
        ] do
      previous = Application.fetch_env(:at_mcp, key)
      Application.put_env(:at_mcp, key, value)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:at_mcp, key, value)
          :error -> Application.delete_env(:at_mcp, key)
        end
      end)
    end

    # Nothing here may reach past this machine.
    for url <- [info["pds"], info["appview"], AtMcp.Network.appview_url()],
        do: assert(URI.parse(url).host in ["localhost", "127.0.0.1"], url)

    account = fn %{"handle" => handle, "password" => password} = account ->
      effects =
        start_supervised!(
          {AtMcp.Effects,
           backend: AtMcp.Effects.ProtoRune,
           handle: handle,
           password: password,
           service: info["pds"],
           write_quota: AtMcp.Test.QuotaFixture.quota(1_000)},
          id: make_ref()
        )

      %{effects: effects, did: account["did"], handle: handle}
    end

    # A session of the account's own, outside AtMcp's tools, for reading what
    # no read tool shows (the account's preferences) and for writing what no
    # tool would (a write over a stale version).
    {:ok, session} =
      AtMcp.Effects.ProtoRune.login(
        handle: info["accounts"]["self"]["handle"],
        password: info["accounts"]["self"]["password"],
        service: info["pds"]
      )

    %{
      net: net,
      moderation: info["moderation"],
      feed: info["feed"],
      me: account.(info["accounts"]["self"]),
      them: account.(info["accounts"]["other"]),
      session: session
    }
  end

  # A tool call that must succeed; its structured result.
  defp call!(account, name, arguments) do
    result = call(account, name, arguments)
    refute result[:isError], "#{name}: #{hd(result.content).text}"
    result.structuredContent
  end

  # A tool call that must fail; its structured result.
  defp refused(account, name, arguments) do
    result = call(account, name, arguments)
    assert result[:isError], "#{name} succeeded: #{inspect(result.structuredContent)}"
    result.structuredContent
  end

  defp call(account, name, arguments) do
    state = %{effects: account.effects}
    {:ok, result, ^state} = AtMcp.MCP.Server.handle_call_tool(name, arguments, state)
    result
  end

  defp sync(net), do: assert(:ok = DevNetwork.sync(net))

  defp profile_uri(account), do: "at://#{account.did}/app.bsky.actor.profile/self"

  defp record(account, uri) do
    case call(account, "get_record", %{"uri" => uri}) do
      %{isError: true} -> nil
      result -> result.structuredContent["value"]
    end
  end

  defp post!(account, text, extra \\ %{}),
    do: call!(account, "post", Map.put(extra, "text", text))

  defp only_post(account, uri) do
    %{"items" => [post]} = call!(account, "get_posts", %{"uris" => [uri]})
    post
  end

  describe "posts and their gates" do
    test "post with reply and quote rules: the AppView enforces both, set_post_interactions lifts them, delete_post removes the post",
         %{net: net, me: me, them: them} do
      post = post!(me, "gated", %{"reply_rule" => ["following"], "quotes" => "disabled"})
      assert post["threadgate_uri"] && post["postgate_uri"]
      sync(net)

      assert %{"allow" => [%{"$type" => "app.bsky.feed.threadgate#followingRule"}]} =
               record(me, post["threadgate_uri"])

      assert %{"embeddingRules" => [%{"$type" => "app.bsky.feed.postgate#disableRule"}]} =
               record(me, post["postgate_uri"])

      # Its author may still reply and quote; the other account may not.
      assert %{"reply_disabled" => false, "embedding_disabled" => false} =
               call!(me, "get_thread", %{"uri" => post["uri"]})["viewer"]

      assert %{"reply_disabled" => true, "embedding_disabled" => true} =
               call!(them, "get_thread", %{"uri" => post["uri"]})["viewer"]

      lifted =
        call!(me, "set_post_interactions", %{
          "uri" => post["uri"],
          "reply_rule" => ["everyone"],
          "quotes" => "allowed"
        })

      assert %{"reply_rule" => ["everyone"], "quotes" => "allowed", "unchanged" => false} =
               lifted

      assert lifted["threadgate_uri"] == nil and lifted["postgate_uri"] == nil
      sync(net)

      assert record(me, post["threadgate_uri"]) == nil
      assert record(me, post["postgate_uri"]) == nil
      viewer = call!(them, "get_thread", %{"uri" => post["uri"]})["viewer"]
      refute viewer["reply_disabled"]
      refute viewer["embedding_disabled"]

      # Setting the same rules again writes nothing.
      assert %{"unchanged" => true} =
               call!(me, "set_post_interactions", %{
                 "uri" => post["uri"],
                 "reply_rule" => ["everyone"],
                 "quotes" => "allowed"
               })

      call!(me, "delete_post", %{"uri" => post["uri"]})
      sync(net)

      assert %{code: "not_found", uri: uri} = refused(me, "get_record", %{"uri" => post["uri"]})
      assert uri == post["uri"]
      assert %{"items" => []} = call!(me, "get_posts", %{"uris" => [post["uri"]]})
    end

    test "a reply the thread's rule forbids is refused before it is written",
         %{net: net, me: me, them: them} do
      # The PDS accepts a reply the threadgate excludes and the AppView leaves
      # it out of the thread, so the reply tool reads the parent's
      # viewer.reply_disabled first, as the app does.
      root = post!(me, "only people I follow may reply", %{"reply_rule" => ["following"]})
      sync(net)
      assert call!(them, "get_thread", %{"uri" => root["uri"]})["viewer"]["reply_disabled"]

      assert %{code: "reply_disabled", uri: uri} =
               refused(them, "reply", %{"uri" => root["uri"], "text" => "replying anyway"})

      assert uri == root["uri"]
      sync(net)

      refute Enum.any?(
               call!(them, "get_author_feed", %{"actor" => them.did})["items"],
               &(&1["text"] == "replying anyway")
             )

      thread = call!(me, "get_thread", %{"uri" => root["uri"]})
      assert thread["replies"] == []
      assert thread["reply_count"] == 0

      call!(me, "delete_post", %{"uri" => root["uri"]})
    end

    test "reply and delete_post: the reply shows in the thread, and is gone after",
         %{net: net, me: me, them: them} do
      root = post!(them, "a thread")
      sync(net)
      reply = call!(me, "reply", %{"uri" => root["uri"], "text" => "a reply"})
      assert reply["reply_to"] == root["uri"]
      sync(net)

      thread = call!(them, "get_thread", %{"uri" => root["uri"]})
      assert [%{"uri" => uri, "text" => "a reply"}] = thread["replies"]
      assert uri == reply["uri"]

      call!(me, "delete_post", %{"uri" => reply["uri"]})
      sync(net)
      assert call!(them, "get_thread", %{"uri" => root["uri"]})["replies"] == []
    end

    test "a post with an image: get_post_images reads the AppView's copy back",
         %{net: net, me: me} do
      post =
        post!(me, "a dot", %{
          "images" => [%{"data" => @png, "mime_type" => "image/png", "alt" => "one pixel"}]
        })

      sync(net)

      # get_post_images fetches the fullsize URL the view names; it must be
      # this machine's AppView.
      assert [%{"fullsize" => fullsize}] = only_post(me, post["uri"])["images"]
      assert URI.parse(fullsize).host == "localhost"

      assert %{"count" => 1, "images" => [%{"alt" => "one pixel", "status" => "attached"}]} =
               call!(me, "get_post_images", %{"uri" => post["uri"]})

      call!(me, "delete_post", %{"uri" => post["uri"]})
    end

    test "hide_reply and unhide_reply: the thread reads the reply as hidden, then not",
         %{net: net, me: me, them: them} do
      root = post!(me, "my thread")
      sync(net)
      reply = call!(them, "reply", %{"uri" => root["uri"], "text" => "a reply to hide"})
      sync(net)

      hidden = call!(me, "hide_reply", %{"uri" => reply["uri"]})
      assert hidden["subject_uri"] == root["uri"]
      sync(net)

      assert [%{"uri" => uri, "hidden_by_threadgate" => true}] =
               call!(me, "get_thread", %{"uri" => root["uri"]})["replies"]

      assert uri == reply["uri"]

      shown = call!(me, "unhide_reply", %{"uri" => reply["uri"]})
      # The threadgate held only the hidden reply, so it goes with it.
      assert shown["threadgate_uri"] == nil
      sync(net)

      assert [reply_view] = call!(me, "get_thread", %{"uri" => root["uri"]})["replies"]
      refute reply_view["hidden_by_threadgate"]
    end

    test "detach_quote and reattach_quote: the quoting post reads the quote as detached, then back",
         %{net: net, me: me, them: them} do
      quoted = post!(me, "quote me")
      sync(net)
      quoting = post!(them, "quoting you", %{"quote" => quoted["uri"]})
      sync(net)
      assert %{"status" => "available"} = only_post(them, quoting["uri"])["quote"]

      assert %{"subject_uri" => subject} =
               call!(me, "detach_quote", %{"uri" => quoting["uri"]})

      assert subject == quoted["uri"]
      sync(net)
      assert %{"status" => "detached"} = only_post(them, quoting["uri"])["quote"]

      call!(me, "reattach_quote", %{"uri" => quoting["uri"]})
      sync(net)

      assert %{"status" => "available", "text" => "quote me"} =
               only_post(them, quoting["uri"])["quote"]
    end
  end

  describe "the profile" do
    test "pin_post by a handle-form uri pins the DID form; unpin_post removes it",
         %{net: net, me: me} do
      post = post!(me, "pin me")
      sync(net)
      "at://" <> path = post["uri"]
      [_did, collection, rkey] = String.split(path, "/")
      by_handle = "at://#{me.handle}/#{collection}/#{rkey}"

      pinned = call!(me, "pin_post", %{"uri" => by_handle})
      assert pinned["subject_uri"] == post["uri"]
      sync(net)

      assert %{"uri" => uri, "cid" => cid} = record(me, profile_uri(me))["pinnedPost"]
      assert uri == post["uri"]
      assert cid == post["cid"]
      # The profile read shows it, as the app's profile page does.
      assert call!(me, "get_profile", %{})["pinned_post"] == post["uri"]

      assert %{"replaced_uri" => replaced} = call!(me, "unpin_post", %{})
      assert replaced == post["uri"]
      sync(net)
      refute Map.has_key?(record(me, profile_uri(me)), "pinnedPost")
      assert call!(me, "get_profile", %{})["pinned_post"] == nil

      # Nothing pinned: nothing written.
      assert %{"replaced_uri" => nil, "uri" => nil} = call!(me, "unpin_post", %{})
      call!(me, "delete_post", %{"uri" => post["uri"]})
    end

    test "update_profile writes over the version it read, keeps what it was not given, and removes what is emptied",
         %{net: net, me: me} do
      call!(me, "update_profile", %{
        "display_name" => "Round Trip",
        "description" => "written end to end",
        "pronouns" => "they/them",
        "website" => "https://example.com"
      })

      sync(net)

      assert %{
               "display_name" => "Round Trip",
               "description" => "written end to end",
               "pronouns" => "they/them",
               "website" => "https://example.com"
             } = call!(me, "get_profile", %{})

      call!(me, "update_profile", %{"display_name" => "Round Trip 2"})
      sync(net)

      assert %{
               "displayName" => "Round Trip 2",
               "description" => "written end to end",
               "pronouns" => "they/them",
               "website" => "https://example.com"
             } = record(me, profile_uri(me))

      assert %{"display_name" => "Round Trip 2"} = call!(me, "get_profile", %{})

      call!(me, "update_profile", %{"pronouns" => "", "website" => ""})
      sync(net)
      kept = record(me, profile_uri(me))
      refute Map.has_key?(kept, "pronouns")
      refute Map.has_key?(kept, "website")
      assert kept["displayName"] == "Round Trip 2"

      assert %{"pronouns" => nil, "website" => nil, "display_name" => "Round Trip 2"} =
               call!(me, "get_profile", %{})
    end

    test "update_profile with an avatar and links: the AppView serves the avatar from localhost, the profile names the link records",
         %{net: net, me: me} do
      written =
        call!(me, "update_profile", %{
          "avatar" => %{"data" => @png, "mime_type" => "image/png"},
          "links" => [%{"url" => "https://example.com/a", "title" => "A"}]
        })

      assert [%{"uri" => link_uri, "url" => "https://example.com/a"}] = written["links"]
      sync(net)

      avatar = call!(me, "get_profile", %{})["avatar"]
      assert URI.parse(avatar).host == "localhost"
      assert avatar =~ written["avatar_cid"]

      profile = record(me, profile_uri(me))
      assert profile["avatar"]["ref"]["$link"] == written["avatar_cid"]
      assert [%{"uri" => ^link_uri}] = profile["links"]
      assert %{"url" => "https://example.com/a", "title" => "A"} = record(me, link_uri)

      assert [%{"url" => "https://example.com/a", "title" => "A", "uri" => ^link_uri}] =
               call!(me, "get_profile", %{})["links"]

      removed = call!(me, "update_profile", %{"links" => []})
      assert removed["links"] == []
      sync(net)
      refute Map.has_key?(record(me, profile_uri(me)), "links")
      assert record(me, link_uri) == nil
    end

    test "the reference PDS answers a stale swap as AtMcp expects: InvalidSwap, for a record and for a commit",
         %{net: net, me: me, session: session} do
      # update_profile, pin_post, set_status and the list writes depend on the
      # service refusing a write over a version that moved. No tool can be
      # made to read a version that then moves, so this writes over a stale
      # one directly and checks the refusal is the one AtMcp recognizes.
      call!(me, "update_profile", %{"description" => "first"})
      sync(net)

      {:ok, %{"cid" => stale}} =
        AtMcp.ATProto.get_record_as_stored(session, %{
          repo: me.did,
          collection: "app.bsky.actor.profile",
          rkey: "self"
        })

      call!(me, "update_profile", %{"description" => "second"})

      assert {:error, %ProtoRune.XRPC.Error{reason: reason}} =
               AtMcp.ATProto.put_record(session, %{
                 repo: me.did,
                 collection: "app.bsky.actor.profile",
                 rkey: "self",
                 record: %{"$type" => "app.bsky.actor.profile", "description" => "stale"},
                 swap_record: stale
               })

      assert reason in [:invalid_swap, "invalid_swap"]
      assert record(me, profile_uri(me))["description"] == "second"

      # A null swap, which a write sends when it read no record, is refused
      # the same way once a record exists: a record another client created
      # in between is not written over.
      assert {:error, %ProtoRune.XRPC.Error{reason: reason}} =
               AtMcp.ATProto.put_record(session, %{
                 repo: me.did,
                 collection: "app.bsky.actor.profile",
                 rkey: "self",
                 record: %{"$type" => "app.bsky.actor.profile", "description" => "stale"},
                 swap_record: nil
               })

      assert reason in [:invalid_swap, "invalid_swap"]
      assert record(me, profile_uri(me))["description"] == "second"

      {:ok, commit} = AtMcp.ATProto.get_latest_commit(session, me.did)
      old_commit = commit[:cid] || commit["cid"]
      assert is_binary(old_commit)

      call!(me, "update_profile", %{"description" => "third"})

      assert {:error, %ProtoRune.XRPC.Error{reason: reason}} =
               AtMcp.ATProto.apply_writes(
                 session,
                 me.did,
                 [{:delete, "app.bsky.actor.profile", "self"}],
                 swap_commit: old_commit
               )

      assert reason in [:invalid_swap, "invalid_swap"]
      assert record(me, profile_uri(me))["description"] == "third"
    end

    test "set_status live, then clear: the status record is written and removed",
         %{net: net, me: me} do
      live =
        call!(me, "set_status", %{
          "kind" => "live",
          "url" => "https://www.twitch.tv/example",
          "duration_minutes" => 30,
          "title" => "streaming"
        })

      assert %{"status" => "live", "replaced" => nil, "duration_minutes" => 30} = live
      sync(net)

      assert %{
               "status" => "app.bsky.actor.status#live",
               "durationMinutes" => 30,
               "embed" => %{"external" => %{"uri" => "https://www.twitch.tv/example"}}
             } = record(me, live["uri"])

      # The profile read shows the Live badge and where it links.
      assert %{"active" => true, "url" => "https://www.twitch.tv/example"} =
               call!(me, "get_profile", %{})["status"]

      cleared = call!(me, "set_status", %{"kind" => "clear"})

      assert %{"url" => "https://www.twitch.tv/example", "duration_minutes" => 30} =
               cleared["replaced"]

      sync(net)
      assert record(me, live["uri"]) == nil
      assert call!(me, "get_profile", %{})["status"] == nil
    end
  end

  describe "interactions" do
    test "like and unlike, repost and unrepost, by a handle-form uri: the post's viewer and counts follow",
         %{net: net, me: me, them: them} do
      post = post!(them, "like and repost me")
      sync(net)

      # The AppView counts a like or a repost only when its subject is the
      # post's DID-form uri; both are given the handle form here.
      "at://" <> path = post["uri"]
      [_did, collection, rkey] = String.split(path, "/")
      by_handle = "at://#{them.handle}/#{collection}/#{rkey}"

      like = call!(me, "like", %{"uri" => by_handle, "cid" => post["cid"]})
      repost = call!(me, "repost", %{"uri" => by_handle, "cid" => post["cid"]})
      assert like["subject_uri"] == post["uri"]
      assert repost["subject_uri"] == post["uri"]
      sync(net)

      view = only_post(me, post["uri"])
      assert view["viewer"]["like"] == like["uri"]
      assert view["viewer"]["repost"] == repost["uri"]
      assert view["like_count"] == 1 and view["repost_count"] == 1

      assert %{"items" => [%{"did" => did}]} = call!(them, "get_likes", %{"uri" => post["uri"]})
      assert did == me.did

      assert %{"items" => [%{"did" => ^did}]} =
               call!(them, "get_reposted_by", %{"uri" => post["uri"]})

      call!(me, "unlike", %{"uri" => like["uri"]})
      call!(me, "unrepost", %{"uri" => repost["uri"]})
      sync(net)

      view = only_post(me, post["uri"])
      refute view["viewer"]["like"]
      refute view["viewer"]["repost"]
      assert view["like_count"] == 0 and view["repost_count"] == 0
    end

    test "like by the post's web link: it is read as the post's uri, and the link reads back beside it",
         %{net: net, me: me, them: them} do
      post = post!(them, "like me by my link")
      sync(net)

      # The link the app shares: the author by handle, on this network's web origin.
      "at://" <> path = post["uri"]
      [_did, _collection, rkey] = String.split(path, "/")
      link = "https://bsky.app/profile/#{them.handle}/post/#{rkey}"
      assert only_post(me, post["uri"])["web_url"] == link

      result = call(me, "like", %{"uri" => link})
      refute result[:isError], hd(result.content).text
      like = stringify(result.structuredContent)
      uri = post["uri"]
      assert [%{"argument" => "uri", "link" => ^link, "value" => ^uri}] = like["resolved"]
      assert like["subject_uri"] == uri
      assert List.last(result.content).text == "resolved: uri #{link} is #{uri}"
      sync(net)

      # Read back by the link too: the text names the link beside the uri.
      read = call(me, "get_posts", %{"uris" => [link]})
      refute read[:isError]
      text = hd(read.content).text
      assert text =~ "uri: #{uri}"
      assert text =~ "\nlink: #{link}"
      assert text =~ "You liked this: #{like["uri"]}"

      call!(me, "unlike", %{"uri" => like["uri"]})
    end

    test "like and repost without a cid take the post's own; a cid that is not its own is refused, naming it",
         %{net: net, me: me, them: them} do
      post = post!(them, "like me by uri alone")
      sync(net)

      wrong = String.replace(post["cid"], ~r/.$/, fn c -> if c == "a", do: "b", else: "a" end)

      assert %{"code" => "subject_cid_mismatch", "current_cid" => current} =
               refused(me, "repost", %{"uri" => post["uri"], "cid" => wrong})
               |> Jason.encode!()
               |> Jason.decode!()

      assert current == post["cid"]

      like = call!(me, "like", %{"uri" => post["uri"]})
      repost = call!(me, "repost", %{"uri" => post["uri"]})
      assert like["subject_cid"] == post["cid"]
      assert repost["subject_cid"] == post["cid"]
      assert record(me, like["uri"])["subject"] == %{"uri" => post["uri"], "cid" => post["cid"]}
      sync(net)

      view = only_post(me, post["uri"])
      assert view["viewer"]["like"] == like["uri"]
      assert view["viewer"]["repost"] == repost["uri"]
      assert view["like_count"] == 1 and view["repost_count"] == 1

      call!(me, "unlike", %{"uri" => like["uri"]})
      call!(me, "unrepost", %{"uri" => repost["uri"]})
    end

    test "like, repost, follow and block twice: the second answers the first, unchanged; an undo deletes every record of its kind for the subject",
         %{net: net, me: me, them: them, session: session} do
      post = post!(them, "like me twice")
      sync(net)

      on_post = %{"uri" => post["uri"], "cid" => post["cid"]}
      on_them = %{"actor" => them.handle}

      twice = fn name, args ->
        first = call!(me, name, args)
        refute first["unchanged"], name
        sync(net)
        again = call!(me, name, args)
        assert again["unchanged"] == true, name
        assert again["uri"] == first["uri"], name
        first
      end

      like = twice.("like", on_post)
      repost = twice.("repost", on_post)
      follow = twice.("follow", on_them)
      # Last, so the reads above are made with no block between the accounts.
      block = twice.("block", on_them)

      # A second record of each, as another client could leave. The reference
      # PDS's createRecord deletes a like, repost, follow or block with the
      # same subject before it writes a new one; applyWrites does not.
      subject = %{uri: post["uri"], cid: post["cid"]}

      second =
        for {kind, record} <- [
              like: AtMcp.ATProto.like_record(subject: subject),
              repost: AtMcp.ATProto.repost_record(subject: subject),
              follow: AtMcp.ATProto.follow_record(subject: them.did),
              block: AtMcp.ATProto.block_record(subject: them.did)
            ],
            into: %{} do
          collection = AtMcp.Network.collection(kind)
          [rkey] = AtMcp.ATProto.tids(1)

          {:ok, _} =
            AtMcp.ATProto.apply_writes(session, me.did, [{:create, collection, rkey, record}])

          {kind, "at://#{me.did}/#{collection}/#{rkey}"}
        end

      sync(net)

      relationship = fn ->
        %{"items" => [item]} =
          call!(me, "get_relationships", %{"actor" => me.did, "others" => [them.did]})

        item
      end

      # The record the AppView names for the subject now: one of the two.
      viewed = fn
        :block ->
          %{"items" => [%{"viewer" => %{"blocking" => uri}}]} = call!(me, "get_blocks", %{})
          uri

        :follow ->
          relationship.()["following"]

        kind ->
          only_post(me, post["uri"])["viewer"][Atom.to_string(kind)]
      end

      # The block goes first, so the post reads are made with no block between
      # the accounts. Each undo is given the record the AppView does not name,
      # as a caller holding a retried write's first answer would be, and takes
      # the one it names with it.
      for {name, first, kind} <- [
            {"unblock", block, :block},
            {"unfollow", follow, :follow},
            {"unlike", like, :like},
            {"unrepost", repost, :repost}
          ] do
        pair = [first["uri"], second[kind]]
        named_by_appview = viewed.(kind)
        assert named_by_appview in pair, "#{name}: #{inspect(named_by_appview)}"
        [given] = pair -- [named_by_appview]

        assert %{"deleted" => deleted} = call!(me, name, %{"uri" => given})
        assert deleted == [given, named_by_appview], "#{name} deleted #{inspect(deleted)}"
        sync(net)
      end

      for uri <- Map.values(second) ++ Enum.map([like, repost, follow, block], & &1["uri"]),
          do: assert(record(me, uri) == nil, uri)

      view = only_post(me, post["uri"])
      refute view["viewer"]["like"]
      refute view["viewer"]["repost"]
      assert view["like_count"] == 0 and view["repost_count"] == 0
      assert %{"items" => []} = call!(me, "get_blocks", %{})

      assert relationship.()["following"] == nil

      call!(them, "delete_post", %{"uri" => post["uri"]})
    end

    test "follow and unfollow: get_relationships names the follow record, then none",
         %{net: net, me: me, them: them} do
      follow = call!(me, "follow", %{"actor" => them.handle})
      assert follow["actor"] == them.did
      sync(net)

      relationship = fn ->
        %{"items" => [item]} =
          call!(me, "get_relationships", %{"actor" => me.did, "others" => [them.did]})

        item
      end

      assert relationship.()["following"] == follow["uri"]

      assert %{"items" => [%{"did" => did}]} =
               call!(them, "get_followers", %{"actor" => them.did})

      assert did == me.did

      call!(me, "unfollow", %{"uri" => follow["uri"]})
      sync(net)
      assert relationship.()["following"] == nil
    end

    test "block and unblock: get_blocks lists the account with the block record, then not",
         %{net: net, me: me, them: them} do
      block = call!(me, "block", %{"actor" => them.handle})
      sync(net)

      assert %{"items" => [%{"did" => did, "viewer" => %{"blocking" => uri}}]} =
               call!(me, "get_blocks", %{})

      assert did == them.did and uri == block["uri"]

      call!(me, "unblock", %{"uri" => block["uri"]})
      sync(net)
      assert %{"items" => []} = call!(me, "get_blocks", %{})
    end

    test "mute and unmute: get_mutes lists the account, then not",
         %{net: net, me: me, them: them} do
      call!(me, "mute", %{"actor" => them.handle})
      sync(net)
      assert %{"items" => [%{"did" => did}]} = call!(me, "get_mutes", %{})
      assert did == them.did

      call!(me, "unmute", %{"actor" => them.handle})
      sync(net)
      assert %{"items" => []} = call!(me, "get_mutes", %{})
    end

    test "mute_thread and unmute_thread: a reply names the thread, and the root reads as muted, then not",
         %{net: net, me: me, them: them} do
      root = post!(them, "a thread to mute")
      sync(net)
      reply = call!(them, "reply", %{"uri" => root["uri"], "text" => "deeper"})
      sync(net)

      assert %{"uri" => muted} = call!(me, "mute_thread", %{"uri" => reply["uri"]})
      assert muted == root["uri"]
      sync(net)
      assert only_post(me, root["uri"])["viewer"]["thread_muted"] == true

      call!(me, "unmute_thread", %{"uri" => reply["uri"]})
      sync(net)
      assert only_post(me, root["uri"])["viewer"]["thread_muted"] == false
    end

    test "bookmark and unbookmark: get_bookmarks lists the post, then not",
         %{net: net, me: me, them: them} do
      post = post!(them, "bookmark me")
      sync(net)

      call!(me, "bookmark", %{"uri" => post["uri"]})
      sync(net)
      assert %{"items" => [%{"uri" => uri}]} = call!(me, "get_bookmarks", %{})
      assert uri == post["uri"]

      call!(me, "unbookmark", %{"uri" => post["uri"]})
      sync(net)
      assert %{"items" => []} = call!(me, "get_bookmarks", %{})
    end

    test "update_seen: the unread count drops to zero, including a notification from this second",
         %{net: net, me: me, them: them} do
      # The AppView counts a notification unread when it was indexed after
      # the seen time, to the millisecond; the follow below is indexed
      # moments before update_seen is called.
      follow = call!(them, "follow", %{"actor" => me.handle})
      sync(net)
      assert call!(me, "get_unread_count", %{})["count"] > 0

      # A time that does not parse is refused, not read as now.
      assert %{code: "invalid_arguments", problems: [%{path: "seen_at"}]} =
               refused(me, "update_seen", %{"seen_at" => "yesterday"})

      sync(net)
      assert call!(me, "get_unread_count", %{})["count"] > 0

      call!(me, "update_seen", %{})
      sync(net)
      assert call!(me, "get_unread_count", %{})["count"] == 0

      call!(them, "unfollow", %{"uri" => follow["uri"]})
    end

    test "feed_feedback is refused, before anything is sent, for a feed whose generator does not take feedback",
         %{net: net, me: me, them: them, feed: feed} do
      # dev-env's feed generator serves only getFeedSkeleton and
      # describeFeedGenerator, and its record does not accept interactions,
      # so only the refusal is a round trip here: get_feed_info reads the
      # generator as the AppView indexed it, and feed_feedback follows that.
      post = post!(them, "in the feed")
      sync(net)

      assert %{"items" => [%{"uri" => ^feed} = generator]} =
               call!(me, "get_feed_info", %{"uris" => [feed]})

      refute generator["accepts_interactions"]

      assert Enum.any?(
               call!(me, "get_feed", %{"feed" => feed})["items"],
               &(&1["uri"] == post["uri"])
             )

      assert %{code: "invalid_arguments", problems: [%{path: "feed"}]} =
               refused(me, "feed_feedback", %{
                 "feed" => feed,
                 "uri" => post["uri"],
                 "kind" => "show_more"
               })
    end
  end

  describe "lists and starter packs" do
    test "create_list, add_to_list, update_list, remove_from_list, delete_list",
         %{net: net, me: me, them: them} do
      list =
        call!(me, "create_list", %{
          "name" => "round trip",
          "purpose" => "curate",
          "description" => "a list"
        })

      sync(net)

      item = call!(me, "add_to_list", %{"list" => list["uri"], "actor" => them.handle})
      assert item["actor"] == them.did
      sync(net)

      read = call!(me, "get_list", %{"uri" => list["uri"]})
      assert %{"name" => "round trip", "purpose" => "curate", "item_count" => 1} = read["list"]
      assert [%{"did" => did, "item_uri" => item_uri}] = read["items"]
      assert did == them.did and item_uri == item["uri"]

      assert %{"items" => [%{"uri" => uri, "member_item" => ^item_uri}]} =
               call!(me, "get_lists", %{"contains" => them.handle})

      assert uri == list["uri"]

      call!(me, "update_list", %{"uri" => list["uri"], "name" => "renamed"})
      sync(net)

      assert %{"name" => "renamed", "description" => "a list"} =
               call!(me, "get_list", %{"uri" => list["uri"]})["list"]

      assert %{"deleted" => [^item_uri]} =
               call!(me, "remove_from_list", %{"list" => list["uri"], "actor" => them.did})

      sync(net)

      assert %{"items" => [], "list" => %{"item_count" => 0}} =
               call!(me, "get_list", %{"uri" => list["uri"]})

      call!(me, "add_to_list", %{"list" => list["uri"], "actor" => them.did})
      assert %{"deleted" => deleted} = call!(me, "delete_list", %{"uri" => list["uri"]})
      # The list and the item on it, in one commit.
      assert list["uri"] in deleted and length(deleted) == 2
      sync(net)

      assert %{code: "not_found", uri: uri} = refused(me, "get_list", %{"uri" => list["uri"]})
      assert uri == list["uri"]

      assert %{"items" => []} = call!(me, "get_lists", %{})
    end

    test "create_starter_pack, set_list_opt_out, update_starter_pack, delete_starter_pack",
         %{net: net, me: me, them: them, feed: feed} do
      pack =
        call!(me, "create_starter_pack", %{
          "name" => "a pack",
          "actors" => [them.handle],
          "feeds" => [feed]
        })

      sync(net)

      read = call!(me, "get_starter_pack", %{"uri" => pack["uri"]})
      assert %{"name" => "a pack", "list" => list} = read
      assert list == pack["list"]
      assert [%{"uri" => ^feed}] = read["feeds"]
      assert [%{"did" => did}] = read["members_sample"]
      assert did == them.did

      # Opting out is only enforced on a reference list, which is what a
      # starter pack's list is; its creator then sees the account marked.
      assert record(me, list)["purpose"] == "app.bsky.graph.defs#referencelist"
      opt_out = call!(them, "set_list_opt_out", %{"list" => pack["uri"], "opted_out" => true})
      assert opt_out["list"] == list
      sync(net)

      assert [%{"did" => ^did, "opted_out" => true}] =
               call!(me, "get_list", %{"uri" => list})["items"]

      assert %{"deleted" => [opt_out_uri]} =
               call!(them, "set_list_opt_out", %{"list" => pack["uri"], "opted_out" => false})

      assert opt_out_uri == opt_out["uri"]
      sync(net)
      assert [%{"did" => ^did} = item] = call!(me, "get_list", %{"uri" => list})["items"]
      refute item["opted_out"]

      call!(me, "update_starter_pack", %{"uri" => pack["uri"], "name" => "renamed pack"})
      sync(net)
      assert %{"name" => "renamed pack"} = call!(me, "get_starter_pack", %{"uri" => pack["uri"]})

      assert %{"deleted" => deleted} =
               call!(me, "delete_starter_pack", %{"uri" => pack["uri"]})

      assert pack["uri"] in deleted and list in deleted
      sync(net)
      assert record(me, pack["uri"]) == nil
      assert record(me, list) == nil

      assert %{code: "not_found"} = refused(me, "get_starter_pack", %{"uri" => pack["uri"]})
    end
  end

  describe "preferences and drafts" do
    test "save_feed and unsave_feed: the saved feed is in the account's preferences, then not",
         %{me: me, feed: feed, session: session} do
      # get_preferences reads the saved feeds as the app shows them, and the
      # PDS holds them as written.
      saved = fn ->
        {:ok, preferences} = AtMcp.ATProto.preferences_as_stored(session)

        stored =
          for %{"$type" => "app.bsky.actor.defs#savedFeedsPrefV2", "items" => items} <-
                preferences,
              item <- items,
              item["value"] == feed,
              do: Map.take(item, ["type", "value", "pinned"])

        read =
          for item <- call!(me, "get_preferences", %{})["saved_feeds"],
              item["value"] == feed,
              do: item

        assert read == stored
        stored
      end

      assert saved.() == []

      assert %{"unchanged" => false, "pinned" => true} =
               call!(me, "save_feed", %{"uri" => feed, "pinned" => true})

      assert [%{"type" => "feed", "pinned" => true}] = saved.()

      # Already as asked: nothing written.
      assert %{"unchanged" => true} = call!(me, "save_feed", %{"uri" => feed, "pinned" => true})

      assert %{"unchanged" => false} = call!(me, "save_feed", %{"uri" => feed, "pinned" => false})
      assert [%{"pinned" => false}] = saved.()

      assert %{"unchanged" => false} = call!(me, "unsave_feed", %{"uri" => feed})
      assert saved.() == []
      assert %{"unchanged" => true} = call!(me, "unsave_feed", %{"uri" => feed})
    end

    test "set_preference, each preference kind: get_preferences reads it back, the PDS keeps every other preference, and the undo puts it back",
         %{me: me, session: session} do
      # A preference AtMcp has no tool for, which every change must keep.
      {:ok, before} = AtMcp.ATProto.preferences_as_stored(session)

      kept = %{
        "$type" => "app.bsky.actor.defs#hiddenPostsPref",
        "items" => ["at://#{me.did}/app.bsky.feed.post/3kkeep"]
      }

      {:ok, _} = AtMcp.ATProto.put_preferences_as_stored(session, before ++ [kept])

      list = call!(me, "create_list", %{"name" => "repliers", "purpose" => "curate"})["uri"]
      by_handle = String.replace(list, me.did, me.handle)

      for {kind, change, read} <- [
            {"home_feed", %{"hide_reposts" => true, "hide_quotes" => true},
             %{"hide_reposts" => true, "hide_quotes" => true}},
            {"threads", %{"sort" => "newest", "tree_view" => true},
             %{"sort" => "newest", "tree_view" => true}},
            {"interaction_defaults",
             %{"reply_rule" => ["mentioned", by_handle], "quotes" => "disabled"},
             %{"reply_rule" => ["mentioned", list], "quotes" => "disabled"}},
            {"interests", %{"tags" => ["art", "science"]}, %{"tags" => ["art", "science"]}},
            {"verification", %{"hide_badges" => true}, %{"hide_badges" => true}}
          ] do
        initial = call!(me, "get_preferences", %{})[kind]
        result = call!(me, "set_preference", Map.put(change, "kind", kind))
        assert result["unchanged"] == false, kind
        assert result["previous"] == initial, kind
        assert Map.take(result["now"], Map.keys(read)) == read, kind
        assert Map.take(call!(me, "get_preferences", %{})[kind], Map.keys(read)) == read, kind

        # Asked again: already so, nothing written.
        assert call!(me, "set_preference", Map.put(change, "kind", kind))["unchanged"], kind

        # Undo with what the result named as before.
        undo = Map.take(result["previous"], result["changed"])
        call!(me, "set_preference", Map.put(undo, "kind", kind))
        assert call!(me, "get_preferences", %{})[kind] == initial, kind

        {:ok, stored} = AtMcp.ATProto.preferences_as_stored(session)
        assert kept in stored, kind
      end

      # The app shows adult content only to an account whose birth date makes
      # it 18 or over; these accounts have none.
      assert call!(me, "get_preferences", %{})["adult_content"]["declared_over_18"] == false

      assert %{code: "invalid_arguments", problems: [%{path: "enabled"}]} =
               refused(me, "set_preference", %{"kind" => "adult_content", "enabled" => true})

      call!(me, "delete_list", %{"uri" => list})
      {:ok, _} = AtMcp.ATProto.put_preferences_as_stored(session, before)
    end

    test "set_preference discoverable and activity_subscriptions: the declaration records, read back by get_preferences, get_record and another account's get_profile, then undone",
         %{net: net, me: me, them: them} do
      assert %{"hide_from_recommendations" => false} =
               call!(me, "get_preferences", %{})["discoverable"]

      written =
        call!(me, "set_preference", %{
          "kind" => "discoverable",
          "hide_from_recommendations" => true
        })

      assert written["uri"] == "at://#{me.did}/app.bsky.actor.contentVisibilityDeclaration/self"

      assert %{"hideFromAlgorithmicRecommendations" => true} = record(me, written["uri"])

      assert %{"hide_from_recommendations" => true} =
               call!(me, "get_preferences", %{})["discoverable"]

      call!(me, "set_preference", %{
        "kind" => "discoverable",
        "hide_from_recommendations" => false
      })

      assert %{"hideFromAlgorithmicRecommendations" => false} = record(me, written["uri"])

      assert %{"hide_from_recommendations" => false} =
               call!(me, "get_preferences", %{})["discoverable"]

      # No declaration lets followers subscribe; asking for that writes nothing.
      assert %{"unchanged" => true} =
               call!(me, "set_preference", %{
                 "kind" => "activity_subscriptions",
                 "allow" => "followers"
               })

      written =
        call!(me, "set_preference", %{"kind" => "activity_subscriptions", "allow" => "none"})

      assert %{"allowSubscriptions" => "none"} = record(me, written["uri"])
      sync(net)
      assert call!(them, "get_profile", %{"actor" => me.did})["subscriptions_from"] == "none"

      call!(me, "set_preference", %{"kind" => "activity_subscriptions", "allow" => "followers"})
      sync(net)

      assert call!(me, "get_preferences", %{})["activity_subscriptions"] == %{
               "allow" => "followers"
             }

      assert call!(them, "get_profile", %{"actor" => me.did})["subscriptions_from"] == "followers"
    end

    test "set_notification_setting: get_notification_settings reads it back, then the undo",
         %{me: me} do
      setting = fn reason ->
        Enum.find(
          call!(me, "get_notification_settings", %{})["settings"],
          &(&1["reason"] == reason)
        )
      end

      initial = setting.("like")
      assert %{"include" => "all", "list" => true, "push" => true} = initial

      result =
        call!(me, "set_notification_setting", %{
          "reason" => "like",
          "include" => "follows",
          "push" => false
        })

      assert result["changed"] == ["include", "push"]
      assert result["now"] == %{"include" => "follows", "list" => true, "push" => false}
      assert setting.("like") == Map.merge(initial, %{"include" => "follows", "push" => false})

      # Another reason is untouched.
      assert setting.("reply") == %{
               "reason" => "reply",
               "include" => "all",
               "list" => true,
               "push" => true
             }

      plain =
        call!(me, "set_notification_setting", %{"reason" => "starterpack_joined", "list" => false})

      assert plain["now"] == %{"include" => nil, "list" => false, "push" => true}

      call!(
        me,
        "set_notification_setting",
        Map.put(Map.take(result["previous"], result["changed"]), "reason", "like")
      )

      call!(me, "set_notification_setting", %{"reason" => "starterpack_joined", "list" => true})
      assert setting.("like") == initial
      assert setting.("starterpack_joined")["list"] == true
    end

    test "get_notifications grouped: another account's like reads as a likeGroup naming it and the post, and is gone after the unlike",
         %{net: net, me: me, them: them} do
      post = post!(me, "group my likes")
      sync(net)
      like = call!(them, "like", %{"uri" => post["uri"], "cid" => post["cid"]})
      sync(net)

      group = fn ->
        call!(me, "get_notifications", %{"grouped" => true})["items"]
        |> Enum.find(
          &(&1["kind"] == "likeGroup" and
              Enum.any?(&1["posts"], fn p -> p["uri"] == post["uri"] end))
        )
      end

      assert %{
               "count" => 1,
               "actors" => [%{"did" => did, "handle" => handle}],
               "posts" => [%{"text" => "group my likes"}]
             } = group.()

      assert {did, handle} == {them.did, them.handle}

      call!(them, "unlike", %{"uri" => like["uri"]})
      sync(net)
      assert group.() == nil

      call!(me, "delete_post", %{"uri" => post["uri"]})
      sync(net)
    end

    test "subscribe_to_activity by handle: refused until this account follows, then get_profile and get_activity_subscriptions read it back, then the unsubscribe",
         %{net: net, me: me, them: them} do
      # Followers may subscribe by default, and this account does not follow.
      assert %{code: "invalid_arguments", problems: [%{path: "actor"}]} =
               refused(me, "subscribe_to_activity", %{
                 "actor" => them.handle,
                 "posts" => true,
                 "replies" => false
               })

      follow = call!(me, "follow", %{"actor" => them.handle})
      sync(net)

      result =
        call!(me, "subscribe_to_activity", %{
          "actor" => them.handle,
          "posts" => true,
          "replies" => true
        })

      assert result["actor"] == them.did
      assert result["previous"] == %{"posts" => false, "replies" => false}
      assert result["now"] == %{"posts" => true, "replies" => true}
      sync(net)

      assert call!(me, "get_profile", %{"actor" => them.did})["activity_subscription"] ==
               %{"posts" => true, "replies" => true}

      assert %{"items" => [%{"did" => did, "activity_subscription" => %{"posts" => true}}]} =
               call!(me, "get_activity_subscriptions", %{})

      assert did == them.did

      assert call!(me, "subscribe_to_activity", %{
               "actor" => them.did,
               "posts" => true,
               "replies" => true
             })["unchanged"]

      call!(me, "subscribe_to_activity", %{
        "actor" => them.did,
        "posts" => false,
        "replies" => false
      })

      sync(net)
      assert call!(me, "get_profile", %{"actor" => them.did})["activity_subscription"] == nil
      assert %{"items" => []} = call!(me, "get_activity_subscriptions", %{})

      call!(me, "unfollow", %{"uri" => follow["uri"]})
      sync(net)
    end

    test "save_draft, update it, delete_draft: get_drafts follows each", %{me: me} do
      draft = call!(me, "save_draft", %{"text" => "first words"})
      id = draft["id"]

      assert %{"items" => [%{"id" => ^id, "posts" => [%{"text" => "first words"}]}]} =
               call!(me, "get_drafts", %{})

      call!(me, "save_draft", %{"id" => id, "text" => "second words"})

      assert %{"items" => [%{"id" => ^id, "posts" => [%{"text" => "second words"}]}]} =
               call!(me, "get_drafts", %{})

      assert %{"draft" => %{"posts" => [%{"text" => "second words"}]}} =
               call!(me, "delete_draft", %{"id" => id})

      assert %{"items" => []} = call!(me, "get_drafts", %{})

      # An id the account does not have is refused.
      assert %{code: "invalid_arguments", problems: [%{path: "id"}]} =
               refused(me, "save_draft", %{"id" => id, "text" => "gone"})
    end
  end

  describe "moderation" do
    # The preferences as the PDS holds them, every type but the ones `keep`
    # names: what a moderation write must leave as it was.
    defp other_preferences(session, types) do
      {:ok, preferences} = AtMcp.ATProto.preferences_as_stored(session)
      Enum.reject(preferences, &(&1["$type"] in types))
    end

    test "mute_word, mute it again, unmute_word: get_preferences follows each, and every other preference is kept",
         %{me: me, session: session} do
      call!(me, "set_preference", %{"kind" => "threads", "sort" => "newest"})
      others = other_preferences(session, ["app.bsky.actor.defs#mutedWordsPref"])

      muted =
        call!(me, "mute_word", %{
          "value" => "#Spoilers",
          "tags_only" => true,
          "duration" => "7d",
          "only_non_followed" => true
        })

      assert %{"previous" => [], "now" => [%{"value" => "Spoilers", "id" => id}]} = muted

      assert [
               %{
                 "value" => "Spoilers",
                 "id" => ^id,
                 "tags_only" => true,
                 "only_non_followed" => true,
                 "expired" => false,
                 "expires_at" => expires
               }
             ] = call!(me, "get_preferences", %{})["muted_words"]

      assert is_binary(expires)
      assert other_preferences(session, ["app.bsky.actor.defs#mutedWordsPref"]) == others

      # The same word again, for ever and everywhere: changed in place.
      assert %{"now" => [%{"id" => ^id, "expires_at" => nil, "tags_only" => false}]} =
               call!(me, "mute_word", %{"value" => "spoilers"})

      assert [%{"id" => ^id, "expires_at" => nil}] =
               call!(me, "get_preferences", %{})["muted_words"]

      assert call!(me, "mute_word", %{"value" => "SPOILERS"})["unchanged"]

      assert %{"removed" => [%{"id" => ^id, "value" => "Spoilers"}]} =
               call!(me, "unmute_word", %{"value" => "spoilers"})

      assert call!(me, "get_preferences", %{})["muted_words"] == []
      assert call!(me, "unmute_word", %{"value" => "spoilers"})["unchanged"]

      # A removed word comes back exactly as it was, from what unmute_word
      # returned, and goes again.
      call!(me, "mute_word", %{"value" => "plot", "tags_only" => true, "duration" => "24h"})
      %{"removed" => [removed]} = call!(me, "unmute_word", %{"value" => "plot"})

      call!(me, "mute_word", %{
        "value" => removed["value"],
        "targets" => removed["targets"],
        "only_non_followed" => removed["only_non_followed"],
        "expires_at" => removed["expires_at"]
      })

      assert [restored] = call!(me, "get_preferences", %{})["muted_words"]
      assert Map.delete(restored, "id") == Map.delete(removed, "id")
      call!(me, "unmute_word", %{"value" => "plot"})
      assert other_preferences(session, ["app.bsky.actor.defs#mutedWordsPref"]) == others
      call!(me, "set_preference", %{"kind" => "threads", "sort" => "top"})
    end

    test "reads mark what the app would hide or cover: a muted word, a thread's reply, and a label as the account's own setting for it says",
         %{net: net, me: me, them: them, moderation: moderation, session: session} do
      {:ok, before} = AtMcp.ATProto.preferences_as_stored(session)
      text = fn result -> hd(result.content).text end

      # A muted word: the post is marked, and all of it is still there.
      call!(me, "mute_word", %{"value" => "kumquat"})
      muted = post!(them, "I love kumquat pie")
      sync(net)

      read = call(me, "get_posts", %{"uris" => [muted["uri"]]})
      [post] = read.structuredContent["items"]
      assert post["raw_text"] == "I love kumquat pie"

      assert %{
               "causes" => [%{"type" => "muted_word", "effect" => "hide", "words" => ["kumquat"]}]
             } =
               post["moderation"]

      assert text.(read) =~ "Hidden by the app: matches your muted word \"kumquat\""
      assert text.(read) =~ "I love kumquat pie"

      # On the author's own profile the app leaves none of their posts out.
      feed = call!(me, "get_author_feed", %{"actor" => them.did})["items"]
      on_profile = Enum.find(feed, &(&1["uri"] == muted["uri"]))

      assert %{"causes" => [%{"type" => "muted_word", "effect" => "cover"}]} =
               on_profile["moderation"]

      # In a thread, the reply goes under "Show more replies".
      root = post!(me, "what fruit?")
      call!(them, "reply", %{"uri" => root["uri"], "text" => "kumquat, always"})
      call!(them, "reply", %{"uri" => root["uri"], "text" => "pears"})
      sync(net)

      thread = call(me, "get_thread", %{"uri" => root["uri"]})
      replies = thread.structuredContent["replies"]
      moved = Enum.find(replies, &(&1["raw_text"] == "kumquat, always"))
      kept = Enum.find(replies, &(&1["raw_text"] == "pears"))
      # A thread covers it, never leaves it out.
      assert %{"in_thread" => "show_more_replies", "causes" => [%{"effect" => "cover"}]} =
               moved["moderation"]

      refute Map.has_key?(kept, "moderation")
      assert text.(thread) =~ ~s(Under "Show more replies" in the app)

      # The account's own posts are never matched.
      own = post!(me, "kumquat season")
      sync(net)
      refute Map.has_key?(only_post(me, own["uri"]), "moderation")
      call!(me, "unmute_word", %{"value" => "kumquat"})
      refute Map.has_key?(only_post(me, muted["uri"]), "moderation")

      # A label the network's moderation service applies, read as the
      # service defines it (spam: blurs content, hidden unless set), then as
      # the account sets it.
      labelled = post!(them, "buy now")
      sync(net)
      assert :ok = DevNetwork.label(net, labelled["uri"], labelled["cid"], "spam")

      assert %{
               "causes" => [
                 %{
                   "type" => "label",
                   "label" => "spam",
                   "label_name" => "Spam",
                   "labeler" => ^moderation,
                   "effect" => "hide",
                   "setting" => "hide"
                 } = cause
               ]
             } = only_post(me, labelled["uri"])["moderation"]

      handle = cause["labeler_handle"]
      assert is_binary(handle)

      read = call(me, "get_posts", %{"uris" => [labelled["uri"]]})
      assert text.(read) =~ "Hidden by the app: labeled 'spam' (\"Spam\") by #{handle}"

      call!(me, "set_label_visibility", %{
        "label" => "spam",
        "visibility" => "warn",
        "labeler" => moderation
      })

      assert %{"causes" => [%{"effect" => "cover", "setting" => "warn"}]} =
               only_post(me, labelled["uri"])["moderation"]

      read = call(me, "get_posts", %{"uris" => [labelled["uri"]]})
      assert text.(read) =~ "Behind a warning in the app: labeled 'spam' (\"Spam\") by #{handle}"

      call!(me, "set_label_visibility", %{
        "label" => "spam",
        "visibility" => "show",
        "labeler" => moderation
      })

      refute Map.has_key?(only_post(me, labelled["uri"]), "moderation")

      call!(me, "set_label_visibility", %{
        "label" => "spam",
        "visibility" => "hide",
        "labeler" => moderation
      })

      assert %{"causes" => [%{"effect" => "hide", "setting" => "hide"}]} =
               only_post(me, labelled["uri"])["moderation"]

      {:ok, _} = AtMcp.ATProto.put_preferences_as_stored(session, before)
    end

    test "subscribe_labeler, set_label_visibility for its label, unsubscribe_labeler: get_labelers and get_preferences follow each",
         %{me: me, them: them, moderation: moderation, session: session} do
      assert [^moderation] = call!(me, "get_preferences", %{})["labelers"]

      assert %{"items" => [%{"did" => ^moderation, "built_in" => true}], "missing" => []} =
               call!(me, "get_labelers", %{})

      # The network's own is always on; an account with no labeler is none.
      refused(me, "subscribe_labeler", %{"actor" => moderation})

      assert %{"problems" => [%{"path" => "actor"}]} =
               refused(them, "subscribe_labeler", %{"actor" => me.handle}) |> stringify()

      assert %{"previous" => false, "now" => true, "actor" => did} =
               call!(me, "subscribe_labeler", %{"actor" => them.handle})

      assert did == them.did
      assert call!(me, "subscribe_labeler", %{"actor" => them.did})["unchanged"]
      assert [^moderation, ^did] = call!(me, "get_preferences", %{})["labelers"]

      assert %{"items" => [%{"subscribed" => true, "labels" => [spoiler]}]} =
               call!(me, "get_labelers", %{"actors" => [them.handle]})

      assert %{"identifier" => "spoiler", "default" => "warn", "setting" => "warn"} = spoiler

      assert %{"previous" => "warn", "now" => "hide"} =
               call!(me, "set_label_visibility", %{
                 "label" => "spoiler",
                 "visibility" => "hide",
                 "labeler" => them.handle
               })

      assert %{"items" => [%{"labels" => [%{"setting" => "hide"}]}]} =
               call!(me, "get_labelers", %{"actors" => [them.did]})

      assert {:ok, stored} = AtMcp.ATProto.preferences_as_stored(session)

      assert %{"labelerDid" => ^did, "visibility" => "hide"} =
               Enum.find(stored, &(&1["label"] == "spoiler"))

      # Undone: set back to what it was.
      call!(me, "set_label_visibility", %{
        "label" => "spoiler",
        "visibility" => "warn",
        "labeler" => them.did
      })

      assert %{"items" => [%{"labels" => [%{"setting" => "warn"}]}]} =
               call!(me, "get_labelers", %{"actors" => [them.did]})

      assert %{"previous" => true, "now" => false} =
               call!(me, "unsubscribe_labeler", %{"actor" => them.handle})

      assert [^moderation] = call!(me, "get_preferences", %{})["labelers"]

      assert %{"items" => [%{"subscribed" => false, "labels" => [%{"setting" => nil}]}]} =
               call!(me, "get_labelers", %{"actors" => [them.did]})

      # A label setting for a labeler the account does not take labels from
      # would show nowhere.
      refused(me, "set_label_visibility", %{
        "label" => "spoiler",
        "visibility" => "hide",
        "labeler" => them.did
      })
    end

    test "set_label_visibility for an adult content filter: refused while adult content is off, then set, its old name too, and set back",
         %{me: me, session: session} do
      assert %{"problems" => [%{"path" => "label"}]} =
               refused(me, "set_label_visibility", %{"label" => "porn", "visibility" => "warn"})
               |> stringify()

      # No tool turns adult content on for an account with no birth date (the
      # app would not show it), so it is written here, outside the tools.
      {:ok, before} = AtMcp.ATProto.preferences_as_stored(session)
      adult = %{"$type" => "app.bsky.actor.defs#adultContentPref", "enabled" => true}
      {:ok, _} = AtMcp.ATProto.put_preferences_as_stored(session, before ++ [adult])

      assert %{"previous" => "hide", "now" => "warn"} =
               call!(me, "set_label_visibility", %{"label" => "porn", "visibility" => "warn"})

      assert call!(me, "get_preferences", %{})["content_labels"]["porn"] == "warn"
      {:ok, stored} = AtMcp.ATProto.preferences_as_stored(session)

      assert [
               %{"label" => "porn", "visibility" => "warn"},
               %{"label" => "nsfw", "visibility" => "warn"}
             ] =
               Enum.filter(stored, &(&1["label"] in ["porn", "nsfw"]))

      assert %{"previous" => "warn", "now" => "hide"} =
               call!(me, "set_label_visibility", %{"label" => "porn", "visibility" => "hide"})

      assert call!(me, "get_preferences", %{})["content_labels"]["porn"] == "hide"
      {:ok, _} = AtMcp.ATProto.put_preferences_as_stored(session, before)
    end

    test "mute_list and block_list of a moderation list: the list, get_moderation_lists and the profile say via a list; undone, they say nothing",
         %{net: net, me: me, them: them} do
      list = call!(me, "create_list", %{"name" => "mod", "purpose" => "moderation"})
      call!(me, "add_to_list", %{"list" => list["uri"], "actor" => them.handle})
      curate = call!(me, "create_list", %{"name" => "curated", "purpose" => "curate"})
      sync(net)

      # A list named by its handle form is muted by its DID form.
      handle_form = String.replace(list["uri"], me.did, me.handle)

      assert %{"list" => uri, "muted" => true, "previous" => false} =
               call!(me, "mute_list", %{"uri" => handle_form})

      assert uri == list["uri"]
      sync(net)

      assert %{"viewer" => %{"muted" => true}} = call!(me, "get_list", %{"uri" => uri})["list"]

      assert %{"items" => [%{"uri" => ^uri}]} =
               call!(me, "get_moderation_lists", %{"kind" => "muted"})

      assert get_in(call!(me, "get_profile", %{"actor" => them.did}), ["viewer", "muted_by_list"]) ==
               uri

      call!(me, "unmute_list", %{"uri" => uri})
      sync(net)

      assert get_in(call!(me, "get_list", %{"uri" => uri}), ["list", "viewer", "muted"]) in [
               false,
               nil
             ]

      assert %{"items" => []} = call!(me, "get_moderation_lists", %{"kind" => "muted"})

      assert get_in(call!(me, "get_profile", %{"actor" => them.did}), ["viewer", "muted_by_list"]) ==
               nil

      block = call!(me, "block_list", %{"uri" => handle_form})
      assert %{"list" => ^uri, "uri" => block_uri, "name" => "mod"} = block
      sync(net)

      assert call!(me, "get_list", %{"uri" => uri})["list"]["viewer"]["blocked"] == block_uri

      assert %{"items" => [%{"uri" => ^uri}]} =
               call!(me, "get_moderation_lists", %{"kind" => "blocked"})

      assert get_in(call!(me, "get_profile", %{"actor" => them.did}), [
               "viewer",
               "blocking_by_list"
             ]) == uri

      assert call!(me, "block_list", %{"uri" => uri})["unchanged"]

      assert %{"deleted" => [^block_uri]} = call!(me, "unblock_list", %{"uri" => block_uri})
      sync(net)
      assert get_in(call!(me, "get_list", %{"uri" => uri}), ["list", "viewer", "blocked"]) == nil
      assert %{"items" => []} = call!(me, "get_moderation_lists", %{"kind" => "blocked"})

      assert get_in(call!(me, "get_profile", %{"actor" => them.did}), [
               "viewer",
               "blocking_by_list"
             ]) == nil

      assert call!(me, "unblock_list", %{"uri" => uri})["unchanged"]

      # The app offers neither for a curation list.
      refused(me, "mute_list", %{"uri" => curate["uri"]})
      refused(me, "block_list", %{"uri" => curate["uri"]})

      call!(me, "delete_list", %{"uri" => list["uri"]})
      call!(me, "delete_list", %{"uri" => curate["uri"]})
      sync(net)
    end

    test "report an account and a post: the moderation service records each as sent; the account's own are refused",
         %{net: net, me: me, them: them, moderation: moderation} do
      post = post!(them, "report me")
      sync(net)

      report =
        call!(me, "report", %{
          "subject" => them.handle,
          "reason" => "spam",
          "details" => "round trip"
        })

      assert %{"labeler" => ^moderation, "reason" => "misleading_spam", "id" => id} = report
      assert report["note"] =~ "cannot be withdrawn"

      assert %{
               "subjectDid" => subject,
               "subjectUri" => nil,
               "comment" => "round trip",
               "createdBy" => by
             } =
               DevNetwork.report(net, id)

      assert subject == them.did and by == me.did

      handle_form = String.replace(post["uri"], them.did, them.handle)

      assert %{"id" => id, "subject" => uri} =
               call!(me, "report", %{"subject" => handle_form, "reason" => "harassment_troll"})

      assert uri == post["uri"]

      assert %{"subjectUri" => ^uri, "subjectCid" => cid, "meta" => meta} =
               DevNetwork.report(net, id)

      assert cid == post["cid"]
      assert meta["reportType"] == "tools.ozone.report.defs#reasonHarassmentTroll"

      for subject <- [me.handle, me.did, String.replace(post["uri"], them.did, me.did)] do
        refused(me, "report", %{"subject" => subject, "reason" => "spam"})
      end

      call!(them, "delete_post", %{"uri" => post["uri"]})
      sync(net)
    end
  end

  defp stringify(result), do: Jason.decode!(Jason.encode!(result))
end
