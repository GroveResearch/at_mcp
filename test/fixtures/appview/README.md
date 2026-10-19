# Recorded AppView responses

Read by `test/at_mcp/field_coverage_test.exs`. Each file is a public,
unauthenticated response from the Bluesky AppView (`public.api.bsky.app`),
recorded by `scripts/record_appview_fixtures.py`:

- `feed.json`: `app.bsky.feed.getAuthorFeed` of @bsky.app with pins and
  replies. These are the fewest of 100 items that together carry every field
  path: reposts, a pin, replies with their parents, images, video, link cards,
  quotes, quotes with media, and a quoted starter pack.
- `thread.json`: `app.bsky.feed.getPostThread` of a post with a threadgate.
- `profile.json`, `likes.json`, `feeds.json`: `getProfile`, `getLikes` and
  `getSuggestedFeeds`.

Identities, text and URLs are replaced; keys and value types are not. Text
keeps its byte length, so facet ranges still fall inside it. Public responses
carry no `viewer` state, and notifications need an account, so neither is
covered here yet.

Re-record when the lexicon grows:

    python3 scripts/record_appview_fixtures.py test/fixtures/appview
