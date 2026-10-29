# A plain script

A program with no MCP library can still use at_mcp: the service accepts MCP
messages as JSON over HTTP on this machine, so a script needs only an HTTP
client and a JSON parser.

## Connect

Run at_mcp as a service ([docs/operations.md](../operations.md)) and issue
the script a grant. A script that only reads should have a `read` grant, so
nothing it does by mistake can post:

```sh
at_mcp-accounts connection alice --scope read
export AT_MCP_GRANT=at_mcp-...   # the output's authorization header, after "Bearer "
```

`at_mcp-accounts` is in the release's `bin` folder, such as
`~/at_mcp/current/bin`, and finds the service's accounts through the
environment file given in `AT_MCP_ENV_FILE`
([docs/operations.md](../operations.md#add-accounts)).

A session is two requests: `initialize`, whose answer carries the session's
id in the `Mcp-Session-Id` header, and the `notifications/initialized` note.
Every call after that carries the grant and the session id. This script, in
Python with its standard library alone, reads the five newest posts of the
account's timeline and prints who wrote each and its address:

```python
import json, os, urllib.request

URL = os.environ.get("AT_MCP_URL", "http://127.0.0.1:4400/mcp")
headers = {
    "Authorization": "Bearer " + os.environ["AT_MCP_GRANT"],
    "Content-Type": "application/json",
    "Accept": "application/json, text/event-stream",
}

def send(message):
    request = urllib.request.Request(URL, json.dumps(message).encode(), headers)
    with urllib.request.urlopen(request) as response:
        session = response.headers.get("Mcp-Session-Id")
        body = response.read().decode()
    # An answer may come as an event stream: its JSON is on the data line.
    for line in body.splitlines():
        if line.startswith("data:"):
            body = line[5:]
    return session, json.loads(body) if body.strip() else None

session, _ = send({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
    "protocolVersion": "2025-06-18", "capabilities": {},
    "clientInfo": {"name": "my-script", "version": "1"}}})
headers["Mcp-Session-Id"] = session
headers["MCP-Protocol-Version"] = "2025-06-18"
send({"jsonrpc": "2.0", "method": "notifications/initialized"})

def call(tool, **arguments):
    _, answer = send({"jsonrpc": "2.0", "id": 2, "method": "tools/call",
                      "params": {"name": tool, "arguments": arguments}})
    result = answer["result"]
    if result.get("isError"):
        raise RuntimeError(result["content"][0]["text"])
    return result["structuredContent"]

page = call("get_timeline", limit=5, format="json")
for post in page["items"]:
    print(post["author"], post["uri"])
```

## What a script gets

With `"format": "json"`, a read returns its full summary as the result's
`structuredContent`, every field present and `null` where the service gave
nothing, and the same JSON as its text. Without it, a read returns text
written for a model, which a script should not parse. A write always
returns its JSON summary. [docs/tools.md](../tools.md) lists every tool and
its arguments.

A failed call has `isError: true` and a reason in its text. A failed write,
and a failed read that passed `"format": "json"`, also have a `code` in
their structured content; a read without it returns text alone, errors
included. When a write's outcome is unknown, the result says
`outcome: "unknown"`. The write may have happened, so read the account
before trying again.

## The full tool set

at_mcp lists 46 tools by default (45 on Bluesky), to keep the tool list the
model reads small. That list covers posting, reading and replying, a post's
pictures, pinning and the network's policies, plus the tools for the
account's own records. A script can call any tool by name, listed or not,
with no setting. To list every tool
with `tools/list`, issue the grant with `--tools full` ([docs/operations.md](../operations.md#offer-a-client-every-tool)).

## Be woken

A script can be the program the service delivers notifications to: it
receives each one as an HTTP `POST` with a JSON body
([docs/delivery.md](../delivery.md), "Write a receiver"). Or run it as the
command the example receiver starts when notifications arrive.

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
  --command 'python3 /path/to/answer.py'
```

`--reasons`, `--quiet` and `--max-wait` change which notifications wake the
agent and how long it waits. [delivery.md's "Wake an agent" section](../delivery.md#wake-an-agent) has the
details.

The script reads the summary from its standard input.
