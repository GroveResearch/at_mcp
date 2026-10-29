# Design

This document explains at_mcp's internals and the reasons for its larger
choices, for contributors and for anyone judging how far to rely on its
behavior. [decisions.md](../decisions.md) records individual decisions with
the tests holding them in place.

## Division of work

at_mcp handles the account's side of an agent's life on the network. It logs
in, keeps the session alive, limits the agent's posting rate, offers tools,
and collects incoming activity. The agent and its host handle the rest.

| Part | Responsible for |
| --- | --- |
| ProtoRune, the AT Protocol client library | Sessions and requests to the network |
| at_mcp | Account configuration, login, tools, the write quota, collection and delivery |
| MCP | The connection between the agent's client and at_mcp's tools |
| A receiving program, when present | Routing delivered events, queues, conversations and permissions |
| The agent | Choosing tools to call |

An MCP client can use at_mcp with no receiving program at all.

## Processes

When at_mcp starts, its supervisor starts the write quota, the store for
incoming events, the stream collector, `AtMcp.Identities` (a
`DynamicSupervisor` for accounts), and `AtMcp.Accounts`, which coordinates
account changes. For each account, `AtMcp.Identities` starts an
`AtMcp.Identity`. The identity runs the account's session process, its
notification poller and, when enabled, its place in the stream.

`AtMcp.Effects` runs every call against an account. It holds the session,
checks the account's DID after each login, takes write quota slots, and
recovers expired sessions. It runs each call in a task under the call's
deadline:

- writes run one at a time, in arrival order
- reads run alongside the writes
- logins and refreshes run one at a time

When the account stops, its tasks stop with it.

`AtMcp.Summary` describes each kind of record once. The network code builds
results from those descriptions, and `AtMcp.MCP.Server` derives each tool's
output schema from them. A test checks every result against its tool's
schema; a read's is checked when it is asked for json.

A long-running service runs a single MCP listener for all its accounts. The
stdio launcher runs a single account and starts no listener.

## Accounts

at_mcp identifies an account by its DID. The local name in the accounts file,
such as `alice`, picks out the saved configuration. at_mcp logs in with an app
password, and after every login and refresh it checks the session's DID
against the saved one.

Account changes, such as a login, a reload or a disconnect, run as supervised
operations. A disconnect or a configuration change cancels any older operation
still running for the same DID. A slow login started before a disconnect
therefore ends without undoing it. A cancelled start, reconnect or reload
reports `account_runtime_unavailable`.

at_mcp saves a disconnect to disk before acting on it. Only an explicit
reconnect undoes it. A reload checks the whole new configuration first, then
restarts the accounts with changed configuration.

`at_mcp-connect` gives a stdio client access to an account on a running
service. It authenticates with the client's grant, and the service keeps the
password. Stdio and HTTP clients on the same account therefore share its
session and write quota.

## Grants and scopes

A long-running service has a single MCP endpoint for every account. A client
sends `Authorization: Bearer GRANT`, and at_mcp looks the grant up to find the
account and the scope. Every request needs a grant, since the grant selects
the account. A request without one gets `401`.

The `x-at-mcp-account-did` header lets a client confirm the account it
expects. at_mcp answers a mismatch with `409`, and ignores the header when
choosing the account.

Each request's account and tools come from a lookup in `AtMcp.Grants`, and
from nowhere else. `AtMcp.Grants` stores a SHA-256 hash of each grant in
`accounts.grants.json`. Revoking a grant deletes its entry, and the next
request with it fails.

Scopes come from the annotations each tool declares, so a new tool falls into
the right scope with no separate list to update:

- `read` covers every tool with `readOnlyHint` set.
- `write` adds the writes without `destructiveHint`.
- `manage` adds the tools with `destructiveHint`.

Grants cover only the tools declared in `AtMcp.MCP.Server`. A tool renamed
without a matching declaration is refused under every scope.

