# Run only with explicit authorization for the three public test posts below.
# MIX_ENV=test mix run --no-start scripts/live_roundtrip.exs
# Requires PROBE_{FIRST,SECOND}_{URL,GRANT_FILE,DID}. The host colleagues
# should be in read-only mode while this probe observes their inbound turns.
# Only records created by this invocation are deleted. A private receipt retains
# their URIs and cleanup outcomes if the probe is interrupted or cleanup fails.
Application.ensure_all_started(:ex_mcp)
Application.ensure_all_started(:req)

defmodule AtMcp.LiveRoundtrip do
  def run do
    receipt = System.get_env("PROBE_RECEIPT", "/tmp/at_mcp-live-roundtrip.json")

    clients =
      for suffix <- ["FIRST", "SECOND"] do
        url = System.fetch_env!("PROBE_#{suffix}_URL")
        did = System.fetch_env!("PROBE_#{suffix}_DID")

        grant =
          System.fetch_env!("PROBE_#{suffix}_GRANT_FILE") |> File.read!() |> String.trim()

        {:ok, client} =
          ExMCP.Client.connect(url,
            headers: [{"authorization", "Bearer " <> grant}, {"x-kite-account-did", did}]
          )

        {:ok, %{"did" => ^did}} = call(client, "identity_status", %{})
        client
      end

    [grug, gregory] = clients
    Process.put(:created, [])

    try do
      first =
        create(
          grug,
          "post",
          %{"text" => "AtMcp cutover test 1/3 — account routing check; no response needed."},
          receipt
        )

      second =
        create(
          gregory,
          "reply",
          %{
            "uri" => first,
            "text" => "AtMcp cutover test 2/3 — Gregory reply check; no response needed."
          },
          receipt
        )

      _third =
        create(
          grug,
          "reply",
          %{
            "uri" => second,
            "text" => "AtMcp cutover test 3/3 — Grug return reply check; no response needed."
          },
          receipt
        )

      IO.puts("Three test records created; observing inbound delivery for 30 seconds.")
      Process.sleep(30_000)
    after
      for %{client: client, uri: uri} <- Process.get(:created, []) do
        result = call(client, "delete_post", %{"uri" => uri})
        update_receipt(receipt, uri, result)

        IO.puts(
          "cleanup #{uri}: #{if match?({:ok, _}, result), do: "deleted", else: "FAILED — see receipt"}"
        )
      end

      for client <- clients, do: ExMCP.Client.disconnect(client)
    end
  end

  defp create(client, name, args, receipt) do
    {:ok, %{"uri" => uri}} = call(client, name, args)
    Process.put(:created, [%{client: client, uri: uri} | Process.get(:created)])
    previous = if File.exists?(receipt), do: Jason.decode!(File.read!(receipt)), else: []
    File.write!(receipt, Jason.encode!([%{uri: uri, deleted: false} | previous], pretty: true))
    File.chmod!(receipt, 0o600)
    IO.puts("created #{uri}")
    uri
  end

  defp call(client, name, args) do
    case ExMCP.Client.call_tool(client, name, args, format: :map) do
      {:ok, result} ->
        content = result["content"] || result[:content]
        text = Enum.map_join(content, &(&1["text"] || &1[:text]))
        if result["isError"] || result[:isError], do: {:error, text}, else: Jason.decode(text)

      error ->
        error
    end
  end

  defp update_receipt(path, uri, result) do
    entries = Jason.decode!(File.read!(path))

    entries =
      Enum.map(entries, fn entry ->
        if entry["uri"] == uri,
          do: Map.put(entry, "deleted", match?({:ok, _}, result)),
          else: entry
      end)

    File.write!(path, Jason.encode!(entries, pretty: true))
  end
end

AtMcp.LiveRoundtrip.run()
