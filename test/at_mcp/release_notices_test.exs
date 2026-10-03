Code.require_file("../../rel/notices.exs", __DIR__)

defmodule AtMcp.ReleaseNoticesTest do
  use ExUnit.Case, async: true

  setup do
    root = Path.join(System.tmp_dir!(), "at-mcp-notices-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    File.mkdir_p!(Path.join(root, "release/lib/sample-1.0.0"))
    File.mkdir_p!(Path.join(root, "deps/sample"))

    for entry <- ["otp-1", "elixir-1", "openssl-1"] do
      File.mkdir_p!(Path.join(root, "notices/#{entry}"))
      text = "upstream #{entry} terms"
      File.write!(Path.join(root, "notices/#{entry}/LICENSE"), text)
      digest = :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)
      File.write!(Path.join(root, "notices/#{entry}/SHA256SUMS"), digest <> "  LICENSE\n")
    end

    %{
      root: root,
      release: Path.join(root, "release"),
      deps: %{sample: Path.join(root, "deps/sample")},
      notices: Path.join(root, "notices")
    }
  end

  test "a bundled dependency without its upstream notice stops the release", ctx do
    assert_raise RuntimeError, ~r/No upstream license notice found for sample-1.0.0/, fn ->
      copy(ctx)
    end

    File.write!(Path.join(ctx.deps.sample, "LICENSE"), "Copyright Example. Permission granted.")
    assert :ok = copy(ctx)
  end

  test "missing upstream runtime notice stops the build", ctx do
    File.write!(Path.join(ctx.deps.sample, "LICENSE"), "Copyright Example")
    File.rm!(Path.join(ctx.notices, "otp-1/LICENSE"))
    assert_raise File.Error, fn -> copy(ctx) end
  end

  test "empty upstream runtime manifest stops the build", ctx do
    File.write!(Path.join(ctx.deps.sample, "LICENSE"), "Copyright Example")
    File.write!(Path.join(ctx.notices, "otp-1/SHA256SUMS"), "")
    assert_raise RuntimeError, ~r/Empty upstream notice manifest/, fn -> copy(ctx) end
  end

  test "missing or changed distributed notices fail verification", ctx do
    File.write!(Path.join(ctx.deps.sample, "LICENSE"), "Copyright Example. Permission granted.")
    assert :ok = copy(ctx)
    notice = Path.join(ctx.release, "licenses/bundled/sample-1.0.0/LICENSE")
    original = File.read!(notice)
    File.rm!(notice)
    assert_raise File.Error, fn -> AtMcp.ReleaseNotices.verify!(ctx.release) end
    File.write!(notice, "wrong license")

    assert_raise RuntimeError, ~r/Changed bundled notice/, fn ->
      AtMcp.ReleaseNotices.verify!(ctx.release)
    end

    File.write!(notice, original)
    assert :ok = AtMcp.ReleaseNotices.verify!(ctx.release)
  end

  test "application inventory covers shipped apps and ignores unbundled dependencies", ctx do
    File.write!(Path.join(ctx.deps.sample, "LICENSE"), "Copyright Example")
    ctx = %{ctx | deps: Map.put(ctx.deps, :unbundled, "/does/not/exist")}
    assert :ok = copy(ctx)
    File.mkdir_p!(Path.join(ctx.release, "lib/new_app-2.0"))

    assert_raise RuntimeError, ~r/do not match the release/, fn ->
      AtMcp.ReleaseNotices.verify!(ctx.release)
    end
  end

  defp copy(ctx) do
    AtMcp.ReleaseNotices.copy!(
      ctx.release,
      ctx.deps,
      [otp: "1", elixir: "1", openssl: "1"],
      ctx.notices
    )
  end
end
