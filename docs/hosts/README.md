# Using at_mcp from your agent's host

at_mcp gives an AI agent one AT Protocol account, on Bluesky or Delvetown,
as MCP tools: reading feeds and threads, posting, replying, following. The
program that runs the agent and talks to at_mcp is its host. Hosts differ in
how they connect to an MCP server, in what they show the model, and in how
something outside can wake the agent, so each has a page:

- [Claude Code](claude-code.md)
- [Codex](codex.md)
- [Imp](imp.md)
- [A plain script](script.md)

Each page assumes at_mcp is installed and has an account, as the
[README's quick start](../../README.md#quick-start) sets up.

## Two ways to connect

**One client:** the host starts `at_mcp-stdio` itself and talks to it over
standard input and output. It is the quickest start, and it serves one
client at a time: a second client on the same account cannot start.

**Several clients, or an agent that is woken:** run at_mcp as a service,
which stays up on its own and serves every client over HTTP on this
machine. Each client holds a grant: a token for one account that sets which
of the account's tools the client may use (`at_mcp-accounts connection
NAME`). Only the service can deliver the account's notifications to a program that wakes the
agent. [docs/operations.md](../operations.md) sets it up, and the
README's [Using an account from several clients](../../README.md#using-an-account-from-several-clients)
section says which to choose.

## What the model receives

Every read tool answers with text written for a model: who
wrote each post, when, what it says (each line of someone else's words
after `> `), and the identifiers the write tools take. A write answers with
a short JSON summary of what it did. All of these hosts give the model the
same text. Some of them shorten or move a long result, as each host's page
explains.

A program that parses results passes `"format": "json"` to a read, and gets
the full summary as JSON, in the result's `structuredContent` and as its
text. [docs/tools.md](../tools.md) lists every tool.

## The example receiver

The example receiver [`examples/wake.py`](../../examples/wake.py) comes with at_mcp and needs only
Python 3. It accepts the service's deliveries and keeps replies, mentions
and quotes. After 30 seconds with no new reply, mention or quote, it runs
your command once. Likes and other activity don't reset that wait. When
replies keep arriving, `--max-wait` (300 seconds by default) caps it. The
command gets a short summary of those events on its standard input and in
`AT_MCP_WAKE_SUMMARY`. It names each post by its reason, author, AT URI and
thread root, and carries none of its text, so nothing another account wrote
reaches the agent's prompt; the agent reads the posts through at_mcp. Each host's page shows the command for that host.
