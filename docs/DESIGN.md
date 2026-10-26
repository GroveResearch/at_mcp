# Design

at_mcp gives locally run agents their own persistent AT Protocol identity. It
owns credentials, sessions, account policy and durable delivery of incoming
activity. MCP exposes the tools to agent clients; an Elixir application can use
the same account implementation directly. The dated record of each decision,
with the test that holds it, is [decisions.md](../decisions.md). A glossary of
the terms used here is at the end.

## Parts and ownership

The application supervisor starts two registries, the inbound store, the write quota,
the shared `AtMcp.Inbound` stream collector, the `AtMcp.Identities`
DynamicSupervisor and the `AtMcp.Accounts` lifecycle coordinator. Each
`AtMcp.Identity` owns its Effects session, its notification poller and an
optional stream registration. One MCP HTTP listener is shared across
identities, and `start_mcp: false` is what keeps the single-account stdio
launcher from binding one at all; `AtMcp.Control` is a separate operator
listener, started only when a control port is configured.

`AtMcp.Effects` is the one process that owns an account. It holds the session,
verifies identity, reserves writes and recovers sessions, and it runs every
call on the account in a task it owns, under the call's deadline: writes one at
a time in the order they arrive, reads alongside them, and at most one login or
refresh at a time. The work stops when the owner stops. `AtMcp.Effects.ProtoRune`
is the backend behind it.
`AtMcp.Summary` declares each record shape once: the backend builds summaries
with it and `AtMcp.MCP.Server` derives its output schemas from it, so a tool
cannot describe a field it does not return. `AtMcp.AccountConfig` owns the
private accounts file and `AtMcp.Accounts` reconciles it with supervised
processes and the durable record of which accounts are disconnected.

| Layer | Owns | Does not own |
| --- | --- | --- |
| ProtoRune | AT Protocol sessions and XRPC transport | The records AtMcp writes, or the namespace it writes them to |
| AtMcp | Account configuration, readiness, tools, write quota, collection and delivery | Agent turns or conversational instructions |
| MCP | The client's tool connection to AtMcp | The agent's execution lifecycle |
| Consumer | Routing, queues, conversations, mediated permissions | Account passwords or tool implementation |
| Agent | Tool selection under its instructions | AtMcp's durable account state |

ACP is the host-to-agent connection; MCP is the agent-to-tool connection. An
independent MCP client needs neither ACP nor a consumer.

## Accounts and identities

An account is identified by its DID; a local name such as `personal` selects
its saved configuration in the accounts file. Login uses an app password; there is no
OAuth. Saved accounts retain the expected DID, and login, refresh and
replacement sessions must match it before the account is ready.

Login and runtime transitions run as supervised operations that report back
with an operation reference. Disconnect and configuration changes invalidate
the affected operations across every known alias of the DID, and discovery of
another alias checks the policy generation before binding it, so a late login
cannot undo a newer disconnect. A concurrent replacement or disconnect cancels a
pending start, reconnect or reload with `account_runtime_unavailable`, and the
newer configuration or disconnect stays in force.

Disconnect is persisted and stops tool calls and collection; reconnect is
explicit. Reload validates the whole plan first and replaces only affected
owners; stale credentials never become the fallback.

`at_mcp-stdio` owns a single-account runtime and stops on EOF. `at_mcp-connect` is a
stdio front onto the shared service: it owns a client connection, not an
account session, so HTTP and stdio clients on one account share the session,
the write quota and disconnect control.

## Grants and scopes

One endpoint serves every identity, and `Authorization: Bearer <grant>` decides
which one a client acts as. A grant names one account and one scope. A request
with no grant is refused with `401`: a mode in which an uncredentialed caller is
served is the mode in which nothing is separated. `x-at-mcp-account-did`
confirms the binding and selects nothing. Revocation is removing the grant, and
takes effect on the next request.

`AtMcp.Grants` alone answers which identity a request acts as and how much of the
surface it may reach; `AtMcp.MCP.HTTP` resolves, and nothing else reads the
grants file. Grants live in `accounts.grants.json` beside the accounts file,
which holds a SHA-256 digest of each token and never the token itself.

The three scopes are ordered, and each is derived from what the tools declare
about themselves rather than from a verb list kept in step by hand:

