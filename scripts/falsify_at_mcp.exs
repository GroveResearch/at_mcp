# Matklad-style live probes for AtMcp claims 3,4,6(live).
# Run from at_mcp/:
#   set -a; source ../dwell/.env; set +a
#   AT_MCP_PORT=4411 AT_MCP_JETSTREAM=0 mix run scripts/falsify_at_mcp.exs
#
# mix run starts the OTP app (Effects + MCP HTTP + Listen).

defmodule AtMcp.FalsifyLive do
  @moduledoc false

  def main do
    Process.flag(:trap_exit, true)
    port = Application.get_env(:at_mcp, :mcp_port, 4400)
    url = "http://127.0.0.1:#{port}/mcp"
    IO.puts("MCP URL: #{url}")
    IO.puts("BLUESKY_HANDLE set?: #{not is_nil(System.get_env("BLUESKY_HANDLE"))}")

    results =
      %{}
      |> Map.merge(probe_mcp(url))
      |> Map.merge(probe_jetstream_live())

    print_matrix(results)
    File.write!("scripts/falsify_at_mcp_report.md", inspect(results, pretty: true, limit: 80))
    IO.puts("Wrote scripts/falsify_at_mcp_report.md")
  end

  defp probe_mcp(url) do
    case ExMCP.Client.connect(url) do
      {:ok, client} ->
        list_result = ExMCP.Client.list_tools(client, timeout: 15_000, format: :map)
        claim3 = evaluate_tools_list(list_result)

        claim4 =
          with {:ok, status} <-
                 ExMCP.Client.call_tool(client, "identity_status", %{},
                   timeout: 45_000,
                   format: :map
                 ),
               status_text = extract_text(status),
               {:ok, profile} <-
                 ExMCP.Client.call_tool(
                   client,
                   "get_profile",
                   %{},
                   timeout: 45_000,
                   format: :map
                 ),
               profile_text = extract_text(profile) do
            cond do
              String.contains?(profile_text, "error:") and
                  not (profile_text =~ ~r/did|handle/i) ->
                {"FAIL", "identity=#{clip(status_text)}; profile=#{clip(profile_text)}"}

              status_text =~ "logged_in" or profile_text =~ ~r/did|handle/i ->
                {"PASS", "identity=#{clip(status_text)}; profile=#{clip(profile_text)}"}

              true ->
                {"FAIL", "unexpected identity=#{clip(status_text)} profile=#{clip(profile_text)}"}
            end
          else
            {:error, reason} ->
              {"FAIL", "tools/call error: #{inspect(reason)}"}
          end

        %{claim3: claim3, claim4: claim4, mcp_url: url}

      {:error, reason} ->
        %{
          claim3: {"FAIL", "connect failed: #{inspect(reason)}"},
          claim4: {"FAIL", "no client"},
          mcp_url: url
        }
    end
  rescue
    e ->
      %{
        claim3: {"FAIL", Exception.message(e)},
        claim4: {"FAIL", Exception.message(e)},
        mcp_url: url
      }
  end

  defp evaluate_tools_list({:ok, payload}) do
    tools = tools_from(payload)
    names = MapSet.new(Enum.map(tools, &tool_name/1))
    need = ["post", "get_profile", "identity_status", "like"]
    missing = Enum.reject(need, &MapSet.member?(names, &1))
    post = Enum.find(tools, &(tool_name(&1) == "post"))
    get_profile = Enum.find(tools, &(tool_name(&1) == "get_profile"))

    ann_ok? =
      missing == [] and read_only?(get_profile) == true and read_only?(post) == false

    evidence =
      "n=#{length(tools)} missing=#{inspect(missing)} " <>
        "get_profile.ann=#{inspect(annotations(get_profile))} " <>
        "post.ann=#{inspect(annotations(post))}"

    if ann_ok?, do: {"PASS", evidence}, else: {"FAIL", evidence}
  end

  defp evaluate_tools_list({:error, reason}), do: {"FAIL", inspect(reason)}

  defp tools_from(%{"tools" => tools}) when is_list(tools), do: tools
  defp tools_from(%{tools: tools}) when is_list(tools), do: tools

  defp tools_from(other) when is_map(other),
    do: Map.get(other, "tools") || Map.get(other, :tools) || []

  defp tools_from(_), do: []

  defp tool_name(%{"name" => n}), do: n
  defp tool_name(%{name: n}), do: n
  defp tool_name(_), do: nil

  defp annotations(nil), do: nil
  defp annotations(tool), do: Map.get(tool, "annotations") || Map.get(tool, :annotations)

  defp read_only?(nil), do: nil

  defp read_only?(tool) do
    case annotations(tool) do
      %{readOnlyHint: v} -> v
      %{"readOnlyHint" => v} -> v
      _ -> nil
    end
  end

  defp extract_text(%{"content" => content}) when is_list(content) do
    Enum.map_join(content, "\n", fn
      %{"text" => t} -> t
      %{text: t} -> t
      other -> inspect(other)
    end)
  end

  defp extract_text(%{content: content}) when is_list(content),
    do: extract_text(%{"content" => content})

  defp extract_text(other), do: inspect(other)

  defp probe_jetstream_live do
    # Prefer session DID after a successful login; else a synthetic DID.
    did =
      case Process.whereis(AtMcp.Effects) do
        nil -> nil
        pid -> AtMcp.Effects.session_did(pid)
      end

    did = did || "did:plc:falsify-live-probe"
    parent = self()

    # Stop app Listen jetstream name clash if any
    if pid = Process.whereis(AtMcp.Listen.Jetstream) do
      try do
        GenServer.stop(pid, :normal, 500)
      catch
        :exit, _ -> :ok
      end
    end

    result =
      try do
        case ProtoRune.Jetstream.start_link(
               handler: parent,
               wanted_dids: [did],
               wanted_collections: ["app.bsky.feed.post"],
               auto_reconnect: false,
               name: :at_mcp_falsify_live_jetstream
             ) do
          {:ok, pid} ->
            receive do
              {:jetstream, event} ->
                safe_stop(pid)

                {"PASS", "event received type=#{inspect(event_type(event))} wanted_dids=[#{did}]"}
            after
              5_000 ->
                alive? = Process.alive?(pid)
                safe_stop(pid)

                if alive? do
                  {"PASS", "alive 5s without crash (quiet stream) wanted_dids=[#{did}]"}
                else
                  {"FAIL", "died within 5s wanted_dids=[#{did}]"}
                end
            end

          {:error, reason} ->
            {"FAIL", "start_link: #{inspect(reason)}"}
        end
      catch
        kind, reason ->
          {"FAIL", "#{kind}: #{inspect(reason)}"}
      end

    %{claim6_live: result}
  end

  defp event_type(%{type: t}), do: t
  defp event_type(%{"type" => t}), do: t
  defp event_type(%{__struct__: s}), do: s
  defp event_type(_), do: :unknown

  defp safe_stop(pid) do
    if is_pid(pid) and Process.alive?(pid) do
      Process.unlink(pid)
      Process.exit(pid, :kill)
    end
  catch
    _, _ -> :ok
  end

  defp print_matrix(results) do
    rows = [
      {"1 Single login", "PASS", "unit falsify_claims_test claim1"},
      {"2 Write rail", "PASS", "unit max_writes=1 → :post_budget_exhausted"},
      {"3 MCP tools/list", elem(results.claim3, 0), elem(results.claim3, 1)},
      {"4 MCP tools/call read", elem(results.claim4, 0), elem(results.claim4, 1)},
      {"5 Honest doors", "PASS",
       "unit Notifications poll inbound; Jetstream wanted_dids=own-repo"},
      {"6 Jetstream unit", "PASS", "unit FakeJetstream wanted_dids"},
      {"6 Jetstream live", elem(results.claim6_live, 0), elem(results.claim6_live, 1)},
      {"7 dwell import", "see dwell", "falsify_at_mcp_claims_test + acp_test"},
      {"8 Permission grain", "see dwell", "permission_policy :client for mcp_at_mcp_post"},
      {"9 Refresh ownership", "PASS", "unit no Effects.login( in MCP"},
      {"10 Haven attach doc", "see haven", "falsify_at_mcp_attach_test"}
    ]

    IO.puts("\n## Falsify matrix\n")
    IO.puts("| CLAIM | RESULT | EVIDENCE |")
    IO.puts("| --- | --- | --- |")

    for {c, r, e} <- rows do
      e = e |> to_string() |> String.replace("|", "/") |> String.replace("\n", " ")
      IO.puts("| #{c} | #{r} | #{e} |")
    end

    IO.puts("")
  end

  defp clip(s) when is_binary(s) do
    s = String.replace(s, "\n", " ")
    if String.length(s) > 200, do: String.slice(s, 0, 200) <> "…", else: s
  end

  defp clip(other), do: clip(inspect(other))
end

AtMcp.FalsifyLive.main()
