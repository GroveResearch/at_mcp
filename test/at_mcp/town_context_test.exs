defmodule AtMcp.TownContextTest do
  @moduledoc """
  What a person sees in the Delvetown app and an agent could not read (#138):
  the Town feed, which the app pins as a tab for every account without storing
  it in the account's preferences, and the town's published policy pages.

  The feed comes from `AtMcp.Network.app_pinned_feeds/0`. `get_preferences`
  lists it beside the account's own saved feeds and writes nothing;
  `get_suggested_feeds` reads its view beside the service's suggestions on a
  first page. A network whose app pins nothing reads no more than before.

  The policy pages come from `AtMcp.Network.policy_url/1` and are read by
  `AtMcp.PolicyPage`, which is checked here against a local web server.
  """
  use ExUnit.Case, async: false

  alias AtMcp.Test.FakePDS

  @town "at://did:plc:qzqct2rrq4u2gmy5g3mjxske/town.delve.feed.generator/town"

  defp on_network(name) do
    Application.put_env(:at_mcp, :network, name)
    on_exit(fn -> Application.delete_env(:at_mcp, :network) end)
  end

  defp pds(opts) do
    {session, pds} =
      FakePDS.start(
        preferences: Keyword.get(opts, :preferences, []),
        answers: Keyword.get(opts, :answers, %{})
      )

    effects =
      start_supervised!(
        {AtMcp.Effects,
         backend: AtMcp.Effects.ProtoRune,
         backend_state: session,
         write_quota: AtMcp.Test.QuotaFixture.quota(10)},
        id: make_ref()
      )

    %{effects: effects, pds: pds}
  end

  defp generator(uri),
    do: %{
      uri: uri,
      cid: "bafytown",
      did: "did:web:api.delve.town",
      creator: %{did: "did:plc:qzqct2rrq4u2gmy5g3mjxske", handle: "delve.town"},
      displayName: "Town",
      description: "New posts across town.",
      likeCount: 0,
      indexedAt: "2026-09-08T00:00:00.000Z"
    }

  describe "the feeds the app pins for every account" do
    test "on delve.town the app pins the Town feed; Bluesky's app pins none" do
      on_network(:delve)
      assert AtMcp.Network.app_pinned_feeds() == [@town]
      on_network(:bluesky)
      assert AtMcp.Network.app_pinned_feeds() == []
    end

    test "get_preferences lists them apart from the account's saved feeds, and writes nothing" do
      on_network(:delve)

      %{effects: effects, pds: pds} =
        pds(
          preferences: [
            %{
              "$type" => "town.delve.actor.defs#savedFeedsPrefV2",
              "items" => [
                %{"id" => "1", "type" => "timeline", "value" => "following", "pinned" => true}
              ]
            }
          ]
        )

      assert {:ok, summary} = AtMcp.Effects.get_preferences(effects)
      assert summary.saved_feeds == [%{type: "timeline", value: "following", pinned: true}]
      assert summary.app_pinned_feeds == [%{type: "feed", value: @town, pinned: true}]
      refute "town.delve.actor.putPreferences" in FakePDS.methods(pds)

      text = AtMcp.Reading.preferences(Jason.decode!(Jason.encode!(summary)))
      assert text =~ "Pinned by the app for every account:\n- #{@town} · feed · pinned"
    end

    test "on a network whose app pins none, get_preferences lists none and its text says nothing of them" do
      on_network(:bluesky)
      %{effects: effects} = pds([])
      assert {:ok, %{app_pinned_feeds: []} = summary} = AtMcp.Effects.get_preferences(effects)

      refute AtMcp.Reading.preferences(Jason.decode!(Jason.encode!(summary))) =~
               "Pinned by the app"
    end

    test "get_suggested_feeds reads their views beside the service's suggestions on a first page" do
      on_network(:delve)

      %{effects: effects, pds: pds} =
        pds(
          answers: %{
            "town.delve.feed.getSuggestedFeeds" => {200, %{feeds: []}},
            "town.delve.feed.getFeedGenerator" =>
              {200, %{view: generator(@town), isOnline: true, isValid: true}}
          }
        )

      assert {:ok, page} = AtMcp.Effects.get_suggested_feeds(effects)
      assert page.items == []

      assert [%{uri: @town, display_name: "Town", creator: "delve.town", is_online: true}] =
               page.app_pinned_feeds

      assert [%{query: %{"feed" => @town}}] =
               FakePDS.sent(pds, "town.delve.feed.getFeedGenerator")

      text = AtMcp.Reading.feeds(Jason.decode!(Jason.encode!(page)))
      assert text =~ "0 feeds."
      assert text =~ "Pinned by the app for every account: \"Town\""
      assert text =~ "uri: #{@town}"

      # A later page is the service's alone.
      assert {:ok, later} = AtMcp.Effects.get_suggested_feeds(effects, cursor: "c")
      refute Map.has_key?(later, :app_pinned_feeds)
      assert [_] = FakePDS.sent(pds, "town.delve.feed.getFeedGenerator")
    end

    test "on a network whose app pins none, get_suggested_feeds reads only the suggestions" do
      on_network(:bluesky)

      %{effects: effects, pds: pds} =
        pds(answers: %{"app.bsky.feed.getSuggestedFeeds" => {200, %{feeds: []}}})

      assert {:ok, page} = AtMcp.Effects.get_suggested_feeds(effects)
      refute Map.has_key?(page, :app_pinned_feeds)
      refute Enum.any?(FakePDS.methods(pds), &String.contains?(&1, "getFeedGenerator"))
    end
  end

  describe "the town's policy pages" do
    defmodule Site do
      @moduledoc false
      import Plug.Conn

      def init(opts), do: opts

      def call(%{request_path: "/support/ai-agents"} = conn, _opts) do
        conn
        |> put_resp_content_type("text/html")
        |> send_resp(200, AtMcp.TownContextTest.page())
      end

      def call(%{request_path: "/support/bare"} = conn, _opts) do
        conn
        |> put_resp_content_type("text/html")
        |> send_resp(200, ~s(<!doctype html><html><body><div id="root"></div></body></html>))
      end

      def call(conn, _opts), do: send_resp(conn, 404, "not found")
    end

    # The shape delve.town serves (checked 2026-10-27): the app's shell, with
    # the page's text in `<main id="public-reading">` for a reader without
    # JavaScript.
    def page do
      """
      <!doctype html><html><head><title>Delvetown</title><style>p{color:red}</style></head><body>
      <main id="public-reading" lang="en"><nav><a href="/">Delvetown</a> · <a href="?app=1">Open app</a></nav><h1>Delvetown AI Agent Policy</h1><p>Effective date: September 29, 2026</p><p>The <a href="/support/tos">Terms of Service</a>
        and   Community Rules also apply.</p><h2>Visible identity &amp; first interaction</h2><ul><li>Use the label.</li><li>Don&#39;t &quot;pretend&quot; &lt;ever&gt;.</li></ul><p>Questions: <a href="mailto:hi@example.com">hi@example.com</a></p><noscript><p>Public reading works without JavaScript.</p></noscript></main><div id="root"></div></body></html>
      """
    end

    setup do
      ref = :"policy_site_#{System.unique_integer([:positive])}"

      start_supervised!(
        Plug.Cowboy.child_spec(
          scheme: :http,
          plug: Site,
          options: [port: 0, ip: {127, 0, 0, 1}, ref: ref]
        ),
        id: ref
      )

      %{origin: "http://127.0.0.1:#{:ranch.get_port(ref)}"}
    end

    test "a page reads as its title and its text, links with their addresses, and nothing of the site's chrome",
         %{origin: origin} do
      assert {:ok, %{title: "Delvetown AI Agent Policy", text: text}} =
               AtMcp.PolicyPage.read(origin <> "/support/ai-agents")

      assert text ==
               """
               # Delvetown AI Agent Policy

               Effective date: September 29, 2026

               The Terms of Service <#{origin}/support/tos> and Community Rules also apply.

               ## Visible identity & first interaction

               - Use the label.
               - Don't "pretend" <ever>.

               Questions: hi@example.com
               """
               |> String.trim()
    end

    test "a page without its reading text is unreadable, and a missing page is refused", %{
      origin: origin
    } do
      assert {:error, %AtMcp.Effects.Failure{kind: :unreadable}} =
               AtMcp.PolicyPage.read(origin <> "/support/bare")

      assert {:error, %AtMcp.Effects.Failure{kind: :refused, status: 404}} =
               AtMcp.PolicyPage.read(origin <> "/support/gone")
    end

    test "a page that cannot be read is reported as the site's answer, with no word of the account's service" do
      address = "https://delve.town/support/ai-agents"

      for {failure, code, says} <- [
            {AtMcp.Effects.Failure.new(:refused, status: 404, detail: {:web_page, address}),
             "page_unavailable", "#{address} answered HTTP 404."},
            {AtMcp.Effects.Failure.new(:unreadable, detail: {:web_page, address}),
             "page_unreadable", "#{address} answered, and its text could not be read"}
          ] do
        assert {:ok, %{isError: true} = result, :state} =
                 AtMcp.MCP.Tools.respond({:error, failure}, :state, :policy)

        assert result.structuredContent.code == code
        text = hd(result.content).text
        assert text =~ says
        refute text =~ "account's service"
      end
    end

    test "delve.town publishes each page under /support; Bluesky's network has none here" do
      on_network(:delve)
      assert AtMcp.Network.policy_url("ai_agents") == "https://delve.town/support/ai-agents"

      assert AtMcp.Network.policy_url("community_rules") ==
               "https://delve.town/support/community-guidelines"

      on_network(:bluesky)
      assert AtMcp.Network.policy_url("ai_agents") == nil
    end

    test "on a network without them, get_policy is refused before anything is sent" do
      on_network(:bluesky)
      %{effects: effects, pds: pds} = pds([])
      state = %{effects: effects}

      assert {:ok, %{isError: true} = result, ^state} =
               AtMcp.MCP.Server.handle_call_tool(
                 "get_policy",
                 %{"page" => "ai_agents", "format" => "json"},
                 state
               )

      assert result.structuredContent.code == "policies_not_published"
      assert hd(result.content).text =~ "Nothing was sent"
      assert FakePDS.methods(pds) == []
    end

    test "the text a model reads quotes the page as the town's words" do
      text =
        AtMcp.Reading.policy(%{
          "page" => "ai_agents",
          "title" => "Delvetown AI Agent Policy",
          "url" => "https://delve.town/support/ai-agents",
          "text" => "# Delvetown AI Agent Policy\n\nUse the label."
        })

      assert text ==
               Enum.join(
                 [
                   ~s("Delvetown AI Agent Policy", published at https://delve.town/support/ai-agents. Its text, quoted:),
                   "> # Delvetown AI Agent Policy",
                   "> ",
                   "> Use the label."
                 ],
                 "\n"
               )
    end
  end
end
