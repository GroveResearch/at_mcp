# Imp

[Imp](https://github.com/deepfates/imp) is an Elixir library for programs
built on language models. Its MCP client imports a server's tools as
ordinary Imp tools.

## Connect

Run at_mcp as a service ([docs/operations.md](../operations.md)), issue the
program a grant, and keep the grant in an environment variable:

```sh
at_mcp-accounts connection alice
export AT_MCP_GRANT=at_mcp-...   # the output's authorization header, after "Bearer "
```

`at_mcp-accounts` is in the release's `bin` folder, such as
`~/at_mcp/current/bin`, and finds the service's accounts through the
environment file given in `AT_MCP_ENV_FILE`
([docs/operations.md](../operations.md#add-accounts)).

Then connect with a descriptor that reads it:

```elixir
server = %{
  "name" => "at_mcp",
  "type" => "http",
  "url" => "http://127.0.0.1:4400/mcp",
  "auth" => %{"type" => "bearer_env", "variable" => "AT_MCP_GRANT", "required" => true}
}

{:ok, import} = Imp.MCP.connect([server], trusted_servers: [server])
```

`import.tools` holds at_mcp's tools, and `import.cleanup.()` closes the
connection. `Imp.MCP.Connections` describes the descriptor and its options.

An Elixir program that runs its own accounts can embed at_mcp instead and
call its functions directly ([docs/embedding.md](../embedding.md)).

## What the model sees

Imp's default, `result_mode: :text`, gives the model a result's text. A read
returns only the text at_mcp writes for a model: each post's author, time,
text and identifiers. A write returns a short JSON summary of what it did.
Imp's own test of this is `test/mcp_content_mode_test.exs` in its repository.

## Get JSON

Code that reads a result's fields, rather than handing it to a model, asks
for the summary and reads the structured result:

```elixir
tool = Enum.find(import.tools, &(to_string(&1.name) == "get_thread"))
Imp.MCP.call(tool, %{"uri" => uri, "format" => "json"}, result_mode: :structured)
```

The result is the full summary as a map.

## The full tool set

at_mcp lists 46 tools by default (45 on Bluesky), to keep the tool list the
model reads small. That list covers posting, reading and replying, a post's
pictures, pinning and the network's policies, plus the tools for the
account's own records. A program can call any other tool by name, even
when it isn't listed, but a model can call only the tools it is given. A
model that needs another tool needs the full set.

For the full set ([docs/operations.md](../operations.md#offer-a-client-every-tool)), add `--tools full` when issuing the program's grant
(`at_mcp-accounts connection alice --tools full`). A program can also leave
some of them out of what its model sees: Imp's descriptor takes a tool
filter (`Imp.MCP.Connections`).

## Be woken

The service delivers the account's notifications by HTTP to a program you
run ([docs/delivery.md](../delivery.md), "Write a receiver"). An Imp program
can receive them itself and run the agent. Give the agent what names each
post, its `uri` and `thread_root_uri`, and let it read the thread through
at_mcp, which quotes what other people wrote; a post's `text` is someone
else's words, not instructions ([docs/delivery.md](../delivery.md#other-peoples-words)). Waking an agent from at_mcp itself, with no program of yours in between, is planned in [#259](https://github.com/GroveResearch/at_mcp/issues/259).
