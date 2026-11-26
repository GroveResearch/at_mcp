# at_mcp-spaces

The Spaces helper: a small Node program at_mcp starts beside itself
(`AtMcp.Spaces.Helper`), wrapping Bluesky's `@atproto/oauth-client` and
`@atproto/lex-space`. at_mcp stays in Elixir; this is the part of atproto
Spaces it does not mirror (decisions.md, "Spaces").

It holds each account's OAuth session, approved by the account's own login
key, and does everything Spaces needs: the pass exchange (delegation token
for a space credential), request signing, MAC checks and sync.

## Build

```
scripts/build_spaces_helper.sh      # npm ci, type check, tests, bundle
```

The bundle is `priv/spaces_helper/at_mcp-spaces.mjs`, one file with no
`node_modules`, which the release ships with its license notices beside it.
It needs Node 22 or later.

## Protocol

JSON-RPC 2.0 on stdio, one JSON object per line, to the one at_mcp process
that started it. The helper stops when its input ends. Log lines arrive as
`log` notifications. A failure's `error.data` carries `class`, one of
at_mcp's kinds (`refused`, `auth_refused`, `indeterminate`), and `code`.

| Method | Params | Answers |
| --- | --- | --- |
| `init` | `stateDir`, `userAgent`, `plcDirectoryUrl?`, `handleResolver?`, `allowHttp?`, `inboxReaders?`, `tosHash?` | `{protocol: 1, version}` |
| `key.generate` | `keyFile` | `{didKey, jkt}`: a new P-256 key, written 0600; never replaces a file |
| `key.public` | `keyFile` | `{didKey, jkt}` |
| `oauth.login` | `account`, `keyFile`, `scope` | `{did, scope, expiresAt}` |
| `oauth.credentials` | `did`, `refresh?`, `relogin?: {account, keyFile, scope}` | `{did, accessToken, dpopJwk, serviceUrl, issuer, scope, expiresAt}` |
| `oauth.status`, `oauth.logout` | `did` | `{did, held, …}` |
| `space.create` | `did`, `type`, `skey?`, `policy: personal\|member`, `members?` | `{space, members}` |
| `space.list` | `did`, `type?`, `authority?`, `cursor?`, `limit?` | `com.atproto.space.listSpaces` |
| `space.get`, `space.authorize` | `did`, `space` | the space and its policy; its credential |
| `space.records.create\|put\|get\|list\|delete` | `did`, `space`, `collection`, `rkey?`, `record?`, `repo?` | the method's answer |
| `space.writers` | `did`, `space`, `cursor?` | the writer set |
| `space.all` | `did`, `space`, `limit?` | `{records, more}`: every repo, verified, each record with `valid` |
| `space.members.put\|remove\|list` | `did`, `space`, `members?` | `{members}` |
| `space.pull` | `did`, `space`, `repo` | `{type, rev, changes, held}`: the helper keeps the synced copy |
| `inbox.ensure` | `did` | `{space, created, readers}`: the account's `org.atgrp.inbox`, with `inboxReaders` read-only |

`space` is an `at:space/{authority}/{type}/{skey}` URI, or `{type, authority?, skey?}`.

## Logging in with a key

`oauth.login` is Welcome Mat's
[agent-authorization extension](https://github.com/solpbc/welcome-mat/blob/main/extensions/agent-authorization.md)
from the agent's side, with at_mcp as a loopback public client:

1. PAR, as any atproto OAuth client.
2. The authorize URL fetched with `Accept: application/json`: the JSON
   preview, and the server's `DPoP-Nonce`.
3. The preview checked against the request: `client_id`, `redirect_uri`,
   `scope` and `login_hint`. Anything else is `preview_mismatch`, and nothing
   is signed.
4. The same URL fetched with `Authorization: DPoP <wm+jwt>` (self-signed,
   `aud` the server's origin, `cnf.jkt` the key's thumbprint) and a DPoP
   proof from the login key. The answer is the redirect with the code.
5. The code redeemed by the client as usual. The session's own DPoP key is a
   new P-256 key, not the login key.

A refused key is `auth_refused` with code `key_refused`: a principal may have
revoked the agent or replaced its key.

## Tests

`npm test` runs the OAuth tests against `test/mock-pds.ts`, a stand-in
authorization server with the signed authorize path.
