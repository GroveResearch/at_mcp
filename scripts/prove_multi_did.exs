# Multi-DID Inbound prove — two identities, one Jetstream fanout.
# Fixtures always; live Jetstream optional via AT_MCP_LIVE_INBOUND=1 (listen-only, no posts).
#
#   set -a; source /path/to/your/at_mcp-accounts.env; set +a   # the account credentials the live run needs
#   cd /path/to/at_mcp
#   mix run scripts/prove_multi_did.exs
#   AT_MCP_LIVE_INBOUND=1 AT_MCP_JETSTREAM=0 mix run scripts/prove_multi_did.exs

defmodule AtMcp.Prove.FakeJetstream do
  @moduledoc false
  use Agent

  def start_link(opts) do
    Agent.start_link(fn -> opts end, name: Keyword.get(opts, :name, __MODULE__))
  end
end

defmodule AtMcp.Prove.MultiDid do
  @moduledoc false

  def run do
    handle_a = System.fetch_env!("BLUESKY_HANDLE")
    handle_b = System.fetch_env!("BLUESKY_HANDLE_2")
    pass_a = System.fetch_env!("BLUESKY_APP_PASSWORD")
    pass_b = System.fetch_env!("BLUESKY_APP_PASSWORD_2")

    unless Process.whereis(AtMcp.Listen.Registry) do
      {:ok, _} = Registry.start_link(keys: :duplicate, name: AtMcp.Listen.Registry)
    end

    {:ok, effects_a} =
      AtMcp.Effects.start_link(name: :at_mcp_prove_a, backend: AtMcp.Effects.ProtoRune)

    {:ok, effects_b} =
      AtMcp.Effects.start_link(name: :at_mcp_prove_b, backend: AtMcp.Effects.ProtoRune)

    IO.puts(
      "Login AtMcp A (#{handle_a}) + AtMcp B (#{handle_b}) — separate Effects, never communal…"
    )

    {:ok, _} = AtMcp.Effects.login(effects_a, handle: handle_a, password: pass_a)
    {:ok, _} = AtMcp.Effects.login(effects_b, handle: handle_b, password: pass_b)

    did_a = AtMcp.Effects.session_did(effects_a)
    did_b = AtMcp.Effects.session_did(effects_b)

    if not is_binary(did_a) or not is_binary(did_b) or did_a == did_b do
      raise "expected two distinct DIDs, got A=#{inspect(did_a)} B=#{inspect(did_b)}"
    end

    IO.puts("AtMcp A DID: #{did_a}")
    IO.puts("AtMcp B DID: #{did_b}")

    live? = System.get_env("AT_MCP_LIVE_INBOUND", "0") == "1"

    inbound_opts = [name: :at_mcp_prove_inbound, enabled: true]

    inbound_opts =
      if live? do
        inbound_opts
      else
        Keyword.merge(inbound_opts,
          jetstream: AtMcp.Prove.FakeJetstream,
          jetstream_name: :at_mcp_prove_fake_js
        )
      end

    {:ok, inbound} = AtMcp.Inbound.start_link(inbound_opts)
    :ok = AtMcp.Inbound.track(inbound, did_a, %{label: :at_mcp_a})
    :ok = AtMcp.Inbound.track(inbound, did_b, %{label: :at_mcp_b})

    parent = self()

    AtMcp.Deliver.set_callback(fn
      %{matched_did: ^did_a} = e -> send(parent, {:deliver_a, e})
      %{matched_did: ^did_b} = e -> send(parent, {:deliver_b, e})
      e -> send(parent, {:deliver_other, e})
    end)

    IO.puts("\n=== Fixture prove ===")
    other = "did:plc:prove-other"

    inject_reply!(inbound, other, did_a)

    receive do
      {:deliver_a, %{inbound?: true, matched_did: ^did_a}} ->
        IO.puts("OK: reply→A delivered to AtMcp A")
    after
      1_000 -> raise "timeout deliver_a"
    end

    assert_quiet!()

    inject_mention!(inbound, other, did_b)

    receive do
      {:deliver_b, %{inbound?: true, matched_did: ^did_b}} ->
        IO.puts("OK: mention→B delivered to AtMcp B")
    after
      1_000 -> raise "timeout deliver_b"
    end

    assert_quiet!()

    :ok =
      AtMcp.Inbound.inject(inbound, %{
        type: :commit,
        did: other,
        collection: "app.bsky.feed.post",
        rkey: "noise",
        record: %{"text" => "unrelated"}
      })

    assert_quiet!()
    IO.puts("OK: unrelated delivered to nobody")

    if live? do
      IO.puts("\n=== Live listen 8s (no posts) ===")
      {a, b} = drain_live(8_000)
      IO.puts("live delivers A=#{a} B=#{b} (quiet OK — nothing public-posted)")
    else
      IO.puts("\n(skip live — set AT_MCP_LIVE_INBOUND=1 AT_MCP_JETSTREAM=0 for listen-only)")
    end

    tracked = inbound |> AtMcp.Inbound.tracked_dids() |> Enum.sort()
    IO.puts("\ntracked_dids=#{inspect(tracked)}")
    IO.puts("PASS: multi-DID Inbound fanout (A=#{handle_a}, B=#{handle_b})")
  end

  defp inject_reply!(inbound, author, target_did) do
    :ok =
      AtMcp.Inbound.inject(inbound, %{
        type: :commit,
        did: author,
        collection: "app.bsky.feed.post",
        rkey: "reply-a",
        record: %{
          "text" => "reply to A",
          "reply" => %{
            "parent" => %{"uri" => "at://#{target_did}/app.bsky.feed.post/x", "cid" => "c"},
            "root" => %{"uri" => "at://#{target_did}/app.bsky.feed.post/x", "cid" => "c"}
          }
        }
      })
  end

  defp inject_mention!(inbound, author, target_did) do
    :ok =
      AtMcp.Inbound.inject(inbound, %{
        type: :commit,
        did: author,
        collection: "app.bsky.feed.post",
        rkey: "mention-b",
        record: %{
          "text" => "hi B",
          "facets" => [
            %{
              "features" => [
                %{"$type" => "app.bsky.richtext.facet#mention", "did" => target_did}
              ]
            }
          ]
        }
      })
  end

  defp assert_quiet! do
    receive do
      {:deliver_a, msg} -> raise "unexpected deliver_a: #{inspect(msg)}"
      {:deliver_b, msg} -> raise "unexpected deliver_b: #{inspect(msg)}"
    after
      150 -> :ok
    end
  end

  defp drain_live(ms) do
    deadline = System.monotonic_time(:millisecond) + ms

    Enum.reduce_while(Stream.cycle([:t]), {0, 0}, fn _, {ca, cb} ->
      rem = deadline - System.monotonic_time(:millisecond)

      if rem <= 0 do
        {:halt, {ca, cb}}
      else
        receive do
          {:deliver_a, e} ->
            IO.puts("live A #{inspect(Map.take(e, [:kind, :author_did, :uri]))}")
            {:cont, {ca + 1, cb}}

          {:deliver_b, e} ->
            IO.puts("live B #{inspect(Map.take(e, [:kind, :author_did, :uri]))}")
            {:cont, {ca, cb + 1}}

          _ ->
            {:cont, {ca, cb}}
        after
          min(rem, 400) -> {:cont, {ca, cb}}
        end
      end
    end)
  end
end

AtMcp.Prove.MultiDid.run()
