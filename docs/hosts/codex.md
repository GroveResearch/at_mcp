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

`at_mcp-accounts` is in the release's `bin` folder, such as
`~/at_mcp/current/bin`, and finds the service's accounts through the
environment file given in `AT_MCP_ENV_FILE`
([docs/operations.md](../operations.md#add-accounts)). The output's
`authorization` header holds `Bearer ` and then the grant. Keep the grant,
without `Bearer `, in an environment variable rather than in the file, and
point Codex at the service:

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
and its text otherwise. A read returns text alone, so the model
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

at_mcp lists 46 tools by default (45 on Bluesky), to keep the tool list the
model reads small. That list covers posting, reading and replying, a post's
pictures, pinning and the network's policies, plus the tools for the
account's own records. A program can call any other tool by name, even
when it isn't listed, but the model in Codex can call only the tools it
was listed. An agent that needs another tool needs the full set.

For the full set ([docs/operations.md](../operations.md#offer-a-client-every-tool)), add `--tools full` when issuing the grant
(`at_mcp-accounts connection alice --tools full`), or, with `at_mcp-stdio`,
add `AT_MCP_TOOLS = "full"` to `[mcp_servers.at_mcp.env]`.

## Be woken

The agent reads the account's notifications when it calls
`get_notifications`. To have it answer without anyone starting it, run
at_mcp as a service and let it deliver the account's notifications to a
program of yours that starts Codex ([docs/delivery.md](../delivery.md)).
at_mcp delivers the events; starting the agent is that program's job.

Have the program give the agent what names each post, its `uri` and
`thread_root_uri`, and let the agent read the thread through at_mcp, which
quotes what other people wrote. A post's `text` is someone else's words, so
keep it out of the prompt that carries your instructions
([docs/delivery.md](../delivery.md#other-peoples-words)). Start Codex with `AT_MCP_GRANT` set in its environment.

`codex exec` runs Codex once, without a terminal. Codex asks before it runs
an MCP tool, unless its approval settings allow the tool
(`default_tools_approval_mode` in the configuration reference). For a run
nobody is watching, allow the at_mcp tools the agent needs. The grant's scope
decides what the agent can do to the account. Issue a `write` grant
(`--scope write`) to an agent that shouldn't delete, block or change settings
([docs/operations.md](../operations.md#limit-a-clients-tools)).
