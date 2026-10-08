defmodule AtMcp.MixProject do
  use Mix.Project

  def project do
    [
      app: :at_mcp,
      version: "0.2.0",
      elixir: "~> 1.19",
      description: "An agent's own AT Protocol identity, sessions and tools through MCP",
      package: [
        licenses: ["MIT", "Apache-2.0"],
        links: %{"Source" => "https://github.com/GroveResearch/at_mcp"},
        files: [
          "lib",
          "config",
          "priv/lexicons",
          "c_src",
          "Makefile",
          "mix.exs",
          "README.md",
          "decisions.md",
          "LICENSE",
          "licenses",
          "docs",
          "rel",
          ".formatter.exs"
        ]
      ],
      docs: [
        main: "readme",
        extras: [
          "README.md",
          "docs/embedding.md",
          "docs/operations.md",
          "docs/DESIGN.md",
          "decisions.md"
        ],
        source_url: "https://github.com/GroveResearch/at_mcp",
        source_ref: "main"
      ],
      start_permanent: Mix.env() == :prod,
      releases: [at_mcp: [overlays: ["rel/overlays"], steps: [:assemble, &write_build/1]]],
      compilers: [:elixir_make] ++ Mix.compilers(),
      make_clean: ["clean"],
      deps: deps(),
      aliases: aliases(),
      elixirc_paths: elixirc_paths(Mix.env())
    ]
  end

  def application do
    [
      extra_applications: [:logger, :inets, :ssl],
      mod: {AtMcp.Application, []}
    ]
  end

  def cli do
    [preferred_envs: [check: :test, "at_mcp.check": :test]]
  end

  # A release names its build in `BUILD` at its root: the version and the
  # commit it was built from, and `-dirty` when the tree had uncommitted
  # changes. Continuous integration names the GitHub release and its tarball
  # from this file, so the two cannot disagree about what was built. The
  # example service units travel with the release as `examples/`, so
  # installing one needs only the release.
  @doc false
  def write_build(release) do
    File.write!(Path.join(release.path, "BUILD"), build_name(release.version) <> "\n")
    File.cp_r!("rel/examples", Path.join(release.path, "examples"))
    File.cp_r!("licenses", Path.join(release.path, "licenses"))
    File.cp!("LICENSE", Path.join(release.path, "LICENSE"))
    Code.require_file("rel/notices.exs")
    AtMcp.ReleaseNotices.install(release)
  end

  defp build_name(version) do
    with {sha, 0} <- System.cmd("git", ["rev-parse", "--short=7", "HEAD"], stderr_to_stdout: true),
         {status, 0} <-
           System.cmd("git", ["status", "--porcelain", "--untracked-files=no"],
             stderr_to_stdout: true
           ) do
      dirty = if String.trim(status) == "", do: "", else: "-dirty"
      "#{version}-#{String.trim(sha)}#{dirty}"
    else
      _ -> version
    end
  rescue
    _ -> version
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:proto_rune, "~> 0.6.0"},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      {:ex_mcp, "~> 1.5"},
      {:elixir_make, "~> 0.10", runtime: false},
      {:plug, "~> 1.20"},
      {:plug_cowboy, "~> 2.9"},
      {:plug_crypto, "~> 2.1"},
      {:req, "~> 0.7"},
      {:jason, "~> 1.4"}
    ]
  end

  defp aliases do
    [
      check: ["format --check-formatted", "compile --warnings-as-errors", "test"],
      "at_mcp.check": ["check"]
    ]
  end
end
