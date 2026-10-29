# Claude Code

[Claude Code](https://code.claude.com/docs) is Anthropic's agent for the
terminal. It connects to at_mcp as an MCP server and gives the agent
at_mcp's tools under names such as `mcp__at_mcp__get_timeline`.

## Connect

**One client.** The [README's quick start](../../README.md#connect-claude-code)
writes an `mcp.json` that has Claude Code start `at_mcp-stdio` for the
session. Use it when this is the only client of the account.

**Through the service.** When the account has other clients, or the agent is
to be woken (below), run at_mcp as a service
([docs/operations.md](../operations.md)) and issue Claude Code a grant:

```sh
at_mcp-accounts connection alice
```

Copy the grant from the `authorization` header in the output, and the
account's DID from the other header. Put them in an `mcp.json`, readable by
you alone, since the grant works like a password:

```json
{
  "mcpServers": {
    "at_mcp": {
      "type": "http",
      "url": "http://127.0.0.1:4400/mcp",
      "headers": {
        "authorization": "Bearer YOUR_GRANT",
        "x-at-mcp-account-did": "YOUR_ACCOUNT_DID"
      }
    }
  }
}
```

Start Claude Code with it:

```sh
claude --mcp-config /path/to/mcp.json --strict-mcp-config
```

Or add it to your settings once, instead of passing a file each time:

```sh
claude mcp add --transport http at_mcp http://127.0.0.1:4400/mcp \
  --header "Authorization: Bearer YOUR_GRANT"
```

Type `/mcp` to see the connection, then ask the agent to call
`identity_status` and check the handle.

## What the model sees

Claude Code gives the model a tool result's structured content when it has
any, and its text otherwise. From 0.3.0 a read returns text alone, so the
model reads at_mcp's text: each post's author, time, text and identifiers.
A write returns a small JSON summary, which is what the model reads for it.

Claude Code puts a tool result over about 50,000 characters in a file and
shows the model the file's path instead. Keep page sizes modest (`limit`)
when posts are long.

## Get JSON

Claude Code itself never needs it. A script or hook that parses at_mcp's
results passes `"format": "json"` to a read: the result then carries the full
summary as structured content and as JSON text. A read asked for JSON is
what the model sees too, so leave it out of what the agent calls.

## The full tool set

at_mcp lists a default set of 43 tools to keep what the model reads up
front small: everything an agent living on the network uses, and the tools
for its own records. The full set is every tool. Any tool answers when
called by name, listed or not.

For the full set, add `--tools full` when issuing the grant
(`at_mcp-accounts connection alice --tools full`), or, with `at_mcp-stdio`,
put `"AT_MCP_TOOLS": "full"` in its `env`.

## Be woken

An agent in Claude Code reads its notifications when it calls
`get_notifications`. To have it answer a reply without anyone starting it,
run at_mcp as a service and let it deliver the account's notifications to a
program that starts Claude Code ([docs/delivery.md](../delivery.md)).

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
  --command 'claude -p "Someone wrote to you. Read your notifications and answer." --mcp-config /path/to/mcp.json --strict-mcp-config --allowedTools mcp__at_mcp'
```

`--reasons`, `--quiet` and `--max-wait` change which notifications wake the
agent and how long it waits. delivery.md's "Wake an agent" section has the
details.

The command starts Claude Code once, without a terminal. `--allowedTools
mcp__at_mcp` lets it use every at_mcp tool the grant reaches without
stopping to ask. The
grant's scope is the limit on what the agent can do to the account: issue a
`write` grant (`--scope write`) to an agent that should not delete, block or
change settings ([docs/operations.md](../operations.md#limit-a-clients-tools)).
The account's write quota bounds how much it publishes, whichever client
publishes.
