# Using at_mcp in an Elixir application

The `at_mcp` Hex package gives an Elixir application the same account code
the MCP server runs, without MCP in between. Your application starts an
account, then calls functions to read and write as it. This suits an
application managing its own accounts, such as an agent host, where accounts
come and go at runtime.

The package compiles native code, so you need Elixir 1.19, Erlang/OTP, Make
and a C compiler.

## Add the dependency

Add `at_mcp` to `mix.exs`, run `mix deps.get`, and commit the `mix.lock` it
writes:

```elixir
{:at_mcp, "~> 0.2.0"}
```

## Configure it

Put this in `config/config.exs`. It turns off everything at_mcp would
otherwise start from environment variables, so your application stays in
charge of its accounts:

```elixir
config :at_mcp,
  boot_from_env: false,
  inbound_state_dir: "/absolute/private/path/my-app/at_mcp",
  # Leaves the MCP listener off, so the application opens no port.
  start_mcp: false,
  jetstream_enabled: false,
  notifications_enabled: false

# Turns off ProtoRune's own retries. at_mcp decides when to retry.
config :proto_rune, :retry, false
```

For Delvetown, also set `config :at_mcp, network: :delve`. The default is
`:bluesky`.

`inbound_state_dir` holds the write quota count and any queued notifications.
Use a single folder per running application, and keep it between restarts.

## Start an account

Once the application has started, for example in `iex -S mix`, start an
account and read its profile:

```elixir
{:ok, _} = AtMcp.Identities.start_identity(
  id: "social",
  handle: System.fetch_env!("AT_MCP_HANDLE"),
  password: System.fetch_env!("AT_MCP_APP_PASSWORD"),
  service: System.fetch_env!("AT_MCP_SERVICE"),
  listen_enabled: false
)

effects = AtMcp.Identity.effects_name("social")
{:ok, profile} = AtMcp.Effects.get_profile(effects, AtMcp.Effects.session_did(effects))

:ok = AtMcp.Accounts.disconnect("social")
{:ok, _} = AtMcp.Accounts.reconnect("social")
```

`id` is your local name for the account. `service` is the address of the
server hosting it, such as `https://bsky.social`. With `boot_from_env: false`,
at_mcp reads no environment variables itself, so the example reads them and
passes the values in.

`AtMcp.Effects` holds the read and write functions, the same ones behind the
MCP tools. `AtMcp.Accounts` pauses and resumes accounts.

## Write quota

Each account starts with the default quota of 16 posts, replies and reposts
per hour. To change the default for every account, set
`config :at_mcp, write_quota: [limit: ..., window_seconds: ...]`. To give a
single account its own limit, pass `write_limit:` and `write_window_seconds:`
to `start_identity`. Both take positive whole numbers. at_mcp keeps a single
count per DID, so if you start the same DID under two names, give both the
same limit.

Calling `start_identity` again for a running account, with a changed option,
replaces the running account. The new option applies once the call returns,
and options left out keep their earlier values.

## After a restart

at_mcp keeps account configurations in memory only. After your application
restarts, call `start_identity` again for each account. The write quota count
and the paused state survive on disk.

If `start_identity` returns `{:error, :account_disconnected}`, someone paused
the account on purpose. at_mcp has saved the configuration and left the
account stopped. Wait for an explicit `AtMcp.Accounts.reconnect/1` before
starting it.

## Editing a profile

`AtMcp.Effects.get_own_profile(effects)` returns `{:ok, %{value: record}}`,
the profile record as stored, with string keys. `update_profile` keeps the
values in this record for any field the call leaves out. Read it first to
compare with your own copy before uploading an image or changing text.

On Delvetown, `update_profile` writes the account's Delvetown profile and
leaves its Bluesky profile alone, apart from labels in releases after 0.2.15.
If the profile changed after your read, at_mcp refuses the edit. A write
without an answer is an unknown outcome, and at_mcp leaves it for you to
check.

## Notifications

To receive the account's notifications, turn collection on and register a
callback with `AtMcp.Deliver.set_callback/2`. [delivery.md](delivery.md)
describes collection and the event fields. [DESIGN.md](DESIGN.md) explains
how at_mcp divides the work between its processes.
