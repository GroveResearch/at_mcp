defmodule AtMcp.Rename do
  @moduledoc false

  # The old application intentionally is not an alias: running with an ignored
  # old setting could silently create another account store or use another
  # network. Require an explicit configuration cutover, without printing values
  # (delivery tokens and grants can be present in this environment).
  def check_environment! do
    for {"KITE_" <> suffix = old, _value} <- System.get_env() do
      new = if suffix == "MCP_PORT", do: "AT_MCP_PORT", else: "AT_MCP_" <> suffix

      raise ArgumentError,
            "#{old} was renamed to #{new}; rename the setting and preserve its value"
    end

    :ok
  end

  def check_application! do
    # Only recognize this application's former settings; another dependency may
    # legitimately use the :kite application name.
    old_keys = ~w(boot_from_env start_mcp mcp_port network notifications_enabled
      jetstream_enabled jetstream_cursor jetstream_client write_quota control_port
      call_deadline_ms effects_pause_before_dispatch inbound_state_dir)a

    if Enum.any?(old_keys, &(Application.fetch_env(:kite, &1) != :error)) do
      raise ArgumentError,
            "config :kite was renamed to config :at_mcp; move the settings and preserve their values"
    end

    check_environment!()
  end

  def default_state_path(suffix \\ []) do
    parts = ["inbound" | suffix]

    default_path(
      Path.join([to_string(:filename.basedir(:user_data, ~c"at_mcp")) | parts]),
      Path.join([to_string(:filename.basedir(:user_data, ~c"kite")) | parts]),
      "AT_MCP_STATE_DIR"
    )
  end

  # An explicit path can deliberately keep the old location. Without one,
  # existing old data must never look like a fresh empty installation.
  def default_path(current, legacy, setting) do
    if File.exists?(legacy) do
      raise ArgumentError,
            "Existing Kite data at #{legacy}; set #{setting}=#{legacy} to use it, " <>
              "or set #{setting} explicitly to choose a separate installation"
    end

    current
  end
end
