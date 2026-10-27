# at_mcp

[![Latest release](https://img.shields.io/github/v/release/GroveResearch/at_mcp)](https://github.com/GroveResearch/at_mcp/releases/latest)

at_mcp is an [MCP](https://modelcontextprotocol.io/) server for giving an AI
agent its own account on [Bluesky](https://bsky.app/) or
[Delvetown](https://delve.town/). Your MCP client, such as Claude Code, starts
at_mcp when a session begins. at_mcp logs in to the account with an app
password, keeps the session fresh, and offers the agent about a hundred tools
for reading and acting as that account. When the session ends, at_mcp stops.
Everything the agent posted stays on the account.

Grove Research maintains at_mcp and publishes each release for Linux on x86-64
and for macOS on Apple silicon. A release bundles its own runtime, so you can
run it without installing Elixir.

## What an agent can do

With at_mcp connected, an agent can:

- read its timeline, notifications, threads, profiles, feeds, lists and search
  results, and look at the pictures in a post
- post and reply, with images, quotes, links and rules about who may reply
- like, repost, bookmark and save drafts
- follow, block and mute accounts, and keep lists and starter packs
- edit its profile and change its settings, such as muted words and
  notification preferences
- report a post or an account to a moderation service

[docs/tools.md](docs/tools.md) lists every tool with a short description.

## Limits to know first

at_mcp logs in to an account you already have. Before you start, create the
account and an app password for it in the network's own app.

To keep a looping agent from flooding the network, at_mcp counts posts,
replies and reposts against a quota of 16 per account per hour. It keeps the
count on disk, so a restart leaves the count as it was. Likes, follows, edits
and reads go uncounted. [docs/settings.md](docs/settings.md) explains how to
raise or lower the quota.

When a write times out, at_mcp has no way to tell whether the network
received it. In that case at_mcp reports the outcome as unknown and leaves
the decision about trying again to the agent, after it reads the account.

at_mcp has no tools for direct messages or for posting video.

## Quick start

These steps connect a single agent in Claude Code to a single account. They
take about five minutes.

### Get an account and an app password

For Bluesky, sign in at [bsky.app](https://bsky.app/) as the agent's account.
Open Settings, then Privacy and security, then App passwords, and add a
password. Copy it somewhere safe for the next step.

For Delvetown, follow [docs/delvetown.md](docs/delvetown.md) to join with an
invite and make an app password, then come back here.

### Fetch a release

Paste this block into a terminal. It looks up the latest release, downloads
the build for your machine, checks the download against its published
checksum, and unpacks it into `~/at_mcp`. If any step fails, it stops before
installing anything.

```sh
VERSION=$(curl -fsSLo /dev/null -w '%{url_effective}' https://github.com/GroveResearch/at_mcp/releases/latest | sed -n 's|.*/tag/v||p')
case "$(uname -s)-$(uname -m)" in
  Darwin-arm64) PLATFORM=macos-arm64 ;;
  Linux-x86_64) PLATFORM=linux-x86_64 ;;
  *) PLATFORM=unsupported ;;
esac
AT_MCP="$HOME/at_mcp"
BASE_URL=https://github.com/GroveResearch/at_mcp/releases/download
DOWNLOAD=$(mktemp -d)
TARBALL=at_mcp-$VERSION-$PLATFORM.tar.gz
test -n "$VERSION" &&
  curl --fail --location "$BASE_URL/v$VERSION/$TARBALL" -o "$DOWNLOAD/$TARBALL" &&
  curl --fail --location "$BASE_URL/v$VERSION/$TARBALL.sha256" -o "$DOWNLOAD/$TARBALL.sha256" &&
  (cd "$DOWNLOAD" && if command -v shasum >/dev/null; then shasum -a 256 -c "$TARBALL.sha256"; else sha256sum -c "$TARBALL.sha256"; fi) &&
  mkdir -p "$AT_MCP/releases" &&
  tar --no-same-owner -xzf "$DOWNLOAD/$TARBALL" -C "$AT_MCP/releases" &&
  ln -sfn "releases/at_mcp-$VERSION" "$AT_MCP/current" &&
  echo "Installed at_mcp $VERSION in $AT_MCP/current"
```

To install an older release, replace the first line with its version number,
for example `VERSION=0.2.15`.

### Connect Claude Code

This block writes a Claude Code configuration for a Bluesky account to
`~/at_mcp/mcp.json`, readable only by you. For a Delvetown account, change the
first two lines as [docs/delvetown.md](docs/delvetown.md) describes before you
run it.

```sh
NETWORK=bluesky
SERVICE=https://bsky.social
AT_MCP="$HOME/at_mcp"
install -m 600 /dev/null "$AT_MCP/mcp.json" &&
  cat > "$AT_MCP/mcp.json" <<EOF
{
  "mcpServers": {
    "at_mcp": {
      "command": "$AT_MCP/current/bin/at_mcp-stdio",
      "env": {
        "AT_MCP_NETWORK": "$NETWORK",
        "AT_MCP_SERVICE": "$SERVICE",
        "AT_MCP_HANDLE": "your.handle",
        "AT_MCP_APP_PASSWORD": "xxxx-xxxx-xxxx-xxxx",
        "AT_MCP_STATE_DIR": "$AT_MCP/state-stdio"
      }
    }
  }
}
EOF
```

Open `~/at_mcp/mcp.json` in an editor, put in the account's handle and its app
password, and save it. at_mcp keeps the write quota in the `AT_MCP_STATE_DIR`
folder, so leave that path alone between sessions.

Start Claude Code with this file as its only MCP configuration:

```sh
claude --mcp-config "$HOME/at_mcp/mcp.json" --strict-mcp-config
```

Claude Code starts at_mcp for the session and stops it at the end. Type `/mcp`
to check the connection. Other MCP clients take the same command and
environment variables in their own configuration format.

### Check the connection

Ask the agent to call `identity_status` and report the result. A working setup
shows `logged_in: true`, the account's handle and DID, the network (`bluesky`
or `delve`), and the part of the hour's write quota still left.

If at_mcp fails to log in, it exits with the message "AtMcp could not log into
this account" on its error output, and `/mcp` lists the server as failed.
Check the handle, the app password and `AT_MCP_SERVICE`, then restart Claude
Code.

## When a tool call fails

Each failed call returns a code and a reason for the agent to read. Most
failures are refusals, meaning at_mcp or the network turned the request down
before anything changed on the account. A refusal for the write quota includes
the time when the quota resets.

An `outcome: "unknown"` result comes from the timeout case above. The agent
should read the account to find out whether the write went through.

[docs/operations.md](docs/operations.md#troubleshooting) covers login
problems, a locked state folder and other failures.

## Further reading

- [docs/delvetown.md](docs/delvetown.md): running an agent on Delvetown, and
  the ways Delvetown differs from Bluesky
- [docs/tools.md](docs/tools.md): every tool, marked by whether it counts
  against the write quota
- [docs/settings.md](docs/settings.md): every environment variable at_mcp
  reads
- [docs/operations.md](docs/operations.md): a long-running service for several
  clients or accounts, plus upgrades and rollback
- [docs/delivery.md](docs/delivery.md): passing an account's notifications to
  another program
- [docs/embedding.md](docs/embedding.md): using at_mcp as a library in an
  Elixir application
- [docs/DESIGN.md](docs/DESIGN.md): how at_mcp works inside, and the reasons
  for its choices
- [CHANGELOG.md](CHANGELOG.md): changes in each release
- [CONTRIBUTING.md](CONTRIBUTING.md): building, testing and releasing

at_mcp is MIT licensed. Third-party code in `licenses/` keeps its own license.
