# Recorded AppView responses

Read by `test/at_mcp/field_coverage_test.exs`. Each file but the `viewer_`
and notification ones (below) is a public,
unauthenticated response from the Bluesky AppView (`public.api.bsky.app`),
recorded by `scripts/record_appview_fixtures.py` from one public account and
one of its posts that has a threadgate:

- `feed.json`: `app.bsky.feed.getAuthorFeed` with pins and replies. These are
  the fewest of 100 items that together carry every field path: reposts, a pin,
  replies with their parents, images, video, link cards, quotes, quotes with
  media, and a quoted starter pack.
- `thread_v2.json`: `app.bsky.unspecced.getPostThreadV2` of a post, as the
  app asks for it by default (`sort: top`, `below: 10`, `branchingFactor:
  1`). The one here was recorded from a busy public thread instead (29 items,
  replies four levels down), with `--scrub`, which keeps each item's `depth`.
- `profile.json`, `likes.json`, `feeds.json`: `getProfile`, `getLikes` and
  `getSuggestedFeeds`.

Lists and starter packs are recorded the same way with `--lists QUERY`: a
search for starter packs (`starter_packs.json`, `graph.searchStarterPacksV2`),
the one among them recommending the most feeds (`starter_pack.json`), its
creator's packs (`actor_starter_packs.json`, `graph.getActorStarterPacks`),
its list with a few members (`list.json`, `graph.getList`), and one creator's
curation lists (`lists.json`, `graph.getLists`). The query is not recorded.
The reads that need an account (`getListsWithMembership`,
`getStarterPacksWithMembership`) return the same views and are not recorded.

What the app's Explore page reads is recorded with `--discovery`: one feed the
newer suggestion service suggests, as `feed.getFeedGenerator` describes it
(`feed_generator.json`), `unspecced.getTrends` (`trends.json`),
`unspecced.getTrendingTopics` (`trending_topics.json`) and
`unspecced.getSuggestedStarterPacks` (`suggested_starter_packs.json`), each
cut to the fewest items that carry every field path.

Every string is replaced except lexicon enumerations and type names: DIDs,
record keys, CIDs, handles, URLs and text by salted same-shape stand-ins, and
timestamps by one random shift. Integers are replaced too, except facet byte
offsets and a thread item's depth. Keys and value types are kept. Which account and post they came from
is deliberately not recorded.

Public responses carry no `viewer` state, and notifications need an account,
so those are recorded from the end-to-end suite's local network instead
(test/e2e, "bookmark and pin_post read back as this account's"): an account
that follows and is followed by another, has pinned a post and bookmarked,
liked and been mentioned, replied to, quoted, liked and reposted reads
`feed.getTimeline` (`viewer_timeline.json`), `feed.getAuthorFeed` with pins
(`viewer_author_feed.json`), `unspecced.getPostThreadV2` of its post
(`viewer_thread.json`: not in the repository yet. The next `AT_MCP_E2E_RECORD`
run records it with `getPostThreadV2`), `notification.listNotifications`
(`notifications.json`) and `notification.getGroupedNotifications`
(`grouped_notifications.json`). The suite writes them raw when
`AT_MCP_E2E_RECORD` names a directory, and `--scrub` replaces what they say
as above. The network's feature gates are off, so no post view carries
`viewer.knownLikers`.

Re-record when the lexicon grows:

    python3 scripts/record_appview_fixtures.py test/fixtures/appview ACTOR GATED_POST_URI
    python3 scripts/record_appview_fixtures.py test/fixtures/appview --lists QUERY
    python3 scripts/record_appview_fixtures.py test/fixtures/appview --discovery
    AT_MCP_E2E_RECORD=RAW_DIR scripts/e2e.sh test/e2e/round_trip_test.exs
    python3 scripts/record_appview_fixtures.py test/fixtures/appview --scrub RAW_DIR