A grant is a bearer token on the local machine, without TLS or any tie to a
process. It keeps each client to the tools it was given. A process able to
read another client's configuration can use that client's grant. Bearer
tokens leave room for signed tokens later, with no change to clients.

The client's approval settings and at_mcp's write quota answer separate
questions. The first asks whether a person allows an action. The second asks
whether the account has capacity left.

## Tools

[tools.md](tools.md) lists every tool. `mix at_mcp.tools_doc` writes it from
`AtMcp.MCP.Server`, and a test fails when the file falls out of date. Tool
handlers call `AtMcp.Effects` and leave account rules to it.

A read returns text for the model and nothing else, because hosts differ in
which half of a result the model gets: Claude Code and Codex give it
`structuredContent` when there is any, Gemini CLI and Imp give it `content`.
A read declares no output schema, since a tool that declares one must return
structured content. A program passes `"format": "json"`, or holds a grant
whose default is json, and gets the summary as structured content and as
JSON text (`AtMcp.MCP.Output`). A write returns its small summary both ways
and declares its output schema. Tests check every structured result against
its tool's schema, for reads asked for json as well as for writes.

### Text for the model

For writes and for reads with no reading of their own, the text is the
result's JSON. For reads made of posts,
such as feeds, notifications, searches and threads, `AtMcp.Reading` writes
readable text. Each post shows its author, time, parent post, text,
attachments, counts and labels, plus the `uri` and `cid` the write tools take.
Accounts, lists and starter packs read the same way. A post reads the same in
every tool showing it.

at_mcp marks text written by other people, so a model can tell it apart from
at_mcp's own words. It fences a post's text, each line after `> `. It puts
every other string written by someone else, such as names, alt text and
titles, in double quotes, with `"` and backslashes escaped. It leaves an
identifier bare only when the identifier holds nothing but identifier
characters, and percent-encodes web addresses. `AtMcp.Reading` builds its
text from `AtMcp.Reading.Text` pieces made by its own renderers, and a test
fails if a raw string appears in the output.

The time on a post is the time the network indexed it, as in the app. When
the author's own date is more than a day earlier, the text adds it as
"archived from". A mention reads with the DID it links to, so a real mention
stands apart from a bare `@word`.

`raw_text` keeps a post's text exactly as written. `text` adds each link's
destination and each mention's DID in angle brackets, and escapes the
author's own `<` and backslashes. Any unescaped angle brackets in `text` come
from at_mcp.

Image addresses, link cards, videos and quotes come from the network's
response. A quote inside a quote appears as its AT URI. Feed reads leave
pictures out to keep results small, and `get_post_images` fetches a single
post's pictures as MCP image content.

Every post, account, list, feed and starter pack carries `web_url`, the link a
person would share, built as the app builds it. Every tool taking an AT URI,
handle or DID also takes such a link, and reports its resolution of the link.

Results include the account's own like, repost, follow and block record
addresses, so an agent can undo an action without keeping the original
result. at_mcp includes a viewer state only when the network reports it.

### Annotations

Each tool's `readOnlyHint` and `destructiveHint` decide its scope. Each write
tool also carries `at_mcp/publicWrite`, set to true for `post`, `reply` and
`repost`, the writes counted against the write quota. Its description ends
with a matching sentence. Both come from `AtMcp.Effects.publishing/0`, the
list the quota uses. A host counting writes from the annotation therefore
arrives at at_mcp's own total.

### Writes

An edit reads the record, keeps the fields it leaves unchanged, and writes
back with `swapRecord`, so the write succeeds only if the record still matches
the one read. A write built from several reads checks the repository's commit
from before them with `swapCommit`. If the check fails, at_mcp writes nothing
and reports `changed_meanwhile`. An edit changing nothing writes nothing and
reports `unchanged`.

`post` writes the post and its reply and quote rules in a single commit. The
agent supplies a link card's title and description. at_mcp adds `langs` only
when the agent gives a language.

