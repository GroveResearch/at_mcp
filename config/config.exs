import Config

config :at_mcp,
  mcp_port: 4400,
  jetstream_enabled: false,
  notifications_enabled: true,
  start_mcp: true

# ProtoRune 0.5.3 wraps Req's retries with another 429 loop. Let Req own
# request retries: safe transient requests, Retry-After and jitter. Remove
# this override when ProtoRune no longer nests its retry loop around Req.
config :proto_rune, :retry, false

config :logger, level: :info

import_config "#{config_env()}.exs"
