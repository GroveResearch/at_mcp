# Delivering notifications to another program

An agent running inside an MCP client learns about replies and mentions only
when it calls a read tool. A long-running at_mcp service can do more: it
collects each account's notifications as they arrive and sends them by HTTP
to a program of yours, such as an agent host waking an agent to answer. This
guide covers both sides, configuring at_mcp and writing the receiving
program.

Delivery needs the service from [operations.md](operations.md). An
`at_mcp-stdio` started by a client collects nothing in the background.

## Collection

By default the service polls each account's notifications every 60 seconds,
through the account's host. Polling leaves the notifications' read state
alone, so the account's app still shows them as unread. Each poll looks back
five minutes past the last one and drops duplicates, and the very first poll
looks back five minutes only.

With `AT_MCP_JETSTREAM=1`, the service also follows Bluesky's network-wide
stream of posts, likes and reposts, and picks out the ones addressed to its
accounts. The stream catches deeper replies and the account's own posts, both
missing from notifications, at the cost of steady download traffic. Both
collectors feed the same queue and share duplicate removal.

at_mcp keeps collected events on disk until a delivery succeeds. When an
account has 10,000 undelivered events, or a quarter of the 64 MiB store,
at_mcp pauses collection for that account until delivery catches up. The
stream collector shares a single position across accounts, so a full account
pauses the stream for all of them.

## Configure a receiver

For a single program receiving every account's events, add these lines to the
service's environment file and restart the service:

```sh
AT_MCP_DELIVERY_URL=http://127.0.0.1:4420/inbound
AT_MCP_DELIVERY_TOKEN_FILE=/absolute/path/to/receiver-token
```

The token file holds a secret shared with your program. at_mcp sends it as a
bearer token and reads the file again before each delivery, so you can change
the token without a restart. Make the file readable by the service's user
only.

To send each account's events to a different program, give each account its
own receiver:

```sh
at_mcp-accounts delivery alice --url http://127.0.0.1:4420/inbound --token-file /path/to/alice-token
at_mcp-accounts delivery bob --url http://127.0.0.1:4421/inbound --token-file /path/to/bob-token
at_mcp-accounts reload
```

at_mcp saves each receiver in the accounts file. Per-account receivers and
`AT_MCP_DELIVERY_URL` exclude each other, and at_mcp refuses to start with
both. To switch from the single receiver, remove `AT_MCP_DELIVERY_URL` and its
token setting, set up every account, and restart the service.

With per-account receivers in use, the first `delivery` command switches
delivery off for the other accounts, and accounts added later start with
delivery off. Set up each receiver before running `reload`. To hold an
account's events for a while, run `at_mcp-accounts delivery alice --disable`
and `reload`. The account stays connected, and its events stay queued.

Changing an account's receiver cancels the delivery in progress, and queued
events go to the new receiver. The old receiver may already have stored the
cancelled event, so the new receiver should expect possible repeats.

## Write a receiver

at_mcp sends each event as an HTTP `POST` with a JSON body and the header
`Authorization: Bearer TOKEN`. Your program should:

1. Check the token.
2. Store the event durably, in a database or a queue.
3. Answer with a `2xx` status only after storing it.
4. Drop repeats, keyed on `matched_did` together with `uri`.

at_mcp treats any other answer as a failure: a non-`2xx` status, a redirect,
a connection error, or no answer within five seconds. It keeps the event and
tries again later, waiting longer after each failure. Delivery happens at
least once, so repeats are possible and step 4 matters.

at_mcp delivers each account's events in order, one at a time. An event your
program keeps refusing holds back that account's later events. Other
accounts' events keep flowing.

### The event

A typical reply notification looks like this:

```json
{
  "source": "notifications",
  "kind": "inbound_notification",
  "matched_did": "did:plc:youragent",
  "reason": "reply",
  "uri": "at://did:plc:someone/app.bsky.feed.post/3abc",
  "author": "someone.bsky.social",
  "text": "Interesting point. What about winter?",
  "thread_root_uri": "at://did:plc:youragent/app.bsky.feed.post/3xyz",
  "thread_parent_uri": "at://did:plc:youragent/app.bsky.feed.post/3xyz",
  "network": {"name": "bluesky", "label": "Bluesky"}
}
```

The fields a receiver usually needs:

| Field | Meaning |
| --- | --- |
| `matched_did` | The DID of your account receiving the event. Route on this. |
| `uri` | The record behind the event: the reply, mention or quote post, or the like or repost record. |
| `reason` or `reasons` | The kind of event, one of `reply`, `mention`, `quote`, `like` or `repost`. Polling gives `reason`, and the stream gives a `reasons` list. |
| `author`, `author_did` | The account acting. Polling gives the handle in `author`. The stream gives only `author_did`. |
| `text`, `raw_text` | A post's text. `raw_text` is exactly as written. `text` adds each link's destination and each mention's DID in angle brackets. |
| `thread_root_uri` | For a reply, mention or quote: the thread to read before answering. For a top-level post, it equals `uri`. |
| `thread_parent_uri` | For a reply: the post being answered. Absent when the post declares no parent. |
| `subject_uri` | For a like, repost or quote: the post liked, reposted or quoted. |
| `network` | The network the event came from. |

at_mcp copies `thread_root_uri` and `thread_parent_uri` from the post itself
without fetching either one, so a receiver should treat them as claims by the
post's author. Older fields `reply_root_uri` and `reply_parent_uri` carry the
same declared values without at_mcp's fallbacks.

## When delivery stalls

`at_mcp-accounts status` shows a `delivery` object for an account whose
events are stuck. It holds `"state": "stalled"`, the receiver's last answer
in `reason`, the time of the first failure in `since`, the number of attempts
so far, and the count of queued events. While delivery flows, `delivery` is
`null`.

When delivery stalls:

- Check the receiver's logs for the event it keeps refusing.
- Check the token file's contents and permissions. at_mcp fails the delivery
  for an empty or unreadable file, and leaves the token out of its logs.
- Check the address in the accounts file or the environment file.

Queued events wait through a receiver outage and go out once the receiver
answers again.

## Gaps

Polling covers what the network puts in the account's notifications. A
notification arriving more than five minutes late, after its poll window, can
be missed. Events during a `disconnect` are not collected. The stream
collector fills some of these gaps for Bluesky accounts.
