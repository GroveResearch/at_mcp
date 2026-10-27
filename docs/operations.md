# Running at_mcp as a service

The [quick start](../README.md#quick-start) runs at_mcp inside a single MCP
client, for a single account. This guide covers the other arrangement: at_mcp
running as a long-lived service on a machine, under systemd on Linux or
launchd on a Mac. Run a service when you need any of these:

- several MCP clients sharing an account, with a shared write quota
- several accounts served from a single installation
- each client limited to the tools for its job, such as reading only
- an account's notifications passed to another program as they arrive
  ([delivery.md](delivery.md))

Each client of a service holds a grant, a secret token issued by at_mcp for a
single account. The client sends the grant with every request, and at_mcp
uses it to pick the account and the set of tools the client may call.

## Install

On a Mac, install a release with the README's
[Fetch a release](../README.md#fetch-a-release) block. On Linux, run this
block. It installs the latest release under `/opt/at_mcp`, owned by root, so
the service's own user has no way to change the program it runs.

```sh
VERSION=$(curl -fsSLo /dev/null -w '%{url_effective}' https://github.com/GroveResearch/at_mcp/releases/latest | sed -n 's|.*/tag/v||p')
PLATFORM=linux-x86_64
AT_MCP=/opt/at_mcp
BASE_URL=https://github.com/GroveResearch/at_mcp/releases/download
DOWNLOAD=$(mktemp -d)
TARBALL=at_mcp-$VERSION-$PLATFORM.tar.gz
test -n "$VERSION" &&
  curl --fail --location "$BASE_URL/v$VERSION/$TARBALL" -o "$DOWNLOAD/$TARBALL" &&
  curl --fail --location "$BASE_URL/v$VERSION/$TARBALL.sha256" -o "$DOWNLOAD/$TARBALL.sha256" &&
  (cd "$DOWNLOAD" && sha256sum -c "$TARBALL.sha256") &&
  sudo mkdir -p "$AT_MCP/releases" &&
  sudo tar --no-same-owner -xzf "$DOWNLOAD/$TARBALL" -C "$AT_MCP/releases" &&
  sudo ln -sfn "releases/at_mcp-$VERSION" "$AT_MCP/current"
```

Then create a system user for the service:

```sh
sudo useradd --system --home-dir /var/lib/at_mcp --shell /usr/sbin/nologin at_mcp
```

The example service files in the release expect these locations:

| | Linux | Mac |
| --- | --- | --- |
| Releases, and `current` pointing at the active one | `/opt/at_mcp` | `~/at_mcp` |
| Environment file | `/etc/at_mcp/at_mcp.env` | `~/at_mcp/at_mcp.env` |
| State folder, holding accounts, grants and stored data | `/var/lib/at_mcp` | `~/at_mcp/state` |
| Logs | the systemd journal | `~/Library/Logs/AtMcp/at_mcp.log` |

On a Mac, create the state and log folders, readable by you alone:

```sh
mkdir -m 700 -p ~/at_mcp/state ~/Library/Logs/AtMcp
```

On Linux, systemd creates `/var/lib/at_mcp` with the right permissions when
the service first starts.

## The environment file

The service takes its settings from an environment file. The file holds
secrets, so create it empty with tight permissions before writing anything in
it:

```sh
# Linux
sudo mkdir -p /etc/at_mcp && sudo install -m 640 -g at_mcp /dev/null /etc/at_mcp/at_mcp.env
# Mac
install -m 600 /dev/null ~/at_mcp/at_mcp.env
```

Then fill it in. On Linux:

```sh
AT_MCP_ACCOUNTS_FILE=/var/lib/at_mcp/accounts.json
AT_MCP_STATE_DIR=/var/lib/at_mcp
RELEASE_COOKIE=paste-the-output-of-openssl-rand-hex-32
AT_MCP_DIST_PORT=4370
AT_MCP_PORT=4400
```

On a Mac, write the paths out in full, such as
`/Users/you/at_mcp/state/accounts.json`, because launchd leaves `~`
unexpanded.

Write each line as `NAME=value`, without `export`. Put double quotes around a
value containing a space. Leave out `$`, backslashes and backticks, so that
systemd, the launchd wrapper and at_mcp's own commands all read the file the
same way.

`RELEASE_COOKIE` is the password for operator commands such as
`at_mcp-accounts`. Every published release carries a default cookie, readable
by anyone with the download, so set your own with `openssl rand -hex 32`. The
service and its commands refuse to run with an empty cookie. The cookie
goes on the service's command line, where other local users could read it.
On a machine with other login users, mount `/proc` with `hidepid=invisible`
to hide it from them.

[settings.md](settings.md) lists every other variable. For notifications, add
the delivery settings described in [delivery.md](delivery.md).

## Start the service

The release includes example service files under `examples/`. On Linux:

```sh
sudo cp /opt/at_mcp/current/examples/at_mcp.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now at_mcp
journalctl -u at_mcp -f
```

On a Mac:

```sh
mkdir -p ~/Library/LaunchAgents
sed "s|/Users/you|$HOME|g" ~/at_mcp/current/examples/li.example.at_mcp.plist \
  > ~/Library/LaunchAgents/li.example.at_mcp.plist
launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/li.example.at_mcp.plist
tail -f ~/Library/Logs/AtMcp/at_mcp.log
```

systemd restarts the service after a failure. launchd starts it at login and
restarts it after an exit with an error. To stop it, run
`sudo systemctl stop at_mcp` on Linux or
`launchctl bootout "gui/$(id -u)/li.example.at_mcp"` on a Mac.

## Add accounts

`at_mcp-accounts` manages the service's accounts. It reads the environment
file given in `AT_MCP_ENV_FILE` and talks to the running service over
127.0.0.1. On a Mac:

```sh
export AT_MCP_ENV_FILE=~/at_mcp/at_mcp.env
~/at_mcp/current/bin/at_mcp-accounts add grug --handle grug.example
~/at_mcp/current/bin/at_mcp-accounts reload
~/at_mcp/current/bin/at_mcp-accounts status
```

On Linux, run each command as the service's user, from a folder that user can
read:

```sh
cd / && sudo -u at_mcp env AT_MCP_ENV_FILE=/etc/at_mcp/at_mcp.env /opt/at_mcp/current/bin/at_mcp-accounts status
```

The rest of this guide writes `at_mcp-accounts` for short. Put the same prefix
in front of each command.

`add` asks for the app password, logs in to check it, and saves the account
under the local name you gave, `grug` here. To pipe the password in from a
script, add `--password-stdin`. at_mcp never takes a password as a
command-line argument. For an account hosted outside the network's own
server, add `--service URL`. `reload` tells the running service to start any
new accounts, and `status` shows each account's state. `list` shows the saved
configuration without asking the service.

The accounts file holds app passwords, so at_mcp writes it with mode 600.

## Connect a client

To issue a grant for a client, run:

```sh
at_mcp-accounts connection grug
```

The command prints a JSON object. Its `mcp` field gives the details a client
needs: the URL `http://127.0.0.1:4400/mcp`, an `Authorization: Bearer` header
carrying the new grant, and a header with the account's DID. at_mcp stores
only a hash of each grant, so copy the grant now, because nothing can print it
again.

Claude Code takes these values in an `mcp.json` file like this one, with your
grant and DID filled in:

```json
{"mcpServers": {"at_mcp": {
  "type": "http",
  "url": "http://127.0.0.1:4400/mcp",
  "headers": {"authorization": "Bearer YOUR_GRANT",
              "x-at-mcp-account-did": "YOUR_ACCOUNT_DID"}}}}
```

Start Claude Code with `claude --mcp-config /path/to/mcp.json
--strict-mcp-config`, then ask the agent to call `identity_status` and check
the handle.

For a client limited to stdio, add `--transport stdio` to the `connection`
command. The client then runs `at_mcp-connect`, which carries the grant in
`AT_MCP_GRANT` and passes the client's requests to the service. Clients on
HTTP and on stdio share the account's session and write quota.

### Limit a client's tools

Every grant has a scope, set with `--scope` when you issue it:

| Scope | Tools allowed |
| --- | --- |
| `read` | reads only |
| `write` | reads, plus writes adding to the account, such as posting, following or editing the profile |
| `manage` | every tool, including deleting, unfollowing, blocking, muting and changing settings. This is the default. |

```sh
at_mcp-accounts connection grug --scope read
```

A client sees only the tools in its scope, and at_mcp refuses calls to any
others. [tools.md](tools.md) gives the scope of each tool.

A grant works like a password on the local machine. Any process able to read
a client's configuration can use its grant, so keep those files private.

### Revoke a grant

```sh
at_mcp-accounts grants
at_mcp-accounts revoke GRANT_ID
```

The client loses access on its next request. at_mcp keeps grants in
`accounts.grants.json` next to the accounts file. Deleting that file revokes
every grant and leaves the accounts in place. Removing an account revokes its
grants.

## Change accounts

```sh
at_mcp-accounts update grug        # new password, or --handle, --service
at_mcp-accounts remove reader
at_mcp-accounts reload
```

`update` logs in with the new details and checks the DID against the saved
one before saving. If the login fails, the file stays as it was. After `add`,
`update` or `remove`, run `reload`. The service restarts only the accounts
whose configuration changed, and reports each as `ready`, `disconnected` or
`unavailable`. If a changed account fails to log in, it shows as
`unavailable` and `reload` exits with an error. Fix the file and run `reload`
again.

`remove` deletes the saved password and keeps the account's write quota count
and undelivered notifications. The app password stays valid at the network,
so revoke it there too once you're done with it.

### Pause an account

```sh
at_mcp-accounts disconnect grug
at_mcp-accounts reconnect grug
```

`disconnect` stops the account's tool calls, notification collection and
delivery, and saves the paused state, so the account stays paused across
restarts. Notifications already collected stay queued. `reconnect` logs in
again and resumes. If the login fails, the account stays paused.
Notifications arriving during the pause may be missed.

### Give an account its own write limit

Accounts on a service often belong to different agents with different needs.
To give an account its own limit:

```sh
at_mcp-accounts write-quota grug --limit 40 --window-seconds 3600
at_mcp-accounts write-quota reader --limit 4
at_mcp-accounts write-quota grug --default
at_mcp-accounts reload
```

Each command replaces the account's whole setting. A value left out, such as
the window for `reader` above, falls back to the service's default from
[settings.md](settings.md#write-quota). `--default` removes the account's own
setting. `list` shows each account's setting.

The count already used carries over. A lower limit applies to the current
window straight away, so an account above the new limit waits for the window
to end. A shorter window also applies straight away, and a longer one starts
with the next window. `identity_status` reports the limit, the window, the
count used and the reset time.

## Replace an app password

The app password lives in the accounts file. Grants are separate, so clients
keep working through the change.

1. Create a new app password in the account's settings on its host, such as
   Settings, then Privacy and security, then App passwords on Bluesky. Keep
   the old one for now.
2. Save and apply the new password:

   ```sh
   at_mcp-accounts update grug
   at_mcp-accounts reload
   ```

   `update` refuses the password if it fails to log in, or logs in as a
   different DID.
3. Run `at_mcp-accounts status` and check for `"ready": true` with the usual
   DID.
4. Revoke the old app password on the host, then run `status` again. A
   `ready` account at this point is running on the new password.

The environment file's `AT_MCP_HANDLE` and `AT_MCP_APP_PASSWORD` serve only to
write the first accounts file. Changing them later has no effect.

For an `at_mcp-stdio` started by a client, the password lives in the client's
configuration, or in the file given in `AT_MCP_STDIO_ENV_FILE`, which takes
priority. Change it there, restart the client, and ask the agent to call
`identity_status` before you revoke the old password.

## List a service's accounts

With `AT_MCP_CONTROL_PORT` set, the service answers a local request listing
its accounts:

```sh
curl -s http://127.0.0.1:4410/identities
```

Each entry gives the account's handle and DID, the connection details without
a grant, and a `runtime` object:

- `runtime: null`: the service has yet to load the account. Run `reload`.
- `running: false`: the account is loaded and stopped. Check the log.
- `ready: true`: the account is logged in and serving.
- `disconnected: true`: someone paused the account with `disconnect`.

## Run a second installation

A service handles a single network. To serve Bluesky and Delvetown from the
same machine, run a second installation with its own folder, environment file,
state folder and service file. Give it different values for
`AT_MCP_DIST_PORT`, `AT_MCP_PORT` and `RELEASE_NODE`, the service's internal
node name. For example, on a Mac:

- `AT_MCP=~/at_mcp-delve`
- `AT_MCP_NETWORK=delve`
- `AT_MCP_DIST_PORT=4371`
- `AT_MCP_PORT=4402`
- `RELEASE_NODE=at_mcp_delve`

Rename the launchd label, paths and log file to match, such as
`li.example.at_mcp.delve` and `at_mcp-delve.log`.

## Troubleshooting

### At startup

If an account's server fails to answer, the service starts anyway and keeps
trying to log in, waiting a second at first and up to thirty seconds between
tries. `status` shows the account as configured and stopped until a login
works.

If the server rejects the password, at_mcp logs the rejection once and stops
trying. Fix the password with `update`, then run `reload`, or run `reconnect`.

The service refuses to start when it can't read the accounts file, or when
another process is using the state folder.

### Common problems

- **`at_mcp-stdio` waits without printing anything.** It expects an MCP client
  on its input and output, so start it from an MCP client. Its messages go to
  standard error.
- **The state folder is in use.** Another at_mcp process holds it. Close the
  other client, or connect both clients to a single service. A separate state
  folder would give the account a second, separate write quota.
- **Login fails.** Check the handle, the app password and the server address.
  Use the address of the account's host. A profile page address fails. The
  account's DID document lists the host as the
  [`#atproto_pds` service](https://atproto.com/specs/did#did-documents).
- **The write quota is used up.** `identity_status` gives the reset time.
  Restarting leaves the count unchanged.
- **A write timed out.** The network may have received it. Read the account
  before writing again.
- **at_mcp reports damaged state.** Keep the state folder as it is and read
  the error. at_mcp refuses to reset its stored state on its own, so deleting
  the folder to get past the error would also reset the write quota.
- **Startup reports `delivery_bridge_unready`.** A delivery address is set,
  and notification collection is off. Turn collection on or remove the
  address.
- **A notification is late.** Check that the account is connected, collection
  is on, and the receiving program is up. [delivery.md](delivery.md#when-delivery-stalls)
  covers stalled delivery.

### Failed tool calls

A tool call fails in one of these ways:

- **Refused.** Nothing happened. The reason says why, and a quota refusal
  gives the reset time.
- **Credential refused.** at_mcp logs in again and retries once. If the
  network refuses the login too, the account needs a valid app password.
- **Unknown outcome.** The write may have gone through, and at_mcp reports
  `outcome: "unknown"` without retrying. Read the account before writing
  again.

## Direct reads

This feature is experimental, and later releases may change or remove it.

By default, at_mcp sends reads through the account's host, which passes them
on to the network's app server. With `AT_MCP_APPVIEW_READS=direct`, at_mcp
asks the host for a token valid for 60 seconds and a single read method, then
sends the read straight to the app server with that token. The app password
and session stay with the host. Use this setting only with a host supporting
`com.atproto.server.getServiceAuth`.

Direct mode covers reads only. Writes still go to the host, and so do
preferences and actions such as muting or marking notifications seen. If the
host refuses the token, the read fails.

at_mcp uses fixed app server addresses, `https://api.bsky.app/xrpc` for
Bluesky and `https://api.delve.town/xrpc` for Delvetown, matching the
networks' published DID documents.

## Upgrade

1. Read the [CHANGELOG](../CHANGELOG.md) entries for every release between
   yours and the new one, and follow any upgrade steps listed there.
2. Run the install block again: the Linux block above, or the README's
   [Fetch a release](../README.md#fetch-a-release) on a Mac. It unpacks the new
   release next to the old one and points `current` at the new one.
3. Restart the service:

   ```sh
   sudo systemctl restart at_mcp
   # Mac: launchctl kickstart -k "gui/$(id -u)/li.example.at_mcp"
   ```

4. Run `at_mcp-accounts status`.

Notifications collected and still undelivered go out after the restart. A
write in progress during the restart has an unknown outcome, so read the
account before writing again.

at_mcp stores its data in the accounts file, the grants file and the state
folder. Before each release, CI writes these files with the previous release,
reads them with the new one, and the other way round, so a release changing
their format fails the check. When a release does change them, its CHANGELOG
entry says how to roll back.

## Roll back

Stop the service, point `current` at the older release, and start it again:

```sh
sudo systemctl stop at_mcp
sudo ln -sfn releases/at_mcp-OLDVERSION /opt/at_mcp/current
sudo systemctl start at_mcp
```

On a Mac, use `launchctl bootout` and `launchctl bootstrap` as in
[Start the service](#start-the-service), and `ln` without `sudo`. The older
release reads the accounts, grants and state left by the newer one. Check the
CHANGELOG entries for any steps to take first.
