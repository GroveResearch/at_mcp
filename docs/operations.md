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

The URL belongs to the receiving application (Dwell accepts into its
resident's work queue). The token is re-read for every delivery, so rotation
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
matches the JSON text on real responses, and that refusals arrive as codes. It
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

Pushing a version tag publishes one; a merge to `main` does not. A release is
its version: bump `version:` in `mix.exs` in a pull request and merge it,
then tag that commit of `main` with `v` and the version (for 0.3.0):

```sh
git tag v0.3.0 && git push origin v0.3.0
```

CI tests the tagged commit, refuses a tag that is not `v` + the version in
`mix.exs`, builds the Linux and macOS releases, and publishes only after both platforms
pass. Publication requires both exact-version tarballs and their checksum files;
a partial platform build does not create or replace a release. Once the GitHub
release is published, CI publishes the package and its docs to Hex with
`mix hex.publish`, using the `HEX_API_KEY` secret in the repository's `hex`
environment.

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
