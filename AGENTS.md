# Working on AtMcp

Read this before changing anything here, then read the README, relevant code
and tests, and recent history. `decisions.md` records the rulings and
load-bearing decisions with their evidence. This repository is self-contained;
no external workshop instructions are needed.

Prefer the stack’s existing mechanisms: declare shapes once and derive their
uses, classify boundary failures explicitly, and keep uncertainty distinct from
refusal. One owner holds each resource, and children stop with their owner.
Put the reason for a dependency workaround beside it, including what would
make it unnecessary.

Plan work in a repository issue with falsifiable acceptance criteria and submit
a topic-branch pull request for independent review before merging. Keep claims
of implemented behavior separate from exercised evidence and remaining limits.
Put durable conclusions in the owning code or documentation, not extra logs or
ticket files. Tests should fail when the behavior they protect is removed.
Release publication is a separate, explicit maintainer decision.

## What AtMcp owns

One AT Protocol account, and everything an agent needs to act as it:
credentials, the session and its refresh, readiness and disconnect, the durable
per-DID write quota, the MCP tool surface, and durable delivery of incoming
activity to a consumer. An account is a DID; one process owns it (today one per configured account, so
aliases of a DID each have their own — the provisional line in `decisions.md`),
one write quota covers every
client attached to it, and one process owns each state directory.

## What AtMcp does not own

Conversations, agent behavior, permission decisions, or an agent's character.
A host decides whether an action is approved; AtMcp decides whether the account
has capacity left. Nor does AtMcp own per-turn policy: it bounds writes per
account per hour, and anything that bounds a turn belongs to the host that owns
the turn.

## Boundaries

- `AtMcp.Effects.Backend` — the application capability boundary. Implementations
  return summaries built with `AtMcp.Summary` and failures as
  `AtMcp.Effects.Failure` (`:refused`, `:auth_refused`, `:indeterminate`). Any
  other reason is indeterminate, which for a write is an unknown outcome that is
  never retried.
- `AtMcp.Stream` — the event stream boundary. An adapter owns its service's
  options, message shape and event fields; `AtMcp.Inbound` and
  `AtMcp.Inbound.Match` see only `AtMcp.Stream.Event`.
- `AtMcp.Network` — which AT Protocol network AtMcp talks to. Every NSID derives
  from it; `AtMcp.ATProto` builds every record AtMcp writes. A literal namespace
  anywhere else in `lib/` is a defect. `com.atproto.*` and `chat.bsky.*` stay
  literal because the rename does not touch them.
- `AtMcp.MCP.Server` — the tool surface. Handlers call `AtMcp.Effects` and never
  reimplement account policy. Every tool declares an output schema from
  `AtMcp.Summary`, and its `readOnlyHint` / `destructiveHint` annotations are the
  only definition of what a grant's scope reaches.
- `AtMcp.Grants` — the credential boundary. It alone answers which identity a
  request acts as and how much it may reach; `AtMcp.MCP.HTTP` resolves, nothing
  else reads the grants file. An account id arriving from anywhere but a
  resolved grant is a defect.
- `AtMcp.PrivateFile` — the 0600 read-modify-write under a lock for the accounts
  and grants files. A second copy of that code is a second chance to lose an
  operator's credentials.
- Running AtMcp is the release's own `bin/at_mcp start` under systemd or launchd,
  from the example units in `rel/examples/`, with one environment file
  (docs/operations.md, "Run a shared service"). `rel/env.sh.eex` loads that file for a command run from
  a shell when `AT_MCP_ENV_FILE` names it. AtMcp has no installer, upgrade or
  service-manager code; do not add one.
- The MCP tool surface is public: `test/support/tool_surface.json` is what has
  been published, and `test/at_mcp/tool_surface_test.exs` states how it may
  change. A rename keeps the old name until a date written beside it.

## Divergences

Each one's reason lives where the divergence lives, and its retirement
condition is in `decisions.md` under Dependencies:

- `ex_mcp` comes unmodified from Hex. AtMcp validates the declared tool input
  schemas before handlers in `AtMcp.MCP.DSL` / `AtMcp.MCP.Input`, since upstream's
  DSL only normalizes arguments. It owns post-handler output validation in
  `AtMcp.MCP.Output`: diagnostics cannot turn a completed action into a failure. Re-run `test/at_mcp/stdio_test.exs` with `MCP_CLIENT_PATH`
  set before changing the dependency.
- `AtMcp.NativeLock` owns the repaired native advisory lock derived from flock_ex
  0.1.0; the reason lives in `c_src/native_lock.c`, with Apache-2.0 attribution
  in `licenses/flock_ex/`.
- proto_rune workarounds live in `AtMcp.Effects.ProtoRune`, `AtMcp.ATProto` and
  `AtMcp.RichText`, each commented with the upstream defect. `ProtoRune.Bsky` is
  not called at all.
- `AtMcp.ATProto` calls proto_rune's XRPC request pieces directly, resolving the
  NSID at call time and adding the AppView proxy header; see its comments.
- `priv/lexicons` holds copies of `feed/post.json` for each network — see the
  README beside them.

## Evidence

The test suite is the evidence. A claim is established when a test fails if
you revert the change that makes it true. Where a check needs credentials, a
network or a machine, say so in the test with `@tag skip:` and a reason, and
supply that environment in `.github/workflows/check.yml`, which fails on any
skipped test. Running a built release as Operations says is
`scripts/foreground_boot_check.py` and `scripts/upgrade_rollback_check.py`,
which CI runs under the example units. A limit that belongs to the code goes in the moduledoc beside it.
What was exercised on a particular day belongs in the pull request.

`test/at_mcp/telos_test.exs` holds AtMcp's purpose as claims. A claim not yet true
is tagged `:goal` and excluded (`mix test --only goal` lists them); making one
true deletes its tag in the same commit. Do not weaken a claim to make it pass,
and do not add one for work you are about to do.
