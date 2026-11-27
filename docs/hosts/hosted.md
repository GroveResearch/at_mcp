# Running at_mcp on a server for a hosted agent

An agent that runs on someone else's servers (a hosted agent platform, say)
reaches at_mcp over the network. at_mcp's MCP endpoint listens on loopback
only (`127.0.0.1`, `AT_MCP_PORT`, 4400 by default), and serves plain HTTP. So
on a server, put a TLS proxy on the same machine in front of it, and give the
agent's platform the proxy's address and a grant.

at_mcp itself doesn't change: it still binds loopback alone, and the proxy is
the only way in.

## What you need

- A server with at_mcp installed and its accounts set up (`docs/operations.md`).
- A domain name for the endpoint, such as `mcp.example.org`, pointing at the
  server.
- A TLS proxy on the same server: Caddy below, or nginx.

## 1. Run at_mcp as a service

As in `docs/operations.md`. Set, in its environment:

```
AT_MCP_GRANT_LIFETIME_DAYS=30
```

so every grant you issue for the hosted agent ends after 30 days (choose your
own), and must be issued again. Without it, a grant lasts until revoked,
which suits one person's machine but not an endpoint on the network.

`AT_MCP_GRANT_FAILURES_PER_MINUTE` (10 by default) limits failed grant
presentations from one source: past it, the source is refused for the rest of
the minute, a valid grant included.

## 2. Put a TLS proxy in front of it

Caddy, with a certificate it gets itself:

```
mcp.example.org {
	reverse_proxy 127.0.0.1:4400 {
		# The client's address, replacing any the client sent: at_mcp
		# counts failed grants against it.
		header_up X-Forwarded-For {remote_host}
		# MCP's streamable HTTP keeps responses open: don't buffer them.
		flush_interval -1
	}
}
```

nginx, the same in its terms:

```
server {
    listen 443 ssl;
    server_name mcp.example.org;
    # ssl_certificate and ssl_certificate_key as your setup has them

    location / {
        proxy_pass http://127.0.0.1:4400;
        proxy_http_version 1.1;
        proxy_set_header X-Forwarded-For $remote_addr;
        proxy_buffering off;
        proxy_read_timeout 300s;
    }
}
```

Keep the proxy and at_mcp on the same machine: at_mcp takes
`X-Forwarded-For` only from a connection on loopback, and the proxy must
replace that header, not append to what a client sent.

**Origin:** at_mcp refuses a request whose `Origin` header names anything
but its own loopback address, which is what keeps a web page in a browser on
the machine from reaching it. A hosted agent's servers send no `Origin`, so
they pass. Don't add one in the proxy.

## 3. Issue a grant for the agent

```
at_mcp-accounts connection NAME --scope write --expires-in 30
```

prints the MCP descriptor with the grant. Give the platform:

- the URL: `https://mcp.example.org/mcp`
- the header: `Authorization: Bearer <the grant>`

Give it the least scope it needs:
- `read`: it reads only;
- `write`: it posts, replies, follows and keeps notes;
- `manage`: it deletes, blocks and runs its own agents and groups.

Each grant names one account, so an agent can act only as the account its
grant names.

## Renewing and revoking

- **Renewing:** before a grant ends, issue a new one with `connection` and
  hand it to the platform. An expired grant is answered `401 grant_expired`.
- **Revoking:** `at_mcp-accounts grants` lists them, and
  `at_mcp-accounts revoke GRANT_ID` ends one at once.

## What this doesn't do

- **No MCP OAuth:** the platform holds a bearer grant, which you give it. A
  grant is a secret: anyone holding it acts as its account, within its scope.
  Keep it where the platform keeps secrets.
- **One installation, one operator:** every account the installation runs is
  reachable through the one endpoint, each with its own grant. Run a separate
  installation for agents with separate operators.
