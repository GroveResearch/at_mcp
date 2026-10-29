# Contributing to at_mcp

Before changing code, read [AGENTS.md](AGENTS.md) for
at_mcp's responsibilities and conventions, and [docs/DESIGN.md](docs/DESIGN.md)
for how the parts fit together. [decisions.md](decisions.md) records past
decisions and the tests holding them.

Open an issue first, and state its acceptance criteria in testable terms.
Send the change as a pull request from a topic branch. Every pull request gets
an independent review before it merges.

## Set up

You need Elixir 1.19 with a matching Erlang/OTP, a C compiler and Make. The
interoperability tests also need Node.js and npm.

```sh
git clone https://github.com/GroveResearch/at_mcp.git
cd at_mcp
mix deps.get
mix check
```

`mix check` checks the formatting, compiles with warnings treated as errors,
and runs the tests, failing on a warning in a test file too. Run `mix format` to fix formatting.

## Build a release

```sh
MIX_ENV=prod mix release
```

The build goes to `_build/prod/rel/at_mcp`, with the version `0.0.0-dev`
and the commit in its `BUILD` file. To build a numbered version, as CI does
for a tag, run `RELEASE_VERSION=0.3.0 MIX_ENV=prod mix release`. Mix skips
recompiling when only the version changes, so run `MIX_ENV=prod mix clean`
before building a different version.

To try a local build with an MCP client, put the absolute path to
`_build/prod/rel/at_mcp/bin/at_mcp-stdio` in the client's configuration. In a
checkout, `mix at_mcp.server` runs the service in the foreground with the
shell's environment.

