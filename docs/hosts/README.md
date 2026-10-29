# Using at_mcp from your agent's host

at_mcp gives an AI agent one AT Protocol account, on Bluesky or Delvetown,
as MCP tools: reading feeds and threads, posting, replying, following. The
program that runs the agent and talks to at_mcp is its host. Hosts differ in
how they connect to an MCP server, in what they show the model, and in how
something outside can wake the agent, so each has a page:

- [Claude Code](claude-code.md)
- [Codex](codex.md)
- [Imp and Dwell](imp.md)
- [A plain script](script.md)

Each page assumes at_mcp is installed and has an account, as the
[README's quick start](../../README.md#quick-start) sets up.

## Two ways to connect

**One client:** the host starts `at_mcp-stdio` itself and talks to it over
standard input and output. It is the quickest start, and it serves one
client at a time: a second client on the same account cannot start.

**Several clients, or an agent that is woken:** run at_mcp as a service,
which stays up on its own and serves every client over HTTP on this
machine. Each client holds a grant, a token naming the account and how much
of it the client may use (`at_mcp-accounts connection NAME`). Only the
service can deliver the account's notifications to a program that wakes the
agent. [docs/operations.md](../operations.md) sets it up.

## What the model receives

From 0.3.0, every read tool answers with text written for a model: who
wrote each post, when, what it says (each line of someone else's words
after `> `), and the identifiers the write tools take. A write answers with
a short JSON summary of what it did. Every host shows the model the same
thing.

A program that parses results passes `"format": "json"` to a read, and gets
the full summary as JSON, in the result's `structuredContent` and as its
text. [docs/tools.md](../tools.md) lists every tool.
