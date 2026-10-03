defmodule AtMcp.ReleaseEnvTest do
  @moduledoc """
  `rel/env.sh.eex`, the script every release command sources before AtMcp
  starts, run by the system's `sh` under a clean environment.
  """
  use ExUnit.Case, async: true
  @moduletag :tmp_dir

  @script Path.expand("../../rel/env.sh.eex", __DIR__)

  # What the release script has set when it sources env.sh, then what env.sh
  # leaves behind: {status, "AT_MCP_ENV_FILE|AT_MCP_MARK|LANG|RELEASE_NODE"}.
  # `set -e`, as `bin/at_mcp` has, so a line of the file that fails stops it.
  defp source(dir, extra \\ []) do
    env =
      [
        {"PATH", "/usr/bin:/bin"},
        {"HOME", dir},
        {"RELEASE_ROOT", Path.join(dir, "at_mcp")},
        {"RELEASE_NAME", "at_mcp"},
        {"RELEASE_COMMAND", "rpc"},
        {"RELEASE_COOKIE", "scratch-cookie"}
      ]
      |> Map.new()
      |> Map.merge(Map.new(extra))
      |> Enum.reject(fn {_, v} -> is_nil(v) end)

    {out, status} =
      System.cmd(
        "/usr/bin/env",
        ["-i"] ++
          Enum.map(env, fn {k, v} -> "#{k}=#{v}" end) ++
          [
            "sh",
            "-c",
            ~S(set -e; . "$1"; printf '%s|%s|%s|%s' "${AT_MCP_ENV_FILE:-}" "${AT_MCP_MARK:-}" "$LANG" "$RELEASE_NODE"),
            "sh",
            @script
          ],
        stderr_to_stdout: true
      )

    {status, out}
  end

  test "loads the environment file AT_MCP_ENV_FILE names", %{tmp_dir: dir} do
    file = Path.join(dir, "at_mcp.env")
    File.write!(file, "AT_MCP_MARK=sourced\nRELEASE_NODE=at_mcp_two\n")

    assert {0, said} = source(dir, [{"AT_MCP_ENV_FILE", file}])
    assert [^file, "sourced", _lang, "at_mcp_two@localhost"] = String.split(said, "|")

    # Without it, nothing is read and the defaults hold.
    assert {0, said} = source(dir)
    assert ["", "", _lang, "at_mcp@localhost"] = String.split(said, "|")
  end

  # The environment file is NAME=value lines that sh and systemd's
  # EnvironmentFile= both read. A value with a space, such as a path under
  # `~/Library/Application Support`, is double-quoted; written bare, sh runs
  # the part after the space as a command and the release never starts.
  test "a double-quoted value with a space reaches the command whole", %{tmp_dir: dir} do
    file = Path.join(dir, "at_mcp.env")
    spaced = "/Users/you/Library/Application Support/AtMcp/accounts.json"

    File.write!(file, ~s(AT_MCP_MARK="#{spaced}"\n))
    assert {0, said} = source(dir, [{"AT_MCP_ENV_FILE", file}])
    assert [_, ^spaced, _, _] = String.split(said, "|")

    File.write!(file, "AT_MCP_MARK=#{spaced}\n")
    assert {status, _} = source(dir, [{"AT_MCP_ENV_FILE", file}])
    assert status != 0
  end

  test "refuses a file it cannot read, or a relative path", %{tmp_dir: dir} do
    assert {66, said} = source(dir, [{"AT_MCP_ENV_FILE", Path.join(dir, "absent.env")}])
    assert said =~ "cannot be read"

    assert {64, said} = source(dir, [{"AT_MCP_ENV_FILE", "at_mcp.env"}])
    assert said =~ "absolute"
  end

  # The release script falls back to releases/COOKIE, which every copy of a
  # published release carries, so a command that uses distribution refuses to
  # run without the installation's own. `eval` uses none and is not stopped.
  test "a distribution command refuses an empty or missing RELEASE_COOKIE", %{tmp_dir: dir} do
    file = Path.join(dir, "at_mcp.env")
    File.write!(file, "RELEASE_COOKIE=\n")

    for command <- ["start", "daemon", "rpc", "remote", "stop", "pid"] do
      assert {78, said} =
               source(dir, [{"RELEASE_COMMAND", command}, {"AT_MCP_ENV_FILE", file}])

      assert said =~ "openssl rand -hex 32"
      assert {78, _} = source(dir, [{"RELEASE_COMMAND", command}, {"RELEASE_COOKIE", ""}])
      assert {78, _} = source(dir, [{"RELEASE_COMMAND", command}, {"RELEASE_COOKIE", nil}])
    end

    assert {0, _} = source(dir, [{"RELEASE_COMMAND", "eval"}, {"AT_MCP_ENV_FILE", file}])

    File.write!(file, "RELEASE_COOKIE=from-the-file\n")
    assert {0, _} = source(dir, [{"RELEASE_COMMAND", "start"}, {"AT_MCP_ENV_FILE", file}])
  end

  test "a UTF-8 locale is supplied when there is none, one this system has", %{tmp_dir: dir} do
    {0, said} = source(dir)
    [_, _, lang, _] = String.split(said, "|")

    expected =
      if match?({:unix, :darwin}, :os.type()), do: "en_US.UTF-8", else: "C.UTF-8"

    assert lang == expected
    assert {0, said} = source(dir, [{"LANG", "fr_FR.UTF-8"}])
    assert [_, _, "fr_FR.UTF-8", _] = String.split(said, "|")
  end
end
