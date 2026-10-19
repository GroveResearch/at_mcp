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
    * `{:not_served, evidence}`: the delve.town deployment does not serve it, so
      a tool would only ever refuse there. The evidence is what the service
      answered.
    * `{:left_out, reason}`: not something a person does through the app on
      their own account, or already done by another tool. The reason says
      which.
  """

  @posts 88
  @lists 89
  @moderation 90
  @preferences 91
  @feeds 93

  # Checked 2026-10-18 by calling each method on https://api.delve.town/xrpc.
  @delve_501 "delve.town's AppView answers 501 Method Not Implemented"

  @entries [
    # --- Reading posts, threads and feeds ---
    {"app.bsky.feed.getTimeline", {:tool, "get_timeline"}},
    {"app.bsky.feed.getAuthorFeed", {:tool, "get_author_feed"}},
    {"app.bsky.feed.getPostThread", {:tool, "get_thread"}},
    {"app.bsky.unspecced.getPostThreadV2",
     {:left_out,
      "The app's newer form of the thread `feed.getPostThread` returns; `get_thread` and `get_thread_chain` read that"}},
    {"app.bsky.unspecced.getPostThreadOtherV2", {:todo, @posts}},
    {"app.bsky.feed.getPosts", {:tool, "get_posts"}},
    {"app.bsky.feed.getLikes", {:tool, "get_likes"}},
    {"app.bsky.feed.getRepostedBy", {:tool, "get_reposted_by"}},
    {"app.bsky.feed.getQuotes", {:tool, "get_quotes"}},
    {"app.bsky.feed.getActorLikes", {:tool, "get_actor_likes"}},
    {"app.bsky.feed.searchPosts", {:tool, "search_posts"}},
    {"app.bsky.feed.searchPostsV2",
     {:left_out, "A second version of `feed.searchPosts`, which `search_posts` calls"}},
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
    {"app.bsky.feed.sendInteractions", {:not_served, @delve_501}},
    {"app.bsky.embed.getEmbedExternalView",
     {:left_out,
      "Builds a link card's view from a URL; the app does not call it, and `post`'s `link` argument (#88) takes the card from the agent"}},

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
    {"app.bsky.video.*",
     {:not_served,
      "#{@delve_501}; Bluesky serves video upload from a separate service (video.bsky.app)"}},

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
    {"app.bsky.actor.link",
     {:not_served, "Not in delve.town's lexicons; profile links are new in Bluesky's app"}},
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
    {"app.bsky.graph.getList", {:todo, @lists}},
    {"app.bsky.graph.getLists", {:todo, @lists}},
    {"app.bsky.graph.getListsWithMembership", {:todo, @lists}},
    {"app.bsky.graph.list", {:todo, @lists}},
    {"app.bsky.graph.listitem", {:todo, @lists}},
    {"app.bsky.graph.referencelistoptout", {:todo, @lists}},
    {"app.bsky.graph.getStarterPack", {:todo, @lists}},
    {"app.bsky.graph.getStarterPacks",
     {:left_out,
      "Several starter packs by URI, for hydrating links; `get_starter_pack` (#89) reads one"}},
    {"app.bsky.graph.getActorStarterPacks", {:todo, @lists}},
    {"app.bsky.graph.getStarterPacksWithMembership", {:todo, @lists}},
    {"app.bsky.graph.searchStarterPacks",
     {:left_out,
      "The first version of `graph.searchStarterPacksV2`, which `get_starter_packs` (#89) calls"}},
    {"app.bsky.graph.searchStarterPacksV2", {:todo, @lists}},
    {"app.bsky.graph.starterpack", {:todo, @lists}},
    {"app.bsky.unspecced.getSuggestedStarterPacks", {:todo, @feeds}},
    {"app.bsky.unspecced.getOnboardingSuggestedStarterPacks",
     {:left_out,
      "Starter packs for a new account's first run; `get_suggested_starter_packs` (#93) reads suggestions"}},

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
    {"app.bsky.notification.getGroupedNotifications",
     {:left_out,
      "Groups the notifications `get_notifications` reads; delve.town does not serve it (absent from its lexicons, 501)"}},
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
    {"app.bsky.unspecced.getSuggestedFeeds",
     {:not_served, "#{@delve_501}; `get_suggested_feeds` reads `feed.getSuggestedFeeds`"}},
    {"app.bsky.unspecced.getSuggestedUsers", {:not_served, @delve_501}},
    {"app.bsky.unspecced.getSuggestedUsersForDiscover",
     {:left_out,
      "A variant of account suggestions for one screen of the app; `get_suggested_follows` (#93) reads suggestions"}},
    {"app.bsky.unspecced.getSuggestedUsersForExplore",
     {:left_out,
      "A variant of account suggestions for one screen of the app; `get_suggested_follows` (#93) reads suggestions"}},
    {"app.bsky.unspecced.getSuggestedUsersForSeeMore",
     {:left_out,
      "A variant of account suggestions for one screen of the app; `get_suggested_follows` (#93) reads suggestions"}},
    {"app.bsky.unspecced.getSuggestedOnboardingUsers",
     {:left_out,
      "Suggestions for a new account's first run; `get_suggested_follows` (#93) reads suggestions"}},
    {"app.bsky.unspecced.getTaggedSuggestions",
     {:left_out,
      "Suggestions grouped by the app's interest tags, an older form of the same suggestions"}},
    {"app.bsky.unspecced.getTrends", {:not_served, @delve_501}},
    {"app.bsky.unspecced.getTrendingTopics", {:not_served, @delve_501}},
    {"app.bsky.unspecced.getAtmosphereExploreTab",
     {:not_served, "Not in delve.town's lexicons; new in Bluesky's app"}},
    {"app.bsky.unspecced.getAtmosphereExploreArticleRecommendations",
     {:not_served, "Not in delve.town's lexicons; new in Bluesky's app"}},
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
    {"chat.bsky.convo.*",
     {:not_served,
      "#{@delve_501}, and its DID document names no chat service; Bluesky serves chat from api.bsky.chat. Tools are designed in #92"}},
    {"chat.bsky.group.*",
     {:not_served, "#{@delve_501}; group chats are part of the design in #92"}},
    {"chat.bsky.notification.*",
     {:not_served, "#{@delve_501}; chat notification settings are part of the design in #92"}},
    {"chat.bsky.actor.getStatus", {:not_served, "#{@delve_501}; part of the design in #92"}},
    {"chat.bsky.actor.declaration",
     {:not_served,
      "Who may message this account, read by a chat service; delve.town runs none. Part of the design in #92"}},
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
    {"com.atproto.repo.applyWrites", {:todo, @posts}},
    {"com.atproto.repo.getRecord", {:todo, 70}},
    {"com.atproto.repo.listRecords",
     {:left_out,
      "Lists a repository's raw records; the app reads views, and `get_record` (#70) reads one record"}},
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
      "Joining accepts delve.town's terms, so the person responsible for the account does it at delve.town"}},
    {"town.delve.membership.withdraw",
     {:left_out,
      "Withdrawing ends the account's membership, a decision for the person responsible for it"}},
    {"town.delve.invitation.getCodes",
     {:left_out, "Invitation codes are handed out by the person responsible for the account"}},
    {"town.delve.admin.*", {:left_out, "The town operator's administration API"}},

    # --- Other applications' records that Bluesky's AppView reads ---
    {"com.germnetwork.*",
     {:left_out,
      "Another application's record; the AppView shows it on profiles, and #79 covers what reads drop"}},
    {"place.stream.*", {:left_out, "Another application's records (live streaming)"}},
    {"site.standard.*", {:left_out, "Another application's records (long-form publishing)"}},
    {"social.grain.*", {:left_out, "Another application's records (photo galleries)"}}
  ]

  @doc "Every entry, in order: `{pattern, outcome}`."
  def entries, do: @entries

  @doc "Whether `pattern` covers `nsid`. `*` stands for any run of characters."
  def covers?(pattern, nsid) do
    regex =
      pattern
      |> String.split("*")
      |> Enum.map_join(".*", &Regex.escape/1)

    Regex.match?(~r/\A#{regex}\z/, nsid)
  end
end
