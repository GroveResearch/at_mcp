defmodule AtMcp.ReleaseNotices do
  @moduledoc false
  @runtime_apps ~w(asn1 compiler crypto inets kernel public_key sasl ssl stdlib)
  @elixir_apps ~w(eex elixir iex logger)

  def install(release) do
    otp = :erlang.system_info(:otp_release) |> to_string()

    otp_version =
      File.read!(Path.join([to_string(:code.root_dir()), "releases", otp, "OTP_VERSION"]))
      |> String.trim()

    [{_, _, openssl}] = :crypto.info_lib()
    [_, openssl_version | _] = String.split(to_string(openssl))

    copy!(release.path, Mix.Project.deps_paths(),
      otp: otp_version,
      elixir: System.version(),
      openssl: openssl_version,
      strict: strict?()
    )

    release
  end

  # A build for distribution, in CI or with RELEASE_VERSION set, must bundle the
  # notices for the exact Erlang, Elixir and OpenSSL it carries. A local build
  # from source runs on whatever versions the machine has, so a missing tree
  # becomes a pointer to the upstream license instead of a failed build.
  def strict? do
    System.get_env("CI") not in [nil, "", "false"] or
      System.get_env("RELEASE_VERSION") not in [nil, ""]
  end

  def copy!(release_path, deps, versions, notices \\ Path.join(__DIR__, "notices")) do
    strict = Keyword.get(versions, :strict, true)

    target = Path.join(release_path, "licenses/bundled")
    File.rm_rf!(target)
    File.mkdir_p!(target)

    apps =
      Path.wildcard(Path.join(release_path, "lib/*")) |> Enum.map(&Path.basename/1) |> Enum.sort()

    Enum.each(apps, fn entry ->
      [app, _version] = String.split(entry, "-", parts: 2)
      destination = Path.join(target, entry)

      cond do
        app == "at_mcp" ->
          :ok

        app in @runtime_apps ->
          runtime_tree!(notices, "otp-#{versions[:otp]}", destination, strict)

        app in @elixir_apps ->
          runtime_tree!(notices, "elixir-#{versions[:elixir]}", destination, strict)

        true ->
          source = Map.fetch!(deps, String.to_atom(app))

          files =
            Path.wildcard(Path.join(source, "*"))
            |> Enum.filter(fn path ->
              File.regular?(path) and
                Regex.match?(~r/^(license|licence|copying|notice)(\.|$)/i, Path.basename(path))
            end)

          readme = Path.join(source, "README.md")

          license_section =
            if File.exists?(readme),
              do: Regex.run(~r/^\#{1,3} License\b.*\z/msi, File.read!(readme)),
              else: nil

          File.mkdir_p!(destination)
          Enum.each(files, &File.cp!(&1, Path.join(destination, Path.basename(&1))))

          if license_section,
            do: File.write!(Path.join(destination, "README-license.md"), hd(license_section))

          cond do
            files != [] ->
              :ok

            app in ["castore", "ecto", "nimble_pool"] and license_section != nil ->
              apache = Path.join(notices, "elixir-#{versions[:elixir]}/LICENSES/Apache-2.0.txt")

              if File.exists?(apache) or strict,
                do: File.cp!(apache, Path.join(destination, "Apache-2.0.txt")),
                else: upstream_pointer!("elixir-#{versions[:elixir]}", destination)

            app == "mint_web_socket" ->
              copy_tree!(notices, entry, destination)

            true ->
              raise "No upstream license notice found for #{entry} in #{source}"
          end

          if app == "castore",
            do: copy_tree!(notices, "castore-data", Path.join(destination, "certificate-data"))
      end
    end)

    runtime_tree!(notices, "otp-#{versions[:otp]}", Path.join(target, "erts"), strict)
    runtime_tree!(notices, "openssl-#{versions[:openssl]}", Path.join(target, "openssl"), strict)
    File.write!(Path.join(target, "APPLICATIONS"), Enum.join(apps, "\n") <> "\n")
    files = Path.wildcard(Path.join(target, "**/*")) |> Enum.filter(&File.regular?/1)

    lines =
      Enum.map(files, fn path ->
        digest = :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)
        digest <> "  " <> Path.relative_to(path, target)
      end)

    File.write!(Path.join(target, "SHA256SUMS"), Enum.join(lines, "\n") <> "\n")
    verify!(release_path)
  end

  def verify!(release_path) do
    target = Path.join(release_path, "licenses/bundled")

    expected =
      Path.wildcard(Path.join(release_path, "lib/*")) |> Enum.map(&Path.basename/1) |> Enum.sort()

    actual = File.read!(Path.join(target, "APPLICATIONS")) |> String.split("\n", trim: true)
    if actual != expected, do: raise("Bundled application notices do not match the release")

    File.read!(Path.join(target, "SHA256SUMS"))
    |> String.split("\n", trim: true)
    |> Enum.each(fn line ->
      [digest, path] = String.split(line, "  ", parts: 2)

      actual =
        :crypto.hash(:sha256, File.read!(Path.join(target, path))) |> Base.encode16(case: :lower)

      if actual != digest, do: raise("Changed bundled notice: #{path}")
    end)

    :ok
  end

  defp runtime_tree!(root, entry, target, strict) do
    if strict or File.dir?(Path.join(root, entry)),
      do: copy_tree!(root, entry, target),
      else: upstream_pointer!(entry, target)
  end

  defp upstream_pointer!(entry, target) do
    File.mkdir_p!(target)

    File.write!(
      Path.join(target, "UPSTREAM-NOTICES.txt"),
      "This local build does not bundle the license notices for #{entry}. " <>
        "They are in that project's own distribution.\n"
    )
  end

  defp copy_tree!(root, entry, target) do
    source = Path.join(root, entry)
    if not File.dir?(source), do: raise("Missing upstream release notices: #{source}")

    entries = File.read!(Path.join(source, "SHA256SUMS")) |> String.split("\n", trim: true)
    if entries == [], do: raise("Empty upstream notice manifest: #{source}")

    Enum.each(entries, fn line ->
      [digest, path] = String.split(line, "  ", parts: 2)

      actual =
        :crypto.hash(:sha256, File.read!(Path.join(source, path))) |> Base.encode16(case: :lower)

      if actual != digest, do: raise("Changed upstream notice: #{source}/#{path}")
    end)

    File.cp_r!(source, target)
  end
end
