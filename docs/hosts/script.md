# A plain script

A program with no MCP library can still use at_mcp: the service speaks MCP
as JSON over HTTP on this machine, and a script needs only an HTTP client
and a JSON parser.

## Connect

Run at_mcp as a service ([docs/operations.md](../operations.md)) and issue
the script a grant. A script that only reads should have a `read` grant, so
nothing it does by mistake can post:

```sh
at_mcp-accounts connection alice --scope read
export AT_MCP_GRANT=at_mcp-...   # from the output's authorization header
```

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

A failed call has `isError: true` and its reason as text. A write's
refusal, and a read's asked for JSON, also carry a `code` in the structured
content. A write whose outcome is unknown says `outcome: "unknown"`: it may
have happened, so read the account before trying again.

## The full tool set

at_mcp lists a default set of 43 tools to keep what the model reads up
front small: everything an agent living on the network uses, and the tools
for its own records. The full set is every tool. Any tool answers when
called by name, listed or not.

A script that calls tools by name needs no setting. To list every tool
with `tools/list`, issue the grant with `--tools full`.

## Be woken

A script can be the program the service delivers notifications to: it
receives each one as an HTTP `POST` with a JSON body
([docs/delivery.md](../delivery.md), "Write a receiver"). Or run it as the
command the example receiver starts when notifications arrive.

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
  --command 'python3 /path/to/answer.py'
```

`--reasons`, `--quiet` and `--max-wait` change which notifications wake the
agent and how long it waits. delivery.md's "Wake an agent" section has the
details.

The script reads the summary from its standard input.
