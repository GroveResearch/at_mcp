import Config

# The accounts file is the only way an installation is configured, and its
# default path is the operator's own. A test run must never read, log in to,
# or rewrite that file, so point the whole test environment — including the
# boots tests start as child processes — at a path that does not exist.
config :at_mcp,
  accounts_file: Path.join(System.tmp_dir!(), "at_mcp-test-accounts-#{System.pid()}.json"),
  inbound_state_dir: Path.join(System.tmp_dir!(), "at_mcp-test-#{System.pid()}"),
  jetstream_enabled: false,
  notifications_enabled: false,
  # The one MCP endpoint, on a port the OS picks. Tests reach it through
  # `:ranch.get_port(:at_mcp_http)`, as they already do for the control
  # listener, so nothing binds a port an operator might be using.
  start_mcp: true,
  mcp_port: 0,
  control_port: 0,
  # A raw string reaching a reading's text fails the test that reaches it
  # (`AtMcp.Reading.Text`); elsewhere it is quoted.
  strict_reading: true,
  # No link card is looked up from Bluesky's card service, which is past this
  # machine. The tests of `AtMcp.LinkCards` name one on localhost.
  card_service: nil

config :logger, level: :warning
