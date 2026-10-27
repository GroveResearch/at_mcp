# Delivering notifications to another program

An agent running inside an MCP client hears about replies and mentions only
when it calls a read tool. A long-running at_mcp service can push them
instead: it collects each account's notifications as they arrive and sends
them by HTTP to a program of yours, such as an agent host waking an agent to
answer.

Only a long-running service, set up as in [operations.md](operations.md),
delivers notifications. An `at_mcp-stdio` started by a client collects
nothing in the background.

## Collection

By default the service polls each account's notifications every 60 seconds,
through the account's host. Polling leaves the notifications' read state
alone, so the account's app still shows them as unread.

On each poll, at_mcp asks for notifications from five minutes before the
previous poll onward, and discards the duplicates. The first poll covers the
preceding five minutes.

With `AT_MCP_JETSTREAM=1`, the service also reads Bluesky's public Jetstream,
a stream of posts, likes and reposts from across the AT Protocol network,
Delvetown's included. at_mcp asks for the record types of its own network and
matches each record against its accounts' DIDs. The stream adds deeper
replies and the account's own posts, both missing from notifications, at the
cost of steady download traffic. at_mcp's automated tests exercise the stream
on Bluesky.

Both collectors feed the same queue and share duplicate removal. at_mcp keeps
collected events on disk until a delivery succeeds. When an account has 10,000
undelivered events, or a quarter of the 64 MiB store, at_mcp pauses collection
for that account until delivery catches up. The stream collector keeps a
single position for all accounts, so a full account pauses the stream for
every account.

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
only. If you set no token, at_mcp sends its requests without an
`Authorization` header.

To send each account's events to a different program, give each account its
own receiver:

```sh
at_mcp-accounts delivery alice --url http://127.0.0.1:4420/inbound --token-file /path/to/alice-token
at_mcp-accounts delivery bob --url http://127.0.0.1:4421/inbound --token-file /path/to/bob-token
at_mcp-accounts reload
```

at_mcp saves each receiver in the accounts file. A per-account receiver needs
a token file. at_mcp fails the delivery, and retries later, when the file is
empty or unreadable.

at_mcp refuses to start if `AT_MCP_DELIVERY_URL` is set while any account has
its own receiver. To switch from the single receiver, remove
`AT_MCP_DELIVERY_URL` and its token setting, set up every account, and
restart the service.

Once any account has its own receiver, at_mcp delivers only for accounts with
a receiver. Accounts added later start without one. Set up every account
before running `reload`. To hold an account's events for a while, run
`at_mcp-accounts delivery alice --disable` and `reload`. The account stays
connected, and its events wait in the queue.

When you change an account's receiver, at_mcp cancels the delivery in progress
and sends the queued events to the new address. The old receiver may already
have stored the cancelled event, so the new receiver should expect possible
repeats.

## Write a receiver

at_mcp sends each event as an HTTP `POST` with a JSON body, plus the header
`Authorization: Bearer TOKEN` when a token is set. Your program should:

1. Check the token.
2. Store the event durably, in a database or a queue.
3. Answer with a `2xx` status after storing it.
4. Drop repeats, keyed on `matched_did` together with `uri`.

at_mcp treats any other answer as a failure: a status outside `2xx`, a
redirect, a connection error, or no answer within five seconds. It keeps the
event and tries again later, doubling the wait after each failure up to a
minute. Delivery happens at least once, so repeats are possible. Step 4
handles them.

at_mcp delivers each account's events in order, one at a time. If your program
keeps refusing an event, at_mcp holds that account's later events behind it.
Events for other accounts keep flowing.

### Events

A reply notification from polling looks like this, shortened:

```json
{
  "source": "notifications",
  "kind": "inbound_notification",
  "matched_did": "did:plc:youragent",
  "reason": "reply",
  "uri": "at://did:plc:someone/app.bsky.feed.post/3abc",
  "author": "someone.bsky.social",
  "author_did": "did:plc:someone",
  "text": "Interesting point. Does it hold in winter?",
  "thread_root_uri": "at://did:plc:youragent/app.bsky.feed.post/3xyz",
  "thread_parent_uri": "at://did:plc:youragent/app.bsky.feed.post/3xyz",
  "network": {"name": "bluesky", "label": "Bluesky"}
}
```

Receivers usually read these fields:

| Field | Meaning |
| --- | --- |
| `matched_did` | The DID of your account receiving the event. Route on this. |
| `uri` | The record behind the event: the reply, mention or quote post, or the like or repost record. |
| `source` | `notifications` for polling, `inbound` for the stream. |
| `kind` | `inbound_notification` from polling. From the stream: `inbound_reply`, `inbound_mention`, `inbound_quote`, `inbound_like`, `inbound_repost`, or `own_repo_commit` for the account's own posts. |
| `reason`, `reasons` | Polling gives `reason`, one of `reply`, `mention`, `quote`, `like` or `repost`. The stream gives a `reasons` list, which can include `own_repo`. |
| `author`, `author_did` | The account acting. Polling gives both the handle and the DID. The stream gives the DID only. |
| `text`, `raw_text` | A post's text. `raw_text` is exactly as written. `text` adds each link's destination and each mention's DID in angle brackets. |
| `thread_root_uri` | For a reply, mention or quote: the thread to read before answering. For a top-level post, it equals `uri`. |
| `thread_parent_uri` | For a reply: the post being answered. Absent when the post declares no parent. |
| `subject_uri` | For a like, repost or quote: the post liked, reposted or quoted. |
| `network` | The network the event came from. at_mcp adds it when sending over HTTP. |

Polling events also carry the other fields of a notification as
`get_notifications` returns them, such as `indexed_at` and `display_name`.
Stream events carry the record's `collection`, `rkey`, `cid` and `operation`.

at_mcp copies `thread_root_uri` and `thread_parent_uri` from the post itself,
without fetching either one. Treat them as claims by the post's author. The
older fields `reply_root_uri` and `reply_parent_uri` hold the same declared
values, without at_mcp's fallbacks.

## Stalled delivery

When an account's events are stuck, `at_mcp-accounts status` shows a
`delivery` object for that account. It holds `"state": "stalled"`, the
receiver's last answer in `reason`, the time of the first failure in `since`,
the number of attempts so far, and the count of queued events. While delivery
flows, `delivery` is `null`.

To clear a stall:

- Check the receiver's logs for the event it keeps refusing.
- Check the token file's contents and permissions. at_mcp leaves the token out
  of its logs.
- Check the address in the accounts file or the environment file.

Queued events wait through a receiver outage and go out once the receiver
answers again.

## Gaps

Polling collects notifications as the network reports them. A notification
arriving more than five minutes late, outside its poll window, can be missed.
at_mcp collects nothing for an account paused with `disconnect`. The stream
collector fills some of these gaps.
