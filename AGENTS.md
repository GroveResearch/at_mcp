# Working on AtMcp

Read this before changing anything here. Then read the README, the code and
tests you are changing, and recent history. `decisions.md` records the
load-bearing decisions, each with its reason and the evidence that holds it.
This repository is self-contained: no outside instructions are needed.

Use the stack's existing mechanisms:

- Declare a shape once and derive its uses from it.
- Classify each failure at the boundary where it arrives, and keep
  uncertainty apart from refusal.
- Give each resource one process responsible for it, and stop its children
  with it.
- Put the reason for a dependency workaround beside it, with what would make
  it unnecessary.

Plan work in a repository issue with falsifiable acceptance criteria, and
send it as a pull request from a topic branch for independent review before
it merges. Keep claims of implemented behavior apart from the evidence
exercised and the limits left. Put a lasting conclusion in the code or
documentation it concerns, not in a log or ticket file. A test should fail
when the behavior it protects is removed. Publishing a release is a separate,
explicit decision of a maintainer.

## What AtMcp is responsible for

One AT Protocol account, and everything an agent needs to act as it:

- its credentials, the session and its refresh;
- readiness and disconnect;
- the durable per-DID write quota;
- the MCP tools;
- durable delivery of incoming activity to a consumer.

An account is a DID, and one process runs it. Today that is one process per
configured account, so aliases of a DID each get their own (the provisional
line in `decisions.md`). One write quota covers every client attached to the
account, and one process uses each state directory.

## What AtMcp leaves to others

Conversations, agent behavior, permission decisions and an agent's character
belong to the agent's host. The host decides whether an action is approved;
AtMcp decides whether the account has capacity left. AtMcp bounds writes per
account per hour, and anything that bounds a turn belongs to the host running
the turn.

## Boundaries

- `AtMcp.Effects.Backend` is the application capability boundary.
  Implementations return summaries built with `AtMcp.Summary`, and failures as
  `AtMcp.Effects.Failure` (`:refused`, `:auth_refused`, `:indeterminate`). Any
  other reason counts as indeterminate. For a write, that is an unknown
  outcome, and AtMcp never retries it.
- `AtMcp.Stream` is the event stream boundary. An adapter holds its service's
  options, message format and event fields; `AtMcp.Inbound` and
  `AtMcp.Inbound.Match` see only `AtMcp.Stream.Event`.
- `AtMcp.Network` says which AT Protocol network AtMcp talks to. Every NSID is
  derived from it, and `AtMcp.ATProto` builds every record AtMcp writes. A
  literal namespace anywhere else in `lib/` is a defect. `com.atproto.*` and
  `chat.bsky.*` stay literal because they are the same on every network.
- `AtMcp.MCP.Server` declares the tools. Handlers call `AtMcp.Effects` and
  leave account policy to it. Every tool has an output schema built from
  `AtMcp.Summary`, and `AtMcp.MCP.Output` checks its results against it.
  `tools/list` lists none of the schemas, and a read answers in text unless
  asked for json. A tool's `readOnlyHint` and `destructiveHint` annotations
  alone decide which grant scopes include it.
- `AtMcp.Grants` is the credential boundary. It alone answers which identity a
  request acts as and which tools it may call. `AtMcp.MCP.HTTP` asks it, and
  nothing else reads the grants file. An account id from anywhere but a
  resolved grant is a defect.
- `AtMcp.PrivateFile` does the 0600 read-modify-write under a lock for the
  accounts and grants files. A second copy of that code would be a second
  chance to lose an operator's credentials.
- AtMcp runs as the release's own `bin/at_mcp start` under systemd or
  launchd, from the example units in `rel/examples/`, with one environment
  file (docs/operations.md, "The environment file"). `rel/env.sh.eex` loads
  that file for a command run from a shell when `AT_MCP_ENV_FILE` gives its
  path. AtMcp has no installer, upgrade or service-manager code, and none
  should be added.
- The MCP tools are public: `test/support/tool_surface.json` records what has
  been published, and `test/at_mcp/tool_surface_test.exs` says how it may
  change. A rename keeps the old name until a date written beside it.

## Divergences

Each one's reason lives where the divergence lives, and its retirement
condition is in `decisions.md` under Dependencies:

- `ex_mcp` comes unmodified from Hex. AtMcp validates the declared tool input
  schemas before handlers run, in `AtMcp.MCP.DSL` and `AtMcp.MCP.Input`,
  because upstream's DSL only normalizes arguments. AtMcp validates output
  after the handler in `AtMcp.MCP.Output`, so a diagnostic cannot turn a
  completed action into a failure. Re-run `test/at_mcp/stdio_test.exs` with `MCP_CLIENT_PATH` set
  before changing the dependency.
- `AtMcp.NativeLock` holds the repaired native advisory lock derived from
  flock_ex 0.1.0; the reason lives in `c_src/native_lock.c`, with Apache-2.0 attribution
  in `licenses/flock_ex/`.
- proto_rune workarounds live in `AtMcp.Effects.ProtoRune`, `AtMcp.ATProto` and
  `AtMcp.RichText`, each commented with the upstream defect. `ProtoRune.Bsky` is
  not called at all.
- `AtMcp.ATProto` calls proto_rune's XRPC request pieces directly, resolving the
  NSID at call time and adding the AppView proxy header; see its comments.
- `priv/lexicons` holds copies of `feed/post.json` for each network; the
  README beside them says why.

## Evidence

The test suite is the evidence. A claim is established when a test fails if
you revert the change that makes it true. Where a check needs credentials, a
network or a machine, say so in the test with `@tag skip:` and a reason, and
supply that environment in `.github/workflows/check.yml`, which fails on any
skipped test. `scripts/foreground_boot_check.py` and
`scripts/upgrade_rollback_check.py` run a built release as
docs/operations.md says, and CI runs them under the example units. The
round trips in `test/e2e` run against a local AT Protocol network
(CONTRIBUTING.md, "End-to-end tests"), and the merge queue runs them. A limit
that belongs to the code goes in the moduledoc beside it. What was exercised
on a particular day belongs in the pull request.

`test/at_mcp/telos_test.exs` holds AtMcp's purpose as claims. A claim not yet
true is tagged `:goal` and excluded (`mix test --only goal` lists them); making one
true deletes its tag in the same commit. Do not weaken a claim to make it pass,
and do not add one for work you are about to do.