A tool taking the account's own post or list refuses another account's before
sending anything. A method answering 501 reports `upstream_not_implemented`.
A call needing a method known to be missing on a network, listed in
`AtMcp.Endpoints.deployments/0`, fails with `not_served` before anything is
sent.

at_mcp reads and writes preferences as raw JSON, so every preference a tool
leaves alone stays byte for byte. The network offers no compare-and-swap for
preferences. A change made by another client between the read and the write
is therefore lost, and the tool's description and result say so. at_mcp
leaves the birth date out of reads and writes, and turns on adult content
only for an account old enough for the app to show it.

When an image argument gives a `path`, at_mcp reads the file itself, so a
model avoids copying base64 bytes and getting them wrong. at_mcp reads such
files only from the folder in `AT_MCP_MEDIA_DIR`.

### Threads

`get_thread` shows the area around a post: two levels of parents and two of
replies, nested, with counts of anything left out. `get_thread_chain` shows
the conversation leading to a post: every ancestor from the root down, flat
and in order, plus the direct replies.

For a long chain, `get_thread_chain` returns the posts closest to the
requested one and counts the rest in `chain_omitted`. It gives the address to
continue from in `chain_before`. Passing that address back as `before`
returns the next page up, with no repeats or gaps. `chain_before` is null at
the root, at an unreadable post, and at a loop. `chain_truncated` says whether
any posts are missing.

### Moderation

The moderation tools match the app's moderation settings and report menu.
Muted words, labeler subscriptions and label settings are preferences, and the
app applies them on the device. at_mcp's reads therefore return muted and
labeled content as the network serves it. Each read asks for labels from the
network's moderation service and from every labeler the account subscribes
to, as the app does.

`identity_status` has no counterpart in the app, because a person has no
write quota. An agent acts faster than a person, and its account outlasts its
session, so the agent needs a way to check both.

## The write quota

Each account has a durable quota on posts, replies, reposts, and every
`put_record` or `delete_record` call: 16 attempts per hour by default, shared
by every client of the account and kept across restarts. The default guards
against an agent posting faster than a person would notice and stop it. The figure comes from an earlier per-turn limit,
kept when the limit moved to the hour, and nobody has measured a better one.
`AtMcp.WriteQuota` explains the reasoning. Each account on a service can have
its own limit.

Only publishing writes count against the quota. Likes, follows, blocks,
deletions, profile edits and reads are free. at_mcp takes a slot before
sending a publishing write, and keeps the slot used even when the write fails.
If an agent retries a write with an unknown outcome, the retry costs it
another slot. at_mcp ignores backward jumps in the system clock when it
computes quota windows.

at_mcp checks everything it can before taking a slot. A post over the
network's length limit, an account still logging in, or a reply to a record
the network refuses to show fails before counting. A reply or quote needs the
target's CID, so at_mcp reads the target first, and an unreadable target
fails as `referenced_record_unreadable`. If the network is down during that
read, at_mcp reports the outage, since it can't tell whether the target
exists.

at_mcp adds mention, link and hashtag facets to a post's text using UTF-8 byte
offsets, and lists any handle it failed to resolve in `unresolved_mentions`.
Bare domains and cashtags stay plain text.

## Collection and delivery

`AtMcp.Notifications` polls each account's notifications through the
account's host every 60 seconds. It keeps a private position per DID, looks
back five minutes past it, and drops duplicates. It leaves the account's read
state alone.

`AtMcp.Inbound`, the optional stream collector, follows a single Jetstream
connection for all accounts. Replies and likes are records in other people's
repositories, so the collector subscribes with an empty `wanted_dids` filter,
reads every post, like and repost, and lets `AtMcp.Inbound.Match` match them
against the tracked DIDs. It saves the stream position and resumes from it.
`AtMcp.Stream` keeps the stream service's format out of the rest of the code,
so another stream service needs only a new adapter.

Both collectors write into a single store. When an account fills its share,
at_mcp pauses that account's collection and keeps every event. The stream
keeps a single position for all accounts, so a full account pauses the stream
for every account.

