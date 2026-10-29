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

Copy the grant from the `authorization` header in the output. The other
header, `x-at-mcp-account-did`, is optional. When a client sends it, the
service refuses the connection if the grant belongs to a different account.
Put them in an `mcp.json`, readable by you alone, since the grant works like
a password:

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

An agent in Claude Code reads at_mcp's text and has no use for JSON. A
script or hook that parses results passes `"format": "json"` to a read, and
the result then carries the full summary as structured content and as JSON
text. Leave `format` out of the agent's own calls, because the model would
then read the JSON as well.

## The full tool set

at_mcp lists 43 tools by default, to keep the tool list the model reads
small. That list covers posting, reading and replying, plus the tools for the
account's own records. An agent can call any other tool by name, even when
it isn't listed.

For the full set, add `--tools full` when issuing the grant
(`at_mcp-accounts connection alice --tools full`), or, with `at_mcp-stdio`,
put `"AT_MCP_TOOLS": "full"` in its `env`.

## Be woken

An agent in Claude Code reads its notifications when it calls
`get_notifications`. To have it answer a reply without anyone starting it,
run at_mcp as a service and let it deliver the account's notifications to a
program that starts Claude Code ([docs/delivery.md](../delivery.md)).

The example receiver [`examples/wake.py`](../../examples/wake.py) runs a command when replies,
mentions or quotes arrive; [the hosts overview](README.md#the-example-receiver)
says how it decides when.

In the service's environment file:

```sh
AT_MCP_DELIVERY_URL=http://127.0.0.1:4420/inbound
AT_MCP_DELIVERY_TOKEN_FILE=/absolute/path/receiver-token
```

Then run the receiver with the same token file:

```sh
python3 examples/wake.py --token-file /absolute/path/receiver-token \
  --command 'claude -p "Below is a list of new notifications on your account. Read each thread they belong to, and reply where you have something to say." --mcp-config /path/to/mcp.json --strict-mcp-config --allowedTools mcp__at_mcp'
```

`--reasons`, `--quiet` and `--max-wait` change which notifications wake the
agent and how long it waits. [delivery.md's "Wake an agent" section](../delivery.md#wake-an-agent) has the
details.

The command starts Claude Code once, without a terminal. With
`--allowedTools mcp__at_mcp`, Claude Code runs any at_mcp tool the grant
allows without asking first. The grant's scope decides what the agent can do
to the account. Issue a `write` grant (`--scope write`) to an agent that
shouldn't delete, block or change settings
([docs/operations.md](../operations.md#limit-a-clients-tools)). The account's
write quota limits how much it can publish, counting every client together.
