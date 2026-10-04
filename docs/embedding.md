# Embed AtMcp in an Elixir application

Use this path when your application owns account configuration and lifecycle.
The Hex package is pending publication; `mix deps.get` cannot resolve it yet.
Until then, clone the [public source](https://github.com/GroveResearch/at_mcp),
build with `mix hex.build`, unpack the package, and depend on that directory
with `{:at_mcp, path: "/absolute/path/to/unpacked-package"}`. The package contains
native source and needs Elixir 1.19, Erlang/OTP, Make and a C compiler. After
publication, add this dependency and commit the generated `mix.lock`:

```elixir
{:at_mcp, "~> 0.1.2"}
```

First [prepare the agent’s account](../README.md#prepare-the-account). Add the
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

# ProtoRune 0.5.3 otherwise adds a second retry loop around Req.
config :proto_rune, :retry, false
```

For Delvetown, also set `config :at_mcp, network: :delve`; the default is
`:bluesky`. The network selects the application namespace, while the account’s
`service:` below selects its actual home PDS. Set `BLUESKY_SERVICE` to that
hosting URL, such as `https://bsky.social` for an account hosted there. With
`boot_from_env: false`, these environment variables are read by your code, not
automatically by AtMcp.

Once dependencies are started (for example, in `iex -S mix`), add an account
and read it through the same Effects interface MCP uses:

```elixir
{:ok, _} = AtMcp.Identities.start_identity(
  id: "social",
  handle: System.fetch_env!("BLUESKY_HANDLE"),
  password: System.fetch_env!("BLUESKY_APP_PASSWORD"),
  service: System.fetch_env!("BLUESKY_SERVICE"),
  listen_enabled: false
)

effects = AtMcp.Identity.effects_name("social")
{:ok, profile} = AtMcp.Effects.get_profile(effects, AtMcp.Effects.session_did(effects))

:ok = AtMcp.Accounts.disconnect("social")
{:ok, _} = AtMcp.Accounts.reconnect("social")
```

The account uses the durable write quota by default; a host can supply a quota
server explicitly with `write_quota:`, and `service:` selects another PDS. With
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
