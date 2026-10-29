# Decisions

This file lists the design decisions at_mcp depends on, one bullet per decision. Each bullet starts with the date of the commit that put the decision into code and its status: settled, or provisional while a stated condition could still change it. The bullet then gives the decision and its reason. Where a decision works around a defect elsewhere, it also says what would make the workaround unnecessary. After "Evidence:" come the tests and code that fail if the decision stops being true. An entry marked `unverified` has a reason but no test. When AtMcp stops following a decision, its entry is deleted, and `git log -S` finds it in the history.

## Name

- 2026-10-02, settled. The package, OTP application and release are `at_mcp`, and the Elixir namespace is `AtMcp`. The name says what the program is: an MCP server for one persistent AT Protocol identity.
  - The header confirming an account is `x-at-mcp-account-did`, the annotation on a publishing write tool is `at_mcp/publicWrite`, and a new grant's token starts with `at_mcp-` (#181).
  - The endpoint ignores the earlier `x-kite-account-did` header, and no tool carries `kite/publicWrite` (#195, released in 0.2.18).
  - A grant whose token starts with `kite-` still authorizes. AtMcp looks a grant up by the digest of the whole token, so its prefix makes no difference.
  - Evidence: `test/at_mcp/account_binding_test.exs` "the header's earlier name, x-kite-account-did, is no longer read"; `test/at_mcp/publishing_quota_test.exs` "every mutating tool's description and annotation say what the quota does to it"; `test/at_mcp/grants_test.exs` "a grant issued under the earlier kite- prefix still authorizes" and "a new grant's token starts with at_mcp-".

## Responsibilities

- 2026-09-09, settled. AtMcp acts for one AT Protocol account per DID and handles what an agent needs to act as it: credentials, the session and its refresh, readiness and disconnect, the durable per-DID write quota, the MCP tools, and durable delivery of incoming activity. Conversations, permission decisions and an agent's behavior belong to the host. One process serves each configured account for now, and the provisional entry under Writes covers aliases of a DID. Evidence: `AGENTS.md`; `AtMcp.Effects`; `test/at_mcp/effects_identity_test.exs`.
- 2026-09-13, settled. AtMcp bounds writes per account per hour, and sets no limit per turn. The host runs the turn, so a limit on a turn is the host's policy. `AtMcp.Identities.start_identity_runtime/1` raises when given a turn option (`host_token`, `max_writes_per_turn`, `max_posts_per_turn`, `require_turn`). Evidence: `test/at_mcp/account_quota_boundary_test.exs`.
- 2026-09-11, settled. An operator asks which identities an installation holds through the control listener (`AT_MCP_CONTROL_PORT`), and its answer carries no credential. No MCP tool lists the identities, so an agent knows only the one its grant gives it. Evidence: `AtMcp.Control`; `test/at_mcp/telos_test.exs` "no tool lets an agent enumerate the installation's identities".
- 2026-09-06, settled. `identity_status` reports the session and the write quota. A person in the app has no such tool. An agent needs one to learn how many writes it has left and when the window resets. Evidence: `AtMcp.MCP.Server`; `test/at_mcp/mcp_tools_test.exs`.
- 2026-09-23, settled. AtMcp offers no tool for declining to act. An agent ending its turn without calling a write tool has posted nothing, so a tool for saying so would change nothing on the account. Evidence: `test/at_mcp/mcp_tools_test.exs` "a read returns text alone, and its summary when asked; a write returns its summary" lists every tool.

## Credentials and access

- 2026-10-07, settled (#19). `config/runtime.exs` reads and checks every setting an operator gives through the environment, once, at boot, with each default beside its check. Code in `lib/` reads only the application environment.
  - An unknown `AT_MCP_*` variable or a bad value stops startup, and the error gives the variable.
  - `AtMcp.CLI.settings/0` prints each setting's value and source, and prints a secret only as set or unset.
  - The account variables are `AT_MCP_HANDLE`, `AT_MCP_APP_PASSWORD` and `AT_MCP_SERVICE`, with a `_2` set for a second account. The earlier `BLUESKY_*` names still work with a warning, because existing client configurations and environment files use them.
  - Test harness variables start with `TEST_`, outside the namespace the check covers.
  - Evidence: `config/runtime.exs`; `test/at_mcp/settings_test.exs`.
- 2026-10-05, provisional (#5). With `AT_MCP_APPVIEW_READS=direct`, an application GET needing an AppView goes straight to the AppView with a short-lived service token bound to its method. The default, `proxy`, sends every read through the account's PDS, as the entry under Network and records says. Preferences and writes go through the PDS either way. The direct route has been tried only against the fixed endpoints in `AtMcp.Network`, and other providers are untested. Evidence: `AtMcp.ATProto.ServiceAuth`; `test/at_mcp/direct_service_auth_test.exs`.
- 2026-09-11, settled. One loopback MCP endpoint (`AT_MCP_PORT`, 4400 by default) serves every identity. The `Authorization: Bearer <grant>` header decides which identity a request acts as, and a request without a grant gets `401`. Two clients on one machine share an address, so the credential separates them. Evidence: `AtMcp.MCP.HTTP`; `test/at_mcp/mcp_http_test.exs` "the endpoint refuses a caller that presents nothing"; `test/at_mcp/telos_test.exs` "one endpoint serves every identity".
- 2026-09-11, settled. `x-at-mcp-account-did` confirms the grant's account and selects nothing. A host told a DID may send it, and a grant for a different account gets `409`, which catches a stale or mistyped configuration. Evidence: `AtMcp.MCP.HTTP`; `test/at_mcp/mcp_http_test.exs` "one listener serves every identity, and a grant reaches only its own".
- 2026-09-11, settled. A grant's scope (`read`, `write` or `manage`) comes from each tool's own `readOnlyHint` and `destructiveHint`. A hand-kept list of tool names would drift from the tools. A tool without hints is permitted by no scope, so a renamed tool fails closed. Evidence: `AtMcp.Grants`; `test/at_mcp/mcp_http_test.exs` "a grant's scope bounds the tools it reaches, from the tools' own hints".
- 2026-09-11, settled. Grants live in a 0600 file of their own beside the accounts file, which stores only digests of the tokens. Deleting that file revokes every grant and keeps every identity. Removing an account revokes its grants. Evidence: `AtMcp.Grants`; `test/at_mcp/grants_test.exs`; `test/at_mcp/account_edit_test.exs` "removing an account revokes the grants that name it".
- 2026-09-11, settled. AtMcp runs no authorization server or introspection endpoint and requires no TLS, because it listens on loopback on one person's machine. A grant travels as `Bearer`, the standard form, so a later issuer-signed token would need no client change. Evidence: no `oauth` in `lib/`; `AtMcp.Grants` moduledoc.
- 2026-09-11, settled. An account logs in with an app password, and AtMcp uses neither MCP's OAuth nor AT Protocol's. One installation serves one operator's accounts on loopback, so no second party needs to authorize it. A hosting service serving many people would have that need. Evidence: `AtMcp.AccountSetup`; `AtMcp.Grants` moduledoc; unverified as a test.
- 2026-09-07, settled. `at_mcp-connect` gives a stdio client a connection to the shared service and holds no account password. Evidence: `test/at_mcp/shared_stdio_test.exs`; `test/at_mcp/account_setup_test.exs`.
- 2026-09-11, settled. `at_mcp-connect` receives its grant in `AT_MCP_GRANT` and takes none in its arguments, since every process on the machine can read another's command line. Evidence: `AtMcp.SharedConnection`; `test/at_mcp/account_setup_test.exs` ("Not in argv, where every process on the machine could read it"); `test/at_mcp/shared_stdio_test.exs`.
- 2026-09-11, settled. A grant is a bearer token on loopback, unbound to the process holding it. It separates what each client was given, and any process able to read a grant can use it, so a grant is no sandbox. The write quota is no authorization boundary either. Evidence: `AtMcp.Grants` moduledoc; unverified as a test.

## Configuration

- 2026-09-11, settled. An installation's accounts come from one place: the accounts file `at_mcp-accounts` manages (`AT_MCP_ACCOUNTS_FILE`, or the platform's user configuration directory). No environment variable adds, removes or reauthorizes an account behind it, so the file always lists the accounts the service runs. Evidence: `test/at_mcp/telos_test.exs` "an installation is configured one way".
- 2026-09-11, settled. When no accounts file exists, AtMcp reads the account variables (`AT_MCP_HANDLE` and `AT_MCP_APP_PASSWORD`, or their `BLUESKY_*` names, and the `_2` pair) once, logs in with each, and writes the file. A failed login writes nothing. With a file present, even an empty one, the variables go unread, so the set of accounts cannot change under an installation. Evidence: `AtMcp.AccountSetup.bootstrap_from_env/2`; `test/at_mcp/account_setup_test.exs` "an installation configured by account variables migrates itself into the accounts file".
- 2026-09-11, provisional. AtMcp drops a per-account `mcp_port` key when it loads an accounts file, and the next write leaves it out. Refusing such a file as corrupt would lose an operator their accounts. A caller passing `mcp_port` gets a refusal. The entry can go once no installation has a file written before one endpoint served every account. Evidence: `AtMcp.AccountConfig`; `test/at_mcp/account_config_test.exs` "a file that still carries per-account ports loads without them".
- 2026-09-11, settled. With no accounts file, the service starts with no accounts. A file AtMcp cannot read is reported as unreadable, because reporting it as empty would send an operator to add accounts they already have. Evidence: `test/at_mcp/telos_test.exs` "a configuration that cannot be read is reported as unreadable, not as empty".
- 2026-09-07, settled. AtMcp writes its private files (the accounts file, grants, quota, read positions and state) with mode 0600, as a read-modify-write under one lock, and refuses a file with looser permissions or a symlink. Evidence: `test/at_mcp/account_config_test.exs` "insecure files and symlinks rejected".
- 2026-09-11, settled. That file handling lives in `AtMcp.PrivateFile` alone, and each store calls it. A second copy would be a second chance to lose an operator's credentials. Evidence: `AtMcp.PrivateFile`; `AtMcp.AccountConfig`, `AtMcp.Grants` and `AtMcp.ReadPositions` call it.
- 2026-09-07, settled. `at_mcp-stdio` runs one account for one client over stdio, stops at end of input, opens no port and collects no notifications. It reads its settings from `AT_MCP_STDIO_ENV_FILE` and unsets the service's `AT_MCP_ENV_FILE`, so a shared service's settings cannot pick this client's account. Evidence: `rel/overlays/bin/at_mcp-stdio`; `AtMcp.Stdio`; `test/at_mcp/stdio_startup_test.exs`; `test/at_mcp/stdio_test.exs`.
- 2026-09-12, settled. The network applies to a whole installation. Running against Bluesky and Delvetown at once takes two installations, each with its own unit, environment file, accounts file, ports, grants and `RELEASE_NODE`. Evidence: `AtMcp.Network`; `docs/operations.md` "Run a second installation"; `test/at_mcp/account_release_test.exs` "release account commands manage one daemon across live configuration changes" (a second installation runs beside the first).
- 2026-09-28, settled. Erlang distribution serves only as the release's local control channel (`rpc`, `remote`), and it runs without a port mapper. A mapper shared by several releases on one machine belonged to whichever release started it, and under systemd it stopped with that unit.
  - The service listens on 127.0.0.1 at `AT_MCP_DIST_PORT` (4370 by default). `rpc` and `remote` connect straight to that port and listen on nothing. A second installation sets its own port.
  - OTP still offers the node's name to a mapper on 127.0.0.1 if one is running, and nothing depends on it.
  - A node name without a host gets a loopback one (`localhost`, or `127.0.0.1` under `RELEASE_DISTRIBUTION=name`), because the machine's hostname can resolve to an address where nothing listens.
  - `eval` gets no port.
  - Evidence: `rel/vm.args.eex`, `rel/remote.vm.args.eex`, `rel/env.sh.eex`; `scripts/foreground_boot_check.py` (started as the example plist starts it, with no mapper reachable, every operator command answers and the node listens on 127.0.0.1 alone); `test/at_mcp/account_release_test.exs` "release account commands manage one daemon across live configuration changes" and "the distribution port is 4370 unless the environment file names another, and eval gets none".
- 2026-09-29, settled. AtMcp installs and runs as an ordinary Elixir release. An operator then uses the tools they already know, and AtMcp carries no installer, upgrade or service manager code to maintain.
  - CI builds and publishes the release. A machine runs `bin/at_mcp start` under systemd or launchd from the example units in `rel/examples/`, which the release includes as `examples/`.
  - Settings come from one environment file of `NAME=value` lines, with a value containing a space in double quotes. The file carries the installation's own `RELEASE_COOKIE`. A command run from a shell loads the same file when `AT_MCP_ENV_FILE` gives its path.
  - To upgrade, an operator downloads the tarball and its `.sha256`, checks it, unpacks it beside the running release with `tar --no-same-owner`, repoints `current` and restarts. To roll back, the operator repoints `current` and restarts.
  - `docs/operations.md` holds the install documentation, with the README's "Fetch a release" for a Mac. Release tarballs record root as the owner of every entry.
  - Evidence: `rel/examples/`; `rel/env.sh.eex`; `test/at_mcp/release_env_test.exs`; `scripts/foreground_boot_check.py`; `scripts/upgrade_rollback_check.py` (run under the example systemd unit and the example launchd plist by `check.yml`); `scripts/tarball_owner_check.py`.
- 2026-09-25, settled. AtMcp's MCP tool names and argument types are public. Agents and hosts call tools by name, and an upgrade must not break a caller that worked the day before.
  - A published tool or argument stays served with its type, and no argument becomes newly required.
  - A rename serves the old and new names together. The old name's entry gets `remove_after` with a date, ninety days later by default, and its description gives that date. After the date the old name goes.
  - A tool left out of a session's list, by the default tool set (`AtMcp.MCP.ToolSet`) or by a network that does not serve it (`AtMcp.MCP.Served`), is still published, and `tools/call` accepts it.
  - Evidence: `test/support/tool_surface.json`; `test/at_mcp/tool_surface_test.exs`; `test/at_mcp/tool_set_test.exs`.

## Network and records

- 2026-09-11, settled. The network is a value (`AtMcp.Network`, `AT_MCP_NETWORK`), and every NSID AtMcp uses derives from it. A literal `app.bsky` anywhere else in `lib/` is a defect. `com.atproto.*` and `chat.bsky.*` stay literal, because they are the same on every network. Evidence: `test/at_mcp/network_test.exs`; `test/at_mcp/telos_test.exs` "the network AtMcp talks to is a value, not a literal".
- 2026-09-11, settled. An unrecognized `AT_MCP_NETWORK` raises, and AtMcp has no fallback to Bluesky. Evidence: `test/at_mcp/network_test.exs` "an unrecognized network raises rather than falling back".
- 2026-09-11, settled. AtMcp reads post text limits from the lexicon at compile time and never copies the numbers by hand. `priv/lexicons` holds a copy of `feed/post.json` for each network, because no dependency of AtMcp includes either namespace's lexicons. The copies can go when a dependency includes them. Evidence: `priv/lexicons/README.md`; `test/at_mcp/network_test.exs` "are the numbers in each network's own lexicon".
- 2026-09-11, settled. AtMcp builds every record it writes in `AtMcp.ATProto` and sends it with the `com.atproto.repo` methods (`createRecord`, `putRecord`, `applyWrites`). Nothing in `lib/` calls `ProtoRune.Bsky` or `ProtoRune.Atproto.Repo.create_record/3`. proto_rune 0.6 validates records through Peri schemas, which drop an `embed` and stamp `langs: ["en"]` on every post. AtMcp keeps building its own records even if that is fixed, because the builder decides which network a record goes to. Evidence: `test/at_mcp/write_records_test.exs`; `test/at_mcp/telos_test.exs` "AtMcp builds the records it posts".
- 2026-09-11, settled. Every read goes through `AtMcp.ATProto` to the session's own service URL, so an account hosted elsewhere sends no read to Bluesky by default. This works around proto_rune's fixed `default_base_url` and `plc.directory` resolver. Evidence: `test/at_mcp/network_test.exs` "every declared read and write carries the namespace"; `test/at_mcp/pds_test.exs`.
- 2026-09-12, settled. An optional field filled in with nothing is left out of the record. Evidence: `test/at_mcp/write_records_test.exs` "an optional filled in with nothing is absent, not a value".
- 2026-10-29, provisional (#202, #220). A read answers in text unless asked for JSON, and `tools/list` gives no output schema for any tool.
  - Hosts differ in which half of a result they give the model. Claude Code, Codex CLI and VS Code Copilot give it `structuredContent` whenever a result has some. Gemini CLI, Goose, the LangChain adapters, the OpenAI Agents SDK and Imp's default give it `content`. With both halves, agents in Claude Code read the JSON (37.7 KB for a 20-post page whose text is 14.9 KB) and missed the markers around quoted post text.
  - The specification requires a tool with a declared output schema to return structured content matching it. A read returns text alone, so it declares none. The write schemas made up 243 KB of a 338 KB tool list, so writes list none either (#220).
  - A read takes `format`: `text`, the default, or `json`. A grant may carry `format: "json"` as the default for a program. With json, a read returns the summary as `structuredContent` and as the same JSON in its text, so a program gets JSON from either half. A refusal keeps its message as text.
  - A write returns its summary as `structuredContent` and as the same JSON in its text.
  - `AtMcp.MCP.Server.__output_schemas__/0` keeps every tool's schema, and `AtMcp.MCP.Output` checks each result against it.
  - The entry retires or becomes settled when the specification says which half the model reads.
  - Evidence: `AtMcp.MCP.Output`; `AtMcp.MCP.DSL`; `test/at_mcp/hosts_test.exs` "Claude Code's model receives the text of a read, not its JSON"; `test/at_mcp/mcp_tools_test.exs` "a read returns text alone, and its summary when asked; a write returns its summary"; `test/at_mcp/read_tools_test.exs`; `test/at_mcp/grants_test.exs`.
- 2026-09-08, settled. `AtMcp.Summary` declares each kind of record an agent receives, once. The backend builds summaries with it and the output schemas derive from it, so a schema cannot describe a field the tool does not return. Evidence: `test/at_mcp/summary_test.exs` "each shape reads exactly the fields it describes"; `test/at_mcp/mcp_tools_test.exs` "a read returns text alone, and its summary when asked; a write returns its summary" (every tool's result passes its schema).
- 2026-10-18, provisional. Each field of a recorded AppView response either appears in a summary or appears in `AtMcp.LeftOut` with the reason it is left out, or as `{:todo, issue}` when it hides something the Bluesky app shows. The test changes each field and compares summaries, so nobody marks a field as kept by hand.
  - The recordings are public responses with every string replaced except lexicon enumerations, timestamps shifted, and the source account left out (`scripts/record_appview_fixtures.py`).
  - Viewer state and notifications come from an account's own reads on the end-to-end suite's local network (`AT_MCP_E2E_RECORD`), scrubbed the same way.
  - Evidence: `test/at_mcp/field_coverage_test.exs`.
- 2026-10-19, provisional (#82). An agent can do what a person can do in the Bluesky app, reads and writes alike. `AtMcp.Endpoints` has one entry for every query, procedure and record type in the lexicons: the tool doing it, `{:todo, issue}` for something a person can do and at_mcp cannot yet, or `{:left_out, reason}`.
  - The table is the same on every network. `AtMcp.Endpoints.deployments/0` lists, with evidence, what one deployment does not serve (on delve.town: chat, video and trends).
  - `scripts/list_lexicon_endpoints.py` writes the list in `test/fixtures/lexicon_endpoints.txt` from an atproto checkout, so a lexicon added upstream fails the test until the table says what at_mcp does with it.
  - The work is split by area: #88 threads and posts, #89 lists and starter packs, #90 moderation, #91 preferences and notification settings, #92 direct messages, #93 feeds, discovery and profile, #96 video.
  - Evidence: `test/at_mcp/endpoint_coverage_test.exs`.
- 2026-10-19, provisional (#93). When `AtMcp.Endpoints.deployments/0` says this network's deployment does not serve a tool's method, the tool refuses before sending anything, as `not_served` with the method and the evidence (`AtMcp.Effects.served/1`). Nothing is counted.
  - When one tool reads several methods (the places the app suggests accounts, trends or topics), AtMcp refuses only the call needing the missing method.
  - `tools/list` leaves out a tool none of whose methods the network serves, and an argument whose method it does not serve (`AtMcp.MCP.Served`).
  - The unspecced suggestion and trend reads take at most 25 a page, their lexicons' maximum (`AtMcp.Effects.short_page_max/0`), where other pages take 50.
  - Evidence: `test/at_mcp/discovery_test.exs` "what the town does not serve is refused before anything is sent"; `test/at_mcp/served_test.exs`; `test/at_mcp/limits_test.exs`.
- 2026-10-19, provisional (#93). `save_feed` and `unsave_feed` read the account's preferences as raw JSON, change one entry the way the app's library does, and write every other preference back as stored.
  - `actor.putPreferences` has no compare-and-swap, so the description and the result warn that a change another client makes meanwhile is lost. The account's process orders the write with the account's other writes.
  - Where AtMcp can guard a record write, it does: the profile and the live status are written, and the status cleared, with `swapRecord` over the version read.
  - None of the #93 writes counts against the write quota.
  - Evidence: `test/at_mcp/feed_profile_writes_test.exs`.
- 2026-10-19, provisional (#91). AtMcp changes the account's settings the way the app's library does (`AtMcp.Preferences`): one kind at a time, changing the last valid preference of a type, dropping the others of that type and keeping every other preference as stored.
  - AtMcp writes the two declaration records over the version read. When it read none, it writes with a null `swapRecord`, so a record created meanwhile is not overwritten. The profile and live status writes do the same.
  - AtMcp leaves out or refuses, before sending anything, a setting the app would not show. It leaves out `hideRepliesByUnfollowed`, which the app ignores. It offers the interests the app offers or the account already has, and the three thread sorts the app offers. It turns adult content on only for an account whose declared age is 18 or over. It refuses a subscription the subject's declaration does not allow. It leaves chat's notification settings to the chat service, since `putPreferencesV2` does not keep them.
  - A setting already as asked writes nothing. A result lists the fields that changed, with each setting before and after.
  - AtMcp never writes or returns the birth date.
  - None of these writes counts against the write quota.
  - Evidence: `test/at_mcp/preferences_test.exs`; `test/e2e/round_trip_test.exs`.
- 2026-10-29, provisional (#204). at_mcp stores each account's read position per feed (timeline, list feed, author feed, notifications), as the time of the newest item read: the AppView's sort time in a feed, the indexing time in the notifications. Custom feeds get no position, because their generators set the order.
  - A read moves the position forward when it passes `since: "last_read"` without `mark_read: false`, or `mark_read: true` without `since`.
  - A page stopping short of the old position stores its newest time as pending, and the read getting back to the position commits it.
  - Positions are kept per DID in `read-positions.json` under `AtMcp.PrivateFile`'s lock, so every client of the account shares them.
  - Evidence: `AtMcp.ReadPositions`; `AtMcp.MCP.Tools.page/5`; `test/at_mcp/read_position_test.exs`.
- 2026-10-29, provisional (#137, #203). `get_thread` calls `unspecced.getPostThreadV2` with the parameters social-app's `usePostThread` (62b95002) uses: every parent, the account's `threadViewPref` sort (`top` by default) and its view.
  - The linear view reads 10 levels with one reply under each reply. The tree view reads 4 levels with 10.
  - `depth` and `breadth` override the view within the lexicon's limits (0 to 20, 0 to 100).
  - AtMcp keeps the service's order and rebuilds its flat answer into the nested summary.
  - When the thread settings fail to load, AtMcp reads the thread with the app's defaults.
  - `get_thread_chain` calls `getPostThread`.
  - Evidence: `AtMcp.Effects.ProtoRune.get_thread/3`; `test/at_mcp/thread_test.exs` with `test/fixtures/appview/thread_v2.json`.
- 2026-10-19, provisional (#131). Reads mark what the app would hide, cover or flag, and filter nothing (`AtMcp.ModerationMarks`).
  - Posts in pages, threads and chains, and accounts in `get_profile`, `get_profiles` and `search_actors`, carry `moderation`: the causes the app acts on where it would show them, with what it does (hide, cover, cover_media, alert, inform) and why (a label with its labeler and the account's setting for it, a muted word, a mute or block). The text reading gives one line for it.
  - The decision is the app's moderation module (`@bsky/sdk` 1.2.0, bluesky-social/bsky packages/sdk at 4d511036, whose logic is `@atproto/api`'s at 9f66a7e), ported as it is in `AtMcp.ModerationDecision`, each part citing its source.
  - A `get_thread` reply the app's thread view moves (social-app `usePostThread` at 62b95002) says it is under "Show more replies" or left out. In a thread nothing is left out, only covered (PostHider with `interpretFilterAsBlur`). On a profile, the profile account's own posts are never left out and their mutes are dropped (`ignoreFilterFor`).
  - Each read loads the account's preferences once, and loads labeler definitions once more only when the read carries labels from the account's labelers. A read unable to get them says so in `moderation_unread` and marks nothing.
  - Hidden posts are left out (#90).
  - Notifications, lists, feed generators and the other account pages carry no marks yet.
  - Evidence: `test/at_mcp/moderation_decision_test.exs`; `test/at_mcp/moderation_marks_test.exs`; `test/e2e/round_trip_test.exs` "reads mark what the app would hide".
- 2026-10-19, provisional (#83). Every application-namespace read sends `atproto-accept-labelers` as the app does (@atproto/api's `labelersHeader`): the network's own moderation service with `;redact`, then the labelers in the account's last valid `labelersPref`.
  - Without the header the AppView returns its default labelers' labels only, and a label from a labeler the account subscribes to never arrives.
  - The reference PDS forwards the header when it proxies a read. The end-to-end test fails with the header removed.
  - `AtMcp.AcceptLabelers` keeps the subscribed list per DID and service, from the last preferences read or written. An account's first read loads the preferences first. When that load fails, the read sends the network's service alone and tries again next time.
  - Evidence: `test/at_mcp/moderation_test.exs` "a read asks for the labels of the network's labeler and the account's own"; `test/e2e/round_trip_test.exs` "a label from a labeler the account subscribes to arrives once it subscribes".
- 2026-10-19, provisional (#90). Moderation does what the app's moderation settings and report dialog do (`AtMcp.Moderation`).
  - AtMcp changes muted words, labeler subscriptions and label settings as `@atproto/api`'s helpers change them, and keeps every other preference as stored.
  - AtMcp refuses, before sending anything, what the app would not show:
    1. a label setting for a labeler the account takes no labels from;
    2. an adult content filter while adult content is off;
    3. a label missing from the labeler's own list in the app (its `labelValues`, without a `!` prefix, with a definition the lexicon accepts);
    4. a mute or block of a list other than a moderation list;
    5. a labeler past the app's limit of 20, giving any labelers gone from the network, which the app would drop first.
  - Settings are reported as the app shows them. A `defaultSetting` other than hide or ignore reads as warn, and warn on a label without blur or warning reads as show.
  - A muted word returned by `unmute_word` can be muted again exactly (`targets`, `expires_at`).
  - Hidden posts are left out, because the app keeps them on the device.
  - A report goes through the PDS's `atproto-proxy` to the network's own moderation service, or to a subscribed one accepting this subject and reason. On delve.town, the network's own service is the town's moderation service (`did:plc:7voo3hmmzshypkn34iam3mg5`, moderation.delve.town). Its PLC document gives its labeler endpoint, and the town's web app reports to it.
  - A list, post or account given by handle is sent in DID form.
  - Reports publish nothing and do not count against the write quota.
  - Evidence: `test/at_mcp/moderation_test.exs`; `test/e2e/round_trip_test.exs` "moderation".
- 2026-09-07, settled. Batch reads check their own limits locally: pages take 1 to 50 items, and `get_posts`, `get_profiles` and `get_relationships` take 1 to 25 entries, as the lexicons declare. An oversized list fails before any request. Evidence: `test/at_mcp/mcp_read_pages_test.exs` "invalid page sizes fail before the backend is called"; `test/at_mcp/limits_test.exs` "every batch tool states the batch limit the account enforces".
- 2026-09-24, settled. Each limit is declared once, in the module enforcing it, and everything stating it derives from there. A copy written by hand would drift, and a tool would then promise a limit the account does not apply.
  - The page and batch limits live in `AtMcp.Effects`, and the tool schemas, descriptions and error text take them through `AtMcp.MCP.Schemas`.
  - The thread's depths and breadths live in `AtMcp.Effects.ProtoRune` (`thread_shape/0`).
  - The endpoint's timeout follows from the account's own answer time.
  - Evidence: `test/at_mcp/limits_test.exs`.

## Writes

- 2026-09-29, settled. Only publishing counts against the write quota. `post`, `reply`, `repost`, `put_record` and `delete_record` reserve a slot, and every other write (likes, follows, blocks, mutes, deletions, profile edits, `update_seen` and the rest) goes out without spending one.
  - The quota bounds what an account publishes. If likes and follows counted too, an agent liking and following a lot would spend the quota within minutes and leave its replies waiting for the reset.
  - `put_record` and `delete_record` count on every call, because AtMcp cannot tell whether another application's record is a public post or something as small as a like.
  - `AtMcp.Effects.publishing/0` holds the classification. Each write tool's `at_mcp/publicWrite` annotation and the sentence ending its description derive from it.
  - Evidence: `test/at_mcp/publishing_quota_test.exs`.
- 2026-10-18, provisional (#88). A post's reply and quote rules (`feed.threadgate`, `feed.postgate`) are written with the post in one `com.atproto.repo.applyWrites` under the post's record key, so the post never exists without them, and the post counts once.
  - Editing a post's rules (`set_post_interactions`, `hide_reply`, `detach_quote` and their inverses), pinned posts, thread mutes, bookmarks and drafts publish nothing and do not count.
  - An edit reads the repository's latest commit and then the record it changes, keeps every field it does not set, and writes over that commit only (`swapCommit`).
  - `set_post_interactions` keeps a rule it is not given, as the app's dialog starts from the current settings.
  - A service's 501 is a refusal: the method did not run, so the outcome is known.
  - Evidence: `test/at_mcp/post_gates_test.exs`; `test/at_mcp/publishing_quota_test.exs`; `test/at_mcp/pins_bookmarks_test.exs` "a service that does not implement bookmarks is reported as refusing them".
- 2026-09-06, settled. Each DID has one durable write quota, 16 publishing writes per hour by default, shared by every client, alias and reconnect. An attempted write counts even when the remote call fails, and reads do not count.
  - The quota protects against an agent publishing faster than a person would notice and stop it: a loop, a retry storm, two agents answering each other.
  - The number 16 comes from the per-turn write budget AtMcp had before the bound moved to the hour. Nobody has measured it as an hourly publishing limit. It is a cautious default, and an operator changes it with `AT_MCP_WRITE_LIMIT` (#52; `AtMcp.WriteQuota` moduledoc, "The default").
  - Evidence: `AtMcp.WriteQuota`; `test/at_mcp/write_quota_test.exs` "remote failure counts against the write quota"; `test/at_mcp/shared_http_quota_test.exs`.
- 2026-10-20, provisional (#159). Each account may have its own write limit. Accounts on one service are different agents with different needs, and a single number for all of them suits none.
  - An account may carry a `write_quota` (`limit`, `window_seconds`) in the accounts file, set with `at_mcp-accounts write-quota`. `reload` applies it by replacing that account. An embedding host passes `write_limit` and `write_window_seconds` to `start_identity`.
  - An account leaving them unset uses the service's `AT_MCP_WRITE_LIMIT` and `AT_MCP_WRITE_WINDOW_SECONDS`, so nothing changes until an operator sets one.
  - The count stays one per DID. A changed limit applies to the window already open. So does a shorter window, and the open window then ends at the earlier of its end and its opening plus the new length. A longer window applies from the next window. An account is never held longer than the window it reports.
  - A running embedded account started again with changed options is replaced, so the new limit holds when the call returns.
  - `identity_status` reports the limit the account is held to.
  - Evidence: `test/at_mcp/write_quota_test.exs` "an account's own limit and window apply to it alone; one that sets none has the server's" and "a window shortened while open ends when the new length says, and status says so"; `test/at_mcp/accounts_reload_test.exs` "reload gives an account its own write limit and takes it away" and "starting a running account again with a changed write limit holds it to the new one at once"; `test/at_mcp/account_config_test.exs` "an account's own write limit is saved, listed, replaced and removed".
- 2026-09-06, settled. The write quota's ledger only moves forward in time (`max(clock, last_seen)`). A clock moved back cannot open a fresh window. A clock moved forward keeps the window closed until real time catches up, which errs on the safe side, so AtMcp adds nothing to handle it. Evidence: `AtMcp.WriteQuota` moduledoc; `test/at_mcp/write_quota_test.exs` (clock fixture, "damaged quota state never resets an account's write quota").
- 2026-09-08, settled. AtMcp tells four kinds of failure apart (`AtMcp.Effects.Failure`).
  - A backend reports one of three: refused, credential refused, or indeterminate. AtMcp treats a reason of any other form as indeterminate, because a failure it cannot classify may or may not have been applied.
  - The fourth, unreadable, means the service answered and AtMcp's own parser in `AtMcp.Effects.ProtoRune` could not read the answer. It never classifies a service's error.
  - Only the backend classifies its service's errors. Nothing above it reads status codes or error text.
  - Evidence: `AtMcp.Effects.Failure`; `test/at_mcp/backend_failure_test.exs`.
- 2026-09-07, settled. AtMcp reports an indeterminate write as `outcome: "unknown"` and never retries it. Only a refused credential (the backend's `:auth_refused`, for reads and writes alike) starts session recovery, and the retry after recovery takes a write quota slot of its own. Evidence: `test/at_mcp/write_outcome_test.exs` "committed writes with lost responses stay unknown without retry or leaking backend details".
- 2026-09-24, settled. Every account call answers within `AtMcp.Effects.call_deadline/0`, shorter than the MCP endpoint's handler timeout, so no tool call ends in ExMCP's bare `handler_timeout`.
  - At the deadline, a write already passed to the backend is `write_outcome_unknown`. Anything else, including a write still waiting behind another, is `call_deadline_exceeded` and changed nothing.
  - A task marks a write as sent before its last deadline check. A caller giving up before the mark is never followed by the write, and a write stopped at that check is reported unknown, which errs on the safe side.
  - The longest a caller waits is `AtMcp.Effects.answered_within/0` (the deadline plus twice the account process's grace), and the endpoint's timeout derives from it.
  - Evidence: `test/at_mcp/call_deadline_test.exs`; `test/at_mcp/account_owner_test.exs` "a write queued behind a slow write is not sent once its deadline passes", "a caller that stops waiting is never told nothing changed about a write that is then sent" and "the longest a caller waits is answered_within/0, and the endpoint waits longer".
- 2026-09-24, settled. One process (`AtMcp.Effects`) holds each configured account and does its work in tasks linked to it. Aliases of one DID each get a process of their own, as the provisional entry below says.
  - Writes run one at a time in the order they arrive, so the account's readers find a reply after the post it answers and a like before its undo.
  - Reads run alongside them without waiting.
  - At most one login or refresh runs at a time, and every waiting call shares its result.
  - No caller waits on a lock.
  - When the process stops, its work stops. A write already sent is `write_outcome_unknown`, and a call not yet started is `account_runtime_unavailable`.
  - Evidence: `test/at_mcp/account_owner_test.exs`; `test/at_mcp/session_ownership_test.exs`; `test/at_mcp/call_deadline_test.exs` "a reply is sent while a read the service never answers is still waiting".
- 2026-09-24, provisional. The account process is per configured account, and two account entries logging in to the same DID (aliases) each get their own `AtMcp.Effects`.
  - Writes to that DID through different aliases run in parallel, in no order relative to each other, `update_seen` included: two aliases marking notifications seen can finish out of order. Within one alias, writes stay ordered.
  - The write quota is per DID and bounds the aliases together.
  - The entry retires when one process serves every alias of a DID. That needs the lifecycle supervisor to bind an alias to the DID's process once its login reveals the DID.
  - Evidence: unverified (no test covers the limit).
- 2026-09-07, settled. AtMcp checks post and reply text against the network's grapheme and byte limits before charging the write quota. Evidence: `test/at_mcp/post_validation_test.exs`; `test/at_mcp/network_test.exs` "bound what AtMcp refuses before it sends anything".
- 2026-09-28, settled. A follow, block, mute or unmute resolves its handle to a DID before charging the write quota and before sending anything.
  - A handle the service cannot resolve (a 400 `HandleNotFound` or `InvalidRequest`, or a string with no handle form) is refused as `handle_not_resolved` at no cost, and is never reported as an unknown outcome.
  - Any other failure of that read keeps its own kind and also costs nothing.
  - Every tool taking a handle drops one leading `@`.
  - Evidence: `AtMcp.Effects.Backend.resolve_actor/2`; `test/at_mcp/actor_resolution_test.exs`.
- 2026-09-07, settled. Rich text keeps the supplied text and adds facets for resolved `@handle` mentions, explicit HTTP(S) links and hashtags. An unresolved handle stays plain and appears in `unresolved_mentions`. Bare domains and cashtags go undetected. Evidence: `test/at_mcp/rich_text_test.exs`.
- 2026-10-20, provisional (#163). `AtMcp.Effects.post/3` and `reply/4` take `facets: :none`, which publishes the text as given, with no facets, and resolves no handle. An embedding host quoting someone else's text needs it, since detection would turn each handle in that text into a mention and notify its account.
  - The default, `:detect`, is the entry above. Any other value is an invalid argument, refused before the quota.
  - The MCP `post` and `reply` tools do not take it. The app's composer detects facets from the text when it publishes, the tools offer what a person can do in the app (#82), and a person has no setting for keeping a handle from linking.
  - AtMcp takes no facets from a caller. Nothing needs them yet, and AtMcp would have to check their byte ranges against the text.
  - Evidence: `test/at_mcp/rich_text_test.exs` "facets: :none publishes the text exactly as given"; `test/at_mcp/post_validation_test.exs` "a facets value other than :detect or :none"; `test/e2e/round_trip_test.exs` "a post with facets: :none".
- 2026-09-07, settled. Summaries keep the URIs of the viewer's like, repost, follow and block records, so an agent can undo one without the original receipt. A missing viewer object stays distinct from an empty one. Evidence: `test/at_mcp/summary_test.exs` "an absent viewer stays absent and an empty one stays empty"; `test/at_mcp/viewer_context_test.exs`.
- 2026-10-19, provisional (#110). A like, repost, follow or block first finds the account's own record for its subject in the AppView's viewer state, then confirms it with `com.atproto.repo.getRecord` on the account's repository, since the viewer state can point at a deleted record.
  - A confirmed record with the same subject comes back as `unchanged: true`, and nothing is sent or counted. Otherwise AtMcp writes a new record.
  - The reference PDS's createRecord deletes an existing record of the same subject before writing a new one, so a second write would leave the first call's URI pointing at nothing.
  - An undo deletes the record it is given. When the viewer state shows another of the account's records for the same subject (confirmed the same way), the undo deletes that one too, in one commit. A retry after an unknown outcome leaves such a duplicate.
  - An undo does not scan the collection. An undo of a missing record deletes nothing and says it tells nothing about other records of the subject.
  - Evidence: `test/at_mcp/round_trip_findings_test.exs`; `test/e2e/round_trip_test.exs` "like, repost, follow and block twice".
- 2026-10-19, provisional (#113). Before writing a reply, AtMcp reads the parent with `getPosts`.
  - A view with `viewer.replyDisabled` true means the thread's reply rule shuts the account out, and the app disables its reply button. AtMcp refuses the reply, because the PDS would accept it and the AppView would leave it out.
  - A view with it false or absent, or no view at all (the AppView does not have the post), lets the reply go ahead.
  - Any failure of that read, a rate limit or a refused credential included, fails the reply with nothing sent.
  - Evidence: `test/at_mcp/round_trip_findings_test.exs` "reply (#113)"; `test/e2e/round_trip_test.exs` "a reply the thread's rule forbids is refused before it is written".
- 2026-10-19, provisional (#144). A reply's root is the root its parent declares, copied as the app copies it.
  - A DID-form root is copied unchanged, CID included. A handle-form root gets its handle resolved to a DID and keeps the declared CID.
  - AtMcp does not read the root, so a root whose author's repository is gone does not stop a reply. Detecting a moved handle would cost that read, so AtMcp does not try.
  - A handle failing to resolve refuses the reply before anything is written or counted.
  - When a parent declared its root by handle, the result's `warning` says so, since the app may leave that parent out of its thread.
  - `mute_thread` and `unmute_thread` mute the DID form of the declared root. `bookmark` does not resolve the root.
  - Evidence: `test/at_mcp/write_records_test.exs` "a reply under a parent that names its root by handle (#144)"; `test/e2e/round_trip_test.exs` "a reply under a parent that names its root by handle".
- 2026-10-18, provisional (#69). Summaries also keep the viewer states the service reports without a record of the account's: `blocked_by`, `muted`, `blocking_by_list`, `muted_by_list` and `followed_by` on a profile and on a post's `author_viewer`, and `reply_disabled`, `embedding_disabled` and `thread_muted` on a post. A state the service left out is omitted, and never reported as `false`. A post's text states a block, a mute, a muted thread or a closed reply or quote only when present. Evidence: `test/at_mcp/summary_test.exs` "block and mute state is kept as the service sent it, for a profile and a post's author"; `test/at_mcp/reading_test.exs` "a block or mute with the author is said in words; following is not".

## Collection and delivery

- 2026-09-13, settled. Polling each account's notifications is the ordinary collector. It polls every 60 seconds with a five-minute overlap and keeps a private per-DID checkpoint, which advances only after a complete retained scan. It never marks anything read. The first poll looks back five minutes, and leaves the rest of the inbox alone. Evidence: `AtMcp.Notifications`; `test/at_mcp/notifications_test.exs`.
- 2026-09-06, settled. Jetstream is opt-in (`AT_MCP_JETSTREAM=1`). It subscribes with an empty `wanted_dids` and matches recipients locally, because an incoming interaction is a record in somebody else's repository. Evidence: `AtMcp.Stream.Jetstream`; `test/at_mcp/stream_jetstream_test.exs` "an inbox cannot be a DID filter"; `test/at_mcp/inbound_match_test.exs`.
- 2026-09-09, settled. Collection goes through `AtMcp.Stream`. An adapter handles its service's options, message form and event fields, so a new stream such as Jetstream v2 is a new adapter and leaves collection, matching, the store and delivery as they are. Evidence: `AtMcp.Stream`; `test/support/fake_stream.ex`.
- 2026-09-13, settled. Delivery is an HTTP POST of the normalized event to `AT_MCP_DELIVERY_URL`, with a bearer token read again for each delivery, and it suits any consumer. The event gives its network. AtMcp supplies no route, character or conversation. Evidence: `AtMcp.Deliver.HTTPBridge`; `test/at_mcp/delivery_consumer_test.exs`; `test/at_mcp/http_bridge_test.exs` "a rotated access token reaches the next delivery".
- 2026-09-06, settled. Delivery happens at least once, and only a 2xx from the consumer counts as acceptance. AtMcp follows no redirects. The outbox handles retries, and the consumer deduplicates by recipient DID plus source URI. Evidence: `test/at_mcp/delivery_consumer_test.exs` "a redirected endpoint is not durable acceptance"; `test/at_mcp/inbound_store_test.exs`.
- 2026-09-24, settled. Delivery is ordered per account and parallel across accounts, so one account's slow or failing consumer never delays another's.
  - Each recipient DID is a lane. A lane delivers in acceptance order, one event at a time, and holds later events while an earlier one is in progress or backing off. Lanes run at once.
  - The store persists the acceptance order. A state file without one loads in key order.
  - Evidence: `AtMcp.Inbound.Store`; `test/at_mcp/inbound_store_test.exs` "a consumer that blocks one account does not hold another account's delivery", "one account's events arrive in acceptance order, and a retry holds the ones behind it", "an account's delivery order survives a store restart", "a state file written before acceptance order was recorded loads and delivers everything", "disconnect stops only the disconnected account's delivery; terminate stops the rest".
- 2026-09-24, settled. AtMcp never evicts a pending event. When the store is full, collection waits until delivery makes room.
  - Capacity is per lane (10,000 events, 16 MiB of events), so a stuck account refuses only batches adding to its own lane. The whole file has a 64 MiB ceiling and keeps 10,000 receipts.
  - A notification sweep covers one account. Jetstream has one cursor for every account, so it pauses the stream for all of them while one lane is full.
  - Evidence: `AtMcp.Inbound.Store`; `test/at_mcp/inbound_store_test.exs` "capacity never acknowledges overflow", "a full account refuses only batches that add to it", "an account full by bytes refuses only its own events".
- 2026-09-24, settled. The notification poller accepts a completed sweep oldest first by `indexed_at`, in page-sized chunks, before its checkpoint advances. An incomplete sweep accepts nothing. Evidence: `AtMcp.Notifications`; `test/at_mcp/notifications_test.exs` "a sweep's notifications are delivered oldest first across its pages", "a sweep larger than the account's room accepts its oldest events and holds the checkpoint".
- 2026-09-13, settled. A delivery bridge configured with no collector enabled fails closed at startup. With only the notification poll, it runs. Evidence: `test/at_mcp/http_bridge_test.exs` "maybe_attach_from_env! fails closed when no collector is enabled".
- 2026-09-24, settled. An incomplete notification sweep accepts nothing, so each account's events enter delivery in order. The cost is an account whose delivery stalls behind one refused event, and `at_mcp-accounts status` makes that visible: it reports the stalled account with the consumer's last answer and the time of the first failure, kept with the event across restarts. Evidence: `test/at_mcp/accounts_test.exs` "status shows an account whose delivery is stalled, why, and since when".

## State and process

- 2026-09-06, settled. One process holds each state directory, and the lock survives a supervisor restarting the process holding it. Evidence: `AtMcp.StateLock`; `test/at_mcp/state_lock_test.exs` "cold BEAMs preserve exclusive durable ownership through crashes and application restarts".
- 2026-09-19, settled. AtMcp decodes the inbound checkpoint without `[:safe]`, and the structural checks after decoding reject a damaged one.
  - AtMcp wrote the file, with mode 0600 inside its own 0700 state directory, so it is trusted input. `[:safe]` guards against atom exhaustion from a hostile peer.
  - With `[:safe]`, a restart with a pending event failed to start: an event key from whichever collector produced it (`:thread_root_uri`) does not exist in a fresh VM.
  - Evidence: `AtMcp.Inbound.Store.load!/1`; `test/at_mcp/inbound_store_test.exs` "a cold VM restores a pending event whose keys no loaded module defines".
- 2026-09-07, settled. Damaged state (quota, checkpoint, outbox, accounts) fails startup, because resetting it would reset policy. Evidence: `test/at_mcp/write_quota_test.exs` "damaged quota state never resets an account's write quota"; `test/at_mcp/notification_store_test.exs`; `test/at_mcp/inbound_store_test.exs` "damaged state fails startup instead of silently losing the queue"; `test/at_mcp/account_config_test.exs` "corrupt config preserved".
- 2026-09-07, settled. AtMcp persists a disconnect before stopping the account's processes, and the disconnect fences every alias of the DID.
  - Reconnecting takes an explicit command, and a failed login leaves the account disconnected.
  - Removing an account's configuration keeps its history and its disconnected state.
  - Neither revokes the app password at the provider.
  - Evidence: `test/at_mcp/accounts_test.exs`; `test/at_mcp/account_control_test.exs`.
- 2026-09-07, settled. Reload validates the whole plan first, leaves unchanged accounts running and replaces only affected ones. A replacement unable to log in stays unavailable, and reload exits nonzero. AtMcp never falls back to stale credentials. Evidence: `test/at_mcp/accounts_reload_test.exs`.
- 2026-09-07, settled. An identity started from code keeps its configuration only in the running lifecycle supervisor. After a restart it reports `configuration_required` until supplied again, and its disconnected state stays durable. Evidence: `test/at_mcp/accounts_test.exs` "durable disable survives store and lifecycle owner restart; dynamic accounts must be configured again".
- 2026-09-06, settled. An embedding host sets `boot_from_env: false` and `start_mcp: false`. AtMcp then creates no accounts from the environment, inherits no host credentials and opens no port. Evidence: `test/at_mcp/embedding_test.exs`.

## Dependencies

- 2026-10-20, settled. Jetstream connects through `AtMcp.Stream.Jetstream.HTTP1`, ProtoRune's gun transport opened with `protocols: [:http]`.
  - ProtoRune 0.6's own transport lets ALPN choose HTTP/2. Jetstream's public instances answer a WebSocket upgrade over HTTP/2 with 400, so the collector reconnected forever and never received an event.
  - The workaround can go when AtMcp moves to ProtoRune 0.7, whose Mint transport asks for HTTP/1.1 itself.
  - Evidence: `AtMcp.Stream.Jetstream.HTTP1`; `test/at_mcp/stream_jetstream_http1_test.exs` "opens a WebSocket over HTTP/1.1 from a server that prefers HTTP/2"; `test/at_mcp/stream_jetstream_test.exs` "the client connects over HTTP/1.1, which a WebSocket needs".
- 2026-10-19, settled (#74). AtMcp loads the JSON Schema validator's modules at application start.
  - ExMCP checks arguments and results under a wall-clock deadline: 100 ms by default, and one second as `config/config.exs` sets it (#221). The validator loads one module per schema keyword on first use.
  - Under interactive code loading, that load fell inside the deadline, and on a loaded machine it refused correct calls as `input_validation_unavailable` (6 of 10 runs of `search_posts_filters_test` under CPU load, 0 of 20 with the load done first).
  - `bin/at_mcp start` boots in embedded mode with every module loaded. `at_mcp-stdio` and `at_mcp-connect` start through `bin/at_mcp eval`, which loads code interactively, so they hit the problem too.
  - The preload can go when ExMCP's deadline stops counting code loading.
  - Evidence: `AtMcp.MCP.Input.load_validator/0`; `test/at_mcp/input_schema_test.exs` "the schema validator is loaded before any argument is checked"; `test/at_mcp/validation_deadline_test.exs`.
- 2026-10-08, settled (#13). `get_relationships` resolves each handle in `others` to a DID before calling the AppView, because the AppView resolves only `actor` and keys `others` by DID. A handle failing to resolve comes back as `not_found` with the handle the caller gave. The workaround can go when the AppView resolves `others` the same way. Evidence: `AtMcp.Effects.ProtoRune.get_relationships/3`; `test/at_mcp/actor_resolution_test.exs` "get_relationships resolves a handle in others and asks about the DID".
- 2026-10-02, settled (#106). `ex_mcp` comes unmodified from Hex, and AtMcp checks tool results itself, after the handler.
  - AtMcp keeps each output schema beside its tool, and `AtMcp.MCP.Output` validates the completed response against it.
  - A validation timeout or schema defect logs a diagnostic and leaves the action's result in place. Validation runs after the action and cannot undo a write, so failing the call would report a completed write as one that did not happen.
  - Tests reject a result whose form does not match its schema.
  - The adapter can go when upstream supports this policy after the action.
  - Evidence: `test/at_mcp/write_outcome_test.exs`; `test/at_mcp/mcp_tools_test.exs`; `test/at_mcp/stdio_test.exs`.
- 2026-10-07, settled (#22). `AtMcp.ATProto` declares each application-namespace endpoint as a plain function over proto_rune's `Query`, `Procedure`, `Session` and `Client`, and resolves the NSID when it is called.
  - proto_rune's `defquery` compiles the NSID into the function it generates, so one release could not serve both networks.
  - `ProtoRune.XRPC.query/5` and `procedure/5` take no per-request headers, and AtMcp needs them for the `atproto-proxy` header (`AtMcp.Network.request_headers/2`). That part can go when proto_rune takes a `:headers` option.
  - Evidence: `AtMcp.ATProto`; `test/at_mcp/network_test.exs` "a read asks for the configured namespace's method, not app.bsky's"; `test/at_mcp/external_account_test.exs`.
- 2026-10-02, settled. `AtMcp.NativeLock` is a repaired native advisory lock derived from flock_ex 0.1.0 and built with `elixir_make` from Hex.
  - It ties the lock to a resource's lifetime, handles long paths, keeps descriptors private and close-on-exec, and serializes cleanup.
  - The state lock and the private files use this one implementation.
  - The derived code keeps its Apache-2.0 attribution in `licenses/flock_ex`, included in releases.
  - Evidence: `c_src/native_lock.c`; `test/at_mcp/native_lock_test.exs`; `test/at_mcp/state_lock_test.exs`; `test/at_mcp/account_edit_test.exs`.
- 2026-09-13, settled. ProtoRune's own retry loop is off (`config :proto_rune, :retry, false`), and Req handles retries. The setting can go when ProtoRune stops wrapping Req in a loop of its own for 429s. Evidence: `config/config.exs`; `test/at_mcp/http_retry_test.exs`.
- 2026-09-11, settled. AtMcp declares three XRPC methods with care because proto_rune's declarations are wrong: `getPostThread`'s `parentHeight` casing, the `getRelationShips` spelling, and `updateSeen` sending a `DateTime`. List parameters build their own query, because `URI.encode_query/1` raises on a list. Every endpoint is declared in `AtMcp.ATProto` for the runtime namespace anyway, so an upstream fix would change nothing here, and the comments keep the defects on record. Evidence: `AtMcp.ATProto`; `test/at_mcp/effects_test.exs` "updateSeen is declared with a string wire type", "flatten_query repeats list keys".
- 2026-09-11, settled. A build must not depend on the operator's environment. `config/runtime.exs` reads `AT_MCP_*` at boot, and the `release` and `macos` jobs fail if any such variable is set at build time. Evidence: `.github/workflows/check.yml`.

## Working method

- 2026-09-11, settled. The test suite is the evidence for what AtMcp does. A test fails when its behavior goes away, and a verification log only says someone saw it once, so the repository keeps no verification logs or dated exercise narratives. What was exercised on a particular day goes in the pull request. Evidence: `AGENTS.md` "Evidence".
- 2026-09-11, settled. A test counts as evidence only after reverting the change it protects makes it fail, since a test passing either way protects nothing. Evidence: `AGENTS.md` "Evidence"; unverified as a test.
- 2026-09-11, settled. `test/at_mcp/telos_test.exs` states AtMcp's purpose as claims. A claim not yet true is tagged `:goal` and excluded, and making it true deletes the tag in the same commit. No claim carries the tag now. Evidence: `test/test_helper.exs`.
- 2026-09-15, settled. Continuous integration runs the way a stranger would, from a fresh checkout: `mix deps.get`, the official MCP client packages, a production release, and the suite with every environment-gated test's environment supplied, failing if any test skipped. The `release` job and the Hex package's consumer check start with no cache. Evidence: `.github/workflows/check.yml`.
- 2026-10-19, provisional (#127). The tag sets the version.
  - A maintainer cuts a release by pushing `vX.Y.Z` on a commit of main with a passing `check` run in the merge queue (or one requested on main), and with a version one patch, minor or major step after the newest release tag. `scripts/release_version.sh` refuses any other tag before building, and CI builds as that version through `RELEASE_VERSION`.
  - `mix.exs` holds no version. It reads a `VERSION` file if present, then `RELEASE_VERSION`, else `0.0.0-dev`. CI writes `VERSION` only into the Hex package, so a dependent application compiles the package as the version it asked for, whatever its own environment holds.
  - The MCP server reports the running application's version.
  - A separate version-bump pull request ran CI and the merge queue a second time for one line, and the tag needs neither.
  - A change's upgrade steps go in the CHANGELOG entry for the release carrying it.
  - Evidence: `mix.exs` `version/0`; `scripts/release_version_test.sh`; `scripts/package_consumer_check.py`.
- 2026-10-21, provisional. Each commit is tested once on its way to a release.
  - The merge queue runs the checks on exactly the commit main then moves to, so `check` does not run on a push to main. A tag's run skips the suite: `release` and `macos` each start with `scripts/release_version.sh`, which accepts a passing run in the merge queue or one requested on main.
  - `cache.yml` keeps main's dependency cache, which pull requests and the merge queue restore.
  - Running main's checks and the tag's own suite again would add about 7 and 5 minutes for a commit the merge queue has already passed.
  - The entry changes if main moves to a commit other than the one the merge queue tested, or something needs a run of main itself.
  - Evidence: `.github/workflows/check.yml`; `.github/workflows/cache.yml`; `scripts/release_version.sh`.
- 2026-10-26, provisional. The whole suite runs once per change, in the merge queue, in four `mix test --partitions` jobs running at once.
  - Each partition has every gate's environment and fails if any of its tests skipped.
  - The required `test` check passes only when `build`, every partition, `package` and `e2e` passed.
  - `build` builds the production release once and uploads it for the partitions.
  - `release` runs beside the suite.
  - A pull request runs only `build`: the release contract scripts, formatting, compiling with warnings as errors, and the async tests.
  - The suite spent almost all of its three minutes in synchronous tests and ran twice per change, on the pull request and in the merge queue, so a one-line change took about 12 minutes from push to merge.
  - The entry changes if a partition takes over two minutes, the partitions grow lopsided, or broken changes get to the merge queue often enough that the pull request check needs more of the suite.
  - Evidence: `.github/workflows/check.yml`.
- 2026-09-29, settled. A release is published when a maintainer pushes a version tag, and never on a merge. A published version cannot be taken back (Hex keeps it, and a server may have fetched it), so publishing takes a deliberate act.
  - A release is its version, and tarballs carry the version in their names.
  - On a tag, `release` builds the Linux release and runs its boot check, its upgrade from the newest published release and its rollback under the example systemd unit, and the tarball owner check. `macos` does the same under the example launchd plist, and runs only on a tag or on request, since macOS runner minutes cost ten times Linux's.
  - `publish` creates the GitHub release only when both platforms passed, and `hex` publishes the package only after that.
  - Release N of an upgrade check is the newest published release carrying that platform's tarball whose tag is not on the commit under test. The release's `BUILD` file gives its commit, and AtMcp refuses an N built from the commit under test, since upgrading a build to itself proves nothing.
  - Evidence: `.github/workflows/check.yml`; `scripts/published_release.py`; `mix.exs` `write_build/1`; `CONTRIBUTING.md` "Publish a release".
