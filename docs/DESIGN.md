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
| Consumer (Dwell, Haven) | Routing, queues, conversations, mediated permissions | Account passwords or tool implementation |
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
served is the mode in which nothing is separated. `x-kite-account-did` confirms
the binding and selects nothing. Revocation is removing the grant, and takes
effect on the next request.

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

`AtMcp.MCP.Server` declares 41 tools: 40 network verbs, plus
`identity_status`. Handlers call `AtMcp.Effects` and never reimplement account
policy. Every tool declares an output schema derived from `AtMcp.Summary` and
returns its summary as structured content beside the JSON text.

Each tool's `readOnlyHint` and `destructiveHint` annotations are the only
definition of what a scope reaches. Every write tool also carries
`"kite/publicWrite"`, true for the three that count against the write quota
(`post`, `reply`, `repost`) and false for every other write, and its
description ends with the matching sentence. Both derive from
`AtMcp.Effects.publishing/0`, the list the reservation reads, so a host
counting an account's publishing reads the same classification AtMcp enforces.

| Category | Tools |
| --- | --- |
| Writing | `post`, `reply`, `delete_post`, `update_profile` |
| Reading | `get_timeline`, `get_author_feed`, `get_thread`, `get_thread_chain`, `get_posts`, `get_profile`, `get_profiles`, `search_posts`, `search_actors`, `get_feed`, `get_list_feed`, `get_actor_likes` |
| Reacting | `like`, `unlike`, `repost`, `unrepost`, and the reads `get_likes`, `get_reposted_by`, `get_quotes` |
| Graph | `follow`, `unfollow`, `block`, `unblock`, `mute`, `unmute`, and the reads `get_followers`, `get_follows`, `get_known_followers`, `get_relationships`, `get_blocks`, `get_mutes`, `get_suggested_follows` |
| Notifications | `get_notifications`, `get_unread_count`, `update_seen` |
| Account | `identity_status` |

`post` and `reply` take `images` (base64 bytes, a MIME type and alt text,
uploaded as blobs before the record is built), `quote` (an AT URI, whose CID
AtMcp reads off the record it names) and `langs`. A post with both images and a
quote becomes one `embed.recordWithMedia`. A post whose author said nothing
about its language carries no `langs` at all rather than a default `["en"]`.

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

Post and chain summaries preserve `raw_text` exactly, expand link destinations
in `text`, and expose normalized `facets`. `web_url` is the configured network's
post permalink; AT URIs remain the canonical tool references. Both carry
`images` (alt text and available thumbnail/full-size URLs) and one attributed
`quote`. Image `availability` distinguishes hydrated URLs from raw references;
no blob URLs are guessed. Quote `status` distinguishes available content,
not-found, blocked, detached, unhydrated and unsupported records. A further
quote stays a `nested_uri` rather than recursively expanding. `embed_type`
identifies other media kinds that this projection does not interpret.

These are read projections of what the server already returned, not extra
requests or image pixels. Raw notifications and stream records preserve full
facet URLs and references; when they lack hydrated content they say so.

Summaries also keep the viewer's like, repost, follow and block record URIs so
an agent can undo without the original receipt; a missing viewer object is
distinct from an empty one.

`identity_status` corresponds to nothing a person does: a person has no write
quota to read. It exists because an agent acts faster than a person while the
account outlives the run. There is no tool for declining to act; an agent that
ends its turn without calling a write tool has not posted.

Absent from the surface: lists, starter packs, saved and pinned feeds, pinned
posts, feed discovery, thread gates and reply controls, self-labels, bookmarks,
video and external link cards, direct messages, reporting, mute words and
content preferences, and server-side notification filters. An agent therefore
reads a custom feed only from a generator URI it was given, receives every
notification and discards locally, and reads a video or link-card post as a
post with no images.

## The write quota

Every account has one durable write quota: 16 attempted publishing writes per
hour by default, shared by every client, alias and reconnect. The quota bounds
what the account publishes, so only `post`, `reply` and `repost` count
(`AtMcp.Effects.publishing/0`); a like, a follow, a block, a mute, a deletion, a
profile edit and marking notifications seen do not. A publishing write counts
even when the remote call fails; reads do not count. `identity_status` reports
usage and the reset time. The ledger is monotonic, so a clock moved backwards
cannot open a fresh window.

An attempted publishing write takes a slot in the write quota before dispatch. Refusals
of an account that is not ready, and validation failures, occur before that: posts and replies are checked against
the configured network's grapheme and byte limits, and batch reads against
their own limits (pages 1–50, `get_posts` and `get_profiles` 1–25), before
anything is reserved or sent. So is the read a reply or a quote needs: a strong
reference carries a CID the uri does not, so the referenced record is fetched
first, and a record the service refuses to hand over — deleted, not indexed
yet, or not a post — is refused as `referenced_record_unreadable` with the uri
and without touching the write quota. A transport failure or an outage during
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
