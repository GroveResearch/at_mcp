import Config

# Settings an operator gives through the environment, and their defaults, are
# in config/runtime.exs.
config :at_mcp, start_mcp: true

# ProtoRune 0.5.3 wraps Req's retries with another 429 loop. Let Req own
# request retries: safe transient requests, Retry-After and jitter. Remove
# this override when ProtoRune no longer nests its retry loop around Req.
config :proto_rune, :retry, false

# ExMCP checks each tool call's arguments and result against the tool's
# schema in a separate process, and gives up after 100 ms by default. The
# check takes microseconds, but on a busy machine that process can wait longer
# than 100 ms to run, and a correct call is then refused as
# input_validation_unavailable. AtMcp's schemas are its own and compiled when
# the server compiles, so the deadline only has to stop a runaway check: one
# second is far beyond real work. Remove this when ExMCP's default allows for
# scheduling delay.
config :ex_mcp, :json_schema, validation_timeout_ms: 1_000

config :logger, level: :info

import_config "#{config_env()}.exs"
