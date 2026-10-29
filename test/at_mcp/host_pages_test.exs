defmodule AtMcp.HostPagesTest do
  @moduledoc """
  The pages in docs/hosts/ say how to use at_mcp from each host. What can be
  run here is run as written: the plain script's example, against the
  service's endpoint with a stand-in account. (Claude Code's page is run in
  `AtMcp.HostsTest`, which needs a model.) Every link in the pages resolves.
  """
  use ExUnit.Case, async: false

  alias AtMcp.Summary
  alias AtMcp.Test.Grant

  @pages Path.wildcard(Path.expand("../../docs/hosts/*.md", __DIR__))
  @fixture Path.expand("../fixtures/fieldnote-post.json", __DIR__)

  setup do
    old = Application.get_env(:at_mcp, :network)
    Application.put_env(:at_mcp, :network, :delve)

    on_exit(fn ->
      if old,
        do: Application.put_env(:at_mcp, :network, old),
        else: Application.delete_env(:at_mcp, :network)
    end)

    :ok
  end

  @tag :tmp_dir
  @tag skip: is_nil(System.find_executable("python3")) && "needs python3"
  test "the plain script's example reads the timeline through the service, as JSON",
       %{tmp_dir: dir} do
    post = @fixture |> File.read!() |> Jason.decode!()
    page = %{count: 1, items: [Summary.extract(:post, post)], cursor: nil}
    id = "host_pages_script"

    {:ok, _} =
      AtMcp.Identities.start_identity(
        id: id,
        listen_enabled: false,
        backend: AtMcp.Test.MockBackend,
        backend_state: %{did: "did:plc:mock", mock: true, timeline: page}
      )

    on_exit(fn -> AtMcp.Identities.stop_identity(id) end)

    [script] =
      AtMcp.Test.Docs.blocks(Path.expand("../../docs/hosts/script.md", __DIR__), "python")

    path = Path.join(dir, "example.py")
    File.write!(path, script)

    {output, status} =
      System.cmd("python3", ["-I", path],
        env: [{"AT_MCP_URL", Grant.url()}, {"AT_MCP_GRANT", Grant.token(id, :read)}],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output == "fieldnote.example.test #{post["uri"]}\n"
  end

  test "every link in the host pages reaches a file, and a heading where it names one" do
    for page <- @pages,
        [_, target] <- Regex.scan(~r/\]\(([^)\s]+)\)/, File.read!(page)),
        not String.starts_with?(target, "http") do
      [file | anchor] = String.split(target, "#", parts: 2)
      linked = Path.expand(file, Path.dirname(page))
      assert File.exists?(linked), "#{Path.basename(page)} links to #{target}, which is missing"

      for anchor <- anchor do
        slugs =
          for "#" <> heading <- String.split(File.read!(linked), "\n"),
              do: heading |> String.trim_leading("#") |> slug()

        assert anchor in slugs, "#{Path.basename(page)} links to #{target}, a heading not there"
      end
    end
  end

  # A heading's anchor as GitHub writes it.
  defp slug(heading) do
    heading
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[^\p{L}\p{N}\s_-]/u, "")
    |> String.replace(" ", "-")
  end
end
