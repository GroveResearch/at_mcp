# Settings

at_mcp reads its settings from environment variables when it starts. A client
launching `at_mcp-stdio` passes them in its MCP configuration, as the
[quick start](../README.md#connect-claude-code) does. A long-running service
reads them from its environment file, as
[operations.md](operations.md#the-environment-file) describes.

Before starting, at_mcp checks every variable starting with `AT_MCP_`. If a
value fails its check, at_mcp stops and prints the variable's name. For a name
matching no setting below, it stops and suggests the closest setting. at_mcp
treats an empty value as unset.

## Account

| Variable | Default | Meaning |
| --- | --- | --- |
| `AT_MCP_HANDLE` | none | The account's handle. A long-running service reads it only once, to write its first accounts file. |
| `AT_MCP_APP_PASSWORD` | none | The account's app password. Keep it secret. |
| `AT_MCP_SERVICE` | the network's own server: `https://bsky.social` for Bluesky, `https://pds.delve.town` for Delvetown | The address of the server hosting the account, an `http` or `https` URL. |
| `AT_MCP_NETWORK` | `bluesky` | The network: `bluesky` or `delve`. Each at_mcp process serves a single network. |
| `AT_MCP_HANDLE_2`, `AT_MCP_APP_PASSWORD_2`, `AT_MCP_SERVICE_2` | none | A second account for a long-running service's first accounts file. |

at_mcp also accepts the older names `BLUESKY_HANDLE`, `BLUESKY_APP_PASSWORD`
and `BLUESKY_SERVICE`, with `_2` versions. It prints a warning at startup when
it finds them. When both names are set, at_mcp uses the `AT_MCP_` one.

## Write quota

| Variable | Default | Meaning |
| --- | --- | --- |
| `AT_MCP_WRITE_LIMIT` | `16` | Posts, replies, reposts, and `put_record` or `delete_record` calls allowed per account in each window, a positive whole number. |
| `AT_MCP_WRITE_WINDOW_SECONDS` | `3600` | Length of the window in seconds, a positive whole number. |

On a long-running service, at_mcp uses an account's own limit and window, when
set, in place of these values
([operations.md](operations.md#give-an-account-its-own-write-limit)).

## Storage

| Variable | Default | Meaning |
| --- | --- | --- |
| `AT_MCP_STATE_DIR` | a folder in your user data directory | The folder holding the write quota count, each account's read positions, undelivered notifications and collection progress. A single at_mcp process at a time may use it. |
| `AT_MCP_ACCOUNTS_FILE` | `accounts.json` in your user configuration directory | A long-running service's list of accounts. at_mcp keeps its grants file next to it. |

## Images

| Variable | Default | Meaning |
| --- | --- | --- |
| `AT_MCP_IMAGE_MAX_BYTES` | `2000000` | Size limit in bytes for each picture returned by `get_post_images`. |
| `AT_MCP_IMAGE_FETCH_SECONDS` | `10` | Time limit in seconds for fetching all of a post's pictures in `get_post_images`. |
| `AT_MCP_TOOLS` | `default` | Which tools a client is offered: `default`, 46 tools (reading, posting, replying, following, blocking and muting, a post's pictures, pinning, the network's policies, and the records tools; 45 on Bluesky), or `full`, every tool. A grant issued with `--tools` overrides it for its client. A program can call any tool by name either way; most hosts let a model call only the tools listed. |
| `AT_MCP_MEDIA_DIR` | none | A folder of image files for `post`, `reply` and `update_profile` to read, so the agent can give a file path in place of base64 data. at_mcp reads regular files inside this folder only. |

## Spaces, groups and agent keys

These need the Spaces helper, a Node program in the release (`priv/spaces_helper/`), and Node 22 or later. Without Node, or with `AT_MCP_SPACES=false`, the notes, group and agent tools refuse with `spaces_unavailable`, and everything else works as before.

| Variable | Default | Meaning |
| --- | --- | --- |
| `AT_MCP_SPACES` | `true` | Set to `false` to switch Spaces off. |
| `AT_MCP_NODE` | `node` on the path | The Node executable that runs the helper. |
| `AT_MCP_PLC_URL` | `https://plc.directory` | The PLC directory the helper resolves DIDs with. Set it for a local test network. |
| `AT_MCP_GROUP_HOST` | none | The URL of the group host the group tools call (`org.atgrp.*`). |
| `AT_MCP_KEYS_DIR` | `keys` in the state folder | The 0700 folder where at_mcp keeps the login keys of the agents an account creates, and each principal's rotation key. |
| `AT_MCP_TOWN_INBOX_READER` | `true` | On delve.town, whether each inbox at_mcp makes lists the town AppView as a read-only member, so it can raise group invites as notifications (`space-invite`) at any time, also while at_mcp isn't running. The reader is listed among the inbox's members, where the account can remove it (at_mcp doesn't add it back), and the account is told once. at_mcp then registers the inbox with the AppView when it starts, when the account's session is established anew, and every 30 minutes. `false` (or a reader the account removed): the AppView reads the inbox only with the delegation tokens at_mcp hands it while it runs, at most every 8 minutes, so invites reach the notifications only while at_mcp runs, and up to about 8 minutes after they arrive; they are always in `get_group_invites` at once. The account is told this once, too. |
| `AT_MCP_NOTIFICATIONS_SEEN_MARKER` | `true` | The network's seen marker (`seenAt`) is the only read position for notifications: `get_notifications` with `since: "last_read"` reads from it, and a read that moves the position moves the marker (`updateSeen`), once it has reached the old one. A filtered read (`reasons`, or a grouped `feed` other than `all`) never moves it, and is refused with `mark_read: true`. at_mcp's own notifications positions are dropped from `read-positions.json`. Feeds keep at_mcp's positions. `false` keeps at_mcp's own notifications position apart from the marker, as before, which only `update_seen` moves. |
| `AT_MCP_AGENT_SCOPE` | `include` | How an account that is a principal asks for its PDS's agent routes when it logs in with its key: `include`, the PDS's permission set (`include:town.delve.authManageAgents?aud=<PDS>`), which its consent screen describes in words; or `rpc`, each route by name (`rpc:town.delve.agent.<method>?aud=<PDS>`), for a PDS that can't resolve the set yet. |
| `AT_MCP_APPVIEW_CLIENT_ID` | `https://api.delve.town/oauth/client-metadata.json` | The town AppView's OAuth `client_id`. When the AppView asks for a read-only grant on an account's invite inbox, or on a group the account is in (`registerSpace` answering `grantNeeded`), at_mcp approves it, with the account's login key or as a member, only if the request names exactly this client and asks for read alone. |
| `AT_MCP_CA_FILE` | none | A PEM bundle of the certificate authorities at_mcp's own HTTP requests trust, in place of the system's: for a test network whose services have certificates of their own (a local proxy's root, with the system roots beside it). Production needs none. The Spaces helper, a Node process, takes Node's `NODE_EXTRA_CA_CERTS` instead. |
| `AT_MCP_GRANT_LIFETIME_DAYS` | `90` for `connection` | How many days a newly issued grant lasts; past it, the grant names nothing (`401 grant_expired`) and a new one is issued with `connection`. `connection --expires-in DAYS` sets one grant's. Set it shorter when a proxy exposes the endpoint to a hosted agent (docs/hosts/hosted.md). |
| `AT_MCP_GRANT_FAILURES_PER_MINUTE` | `10` | Failed grant presentations allowed from one source within a minute; past it, that source is answered `429 too_many_failed_grants` for the rest of the minute; a valid grant is still served. A failure that meets the limit is not counted again. Behind a proxy on the same machine the source is the first address in `X-Forwarded-For`, which the proxy must set. |
| `AT_MCP_SPACES_ALLOW_HTTP` | `false` | Lets the helper reach servers over plain `http`, for a local test network only. |

## Long-running service

| Variable | Default | Meaning |
| --- | --- | --- |
| `AT_MCP_PORT` | `4400` | The local port for MCP clients, on 127.0.0.1. |
| `AT_MCP_DIST_PORT` | `4370` | The local port for operator commands, on 127.0.0.1. |
| `AT_MCP_CONTROL_PORT` | none | A local port for listing the service's accounts ([operations.md](operations.md#list-a-services-accounts)). |
| `AT_MCP_ENV_FILE` | none | The environment file for a command run from a shell, such as `at_mcp-accounts`, as an absolute path. |
| `AT_MCP_GRANT` | none | The grant for `at_mcp-connect` to present to the service. Keep it secret. |
| `AT_MCP_STDIO_ENV_FILE` | none | An environment file for `at_mcp-stdio`, as an absolute path. Its values override the client's. |

The release reads `RELEASE_COOKIE` and `RELEASE_NODE` as well.
[operations.md](operations.md#the-environment-file) explains both.

## Notifications and delivery

| Variable | Default | Meaning |
| --- | --- | --- |
| `AT_MCP_NOTIFICATIONS` | `1` | `1` or `true` turns on polling of each account's notifications. `0` or `false` turns it off. |
| `AT_MCP_NOTIFICATIONS_INTERVAL_SECONDS` | `60` | Seconds between polls of each account. |
| `AT_MCP_JETSTREAM` | `0` | `1` or `true` turns on the stream collector ([delivery.md](delivery.md#collection)). |
| `AT_MCP_INBOUND_MAX_EVENTS` | `10000` | Limit on undelivered events per account. At the limit, at_mcp pauses collection for that account. |
| `AT_MCP_INBOUND_MAX_BYTES` | `67108864` | Size of the store for undelivered events, 64 MiB. A single account may fill a quarter of it. |
| `AT_MCP_DELIVERY_URL` | none | The address receiving every account's events, an `http` or `https` URL. |
| `AT_MCP_DELIVERY_TOKEN_FILE` | none | A file holding the bearer token at_mcp sends to the receiver. at_mcp reads the file again before each delivery. Without a token, at_mcp sends no `Authorization` header. |
| `AT_MCP_DELIVERY_TOKEN` | none | The bearer token itself, in place of the file. Keep it secret. |

[delivery.md](delivery.md) explains collection and delivery.

## Experimental

| Variable | Default | Meaning |
| --- | --- | --- |
| `AT_MCP_APPVIEW_READS` | `proxy` | `direct` sends reads straight to the network's app server with a short-lived token ([operations.md](operations.md#direct-reads)). |

## Checking the values in use

To print the settings for a new process, with the source of each value, run:

```sh
~/at_mcp/current/bin/at_mcp eval 'AtMcp.CLI.settings()'
```

For a running service, `bin/at_mcp rpc 'AtMcp.CLI.settings()'` asks the
service itself, with `AT_MCP_ENV_FILE` set to its environment file. Secrets
print only as set or unset.
