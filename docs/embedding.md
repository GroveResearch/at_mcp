# Embed AtMcp in an Elixir application

Use this path when your application owns account configuration and lifecycle.
The package contains native source and needs Elixir 1.19, Erlang/OTP, Make
and a C compiler. Add this dependency and commit the generated `mix.lock`:

```elixir
{:at_mcp, "~> 0.2.0"}
```

First [prepare the agent’s account](../README.md#get-an-account-and-an-app-password). Add the
configuration below to your application’s `config/config.exs` (which imports
`Config`). Disabling environment boot keeps the host in charge of account
configuration and inbound integration:

```elixir
config :at_mcp,
  boot_from_env: false,
  inbound_state_dir: "/absolute/private/path/my-app/at_mcp",
  # One MCP listener serves the whole installation, so this is the switch that
  # keeps an embedded AtMcp from opening a port at all.
  start_mcp: false,
  jetstream_enabled: false,
  notifications_enabled: false

# ProtoRune otherwise adds a second retry loop around Req.
config :proto_rune, :retry, false
```

For Delvetown, also set `config :at_mcp, network: :delve`; the default is
`:bluesky`. The network selects the application namespace, while the account’s
`service:` below selects its actual home PDS. Set `AT_MCP_SERVICE` to that
hosting URL, such as `https://bsky.social` for an account hosted there. With
`boot_from_env: false`, these environment variables are read by your code, not
automatically by AtMcp.

Once dependencies are started (for example, in `iex -S mix`), add an account
and read it through the same Effects interface MCP uses:

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

The account uses the durable write quota by default; a host can supply a quota
server explicitly with `write_quota:`, and `service:` selects another PDS.
`write_limit:` and `write_window_seconds:` give this account its own limit and
window (positive integers; anything else is `{:error, :invalid_configuration}`);
what they leave out is the quota server's, which the application starts from
`config :at_mcp, write_quota: [limit: ..., window_seconds: ...]`. Aliases of one
DID share one count, and each is held to its own limit, so give them the same.
Calling `start_identity` again for a running account with a changed option,
such as a lower `write_limit:`, replaces that account, so the new limit holds
from the moment the call returns; an option left out keeps its value. With
`boot_from_env: false`, AtMcp creates no environment accounts, inherits no host
credentials and attaches no HTTP delivery callback.

Dynamic account configurations live in memory, so the application must supply
them again after its runtime restarts; durable disconnect state and write
quotas remain intact. When restoring a configuration,
`{:error, :account_disconnected}` means the owner disconnected the account on
purpose: AtMcp has saved the configuration but has not started the
account, and the right response is to wait for an explicit reconnect rather
than retry or reconnect it automatically. The success match above is for a first
connection, not for unconditional restart code. Use one state directory per
independent BEAM, with several identities inside it.

## Next steps

Use `AtMcp.Effects` for reads and writes and `AtMcp.Accounts` for lifecycle
control. [Design](DESIGN.md) explains account ownership, failure kinds and
network boundaries; [Operations](operations.md#incoming-activity) describes
the delivery contract if your host needs incoming activity.

## Read the profile before a partial edit

`AtMcp.Effects.get_own_profile(effects)` returns `{:ok, %{value: record}}`, with
native string keys and blob references. It reads the presentation that
`update_profile` will retain for omitted fields. Embedded clients can compare
that map with their configured profile before deciding whether to upload an
image or change text. They should not select profile records from graph state
or read an Effects process's internal session.

On Delvetown, `update_profile` saves the account's complete Delvetown profile
(its Town presentation, the `town.delve.actor.profile` record) and preserves
unrelated fields there. It leaves the shared `app.bsky.actor.profile`, which
Bluesky reads, unchanged, except that in releases after 0.2.15 a call that
gives `labels` changes that profile's labels, such as the public `bot` label. A stale selected profile or changed repository refuses
the edit; an unacknowledged write remains an unknown outcome and is not retried.
