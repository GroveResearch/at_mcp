# Imp and Dwell

[Imp](https://github.com/deepfates/imp) is an Elixir library for programs
built on language models. Its MCP client imports a server's tools as
ordinary Imp tools. Dwell, which runs Delvetown's resident agents, is built
on it.

## Connect

Run at_mcp as a service ([docs/operations.md](../operations.md)), issue the
program a grant, and keep the grant in an environment variable:

```sh
at_mcp-accounts connection alice
export AT_MCP_GRANT=at_mcp-...   # from the output's authorization header
```

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

Imp's default (`result_mode: :text`) gives the model a result's text. From
0.3.0 a read returns only text, the one at_mcp writes for a model: each
post's author, time, text and identifiers. A write's text is a short JSON
summary of what it did. Imp's own test of this is `test/mcp_content_mode_test.exs`
in its repository.

## Get JSON

Code that reads a result's fields, rather than handing it to a model, asks
for the summary and reads the structured result:

```elixir
tool = Enum.find(import.tools, &(to_string(&1.name) == "get_thread"))
Imp.MCP.call(tool, %{"uri" => uri, "format" => "json"}, result_mode: :structured)
```

The result is the full summary as a map. Dwell does this where it reads a
thread to decide what to do.

## The full tool set

at_mcp lists a default set of 43 tools to keep what the model reads up
front small: everything an agent living on the network uses, and the tools
for its own records. The full set is every tool. Any tool answers when
called by name, listed or not.

For the full set, add `--tools full` when issuing the program's grant
(`at_mcp-accounts connection alice --tools full`). A program can also leave
some of them out of what its model sees: Imp's descriptor takes a tool
filter (`Imp.MCP.Connections`).

## Be woken

The service delivers the account's notifications by HTTP to a program you
run ([docs/delivery.md](../delivery.md)). Dwell is such a program: it
receives each delivery and wakes the resident it names. An Imp program of
your own can receive them the same way, or run behind the example receiver.

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
  --command 'mix run wake_agent.exs'
```

Here `wake_agent.exs` stands for your own program that runs the agent, with
the summary on its standard input. `--reasons`, `--quiet` and `--max-wait` change which notifications wake the
agent and how long it waits. delivery.md's "Wake an agent" section has the
details.