The store delivers each account's events in order, one at a time. A failing
event holds the later ones behind it, with growing waits between attempts.
Accounts deliver in parallel, so a slow receiver delays only its own account.
at_mcp stops a delivery running past `AtMcp.Deliver.timeout_ms/0` and retries
it. `AtMcp.Deliver.HTTPBridge` sends each event as an HTTP POST and counts
only a `2xx` answer as success. Delivery happens at least once, and the
receiver removes repeats. [delivery.md](delivery.md) describes the event.

## Failure kinds

at_mcp classifies each failure inside the module calling ProtoRune, since that
module handles ProtoRune's error values directly. It sorts each failure into
a kind:

- **refused**: the network turned the request down, and nothing happened
- **credential refused**: at_mcp recovers the session and retries once, and
  the retry takes its own quota slot
- **indeterminate**: anything else, including timeouts

A further kind, `unreadable`, means the network answered and at_mcp's parser
failed to read the answer. Nothing was applied, and a retry fails the same
way.

An indeterminate write has an unknown outcome. at_mcp reports `outcome:
"unknown"` and leaves the retry decision to the agent. A write stopped after
sending, by its deadline or by the account stopping, counts as unknown too. A
call stopped while still waiting for the account never started, and its
result says so.

at_mcp refuses to start on damaged stored data, such as the quota, a
collection position, the delivery queue or the accounts file, and leaves the
data for an operator to inspect. at_mcp writes its collection checkpoint
itself, with mode 600 in a folder with mode 700, and checks its structure on
reading it back.

## Networks

The network is a value in `AtMcp.Network`, set by `AT_MCP_NETWORK` or
`config :at_mcp, network:`. Every method name, record type and post limit
comes from it, and `AtMcp.ATProto` builds every record and request from it.
`com.atproto.*` and `chat.bsky.*` names stay literal, since both networks
share them. The table of methods missing on each network, in
`AtMcp.Endpoints`, also uses literal `app.bsky` names as its keys. Elsewhere
in `lib/`, a literal `app.bsky` name is a bug.

Delvetown's `town.delve.*` lexicons mirror Bluesky's `app.bsky.*` ones. at_mcp
enforces different post lengths: 100,000 characters and 500,000 bytes on
Delvetown, against 300 and 3,000 on Bluesky, read from the lexicons at compile
time. Delvetown adds its own methods, such as `town.delve.membership.*`, and
uses Bluesky's records for follows, blocks and self-labels.
[delvetown.md](delvetown.md#delvetowns-record-types) links to the published
lexicons.

`AT_MCP_NETWORK` applies to a whole installation. An account's host and an
installation's network are separate settings. To support another network, a
contributor adds its names and limits to `AtMcp.Network`, along with any
tools specific to it.

## Left to the host

at_mcp keeps to the account's side of the work. These belong to the agent's
host:

- conversations, the agent's character and its instructions
- approving or refusing an action, which the host decides before at_mcp's
  quota applies
- limits on an agent's turn, since at_mcp limits writes per account per hour
- routing delivered events beyond the receiver configured for each account

## Glossary

- **Account**: an AT Protocol repository at_mcp holds a password for,
  identified by its DID, with a local name in the accounts file.
- **Identity**: the running processes for an account: its session, poller and
  stream registration.
- **Grant**: a token issued by at_mcp for a single account and scope, stored
  as a hash.
- **Scope**: the tools a grant allows: `read`, `write` or `manage`.
- **Network**: the AT Protocol application an installation talks to,
  `bluesky` or `delve`.
- **Collection**: gathering an account's incoming activity, by polling or from
  the stream.
- **Delivery**: sending a collected event to a receiving program, retried
  until accepted.
- **Write quota**: the per-account limit on posts, replies, reposts and record writes in a
  time window.
- **Ready**: logged in, checked against its DID, and not paused.
- **Disconnected**: paused with `disconnect`, until `reconnect`.
