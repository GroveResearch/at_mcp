# Design

This document explains how at_mcp works inside and the reasons for its
larger choices. It is for contributors, and for anyone deciding how far to
rely on at_mcp's behavior. [decisions.md](../decisions.md) records individual
decisions with the tests holding them in place.

## Division of work

at_mcp handles an account's side of an agent's life on the network: logging
in, keeping the session alive, limiting how fast the agent posts, offering
tools, and collecting incoming activity. The agent and its host handle the
rest.

| Part | Responsible for |
| --- | --- |
| ProtoRune, the AT Protocol client library | Sessions and requests to the network |
| at_mcp | Account configuration, login, tools, the write quota, collection and delivery |
| MCP | The connection between the agent's client and at_mcp's tools |
| A receiving program, when present | Routing delivered events, queues, conversations and permissions |
| The agent | Choosing which tools to call |

An MCP client can use at_mcp with no receiving program at all.

## Processes

When at_mcp starts, its supervisor starts the write quota, the store for
incoming events, the stream collector, `AtMcp.Identities` (a
`DynamicSupervisor` for accounts), and `AtMcp.Accounts`, which coordinates
account changes. For each account, `AtMcp.Identities` starts an `AtMcp.Identity`, which in turn runs the account's session process,
its notification poller and, when enabled, its place in the stream.

`AtMcp.Effects` runs every call against an account. It holds the session,
checks the account's DID after each login, takes write quota slots, and
recovers expired sessions. It runs each call in a task under the call's
deadline. Writes go one at a time in arrival order, reads run alongside them,
and only one login or refresh runs at a time. When the account stops, its
tasks stop with it.

`AtMcp.Summary` describes each kind of record once. The network code builds
results from those descriptions, and `AtMcp.MCP.Server` derives each tool's
output schema from them, so a tool's schema always matches the result it
returns.

A long-running service runs a single MCP listener for all its accounts. The
stdio launcher runs a single account and starts no listener.

## Accounts

at_mcp identifies an account by its DID. The local name in the accounts file,
such as `grug`, picks out the saved configuration. at_mcp logs in with an app
password, and checks after every login and refresh that the session belongs
to the saved DID.

Account changes, such as a login, a reload or a disconnect, run as supervised
operations. A disconnect or a configuration change cancels any older operation
still running for the same DID, so a slow login from before a disconnect
finishes without undoing it. A cancelled start, reconnect or reload reports
`account_runtime_unavailable`.

at_mcp saves a disconnect to disk before acting on it, and only an explicit
reconnect undoes it. A reload checks the whole new configuration first, then
restarts only the accounts whose configuration changed.

`at_mcp-connect` gives a stdio client access to a running service's account.
It carries the client's grant and holds no account password, so stdio and
HTTP clients on the same account share its session and write quota.

## Grants and scopes

A long-running service has a single MCP endpoint for every account. A client
sends `Authorization: Bearer GRANT`, and at_mcp looks the grant up to find
the account and the scope. A request without a grant gets `401`, because
serving anonymous requests would leave accounts unseparated. The
`x-at-mcp-account-did` header lets a client confirm the account it expects.
at_mcp answers a mismatch with `409`, and ignores the header when choosing
the account.

`AtMcp.Grants` alone decides which account and tools a request may use. It
stores a SHA-256 hash of each grant in `accounts.grants.json`, never the grant
itself. Revoking a grant deletes its entry, and the next request with it
fails.

Scopes come from the annotations each tool declares, so a new tool falls into
the right scope without a separate list to update:

- `read` covers every tool with `readOnlyHint` set.
- `write` adds the writes without `destructiveHint`.
- `manage` adds the tools with `destructiveHint`.

A tool missing from at_mcp's own declarations belongs to no scope, so a
renamed tool loses access until its declaration catches up.

A grant is a bearer token on the local machine, without TLS or any tie to a
process. It keeps each client to what it was given, and offers no protection
against a process able to read another client's configuration. Bearer tokens
leave room for signed tokens later, without changes to clients. The client's
own approval settings and at_mcp's write quota answer separate questions:
whether a person allows an action, and whether the account has capacity left.

## Tools

[tools.md](tools.md) lists every tool. `mix at_mcp.tools_doc` writes it from
`AtMcp.MCP.Server`, and a test fails when the file falls out of date. Tool
handlers call `AtMcp.Effects` and leave account rules to it. Every tool
returns its result as structured content, checked against its output schema,
plus a text block for the model.

### The text a model reads

For most tools, the text block is the result's JSON. For reads made of posts,
such as feeds, notifications, searches and threads, `AtMcp.Reading` writes
readable text: each post's author, time, the post it replies to, its text,
attachments, counts and labels, plus the `uri` and `cid` the write tools take.
Accounts, lists and starter packs read the same way. A post reads the same
in every tool showing it.

