defmodule AtMcp.MixProject do
  use Mix.Project

  def project do
    [
      app: :at_mcp,
      version: version(),
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
          "VERSION",
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

  # The version comes from the release tag, not from this file, so a release
  # is cut by pushing a tag and nothing else. In order:
  #
  #   VERSION          a file beside this one that CI writes into the Hex
  #                    package it publishes, so an application depending on
  #                    the package compiles it as the version it asked for,
  #                    whatever its own environment holds. Not committed;
  #                    `mix hex.build` refuses to build a package without it.
  #   RELEASE_VERSION  the environment, which CI sets from a `vX.Y.Z` tag
  #                    (scripts/release_version.sh) when it builds a release.
  #   0.0.0-dev        anything else: a checkout, a pull request, main. The
  #                    release's BUILD still names the commit it came from.
  #
  # A value that is not a semantic version stops the build.
  defp version do
    given =
      case File.read(Path.join(__DIR__, "VERSION")) do
        {:ok, file} -> String.trim(file)
        {:error, _} -> String.trim(System.get_env("RELEASE_VERSION", ""))
      end

    cond do
      given == "" -> "0.0.0-dev"
      match?({:ok, _}, Version.parse(given)) -> given
      true -> Mix.raise("version #{inspect(given)} is not a semantic version (X.Y.Z)")
    end
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
    same_version!(release)
    File.write!(Path.join(release.path, "BUILD"), build_name(release.version) <> "\n")
    File.cp_r!("rel/examples", Path.join(release.path, "examples"))
    File.cp_r!("licenses", Path.join(release.path, "licenses"))
    File.cp!("LICENSE", Path.join(release.path, "LICENSE"))
    Code.require_file("rel/notices.exs")
    AtMcp.ReleaseNotices.install(release)
  end

  # Mix recompiles on file changes, not on RELEASE_VERSION, so a build left
  # from another version would go into this release under the old version.
  # CI always builds from nothing; elsewhere this says to.
  defp same_version!(release) do
    built = to_string(release.applications[:at_mcp][:vsn])

    if built != release.version do
      Mix.raise(
        "at_mcp was compiled as #{built}, but this release is #{release.version}: " <>
          "run `MIX_ENV=#{Mix.env()} mix clean` and build the release again"
      )
    end
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
      {:ex_mcp, "~> 1.7 and >= 1.7.3"},
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