- `read` — every tool whose `readOnlyHint` is true.
- `write` — those, plus tools that write without destroying anything.
- `manage` — those, plus every tool whose `destructiveHint` is true.

A tool AtMcp does not declare is permitted by no scope, so a renamed tool fails
closed instead of inheriting its last classification.

A grant is a bearer token on loopback, unbound to the holding process; it
separates what each client was given, not what each process could obtain. It is
not a sandbox. Bearer is kept as the shape so an issuer-signed token can arrive
later without a client changing. The host's permission decision and the
account's write quota answer different questions: whether an action is approved,
and whether the account has capacity left.

## The MCP tool surface

`AtMcp.MCP.Server` declares 82 tools: 81 network verbs, plus
`identity_status`. Handlers call `AtMcp.Effects` and never reimplement account
policy. Every tool declares an output schema derived from `AtMcp.Summary` and
returns its summary as structured content beside a text block for the model.
The text is the summary's JSON, except for reads made of posts (notifications,
feeds, searches, bookmarks, `get_posts`, `get_thread`, `get_thread_chain`), where it is
`AtMcp.Reading`'s text: each post's author, time, what it replies to, its
text, attachments, the like, repost, reply and quote counts and the post's and
author's labels when the service sent them, and the uri and cid the write tools
take, with no `null`s and none of the fields only a program uses. Lists and
starter packs read the same way (`get_list`, `get_lists`, `get_starter_pack`,
`get_starter_packs`): a list's name, kind, size and maker, then its accounts,
each with the list item record that puts it there. So do accounts
(`get_profile`, and the pages of them: followers, follows, searches,
suggestions, blocks, mutes, likers and reposters): the name with the badges
the app puts beside it (verified, trusted verifier, live), how the account
relates to this one, the description, counts, links, pinned post and what the
account has made. A post is one view whichever read shows it: a feed, a
thread, a chain, a notification and a quote each say its author's badges,
labels and any block or mute with its author in the same words, and a gated
post says who may reply. Its time is the one the app shows, when the service
first saw it (`indexed_at`), with the author's own `created_at` beside it as
"archived from" when that is more than a day earlier (the app marks such a
backdated post on a thread's main post; here every read says it). A mention
facet reads with the DID it links to, `@alice.test <did:plc:…>`, so it is
told apart from an `@word` with no facet. A link card built from
standard.site records names its publication, the author the app names on it,
the publish date and the reading time. What someone else wrote cannot read
as AtMcp's own words: a post's text is fenced, each of its lines after `> `,
and every other string an author or another account controls (names, quoted
text, alt text, card and publication titles, descriptions) is one quoted
literal on one line, `"` and backslash escaped; an identifier is bare only
when it is nothing but an identifier's characters, and a web address is
percent-encoded so it cannot close a bracket. `AtMcp.Reading` builds its text
only from `AtMcp.Reading.Text` pieces, which only those renderers make; a raw
string given to its joiners fails under test and is quoted elsewhere. Most MCP clients give a model
`content` and validate `structuredContent` against the output schema; the
specification's own examples pair readable text with structured results,
while its text asks for the serialized JSON for older clients
(`decisions.md`).

Each tool's `readOnlyHint` and `destructiveHint` annotations are the only
definition of what a scope reaches. Every write tool also carries
`"at_mcp/publicWrite"`, true for the three that count against the write quota
(`post`, `reply`, `repost`) and false for every other write, and its
description ends with the matching sentence. Both derive from
`AtMcp.Effects.publishing/0`, the list the reservation reads, so a host
counting an account's publishing reads the same classification AtMcp enforces.

| Category | Tools |
| --- | --- |
| Writing | `post`, `reply`, `delete_post`, `update_profile`, `set_status` |
| Reading | `get_timeline`, `get_author_feed`, `get_thread`, `get_thread_chain`, `get_posts`, `get_post_images`, `get_profile`, `get_profiles`, `search_posts`, `search_actors`, `get_feed`, `get_list_feed`, `get_actor_likes`, `get_record` |
| Discovery | `save_feed`, `unsave_feed`, and the reads `get_suggested_feeds`, `get_feed_info`, `get_actor_feeds`, `search_feeds`, `get_suggested_starter_packs`, `get_trends`, `get_invite_codes` (delve.town) |
| Reacting | `like` (a post, a feed or a labeler), `unlike`, `repost`, `unrepost`, `feed_feedback`, and the reads `get_likes`, `get_reposted_by`, `get_quotes` |
| Graph | `follow`, `unfollow`, `block`, `unblock`, `mute`, `unmute`, and the reads `get_followers`, `get_follows`, `get_known_followers`, `get_relationships`, `get_blocks`, `get_mutes`, `get_suggested_follows` |
| Lists | `create_list`, `update_list`, `delete_list`, `add_to_list`, `remove_from_list`, `create_starter_pack`, `update_starter_pack`, `delete_starter_pack`, `set_list_opt_out`, and the reads `get_list`, `get_lists`, `get_starter_pack`, `get_starter_packs` |
| Notifications | `get_notifications` (one at a time, or `grouped` as the app shows them), `get_unread_count`, `update_seen`, `subscribe_to_activity`, and the reads `get_activity_subscriptions`, `get_notification_settings` |
| Settings | `set_preference`, `set_notification_setting`, and the read `get_preferences` |
| Moderation | `report`, `mute_word`, `unmute_word`, `mute_list`, `unmute_list`, `block_list`, `unblock_list`, `subscribe_labeler`, `unsubscribe_labeler`, `set_label_visibility`, and the reads `get_moderation_lists`, `get_labelers` |
| Account | `identity_status` |

`search_posts` calls `feed.searchPostsV2`, the version the app calls. It takes
a query string, filters, or both: `author`, `mentions`, `sort` (`latest` or
`top`, sent as `recent` or `top`), `since`, `until` and `lang` as before, and
`all_time`. A call that gives neither `sort` nor `all_time` is sent as
`sort=recent&allTime=true`, which is what the first version's lexicon default
and handler gave it (V2 alone defaults to `top` over a recent window), so an
existing call means what it did. It also takes
the filters the first version lacked, each sent under the lexicon's own name
(a list as a repeated key). A leading `@` on a handle is stripped the way it is
on every other actor argument, and a post named by a handle-form AT URI is
searched for by its DID form. A sort that is not `latest` or `top`, or a call
with neither a query nor a filter, is refused before a session is taken.

A read that a deployment is known not to serve (`AtMcp.Endpoints.deployments/0`:
on delve.town, trends and two of the suggestion methods) is refused with
`not_served` before anything is sent, naming the method and the evidence.

`post` and `reply` take `images` (base64 bytes or a file path, a MIME type and
alt text, uploaded as blobs before the record is built), `quote` (an AT URI, whose CID
AtMcp reads off the record it names) and `langs`. A post with both images and a
quote becomes one `embed.recordWithMedia`. A post whose author said nothing
about its language carries no `langs` at all rather than a default `["en"]`.

`update_profile` takes `avatar` and `banner` in the same shape, without alt
text. Each is uploaded as a blob and set on the profile record, which is read
first so the fields the call does not mention are kept; the result carries each
uploaded blob's CID. It also takes `pronouns`, `website` (https only, the only
kind the AppView shows) and `links`, the links the profile shows in order.
Links are `actor.link` records that the profile names by strong reference, as
the app writes them: a link given as the profile already shows it keeps its
record, a new one is written first so the profile can name its CID, the
profile is written over the version read (`swapRecord`), and the records it no
longer names are deleted after. A profile the service refuses as changed
meanwhile leaves no new record behind.

