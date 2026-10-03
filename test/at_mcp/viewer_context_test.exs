defmodule AtMcp.ViewerContextTest do
  use ExUnit.Case, async: false
  alias AtMcp.Effects.ProtoRune, as: Backend

  defmodule HTTP do
    def request(:get, url, opts) do
      owner = if {"authorization", "Bearer alice"} in opts[:headers], do: "alice", else: "bob"

      actor = %{
        "did" => "did:plc:author",
        "handle" => "author.test",
        "viewer" => %{
          "following" => relation(owner, "follow"),
          "blocking" => relation(owner, "block"),
          "muted" => true,
          "privateField" => "not part of the contract"
        }
      }

      post = %{
        "uri" => "at://did:plc:author/app.bsky.feed.post/subject",
        "cid" => "subject-cid",
        "record" => %{"text" => "A post"},
        "author" => actor,
        "viewer" => %{
          "like" => relation(owner, "like"),
          "repost" => relation(owner, "repost"),
          "bookmarked" => true,
          "privateField" => "not part of the contract"
        }
      }

      body =
        cond do
          String.contains?(url, "getPostThread") ->
            %{
              "thread" => %{
                "post" => post,
                "parent" => %{"post" => Map.delete(post, "viewer")},
                "replies" => [%{"post" => Map.put(post, "viewer", %{})}]
              }
            }

          String.contains?(url, "getPosts") ->
            %{"posts" => [post]}

          String.contains?(url, "getAuthorFeed") or String.contains?(url, "getTimeline") ->
            %{"feed" => [%{"post" => post}]}

          String.contains?(url, "getProfile") ->
            actor
        end

      {:ok, %{status: 200, headers: [], body: Jason.encode!(body)}}
    end

    def request(:post, url, opts) do
      send(Application.fetch_env!(:at_mcp, :viewer_test_owner), {:delete, url, opts})
      {:ok, %{status: 200, headers: [], body: "{}"}}
    end

    def relation(owner, kind) do
      collection =
        if kind in ["like", "repost"], do: "app.bsky.feed.#{kind}", else: "app.bsky.graph.#{kind}"

      "at://did:plc:#{owner}/#{collection}/record"
    end
  end

  setup do
    previous = Application.get_env(:proto_rune, :http_client)
    Application.put_env(:proto_rune, :http_client, HTTP)
    Application.put_env(:at_mcp, :viewer_test_owner, self())

    on_exit(fn ->
      if previous,
        do: Application.put_env(:proto_rune, :http_client, previous),
        else: Application.delete_env(:proto_rune, :http_client)

      Application.delete_env(:at_mcp, :viewer_test_owner)
    end)

    :ok
  end

  test "two accounts recover their own inverse-action URIs from post reads and feeds" do
    for owner <- ["alice", "bob"] do
      session = session(owner)

      {:ok, %{items: [post]}} =
        Backend.get_posts(session, ["at://did:plc:author/app.bsky.feed.post/subject"])

      assert post.author_did == "did:plc:author"

      assert post.viewer == %{
               like: HTTP.relation(owner, "like"),
               repost: HTTP.relation(owner, "repost")
             }

      {:ok, %{items: [feed_post]}} = Backend.get_author_feed(session, "author.test", [])
      assert feed_post == post
      {:ok, %{items: [timeline_post]}} = Backend.get_timeline(session, [])
      assert timeline_post == post
      assert {:ok, %{action: :unlike}} = Backend.unlike(session, post.viewer.like)
      assert_receive {:delete, url, opts}
      assert url =~ "com.atproto.repo.deleteRecord"

      assert opts[:json] == %{
               repo: "did:plc:#{owner}",
               collection: "app.bsky.feed.like",
               rkey: "record"
             }

      refute Jason.encode!(post) =~ "not part of the contract"
    end
  end

  test "thread context preserves viewer absence rather than inventing negative relationship evidence" do
    {:ok, thread} =
      Backend.get_thread(session("alice"), "at://did:plc:author/app.bsky.feed.post/subject")

    assert thread.viewer.like == HTTP.relation("alice", "like")
    refute Map.has_key?(thread.parent, :viewer)
    assert hd(thread.replies).viewer == %{}
    assert thread.parent.author_did == "did:plc:author"
  end

  test "profile read supplies safe following and blocking refs for the authenticated viewer" do
    for owner <- ["alice", "bob"] do
      {:ok, profile} = Backend.get_profile(session(owner), "author.test")
      assert profile.did == "did:plc:author"

      assert profile.viewer == %{
               following: HTTP.relation(owner, "follow"),
               blocking: HTTP.relation(owner, "block")
             }

      refute Map.has_key?(profile.viewer, :muted)
      refute Jason.encode!(profile) =~ "not part of the contract"
    end
  end

  defp session(owner),
    do: %ProtoRune.Atproto.Session{
      did: "did:plc:#{owner}",
      handle: "#{owner}.test",
      access_jwt: owner,
      refresh_jwt: "unused",
      service_url: "https://pds.invalid/xrpc"
    }
end
