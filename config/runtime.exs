import Config

# Every setting an operator gives AtMcp through the environment is read here,
# once, at boot: its variable, its default, and the check its value must pass.
# A value that fails its check, or an AT_MCP_* variable that is not one of
# these, stops startup and names the variable. An empty value is the same as
# unset. The rest of AtMcp reads the application environment this file writes,
# never the process environment. README.md, "Settings", documents each one, and
# `AtMcp.CLI.settings/0` prints what this file resolved.
#
# A test run configures AtMcp in config/test.exs and the tests themselves, so it
# never depends on the environment of whoever runs it.
if config_env() != :test do
  AtMcp.Rename.check_environment!()

  invalid = fn name, value, expected ->
    raise ArgumentError, "#{name} must be #{expected}, got #{inspect(value)}"
  end

  port = fn name, value ->
    case Integer.parse(value) do
      {n, ""} when n in 0..65_535 -> n
      _ -> invalid.(name, value, "a port number from 0 to 65535")
    end
  end

  positive = fn name, value ->
    case Integer.parse(value) do
      {n, ""} when n > 0 -> n
      _ -> invalid.(name, value, "a positive integer")
    end
  end

  flag = fn name, value ->
    cond do
      value in ["1", "true"] -> true
      value in ["0", "false"] -> false
      true -> invalid.(name, value, "1, true, 0 or false")
    end
  end

  one_of = fn choices ->
    fn name, value ->
      Enum.find(choices, &(Atom.to_string(&1) == value)) ||
        invalid.(name, value, "one of #{Enum.join(choices, ", ")}")
    end
  end

  url = fn name, value ->
    case URI.parse(value) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and host not in [nil, ""] ->
        value

      _ ->
        invalid.(name, value, "an http or https URL")
    end
  end

  text = fn _name, value -> value end

  # {variable, check, default}. A nil default means unset, which the module
  # that uses the setting explains (a per-user path, no listener, no delivery).
  # Secrets are printed only as set or unset.
  settings = [
    {"AT_MCP_PORT", port, 4400},
    {"AT_MCP_CONTROL_PORT", port, nil},
    {"AT_MCP_NETWORK", one_of.(AtMcp.Network.names()), :bluesky},
    {"AT_MCP_APPVIEW_READS", one_of.([:proxy, :direct]), :proxy},
    {"AT_MCP_ACCOUNTS_FILE", text, nil},
    {"AT_MCP_STATE_DIR", text, nil},
    {"AT_MCP_WRITE_LIMIT", positive, 16},
    {"AT_MCP_WRITE_WINDOW_SECONDS", positive, 3600},
    {"AT_MCP_NOTIFICATIONS", flag, true},
    {"AT_MCP_NOTIFICATIONS_INTERVAL_SECONDS", positive, 60},
    {"AT_MCP_JETSTREAM", flag, false},
    {"AT_MCP_INBOUND_MAX_EVENTS", positive, 10_000},
    {"AT_MCP_INBOUND_MAX_BYTES", positive, 67_108_864},
    {"AT_MCP_IMAGE_MAX_BYTES", positive, 2_000_000},
    {"AT_MCP_IMAGE_FETCH_SECONDS", positive, 10},
    {"AT_MCP_MEDIA_DIR", text, nil},
    {"AT_MCP_DELIVERY_URL", url, nil},
    {"AT_MCP_DELIVERY_TOKEN", text, nil},
    {"AT_MCP_DELIVERY_TOKEN_FILE", text, nil},
    # One account from the environment: the stdio launcher's account, or the
    # accounts a shared service writes into a missing accounts file.
    {"AT_MCP_SERVICE", url, nil},
    {"AT_MCP_HANDLE", text, nil},
    {"AT_MCP_APP_PASSWORD", text, nil},
    {"AT_MCP_SERVICE_2", url, nil},
    {"AT_MCP_HANDLE_2", text, nil},
    {"AT_MCP_APP_PASSWORD_2", text, nil},
    # The grant `at_mcp-connect` presents to the shared service.
    {"AT_MCP_GRANT", text, nil},
    # Read by the release's shell scripts before the VM starts, and only
    # checked and reported here.
    {"AT_MCP_DIST_PORT", port, 4370},
    {"AT_MCP_ENV_FILE", text, nil},
    {"AT_MCP_STDIO_ENV_FILE", text, nil}
  ]

  secrets = ~w(AT_MCP_DELIVERY_TOKEN AT_MCP_APP_PASSWORD AT_MCP_APP_PASSWORD_2 AT_MCP_GRANT)

  # The account variables were first named for Bluesky, though an account can
  # live on any PDS. Existing installations keep working under the old names.
  renamed =
    for suffix <- ["", "_2"], part <- ~w(SERVICE HANDLE APP_PASSWORD), into: %{} do
      {"AT_MCP_#{part}#{suffix}", "BLUESKY_#{part}#{suffix}"}
    end

  known = Enum.map(settings, &elem(&1, 0))

  for {name, _} <- System.get_env(), String.starts_with?(name, "AT_MCP_"), name not in known do
    closest = Enum.max_by(known, &String.jaro_distance(&1, name))

    raise ArgumentError,
          "#{name} is not an AtMcp setting; did you mean #{closest}? " <>
            "README.md, \"Settings\", lists every setting."
  end

  present = fn name ->
    case System.get_env(name) do
      value when value in [nil, ""] -> nil
      value -> value
    end
  end

  # {variable, value, source}, where source is :default or the variable read.
  resolved =
    for {name, check, default} <- settings do
      old = renamed[name]

      case {present.(name), old && present.(old)} do
        {nil, nil} ->
          {name, default, :default}

        {nil, value} ->
          IO.warn("#{old} is deprecated; rename it #{name}", [])
          {name, check.(old, value), old}

        {value, other} ->
          if other, do: IO.warn("#{old} is ignored because #{name} is set; remove #{old}", [])
          {name, check.(name, value), name}
      end
    end

  value = Map.new(resolved, fn {name, value, _source} -> {name, value} end)

  account = fn suffix ->
    for {key, name} <- [
          service: "AT_MCP_SERVICE",
          handle: "AT_MCP_HANDLE",
          password: "AT_MCP_APP_PASSWORD"
        ],
        value[name <> suffix],
        do: {key, value[name <> suffix]}
  end

  # What `AtMcp.CLI.settings/0` prints.
  report =
    for {name, value, source} <- resolved do
      shown =
        cond do
          name in secrets -> if(value, do: "set", else: "unset")
          is_nil(value) -> "unset"
          true -> to_string(value)
        end

      {name, shown, source}
    end

  config :at_mcp,
    mcp_port: value["AT_MCP_PORT"],
    control_port: value["AT_MCP_CONTROL_PORT"],
    network: value["AT_MCP_NETWORK"],
    appview_reads: value["AT_MCP_APPVIEW_READS"],
    accounts_file: value["AT_MCP_ACCOUNTS_FILE"],
    inbound_state_dir: value["AT_MCP_STATE_DIR"],
    write_quota: [
      limit: value["AT_MCP_WRITE_LIMIT"],
      window_seconds: value["AT_MCP_WRITE_WINDOW_SECONDS"]
    ],
    notifications_enabled: value["AT_MCP_NOTIFICATIONS"],
    notifications_interval_ms: value["AT_MCP_NOTIFICATIONS_INTERVAL_SECONDS"] * 1000,
    jetstream_enabled: value["AT_MCP_JETSTREAM"],
    inbound_store: [
      max_pending: value["AT_MCP_INBOUND_MAX_EVENTS"],
      max_bytes: value["AT_MCP_INBOUND_MAX_BYTES"]
    ],
    post_images: [
      max_bytes: value["AT_MCP_IMAGE_MAX_BYTES"],
      fetch_ms: value["AT_MCP_IMAGE_FETCH_SECONDS"] * 1000
    ],
    media_dir: value["AT_MCP_MEDIA_DIR"],
    delivery: [
      url: value["AT_MCP_DELIVERY_URL"],
      token: value["AT_MCP_DELIVERY_TOKEN"],
      token_file: value["AT_MCP_DELIVERY_TOKEN_FILE"]
    ],
    env_accounts: [default: account.(""), second: account.("_2")],
    connect_grant: value["AT_MCP_GRANT"],
    settings: report
end
