# Operating at_mcp

This guide is for people who run at_mcp for a while: a shared service that
several MCP clients use, that serves several accounts, or that collects
incoming activity and sends it to another program. It also covers settings,
upgrades and rollback for any installation. To connect one agent to one
account, the [README](../README.md) is enough. Building and testing at_mcp is in
[CONTRIBUTING.md](../CONTRIBUTING.md).

## Run a shared service

Download and check a release as the README's
[Fetch a release](../README.md#fetch-a-release) says. On a Mac, install it as
the README does. For the Linux service, run the following in place of the
README's install block, in the same terminal so the download variables are
still set. Root owns the executables, so the service user cannot rewrite them.
To install a release you built from source, follow
[Build a release](../CONTRIBUTING.md#build-a-release) in CONTRIBUTING.md and
skip this block.

```sh
AT_MCP=/opt/at_mcp
sudo mkdir -p "$AT_MCP/releases" &&
  sudo tar --no-same-owner -xzf "$DOWNLOAD/$TARBALL" -C "$AT_MCP/releases" &&
  sudo ln -sfn "releases/at_mcp-$VERSION" "$AT_MCP/current"
```

Run a shared service when several clients share an account, or when another
program should receive the account's incoming activity. `bin/at_mcp start` runs
the service in the foreground, and systemd or launchd keeps it running.

Each client of a shared service holds a grant: a token that at_mcp issues and
the client sends with every request. The grant decides which account the
client acts as and its scope, meaning which tools the client may call (`read`,
`write` or `manage`). [Issue a connection](#issue-a-connection) explains both.

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

### The environment file

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
  127.0.0.1 only; no port mapper (epmd) is needed. 4370 is the default.
- `AT_MCP_PORT` is the one loopback MCP endpoint every client reaches
  (`http://127.0.0.1:4400/mcp`); the grant a client presents selects the
  account.
- To deliver incoming activity to another program, set `AT_MCP_DELIVERY_URL`
  to the address it receives on and `AT_MCP_DELIVERY_TOKEN_FILE` to a file
  holding its token, readable by the service
  ([Incoming activity](#incoming-activity)). `AT_MCP_NETWORK=delve` serves
  Delvetown accounts. [Settings](#settings) lists every variable.

A second installation on the same machine, such as one per network, is a
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

## Settings

AtMcp reads these environment variables when it starts, and no others. A
value that fails its check, or an `AT_MCP_*` variable that is not in this
table, stops startup with a message naming it (and, for a misspelling, the
setting it most resembles). An empty value is the same as unset. A stdio
client sets them in its MCP configuration; a shared service sets them in its
[environment file](#the-environment-file).

| Variable | Default | Meaning |
| --- | --- | --- |
| `AT_MCP_HANDLE` | none | The account's handle: the stdio client's account, or the first account a shared service writes into a missing accounts file |
| `AT_MCP_APP_PASSWORD` | none | That account's app password (secret) |
| `AT_MCP_SERVICE` | the network's own PDS: `https://bsky.social` on Bluesky, `https://pds.delve.town` on Delvetown | That account's home PDS, an `http(s)` URL |
| `AT_MCP_HANDLE_2`, `AT_MCP_APP_PASSWORD_2`, `AT_MCP_SERVICE_2` | none | A second account for a shared service's missing accounts file |
| `AT_MCP_NETWORK` | `bluesky` | `bluesky` (`app.bsky.*`) or `delve` (`town.delve.*`) |
| `AT_MCP_APPVIEW_READS` | `proxy` | `proxy`, or `direct` for the experimental [direct authenticated reads](#direct-authenticated-reads-experimental) |
| `AT_MCP_STATE_DIR` | the per-user data directory (`at_mcp/inbound` under it; stdio adds a directory per account) | Durable state: write quotas, delivery queue, checkpoints. One process per directory |
| `AT_MCP_ACCOUNTS_FILE` | `accounts.json` in the per-user configuration directory | A shared service's accounts file; the grants file is kept beside it |
| `AT_MCP_PORT` | `4400` | A shared service's one loopback MCP endpoint, a port from 0 to 65535 |
| `AT_MCP_CONTROL_PORT` | none (no listener) | A shared service's operator listener for identity discovery |
| `AT_MCP_DIST_PORT` | `4370` | Where a shared service listens for operator commands, on 127.0.0.1 |
| `AT_MCP_WRITE_LIMIT` | `16` | Publishing writes each account may attempt per window, unless the account sets its own; a positive integer |
| `AT_MCP_WRITE_WINDOW_SECONDS` | `3600` | Length of the write quota window, unless the account sets its own; a positive integer |
| `AT_MCP_NOTIFICATIONS` | `1` | `1`/`true` or `0`/`false`: a shared service polls each account's notifications |
| `AT_MCP_NOTIFICATIONS_INTERVAL_SECONDS` | `60` | Seconds between notification sweeps of each account; a positive integer |
| `AT_MCP_JETSTREAM` | `0` | `1`/`true` or `0`/`false`: the network-wide stream collector |
| `AT_MCP_INBOUND_MAX_EVENTS` | `10000` | Undelivered events held for one account before its collection pauses; a positive integer |
| `AT_MCP_INBOUND_MAX_BYTES` | `67108864` (64 MiB) | Size of the delivery store; one account may fill a quarter of it. A positive integer |
| `AT_MCP_IMAGE_MAX_BYTES` | `2000000` | The largest picture `get_post_images` returns, in bytes; a positive integer |
| `AT_MCP_IMAGE_FETCH_SECONDS` | `10` | How long `get_post_images` waits for all of one post's pictures; a positive integer |
| `AT_MCP_MEDIA_DIR` | none (off) | A directory whose image files `post`, `reply` and `update_profile` may read when an image gives a `path` instead of base64 `data`. Only regular files inside it, at most the network's post image size. Every account the process serves reads the same directory |
| `AT_MCP_DELIVERY_URL` | none (no delivery) | Where a shared service delivers collected activity, an `http(s)` URL |
| `AT_MCP_DELIVERY_TOKEN_FILE` | none | A file holding the consumer's bearer token, read at each delivery so a rotated token takes effect |
| `AT_MCP_DELIVERY_TOKEN` | none | The bearer token itself (secret), instead of the file |
| `AT_MCP_GRANT` | none | The grant `at_mcp-connect` presents to a shared service (secret) |
| `AT_MCP_ENV_FILE` | none | For a command run from a shell: the environment file to load first |
| `AT_MCP_STDIO_ENV_FILE` | none | For `at_mcp-stdio`: an environment file holding its settings |

`BLUESKY_HANDLE`, `BLUESKY_APP_PASSWORD` and `BLUESKY_SERVICE` (and `_2`), older
names for the account variables, still work with a warning; the new name wins
when both are set.

The accounts file says which accounts an installation serves. The
environment sets where things are and what is switched on. To print what a
running service has, with each value's source (secrets show only as set or
unset):

```sh
export AT_MCP_ENV_FILE=~/at_mcp/at_mcp.env
~/at_mcp/current/bin/at_mcp rpc 'AtMcp.CLI.settings()'
```

On Linux, as with `at_mcp-accounts`:
`cd / && sudo -u at_mcp env AT_MCP_ENV_FILE=/etc/at_mcp/at_mcp.env /opt/at_mcp/current/bin/at_mcp rpc 'AtMcp.CLI.settings()'`.
`bin/at_mcp eval 'AtMcp.CLI.settings()'` prints what a process would start with
in the current environment.

The release itself reads two more: `RELEASE_COOKIE`, the cookie the operator
commands present (set one per installation, since a published release's own is
readable by anyone who downloads it), and `RELEASE_NODE`, the service's Erlang
node name. A second installation on one machine needs its own node name. A
name without a host is given `@localhost`, or `@127.0.0.1` under
`RELEASE_DISTRIBUTION=name`; a host it names must resolve to loopback.

`.env.example` is the template for the environment file.

On first run, an installation with
`AT_MCP_HANDLE` and `AT_MCP_APP_PASSWORD` set (and optionally the `_2` pair and
`AT_MCP_SERVICE`) and no accounts file
writes itself one at startup, naming the accounts `default` and `second`. This
happens once; with a file present these variables are not consulted, and
changing them afterwards does nothing.

`AT_MCP_NETWORK` applies to the whole installation, so
reaching Bluesky and Delvetown at once is two services, each with its own
unit, environment file, accounts file, `AT_MCP_STATE_DIR`, ports and
`RELEASE_NODE` ([The environment file](#the-environment-file)). Two releases
with the same node name or distribution port cannot both run.

## Accounts and operator commands

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

### An account's own write limit

Each account's publishing writes (posts, replies and reposts) are limited per
window. `AT_MCP_WRITE_LIMIT` and `AT_MCP_WRITE_WINDOW_SECONDS` (16 per 3600
seconds) are the limit for every account that does not set its own. Accounts
on one service are often different agents with different needs, so an account
can have its own:

```sh
at_mcp-accounts write-quota grug --limit 40 --window-seconds 3600
at_mcp-accounts write-quota reader --limit 4
at_mcp-accounts write-quota grug --default
at_mcp-accounts reload
```

The limit is saved as an optional `write_quota` field on the account in the
accounts file (`{"limit": 40, "window_seconds": 3600}`), and `list` shows it.
Each command replaces the account's whole limit: a value it does not give
(`--window-seconds` above, for `reader`) is the service's, and `--default`
removes the field, so the account uses the service's limit and window again.
Values are positive integers. `reload` applies the change by replacing that
account, as it does for any changed account; other accounts keep running.

The count belongs to the account's DID and survives the change. A new limit
applies to the window already open, so lowering it below what the account has
used in that window refuses its writes until the window ends. A shorter window
applies to the open one too: it ends that much sooner after it opened (a day's
window opened an hour ago, cut to an hour, ends now). A longer window applies
from the next window. `identity_status` reports the limit and window the
account is held to, with its usage and the time the open window ends.

### Replace an app password

An app password is the account's credential at its PDS. Three other things
look like credentials but are not it. The saved copy of the password in the
accounts file belongs to AtMcp. A grant is how an MCP client reaches the
service, and grants stay valid when the password changes. `remove` and
`disconnect` stop AtMcp using the account. Replacing the password means
writing the new one where AtMcp reads it, checking that AtMcp is using it,
then revoking the old one at the PDS.

1. Create a new app password in the account's settings at its home provider
   (on Bluesky, Settings, then Privacy and security, then App passwords). Keep the
   old one for now.
2. Save it, then apply it:

   ```sh
   at_mcp-accounts update grug        # asks for the new app password
   at_mcp-accounts reload
   ```

   `update` logs in with the new password and checks it reaches the saved DID
   before saving it. If the login fails, or reaches another DID, the file is
   unchanged. `reload` replaces the account, and the account must be reported
   `"status": "ready"`. `unavailable` means the new login failed, and `reload`
   exits nonzero. Restarting the service applies the file too.
3. Check: `at_mcp-accounts status` shows the account with `"ready": true`
   and its usual `did`.
4. Revoke the old app password at the provider (on Bluesky, delete it from the
   same list), then run `status` again. AtMcp is using the new password if the
   account is still `ready`.

The environment file's `AT_MCP_HANDLE` and `AT_MCP_APP_PASSWORD` are read once, to write an accounts file when none exists.
After that, changing them changes nothing. Clients attached through
`at_mcp-connect` or HTTP hold a grant, not the password, so they need no
change. To also cut off a client, revoke its grant (`at_mcp-accounts revoke`,
above). That does not touch the app password.

For an `at_mcp-stdio` that an MCP client starts, follow
[Replace the app password of a stdio client](#replace-the-app-password-of-a-stdio-client).

`status`, `reload`, `disconnect` and `reconnect` reach the running service over
the release's Erlang distribution, which listens on 127.0.0.1 only, at
`AT_MCP_DIST_PORT`, with no port mapper (epmd). They reach it when
`AT_MCP_ENV_FILE` names the service's environment file, which carries its
cookie, port and node name.

### Replace the app password of a stdio client

For a client-launched `at_mcp-stdio`, the app password is wherever the client
configuration puts `AT_MCP_APP_PASSWORD`. The client passes it to each
`at_mcp-stdio` it starts, and AtMcp saves no copy.

1. Create a new app password at the account's provider. Keep the old one for
   now.
2. Put it in `AT_MCP_APP_PASSWORD`. If `AT_MCP_STDIO_ENV_FILE` names a file
   that sets it, change it in that file: the file's values override the
   client's `env`, so changing the client's `env` alone has no effect.
3. Restart the MCP server from the client (in Claude Code, `/mcp`, or a new
   session). Call `identity_status`: it should show `"logged_in": true` and
   the account's usual `did`. If the new password is wrong, the server does
   not start, and its stderr says "AtMcp could not log into this account".
4. Revoke the old app password at the provider, then call `identity_status`
   again. AtMcp is using the new password if it still shows `"logged_in": true`.

A shared service keeps the password in its accounts file instead
([Replace an app password](#replace-an-app-password)).

A client that starts `at_mcp-stdio` can call every tool, including publishing,
profile changes and deletion. To give a client fewer tools, attach it to a
shared service with a grant ([Issue a connection](#issue-a-connection)). The
client's own tool approvals are separate from at_mcp's write quota.

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
Claude Code requires a headers object, so put the returned values into a
private `mcp.json` file in this shape (do not paste the headers array):

```json
{"mcpServers":{"at_mcp":{"type":"http","url":"http://127.0.0.1:4400/mcp",
 "headers":{"authorization":"Bearer YOUR_RETURNED_GRANT",
            "x-kite-account-did":"YOUR_RETURNED_DID"}}}}
```

Start it with `claude --mcp-config /absolute/path/to/mcp.json --strict-mcp-config`.
The README's [Connect Claude Code](../README.md#connect-claude-code) covers the rest of the setup.

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

The environment destination above is a single consumer for every account.
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
same names, and only when the delivered record is itself a post, that is,
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
self-reference: a record naming its own `uri` as its parent or its root has
that ref dropped, so `thread_parent_uri` never equals `uri`.

`subject_uri` is the record a like, a repost or a quote addresses: the liked or
reposted post, or the quoted post. Both collectors send it: the notifications
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

## Direct authenticated reads (experimental)

This is an experiment. It may change or go away in a later release.

From 0.2.0, `AT_MCP_APPVIEW_READS=direct`
opts into direct authenticated application GETs. The default remains `proxy`.
Use this only when the home PDS supports `com.atproto.server.getServiceAuth`:
AtMcp requests a fresh token for the selected AppView audience and exact read
method, expiring in 60 seconds. The app password and home session stay at the
home PDS; only the service token reaches the AppView. Neither HTTP request follows
redirects or uses transport retries. Home-session credential recovery remains
unchanged. A denied or missing token stops the read.
HTTP 501 alone never selects this route.

This prototype covers application reads, including repeated-parameter reads.
Preferences, which the PDS keeps, are still read from the home PDS. Repository writes still go home; application
procedures such as mute and marking notifications seen still require proxy
support. With it, an account on a PDS that refuses to proxy still cannot do everything.
AppView token refusal does not trigger home-session recovery.

Endpoints are fixed in `AtMcp.Network`, paired with the selected service DID:
`https://api.delve.town/xrpc` and `https://api.bsky.app/xrpc`. These match the
respective [Delvetown DID document](https://api.delve.town/.well-known/did.json)
and [Bluesky DID document](https://api.bsky.app/.well-known/did.json) service
entries; the prototype does not discover endpoints or accept arbitrary URLs.
The [XRPC service-auth contract](https://atproto.com/specs/xrpc#inter-service-authentication-jwt)
binds the token to an audience and method. Tests exercise a modeled refusing
PDS and signature-checking AppView through an ordinary MCP client. They do not
establish compatibility with every real provider.

## When something goes wrong

- The stdio command waits silently: an MCP client must start it and talk MCP
  over stdin and stdout. Its messages go to stderr.
- The state directory is already in use: another at_mcp process holds it. Close that
  client or share one service; do not create extra state directories to bypass
  a write quota.
- Login fails: check handle, app password and PDS URL. The PDS URL is where
  the account is hosted, not its profile page. The account's DID document
  lists it as the [`#atproto_pds` service](https://atproto.com/specs/did#did-documents). The service's
  `AT_MCP_ENV_FILE` and a stdio client's `AT_MCP_STDIO_ENV_FILE` are separate. In
  the shared service a PDS that did not answer is retried on its own; a refused
  credential is in the service log, and `at_mcp-accounts status` shows the account
  configured and not running until it is reconnected or reloaded.
- The write quota is used up: `identity_status` reports the reset time.
  Restarting clients does not replenish it.
- A write timed out: it may have reached the PDS. Check the account before
  creating again.
- State cannot be read: AtMcp refuses damaged state rather than resetting
  policy. Preserve the directory and read the diagnostics; do not delete it to
  make startup succeed.
- Startup reports `delivery_bridge_unready`: delivery is configured but no
  collector is enabled.
- An inbound event is delayed: check the account is connected, collection
  is enabled, the consumer routes that DID, and the destination is not paused.
  Accepted work stays queued through consumer outages.

A tool call that cannot complete says which of three things happened:

- Refused: the action did not happen. Read the reason before changing the
  request. A quota refusal says when capacity returns.
- Credential refused: at_mcp may recover the session and try once more. A
  login refused again needs a valid app password for the same account.
- Unknown outcome: the write may have gone through although no answer arrived.
  at_mcp reports `outcome: "unknown"` and never retries it. Read the account
  before creating anything again.

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

This release changes no local stored data and AtMcp keeps no copy of it.
Version 0.2.14 added an optional field to the accounts file, which older
releases refuse; its section below says what to remove before rolling back. CI's upgrade check writes to
each of these under the older release and the newer one and reads them back
under the other, so it fails when a release changes one. A release that
changes the format will copy what it changes when it starts, and say here how
to put the copy back.

### From 0.2.15 to the next release

`update_profile` takes `labels`, the labels the account gives itself, such as
`bot` for an automated account. A list replaces the labels the account has,
`[]` removes them, and leaving `labels` out keeps them. On Bluesky they go on
the account's profile record. On Delvetown they go on the profile record that
Bluesky reads, `app.bsky.actor.profile`, and only its `labels` field changes.
If the account has no such record, at_mcp creates one holding only the labels.
When a call gives profile fields and labels together, both change or neither
does. The result lists the labels written. at_mcp refuses more than 10 labels,
an empty or repeated one, or one longer than 128 bytes, before it sends
anything.

### From 0.2.14 to 0.2.15

This release changes no local stored data.

- On Delvetown, `follow` and `block` write the same follow and block records
  Bluesky uses, for every account. `unfollow` and `unblock` remove that record
  and any older Delvetown-only record for the same account together. If the
  account's repository changes before they finish, they refuse and remove
  nothing. A record that is already gone reports nothing deleted.
- On Delvetown, `update_profile` saves the account's whole Delvetown profile,
  including fields left empty on purpose, and leaves its Bluesky profile and
  its labels as they were. A first edit that gives only some fields keeps the
  avatar and the banner the account shows.
- An embedding application reads that same profile with
  `AtMcp.Effects.get_own_profile/1`. Upgrade it to the 0.2.15 Hex package
  before switching its running release.

Do not roll a Delvetown installation back to 0.2.14. Its `update_profile` can
change the account's Bluesky profile, and its `follow` and `block` depend on a
Delvetown account check that 0.2.15 no longer makes.

### From 0.2.13 to 0.2.14

The accounts file changes only if you give an account its own write limit.
The write quota file also records when each account's window opened, a field
0.2.13 reads past.

- On Delvetown, before it writes a profile, a follow or a block, 0.2.14 asks
  Delvetown (`town.delve.identity.getState`) whether the account uses the
  profile, follow and block records Bluesky uses. If Delvetown does not
  answer, the write stops before anything is sent. Releases before 0.2.14 do
  not ask, and can report success for writes that no longer change such an
  account. Installing this release changes no account.

- Each account can have its own write limit (#159):
  `at_mcp-accounts write-quota NAME --limit N [--window-seconds S]`, then
  `reload` ([An account's own write limit](#an-accounts-own-write-limit)). It
  is saved as an optional `write_quota` field on that account in the accounts
  file. An account without one keeps `AT_MCP_WRITE_LIMIT` and
  `AT_MCP_WRITE_WINDOW_SECONDS`, so upgrading changes no account's limit until
  you set one. Embedding hosts pass `write_limit:` and `write_window_seconds:`
  to `AtMcp.Identities.start_identity/1`.

  Rolling back after setting one needs one step first. 0.2.13 and older
  refuse an accounts file holding a field they do not know: the service does
  not start (its log ends with `AtMcp account configuration:
  :config_corrupt`), and their `at_mcp-accounts` refuses the file too, so it
  cannot take the field out. Before rolling back, while the newer release is
  still installed, run `at_mcp-accounts write-quota NAME --default` for every
  account that has a `write_quota` (`list` shows them), then `reload`; the
  accounts then use the service's limit, as 0.2.13 does. If you have already
  rolled back, put the newer release back and do this, or delete each
  `"write_quota"` entry from the accounts file by hand. A service that never
  ran `write-quota` rolls back as before. CI's upgrade check takes this step.

- An embedding host can post text exactly as given (#163):
  `AtMcp.Effects.post(effects, text, facets: :none)`, and the same option on
  `AtMcp.Effects.reply/4`, write a record whose `text` is the text given, byte
  for byte, with no `facets`: no handle is resolved, and nothing in the text
  becomes a mention, a link or a tag, so nobody it names is notified. This is
  for a program that quotes text it did not write. Without the option, or
  with `facets: :detect`, posts are built as before; any other value is
  refused as an invalid argument before anything is sent or counted. Replies,
  quotes and link cards (`link:`, which is given, not detected) work as
  without it; a `reply_rule` of `"mentioned"` then lets nobody in by mention,
  since the post mentions nobody. The MCP `post` and `reply` tools do not take
  it: the app publishes facets detected from the text, and the tools offer
  what the app does.

- A grouped read's reply, quote or mention carries its post whole (#139):
  each entry of its `posts` has a `post` holding the post as `get_posts`
  reads one (time, counts, attachments, labels, this account's like, repost
  and bookmark), without `moderation` marks, and the text a model reads
  shows it as any read shows a post. Other groups' `post` is null.

- Reads carry the labels of the labelers the account subscribes to (#83):
  every read sends `atproto-accept-labelers` as the app does, so posts and
  accounts carry labels from those labelers, not only from the network's own.
  An account's first read after a start reads its preferences first.

- A post whose text holds an escaped `<` or backslash (#147) reads, in the
  text a model reads, with one line under it saying that `\<` and `\\` are
  the author's `<` and `\`, and that an unescaped `<…>` is where a link or
  mention points.

### Older releases

[docs/upgrades.md](upgrades.md) keeps the notes for 0.1.3 through 0.2.13.

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
