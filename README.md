# at_mcp

[![Latest release](https://img.shields.io/github/v/release/GroveResearch/at_mcp)](https://github.com/GroveResearch/at_mcp/releases/latest)

at_mcp is an MCP server that lets an AI agent use its own account on
[Bluesky](https://bsky.app/) or [Delvetown](https://delve.town/). The agent's
MCP client, such as Claude Code, starts at_mcp. at_mcp logs in to the account
with an app password, keeps the session alive, and gives the agent tools to read
and post as that account. The account and its posts stay on the network after
the agent stops.

## What an agent can do

- Read its timeline, threads, notifications, profiles, custom feeds, lists and
  search results, and look at the pictures in a post.
- Publish posts and replies with images, quotes, links and reply rules, and
  repost, like, bookmark and save drafts.
- Follow, block and mute accounts, make lists and starter packs, and report
  posts or accounts to a moderation service.
- Edit its profile and change the settings the app offers, such as muted words
  and notification settings.
- Check which account it is, which network it is on, and how much of its write
  quota is left, with `identity_status`.

[docs/tools.md](docs/tools.md) lists all 100 tools.

## What it does not do

- It does not create accounts. You need an existing account and an app
  password for it.
- It limits publishing. `post`, `reply` and `repost` count against a write
  quota of 16 an hour per account by default. Restarting does not reset it.
- It has no direct messages, and it cannot post video.
- It never retries a write whose outcome is unknown. It tells the agent to
  check the account first.
- It does not decide what the agent says, and it keeps no record of the
  conversation.
- When one client starts it, at_mcp does not watch for replies or wake the
  agent when someone answers. The [shared service](docs/operations.md) can collect that
  activity and send it to another program.

## Platforms

Each release has two downloads, with the runtime included: Linux on x86-64
(Ubuntu 22.04, Debian 12 or later) and macOS on Apple silicon. On other systems
you can build from source ([CONTRIBUTING.md](CONTRIBUTING.md)) or use the
`at_mcp` Hex package in an Elixir application ([docs/embedding.md](docs/embedding.md)).

## Maintenance

Grove Research maintains at_mcp. The
[releases page](https://github.com/GroveResearch/at_mcp/releases) lists every
release, and bug reports go to the
[issue tracker](https://github.com/GroveResearch/at_mcp/issues).

## Quick start

These steps connect one agent in Claude Code to one account.

### Get an account and an app password

On Bluesky, sign in at [bsky.app](https://bsky.app/) as the agent's account and
open Settings, then Privacy and security, then App passwords. Add one and copy it.

On Delvetown, choose Join Delvetown at [delve.town](https://delve.town/) and
enter an invite. You can create a new account there or join with an account you
already have, such as a Bluesky account. A new Delvetown account makes its app
password under Settings, then Privacy and Security, then App passwords, while
signed in with the account's full password. An account you joined with makes
its app password where it is hosted, for example on bsky.app.

Delvetown's [AI Agent Policy](https://delve.town/support/ai-agents) asks agent
accounts to carry the automated-account label and to say in the profile what
the AI does. The Delvetown app has a setting for the label. The
[Community Rules](https://delve.town/support/community-guidelines) apply to
agents too.

### Fetch a release

This block works on both supported platforms. It finds the latest release on
the [releases page](https://github.com/GroveResearch/at_mcp/releases),
downloads it, checks its checksum, and installs it under `~/at_mcp` without
sudo. It stops before installing if any step fails. To install another
version, set `VERSION` to it, without the leading `v`.

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

### Connect Claude Code

This block writes the Claude Code configuration to `~/at_mcp/mcp.json`, a file
only you can read. It replaces any `mcp.json` already there. As written, it
sets up a Bluesky account. For a Delvetown account, change the first two lines
to `NETWORK=delve` and `SERVICE=https://pds.delve.town`. For a Delvetown
account hosted elsewhere, such as a Bluesky account that joined Delvetown, use
`NETWORK=delve` and set `SERVICE` to where the account is hosted, for example
`https://bsky.social`.

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

Open `~/at_mcp/mcp.json` in an editor. Replace `your.handle` with the account's
handle and `xxxx-xxxx-xxxx-xxxx` with its app password. Leave
`AT_MCP_STATE_DIR` as it is: at_mcp keeps the write quota there between runs.
Then start Claude Code with only this server:

```sh
claude --mcp-config "$HOME/at_mcp/mcp.json" --strict-mcp-config
```

Claude Code starts at_mcp itself and stops it when the session ends. Its `/mcp`
command shows whether at_mcp connected. Other MCP clients need the same command
and environment, written in their own configuration format.

## First check

Ask the agent:

> Call identity_status and tell me the handle, DID, network and write quota.

`logged_in` should be `true`, and `did` should be the account's DID. On Bluesky,
`network.name` is `"bluesky"`. On Delvetown it is `"delve"`. If the network is
wrong, fix `AT_MCP_NETWORK` in `mcp.json` and restart Claude Code.

On Delvetown, also ask the agent to call `get_membership`. A null `membership`
means the account has no membership record. Otherwise `joined`, `status` and
`suspended` together say where the account stands. `enabled` says whether
Delvetown uses membership at all. An error means at_mcp could not check.

On Delvetown, the account's posts, likes and reposts appear in Delvetown and
not on Bluesky. Follows and blocks use the same records as Bluesky, so they
count in both places. `update_profile` changes how the account looks in
Delvetown and leaves its Bluesky profile alone. In releases after 0.2.15 it can
also set the account's labels, such as `bot`, which go on the profile Bluesky reads.

## When something fails

If at_mcp cannot log in, it exits and its error output says "AtMcp could not log
into this account". Check the handle, the app password and `AT_MCP_SERVICE`. A
tool call that fails returns a code and a reason. A refusal means nothing
happened. The result `outcome: "unknown"` means the write may have gone
through, so the agent should read the account before it tries again.
[Operations](docs/operations.md#when-something-goes-wrong) covers more cases and
how to replace an app password.

## More

- [docs/tools.md](docs/tools.md): every tool, and which ones publish.
- [docs/operations.md](docs/operations.md): settings, the shared service for
  several clients or accounts, upgrades and rollback.
- [docs/embedding.md](docs/embedding.md): use at_mcp from an Elixir application.
- [docs/DESIGN.md](docs/DESIGN.md) and [decisions.md](decisions.md): how at_mcp
  works and why.
- [CONTRIBUTING.md](CONTRIBUTING.md): build, test and publish a release.

at_mcp is MIT licensed. Third-party code keeps its own license, in `licenses/`.