`save_feed` and `unsave_feed` edit the `savedFeedsPrefV2` preference the way
the app's own library does, keeping every other preference byte for byte (the
preferences are read and written as raw JSON, not through the XRPC client's
key renaming). `actor.putPreferences` has no compare-and-swap, so a change
another client makes between the read and the write is lost; the description
and the result say so. `set_preference` changes one kind of the account's settings
(`AtMcp.Preferences`) the same way: the preference the app's library reads
(the last valid one of its type) is changed, every other of that type
dropped, and every other preference kept as stored; the two that are records
(`actor.contentVisibilityDeclaration`, `notification.declaration`) are
written over the version read (`swapRecord`). A setting already as asked
writes nothing, and the result names what changed with the setting before
and after, which the same tool takes to undo it. Settings the app ignores
(`hideRepliesByUnfollowed`) or keeps about itself (its nudges, beta opt-in,
live-event banners) are left out, the birth date is never written or read
out, and adult content is turned on only for an account whose declared age
the app would show it to. `set_notification_setting` sends one reason's
setting with `notification.putPreferencesV2` and reports what the service
answered it keeps; chat's settings belong to the chat service.
`subscribe_to_activity` reads the account first and refuses a subscription
its `notification.declaration` does not allow, as the app offers no bell for
it. `set_status` writes or deletes the `actor.status` record over the
one read and refuses a duration outside the 5 to 240 minutes the AppView
shows. `feed_feedback` reads the feed first and sends `feed.sendInteractions`
to the feed generator's own service (`atproto-proxy: <did>#bsky_fg`), as the
app does, only when the feed takes feedback.

