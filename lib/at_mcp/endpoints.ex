defmodule AtMcp.Endpoints do
  @moduledoc """
  Every client endpoint and record type in the lexicons, and what at_mcp does
  with each.

  An agent should be able to do what a person can do in the Bluesky app, reads
  and writes alike (#82). This table holds at_mcp to that. Each query,
  procedure, subscription and record type in `test/fixtures/lexicon_endpoints.txt`
  has one entry. `test/at_mcp/endpoint_coverage_test.exs` fails when the list
  has an NSID that no entry covers, when an entry covers nothing in the list, or
  when two entries cover the same NSID. It also fails when a tool an entry names
  is not served. `scripts/list_lexicon_endpoints.py` regenerates the list from an
  atproto checkout, so a lexicon added upstream shows up as a failure here.

  NSIDs are written in the `app.bsky` namespace. On delve.town the same
  endpoints are `town.delve.*`, and `AtMcp.Network` maps between them.
  Endpoints that exist only on delve.town are written `town.delve.*`.

  An entry is `{pattern, outcome}`. A pattern is an NSID, or one with `*`
  standing for any run of characters (`tools.ozone.*`, `app.bsky.unspecced.*Skeleton`).
  The outcome is one of these:

    * `{:tool, name}`: the MCP tool `name` calls this endpoint or writes this
      record. Several endpoints can share a tool. Records and the
      `com.atproto.repo` calls that write them both name the tool.
    * `{:todo, issue}`: a person can do this in the app and at_mcp cannot yet.
      The GroveResearch/at_mcp issue names the tool that will.
    * `{:left_out, reason}`: not something a person does through the app on
      their own account, or already done by another tool. The reason says
      which.

  The outcome is the same on every network: what a person can do on Bluesky,
  at_mcp's default network, is a tool or an issue. Some services a network
  needs are not run by every deployment. Bluesky serves chat and video from
  their own services (`did:web:api.bsky.chat`, `video.bsky.app`), not from the
  AppView. `deployments/0` names what a deployment is known not to serve, with
  the evidence, so a tool can refuse there before sending anything.
  """

  @posts 88
  @moderation 90
  @preferences 91
  @dms 92
  @video 96

  @entries [
    # --- Reading posts, threads and feeds ---
    {"app.bsky.feed.getTimeline", {:tool, "get_timeline"}},
    {"app.bsky.feed.getAuthorFeed", {:tool, "get_author_feed"}},
    {"app.bsky.feed.getPostThread", {:tool, "get_thread"}},
    {"app.bsky.unspecced.getPostThreadV2", {:todo, @posts}},
    {"app.bsky.unspecced.getPostThreadOtherV2", {:tool, "get_thread"}},
    {"app.bsky.feed.getPosts", {:tool, "get_posts"}},
    {"app.bsky.feed.getLikes", {:tool, "get_likes"}},
    {"app.bsky.feed.getRepostedBy", {:tool, "get_reposted_by"}},
    {"app.bsky.feed.getQuotes", {:tool, "get_quotes"}},
    {"app.bsky.feed.getActorLikes", {:tool, "get_actor_likes"}},
    {"app.bsky.feed.searchPosts",
     {:left_out, "The first version of `feed.searchPostsV2`, which `search_posts` calls"}},
    {"app.bsky.feed.searchPostsV2", {:tool, "search_posts"}},
    {"app.bsky.feed.getFeed", {:tool, "get_feed"}},
    {"app.bsky.feed.getListFeed", {:tool, "get_list_feed"}},
    {"app.bsky.feed.getSuggestedFeeds", {:tool, "get_suggested_feeds"}},
    {"app.bsky.feed.getFeedGenerator", {:tool, "get_feed_info"}},
    {"app.bsky.feed.getFeedGenerators", {:tool, "get_feed_info"}},
    {"app.bsky.feed.getActorFeeds", {:tool, "get_actor_feeds"}},
    {"app.bsky.unspecced.getPopularFeedGenerators", {:tool, "search_feeds"}},
    {"app.bsky.feed.describeFeedGenerator",
     {:left_out, "Asked of a feed generator service by an AppView, not by a client"}},
    {"app.bsky.feed.getFeedSkeleton",
     {:left_out,
      "Asked of a feed generator service by an AppView; `get_feed` reads the hydrated feed"}},
    {"app.bsky.feed.sendInteractions", {:tool, "feed_feedback"}},
    {"app.bsky.embed.getEmbedExternalView", {:todo, @posts}},

    # --- Writing posts and interacting with them ---
    {"app.bsky.feed.post", {:tool, "post"}},
    {"app.bsky.feed.like", {:tool, "like"}},
    {"app.bsky.feed.repost", {:tool, "repost"}},
    {"app.bsky.feed.threadgate", {:tool, "set_post_interactions"}},
    {"app.bsky.feed.postgate", {:tool, "set_post_interactions"}},
    {"app.bsky.graph.muteThread", {:tool, "mute_thread"}},
    {"app.bsky.graph.unmuteThread", {:tool, "unmute_thread"}},
    {"app.bsky.bookmark.createBookmark", {:tool, "bookmark"}},
    {"app.bsky.bookmark.deleteBookmark", {:tool, "unbookmark"}},
    {"app.bsky.bookmark.getBookmarks", {:tool, "get_bookmarks"}},
    {"app.bsky.draft.createDraft", {:tool, "save_draft"}},
    {"app.bsky.draft.updateDraft", {:tool, "save_draft"}},
    {"app.bsky.draft.deleteDraft", {:tool, "delete_draft"}},
    {"app.bsky.draft.getDrafts", {:tool, "get_drafts"}},
    {"app.bsky.video.*", {:todo, @video}},

    # --- Accounts and the social graph ---
    {"app.bsky.actor.getProfile", {:tool, "get_profile"}},
    {"app.bsky.actor.getProfiles", {:tool, "get_profiles"}},
    {"app.bsky.actor.searchActors", {:tool, "search_actors"}},
    {"app.bsky.actor.searchActorsTypeahead",
     {:left_out,
      "Prefix search for the app's search box; `search_actors` finds the same accounts"}},
    {"app.bsky.actor.getSuggestions", {:tool, "get_suggested_follows"}},
    {"app.bsky.actor.profile", {:tool, "update_profile"}},
    {"app.bsky.actor.status", {:tool, "set_status"}},
    {"app.bsky.actor.link", {:tool, "update_profile"}},
    {"app.bsky.graph.follow", {:tool, "follow"}},
    {"app.bsky.graph.block", {:tool, "block"}},
    {"app.bsky.graph.muteActor", {:tool, "mute"}},
    {"app.bsky.graph.unmuteActor", {:tool, "unmute"}},
    {"app.bsky.graph.getFollowers", {:tool, "get_followers"}},
    {"app.bsky.graph.getFollows", {:tool, "get_follows"}},
    {"app.bsky.graph.getKnownFollowers", {:tool, "get_known_followers"}},
    {"app.bsky.graph.getSuggestedFollowsByActor", {:tool, "get_suggested_follows"}},
    {"app.bsky.graph.getBlocks", {:tool, "get_blocks"}},
    {"app.bsky.graph.getMutes", {:tool, "get_mutes"}},
    {"app.bsky.graph.getRelationships", {:tool, "get_relationships"}},
    {"app.bsky.graph.verification",
     {:left_out,
      "Only accounts the AppView trusts as verifiers can verify others; the app offers it to them alone"}},

    # --- Lists and starter packs ---
    {"app.bsky.graph.getList", {:tool, "get_list"}},
    {"app.bsky.graph.getLists", {:tool, "get_lists"}},
    {"app.bsky.graph.getListsWithMembership", {:tool, "get_lists"}},
    {"app.bsky.graph.list", {:tool, "create_list"}},
    {"app.bsky.graph.listitem", {:tool, "add_to_list"}},
    {"app.bsky.graph.referencelistoptout", {:tool, "set_list_opt_out"}},
    {"app.bsky.graph.getStarterPack", {:tool, "get_starter_pack"}},
    {"app.bsky.graph.getStarterPacks",
     {:left_out,
      "Several starter packs by URI, for hydrating links; `get_starter_pack` reads one"}},
    {"app.bsky.graph.getActorStarterPacks", {:tool, "get_starter_packs"}},
    {"app.bsky.graph.getStarterPacksWithMembership", {:tool, "get_starter_packs"}},
    {"app.bsky.graph.searchStarterPacks",
     {:left_out,
      "The first version of `graph.searchStarterPacksV2`, which `get_starter_packs` calls"}},
    {"app.bsky.graph.searchStarterPacksV2", {:tool, "get_starter_packs"}},
    {"app.bsky.graph.starterpack", {:tool, "create_starter_pack"}},
    {"app.bsky.unspecced.getSuggestedStarterPacks", {:tool, "get_suggested_starter_packs"}},
    {"app.bsky.unspecced.getOnboardingSuggestedStarterPacks",
     {:tool, "get_suggested_starter_packs"}},

    # --- Moderation ---
    {"com.atproto.moderation.createReport", {:todo, @moderation}},
    {"app.bsky.graph.muteActorList", {:todo, @moderation}},
    {"app.bsky.graph.unmuteActorList", {:todo, @moderation}},
    {"app.bsky.graph.listblock", {:todo, @moderation}},
    {"app.bsky.graph.getListMutes", {:todo, @moderation}},
    {"app.bsky.graph.getListBlocks", {:todo, @moderation}},
    {"app.bsky.labeler.getServices", {:todo, @moderation}},
    {"app.bsky.labeler.service",
     {:left_out,
      "Declares this account a labeler, which needs a labeling service behind it; the app does not create one"}},
    {"com.atproto.label.queryLabels",
     {:left_out, "Labels arrive on the posts and profiles every read returns (`labels`)"}},
    {"com.atproto.label.subscribeLabels",
     {:left_out, "A labeler's event stream, for AppViews and relays"}},

    # --- Preferences and notifications ---
    {"app.bsky.actor.getPreferences", {:tool, "get_preferences"}},
    {"app.bsky.actor.putPreferences", {:tool, "set_preference"}},
    {"app.bsky.actor.contentVisibilityDeclaration", {:tool, "set_preference"}},
    {"app.bsky.notification.declaration", {:tool, "set_preference"}},
    {"app.bsky.notification.listNotifications", {:tool, "get_notifications"}},
    {"app.bsky.notification.getUnreadCount", {:tool, "get_unread_count"}},
    {"app.bsky.notification.updateSeen", {:tool, "update_seen"}},
    {"app.bsky.notification.getGroupedNotifications", {:todo, @preferences}},
    {"app.bsky.notification.getPreferences", {:tool, "get_notification_settings"}},
    {"app.bsky.notification.putPreferencesV2", {:tool, "set_notification_setting"}},
    {"app.bsky.notification.putPreferences",
     {:left_out,
      "The first version of `notification.putPreferencesV2`, which `set_notification_setting` calls"}},
    {"app.bsky.notification.putActivitySubscription", {:tool, "subscribe_to_activity"}},
    {"app.bsky.notification.listActivitySubscriptions", {:tool, "get_activity_subscriptions"}},
    {"app.bsky.notification.registerPush",
     {:left_out,
      "Registers a phone for push notifications; at_mcp delivers notifications itself (`AtMcp.Notifications`)"}},
    {"app.bsky.notification.unregisterPush",
     {:left_out, "Unregisters a phone from push notifications; at_mcp registers none"}},

    # --- Discovery ---
    {"app.bsky.unspecced.*Skeleton",
     {:left_out,
      "What an AppView asks its search or suggestion service; a client calls the hydrated form"}},
    {"app.bsky.unspecced.getSuggestedFeeds", {:tool, "get_suggested_feeds"}},
    {"app.bsky.unspecced.getSuggestedUsers", {:tool, "get_suggested_follows"}},
    {"app.bsky.unspecced.getSuggestedUsersForExplore", {:tool, "get_suggested_follows"}},
    {"app.bsky.unspecced.getSuggestedUsersForDiscover", {:tool, "get_suggested_follows"}},
    {"app.bsky.unspecced.getSuggestedUsersForSeeMore", {:tool, "get_suggested_follows"}},
    {"app.bsky.unspecced.getSuggestedOnboardingUsers", {:tool, "get_suggested_follows"}},
    {"app.bsky.unspecced.getTaggedSuggestions",
     {:left_out,
      "Suggested accounts grouped by interest tag; the current app does not call it, and `get_suggested_follows` reads the suggestion endpoints it does call"}},
    {"app.bsky.unspecced.getTrends", {:tool, "get_trends"}},
    {"app.bsky.unspecced.getTrendingTopics", {:tool, "get_trends"}},
    {"app.bsky.unspecced.getAtmosphereExploreTab",
     {:left_out,
      "The app's Explore tab is behind a feature gate the AppView keeps off: it answers 403 \"Atmosphere Explore is not enabled\" (checked 2026-10-18), so there is no response to read a summary from. Build it when the gate is on"}},
    {"app.bsky.unspecced.getAtmosphereExploreArticleRecommendations",
     {:left_out,
      "A skeleton the AppView asks its recommendation service, which `getAtmosphereExploreTab` hydrates (its lexicon says so); the AppView does not serve it to clients"}},
    {"app.bsky.unspecced.getConfig",
     {:left_out, "The app's own feature configuration, not the account's"}},
    {"app.bsky.feed.generator",
     {:left_out,
      "Declares a feed, which needs a feed generator service behind it; the app does not create one"}},

    # --- Things an agent's account does not do ---
    {"app.bsky.ageassurance.*",
     {:left_out,
      "Age assurance verifies the age of the person who holds the account; an agent cannot truthfully take part"}},
    {"app.bsky.unspecced.getAgeAssuranceState",
     {:left_out,
      "Age assurance verifies the age of the person who holds the account; an agent cannot truthfully take part"}},
    {"app.bsky.unspecced.initAgeAssurance",
     {:left_out,
      "Age assurance verifies the age of the person who holds the account; an agent cannot truthfully take part"}},
    {"app.bsky.contact.*",
     {:left_out,
      "Finds friends from a phone's address book after verifying a phone number; an agent has neither"}},
    {"chat.bsky.convo.*", {:todo, @dms}},
    {"chat.bsky.group.*", {:todo, @dms}},
    {"chat.bsky.notification.*", {:todo, @dms}},
    {"chat.bsky.actor.getStatus", {:todo, @dms}},
    {"chat.bsky.actor.declaration", {:todo, @dms}},
    {"chat.bsky.actor.deleteAccount",
     {:left_out, "The account's lifecycle belongs to its operator, not the agent"}},
    {"chat.bsky.actor.exportAccountData",
     {:left_out, "The account's lifecycle belongs to its operator, not the agent"}},
    {"chat.bsky.moderation.*", {:left_out, "The chat service's API for its moderators"}},

    # --- The account's repository, identity and session ---
    {"com.atproto.repo.createRecord", {:tool, "post"}},
    {"com.atproto.repo.putRecord", {:tool, "update_profile"}},
    {"com.atproto.repo.deleteRecord", {:tool, "delete_post"}},
    {"com.atproto.repo.uploadBlob", {:tool, "post"}},
    {"com.atproto.repo.applyWrites", {:tool, "post"}},
    {"com.atproto.repo.getRecord", {:tool, "get_record"}},
    {"com.atproto.repo.listRecords", {:tool, "remove_from_list"}},
    {"com.atproto.repo.describeRepo",
     {:left_out, "Describes a repository's collections, for tools that inspect repositories"}},
    {"com.atproto.repo.importRepo",
     {:left_out,
      "Moves a whole repository to a new PDS, which is account migration and belongs to the operator"}},
    {"com.atproto.repo.listMissingBlobs",
     {:left_out, "Lists blobs missing after an account migration, which belongs to the operator"}},
    {"com.atproto.identity.resolveHandle",
     {:left_out, "Every tool that takes an actor accepts a handle and resolves it"}},
    {"com.atproto.identity.resolveIdentity",
     {:left_out, "Every tool that takes an actor accepts a handle and resolves it"}},
    {"com.atproto.identity.resolveDid",
     {:left_out, "Every tool that takes an actor accepts a DID; reads return the handle"}},
    {"com.atproto.identity.updateHandle",
     {:left_out,
      "The account's handle is its identity, which its operator configures (`at_mcp account`)"}},
    {"com.atproto.identity.refreshIdentity",
     {:left_out, "Asks the service to re-resolve an identity, a repair step for the operator"}},
    {"com.atproto.identity.getRecommendedDidCredentials",
     {:left_out, "Part of moving the account's DID to a new PDS, which belongs to the operator"}},
    {"com.atproto.identity.requestPlcOperationSignature",
     {:left_out, "Part of changing the account's DID document, which belongs to the operator"}},
    {"com.atproto.identity.signPlcOperation",
     {:left_out, "Part of changing the account's DID document, which belongs to the operator"}},
    {"com.atproto.identity.submitPlcOperation",
     {:left_out, "Part of changing the account's DID document, which belongs to the operator"}},
    {"com.atproto.server.*",
     {:left_out,
      "Sessions, passwords, email and the account's lifecycle belong to its operator; at_mcp logs in with the app password the operator configured, and `identity_status` reports the session"}},
    {"com.atproto.lexicon.*",
     {:left_out, "Publishes or resolves lexicon schemas, for developers of an application"}},
    {"com.atproto.sync.*",
     {:left_out,
      "Repository sync, for relays and AppViews; editing a post's gates, and the list and starter pack writes built from reads, read the latest commit (`getLatestCommit`) to write over it and nothing newer"}},
    {"com.atproto.admin.*", {:left_out, "The PDS operator's administration API"}},
    {"com.atproto.temp.*", {:left_out, "Temporary service-to-service methods"}},
    {"tools.ozone.*", {:left_out, "Ozone, the moderation service's API for moderators"}},
    {"internal.bsky.*", {:left_out, "Internal to Bluesky's services"}},
    {"town.delve.membership.getMembership", {:tool, "get_membership"}},
    {"town.delve.membership.join",
     {:left_out,
      "A policy choice, not a limit of the app: joining accepts delve.town's terms, and at_mcp leaves that to the person responsible for the account"}},
    {"town.delve.membership.withdraw",
     {:left_out,
      "A policy choice, not a limit of the app: withdrawing ends the account's membership, and at_mcp leaves that to the person responsible for the account"}},
    {"town.delve.invitation.getCodes", {:tool, "get_invite_codes"}},
    {"town.delve.admin.*", {:left_out, "The town operator's administration API"}},

    # --- Other applications' records that Bluesky's AppView reads ---
    {"com.germnetwork.*",
     {:left_out,
      "Another application's record; the AppView shows it on profiles, and #79 covers what reads drop"}},
    {"place.stream.*", {:left_out, "Another application's records (live streaming)"}},
    {"site.standard.*", {:left_out, "Another application's records (long-form publishing)"}},
    {"social.grain.*", {:left_out, "Another application's records (photo galleries)"}}
  ]

  # What a deployment is known not to serve. Checked 2026-10-18 by calling each
  # method without credentials on https://api.delve.town/xrpc, where a served
  # method answers 401 or 400 and an unserved one 501, and by reading the
  # AppView's DID document.
  @delve_501 "delve.town's AppView answers 501 Method Not Implemented"
  @delve_absent "Not in delve.town's lexicons; its AppView answers 501"
  @delve_chat "delve.town's AppView answers 501 and its DID document names no chat service. Whether the town's PDS proxies a town account to Bluesky's chat service (`atproto-proxy: did:web:api.bsky.chat#bsky_chat`) is untested: without credentials the PDS answers AuthMissing before proxying"

  @deployments %{
    delve: [
      {"chat.bsky.convo.*", @delve_chat},
      {"chat.bsky.group.*", @delve_chat},
      {"chat.bsky.notification.*", @delve_chat},
      {"chat.bsky.actor.getStatus", @delve_chat},
      {"chat.bsky.actor.declaration", @delve_chat},
      {"app.bsky.video.*",
       "#{@delve_501}, and the town runs no video service. Uploading a town account's video to Bluesky's (video.bsky.app) is untested"},
      {"app.bsky.feed.sendInteractions",
       "#{@delve_501}. The app sends feed feedback to the feed generator's own service, not the AppView, and whether any feed on the town takes `town.delve.feed.sendInteractions` is untested"},
      {"app.bsky.unspecced.getTrends", @delve_501},
      {"app.bsky.unspecced.getTrendingTopics", @delve_501},
      {"app.bsky.unspecced.getSuggestedUsers", @delve_501},
      {"app.bsky.unspecced.getSuggestedFeeds", @delve_501},
      {"app.bsky.actor.link", @delve_absent},
      {"app.bsky.notification.getGroupedNotifications", @delve_absent}
    ]
  }

  @doc "Every entry, in order: `{pattern, outcome}`."
  def entries, do: @entries

  @doc """
  What each deployment is known not to serve: `%{network => [{pattern, evidence}]}`,
  keyed by the network names in `AtMcp.Network`. A network not named here
  serves everything in `entries/0`.
  """
  def deployments, do: @deployments

  @doc """
  Why `network` does not serve `nsid` (written in the `app.bsky` namespace),
  or nil when nothing says it does not. A tool asks before it sends anything,
  so a call a deployment cannot answer is refused at no cost.
  """
  def not_served(network, nsid) do
    Enum.find_value(Map.get(@deployments, network, []), fn {pattern, evidence} ->
      if covers?(pattern, nsid), do: evidence
    end)
  end

  @doc "Whether `pattern` covers `nsid`. `*` stands for any run of characters."
  def covers?(pattern, nsid) do
    regex =
      pattern
      |> String.split("*")
      |> Enum.map_join(".*", &Regex.escape/1)

    Regex.match?(~r/\A#{regex}\z/, nsid)
  end
end
