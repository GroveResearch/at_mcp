import Config

# The accounts file is the only way an installation is configured, and its
# default path is the operator's own. A test run must never read, log in to,
# or rewrite that file, so point the whole test environment — including the
# boots tests start as child processes — at a path that does not exist.
System.put_env(
  "AT_MCP_ACCOUNTS_FILE",
  Path.join(System.tmp_dir!(), "at_mcp-test-accounts-#{System.pid()}.json")
)

config :at_mcp,
  inbound_state_dir: Path.join(System.tmp_dir!(), "at_mcp-test-#{System.pid()}"),
  jetstream_enabled: false,
  notifications_enabled: false,
  # The one MCP endpoint, on a port the OS picks. Tests reach it through
  # `:ranch.get_port(:at_mcp_http)`, as they already do for the control
  # listener, so nothing binds a port an operator might be using.
  start_mcp: true,
  mcp_port: 0,
  control_port: 0

config :logger, level: :warning