An image `path` is read by the server, so a model need not copy the bytes as
base64, which it can get wrong partway through. It is off unless
`AT_MCP_MEDIA_DIR` names a directory, and then reads only regular files inside
it (`AtMcp.MediaFile`).

The two thread reads answer different questions. `get_thread` is what is
*around* a post: two levels of parents and two of replies, nested, with what it
left out reported. `get_thread_chain` is what was said *before* a post: every
ancestor from the thread root down to it, flat and in order, plus the replies
directly underneath, each element carrying its author, its time, whether this
account wrote it, and where its links and mentions point. A chain that cannot
reach the root names in its first element the uri where reading stopped and
sets `chain_truncated`; a conversation taller than one chain carries keeps the
elements nearest the requested post and counts the rest in `chain_omitted`.
A chain cut by that cap names in `chain_before` the uri to read from next, and
passing it back as `before` returns the page above it, so a conversation of any
height is readable upward without repeating or skipping a post. `chain_before`
is null wherever the next uri would be one the page already holds — at the
root, at a head that could not be read, and at a walk that turned back on
itself — so null means nowhere to resume, and `chain_truncated` is what says
whether anything is missing. The caps are module attributes, not numbers in a
tool description that go stale when they move.

Post and chain summaries preserve `raw_text` exactly; `text` writes each
link's destination and each mention facet's DID after its span as `<…>`,
with the author's own `<` and backslash escaped so that only those markers
are unescaped; and `facets` are exposed normalized. `web_url` is the post's web link on
the configured network; AT URIs remain the canonical tool references. Both carry
`images` (alt text and available thumbnail/full-size URLs, a gallery's
included), a `link` card (destination, title, description, image URL), a
`video` (alt text, thumbnail and playlist URLs) and one attributed `quote`.
Image `availability` distinguishes hydrated URLs from raw references; no blob
URLs are guessed, so a raw record's card image and video URLs are null. Quote
`status` distinguishes available content, not-found, blocked, detached,
unhydrated and unsupported records, and an available quote's `kind` says
whether it is a post (with its author, text, images, link card and video) or
a feed, list, starter pack or labeler (with its name, description and
creator). A further quote stays a `nested_uri` rather than recursively
expanding. `embed_type` identifies the embed's kind, including kinds this
projection does not interpret.

Every post, account, list, feed, starter pack and labeler a read shows carries
`web_url`, the link a person opens and shares, built as the app's share actions
build it (`AtMcp.WebLink`), and its text reads `link:` beside the uri. The way
back holds too: wherever a tool takes an AT URI, handle or DID, it takes the web
link instead (`AtMcp.MCP.WebLinks`), reads it as the record's AT URI or the
account's DID, its handle resolved, and says so in `resolved`. A link to the
wrong kind of thing, or to another network, is refused before anything is sent.

A feed (timeline, author feed, custom feed, list feed, likes) wraps each post
with what the app shows above it. `reason` says why the post is there: a
repost, with who reposted it, when, and the repost record's uri, or a pin.
`reply_parent` and `reply_root` say whose post a reply answers and whose
thread it is in, with a status when the feed reports that post deleted or
blocked. They are null outside feeds, where the service does not send them;
`reply_to` is the parent's uri everywhere.

