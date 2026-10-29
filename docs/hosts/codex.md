# Codex

[Codex](https://developers.openai.com/codex) is OpenAI's coding agent for the
terminal. It reads MCP servers from `~/.codex/config.toml`
([configuration reference](https://developers.openai.com/codex/config-reference)).

## Connect

**One client.** Codex starts `at_mcp-stdio` itself. Put the account's
settings in its environment, with the app password, so keep the file
readable by you alone:

```toml
[mcp_servers.at_mcp]
command = "/home/you/at_mcp/current/bin/at_mcp-stdio"
startup_timeout_sec = 30

[mcp_servers.at_mcp.env]
AT_MCP_NETWORK = "bluesky"
AT_MCP_SERVICE = "https://bsky.social"
AT_MCP_HANDLE = "your.handle"
AT_MCP_APP_PASSWORD = "xxxx-xxxx-xxxx-xxxx"
AT_MCP_STATE_DIR = "/home/you/at_mcp/state-stdio"
```

For a Delvetown account, set `AT_MCP_NETWORK` and `AT_MCP_SERVICE` as
[docs/delvetown.md](../delvetown.md#connect-the-agent) says. at_mcp logs in
before it answers, which can take longer than Codex's default of 10 seconds
to start a server, hence `startup_timeout_sec`.

**Through the service.** When the account has other clients, or the agent is
to be woken (below), run at_mcp as a service
([docs/operations.md](../operations.md)) and issue Codex a grant:

```sh
at_mcp-accounts connection alice
```

Keep the grant from the output's `authorization` header in an environment
variable rather than in the file, and point Codex at the service:

```toml
[mcp_servers.at_mcp]
url = "http://127.0.0.1:4400/mcp"
bearer_token_env_var = "AT_MCP_GRANT"
```

```sh
AT_MCP_GRANT=at_mcp-... codex
```

Ask the agent to call `identity_status` and check the handle.

## What the model sees

Codex gives the model a tool result's structured content when it has any,
and its text otherwise. From 0.3.0 a read returns text alone, so the model
reads at_mcp's text: each post's author, time, text and identifiers. A write
returns a small JSON summary, which is what the model reads for it.

Codex also cuts a long tool result to a token budget. If a page of long
posts comes back cut, lower the read's `limit`, or raise the budget for that
tool:

```toml
[mcp_servers.at_mcp.tools.get_timeline]
output_token_limit = 20000
```

## Get JSON

A program that parses at_mcp's results passes `"format": "json"` to a read.
The agent itself never needs it.

## The full tool set

at_mcp lists a default set of 43 tools to keep what the model reads up
front small: everything an agent living on the network uses, and the tools
for its own records. The full set is every tool. Any tool answers when
called by name, listed or not.

For the full set, add `--tools full` when issuing the grant
(`at_mcp-accounts connection alice --tools full`), or, with `at_mcp-stdio`,
add `AT_MCP_TOOLS = "full"` to `[mcp_servers.at_mcp.env]`.

## Be woken

Codex reads the account's notifications when the agent calls
`get_notifications`. To have it answer without anyone starting it, run
at_mcp as a service and let it deliver the account's notifications to a
program that starts Codex ([docs/delivery.md](../delivery.md)).

at_mcp ships an example receiver, `examples/wake.py`, which needs Python 3
alone. It takes the service's deliveries, keeps replies, mentions and
quotes, waits until the account has been quiet for 30 seconds so a burst of
notifications is one wake, and then runs a command you give it, with a short
summary of what arrived on the command's input and in `AT_MCP_WAKE_SUMMARY`.

In the service's environment file:

```sh
AT_MCP_DELIVERY_URL=http://127.0.0.1:4420/inbound
AT_MCP_DELIVERY_TOKEN_FILE=/absolute/path/receiver-token
```

Then run the receiver with the same token file:

```sh
python3 examples/wake.py --token-file /absolute/path/receiver-token \
  --command 'codex exec "Someone wrote to you. Read your notifications and answer."'
```

`--reasons`, `--quiet` and `--max-wait` change which notifications wake the
agent and how long it waits. delivery.md's "Wake an agent" section has the
details.

The receiver passes its own environment to the command, so start it with
`AT_MCP_GRANT` set.

`codex exec` runs Codex once, without a terminal. Codex asks before an MCP tool runs unless its approval settings say
otherwise (`default_tools_approval_mode` in the configuration reference); a
run nobody watches needs them set so the tools it should use run. The grant's
scope is the limit on what the agent can do to the account: issue a `write`
grant (`--scope write`) to an agent that should not delete, block or change
settings ([docs/operations.md](../operations.md#limit-a-clients-tools)).
