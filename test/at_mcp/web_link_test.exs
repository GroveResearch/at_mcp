defmodule AtMcp.WebLinkTest do
  @moduledoc """
  The web link a person sees and shares beside each post, account, list,
  feed, starter pack and labeler (#128), in the reading text and the
  structured content; and a web link given where a tool takes an AT URI,
  handle or DID, read back to what it names.
  """
  use ExUnit.Case, async: false

  alias AtMcp.{Network, Summary, WebLink}

  setup do
    old = Application.get_env(:at_mcp, :network)
    Application.put_env(:at_mcp, :network, :bluesky)

    on_exit(fn ->
      if old,
        do: Application.put_env(:at_mcp, :network, old),
        else: Application.delete_env(:at_mcp, :network)
    end)
  end

  @did "did:plc:alice"
  @post "at://#{@did}/app.bsky.feed.post/3kpost"
  @list "at://#{@did}/app.bsky.graph.list/3klist"
  @feed "at://#{@did}/app.bsky.feed.generator/kites"
  @pack "at://#{@did}/app.bsky.graph.starterpack/3kpack"
  @creator %{"did" => @did, "handle" => "alice.test", "displayName" => "Alice"}

  defp text(data, reading) do
    {:ok, %{content: [%{type: "text", text: text}], structuredContent: structured}, :state} =
      AtMcp.MCP.Tools.respond({:ok, data}, :state, reading)

    {text, structured}
  end

  describe "the links, as the app's share actions build them" do
    test "on each network's web origin" do
      for {network, origin} <- [bluesky: "https://bsky.app", delve: "https://delve.town"] do
        Application.put_env(:at_mcp, :network, network)
        post = "at://#{@did}/#{Network.collection(:post)}/3kpost"

        assert WebLink.profile("alice.test", @did) == origin <> "/profile/alice.test"
        assert WebLink.record(post, "alice.test") == origin <> "/profile/alice.test/post/3kpost"

        assert WebLink.record("at://#{@did}/#{Network.collection(:list)}/l") ==
                 origin <> "/profile/did:plc:alice/lists/l"

        assert WebLink.record("at://#{@did}/#{Network.collection(:generator)}/f") ==
                 origin <> "/profile/did:plc:alice/feed/f"

        assert WebLink.record("at://#{@did}/#{Network.collection(:starter_pack)}/s") ==
                 origin <> "/start/did:plc:alice/s"
      end
    end

    test "an account without a valid handle is named by its DID; a record with no page has none" do
      assert WebLink.profile("handle.invalid", @did) ==
               "https://bsky.app/profile/did:plc:alice"

      assert WebLink.profile(nil, @did) == "https://bsky.app/profile/did:plc:alice"
      assert WebLink.record(@post) == "https://bsky.app/profile/did:plc:alice/post/3kpost"
      assert WebLink.record("at://#{@did}/app.bsky.feed.like/3k") == nil
      assert WebLink.record(@post <> "?x") == nil
    end

    test "a link reads back to what it names" do
      assert WebLink.parse("https://bsky.app/profile/alice.test") ==
               {:ok, {:profile, "alice.test"}}

      assert WebLink.parse("https://bsky.app/profile/did:plc:alice/post/3kpost") ==
               {:ok, {:post, @did, "3kpost"}}

      # The app writes a DID's colons as they are; an encoded one reads the same.
      assert WebLink.parse("https://bsky.app/profile/did%3Aplc%3Aalice/post/3kpost") ==
               {:ok, {:post, @did, "3kpost"}}

      assert WebLink.parse("https://bsky.app/profile/alice.test/lists/l") ==
               {:ok, {:list, "alice.test", "l"}}

      assert WebLink.parse("https://bsky.app/profile/alice.test/feed/f/") ==
               {:ok, {:feed, "alice.test", "f"}}

      assert WebLink.parse("https://bsky.app/start/alice.test/s") ==
               {:ok, {:starter_pack, "alice.test", "s"}}

      assert WebLink.parse("https://bsky.app/starter-pack/alice.test/s?x=1") ==
               {:ok, {:starter_pack, "alice.test", "s"}}

      # A page under an object names the object.
      for page <- ["liked-by", "reposted-by", "quotes"] do
        assert WebLink.parse("https://bsky.app/profile/alice.test/post/p/#{page}") ==
                 {:ok, {:post, "alice.test", "p"}}
      end

      for page <- ["rss", "followers", "follows", "known-followers", "search", "labeler/liked-by"] do
        assert WebLink.parse("https://bsky.app/profile/alice.test/#{page}") ==
                 {:ok, {:profile, "alice.test"}}
      end

      assert WebLink.parse("https://bsky.app/profile/alice.test/feed/f/liked-by") ==
               {:ok, {:feed, "alice.test", "f"}}

      # Without its scheme, as a link is often pasted.
      assert WebLink.parse("bsky.app/profile/alice.test") == {:ok, {:profile, "alice.test"}}

      # A DID is read exactly as written; an escape inside it stays.
      assert WebLink.parse("https://bsky.app/profile/did:web:localhost%3A3000") ==
               {:ok, {:profile, "did:web:localhost%3A3000"}}

      assert {:error, "does not name a record"} =
               WebLink.parse("https://bsky.app/profile/alice.test/post/a%2Fb")

      # A short link is not followed.
      for short <- ["https://go.bsky.app/AbCdE", "https://bsky.app/starter-pack-short/AbCdE"] do
        assert {:error, "is a short link" <> _} = WebLink.parse(short)
      end

      assert WebLink.parse(@post) == :not_a_link
      assert WebLink.parse("alice.test") == :not_a_link

      assert {:error, "is a link to delve.town" <> _} =
               WebLink.parse("https://delve.town/profile/a.test")

      assert {:error, "is not a link to" <> _} = WebLink.parse("https://bsky.app/settings")
    end
  end

  describe "each object reads with its link beside its uri" do
    test "a post, and a post it quotes" do
      quoted = %{
        "$type" => "app.bsky.embed.record#viewRecord",
        "uri" => "at://did:plc:bob/app.bsky.feed.post/3kq",
        "author" => %{"did" => "did:plc:bob", "handle" => "bob.test"},
        "value" => %{"$type" => "app.bsky.feed.post", "text" => "quoted"}
      }

      post = %{
        "uri" => @post,
        "cid" => "bafy",
        "author" => @creator,
        "record" => %{"text" => "hello", "createdAt" => "2026-10-19T00:00:00Z"},
        "embed" => %{"$type" => "app.bsky.embed.record#view", "record" => quoted}
      }

      summary = Summary.extract(:post, post)
      assert summary.web_url == "https://bsky.app/profile/alice.test/post/3kpost"
      assert summary.quote.web_url == "https://bsky.app/profile/bob.test/post/3kq"

      {text, data} = text(%{items: [summary]}, :posts)

      assert text =~
               "uri: #{@post} · cid: bafy\nlink: https://bsky.app/profile/alice.test/post/3kpost"

      assert text =~
               "[quoting @bob.test, at://did:plc:bob/app.bsky.feed.post/3kq (link: https://bsky.app/profile/bob.test/post/3kq): \"quoted\"]"

      assert hd(data["items"])["web_url"] == summary.web_url
    end

    test "an account, wherever accounts are listed" do
      profile = Summary.extract(:profile, @creator)
      assert profile.web_url == "https://bsky.app/profile/alice.test"

      {text, _} = text(profile, :profile)
      assert text =~ "did: #{@did}\nlink: https://bsky.app/profile/alice.test"

      {text, _} = text(%{items: [profile]}, :profiles)
      assert text =~ "link: https://bsky.app/profile/alice.test"
    end

    test "a list, and the accounts on it" do
      list = Summary.extract(:list, %{"uri" => @list, "name" => "Kites", "creator" => @creator})
      assert list.web_url == "https://bsky.app/profile/did:plc:alice/lists/3klist"

      member =
        Summary.extract(:list_member, %{
          "uri" => "at://#{@did}/app.bsky.graph.listitem/i",
          "subject" => %{"did" => "did:plc:bob", "handle" => "bob.test"}
        })

      {text, _} = text(%{list: list, items: [member]}, :list)

      assert text =~
               "uri: #{@list}\nlink: https://bsky.app/profile/did:plc:alice/lists/3klist"

      assert text =~
               "item: at://#{@did}/app.bsky.graph.listitem/i\nlink: https://bsky.app/profile/bob.test"

      {text, _} = text(%{items: [list]}, :lists)
      assert text =~ "link: https://bsky.app/profile/did:plc:alice/lists/3klist"
    end

    test "a feed" do
      feed =
        Summary.extract(:generator, %{
          "uri" => @feed,
          "cid" => "bafy",
          "displayName" => "Kites",
          "creator" => @creator
        })

      {text, _} = text(%{items: [feed]}, :feeds)

      assert text =~
               "uri: #{@feed} · cid: bafy\nlink: https://bsky.app/profile/did:plc:alice/feed/kites"
    end

    test "a starter pack, and the feeds it recommends" do
      pack =
        Summary.extract(:starter_pack, %{
          "uri" => @pack,
          "record" => %{"name" => "Kiters", "feeds" => [%{"uri" => @feed}]},
          "creator" => @creator
        })

      assert hd(pack.feeds).web_url == "https://bsky.app/profile/did:plc:alice/feed/kites"

      {text, _} = text(pack, :starter_pack)
      assert text =~ "uri: #{@pack}\nlink: https://bsky.app/start/did:plc:alice/3kpack"
    end

    test "a labeler, by its account's profile" do
      labeler = %{
        "did" => @did,
        "handle" => "alice.test",
        "web_url" => WebLink.profile("alice.test", @did),
        "labels" => []
      }

      {text, _} = text(%{items: [labeler]}, :labelers)
      assert text =~ "not subscribed\nlink: https://bsky.app/profile/alice.test"
    end
  end

  describe "a web link given to a tool" do
    defp mock do
      {:ok, effects} =
        AtMcp.Test.QuotaFixture.start_effects(
          backend: AtMcp.Test.MockBackend,
          backend_state: %{mock: true, did: "did:plc:mock", handle: "mock.test"},
          quota_limit: 5
        )

      %{effects: effects}
    end

    defp call(state, name, arguments) do
      {:ok, result, ^state} = AtMcp.MCP.Server.handle_call_tool(name, arguments, state)
      result
    end

    test "like takes a post's link, its handle resolved, and says what it was read as" do
      state = mock()
      link = "https://bsky.app/profile/bob.test/post/3kpost"
      result = call(state, "like", %{"uri" => link, "cid" => "bafy"})

      refute result[:isError], inspect(result)
      uri = "at://did:plc:bob.test/app.bsky.feed.post/3kpost"

      assert [%{argument: "uri", link: ^link, value: ^uri}] =
               result.structuredContent[:resolved] || result.structuredContent["resolved"]

      assert List.last(result.content).text == "resolved: uri #{link} is #{uri}"
    end

    test "a link to the wrong kind of thing is refused, naming what it is" do
      state = mock()

      result = call(state, "like", %{"uri" => "https://bsky.app/profile/bob.test/lists/l"})
      assert result.isError
      assert %{code: "invalid_arguments", problems: [%{path: "uri"}]} = result.structuredContent
      assert hd(result.content).text =~ "is a link to a list; this takes a post or a feed"

      result = call(state, "unlike", %{"uri" => "https://bsky.app/profile/bob.test/post/p"})
      assert hd(result.content).text =~ "the AT URI of a record no web link names"

      result = call(state, "get_thread", %{"uri" => "https://example.com/profile/a.test/post/p"})
      assert hd(result.content).text =~ "is a link to example.com, not to https://bsky.app"
    end

    test "an account's link where a handle or DID is taken, and links in a batch" do
      state = mock()

      result = call(state, "follow", %{"actor" => "https://bsky.app/profile/did:plc:bob"})
      refute result[:isError], inspect(result)
      assert List.last(result.content).text =~ "is did:plc:bob"

      result =
        call(state, "get_posts", %{
          "uris" => [@post, "https://bsky.app/profile/mock.test/post/3kmine"]
        })

      refute result[:isError], inspect(result)

      assert List.last(result.content).text ==
               "resolved: uris/1 https://bsky.app/profile/mock.test/post/3kmine is at://did:plc:mock/app.bsky.feed.post/3kmine"
    end

    test "every argument said to take a link is an argument of a served tool" do
      {:ok, tools, nil, :state} = AtMcp.MCP.Server.handle_list_tools(nil, :state)
      served = Map.new(tools, &{&1.name, Map.keys(&1.inputSchema[:properties] || %{})})

      for {tool, args} <- AtMcp.MCP.WebLinks.takes(), arg <- Map.keys(args) do
        assert arg in Enum.map(Map.fetch!(served, tool), &to_string/1), "#{tool}(#{arg})"
      end
    end

    test "every served argument that takes an AT URI, handle or DID takes a link" do
      {:ok, tools, nil, :state} = AtMcp.MCP.Server.handle_list_tools(nil, :state)
      takes = AtMcp.MCP.WebLinks.takes()
      names = ~r/AT URI|handles? or DIDs?|handle or DID|DID or handle/i

      missing =
        for tool <- tools,
            {arg, schema} <- tool.inputSchema[:properties] || %{},
            Regex.match?(names, inspect(schema)),
            not Map.has_key?(Map.get(takes, tool.name, %{}), to_string(arg)),
            do: "#{tool.name}(#{arg})"

      assert missing == []
    end

    test "an AT URI is passed on as before, with nothing resolved" do
      state = mock()
      result = call(state, "like", %{"uri" => @post, "cid" => "bafy"})
      refute result[:isError]
      refute Map.has_key?(result.structuredContent, :resolved)
      refute Map.has_key?(result.structuredContent, "resolved")
    end
  end
end
