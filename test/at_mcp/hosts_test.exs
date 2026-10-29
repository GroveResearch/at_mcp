defmodule AtMcp.HostsTest do
  @moduledoc """
  What a host's model receives from a read, seen through the host itself.

  Hosts disagree about which half of a tool result the model reads: Claude
  Code gives it `structuredContent` when there is any, and `content` only
  otherwise. So a read returns text alone unless asked for json
  (`AtMcp.MCP.Output`), and this test reads one through Claude Code against
  the running endpoint, with a stand-in account, and checks what came back to
  the model.
  """
  use ExUnit.Case, async: false

  # Left out of the suite (test/test_helper.exs): it calls a model.
  @moduletag :hosts

  alias AtMcp.Summary
  alias AtMcp.Test.Grant

  @fixture Path.expand("../fixtures/fieldnote-post.json", __DIR__)

  setup do
    old = Application.get_env(:at_mcp, :network)
    Application.put_env(:at_mcp, :network, :delve)

    on_exit(fn ->
      if old,
        do: Application.put_env(:at_mcp, :network, old),
        else: Application.delete_env(:at_mcp, :network)
    end)

    post = @fixture |> File.read!() |> Jason.decode!()
    page = %{count: 1, items: [Summary.extract(:post, post)], cursor: "c2"}
    id = "hosts_#{System.unique_integer([:positive])}"

    {:ok, _} =
      AtMcp.Identities.start_identity(
        id: id,
        listen_enabled: false,
        backend: AtMcp.Test.MockBackend,
        backend_state: %{did: "did:plc:mock", mock: true, timeline: page},
        write_quota: AtMcp.Test.QuotaFixture.quota(1)
      )

    on_exit(fn -> AtMcp.Identities.stop_identity(id) end)
    %{token: Grant.token(id, :read), post: post}
  end

  # The CLI calls a model, so it needs the CLI and a credential for it; the
  # `hosts` job in .github/workflows/check.yml installs one and supplies the
  # other.
  @tag timeout: 240_000
  @tag skip:
         is_nil(System.find_executable("claude")) &&
           "needs the claude CLI (npm install @anthropic-ai/claude-code) and a credential for it"
  test "Claude Code's model receives the text of a read, not its JSON", ctx do
    received = through_claude(ctx.token, "get_timeline")

    # The reading: who wrote it, quoted words, and the uri a write takes.
    assert received =~ ~s|"Example Notes · AI" (@fieldnote.example.test)|
    assert received =~ "uri: #{ctx.post["uri"]}"
    assert received =~ "pass cursor: c2"
    refute received =~ ~s("author_did")
    refute received =~ ~s("items")
  end

  # Runs one read through `claude -p` and returns what the model was given as
  # the tool's result, from the host's own record of the conversation.
  defp through_claude(token, tool) do
    dir = Path.join(System.tmp_dir!(), "at_mcp-hosts-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    config = Path.join(dir, "mcp.json")

    File.write!(
      config,
      Jason.encode!(%{
        mcpServers: %{
          at_mcp: %{type: "http", url: Grant.url(), headers: %{authorization: "Bearer " <> token}}
        }
      })
    )

    name = "mcp__at_mcp__" <> tool

    {output, status} =
      System.cmd(
        "claude",
        [
          "-p",
          "Call the #{name} tool once with no arguments, then reply with the single word done.",
          "--mcp-config",
          config,
          "--strict-mcp-config",
          "--allowedTools",
          name,
          "--max-turns",
          "3",
          "--model",
          "haiku",
          "--output-format",
          "stream-json",
          "--verbose"
        ],
        cd: dir,
        stderr_to_stdout: true
      )

    assert status == 0, output

    results =
      for line <- String.split(output, "\n", trim: true),
          {:ok, %{"type" => "user", "message" => %{"content" => content}}} <- [Jason.decode(line)],
          is_list(content),
          %{"type" => "tool_result"} = block <- content,
          do: block_text(block["content"])

    assert results != [], "Claude Code made no tool call:\n" <> output
    Enum.join(results, "\n")
  end

  defp block_text(text) when is_binary(text), do: text

  defp block_text(blocks) when is_list(blocks),
    do: Enum.map_join(blocks, "\n", &(&1["text"] || Jason.encode!(&1)))
end