at_mcp marks text written by other people, so a model can tell it apart from
at_mcp's own words. It fences a post's text, each line after `> `. It puts
every other string written by someone else, such as names, alt text and
titles, in double quotes, with `"` and backslashes escaped. It leaves an identifier bare only when the
identifier holds nothing but identifier characters, and percent-encodes web
addresses. `AtMcp.Reading` builds its text only from `AtMcp.Reading.Text`
pieces made by its own renderers, and a test fails when a raw string slips
into the output.

A post's time is the time the network first saw it, as the app shows it. When
the author's own date is more than a day earlier, the text adds it as
"archived from". A mention reads with the DID it links to, so a real mention
differs from a bare `@word`.

`raw_text` keeps a post's text exactly as written. `text` adds each link's
destination and each mention's DID in angle brackets, and escapes the
author's own `<` and backslashes, so the only unescaped brackets come from
at_mcp.

Images, link cards, videos and quotes come from the network's own response.
at_mcp guesses no image addresses, and a quote inside a quote stays a
reference. `get_post_images` fetches a single post's pictures as MCP image
content. Pictures in every feed read would make each read many megabytes,
mostly unused.

Every post, account, list, feed and starter pack carries `web_url`, the link
a person would share, built as the app builds it. Every tool taking an AT URI,
handle or DID also takes such a link, and reports what it resolved the link
to.

Results keep the account's own like, repost, follow and block record
addresses, so an agent can undo an action without having kept the original
result. A state left unmentioned by the network stays out of the result,
rather than appearing as `false`.

### Annotations

Each tool's `readOnlyHint` and `destructiveHint` decide its scope. Each write
tool also carries `at_mcp/publicWrite`, set for `post`, `reply` and `repost`,
the writes counted against the write quota. Its description ends with a
matching sentence. Both come from `AtMcp.Effects.publishing/0`, the same list
the quota uses, so a host reading the annotation counts exactly what at_mcp
counts.

### Writes

An edit reads the record, keeps every field it leaves alone, and writes back
only if the record is still the one it read (`swapRecord`). A write built from
several reads checks the repository's commit from before them
(`swapCommit`). If the check fails, at_mcp writes nothing and reports
`changed_meanwhile`. An edit changing nothing writes nothing and reports
`unchanged`.

`post` writes the post and its reply and quote rules in a single commit, so
the post never exists without its rules. A link card's title and description
come from the agent, and at_mcp leaves the page unfetched. A post without a
stated language carries no `langs` field.

A tool taking the account's own post or list refuses another account's before
sending anything. A method the network leaves unimplemented, answering 501,
reports `upstream_not_implemented`. A read known to be missing on a network,
listed in `AtMcp.Endpoints.deployments/0`, fails with `not_served` before
anything is sent.

at_mcp reads and writes preferences as raw JSON, so every preference a tool
leaves alone stays byte for byte. The network offers no compare-and-swap for
preferences, so a change made by another client between the read and the
write is lost, and the tool's description and result say so. at_mcp never
reads out or writes the birth date, and turns on adult content only for an
account old enough for the app to show it.

When an image argument gives a `path`, at_mcp reads the file itself, so a
model avoids copying base64 bytes and getting them wrong. This works only
inside the folder in `AT_MCP_MEDIA_DIR`.

### Threads

`get_thread` shows the area around a post: two levels of parents and two of
replies, nested, with counts of anything left out. `get_thread_chain` shows
the conversation leading to a post: every ancestor from the root down, flat
and in order, plus the direct replies.

A chain too tall for a single read keeps the posts nearest the requested one
and counts the rest in `chain_omitted`. It gives the address to continue from
in `chain_before`, and passing it back as `before` returns the next page up,
with no repeats or gaps. `chain_before` is null at the root, at an unreadable
post, and at a loop. `chain_truncated` says whether any posts are missing.

### Moderation

The moderation tools match the app's moderation settings and report menu.
Muted words, labeler subscriptions and label settings are preferences, and
the app applies them on the device, so at_mcp's reads still return muted and
labeled content as the network serves it. Each read asks for labels from the
network's moderation service and every labeler the account subscribes to, as
the app does.

`identity_status` has no counterpart in the app, because a person has no
write quota. An agent acts faster than a person, and its account outlasts its
session, so it needs a way to check both.

## The write quota

Each account has a durable quota on posts, replies and reposts: 16 attempts
per hour by default, shared by every client of the account and kept across
restarts. The default guards against an agent posting faster than a person
would notice and stop it. Nobody has measured the right number. The figure
came from an earlier per-turn limit, kept when the limit moved to the hour,
and `AtMcp.WriteQuota` explains the reasoning. Each account on a service can
have its own limit.

