# Operating AtMcp

The runbook for one AtMcp service that serves several clients, collects incoming
activity, or runs continuously, and for working on AtMcp itself. For a single
client-owned `at_mcp-stdio` process, the [README](../README.md) is enough.

## Run a shared service

Binary users: [download and verify a release](../README.md#fetch-a-release).
On a Mac, use the README’s home-directory installation. For the Linux service,
replace its install block with the following, keeping the download variables
in the same terminal. Root owns the executables so the service user cannot
rewrite them. Source builders instead follow [Build a release](#build-a-release),
including its source-install commands; skip this archive-install block.

```sh
AT_MCP=/opt/at_mcp
sudo mkdir -p "$AT_MCP/releases" &&
  sudo tar --no-same-owner -xzf "$DOWNLOAD/$TARBALL" -C "$AT_MCP/releases" &&
  sudo ln -sfn "releases/at_mcp-$VERSION" "$AT_MCP/current"
```

Use this path when several clients share an account or a consumer needs background
activity delivery. For a single local MCP client, use the README instead.
`bin/at_mcp start` runs the service in the foreground; systemd or launchd keeps it
running.

Where things go, as the example units expect them (change both together to
put them elsewhere):

| | Linux (systemd) | Mac (launchd) |
| --- | --- | --- |
| `AT_MCP`: releases, and `current`, the one in use | `/opt/at_mcp` | `~/at_mcp` |
| The environment file | `/etc/at_mcp/at_mcp.env` | `~/at_mcp/at_mcp.env` |
| `STATE`: the accounts file, the grants file, the stores | `/var/lib/at_mcp` | `~/at_mcp/state` |
| Logs | the journal | `~/Library/Logs/AtMcp/at_mcp.log` |

On Linux the service runs as its own user, and the commands below that write
to `/opt` or `/etc` run as root:

```sh
sudo useradd --system --home-dir /var/lib/at_mcp --shell /usr/sbin/nologin at_mcp
```

### Settings

Everything that differs between installations is in one environment file of
`NAME=value` lines, with no `export` and no `$`, backslash or backtick in a
value. A value with a space in it is double-quoted
(`AT_MCP_ACCOUNTS_FILE="/Users/you/Library/Application Support/AtMcp/accounts.json"`):
unquoted, the shell reads the part after the space as a command. Written this
way, systemd's `EnvironmentFile=` (which strips the double quotes, see
systemd.exec(5)), the shell in the launchd plist and the release's own commands
all read the file the same way; the plist's shell stops the start at a line
that fails, rather than run with that setting unset. The file holds secrets,
so create it readable by the service alone before writing anything in it
(Linux: `sudo mkdir -p /etc/at_mcp && sudo install -m 640 -g at_mcp /dev/null
/etc/at_mcp/at_mcp.env`; Mac: `install -m 600 /dev/null ~/at_mcp/at_mcp.env`), then
edit it.

```sh
AT_MCP_ACCOUNTS_FILE=/var/lib/at_mcp/accounts.json
AT_MCP_STATE_DIR=/var/lib/at_mcp
RELEASE_COOKIE=
AT_MCP_DIST_PORT=4370
AT_MCP_PORT=4400
```

On a Mac the paths are `/Users/you/at_mcp/state/accounts.json` and
`/Users/you/at_mcp/state`, written out: nothing expands `~` there. Fill
`RELEASE_COOKIE` with the output of `openssl rand -hex 32`; the service and
the operator commands refuse to run with it empty.

- `AT_MCP_ACCOUNTS_FILE` is the accounts file, which `at_mcp-accounts` writes
  (below); the grants file is kept beside it. `AT_MCP_STATE_DIR` holds the write
  quotas, the delivery queue and the collection checkpoints. Both must be
  writable by the service's user, so they live in the state folder.
- `RELEASE_COOKIE` lets the operator commands reach the service. Every
  published release carries a cookie that anyone who downloads it can read,
  and a new one with every release, so set your own; kept here, it also stays
  the same across upgrades. The release passes the cookie to the VM on its
  command line; the example unit's `ProtectProc=invisible` keeps the service
  and what it runs from reading other services' command lines. On a machine
  with other login accounts, also mount /proc with `hidepid=invisible`.
- `AT_MCP_DIST_PORT` is where the service listens for the operator commands, on
  127.0.0.1 only; no port mapper (epmd) is needed. 4370 is the default
  (Dwell's is 4380, Haven's 4390).
- `AT_MCP_PORT` is the one loopback MCP endpoint every client reaches
  (`http://127.0.0.1:4400/mcp`); the grant a client presents selects the
  account.
- To deliver incoming activity to a consumer such as Dwell,
  `AT_MCP_DELIVERY_URL` (Dwell's `http://127.0.0.1:$DWELL_INBOUND_PORT/inbound`)
  and `AT_MCP_DELIVERY_TOKEN_FILE`, a file holding the consumer's token and
  readable by the service. `AT_MCP_NETWORK=delve` points the tools at
  `town.delve.*`. The README's [Settings](../README.md#settings) lists
  every variable.

**A second installation** on the same machine, such as one per network, is a
second copy of all of this: its own prefix, environment file, state folder and
unit, and its own `AT_MCP_DIST_PORT`, `AT_MCP_PORT` and `RELEASE_NODE` (the
node name; the first is `at_mcp`). For example, on a Mac, `AT_MCP=~/at_mcp-delve`
with `AT_MCP_NETWORK=delve`, `AT_MCP_DIST_PORT=4371`, `AT_MCP_PORT=4402` and
`RELEASE_NODE=at_mcp_delve`, and the plist's label, paths and log renamed to
match (`li.example.at_mcp.delve`, `at_mcp-delve.log`).

The state folder must be private to the service. On Linux the unit's
`StateDirectory=` creates `/var/lib/at_mcp` that way when the service first
starts. On a Mac:

```sh
mkdir -m 700 -p ~/at_mcp/state ~/Library/Logs/AtMcp
```

### Install the service

The example units are in the release, under `examples/`.

Linux:

```sh
sudo cp /opt/at_mcp/current/examples/at_mcp.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now at_mcp
journalctl -u at_mcp -f                  # its logs
```

Mac, where launchd does not expand `~`:

```sh
mkdir -p ~/Library/LaunchAgents
sed "s|/Users/you|$HOME|g" ~/at_mcp/current/examples/li.example.at_mcp.plist \
  > ~/Library/LaunchAgents/li.example.at_mcp.plist
launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/li.example.at_mcp.plist
tail -f ~/Library/Logs/AtMcp/at_mcp.log    # its logs
```

Each runs `bin/at_mcp start` in the foreground with the environment file
loaded. systemd restarts it when it fails; launchd restarts it when it exits
with an error, and starts it at login. To stop it: `sudo systemctl stop at_mcp`,
or `launchctl bootout "gui/$(id -u)/li.example.at_mcp"`.

### Accounts and operator commands

`at_mcp-accounts` and the release's own `bin/at_mcp rpc EXPR`, `remote`, `stop`
and `pid` read the same environment file when `AT_MCP_ENV_FILE` names it, and
reach the running service over 127.0.0.1:

```sh
export AT_MCP_ENV_FILE=~/at_mcp/at_mcp.env
~/at_mcp/current/bin/at_mcp-accounts add grug --handle grug.example   # asks for an app password
~/at_mcp/current/bin/at_mcp-accounts reload
~/at_mcp/current/bin/at_mcp-accounts status
~/at_mcp/current/bin/at_mcp-accounts connection grug                 # a grant, for an MCP client
```

On Linux, as the service's user, which owns the accounts file. Run it from a
directory that user can read, such as `/`: the command starts in the current
directory, and your home is usually closed to the `at_mcp` user.

```sh
cd / && sudo -u at_mcp env AT_MCP_ENV_FILE=/etc/at_mcp/at_mcp.env /opt/at_mcp/current/bin/at_mcp-accounts status
```

`add` verifies the login before saving anything; `reload` tells the running
service. [Account options](#account-options) covers
`update`, `remove`, `disconnect`, `reconnect`, grants and scopes. Leave a
`remote` session with Ctrl-C twice: when its input ends, as piped input does,
the service it is attached to halts.

### Account options

In the remaining examples, replace `at_mcp-accounts` with the same absolute
command and user/environment prefix you used above.

For an account on another PDS, use `add NAME --handle HANDLE --service URL`.
`at_mcp-accounts list` shows saved configuration; `status` shows the running service.

`--password-stdin` reads the password from stdin for automation; passwords are
never command-line arguments. The accounts file holds app passwords and
verified DIDs with mode 0600; the environment file names it
(`AT_MCP_ACCOUNTS_FILE`), and every command given that file uses it.
`--file PATH` selects another one for one command. Duplicate names and DIDs
are rejected.

There is one MCP endpoint for the whole installation, `AT_MCP_PORT` (4400).
Which identity a client acts as follows from the grant it presents.

### Issue a connection

```sh
at_mcp-accounts connection grug
at_mcp-accounts connection grug --transport stdio
at_mcp-accounts connection grug --scope read
```

Each run of `connection` issues a new grant and prints a descriptor an MCP
client consumes: the shared URL, an `Authorization: Bearer` header carrying the
grant, and the account's DID in `x-kite-account-did`, which confirms the
binding and selects nothing. Tokens are stored only as digests, so a grant
cannot be recovered later.

`--scope` bounds what the grant reaches: `read` is every tool that declares
`readOnlyHint`; `write` adds writes that destroy nothing; `manage` (the default)
adds the destructive ones. Discovery currently lists all tools even for a
restricted grant; scope is enforced when a tool is called. A read grant does
not hide write tools, and a visible tool is not proof of permission. Host
approvals remain separate. The stdio descriptor's `at_mcp-connect` command reaches
the same running account through HTTP, carries the grant in `AT_MCP_GRANT` (never
argv) and holds no account password, so HTTP and stdio clients share the
session, write quota and disconnect control.

```sh
at_mcp-accounts grants
at_mcp-accounts revoke GRANT_ID
```

Revocation takes effect on the next request. Grants live in
`accounts.grants.json` beside the accounts file; deleting that file revokes
every grant and keeps every identity. Removing an
account revokes its grants.

### Manage accounts

```sh
at_mcp-accounts update grug        # new password; --handle, --service
at_mcp-accounts remove reader
at_mcp-accounts reload
at_mcp-accounts status
at_mcp-accounts disconnect grug
at_mcp-accounts reconnect grug
```

`update` verifies the saved DID before replacing credentials; a failed login
leaves the file unchanged. After `add`, `update` or `remove`, run `reload`: it
reads the file the service was started with, leaves unchanged accounts running,
replaces changed ones, and keeps disconnected accounts disconnected, write
quotas and delivery history. Each changed account is reported `ready`,
`disconnected` or `unavailable`; a replacement that cannot log in is
`unavailable` and `reload` exits nonzero;
correct the file and reconnect explicitly. `remove` deletes saved credentials
and keeps the account's history and its disconnected state. Neither `remove` nor `disconnect`
revokes the app password at the PDS.

`status`, `reload`, `disconnect` and `reconnect` reach the running service over
the release's Erlang distribution, which listens on 127.0.0.1 only, at
`AT_MCP_DIST_PORT`, with no port mapper (epmd). They reach it when
`AT_MCP_ENV_FILE` names the service's environment file, which carries its
cookie, port and node name.

## Configuration

An installation is configured by its accounts file and nothing else. The
environment sets where things are and what is switched on; the README's
[Settings](../README.md#settings) lists every variable, its default and its
check. A misspelled `AT_MCP_*` variable or a bad value stops the service at
startup and names it. To see what a running service has, with each value's
source:

```sh
export AT_MCP_ENV_FILE=~/at_mcp/at_mcp.env
~/at_mcp/current/bin/at_mcp rpc 'AtMcp.CLI.settings()'
```

On Linux, as with `at_mcp-accounts`:
`cd / && sudo -u at_mcp env AT_MCP_ENV_FILE=/etc/at_mcp/at_mcp.env /opt/at_mcp/current/bin/at_mcp rpc 'AtMcp.CLI.settings()'`.

The release itself reads two more: `RELEASE_COOKIE`, the cookie the operator
commands present (set one per installation, since a published release's own is
readable by anyone who downloads it), and `RELEASE_NODE`, the service's Erlang
node name. A second installation on one machine needs its own node name. A
name without a host is given `@localhost`, or `@127.0.0.1` under
`RELEASE_DISTRIBUTION=name`; a host it names must resolve to loopback.

`.env.example` is the template for the environment file.

**First run from the account variables.** An installation with
`AT_MCP_HANDLE` and `AT_MCP_APP_PASSWORD` set (and optionally the `_2` pair and
`AT_MCP_SERVICE`; the older `BLUESKY_*` names still work) and no accounts file
writes itself one at startup, naming the accounts `default` and `second`. This
happens once; with a file present these variables are not consulted, and
changing them afterwards does nothing.

**Two networks, two installations.** `AT_MCP_NETWORK` is installation-wide, so
reaching Bluesky and Delvetown at once is two services, each with its own
unit, environment file, accounts file, `AT_MCP_STATE_DIR`, ports and
`RELEASE_NODE` (see [Settings](#settings)). Two releases
with the same node name or distribution port cannot both run.

## Attach a client over HTTP

The endpoint is `http://127.0.0.1:4400/mcp`. A request with no grant is refused
with `401`; the descriptor from `at_mcp-accounts connection NAME` is how a client
attaches:

```json
{"name":"at_mcp-grug","type":"http","url":"http://127.0.0.1:4400/mcp",
 "headers":[{"name":"authorization","value":"Bearer kite-..."},
            {"name":"x-kite-account-did","value":"did:plc:..."}]}
```

The descriptor above is AtMcp’s output format, not a universal client config.
Claude Code requires a headers **object**, so put the returned values into a
private `mcp.json` file in this shape (do not paste the headers array):

```json
{"mcpServers":{"at_mcp":{"type":"http","url":"http://127.0.0.1:4400/mcp",
 "headers":{"authorization":"Bearer YOUR_RETURNED_GRANT",
            "x-kite-account-did":"YOUR_RETURNED_DID"}}}}
```

Start it with `claude --mcp-config /absolute/path/to/mcp.json --strict-mcp-config`.
The [README](../README.md#connect-a-first-account) describes the named host.

Then ask the agent for `identity_status` and `get_profile` and check both name
the intended account.

A grant is a bearer token on loopback with no TLS and no binding to the process
holding it: any process that can read a client's environment or configuration
can use it. It separates what each client was given, not what each process
could obtain. The host's own tool-approval controls still govern whether an
action is approved; the account's write quota only says whether capacity is left.

## Incoming activity

The service polls each account's notifications every 60 seconds
(`AT_MCP_NOTIFICATIONS_INTERVAL_SECONDS`) through its PDS, without changing their read state. Configure where to deliver:

```sh
AT_MCP_DELIVERY_URL=http://127.0.0.1:4420/inbound
AT_MCP_DELIVERY_TOKEN_FILE=/absolute/private/path/consumer-token
```

The environment destination above is a **single consumer for every account**.
For separate agents on the same machine, save a destination for each account:

```sh
bin/at_mcp-accounts delivery alice --url http://127.0.0.1:4420/inbound --token-file /private/alice/consumer-token
bin/at_mcp-accounts delivery bob --url http://127.0.0.1:4421/inbound --token-file /private/bob/consumer-token
bin/at_mcp-accounts reload
```

Each token file contains that receiver's bearer token, not a PDS app password
or an MCP grant. Keep it private and readable by the service user. Tokens are
read again on each attempt, so token rotation does not require a reload.
An empty or unreadable token file, or one whose contents are more than one
header value, fails that attempt and is retried; AtMcp never sends that
account's activity without its token, and the failure it reports names
neither the token nor its file.
The destination and token file are saved in the named account's `delivery`
field in the existing accounts file; the command never changes its credentials.
The first destination command explicitly disables delivery for the other saved
accounts; configure each receiver before reloading. While any account remains
in this configuration, accounts added later start with delivery disabled too.
If you remove every account, configure each new destination before reloading
again: an empty accounts file does not retain the delivery mode. This workflow
covers the named shared service, not an embedding host's callback registration.
If editing JSON directly, every account must have
`"delivery"` set to its destination or `null`; a partial migration is rejected.
Use `delivery alice --disable` followed by `reload` to hold Alice's incoming
activity without disconnecting her account or discarding queued events.

When switching from the single consumer, remove `AT_MCP_DELIVERY_URL` and its
`AT_MCP_DELIVERY_TOKEN` / `AT_MCP_DELIVERY_TOKEN_FILE` from the service environment,
configure each account, then restart the service. Combining the global URL with
account destinations is rejected rather than guessing where notifications go.
Once account destinations are configured, an account without a destination
holds its events; there is no fallback to another agent or global credentials.
The existing one-consumer configuration remains supported without changes.

Reloading a changed destination cancels that account's current delivery attempt
before applying the new route; retained events then go to the new receiver.
An interrupted HTTP attempt may already have been accepted by the old receiver,
so changing receivers requires the same deduplication care as other retries.
Removing an account disconnects it and retains its pending events. A restart
loads the saved destinations again. One unavailable receiver holds only its
own account's queue.

The URL belongs to the receiving application (for example, an agent host
that accepts each event into its agent's work queue). The token is re-read for every delivery, so rotation
needs no restart.

The contract, in full in `AtMcp.Deliver.HTTPBridge`: AtMcp POSTs the normalized
event as JSON (`matched_did`, `uri`, reasons, author, text, thread context,
`network`). The receiver must durably accept before returning 2xx and must
deduplicate recipient DID plus source URI. A non-2xx, redirect, transport error
or timeout leaves the event pending for retry, so delivery is at least once.
AtMcp supplies no route, character or conversation.

Each account's events are delivered in order, so an event the consumer keeps
refusing holds that account's later events behind it. `at_mcp-accounts status`
shows such an account with `delivery` set: `"state": "stalled"`, the consumer's
last answer in `reason` (its shape, with any text in it left out; the log line
shows the text), `since` (when that event first failed), `attempts` (counted up to 20)
and the account's `pending` count. `delivery` is `null` while delivery flows.

Thread context is `thread_root_uri` and `thread_parent_uri`: the thread to read
to answer, and the post being answered. Both collectors publish them under the
same names, and only when the delivered record is itself a post — that is,
for a mention, a reply or a quote. They are absent on every other event: a
like or a repost, whose `uri` is the like or repost record rather than a post,
and an own-repo echo of the account's own commit.

`thread_root_uri` is always present on those three. It is the record's declared
reply root; failing that the declared reply parent, which is the nearest
ancestor the record names; failing both the record's own `uri`. A top-level post
is therefore the case `thread_root_uri == uri`, and that comparison, not the
absence of `thread_parent_uri`, is how a host recognises one.
`thread_parent_uri` is absent whenever the record declared no reply parent,
which happens both on a top-level post and on a reply that declared only a
root.

The two uris are what the record declared, resolved against each other only to
the extent above: AtMcp does not fetch either one, so neither is known to exist,
to be a post, or to belong to one thread. The single check AtMcp does make is for
self-reference — a record naming its own `uri` as its parent or its root has
that ref dropped, so `thread_parent_uri` never equals `uri`.

`subject_uri` is the record a like, a repost or a quote addresses: the liked or
reposted post, or the quoted post. Both collectors send it — the notifications
collector from the application's `reasonSubject`, the Jetstream collector from
the record itself. It is the only pointer to a post on a like or a repost. On a
quote it is also the only pointer to the quoted post, because a quote that is
itself a reply has a `thread_root_uri` naming the thread it was posted into,
which need not contain what it quoted.

The older `reply_root_uri` and `reply_parent_uri` still report what the record
itself declared, unresolved. The notifications collector also sends the author's
handle as `author`; the Jetstream collector sends only `author_did`, because a
repo commit carries no handle and resolving one would be a network call per
event.

Collection revisits five minutes before its checkpoint and deduplicates; the
first poll looks back five minutes, not the whole inbox. Pending events are
never evicted: when an account has 10,000 pending events
(`AT_MCP_INBOUND_MAX_EVENTS`) or a quarter of the store's 64 MiB
(`AT_MCP_INBOUND_MAX_BYTES`), that account's collection holds until delivery
makes room. Late arrivals outside the overlap, and activity the provider never
puts in the inbox, are not covered.

`AT_MCP_JETSTREAM=1` adds the network-wide stream collector. It downloads every
post, like and repost and filters recipients locally, so expect continuous
bandwidth; it can see own writes and deeper replies that notifications omit.
Both collectors share delivery and deduplication.

## When the service starts

A login the PDS does not answer is not a failed startup. The service starts,
`at_mcp-accounts status` shows the account configured and not running, and the
login is retried with backoff (one second, doubling to thirty) until it
succeeds. A credential the PDS refuses would be refused again, so it is
reported once in the service log and left alone until `at_mcp-accounts reconnect
NAME`, or a `reload` after the file is corrected. What does fail startup is a
runtime that cannot start any account: an unreadable accounts file, or a state
directory another process owns.

Account controls for the running service:

```sh
at_mcp-accounts status
at_mcp-accounts disconnect grug
at_mcp-accounts reconnect grug
```

Disconnect is persisted first, then stops tool calls, polling, stream tracking
and delivery for every alias of that DID in this runtime; accepted pending
events, receipts and write quotas stay. Reconnect logs in before resuming the
delivery it stopped; a failed login leaves the account disconnected. Activity during the interval is not promised on
reconnect. A configured delivery bridge attaches whether any account is running
or not, so the service stays available for reconnect. A programmatic identity
whose configuration the service no longer has reports `configuration_required` until
it is supplied again.

## Ask an installation which identities it holds

With `AT_MCP_CONTROL_PORT` set, a loopback listener answers what a host would
otherwise be told by hand:

```sh
curl -s http://127.0.0.1:4410/identities
```

Each entry carries the account's public fields, a descriptor with the shared
URL and `x-kite-account-did` (no credential; add the grant from
`at_mcp-accounts connection`), and a `runtime` object. `runtime: null` means the
service has not loaded the account (reload fixes it); `running: false` means it
is loaded and down (reload will not); `ready: true` means it is logged in and
serving tool calls and delivery; `disconnected: true` means its owner
disconnected it. An unreadable configuration answers
`503 configuration_unreadable`. This is deliberately not an MCP tool.

## When something goes wrong

- **The stdio command waits silently:** its MCP host must start it and speak
  the protocol on stdin/stdout; diagnostics are on stderr.
- **The state directory is already in use:** another AtMcp owns it. Close that
  client or share one service; do not create extra state directories to bypass
  a write quota.
- **Login fails:** check handle, app password and PDS URL. The service's
  `AT_MCP_ENV_FILE` and a stdio client's `AT_MCP_STDIO_ENV_FILE` are separate. In
  the shared service a PDS that did not answer is retried on its own; a refused
  credential is in the service log, and `at_mcp-accounts status` shows the account
  configured and not running until it is reconnected or reloaded.
- **The write quota is exhausted:** `identity_status` reports the reset time.
  Restarting clients does not replenish it.
- **A write timed out:** it may have reached the PDS. Check the account before
  creating again.
- **State cannot be read:** AtMcp refuses damaged state rather than resetting
  policy. Preserve the directory and read the diagnostics; do not delete it to
  make startup succeed.
- **Startup reports `delivery_bridge_unready`:** delivery is configured but no
  collector is enabled.
- **An inbound event is delayed:** check the account is connected, collection
  is enabled, the consumer routes that DID, and the destination is not paused.
  Accepted work stays queued through consumer outages.

## Upgrade

Fetch and unpack the new release beside the one running, as above but
without the `ln`. Then repoint and restart (on Linux, `ln` with `sudo`):

```sh
ln -sfn "releases/at_mcp-$VERSION" "$AT_MCP/current"
sudo systemctl restart at_mcp            # Mac: launchctl kickstart -k "gui/$(id -u)/li.example.at_mcp"
```

and check `at_mcp-accounts status`. Activity collected and not yet delivered is
delivered after the restart. A write running at the restart may or may not
have landed, as with any interrupted write, and nothing retries it: check the
account before writing again.

No release so far changes the format of what AtMcp stores (the accounts file,
the grants file, the write quota and the delivery queue), so an upgrade
changes no data and AtMcp keeps no copy of it. CI's upgrade check writes to
each of these under the older release and the newer one and reads them back
under the other, so it fails when a release changes one. A release that
changes the format will copy what it changes when it starts, and say here how
to put the copy back.

### From 0.2.11 to the next release

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

### From 0.2.10 to 0.2.11

0.2.11 stores data in the same format as 0.2.10 and starts from the same
environment, so rolling back works as below.

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

### From 0.2.9 to 0.2.10

0.2.10 stores data in the same format as 0.2.9 and starts from the same
environment, so rolling back works as below.

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

### From 0.2.8 to 0.2.9

0.2.9 stores data in the same format as 0.2.8 and starts from the same
environment, so rolling back works as below.

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

### From 0.2.7 to 0.2.8

0.2.8 stores data in the same format as 0.2.7 and starts from the same
environment, so rolling back works as below. Reads show what the app shows,
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

### From 0.2.6 to 0.2.7

0.2.7 stores data in the same format as 0.2.6 and starts from the same
environment, so rolling back works as below. Fixes found by running the write
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

### From 0.2.5 to 0.2.6

0.2.6 stores data in the same format as 0.2.5 and starts from the same
environment, so rolling back works as below. Existing calls mean what they did;
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

### From 0.2.4 to 0.2.5

0.2.5 stores data in the same format as 0.2.4 and starts from the same
environment, so rolling back works as below. Existing tools keep their
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

### From 0.2.3 to 0.2.4

0.2.4 stores data in the same format as 0.2.3 and starts from the same
environment, so rolling back works as below. No tool or argument changed.
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

### From 0.2.2 to 0.2.3

0.2.3 stores data in the same format as 0.2.2 and starts from the same
environment, so rolling back works as below. No tool or argument changed.
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

### From 0.2.1 to 0.2.2

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

### From 0.2.0 to 0.2.1

0.2.1 stores data in the same format as 0.2.0, and an environment that started
0.2.0 starts 0.2.1 unchanged, so rolling back works as below. No tool, argument
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
See the README's [Settings](../README.md#settings).

**Embedding the Hex package.** `{:at_mcp, "~> 0.2.0"}` selects 0.2.1; nothing
to change.

### From 0.1.3 to 0.2.0

0.2.0 stores data in the same format as 0.1.3, so rolling back works as below.
What changes is how it reads its settings, and some of what it does with them.
The version is 0.2.0 rather than 0.1.4 because an environment that started
0.1.3 can stop 0.2.0 from starting, and because the Hex package changes how an
embedding application configures it (below).

**Check the environment before you restart.** 0.2.0 checks every setting when
it starts and refuses to start, naming the variable, when:

- a variable starting `AT_MCP_` is not one of the settings in the README's
  [Settings](../README.md#settings) table (a misspelling is told the closest
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
[direct authenticated reads](../README.md#prototype-direct-authenticated-reads)
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

## Roll back

Stop the service, point `current` at the release you left and start it (on
Linux, `ln` with `sudo`):

```sh
sudo systemctl stop at_mcp               # Mac: launchctl bootout "gui/$(id -u)/li.example.at_mcp"
ln -sfn releases/at_mcp-OLDVERSION "$AT_MCP/current"
sudo systemctl start at_mcp              # Mac: launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/li.example.at_mcp.plist
```

The older release starts on the accounts, grants and state the newer one
left.

## Transition from Kite

Kite 0.1.2 installations can move to `at_mcp` while keeping their account
state. The public repository starts from a reviewed source snapshot; the
private Kite Git history remains separate.

Stop Kite before starting at_mcp on the same state. Keep the existing state
files and service account; no account recreation, grant rotation or data conversion
is needed. Unpack the new release beside the old one and retain the old release
and configuration for rollback.

Rename each `KITE_*` setting to `AT_MCP_*`, **preserving its value**, except
`KITE_MCP_PORT` becomes `AT_MCP_PORT`. In particular, set
`AT_MCP_ACCOUNTS_FILE` to the exact existing accounts file and `AT_MCP_STATE_DIR`
to the exact existing state directory. The grants file remains beside the accounts
file. `BLUESKY_HANDLE`, `BLUESKY_APP_PASSWORD` and `BLUESKY_SERVICE` keep
working (with a warning to rename them `AT_MCP_HANDLE`, `AT_MCP_APP_PASSWORD`
and `AT_MCP_SERVICE`); the cookie, node name and port values do not change. Old `KITE_*` settings are rejected with
the corresponding new name; they are not silently ignored or treated as aliases.

For example, an existing Linux installation keeps:

```sh
AT_MCP_ACCOUNTS_FILE=/var/lib/kite/accounts.json
AT_MCP_STATE_DIR=/var/lib/kite
AT_MCP_PORT=4400
AT_MCP_DIST_PORT=4370
```

Update the installed unit's command to `current/bin/at_mcp start`, keeping its
existing user, group, environment-file path, working directory and state-directory
ownership. The new-install examples above use new paths; do not replace existing
paths with those defaults during this transition. Update shell commands and MCP
client commands from `kite-accounts` to `at_mcp-accounts`, `kite-mcp` to
`at_mcp-stdio`, and `kite-connect` to `at_mcp-connect`. Set `AT_MCP_ENV_FILE` or
`AT_MCP_STDIO_ENV_FILE` in place of the corresponding old setting. Shared clients
keep their existing bearer token, under `AT_MCP_GRANT` for the new stdio front.
HTTP clients keep their URL, token, tool names and `x-kite-account-did` header.

If the old installation used defaults, at_mcp refuses to silently start an empty
store when it finds the old location and prints the exact new setting and path.
For single-account stdio, that path is the account's existing hashed directory
under the old `inbound/stdio/` folder, not the shared `inbound` root. Fresh
installations without old data use the new `at_mcp` defaults normally.

After restarting, run `at_mcp-accounts status` and confirm the same account IDs,
DIDs, readiness, disconnected accounts and write usage. Roll back by stopping
at_mcp, restoring the old unit command and configuration names, pointing `current`
at the old release, and starting Kite. Both releases read the same unchanged
accounts, grants, quota and inbound files, including work accepted after the upgrade.

Elixir hosts embedding the library also rename `config :kite` to
`config :at_mcp` and module references to `AtMcp`, retaining their configured
paths. Startup rejects recognized settings left under `:kite` instead of
silently choosing new defaults.

## Build a release

This developer path starts from a source checkout and needs Elixir 1.19,
a compatible Erlang/OTP, a C compiler and Make. Clone
[`GroveResearch/at_mcp`](https://github.com/GroveResearch/at_mcp), then run from
the checkout root:

```sh
mix deps.get
MIX_ENV=prod mix release               # _build/prod/rel/at_mcp
```

A build from a checkout is version `0.0.0-dev`; its `BUILD` file names the
commit. To build it as a version, as CI does for a tag, set `RELEASE_VERSION`:
`RELEASE_VERSION=0.3.0 MIX_ENV=prod mix release`. Mix does not recompile when
only the version changes, so after building another version run
`MIX_ENV=prod mix clean` first; the release refuses to assemble otherwise.

For direct stdio, use the absolute path to `_build/prod/rel/at_mcp/bin/at_mcp-stdio`
in the [client configuration](../README.md#connect-a-first-account). To use the
service units, first copy the build into their release layout. These commands
start at the source checkout root. Use a destination version that is not
already installed; do not copy over a running release.

On a Mac:

```sh
VERSION=$(cut -d' ' -f2 _build/prod/rel/at_mcp/releases/start_erl.data)
AT_MCP="$HOME/at_mcp"
test ! -e "$AT_MCP/releases/at_mcp-$VERSION" &&
  mkdir -p "$AT_MCP/releases" &&
  cp -R _build/prod/rel/at_mcp "$AT_MCP/releases/at_mcp-$VERSION" &&
  ln -sfn "releases/at_mcp-$VERSION" "$AT_MCP/current"
```

For the Linux system service:

```sh
VERSION=$(cut -d' ' -f2 _build/prod/rel/at_mcp/releases/start_erl.data)
AT_MCP=/opt/at_mcp
test ! -e "$AT_MCP/releases/at_mcp-$VERSION" &&
  sudo mkdir -p "$AT_MCP/releases" &&
  sudo cp -R _build/prod/rel/at_mcp "$AT_MCP/releases/at_mcp-$VERSION" &&
  sudo ln -sfn "releases/at_mcp-$VERSION" "$AT_MCP/current"
```

Continue with [the service user and settings](#run-a-shared-service), skipping
its archive-install block. These source-install commands use no download
variables or tarball.

A release runs on the Erlang it was built with. An Erlang from Homebrew links
Homebrew's OpenSSL, so a release built with it loads `crypto` only on a Mac
with that same OpenSSL; CI requires distributable macOS releases to link
nothing outside macOS. In
a checkout, without a release, `mix at_mcp.server` runs the service in the
foreground with the environment of the shell.

## Develop and verify

Elixir 1.19, a compatible Erlang/OTP, a C compiler and Make, plus Node.js and
npm for the independent MCP client checks:

```sh
mix deps.get
mix check                     # format, compile with warnings as errors, test
MIX_ENV=prod mix release
```

### Independent client checks

Three tests drive AtMcp with the official MCP packages rather than a mock, and
skip with a reason when the packages are absent:

```sh
probe_dir=$(mktemp -d)
npm install --prefix "$probe_dir" --ignore-scripts --no-audit --no-fund \
  @modelcontextprotocol/sdk@1.29.0 @modelcontextprotocol/client@2.0.0
MCP_SDK_PATH="$probe_dir/node_modules/@modelcontextprotocol/sdk" \
MCP_CLIENT_PATH="$probe_dir/node_modules/@modelcontextprotocol/client" mix check
```

`test/at_mcp/http_client_test.exs` needs `MCP_SDK_PATH`; `test/at_mcp/stdio_test.exs`
and `test/at_mcp/shared_stdio_test.exs` need `MCP_CLIENT_PATH` as well. They use
disposable loopback accounts and publish nothing.

Two more tests exercise the built release and skip without it:

```sh
TEST_ACCOUNT_RELEASE="$PWD/_build/prod/rel/at_mcp" \
TEST_CONNECT_RELEASE="$PWD/_build/prod/rel/at_mcp/bin/at_mcp-connect" mix check
```

`test/at_mcp/account_release_test.exs` is gated on `TEST_ACCOUNT_RELEASE`.
`TEST_CONNECT_RELEASE` makes the shared stdio
test launch the release's `at_mcp-connect` instead of test beams. To drive the
release's `at_mcp-stdio` with the SDK probe directly, run
`test/support/stdio_sdk_probe.mjs` with both package paths,
`TEST_STDIO_RELEASE=1` and `TEST_MCP_COMMAND` pointing at it.

With every variable above set the suite reports no skipped tests. That is what
`.github/workflows/check.yml` runs on every pull request, from a fresh checkout, and it
fails if any test skips: a skipped interoperability check otherwise reads as a
pass.

Two scripts run a built release as [Install the service](#install-the-service)
describes, against a loopback PDS, under a scratch root and HOME:

```sh
python3 scripts/foreground_boot_check.py "$PWD/_build/prod/rel/at_mcp"
python3 scripts/upgrade_rollback_check.py OLD_RELEASE_DIR "$PWD/_build/prod/rel/at_mcp"
```

The first starts it as the example launchd plist does and runs every operator
command against it, with no port mapper; the second upgrades from an older
release to this one and rolls back. With `--systemd` (as root) or `--launchd`
the second installs the example unit for real; those run only on a CI runner,
and the `release` and `macos` jobs of `check.yml` run them.

Dependencies use released Hex packages; package builds do not read local dependency path overrides.

### End-to-end round trips

The fake PDS in the tests answers as AtMcp's authors believe a service
answers. `test/e2e` checks that belief against upstream's own reference PDS and
AppView, from `@atproto/dev-env`, running on this machine at the atproto commit
the vendored lexicons come from. No account on any real network is involved,
and nothing leaves localhost. One command builds what it needs, starts the
network, runs the suite and stops everything:

```sh
scripts/e2e.sh                # or scripts/e2e.sh test/e2e/round_trip_test.exs:LINE
```

It needs git, Node 22.19 or later and pnpm 11.11.0. The first run fetches and
builds atproto under `_build/e2e` (`AT_MCP_E2E_DIR` moves it), which takes a
minute or two; after that a run takes about ten seconds. Without
`DB_POSTGRES_URL` and `REDIS_HOST` it starts a private Postgres and Redis
(`initdb`, `pg_ctl`, `redis-server` on PATH) in a scratch directory and removes
them afterwards. The tests are tagged `:e2e` and excluded from `mix check`;
`.github/workflows/e2e.yml` runs them on request.

`AtMcp.Test.DevNetwork` runs `test/support/dev_network.mjs`, which starts the
network with two accounts and a feed generator, and points AtMcp at its
AppView through `config :at_mcp, appview: [service: ..., url: ...]`
(`AtMcp.Network`), the one setting that exists for this. Each write tool is
written, read back through the read tools as the AppView serves it, undone,
and read again; between a write and a read the suite waits until the AppView
has indexed everything the PDS sequenced, rather than sleeping.

| Write tools | Read back with |
| --- | --- |
| `post` (reply and quote rules, images), `set_post_interactions`, `delete_post` | `get_thread` viewer, `get_record` on the gates, `get_post_images`, `get_posts` |
| `reply`, `hide_reply`, `unhide_reply` | `get_thread` |
| `detach_quote`, `reattach_quote` | `get_posts` (the quote's status) |
| `like`, `unlike`, `repost`, `unrepost` (by a handle-form uri) | `get_posts` viewer and counts, `get_likes`, `get_reposted_by` |
| `follow`, `unfollow`, `block`, `unblock`, `mute`, `unmute` | `get_relationships`, `get_followers`, `get_blocks`, `get_mutes` |
| `mute_thread`, `unmute_thread`, `bookmark`, `unbookmark` | `get_posts` viewer, `get_bookmarks` |
| `update_seen` | `get_unread_count` |
| `pin_post`, `unpin_post`, `set_status` | `get_record` (`get_profile` shows neither) |
| `update_profile` (fields, avatar, links) | `get_profile`, `get_record` |
| `create_list`, `add_to_list`, `update_list`, `remove_from_list`, `delete_list` | `get_list`, `get_lists` |
| `create_starter_pack`, `set_list_opt_out`, `update_starter_pack`, `delete_starter_pack` | `get_starter_pack`, `get_list` |
| `save_feed`, `unsave_feed` | the account's preferences, read from the PDS |
| `set_preference` (each preference kind; `discoverable`, `activity_subscriptions`) | `get_preferences`, the preferences read from the PDS, `get_record`, another account's `get_profile` |
| `set_notification_setting` | `get_notification_settings` |
| `subscribe_to_activity` | `get_profile`, `get_activity_subscriptions` |
| `like` by another account, `unlike` | `get_notifications` with `grouped` |
| `save_draft`, `delete_draft` | `get_drafts` |

What it cannot do locally:

- `feed_feedback` reaches only its refusal: dev-env's feed generator does not
  accept interactions or serve `sendInteractions`, and nothing reads feedback
  back.
- A compare-and-swap that loses a race cannot be provoked through a tool, so
  the suite writes over a stale record and a stale commit directly and checks
  the reference PDS refuses both with the `InvalidSwap` AtMcp recognizes.
- dev-env is Bluesky's AppView, so only the `app.bsky` namespace runs here; the
  delve.town-only reads (`get_membership`, `get_invite_codes`) and that
  network's own AppView are not covered.

### Check a live account

Fixtures prove mechanics; only a live service shows the contract it serves.
Read-only, against a running shared service:

```sh
MCP_CLIENT_PATH="$probe_dir/node_modules/@modelcontextprotocol/client" \
  AT_MCP_GRANT="$(at_mcp-accounts connection NAME | jq -r '.mcp.headers[0].value' | cut -d" " -f2)" \
  node scripts/live_contract_check.mjs \
  /path/to/release/bin/at_mcp-connect http://127.0.0.1:4400/mcp did:plc:...
```

It checks that every tool advertises its output schema, that structured content
matches the text on real responses (its JSON, or for reads made of posts a text
naming every post), and that refusals arrive as codes. It
calls no write tool.

`scripts/pds_read_probe.exs` logs into an authorized account with writes
disabled and reads its profile; set the account credentials, `AT_MCP_SERVICE`
and `EXPECTED_DID` (and `_2` values for a second account), then
`MIX_ENV=test mix run --no-start scripts/pds_read_probe.exs`.

### What counts as evidence

A claim is established when a test fails if you revert the change that makes
it true. Use a focused test while changing behavior and the full check before
landing. Test the observable contract — selected identity, accepted activity,
returned result, durable recovery — rather than prose or private structure.
Where a check cannot run without credentials, a network or a machine, say so
in the test with `@tag skip:` and a reason, and give the `test` job in
`check.yml` its environment so the gap is visible in CI rather than in a document. When a live
check finds what a fixture missed, write the test that fails without the fix,
and record the scope of what was run in the pull request.

## Publish a release

This is a maintainer action, not an installation step. One tag publishes both
the GitHub binary release and the Hex package. The previous-release CI
check uses the newest eligible published release, or the explicit historical
Kite baseline described below when there is no eligible predecessor. That
baseline must be available in this public repository; no private Git history
is required. Do not skip the check or use a rebuilt candidate as its own
previous release.

Pushing a version tag publishes one; a merge to `main` does not. The tag is
the version: nothing in the repository changes to cut a release. Tag a commit
of `main` whose run of `check` passed in the merge queue or on main, with `v`
and the version (for 0.3.0):

```sh
git tag -a v0.3.0 -m "AtMcp 0.3.0" origin/main && git push origin v0.3.0
```

(`origin/main` after a `git fetch`; any older commit of main that passed works
too.) CI refuses a tag that is not `vX.Y.Z`, or whose commit is not on main or
has no passing run of `check` there, before anything is built
(`scripts/release_version.sh`). It then builds and tests the tagged commit as
that version (`RELEASE_VERSION`, which `mix.exs` reads), builds the Linux and
macOS releases, and publishes only after both platforms pass. Publication
requires both exact-version tarballs and their checksum files; a partial
platform build does not create or replace a release. Once the GitHub release
is published, CI writes the version into the package's `VERSION` file and
publishes the package and its docs to Hex with `mix hex.publish`, using the
`HEX_API_KEY` secret in the repository's `hex` environment.

When a tag's run does not finish:

- Refused, or failed before `publish`: nothing was published. Delete the tag
  (`git push origin :refs/tags/v0.3.0`) and tag again.
- `publish` succeeded and `hex` failed: re-run the failed `hex` job
  (`gh run rerun RUN --failed`); the GitHub release stands.
- Never reuse a version that reached the GitHub release or Hex: a server may
  have fetched it, and Hex keeps it. Fix on main and tag the next patch.

The tag check also refuses a version that is not the next patch, minor or
major after the newest release tag (after v0.2.11: v0.2.12, v0.3.0 or
v1.0.0), so a typo cannot publish.

Upgrade notes are not a release step. A pull request that changes what an
upgrade needs, or what an operator sees, adds its note under
[Upgrade](#upgrade) in that same pull request, in a section headed
`From A to the next release`, A being the newest release; the first pull
request after a release renames that heading to the version it shipped as.

## Bootstrap a fresh public repository

This is release preparation for maintainers. It does not publish anything by
itself. A fresh source snapshot has no previous release, and its Git history
must not be populated with the private Kite history just to satisfy upgrade CI.

`scripts/legacy_baseline.json` names a specific historical Kite 0.1.2 build and
pins each platform's notice-complete archive. The repack adds notices and
`BASELINE_PROVENANCE.json`; it preserves every original file's bytes, mode and
symlink target. The archives have new names and new SHA-256 values. Original
release checksums describe only the original archives, never the repacks.

Prepare each repack privately using its genuine original archive and a reviewed
notice tree containing `LICENSE` and `licenses/`. The tree must include the
actual old dependency and runtime versions, rather than today's build's notices:

```sh
python3 scripts/repack_legacy_baseline.py linux-x86_64 ORIGINAL NOTICE_TREE OUTPUT
```

Repeat for `macos-arm64`, review both outputs against the manifest, and run the
usual default-path and upgrade/rollback checks on the repacked old release.
The repack command verifies original hashes and preserves original contents;
it does not establish that a supplied notice tree is complete. Notice review
and the release-notice verifier are separate requirements.

After publication approval, the order is:

1. Create the empty public repository and push the reviewed single-root source
   snapshot to `bootstrap`. The workflow runs pushes to `main`, not this branch.
2. Create `legacy-kite-v0.1.2` in that same repository as a **prerelease**, with
   **latest disabled**, containing both manifest-named repacks and their new
   checksum files. Target the new root commit. State in its release notes that
   the binaries come from historical source `40a969a`, not from the tag's new
   root; only notices and provenance were added. This tag does not match the
   workflow's automatic `v*` publication trigger.
3. Verify unauthenticated downloads against the committed archive digests and
   exact historical `BUILD`, then push the same root to `main` and make it the
   default branch. The first main-branch CI run can now exercise a real
   old-to-new upgrade without private GitHub access.
4. Require green release CI before the separately approved application tag or
   Hex publication. Creating the legacy baseline does not publish `at_mcp`.

The ordinary newest eligible release always takes precedence. Only when there
is no eligible predecessor does the selector use this explicit baseline. Missing
assets, altered checksums, an unexpected `BUILD`, or the candidate serving as its
own baseline fail the gate. A failure fetching an ordinary predecessor never
silently chooses the baseline instead. Keep this exceptional path only while
Kite-to-at_mcp remains a supported first upgrade.
