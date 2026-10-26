# Contributing to at_mcp

This guide is for people who change at_mcp or publish its releases. Read
[AGENTS.md](https://github.com/GroveResearch/at_mcp/blob/main/AGENTS.md) first: it says what at_mcp is responsible for, where its
boundaries are, and what counts as evidence. [decisions.md](decisions.md)
records past decisions and the tests that hold them.

Plan a change in an issue with criteria that a test can check, and send it as a
pull request from a topic branch for independent review before it merges.

## Build a release

This developer path starts from a source checkout and needs Elixir 1.19,
a compatible Erlang/OTP, a C compiler and Make. Clone
[`GroveResearch/at_mcp`](https://github.com/GroveResearch/at_mcp), then run from
the checkout root:

```sh
mix deps.get
MIX_ENV=prod mix release               # _build/prod/rel/at_mcp
```

A build from a checkout is version `0.0.0-dev`; its `BUILD` file gives the
commit. To build it as a version, as CI does for a tag, set `RELEASE_VERSION`:
`RELEASE_VERSION=0.3.0 MIX_ENV=prod mix release`. Mix does not recompile when
only the version changes, so after building another version run
`MIX_ENV=prod mix clean` first; the release refuses to assemble otherwise.

For direct stdio, use the absolute path to `_build/prod/rel/at_mcp/bin/at_mcp-stdio`
as the command in the README's [client configuration](README.md#connect-claude-code). To use the
service units, first copy the build into their release layout. These commands
start at the source checkout root. Use a destination version that is not
already installed; do not copy over a running release.

On a Mac:

```sh
VERSION=$(cut -d' ' -f2 _build/prod/rel/at_mcp/releases/start_erl.data)
AT_MCP="$HOME/at_mcp"
test ! -e "$AT_MCP/releases/at_mcp-$VERSION" &&
  mkdir -p "$AT_MCP/releases" &&
  cp -R _build/prod/rel/at_mcp "$AT_MCP/releases/at_mcp-$VERSION" &&
  ln -sfn "releases/at_mcp-$VERSION" "$AT_MCP/current"
```

For the Linux system service:

```sh
VERSION=$(cut -d' ' -f2 _build/prod/rel/at_mcp/releases/start_erl.data)
AT_MCP=/opt/at_mcp
test ! -e "$AT_MCP/releases/at_mcp-$VERSION" &&
  sudo mkdir -p "$AT_MCP/releases" &&
  sudo cp -R _build/prod/rel/at_mcp "$AT_MCP/releases/at_mcp-$VERSION" &&
  sudo ln -sfn "releases/at_mcp-$VERSION" "$AT_MCP/current"
```

Continue with [Run a shared service](docs/operations.md#run-a-shared-service),
skipping its archive-install block. These source-install commands use no download
variables or tarball.

A release runs on the Erlang it was built with. An Erlang from Homebrew links
Homebrew's OpenSSL, so a release built with it loads `crypto` only on a Mac
with that same OpenSSL; CI requires distributable macOS releases to link
nothing outside macOS. In
a checkout, without a release, `mix at_mcp.server` runs the service in the
foreground with the environment of the shell.


## Develop and verify

Elixir 1.19, a compatible Erlang/OTP, a C compiler and Make, plus Node.js and
npm for the independent MCP client checks:

```sh
mix deps.get
mix check                     # format, compile with warnings as errors, test
MIX_ENV=prod mix release
```

### Independent client checks

Three tests drive AtMcp with the official MCP packages rather than a mock, and
skip with a reason when the packages are absent:

```sh
probe_dir=$(mktemp -d)
npm install --prefix "$probe_dir" --ignore-scripts --no-audit --no-fund \
  @modelcontextprotocol/sdk@1.29.0 @modelcontextprotocol/client@2.0.0
MCP_SDK_PATH="$probe_dir/node_modules/@modelcontextprotocol/sdk" \
MCP_CLIENT_PATH="$probe_dir/node_modules/@modelcontextprotocol/client" mix check
```

`test/at_mcp/http_client_test.exs` needs `MCP_SDK_PATH`; `test/at_mcp/stdio_test.exs`
and `test/at_mcp/shared_stdio_test.exs` need `MCP_CLIENT_PATH` as well. They use
disposable loopback accounts and publish nothing.

Two more tests exercise the built release and skip without it:

```sh
TEST_ACCOUNT_RELEASE="$PWD/_build/prod/rel/at_mcp" \
TEST_CONNECT_RELEASE="$PWD/_build/prod/rel/at_mcp/bin/at_mcp-connect" mix check
```

`test/at_mcp/account_release_test.exs` is gated on `TEST_ACCOUNT_RELEASE`.
`TEST_CONNECT_RELEASE` makes the shared stdio
test launch the release's `at_mcp-connect` instead of test beams. To drive the
release's `at_mcp-stdio` with the SDK probe directly, run
`test/support/stdio_sdk_probe.mjs` with both package paths,
`TEST_STDIO_RELEASE=1` and `TEST_MCP_COMMAND` pointing at it.

With every variable above set the suite reports no skipped tests. That is what
`.github/workflows/check.yml` runs on every pull request, from a fresh checkout, and it
fails if any test skips: a skipped interoperability check otherwise reads as a
pass.

Two scripts run a built release as [Install the service](docs/operations.md#install-the-service)
describes, against a loopback PDS, under a scratch root and HOME:

```sh
python3 scripts/foreground_boot_check.py "$PWD/_build/prod/rel/at_mcp"
python3 scripts/upgrade_rollback_check.py OLD_RELEASE_DIR "$PWD/_build/prod/rel/at_mcp"
```

The first starts it as the example launchd plist does and runs every operator
command against it, with no port mapper; the second upgrades from an older
release to this one and rolls back. With `--systemd` (as root) or `--launchd`
the second installs the example unit for real; those run only on a CI runner,
and the `release` and `macos` jobs of `check.yml` run them.

Dependencies use released Hex packages; package builds do not read local dependency path overrides.

### End-to-end round trips

The fake PDS in the tests answers as AtMcp's authors believe a service
answers. `test/e2e` checks that belief against upstream's own reference PDS and
AppView, from `@atproto/dev-env`, running on this machine at the atproto commit
the vendored lexicons come from. No account on any real network is involved,
and nothing leaves localhost. One command builds what it needs, starts the
network, runs the suite and stops everything:

```sh
scripts/e2e.sh                # or scripts/e2e.sh test/e2e/round_trip_test.exs:LINE
```

It needs git, Node 22.19 or later and pnpm 11.11.0. The first run fetches and
builds atproto under `_build/e2e` (`AT_MCP_E2E_DIR` moves it), which takes a
minute or two; after that a run takes about ten seconds. Without
`DB_POSTGRES_URL` and `REDIS_HOST` it starts a private Postgres and Redis
(`initdb`, `pg_ctl`, `redis-server` on PATH) in a scratch directory and removes
them afterwards. The tests are tagged `:e2e` and excluded from `mix check`;
`.github/workflows/e2e.yml` runs them on request.

`AtMcp.Test.DevNetwork` runs `test/support/dev_network.mjs`, which starts the
network with two accounts and a feed generator, and points AtMcp at its
AppView through `config :at_mcp, appview: [service: ..., url: ...]`
(`AtMcp.Network`), the one setting that exists for this. Each write tool is
written, read back through the read tools as the AppView serves it, undone,
and read again; between a write and a read the suite waits until the AppView
has indexed everything the PDS sequenced, rather than sleeping.

| Write tools | Read back with |
| --- | --- |
| `post` (reply and quote rules, images), `set_post_interactions`, `delete_post` | `get_thread` viewer, `get_record` on the gates, `get_post_images`, `get_posts` |
| `reply`, `hide_reply`, `unhide_reply` | `get_thread` |
| `detach_quote`, `reattach_quote` | `get_posts` (the quote's status) |
| `like`, `unlike`, `repost`, `unrepost` (by a handle-form uri) | `get_posts` viewer and counts, `get_likes`, `get_reposted_by` |
| `follow`, `unfollow`, `block`, `unblock`, `mute`, `unmute` | `get_relationships`, `get_followers`, `get_blocks`, `get_mutes` |
| `mute_thread`, `unmute_thread`, `bookmark`, `unbookmark` | `get_posts` viewer, `get_bookmarks` |
| `update_seen` | `get_unread_count` |
| `pin_post`, `unpin_post`, `set_status` | `get_record` (`get_profile` shows neither) |
| `update_profile` (fields, avatar, links) | `get_profile`, `get_record` |
| `create_list`, `add_to_list`, `update_list`, `remove_from_list`, `delete_list` | `get_list`, `get_lists` |
| `create_starter_pack`, `set_list_opt_out`, `update_starter_pack`, `delete_starter_pack` | `get_starter_pack`, `get_list` |
| `save_feed`, `unsave_feed` | the account's preferences, read from the PDS |
| `set_preference` (each preference kind; `discoverable`, `activity_subscriptions`) | `get_preferences`, the preferences read from the PDS, `get_record`, another account's `get_profile` |
| `set_notification_setting` | `get_notification_settings` |
| `subscribe_to_activity` | `get_profile`, `get_activity_subscriptions` |
| `like` by another account, `unlike` | `get_notifications` with `grouped` |
| `save_draft`, `delete_draft` | `get_drafts` |

What it cannot do locally:

- `feed_feedback` gets only as far as its refusal: dev-env's feed generator does not
  accept interactions or serve `sendInteractions`, and nothing reads feedback
  back.
- A compare-and-swap that loses a race cannot be provoked through a tool, so
  the suite writes over a stale record and a stale commit directly and checks
  the reference PDS refuses both with the `InvalidSwap` AtMcp recognizes.
- dev-env is Bluesky's AppView, so only the `app.bsky` namespace runs here; the
  delve.town-only reads (`get_membership`, `get_invite_codes`) and that
  network's own AppView are not covered.

### Check a live account

Fixtures prove mechanics. Only a live service shows what it actually serves.
Read-only, against a running shared service:

```sh
MCP_CLIENT_PATH="$probe_dir/node_modules/@modelcontextprotocol/client" \
  AT_MCP_GRANT="$(at_mcp-accounts connection NAME | jq -r '.mcp.headers[0].value' | cut -d" " -f2)" \
  node scripts/live_contract_check.mjs \
  /path/to/release/bin/at_mcp-connect http://127.0.0.1:4400/mcp did:plc:...
```

It checks that every tool advertises its output schema, that structured content
matches the text on real responses (its JSON, or for reads made of posts a text
listing every post), and that refusals arrive as codes. It
calls no write tool.

`scripts/pds_read_probe.exs` logs into an authorized account with writes
disabled and reads its profile; set the account credentials, `AT_MCP_SERVICE`
and `EXPECTED_DID` (and `_2` values for a second account), then
`MIX_ENV=test mix run --no-start scripts/pds_read_probe.exs`.

### What counts as evidence

A claim is established when a test fails if you revert the change that makes
it true. Use a focused test while changing behavior and the full check before
merging. Test what a caller can observe, such as the selected identity, accepted
activity, the returned result and durable recovery, rather than prose or
internal structure.
Where a check cannot run without credentials, a network or a machine, say so
in the test with `@tag skip:` and a reason, and give the `test` job in
`check.yml` its environment so the gap is visible in CI rather than in a document. When a live
check finds what a fixture missed, write the test that fails without the fix,
and write down in the pull request what was run.

Two more checks keep the documentation true. `docs/tools.md` is written by
`mix at_mcp.tools_doc` from the tools the server declares, and
`test/at_mcp/tool_surface_test.exs` fails when the file is out of date. Run the
task and commit the result whenever a tool or its description changes.
`scripts/download_release_check.py` runs the README's download and install
blocks against a local copy of a built release, so those blocks must stay
runnable as written.


## Publish a release

Only a maintainer publishes a release. One tag publishes both the GitHub
binary release and the Hex package. CI's upgrade check installs the newest
published release that qualifies, upgrades it to the candidate and rolls back
([Older baseline](#older-baseline) covers the case with no earlier release). Do
not skip the check or use a rebuilt candidate as its own previous release.

Pushing a version tag publishes one; a merge to `main` does not. The tag is
the version: nothing in the repository changes to cut a release. Tag a commit
of `main` whose run of `check` passed in the merge queue, with `v` and the
version (for 0.3.0); the tag can go on as soon as the pull request merges:
main moves to the commit the queue tested, and `check` does not run on main
again.

```sh
git tag -a v0.3.0 -m "AtMcp 0.3.0" origin/main && git push origin v0.3.0
```

(`origin/main` after a `git fetch`; any older commit of main that passed works
too. A commit of main that never went through the queue needs a requested run
first: `gh workflow run check --ref main`.) CI refuses a tag that is not
`vX.Y.Z`, or whose commit is not on main or has no passing run of `check` in
the merge queue or requested on main, before anything is built
(`scripts/release_version.sh`). It does not run the tests again; it builds the
Linux and macOS releases as that version (`RELEASE_VERSION`, which `mix.exs`
reads), checks each as the queue does, and publishes only after both
platforms pass. Publication requires both exact-version tarballs and their
checksum files; a partial platform build does not create or replace a
release. Once the GitHub release is published, CI writes the version into the
package's `VERSION` file and publishes the package and its docs to Hex with
`mix hex.publish`, using the `HEX_API_KEY` secret in the repository's `hex`
environment.

When a tag's run does not finish:

- Refused, or failed before `publish`: nothing was published. Delete the tag
  (`git push origin :refs/tags/v0.3.0`) and tag again.
- `publish` succeeded and `hex` failed: re-run the failed `hex` job
  (`gh run rerun RUN --failed`); the GitHub release stands.
- Never reuse a version that was published to GitHub or Hex: a server may
  have fetched it, and Hex keeps it. Fix on main and tag the next patch.

The tag check also refuses a version that is not the next patch, minor or
major after the newest release tag (after v0.2.11: v0.2.12, v0.3.0 or
v1.0.0), so a typo cannot publish.

Upgrade notes are not a release step. A pull request that changes what an
upgrade needs, or what an operator notices, adds its note under
[Upgrade](docs/operations.md#upgrade) in that same pull request, in a section headed
`From A to the next release`, A being the newest release; the first pull
request after a release renames that heading to the version it was released as.


## Older baseline

The upgrade check needs an earlier release to upgrade from.
`scripts/published_release.py` picks the newest published at_mcp release that
qualifies. Only when there is none does it fall back to the build that
`scripts/legacy_baseline.json` lists: an older 0.1.2 build of this program,
published as a prerelease on the releases page with license notices added. The
script checks each archive's SHA-256 and its `BUILD` file against the manifest,
and fails if anything is missing or differs. A failure to fetch an ordinary
release never falls back to the baseline.

`scripts/repack_legacy_baseline.py` makes those archives from the original ones
and a reviewed notice tree holding `LICENSE` and `licenses/`. The notice tree
must list the dependency and runtime versions of the old build. The current
build's versions are wrong for it. It keeps every
original file's bytes, mode and symlink target, and adds the notices and
`BASELINE_PROVENANCE.json`, so the repacked archives have new SHA-256 values:

```sh
python3 scripts/repack_legacy_baseline.py linux-x86_64 ORIGINAL NOTICE_TREE OUTPUT
```

Run it for `macos-arm64` too. The script checks the original archives' hashes.
It cannot tell whether a notice tree is complete, so review the notices
separately. `scripts/published_release_test.py` tests this path in CI.

## Bootstrap a new repository

To start a new public copy of this repository with no release history:

1. Push the reviewed source snapshot to a branch named `bootstrap`.
2. Publish the repacked baseline archives and their checksum files as a
   prerelease, not marked latest, under the tag the manifest gives. Its release
   notes say which source commit built the binaries, and that only notices and
   `BASELINE_PROVENANCE.json` were added. That tag
   does not start the release workflow, which runs only on `v*` tags.
3. Download the archives without signing in and compare them with the
   manifest's digests and `BUILD`. Then push the snapshot to `main` and make it
   the default branch. From then on, the upgrade check in each merge queue run
   upgrades from the baseline until a `v*` release exists.
4. Publish the first `v*` release only after `check` passes on `main`.