The quota bounds what an account publishes, so likes, follows, blocks,
deletions, profile edits and reads go uncounted. at_mcp takes a slot before
sending a publishing write, and the slot stays used even when the write fails.
Refusing to refund a sent write keeps an agent from retrying an unknown
outcome at no cost. The quota's clock only moves forward, so setting the
system clock back opens no new window.

at_mcp checks everything it can before taking a slot. A post over the
network's length limit, an account not yet ready, or a reply to a record the
network refuses to show fails before counting. A reply or quote needs the
target's CID, so at_mcp reads the target first, and an unreadable target
fails as `referenced_record_unreadable`. A network outage during that read
keeps its own error, because the outage leaves the target's state unknown.

at_mcp adds mention, link and hashtag facets to a post's text using UTF-8 byte
offsets, and lists any handle it failed to resolve in
`unresolved_mentions`. Bare domains and cashtags stay plain text.

## Collection and delivery

`AtMcp.Notifications` polls each account's notifications through the
account's host every 60 seconds. It keeps a private position per DID, looks
back five minutes past it, and drops duplicates. It leaves the account's read
state alone.

`AtMcp.Inbound`, the optional stream collector, follows a single Jetstream
connection for all accounts. Incoming likes, replies and reposts live in other
people's repositories, so filtering the stream by the account's DID would miss
them. The collector subscribes with an empty `wanted_dids` filter, takes every
post, like and repost, and lets
`AtMcp.Inbound.Match` pick out the ones addressed to an account. It saves the
stream position and resumes from it. `AtMcp.Stream` hides the stream service's
format from the rest of the code, so another stream service would need only a
new adapter.

Both collectors write into a single store. When an account fills its share,
at_mcp pauses that account's collection rather than dropping events. The
stream's single position means a full account pauses the stream for every
account.

The store delivers each account's events in order, one at a time, and holds
later events behind a failing one with growing waits. Accounts deliver in
parallel, so a slow receiver delays only its own account. A delivery running
past `AtMcp.Deliver.timeout_ms/0` is stopped and retried.
`AtMcp.Deliver.HTTPBridge` sends each event as an HTTP POST and counts only a
`2xx` answer as success. This gives at-least-once delivery, and the receiver
removes repeats. [delivery.md](delivery.md) describes the event.

## Failure kinds

The network code sorts every failure into a kind, because only that code
knows what its library and the network's errors mean:

- **refused**: the network turned the request down, and nothing happened
- **credential refused**: at_mcp recovers the session and retries once, and
  the retry takes its own quota slot
- **indeterminate**: anything else, including timeouts

A further kind, `unreadable`, means the network answered and at_mcp's parser
failed to read the answer. Nothing was applied, and a retry would fail the
same way.

An indeterminate write has an unknown outcome. at_mcp reports `outcome:
"unknown"` and leaves the retry decision to the agent. A write stopped after
sending, by its deadline or by the account stopping, counts as unknown too. A
call stopped while still waiting for the account never started, and its
result says so.

at_mcp refuses to start on damaged stored data, such as the quota, a
collection position, the delivery queue or the accounts file, rather than
resetting it. at_mcp writes its collection checkpoint itself, with mode 600 in
a folder with mode 700, and checks its structure on reading it back.

## Networks

The network is a value in `AtMcp.Network`, set by `AT_MCP_NETWORK` or
`config :at_mcp, network:`. Every method name, record type and post limit
comes from it, and `AtMcp.ATProto` builds every record and request from it. A
literal `app.bsky` anywhere else in `lib/` is a bug. `com.atproto.*` and
`chat.bsky.*` stay literal, since both networks share them.

Delvetown's `town.delve.*` lexicons mirror Bluesky's `app.bsky.*` ones. The
difference at_mcp enforces is the post length: 100,000 characters and 500,000
bytes on Delvetown, against 300 and 3,000 on Bluesky, read from the lexicons
at compile time. Delvetown adds its own methods, such as
`town.delve.membership.*`, and uses Bluesky's records for follows, blocks and
self-labels. [delvetown.md](delvetown.md#delvetowns-record-types) links to
the published lexicons.

`AT_MCP_NETWORK` applies to a whole installation. Pointing an account at
another host changes where the account lives, and leaves the network's tools
as they were. Supporting a further network means adding its tools and rules
deliberately.

## Left to the host

at_mcp keeps to the account's side of the work. These belong to the agent's
host:

- conversations, the agent's character and its instructions
- approving or refusing an action, which the host decides before at_mcp's
  quota applies
- limits on an agent's turn, since at_mcp limits writes per account per hour
- routing delivered events, since at_mcp sends each event to the receiver
  configured for its account and nothing more

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
- **Delivery**: sending a collected event to a receiving program by HTTP POST,
  retried until accepted.
- **Write quota**: the per-account limit on posts, replies and reposts in a
  time window.
- **Ready**: logged in, checked against its DID, and not paused.
- **Disconnected**: paused with `disconnect`, until `reconnect`.
