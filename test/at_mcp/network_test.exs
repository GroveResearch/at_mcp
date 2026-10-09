defmodule AtMcp.NetworkTest do
  @moduledoc """
  The network is one value, and everything that names a namespace derives from
  it.

  These checks are written to fail for a specific defect rather than to confirm
  that the code runs: a transcribed limit drifting from its lexicon, a method
  path still carrying `app.bsky` on the wire, a collection filter or a facet
  type frozen at the default. The wire-level ones run against a fake PDS,
  because a helper returning the right string proves nothing about the request
  AtMcp actually sends.
  """
  use ExUnit.Case, async: false

  defmodule PDS do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      Agent.update(opts[:paths], &(&1 ++ [conn.request_path]))

      body =
        case conn.request_path do
          "/xrpc/" <> method ->
            if String.ends_with?(method, "getProfile"),
              do: %{did: "did:plc:self", handle: "self.example"},
              else: %{}
        end

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(body))
    end
  end

  setup do
    on_exit(fn -> Application.delete_env(:at_mcp, :network) end)
    :ok
  end

  defp on_network(name) do
    Application.put_env(:at_mcp, :network, name)
  end

  # A session pointed at a fake PDS, so the path AtMcp asks for is observable.
  defp session_against(port) do
    %ProtoRune.Atproto.Session{
      access_jwt: "access",
      refresh_jwt: "refresh",
      did: "did:plc:self",
      handle: "self.example",
      service_url: "http://127.0.0.1:#{port}/xrpc"
    }
  end

  defp fake_pds(ref) do
    paths = start_supervised!({Agent, fn -> [] end}, id: {:paths, ref})

    start_supervised!(
      Plug.Cowboy.child_spec(
        scheme: :http,
        plug: {PDS, paths: paths},
        options: [port: 0, ip: {127, 0, 0, 1}, ref: ref]
      ),
      id: {:pds, ref}
    )

    {:ranch.get_port(ref), paths}
  end

  describe "the declaration" do
    test "Bluesky is the default, so an installation that says nothing is unchanged" do
      assert AtMcp.Network.name() == :bluesky
      assert AtMcp.Network.namespace() == "app.bsky"
      assert AtMcp.Network.collection(:post) == "app.bsky.feed.post"
      assert AtMcp.Network.nsid("feed.getPosts") == "app.bsky.feed.getPosts"
      assert AtMcp.Network.type(:mention_facet) == "app.bsky.richtext.facet#mention"
      assert AtMcp.Network.default_service() == "https://bsky.social"
    end

    test "every name derives from the namespace, with no second substitution rule" do
      on_network(:delve)

      assert AtMcp.Network.namespace() == "town.delve"

      for kind <- [:post, :like, :repost, :follow, :block, :profile, :generator, :list] do
        assert "town.delve." <> _ = AtMcp.Network.collection(kind)
      end

      assert AtMcp.Network.inbound_collections() == [
               "town.delve.feed.post",
               "town.delve.feed.like",
               "town.delve.feed.repost"
             ]

      assert AtMcp.Network.default_service() == "https://pds.delve.town"
    end

    # A typo that keeps talking to Bluesky is the defect this module removes,
    # and it would be invisible until an agent posted to the wrong network.
    test "an unrecognized network raises rather than falling back" do
      on_network(:mastodon)

      assert_raise ArgumentError, ~r/unknown :at_mcp network :mastodon/, fn ->
        AtMcp.Network.collection(:post)
      end
    end
  end

  describe "the post limits" do
    # This is the check that makes the limits a derivation rather than a
    # transcription: it parses the same lexicon files independently and fails if
    # the compiled numbers ever stop matching them.
    test "are the numbers in each network's own lexicon" do
      for {name, dir} <- [bluesky: "app/bsky", delve: "town/delve"] do
        %{"defs" => %{"main" => %{"record" => %{"properties" => %{"text" => field}}}}} =
          Path.join([Application.app_dir(:at_mcp, "priv"), "lexicons", dir, "feed", "post.json"])
          |> File.read!()
          |> Jason.decode!()

        on_network(name)

        assert AtMcp.Network.post_limits() == %{
                 graphemes: field["maxGraphemes"],
                 bytes: field["maxLength"]
               }
      end
    end

    test "bound what AtMcp refuses before it sends anything" do
      long = String.duplicate("a", 5_000)

      assert {:error, :post_text_too_long} = AtMcp.Effects.validate_post_text(long)

      on_network(:delve)
      assert :ok = AtMcp.Effects.validate_post_text(long)

      assert {:error, :post_text_too_long} =
               AtMcp.Effects.validate_post_text(String.duplicate("a", 100_001))
    end

    # An agent told "at most 300 graphemes" on a network that takes 100,000 has
    # been given a reason it cannot act on.
    test "are the numbers the refusal names" do
      on_network(:delve)

      {:ok, result, :state} = AtMcp.MCP.Tools.respond({:error, :post_text_too_long}, :state)
      text = hd(result.content).text

      assert text =~ "100000 Unicode graphemes"
      assert text =~ "500000 UTF-8 bytes"
      refute text =~ "300"
    end
  end

  describe "on the wire" do
    test "a read asks for the configured namespace's method, not app.bsky's" do
      {port, paths} = fake_pds(:network_test_delve)
      on_network(:delve)

      assert {:ok, _} = AtMcp.Effects.ProtoRune.get_profile(session_against(port), "self.example")

      assert Agent.get(paths, & &1) == ["/xrpc/town.delve.actor.getProfile"]
    end

    test "and by default asks for app.bsky's, exactly as before" do
      {port, paths} = fake_pds(:network_test_bluesky)

      assert {:ok, _} = AtMcp.Effects.ProtoRune.get_profile(session_against(port), "self.example")

      assert Agent.get(paths, & &1) == ["/xrpc/app.bsky.actor.getProfile"]
    end

    # Every read AtMcp makes goes through one of these, so naming them one by one
    # is what stops a single endpoint being left behind on the old namespace.
    test "every declared read and write carries the namespace" do
      {port, paths} = fake_pds(:network_test_all)
      on_network(:delve)
      session = session_against(port)

      AtMcp.ATProto.get_post_thread(session, %{uri: "at://did:plc:x/c/1"})
      AtMcp.ATProto.get_author_feed(session, %{actor: "self.example"})
      AtMcp.ATProto.get_feed(session, %{feed: "at://did:plc:x/c/1"})
      AtMcp.ATProto.get_suggested_feeds(session, %{limit: 1})
      AtMcp.ATProto.get_list_feed(session, %{list: "at://did:plc:x/c/1"})
      AtMcp.ATProto.get_likes(session, %{uri: "at://did:plc:x/c/1"})
      AtMcp.ATProto.get_quotes(session, %{uri: "at://did:plc:x/c/1"})
      AtMcp.ATProto.get_reposted_by(session, %{uri: "at://did:plc:x/c/1"})
      AtMcp.ATProto.get_actor_likes(session, %{actor: "self.example"})
      AtMcp.ATProto.get_timeline(session, %{limit: 1})
      AtMcp.ATProto.search_posts(session, %{q: "x"})
      AtMcp.ATProto.get_profile(session, %{actor: "self.example"})
      AtMcp.ATProto.search_actors(session, %{q: "x"})
      AtMcp.ATProto.list_notifications(session, %{limit: 1})
      AtMcp.ATProto.get_unread_count(session, %{})
      AtMcp.ATProto.update_seen(session, %{seen_at: "2026-01-01T00:00:00Z"})
      AtMcp.ATProto.get_followers(session, %{actor: "self.example"})
      AtMcp.ATProto.get_follows(session, %{actor: "self.example"})
      AtMcp.ATProto.get_known_followers(session, %{actor: "self.example"})
      AtMcp.ATProto.get_suggested_follows_by_actor(session, %{actor: "self.example"})
      AtMcp.ATProto.get_blocks(session, %{})
      AtMcp.ATProto.get_mutes(session, %{})
      AtMcp.ATProto.get_profiles(session, ["self.example"])
      AtMcp.ATProto.get_posts(session, ["at://did:plc:x/c/1"])
      AtMcp.ATProto.get_relationships(session, "self.example", ["other.example"])

      asked = Agent.get(paths, & &1)

      assert length(asked) == 25
      assert Enum.all?(asked, &String.starts_with?(&1, "/xrpc/town.delve."))
    end
  end

  describe "the records AtMcp reads and matches" do
    test "the inbound filter subscribes to the configured network's collections" do
      on_network(:delve)

      {:ok, pid} =
        AtMcp.Inbound.start_link(
          name: :"inbound_network_#{System.unique_integer([:positive])}",
          enabled: false
        )

      assert :sys.get_state(pid).collections == [
               "town.delve.feed.post",
               "town.delve.feed.like",
               "town.delve.feed.repost"
             ]

      GenServer.stop(pid)
    end

    test "a mention on the configured network matches, and the other network's does not" do
      on_network(:delve)

      event = fn type ->
        %{
          kind: :commit,
          did: "did:plc:author",
          collection: "town.delve.feed.post",
          record: %{"facets" => [%{"features" => [%{"$type" => type, "did" => "did:plc:me"}]}]}
        }
      end

      assert [{"did:plc:me", [:mention]}] =
               AtMcp.Inbound.Match.match_dids(
                 event.("town.delve.richtext.facet#mention"),
                 ["did:plc:me"]
               )

      assert [] =
               AtMcp.Inbound.Match.match_dids(
                 event.("app.bsky.richtext.facet#mention"),
                 ["did:plc:me"]
               )
    end

    test "a like on the configured network's collection matches as a like" do
      on_network(:delve)

      assert [{"did:plc:me", [:like]}] =
               AtMcp.Inbound.Match.match_dids(
                 %{
                   kind: :commit,
                   did: "did:plc:author",
                   collection: "town.delve.feed.like",
                   record: %{"subject" => %{"uri" => "at://did:plc:me/town.delve.feed.post/1"}}
                 },
                 ["did:plc:me"]
               )
    end

    test "a mention facet AtMcp writes carries the configured network's type" do
      on_network(:delve)

      {rich_text, []} =
        AtMcp.RichText.build("hello @self.example", nil,
          resolve: fn _ -> {:ok, "did:plc:self"} end
        )

      assert [%{features: [%{"$type": "town.delve.richtext.facet#mention"}]}] = rich_text.facets
    end
  end

  # The existing account-setup test pins the Bluesky default by matching
  # `service: "https://bsky.social"` in its login callback, so that half is
  # already falsified. This is the other half.
  test "a new account defaults to the configured network's service" do
    dir =
      Path.join(System.tmp_dir!(), "at_mcp-network-setup-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(dir) end)
    path = Path.join(dir, "accounts.json")

    on_network(:delve)

    assert {:ok, %{account: account}} =
             AtMcp.AccountSetup.execute(
               ["--file", path, "add", "grug", "--handle", "grug.delve.town"],
               password: fn -> "private-password" end,
               login: fn handle, "private-password", [service: "https://pds.delve.town"] ->
                 {:ok, %{did: "did:plc:grug", handle: handle}}
               end
             )

    assert account["service"] == "https://pds.delve.town"
  end

  test "identity_status reports the network, because a tool description cannot" do
    on_network(:delve)

    {:ok, effects} = AtMcp.Test.QuotaFixture.start_effects(backend: AtMcp.Test.MockBackend)
    {:ok, status} = AtMcp.MCP.Tools.identity_status(effects)

    # The label is here too: a caller that has to name the network to a reader
    # cannot make "delve.town" out of the atom or the nsid prefix.
    assert status.network == %{
             name: "delve",
             label: "delve.town",
             namespace: "town.delve",
             post_limits: %{graphemes: 100_000, bytes: 500_000}
           }
  end

  # A host receiving an event has no other way to know which network it happened
  # on: a namespace is a lexicon prefix, and a DID does not say where it lives. An
  # installation that told an inhabitant "on Bluesky" while it was on delve.town
  # would be lying to it.
  test "each network has a name a reader recognises" do
    assert AtMcp.Network.label() == "Bluesky"

    Application.put_env(:at_mcp, :network, :delve)
    on_exit(fn -> Application.delete_env(:at_mcp, :network) end)

    assert AtMcp.Network.label() == "delve.town"
  end
end