These are read projections of what the server already returned, not extra
requests or image pixels. `get_post_images` is the one read that fetches
pictures, for one post at a time: it takes the `fullsize` URLs from that post's
hydrated view and returns them as MCP image content after a text block that
lists every image by index. Putting pictures in every page read would make each
one many megabytes for images most readers never look at. Raw notifications and stream records preserve full
facet URLs and references; when they lack hydrated content they say so.

Summaries also keep the viewer's like, repost, follow and block record URIs so
an agent can undo without the original receipt; a missing viewer object is
distinct from an empty one. Beside those records they keep the states the
service reports with no record of the account's behind them: whether the other
account blocks this one (`blocked_by`), whether this one has muted it
(`muted`), the list a block or mute comes through, and whether the service lets
the account reply to or quote a post (`reply_disabled`, `embedding_disabled`) and
whether it muted the post's thread (`thread_muted`), bookmarked the post
(`bookmarked`) or pinned it to its profile (`pinned`); a post also carries
the accounts this one follows that liked it (`known_likers`), the app's
"Liked by" line. A post carries its author's as
`author_viewer`, so a reader of a post sees a block without a second read. A
state the service did not mention is left out, never reported as `false`.
Blocked only through a moderation list, the AppView puts the list's own URI in
`blocking` as well as in `blocking_by_list`; that is not a block record, and
`unblock` refuses it as the wrong record kind.

`identity_status` corresponds to nothing a person does: a person has no write
quota to read. It exists because an agent acts faster than a person while the
account outlives the run. There is no tool for declining to act; an agent that
ends its turn without calling a write tool has not posted.

An account makes curation and moderation lists and starter packs, and puts
accounts on them or takes them off. None of these counts against the write
quota: a list's name and description are public, like a profile's, but they
are not put in front of followers. An edit reads the record first and keeps
every field it does not change, and is written only if the record is still
the one read (`swapRecord`); a write built from several reads names the
repository's commit from before them (`swapCommit`). A refused swap is
`changed_meanwhile`: nothing was written. A starter pack is its list, the list's items
and the pack record, written in one `applyWrites`, and deleted the same way;
`delete_list` deletes a list's items with it. `remove_from_list` finds the
list items by reading the account's own `graph.listitem` records, so it
needs no record key. `set_list_opt_out` asks to be left out of someone else's
starter pack. A list or pack in another account's repository, or a uri of
the wrong kind, is refused before anything is sent, naming the argument.

An account pins one of its posts to its profile (`pin_post`, `unpin_post`),
mutes a thread by any post in it (`mute_thread`, `unmute_thread`), and keeps
private bookmarks (`bookmark`, `unbookmark`, `get_bookmarks`). None of these
counts against the write quota. A pin rewrites the profile record from the one
it reads, so every other field survives it, and writes only over that record
(`swapRecord`): a profile changed meanwhile is refused as `changed_meanwhile`,
with nothing written. A post named by a handle-form address is pinned, muted
and bookmarked by the DID-form address the service answers, which is the one
the AppView matches. A tool that takes one of the
account's own posts refuses another account's before anything is sent, naming
the argument; a service that does not serve a method answers 501, which is
reported as `upstream_not_implemented` and not as an unknown outcome.

Drafts (`get_drafts`, `save_draft`, `delete_draft`) are private and publish
nothing, so they do not count either. A draft's text may be longer than a
post's (`app.bsky.draft.defs#draftPost`). Saving to an existing draft reads it
first and replaces only its first post's text, keeping the rest; an id the
account does not have is refused, because the service would ignore the update
without saying so. `delete_draft` returns the draft it deleted.

