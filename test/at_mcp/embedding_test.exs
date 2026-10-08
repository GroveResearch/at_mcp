defmodule AtMcp.EmbeddingTest do
  use ExUnit.Case, async: false

  @tag :tmp_dir
  test "a separate consumer boots without inherited environment accounts or callbacks", %{
    tmp_dir: dir
  } do
    consumer = Path.join(dir, "consumer")
    state_dir = Path.join(dir, "state")
    ignored_dir = Path.join(dir, "must-not-use")
    File.mkdir_p!(Path.join(consumer, "config"))
    at_mcp = Path.expand("../..", __DIR__)

    File.write!(Path.join(consumer, "mix.exs"), """
    defmodule EmbeddingConsumer.MixProject do
      use Mix.Project
      def project, do: [app: :embedding_consumer, version: "0.1.0",
        deps_path: #{inspect(Path.join(at_mcp, "deps"))},
        deps: [{:at_mcp, path: #{inspect(at_mcp)}}]]
      def application, do: [extra_applications: [:logger]]
    end
    """)

    File.write!(Path.join(consumer, "config/config.exs"), """
    import Config
    config :at_mcp, boot_from_env: false, inbound_state_dir: #{inspect(state_dir)},
      start_mcp: false, jetstream_enabled: false, notifications_enabled: false
    config :logger, level: :warning
    """)

    # Reuse exact installed dependencies without fetching or changing their source.
    # Keep compilation output isolated from the running parent test project.
    File.cp!(Path.join(at_mcp, "mix.lock"), Path.join(consumer, "mix.lock"))
    File.mkdir_p!(Path.join(consumer, "_build/test"))
    # Build priv paths are relative symlinks; dereference them when relocating
    # the cache so native dependencies remain usable in the consumer project.
    {_, 0} =
      System.cmd("cp", [
        "-RL",
        Path.join(Mix.Project.build_path(), "lib"),
        Path.join(consumer, "_build/test/lib")
      ])

    script = Path.expand("../support/embedding_consumer.exs", __DIR__)

    env = [
      {"MIX_ENV", "test"},
      {"AT_MCP_HANDLE", "inherited-sentinel"},
      {"AT_MCP_APP_PASSWORD", "private-sentinel-never-read"},
      {"AT_MCP_HOST_TOKEN_FILE", Path.join(dir, "missing-host-secret")},
      {"AT_MCP_DELIVERY_URL", "invalid-inherited-url"},
      {"AT_MCP_DELIVERY_TOKEN_FILE", Path.join(dir, "missing-haven-secret")},
      {"AT_MCP_PORT", "invalid-inherited-port"},
      {"AT_MCP_STATE_DIR", ignored_dir},
      {"AT_MCP_ENV_FILE", nil}
    ]

    {output, code} =
      System.cmd("mix", ["run", script], cd: consumer, env: env, stderr_to_stdout: true)

    assert code == 0, output
    assert output =~ "embedding-consumer-passed"
    assert output =~ ~s("ready":true)
    refute output =~ "private-sentinel-never-read"
    refute File.exists?(ignored_dir)
    assert File.exists?(Path.join(state_dir, "inbound.term"))
  end
end
