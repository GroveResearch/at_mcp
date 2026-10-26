# Upgrade notes for older releases

These are the upgrade notes for at_mcp 0.1.3 through 0.2.13, as they were
written when each release came out. Notes for newer releases are in
[Operations](operations.md#upgrade).

## From 0.2.12 to 0.2.13

No stored data changes.

- **`update_seen` with a `seen_at` after now** (#118) is still sent as given,
  and its result carries a `note` saying how far ahead of now it is, since
  notifications that arrive before then will read as seen.

## From 0.2.11 to 0.2.12

No stored data changes. What a client or a delivery receiver reads changes
(#132, #133, #134, #135):

- **A post's `text` marks its mentions and escapes the author's `<`**: after
  each mention facet's span comes the DID it links to, `@alice.test
  <did:plc:…>`, as a link's destination already did, and the author's own `<`
  and backslash are escaped with a backslash. This is the `text` of every read
  and of every incoming event a post makes, so the HTTP bridge's `text`
  changes too. `raw_text` is still the text exactly as written; a receiver
  that matched on `text` should match on `raw_text`.
- **The text a model reads** fences a post's text, each of its lines after
  `> `, and puts every name, quoted text, alt text and card or publication
  title in double quotes, so nothing an author writes reads as AtMcp's own
  line. An identifier (a handle, DID, AT URI, cursor, label value) that holds
  anything an identifier does not is quoted too, and a web address has
  brackets, quotes, blanks and non-ASCII bytes percent-encoded. A refusal's
  text quotes what the service said (`answered 400: "…"`), as it does the
  message of an argument AtMcp refused and the `resolved:` line's link. A post's time is the one the app shows (`indexed_at`), with the
  author's `created_at` beside it as "archived from" when more than a day
  earlier.
- **More escapes in the text a model reads** (#142): inside a quoted name or
  text, quotation marks that look like `"` (`“ ” „ ‟ ″ ‶ ❝ ❞ 〝 〞 〟 ＂`) are
  written as `\uXXXX` escapes, and so is each `#` of a `[[ ##` field marker;
  in a fenced post the marker reads `[[ \#\#`. The control characters FS, GS
  and RS, which some readers take as line breaks, start a new fenced line.
- **New fields**: `indexed_at` on posts and quotes; `viewer.bookmarked`,
  `viewer.pinned` and `known_likers` on posts; `muted_reposts` and
  `muted_quotes` on an account's viewer; `created_at` and `subject_post_uri`
  on notifications; `published_at`, `reading_time`, `publication`, `author`
  and `records` on link cards.

## From 0.2.10 to 0.2.11

0.2.11 stores data in the same format as 0.2.10 and starts from the same
environment, so rolling back works as [Roll back](operations.md#roll-back) says.

- **`like` and `repost` take `cid` as optional** (#51, #125): left out, the
  AppView's CID for the subject is used; a given cid that differs from the
  record's is refused, naming the record's CID.
- **A reference that can't be read says why** (#53, #124): not found (deleted,
  taken down, never existed, or not indexed yet), or the service's own refusal.
  A reply must name a post; a quote may name a post, feed, list, starter pack
  or labeler.
- **The input validator is loaded at start** (#74, #123), so the first checked
  call can't miss its validation deadline (the stdio server runs through
  `eval`, which loads code on demand).

## From 0.2.9 to 0.2.10

0.2.10 stores data in the same format as 0.2.9 and starts from the same
environment, so rolling back works as [Roll back](operations.md#roll-back) says.

- **Moderation** (#90, #121): `report` (to the network's moderation service or
  a labeler the account subscribes to; the service's moderators see the report
  and which account sent it; it cannot be withdrawn), `mute_word` /
  `unmute_word`, `subscribe_labeler` / `unsubscribe_labeler`,
  `set_label_visibility`, `mute_list` / `unmute_list`, `block_list` /
  `unblock_list`, `get_moderation_lists`, `get_labelers`; `get_preferences`
  shows muted words, labelers and label settings. Preferences change as the
  official client does, every other preference kept. On delve.town `report` is
  refused before anything is sent; that was a mistake, since the town runs a
  moderation service (moderation.delve.town), and a later release sends
  reports to it.

## From 0.2.8 to 0.2.9

0.2.9 stores data in the same format as 0.2.8 and starts from the same
environment, so rolling back works as [Roll back](operations.md#roll-back) says.

- **Preferences and notification settings** (#91, #119): `get_preferences`,
  `set_preference` (home feed, threads, interaction defaults, adult content,
  interests, verification badges, discoverability, who may subscribe),
  `get_notification_settings`, `set_notification_setting`,
  `subscribe_to_activity`, `get_activity_subscriptions`; `get_notifications`
  takes `grouped` and `feed`. Preferences are changed as the official client
  does, every other preference written back unchanged; the result gives the
  setting before and after. The birth date is never returned or written.
- **A record written where none was read is guarded.** Profile, live status
  and declaration writes that found no record send a "must not exist" swap, so
  a record another client created meanwhile is refused as `changed_meanwhile`
  instead of overwritten.

## From 0.2.7 to 0.2.8

0.2.8 stores data in the same format as 0.2.7 and starts from the same
environment, so rolling back works as [Roll back](operations.md#roll-back) says. Reads show what the app shows,
the same way through every tool (#116):

- **Profiles read as plain text**, not JSON, in every tool that returns
  accounts; structured content keeps every field. A profile adds pronouns,
  website, links, join date, pinned post, verification, a live status (only
  when the app would show its badge), lists/feeds/starter packs made, whether
  it runs a labeler, the starter pack it joined through, known followers, and
  avatar and banner links. Follow and block record URIs are printed for
  `unfollow` and `unblock`.
- **Posts** carry who may reply (on a thread's first post) and the author's
  verification and live badges; `get_thread_chain` elements carry the post's
  viewer state; quotes carry labels and the relationship with their author.
- **Notifications** carry the author's display name, labels, badges and
  relationship, and the starter pack for starterpack-joined; `get_notifications`
  takes `reasons`, checked against the known values.

## From 0.2.6 to 0.2.7

0.2.7 stores data in the same format as 0.2.6 and starts from the same
environment, so rolling back works as [Roll back](operations.md#roll-back) says. Fixes found by running the write
tools against the reference PDS and AppView (#107, #109):

- **`repost` by a handle-form address** now writes the DID form; before, the
  repost was written and counted nowhere.
- **`update_seen`** keeps milliseconds, so a notification from the same second
  is marked seen; an unparseable `seen_at` is refused instead of becoming now
  (#112).
- **`like`, `repost`, `follow` and `block` write once** (#110). When this account
  already has that record for the subject, confirmed in its own repository, the
  tool returns it as `unchanged` and sends nothing. The undo tools also delete a
  second record of the same kind for the subject when the AppView names one.
- **`reply` refuses a reply the thread's reply rule excludes** (#113), with
  nothing sent; if that rule can't be read, nothing is sent either.
- **A deleted record, list or starter pack reads as `not_found`** (#111), not as
  a malformed request.

## From 0.2.5 to 0.2.6

0.2.6 stores data in the same format as 0.2.5 and starts from the same
environment, so rolling back works as [Roll back](operations.md#roll-back) says. Existing calls mean what they did;
new arguments are optional.

- **Feeds and discovery** (#93, #104): `get_feed_info`, `get_actor_feeds`,
  `search_feeds`, `get_suggested_starter_packs`, `get_trends`, `get_record`,
  `get_invite_codes`. `get_suggested_feeds` takes `source`;
  `get_suggested_follows` no longer needs `actor` and takes `context` and
  `category`. On delve.town, what the town does not serve (trends, some
  suggestion sources) is refused before anything is sent, as `not_served`.
- **`search_posts` uses the newer search.** A call that names neither `sort`
  nor `all_time` still searches every post, newest first, as before;
  `all_time: false` asks for the service's recent window, and the newer
  filters are added.
- **Feeds, profile and status writes** (#93, #105): `save_feed` and
  `unsave_feed` (preferences have no compare-and-swap, which the result says);
  `like` also takes a feed generator or labeler; `update_profile` takes
  `pronouns`, `website` and `links`; `set_status` sets or clears a live status;
  `feed_feedback` sends show-more/show-less to feeds that take it. None count
  against the public write quota.
- **Profile images** (#50): `get_profile` carries the `avatar` and `banner`
  URLs the service hosts, or null.

## From 0.2.4 to 0.2.5

0.2.5 stores data in the same format as 0.2.4 and starts from the same
environment, so rolling back works as [Roll back](operations.md#roll-back) says. Existing tools keep their
arguments; `post` and `get_thread` gain optional ones. New tools bring the app's
remaining post, list and starter pack actions.

- **Pins, thread mutes and bookmarks** (#98): `pin_post`, `unpin_post`,
  `mute_thread`, `unmute_thread`, `bookmark`, `unbookmark`, `get_bookmarks`.
  A post named by a handle-form address is written by the DID form the service
  answers with, since the AppView matches pins, mutes and bookmarks by it.
- **Drafts** (#99): `get_drafts`, `save_draft`, `delete_draft`. A saved draft
  returns the text sent; the service may take a moment to show it.
- **Who may reply and quote** (#100): `post` takes `reply_rule`, `quotes`,
  `labels` (self-labels) and `link` (a link card); `set_post_interactions`, `hide_reply` and
  `detach_quote` change them afterwards, keeping any rule not named.
  `get_thread` marks replies the app leaves out, and with `include_hidden`
  reads them.
- **Lists and starter packs** (#89): `get_list`, `get_lists`,
  `get_starter_pack`, `get_starter_packs`, `create_list`, `update_list`,
  `delete_list`, `add_to_list`, `remove_from_list`, `create_starter_pack`,
  `update_starter_pack`, `delete_starter_pack`, `set_list_opt_out`.
- **Edits don't overwrite a concurrent change.** Every read-modify-write
  (profile, pins, gates, lists) is sent with `swapRecord` or `swapCommit`; if
  the account changed in between, the tool answers `changed_meanwhile` and
  writes nothing. A multi-commit delete that stops partway answers
  `partially_written` with what was deleted.
- None of the new writes count against the public write quota except a post.

## From 0.2.3 to 0.2.4

0.2.4 stores data in the same format as 0.2.3 and starts from the same
environment, so rolling back works as [Roll back](operations.md#roll-back) says. No tool or argument changed.
Reads pass on more of what the service returns; a post without these things
reads exactly as before, except that multi-line image alt text now reads as
one line.

- **Why a post is in a feed** (#85). A repost reads "Reposted by Name
  (@handle) · time" above the post, and a pinned post "Pinned". A reply's
  header names whose post it answers ("replying to @parent (at://…)"), and
  "in a thread by @root" when the thread was started by someone else; a
  deleted or blocked parent says so. Structured content carries `reason`,
  `reply_parent` and `reply_root`.
- **Embeds** (#86). Link cards read `[link: Title — description (url)]`, with
  the description cut to 300 characters in the text; videos read `[video:
  alt]`; gallery images read like other images; quoted feeds, lists, starter
  packs and labelers read with their name, creator and description instead of
  "unsupported". Names, handles and alt text are kept to one line, and
  whitespace in a link's URL is percent-encoded, so no embed can start a line
  of its own.
- **Field coverage** (#84). A test now replays recorded service responses and
  fails when a field reaches a summary unread and unlisted in
  `AtMcp.LeftOut`, where each left-out field gives its reason.

## From 0.2.2 to 0.2.3

0.2.3 stores data in the same format as 0.2.2 and starts from the same
environment, so rolling back works as [Roll back](operations.md#roll-back) says. No tool or argument changed.
Reads now pass on more of what the service returns, so a client reading
results sees more.

- **Post reads** (#71) carry the service's `like_count`, `repost_count`,
  `reply_count` and `quote_count`, and the post's and author's `labels`
  (each `{val, src, neg}`, plus `exp` when set). Profiles carry `labels`. In
  the readable text, a post gains a counts line only when some count is above
  zero (for example `12 likes · 5 replies`), and a labels line naming each
  value once, with `(self)` for a label the author applied to itself.
  Expired and negated labels, and client directives such as
  `!no-unauthenticated`, stay in `structuredContent` but are left out of the
  text. A post with no engagement and no labels reads exactly as in 0.2.2.
- **Block and mute state** (#72). Profiles, and each post's author (as
  `author_viewer`), carry `following`, `followed_by`, `blocking`,
  `blocking_by_list`, `blocked_by`, `muted` and `muted_by_list`. Posts carry
  `reply_disabled`, `embedding_disabled` and `thread_muted`. A state the
  service didn't send stays absent, never `false`. The text adds a line only
  when something is unusual: "They blocked you", "You blocked them", "You
  muted them", "You cannot reply to this post", "You cannot quote this post",
  "You muted this thread". A block made through a list puts the list's URI in
  `blocking`, as the service does; `unblock` refuses it, since only the list
  can undo it.

## From 0.2.1 to 0.2.2

0.2.2 stores data in the same format as 0.2.1, apart from one optional field,
and an environment that started 0.2.1 starts 0.2.2 unchanged. No tool or
argument was removed, and every call that worked on 0.2.1 works on 0.2.2.

**Several agents can share one service (#64).** `at_mcp-accounts delivery NAME
--url … --token-file …` gives an account its own notification destination,
saved as an optional `delivery` field on that account in the accounts file.
Each account's notifications go only to its destination, a destination that is
down holds only its own account's queue, and queued notifications survive a
destination change and a restart. `AT_MCP_DELIVERY_URL` still works as before
for a service with one consumer; combining it with per-account destinations is
refused at start and on reload.

**Rolling back after saving a destination needs one manual step.** 0.2.1
refuses an account with any field it does not know, and once one account has
a destination, 0.2.2 writes `"delivery": null` onto every other account too.
So before starting 0.2.1 again, keep a copy of the accounts file and remove the
`delivery` field from every account in it (it is a private JSON file; edit it
while the service is stopped). A service that never ran `at_mcp-accounts
delivery` has no such field and rolls back as before.

**A token file is checked before it is used.** An empty token file, a missing
one, or one holding more than one line now fails the delivery attempt (it is
retried) with a reason that names neither the token nor the file. In 0.2.1 an
empty file sent no `Authorization` header, and a token with a second line was
refused by the HTTP client with an error that included the token, which was
then logged on every retry. If your logs from 0.2.1 contain a delivery error
quoting `Bearer`, rotate that token.

**What a client sees differently.**

- A call whose arguments don't match a tool's schema is refused as before, and
  the refusal now names each failing argument (`path: message`, up to five)
  and lists them in `structuredContent.problems` (#62).
- Images (`post`, `reply`, `update_profile` avatar and banner) accept the AT
  Protocol spelling `mimeType` as well as `mime_type`. Both are plain optional
  properties in the published schema; an image with neither, or with two
  different types, is refused as `invalid_image` and nothing is sent (#65).
- A call carrying arguments the tool does not define still runs, and its result
  now says which were ignored: a text line, `structuredContent.ignored`, and
  the same `ignored` in the JSON text (#65). In 0.2.1 they were dropped without
  a word, so `post` with `embed` published the text and reported success.

## From 0.2.0 to 0.2.1

0.2.1 stores data in the same format as 0.2.0, and an environment that started
0.2.0 starts 0.2.1 unchanged, so rolling back works as [Roll back](operations.md#roll-back) says. No tool, argument
or setting was removed or made stricter, and every call that worked on 0.2.0
works on 0.2.1. Two things a client reading tool results sees are different.

**What a client reading results sees differently.**

- Reads made of posts (`get_notifications`, `get_timeline`, `get_author_feed`,
  `get_posts`, `search_posts`, `get_quotes`, `get_actor_likes`, `get_feed`,
  `get_list_feed`, `get_thread` and `get_thread_chain`) put readable text in
  `content`: each post as its author, time, what it replies to, its text, its
  images by alt text, any quoted post, and the uri and cid the write tools
  take. In 0.2.0 that text was the result's JSON. `structuredContent` is still
  the whole result, validated against the tool's output schema, so nothing is
  lost there; feed and thread posts also gain `display_name`, `created_at` and
  `reply_to`. A client that parsed the `content` text of these tools as JSON
  must read `structuredContent` instead. Every other tool's text is still its
  JSON.
- In `get_thread`, `replies_omitted` on a post at the read's depth limit, and
  on each parent, now counts the replies that were not read. 0.2.0 said `0`
  there even when the post had replies. A parent's count leaves out the one
  reply the read shows below it. It is `null` when the service gave no count
  (a missing or blocked post), so a client must accept `null` as unknown, which
  the output schema already allowed.

**New tools**, all reads, outside the write quota and reachable with a read
grant:

- `get_post_images` returns a post's pictures as MCP image content, after a
  text block listing each one with its alt text.
- `get_suggested_feeds` pages through the custom feeds the service suggests;
  each item's `uri` is what `get_feed` takes.

**Changed arguments and answers.**

- `search_posts` takes optional `author`, `mentions`, `sort` (`latest` or
  `top`), `since`, `until` and `lang`. A call with only `query` is unchanged.
- `update_profile` takes optional `avatar` and `banner`. Fields the call does
  not mention, an existing avatar or banner included, are kept.
- `get_relationships` resolves handles in `others` before asking the AppView.
  0.2.0 answered `not_found` for every handle there, even for accounts that
  exist.

**New settings**, all optional: `AT_MCP_IMAGE_MAX_BYTES` (2,000,000) and
`AT_MCP_IMAGE_FETCH_SECONDS` (10) for `get_post_images`, and
`AT_MCP_MEDIA_DIR` (unset, so off), a directory from which `post`, `reply` and
`update_profile` may read an image named by `path` instead of base64 `data`.
See [Settings](operations.md#settings).

**Embedding the Hex package.** `{:at_mcp, "~> 0.2.0"}` selects 0.2.1; nothing
to change.

## From 0.1.3 to 0.2.0

0.2.0 stores data in the same format as 0.1.3, so rolling back works as [Roll back](operations.md#roll-back) says.
What changes is how it reads its settings, and some of what it does with them.
The version is 0.2.0 rather than 0.1.4 because an environment that started
0.1.3 can stop 0.2.0 from starting, and because the Hex package changes how an
embedding application configures it (below).

**Check the environment before you restart.** 0.2.0 checks every setting when
it starts and refuses to start, naming the variable, when:

- a variable starting `AT_MCP_` is not one of the settings in the
  [Settings](operations.md#settings) table (a misspelling is told the closest
  setting). 0.1.3 ignored such a variable;
- a value fails its check. `AT_MCP_NOTIFICATIONS` and `AT_MCP_JETSTREAM` take
  only `1`, `true`, `0` or `false`, where 0.1.3 read any other value as the
  default. Ports must be whole numbers from 0 to 65535, counts and intervals
  positive whole numbers, and `AT_MCP_SERVICE`, `AT_MCP_SERVICE_2` and
  `AT_MCP_DELIVERY_URL` `http` or `https` URLs.

An empty value now counts as unset. After unpacking 0.2.0 and before
repointing `current`, run its settings report with the service's environment
file:

```sh
AT_MCP_ENV_FILE=~/at_mcp/at_mcp.env ~/at_mcp/releases/at_mcp-0.2.0/bin/at_mcp eval 'AtMcp.CLI.settings()'
```

On Linux, as the service's user:

```sh
cd / && sudo -u at_mcp env AT_MCP_ENV_FILE=/etc/at_mcp/at_mcp.env /opt/at_mcp/releases/at_mcp-0.2.0/bin/at_mcp eval 'AtMcp.CLI.settings()'
```

It prints every setting, its value and where it came from, or the error that
would stop the service. Do the same for each stdio client's environment (its
MCP configuration, or `AT_MCP_STDIO_ENV_FILE`).

**`BLUESKY_*` account variables are deprecated, not removed.**
`BLUESKY_HANDLE`, `BLUESKY_APP_PASSWORD` and `BLUESKY_SERVICE` (and the `_2`
set) still work, with a warning at startup; the new names are
`AT_MCP_HANDLE`, `AT_MCP_APP_PASSWORD` and `AT_MCP_SERVICE`. When both are set,
the `AT_MCP_*` name wins and the warning says to remove the old one. Rename them
when convenient; nothing else needs to change.

**New settings**, all optional, with defaults that keep 0.1.3's behaviour:
`AT_MCP_WRITE_LIMIT` and `AT_MCP_WRITE_WINDOW_SECONDS` (each account's write
quota, 16 per 3600 seconds), `AT_MCP_INBOUND_MAX_EVENTS` and
`AT_MCP_INBOUND_MAX_BYTES` (the undelivered-activity queue, 10,000 events per
account and 64 MiB in all), `AT_MCP_NOTIFICATIONS_INTERVAL_SECONDS` (60), and
`AT_MCP_APPVIEW_READS` (`proxy`; `direct` is the
[direct authenticated reads](operations.md#direct-authenticated-reads-experimental)
prototype).

**What clients see.**

- `tools/list` offers a connection only the tools its grant's scope allows. A
  read-only grant no longer sees write or delete tools that would have been
  refused with `out_of_scope`. The local stdio server holds no grant and still
  lists every tool.
- The MCP endpoint accepts a post carrying the largest images the network's
  lexicon allows (four of 2,000,000 bytes each). 0.1.3 refused any request
  over 1 MB. Other requests keep the 1 MB limit.
- A service that answers HTTP 501 is reported as `upstream_not_implemented`,
  with no advice to retry.

**Embedding the Hex package.** Change the requirement to
`{:at_mcp, "~> 0.2.0"}`; `~> 0.1.2` does not select 0.2.0. AtMcp's code no
longer reads the process environment, only the application environment
(see [Embed AtMcp](embedding.md)). In particular
`AtMcp.Effects` no longer falls back to `BLUESKY_HANDLE` and
`BLUESKY_APP_PASSWORD` when it is started without `:handle` and `:password`,
and `AT_MCP_STATE_DIR`, `AT_MCP_ACCOUNTS_FILE`, `AT_MCP_DELIVERY_*` and
`AT_MCP_GRANT` set in your application's environment are no longer read; set
`inbound_state_dir`, `accounts_file`, `delivery` and `connect_grant` instead.
AtMcp now requires `proto_rune ~> 0.6.0`.