A post can say who may reply to it (`reply_rule`: everyone, nobody, people
it mentions, people the account follows, its followers, or a list's members)
and whether it may be quoted (`quotes`). Those are a `feed.threadgate` and a
`feed.postgate` under the post's record key, and `post` writes them with the
post in one `applyWrites` commit, so the post never exists without them; it
counts once. `set_post_interactions` changes them later, as the app's dialog
does, starting from the current settings: a rule not given is kept, and the
result states both rules now in force. Who may reply belongs to a thread's
first post, so `reply` does not take `reply_rule`. A list rule is written with
the list's DID-form address, which is what the AppView matches; a handle-form
address is resolved first. `hide_reply` and `detach_quote` are separate tools
because each is a choice about someone else's post. Each edit reads the
repository's latest commit, then the gate it changes, keeps the rest, and
writes over that commit only (`swapCommit`): a repository changed meanwhile is
refused as `changed_meanwhile` with nothing written. An edit that changes
nothing writes nothing and says `unchanged`; a gate left saying nothing is
deleted. A post can carry self-labels (`labels`) and a link card (`link`)
whose title and description the agent gives: at_mcp does not fetch the page.
`feed.getPostThread` returns replies the thread's author hid among the others;
`get_thread` marks those the response's threadgate lists. With
`include_hidden` it also reads the replies the app leaves out
(`unspecced.getPostThreadOtherV2`): one the thread read already returned is
marked where it stands, saying whether its author hid it or the account muted
its writer, and only the rest are listed after the thread. If that read fails,
the thread is returned with a line saying why.

The moderation tools do what the app's moderation settings and Report menu
do (`AtMcp.Moderation`). `report` sends `com.atproto.moderation.createReport`
through the account's PDS to a moderation service's labeler endpoint
(`atproto-proxy: <did>#atproto_labeler`), as the app sends it: to the
network's own service unless another the account subscribes to is named, and
only after reading that the service takes reports on this kind of subject,
record type and reason; the result names the report's id and the service.
A report reaches the people who run that service and cannot be withdrawn.
On delve.town the network's own service is the town's moderation service
(moderation.delve.town), read through `town.delve.labeler.getServices`.
Muted words, labeler subscriptions and label settings are preferences,
changed as `@atproto/api`'s `addMutedWord`, `updateMutedWord`,
`removeMutedWord`, `addLabeler`, `removeLabeler` and `setContentLabelPref`
change them, every other preference kept as stored, and `get_preferences`
reads them back. The app applies them on the device, so at_mcp's reads still
return muted posts and labelled content as served. Every read asks the
AppView for the labels the app asks for (`atproto-accept-labelers`, which the
PDS forwards): the network's own moderation service with `;redact`, then each
labeler the account subscribes to, as its preferences named them when at_mcp
last read or wrote them (`AtMcp.AcceptLabelers`). An account's first read
reads its preferences first; if that fails, the read names the network's
service alone, as the app does before its preferences load.
`mute_list` and `block_list` take a moderation list by its DID-form URI,
which is how reads name it (`muted_by_list`, `blocking_by_list`); a list
block is a `graph.listblock` record written over the commit read, and
`unblock_list` deletes every one naming the list. Hidden posts
(`hiddenPostsPref`) are left out: the app keeps "Hide post for me" on the
device and reads nothing from that preference.

Absent from the surface: posting video and direct messages. `get_notifications` takes the service's own
filter by reason (`reasons`). An agent reads a video by its alt text and a
link card by its text, without the video or the card's image.

## The write quota

Every account has one durable write quota: 16 attempted publishing writes per
hour by default, shared by every client, alias and reconnect. The default
guards against an agent publishing faster than a person would notice and stop
it. The number is the per-turn budget an earlier version had, kept when the
bound moved to the hour, and has not been measured; `AtMcp.WriteQuota`'s
moduledoc gives the reasoning, and `AT_MCP_WRITE_LIMIT` changes it. Accounts on
one service are different agents with different needs, so each account can
have its own limit and window, saved on the account
([Operations](operations.md#an-accounts-own-write-limit)) or given by an
embedding host; the service's numbers are the default for an account that
sets none. The quota bounds
what the account publishes, so only `post`, `reply` and `repost` count
(`AtMcp.Effects.publishing/0`); a like, a follow, a block, a mute, a deletion, a
profile edit and marking notifications seen do not. A publishing write counts
even when the remote call fails; reads do not count. `identity_status` reports
the limit the account is held to, its window, usage and the reset time. The ledger is monotonic, so a clock moved backwards
cannot open a fresh window.

An attempted publishing write takes a slot in the write quota before dispatch. Refusals
of an account that is not ready, and validation failures, occur before that: posts and replies are checked against
the configured network's grapheme and byte limits, and batch reads against
their own limits (pages 1–50, `get_posts` and `get_profiles` 1–25), before
anything is reserved or sent. So is the read a reply or a quote needs: a strong
reference carries a CID the uri does not, so the referenced record is fetched
first, and a record the service refuses to hand over is refused as
`referenced_record_unreadable` with the uri and without touching the write
quota. The refusal says what the service said: `RecordNotFound` as `cause:
"not_found"`, any other refusal with the service's error name and message. A
reply to a uri whose collection is not a post, or a quote of one that is not
a post, feed, list, starter pack or labeler, is refused as an invalid argument
before anything is read. A transport failure or an outage during
that read keeps its own kind instead: it says nothing about the record, and a
caller told a live post may be deleted stops trying. A write that was actually sent is still never refunded:
its outcome is unknown, and an unknown outcome that costs nothing is a retry
loop.

Rich text preserves the supplied text and adds mention, explicit HTTP(S) link
and hashtag facets over UTF-8 byte offsets; an unresolved handle stays plain
and is named in `unresolved_mentions`. Bare domains and cashtags are not
detected.

## Inbound

`AtMcp.Notifications` is the ordinary collector. It polls each account every 60
seconds through the account's own PDS with a private per-DID checkpoint, a
five-minute overlap and durable deduplication; the first poll starts from the
recent window. The account's read state is neither a checkpoint nor changed by
collection.

`AtMcp.Inbound` is the opt-in stream collector, sharing one Jetstream connection
across accounts. It subscribes to the post, like and repost collections with an
**empty** `wanted_dids` filter and matches recipients locally in
`AtMcp.Inbound.Match`, because incoming interactions are records in somebody
else's repository: a DID filter cannot be the inbox. It persists the cursor its
adapter reports and resumes from it. The stream sees own writes and deeper
replies that notifications omit, at the cost of steady commit volume.

`AtMcp.Stream` is the adapter boundary: an adapter owns its service's options,
message shape and event fields, and `AtMcp.Inbound` and `AtMcp.Inbound.Match` see
only `AtMcp.Stream.Event`. The current adapter is Jetstream v1 through
ProtoRune's client. Another service is another module implementing that
behaviour, not a change to collection, matching, the store or delivery.

Both collectors persist into the same store and share delivery and
deduplication. Pending events are never evicted: when an account has 10,000
pending events or 16 MiB of them, batches for that account are refused and its
collection holds until delivery makes room; other accounts keep collecting,
except that Jetstream's one shared cursor pauses the stream for all of them.
The notification poller accepts each sweep oldest first, since the provider
pages newest first. Delivery runs outside collection.
Each account is a lane: its events are delivered in the order the store
accepted them, one at a time, and a failed event keeps its place and holds the
events behind it through a capped exponential backoff. Lanes deliver
concurrently, so one account's slow or failing consumer never delays another
account's events. A delivery that outlives `AtMcp.Deliver.timeout_ms/0` is
killed and retried; the HTTP bridge bounds its own request to end before that.

`AtMcp.Deliver.HTTPBridge` registers one global delivery callback and POSTs the
normalized event as JSON to the configured consumer. Only a 2xx is acceptance,
and the consumer must durably accept before returning one and must deduplicate
on recipient DID plus source URI. Redirects are not followed; a non-2xx,
redirect, transport error or timeout leaves the event in the durable outbox.
This is at-least-once delivery with consumer deduplication. It does not make
account writes exactly-once, and public activity is attributed data that
supplies no new authority. The bridge attaches whether or not any account is
logged in; a delivery URL configured with no collector enabled fails startup
with `delivery_bridge_unready` rather than running silently.

The delivered event and its thread fields are specified in full in
`AtMcp.Deliver.HTTPBridge`, and the operator's view of them is in
[operations.md](operations.md#incoming-activity).

## Failure kinds

The backend reports failure as one of three kinds — refused, credential
refused, indeterminate — and only the backend classifies its service's errors,
because only the backend knows what its client library and service mean. Any
reason of another shape is indeterminate. Credential refusal triggers session
recovery, and the retry after recovery takes its own write quota slot.

A fourth kind is AtMcp's own: `unreadable`, where the service answered but AtMcp's
parsing in the backend (`AtMcp.Effects.ProtoRune`) could not read the answer. Nothing was applied and
retrying cannot change that, because the limit is AtMcp's parser.

Anything indeterminate is an unknown outcome: the action may have happened,
AtMcp reports `outcome: "unknown"`, and never retries it. A write whose task
stopped after sending it — at the call's deadline, or because the account's
owner stopped — is the same uncertainty. A call that never started, because it
was still waiting for the account, changed nothing and says so.

Known failures carry stable codes in structured content beside recovery
guidance. Damaged durable state — quota, checkpoint, outbox, accounts file —
fails startup rather than resetting policy.

The inbound checkpoint is trusted input. AtMcp wrote it itself, mode 0600 inside
its own 0700 state directory, so it is decoded without `[:safe]` and the
structural checks on the decoded term — `version: 1`, a pending map, a receipt
list, well-formed accounts and notification watermarks — are what distinguish a
damaged checkpoint from a good one. `[:safe]` protects an atom table against
untrusted input; applied to AtMcp's own file its only effect was to refuse a
restart, because an event carries whatever keys the collector that produced it
defined and a fresh VM has not loaded that collector yet.

## Which network

The network is a value, `AtMcp.Network`, set by `AT_MCP_NETWORK` or
`config :at_mcp, network:`. Every NSID, collection, `$type`, facet and embed type
and post limit derives from it, and `AtMcp.ATProto` builds every record AtMcp
writes and declares every read it makes, over the session's own service URL. A
literal namespace anywhere else in `lib/` is a defect; `com.atproto.*` and
`chat.bsky.*` stay literal because the rename does not touch them. An
unrecognized network name raises rather than falling back to Bluesky.

`town.delve.*` is a mechanically complete rename of `app.bsky.*`. The
substantive difference AtMcp enforces is the post record's limits, read at
compile time from the vendored lexicons: `town.delve.feed.post` allows 100,000
graphemes and 500,000 bytes where `app.bsky.feed.post` allows 300 and 3,000.
The batch limit of 25 is a literal because both namespaces declare the same 25.

`AT_MCP_NETWORK` is installation-wide. Selecting another PDS changes account
hosting, not the application surface; supporting a further application means
deliberate tools and matching rules, not arbitrary records under a Bluesky
interface.

## Embedding in an Elixir application

The [embedding guide](embedding.md) covers the dependency, configuration, first
account and restart handling. The API reference describes each call.

## What AtMcp never does

- Own conversations, agent behavior, permission decisions or an agent's
  character. A host decides whether an action is approved; AtMcp decides whether
  the account has capacity left.
- Bound a turn. AtMcp bounds writes per account per hour; anything that bounds a
  turn belongs to the host that owns the turn.
- Retry an uncertain write, or reset a write quota on request.
- Serve a request that presents no grant, or let an account id arrive from
  anywhere but a resolved grant.
- Enumerate an installation's identities through an MCP tool. That is the
  operator listener's answer, and it carries no credential.
- Reset damaged durable state to make startup succeed.
- Share credentials between identities. Tracking a DID for collection grants no
  write access.
- Supply a route, a character or a conversation to the consumer it delivers to.

## Glossary

- **Account** — one AT Protocol repository AtMcp holds credentials for,
  identified by its DID and given a local name in the accounts file.
- **Identity** — the running process tree that owns an account's session,
  poller and stream registration.
- **Grant** — a bearer token AtMcp issues that names one account and one scope,
  stored only as a digest.
- **Scope** — how much of the tool surface a grant reaches: `read`, `write` or
  `manage`, derived from the tools' own annotations.
- **Connection** — a client's attachment to an account's tools, over HTTP or
  through `at_mcp-connect` on stdio, established by presenting a grant.
- **Network** — which AT Protocol namespace an installation talks
  (`bluesky` or `delve`), a value every NSID derives from.
- **Inbound** — activity arriving from the network, gathered by the
  notification poller or the Jetstream collector.
- **Delivery** — the at-least-once HTTP POST of a collected event to the
  configured consumer, retried from a durable outbox.
- **Consumer** — the one application an installation delivers inbound events
  to, which owns routing and must deduplicate.
- **Write quota** — the durable per-account limit on attempted publishing
  writes (post, reply, repost) per hour, shared by every client on that account.
- **Ready** — an account that is logged in, verified as its DID and not
  disconnected, so it serves tool calls and receives delivery.
- **Disconnected** — an account its owner stopped with `disconnect`; it stays
  stopped across restarts until `reconnect`.
