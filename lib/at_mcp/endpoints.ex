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
  @feeds 93
  @video 96

  @entries [
    # --- Reading posts, threads and feeds ---
    {"app.bsky.feed.getTimeline", {:tool, "get_timeline"}},
    {"app.bsky.feed.getAuthorFeed", {:tool, "get_author_feed"}},
    {"app.bsky.feed.getPostThread", {:tool, "get_thread"}},
    {"app.bsky.unspecced.getPostThreadV2", {:todo, @posts}},
    {"app.bsky.unspecced.getPostThreadOtherV2", {:todo, @posts}},
    {"app.bsky.feed.getPosts", {:tool, "get_posts"}},
    {"app.bsky.feed.getLikes", {:tool, "get_likes"}},
    {"app.bsky.feed.getRepostedBy", {:tool, "get_reposted_by"}},
    {"app.bsky.feed.getQuotes", {:tool, "get_quotes"}},
    {"app.bsky.feed.getActorLikes", {:tool, "get_actor_likes"}},
    {"app.bsky.feed.searchPosts", {:tool, "search_posts"}},
    {"app.bsky.feed.searchPostsV2", {:todo, @feeds}},
    {"app.bsky.feed.getFeed", {:tool, "get_feed"}},
    {"app.bsky.feed.getListFeed", {:tool, "get_list_feed"}},
    {"app.bsky.feed.getSuggestedFeeds", {:tool, "get_suggested_feeds"}},
    {"app.bsky.feed.getFeedGenerator", {:todo, @feeds}},
    {"app.bsky.feed.getFeedGenerators", {:todo, @feeds}},
    {"app.bsky.feed.getActorFeeds", {:todo, @feeds}},
    {"app.bsky.unspecced.getPopularFeedGenerators", {:todo, @feeds}},
    {"app.bsky.feed.describeFeedGenerator",
     {:left_out, "Asked of a feed generator service by an AppView, not by a client"}},
    {"app.bsky.feed.getFeedSkeleton",
     {:left_out,
      "Asked of a feed generator service by an AppView; `get_feed` reads the hydrated feed"}},
    {"app.bsky.feed.sendInteractions", {:todo, @feeds}},
    {"app.bsky.embed.getEmbedExternalView", {:todo, @posts}},

    # --- Writing posts and interacting with them ---
    {"app.bsky.feed.post", {:tool, "post"}},
    {"app.bsky.feed.like", {:tool, "like"}},
    {"app.bsky.feed.repost", {:tool, "repost"}},
    {"app.bsky.feed.threadgate", {:todo, @posts}},
    {"app.bsky.feed.postgate", {:todo, @posts}},
    {"app.bsky.graph.muteThread", {:todo, @posts}},
    {"app.bsky.graph.unmuteThread", {:todo, @posts}},
    {"app.bsky.bookmark.createBookmark", {:todo, @posts}},
    {"app.bsky.bookmark.deleteBookmark", {:todo, @posts}},
    {"app.bsky.bookmark.getBookmarks", {:todo, @posts}},
    {"app.bsky.draft.createDraft", {:todo, @posts}},
    {"app.bsky.draft.updateDraft", {:todo, @posts}},
    {"app.bsky.draft.deleteDraft", {:todo, @posts}},
    {"app.bsky.draft.getDrafts", {:todo, @posts}},
    {"app.bsky.video.*", {:todo, @video}},

    # --- Accounts and the social graph ---
    {"app.bsky.actor.getProfile", {:tool, "get_profile"}},
    {"app.bsky.actor.getProfiles", {:tool, "get_profiles"}},
    {"app.bsky.actor.searchActors", {:tool, "search_actors"}},
    {"app.bsky.actor.searchActorsTypeahead",
     {:left_out,
      "Prefix search for the app's search box; `search_actors` finds the same accounts"}},
    {"app.bsky.actor.getSuggestions", {:todo, @feeds}},
    {"app.bsky.actor.profile", {:tool, "update_profile"}},
    {"app.bsky.actor.status", {:todo, @feeds}},
    {"app.bsky.actor.link", {:todo, @feeds}},
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
    {"app.bsky.unspecced.getSuggestedStarterPacks", {:todo, @feeds}},
    {"app.bsky.unspecced.getOnboardingSuggestedStarterPacks", {:todo, @feeds}},

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
    {"app.bsky.actor.getPreferences", {:todo, @preferences}},
    {"app.bsky.actor.putPreferences", {:todo, @preferences}},
    {"app.bsky.actor.contentVisibilityDeclaration", {:todo, @preferences}},
    {"app.bsky.notification.declaration", {:todo, @preferences}},
    {"app.bsky.notification.listNotifications", {:tool, "get_notifications"}},
    {"app.bsky.notification.getUnreadCount", {:tool, "get_unread_count"}},
    {"app.bsky.notification.updateSeen", {:tool, "update_seen"}},
    {"app.bsky.notification.getGroupedNotifications", {:todo, @preferences}},
    {"app.bsky.notification.getPreferences", {:todo, @preferences}},
    {"app.bsky.notification.putPreferencesV2", {:todo, @preferences}},
    {"app.bsky.notification.putPreferences",
     {:left_out,
      "The first version of `notification.putPreferencesV2`, which `set_notification_setting` (#91) calls"}},
    {"app.bsky.notification.putActivitySubscription", {:todo, @preferences}},
    {"app.bsky.notification.listActivitySubscriptions", {:todo, @preferences}},
    {"app.bsky.notification.registerPush",
     {:left_out,
      "Registers a phone for push notifications; at_mcp delivers notifications itself (`AtMcp.Notifications`)"}},
    {"app.bsky.notification.unregisterPush",
     {:left_out, "Unregisters a phone from push notifications; at_mcp registers none"}},

    # --- Discovery ---
    {"app.bsky.unspecced.*Skeleton",
     {:left_out,
      "What an AppView asks its search or suggestion service; a client calls the hydrated form"}},
    {"app.bsky.unspecced.getSuggestedFeeds", {:todo, @feeds}},
    {"app.bsky.unspecced.getSuggestedUsers", {:todo, @feeds}},
    {"app.bsky.unspecced.getSuggestedUsersForExplore", {:todo, @feeds}},
    {"app.bsky.unspecced.getSuggestedUsersForDiscover", {:todo, @feeds}},
    {"app.bsky.unspecced.getSuggestedUsersForSeeMore", {:todo, @feeds}},
    {"app.bsky.unspecced.getSuggestedOnboardingUsers", {:todo, @feeds}},
    {"app.bsky.unspecced.getTaggedSuggestions",
     {:left_out,
      "Suggested accounts grouped by interest tag; the current app does not call it, and the suggestion endpoints it does call are in #93"}},
    {"app.bsky.unspecced.getTrends", {:todo, @feeds}},
    {"app.bsky.unspecced.getTrendingTopics", {:todo, @feeds}},
    {"app.bsky.unspecced.getAtmosphereExploreTab", {:todo, @feeds}},
    {"app.bsky.unspecced.getAtmosphereExploreArticleRecommendations", {:todo, @feeds}},
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
    {"com.atproto.repo.applyWrites", {:tool, "create_starter_pack"}},
    {"com.atproto.repo.getRecord", {:todo, 70}},
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
    {"com.atproto.sync.*", {:left_out, "Repository sync, for relays and AppViews"}},
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
    {"town.delve.invitation.getCodes", {:todo, @feeds}},
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
      {"app.bsky.feed.sendInteractions", @delve_501},
      {"app.bsky.unspecced.getTrends", @delve_501},
      {"app.bsky.unspecced.getTrendingTopics", @delve_501},
      {"app.bsky.unspecced.getSuggestedUsers", @delve_501},
      {"app.bsky.unspecced.getSuggestedFeeds", @delve_501},
      {"app.bsky.actor.link", @delve_absent},
      {"app.bsky.notification.getGroupedNotifications", @delve_absent},
      {"app.bsky.unspecced.getAtmosphereExploreTab", @delve_absent},
      {"app.bsky.unspecced.getAtmosphereExploreArticleRecommendations", @delve_absent}
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

  @doc "Whether `pattern` covers `nsid`. `*` stands for any run of characters."
  def covers?(pattern, nsid) do
    regex =
      pattern
      |> String.split("*")
      |> Enum.map_join(".*", &Regex.escape/1)

    Regex.match?(~r/\A#{regex}\z/, nsid)
  end
end
