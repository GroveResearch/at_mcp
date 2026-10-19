# Recorded AppView responses

Read by `test/at_mcp/field_coverage_test.exs`. Each file is a public,
unauthenticated response from the Bluesky AppView (`public.api.bsky.app`),
recorded by `scripts/record_appview_fixtures.py` from one public account and
one of its posts that has a threadgate:

- `feed.json`: `app.bsky.feed.getAuthorFeed` with pins and replies. These are
  the fewest of 100 items that together carry every field path: reposts, a pin,
  replies with their parents, images, video, link cards, quotes, quotes with
  media, and a quoted starter pack.
- `thread.json`: `app.bsky.feed.getPostThread` of the threadgated post.
- `profile.json`, `likes.json`, `feeds.json`: `getProfile`, `getLikes` and
  `getSuggestedFeeds`.

Every string is replaced except lexicon enumerations and type names: DIDs,
record keys, CIDs, handles, URLs and text by salted same-shape stand-ins, and
timestamps by one random shift. Integers are replaced too, except facet byte
offsets. Keys and value types are kept. Which account and post they came from
is deliberately not recorded.

Public responses carry no `viewer` state, and notifications need an account,
so neither is covered here yet. Re-record when the lexicon grows:

    python3 scripts/record_appview_fixtures.py test/fixtures/appview ACTOR GATED_POST_URI