To install a local build as a service, copy it into the release layout from
[docs/operations.md](docs/operations.md#install). On a Mac:

```sh
VERSION=$(cut -d' ' -f2 _build/prod/rel/at_mcp/releases/start_erl.data)
AT_MCP="$HOME/at_mcp"
test ! -e "$AT_MCP/releases/at_mcp-$VERSION" &&
  mkdir -p "$AT_MCP/releases" &&
  cp -R _build/prod/rel/at_mcp "$AT_MCP/releases/at_mcp-$VERSION" &&
  ln -sfn "releases/at_mcp-$VERSION" "$AT_MCP/current"
```

On Linux, use `AT_MCP=/opt/at_mcp` and run the last three commands with
`sudo`. Pick a version number not already installed, so the copy leaves a
running release alone.

A release includes the Erlang runtime from the build machine. Homebrew's
Erlang links Homebrew's OpenSSL, so a release built with it runs only on Macs
with that OpenSSL. CI checks that published macOS releases link nothing outside macOS.

## Test

### Interoperability tests

Some tests drive at_mcp with the official MCP client packages, and skip with
a reason when the packages are missing. To run them:

```sh
probe_dir=$(mktemp -d)
npm install --prefix "$probe_dir" --ignore-scripts --no-audit --no-fund \
  @modelcontextprotocol/sdk@1.29.0 @modelcontextprotocol/client@2.0.0
MCP_SDK_PATH="$probe_dir/node_modules/@modelcontextprotocol/sdk" \
MCP_CLIENT_PATH="$probe_dir/node_modules/@modelcontextprotocol/client" mix check
```

`test/at_mcp/http_client_test.exs` needs `MCP_SDK_PATH`.
`test/at_mcp/stdio_test.exs` and `test/at_mcp/shared_stdio_test.exs` need
`MCP_CLIENT_PATH` too. All of them use throwaway local accounts and publish
nothing.

### Release tests

These tests run against a built release, and skip without one:

```sh
TEST_ACCOUNT_RELEASE="$PWD/_build/prod/rel/at_mcp" \
TEST_CONNECT_RELEASE="$PWD/_build/prod/rel/at_mcp/bin/at_mcp-connect" mix check
```

With every variable above set, the suite skips nothing. CI's `check` workflow
runs it this way in the merge queue, split across parallel jobs with
`mix test --partitions`, and fails if any test skips, so a skipped
interoperability test can't pass for a success. A pull request gets a quick
check first: formatting, compiling with warnings as errors and the async tests.

To rerun the one partition that failed in the queue, say `suite (2)` of four,
give it the same number and the variables above:

```sh
MIX_TEST_PARTITION=2 mix test --partitions 4
```

Two scripts install a built release under a scratch folder and run it against
a local server:

```sh
python3 scripts/foreground_boot_check.py "$PWD/_build/prod/rel/at_mcp"
python3 scripts/upgrade_rollback_check.py OLD_RELEASE_DIR "$PWD/_build/prod/rel/at_mcp"
```

The first starts the release as the example launchd file does and runs every
operator command against it. The second upgrades from an older release and
rolls back. With `--systemd` or `--launchd`, the second installs the example
service for real. Those modes run only on CI machines.

### End-to-end tests

The fake server in the unit tests answers the way at_mcp's authors believe the
network answers. The end-to-end tests check that belief against the reference
server and app server from `@atproto/dev-env`, running on your machine. They
use no real account and stay on localhost.

```sh
scripts/e2e.sh
scripts/e2e.sh test/e2e/round_trip_test.exs:LINE
```

You need git, Node 22.19 or later, pnpm 11.11.0, and `initdb`, `pg_ctl` and
`redis-server` on your `PATH`. The first run builds
atproto under `_build/e2e`, taking a minute or two, and later runs take about
ten seconds. Without `DB_POSTGRES_URL` and `REDIS_HOST`, the script starts a
private Postgres and Redis and removes them afterwards. CI runs these tests in
the merge queue (the `e2e` job in `.github/workflows/check.yml`), so a change
that breaks one does not reach main.

The suite calls each write tool, reads the result back through the read tools,
undoes the write, and reads again. The suite leaves these uncovered:

- `feed_feedback` gets only as far as its refusal, because the dev-env feed
  generator ignores feedback.
- A lost compare-and-swap race is hard to cause through a tool, so the suite
  writes over a stale record directly and checks the server's refusal.
- dev-env runs Bluesky's app server, so Delvetown's own methods, such as
  `get_membership`, stay untested here.

### Check a live account

The fixtures test at_mcp against known responses. To compare its output with
real network responses, run this script against a running service. It checks
that no tool lists an output schema, and compares real read results, asked
for as json, with their text. It calls no write tool. `$probe_dir` comes from
the [interoperability tests](#interoperability-tests) above, and each run of
`connection` issues a fresh grant, so revoke old ones with
`at_mcp-accounts revoke`:

```sh
MCP_CLIENT_PATH="$probe_dir/node_modules/@modelcontextprotocol/client" \
  AT_MCP_GRANT="$(at_mcp-accounts connection NAME --scope read | jq -r '.mcp.headers[0].value' | cut -d' ' -f2)" \
  node scripts/live_contract_check.mjs \
  /path/to/release/bin/at_mcp-connect http://127.0.0.1:4400/mcp did:plc:...
```

## Evidence for a change

Back each claim about behavior with a test failing when you revert the
change. Test behavior visible to a caller, such as the account chosen, the
result returned, or the state after a restart, rather than wording or
internal structure. When a check needs credentials, a network or a particular
machine, mark the test `@tag skip:` with the reason, and give CI the
environment for it. When a live check finds a problem missed by the fixtures,
add a test failing without the fix, and list your commands in the pull
request.

CI compares the documentation with the code:

- `mix at_mcp.tools_doc` writes `docs/tools.md` from the server's tools, and
  `test/at_mcp/tool_surface_test.exs` fails when the file is out of date. Run
  the task after changing a tool or its description.
- `scripts/download_release_check.py` runs the README's install block against
  a local copy of a built release, so the block has to keep working as
  written.
- `test/at_mcp/host_pages_test.exs` runs the plain-script example in
  `docs/hosts/script.md`. It also checks each link in the host pages, the
  heading a link points to, and the default tool count the pages give.

## Publish a release

A maintainer publishes a release by pushing a version tag. Only a version tag
starts a release, and the build takes its version from the tag. Pick a commit
on `main` with a passing `check` run from the merge queue, and tag it:

```sh
git fetch && git tag -a v0.3.0 -m "AtMcp 0.3.0" origin/main && git push origin v0.3.0
```

For a commit of `main` without a merge queue run, request one first with
`gh workflow run check --ref main`.

CI then:

1. checks the tag's form, `vX.Y.Z`, and that it follows the newest release as
   the next patch, minor or major version
2. checks the commit is on `main` with a passing `check` run
3. builds the Linux and macOS releases as that version and checks each one
4. upgrades the newest published release to the candidate and rolls back
5. publishes the GitHub release once both platforms pass
6. publishes the Hex package and its documentation

If the run fails before publishing, delete the tag with
`git push origin :refs/tags/v0.3.0` and tag again. If the GitHub release
publishes and the Hex step fails, rerun the failed job with
`gh run rerun RUN --failed`. Never reuse a published version number, because
servers may have fetched it and Hex keeps it. Fix the problem on `main` and
tag the next patch.

Give a change worth telling users about a "Changelog" section in its pull
request's description, with the entry as it should read. Leave CHANGELOG.md
alone in the pull request: entries written there conflicted on nearly every
merge. Before tagging, the maintainer cutting the release writes the
[CHANGELOG](CHANGELOG.md) section for the new version from those entries.
