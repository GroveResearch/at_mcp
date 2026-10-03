defmodule AtMcp.FalsifyClaimsTest do
  @moduledoc """
  Matklad-style adversarial probes for at_mcp design claims.
  Prefer failing assertions that expose lies over narrative.
  """
  use ExUnit.Case, async: false

  # --- Claim 1: Single login ---
  test "claim1: two Effects verbs without re-login keep login_count at 1" do
    {:ok, effects} =
      AtMcp.Test.QuotaFixture.start_effects(backend: AtMcp.Test.MockBackend, quota_limit: 5)

    assert {:ok, %{login_count: 1}} = AtMcp.Effects.login(effects)
    assert {:ok, _} = AtMcp.Effects.get_profile(effects, "alice.bsky.social")
    assert {:ok, _} = AtMcp.Effects.get_timeline(effects)
    assert AtMcp.Effects.login_count(effects) == 1
  end

  # --- Claim 2: Write rail ---
  test "claim2: account quota limit=1 refuses the second publishing write" do
    {:ok, effects} =
      AtMcp.Test.QuotaFixture.start_effects(backend: AtMcp.Test.MockBackend, quota_limit: 1)

    assert {:ok, _} = AtMcp.Effects.login(effects)
    assert {:ok, _} = AtMcp.Effects.post(effects, "first")
    assert {:error, {:write_quota_exhausted, _}} = AtMcp.Effects.post(effects, "second")
    assert {:error, {:write_quota_exhausted, _}} = AtMcp.Effects.repost(effects, "at://u", "cid")
    # Only publishing counts against the write quota.
    assert {:ok, _} = AtMcp.Effects.like(effects, "at://u", "cid")
    assert {:ok, _} = AtMcp.Effects.update_seen(effects)
  end

  # --- The opt-in stream matches recipients locally; no wanted_dids-as-inbox ---
  test "the optional stream matches recipients and notifications collect account activity" do
    lib = Path.join(File.cwd!(), "lib")

    inbound_src = File.read!(Path.join(lib, "at_mcp/inbound.ex"))
    assert File.read!("lib/at_mcp/stream/jetstream.ex") =~ "wanted_dids: []"
    assert inbound_src =~ "AtMcp.Inbound.Match"
    refute inbound_src =~ ~r/wanted_dids:\s*\[did\]/
    refute inbound_src =~ ~r/wanted_dids:\s*\[session/

    match_src = File.read!(Path.join(lib, "at_mcp/inbound/match.ex"))
    assert match_src =~ ":mention"
    assert match_src =~ ":reply"
    assert match_src =~ ":quote"

    listen_src = File.read!(Path.join(lib, "at_mcp/listen.ex"))
    assert listen_src =~ "Inbound.track" or listen_src =~ "do_track"
    refute listen_src =~ ~r/wanted_dids:\s*\[did\]/

    notif_src = File.read!(Path.join(lib, "at_mcp/notifications.ex"))
    assert notif_src =~ "list_notifications"

    design = File.read!(Path.join(File.cwd!(), "docs/DESIGN.md"))
    assert design =~ "Inbound"
    assert design =~ "empty" or design =~ "**empty**"
    refute design =~ ~r/wanted_dids: \[session_did\].*inbox/s
    # No document may claim that wanted_dids is the mention inbox.
    refute design =~ ~r/wanted_dids:\s*\[session_did\].*mention/is
    assert design =~ "cannot be the inbox" or design =~ "empty"

    # The public MCP surface does not expose reset_turn_budget.
    mcp_src = File.read!(Path.join(lib, "at_mcp/mcp/server.ex"))
    refute mcp_src =~ ~r/tool "reset_turn_budget"/

    mute_chunk = mcp_src |> String.split(~s(tool "mute")) |> Enum.at(1) |> String.slice(0, 180)
    block_chunk = mcp_src |> String.split(~s(tool "block")) |> Enum.at(1) |> String.slice(0, 180)
    assert mute_chunk =~ "destructiveHint: true"
    assert block_chunk =~ "destructiveHint: true"
  end

  # --- Claim 6: Inbound starts jetstream with empty wanted_dids ---
  test "claim6 unit: Inbound starts its stream adapter with the matched collections" do
    parent = self()
    :persistent_term.put(:at_mcp_falsify_js_parent, parent)

    on_exit(fn ->
      :persistent_term.erase(:at_mcp_falsify_js_parent)
      AtMcp.Deliver.clear_callback()

      if pid = Process.whereis(AtMcp.Test.FakeStream) do
        try do
          Agent.stop(pid)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    name = :"falsify_inbound_#{System.unique_integer([:positive])}"
    js_name = :"falsify_js_#{System.unique_integer([:positive])}"

    {:ok, inbound} =
      AtMcp.Inbound.start_link(
        name: name,
        enabled: true,
        stream: AtMcp.Test.FakeStream,
        stream_name: js_name
      )

    assert :ok = AtMcp.Inbound.track(inbound, "did:plc:falsify")
    assert_receive {:js_opts, opts}, 1_000
    assert opts[:collections] != []
    assert is_list(opts[:collections])
    assert is_pid(opts[:handler])
  end

  test "claim: inbound reply wakes AtMcp without notification poll" do
    unless Process.whereis(AtMcp.Listen.Registry) do
      {:ok, _} = Registry.start_link(keys: :duplicate, name: AtMcp.Listen.Registry)
    end

    parent = self()
    AtMcp.Deliver.set_callback(fn event -> send(parent, {:deliver, event}) end)
    on_exit(fn -> AtMcp.Deliver.clear_callback() end)

    name = :"falsify_deliver_#{System.unique_integer([:positive])}"
    js_name = :"falsify_deliver_js_#{System.unique_integer([:positive])}"

    {:ok, inbound} =
      AtMcp.Inbound.start_link(
        name: name,
        enabled: true,
        stream: AtMcp.Test.FakeStream,
        stream_name: js_name
      )

    us = "did:plc:deliver-us"
    assert :ok = AtMcp.Inbound.track(inbound, us)

    :ok =
      AtMcp.Inbound.inject(inbound, %{
        type: :commit,
        did: "did:plc:other",
        collection: "app.bsky.feed.post",
        rkey: "r1",
        record: %{
          "text" => "hey",
          "reply" => %{
            "parent" => %{"uri" => "at://#{us}/app.bsky.feed.post/p", "cid" => "c"},
            "root" => %{"uri" => "at://#{us}/app.bsky.feed.post/p", "cid" => "c"}
          }
        }
      })

    assert_receive {:deliver, %{source: :inbound, inbound?: true, kind: :inbound_reply}}, 500
  end

  # --- Claim 9: Refresh ownership / sole session holder ---
  test "claim9: Effects is sole session holder; MCP handlers have no second login path" do
    mcp_server = File.read!(Path.join(File.cwd!(), "lib/at_mcp/mcp/server.ex"))
    mcp_tools = File.read!(Path.join(File.cwd!(), "lib/at_mcp/mcp/tools.ex"))

    refute mcp_server =~ ~r/ProtoRune\.login/
    refute mcp_tools =~ ~r/ProtoRune\.login/
    refute mcp_tools =~ ~r/Effects\.login\(/
    refute mcp_server =~ ~r/Effects\.login\(/
    refute mcp_server =~ ~r/backend\.login\(/
    refute mcp_tools =~ ~r/backend\.login\(/

    effects_src = File.read!(Path.join(File.cwd!(), "lib/at_mcp/effects.ex"))
    assert effects_src =~ "defp ready_session"
    assert effects_src =~ "def login("

    {:ok, effects} =
      AtMcp.Test.QuotaFixture.start_effects(backend: AtMcp.Test.MockBackend, quota_limit: 3)

    assert {:ok, _} = AtMcp.Effects.login(effects)
    assert {:ok, _} = AtMcp.Effects.get_profile(effects, "a")
    assert {:ok, _} = AtMcp.Effects.post(effects, "x")
    assert AtMcp.Effects.login_count(effects) == 1
  end

  test "claim: like/repost Match reasons are not :reply" do
    match_src = File.read!(Path.join(File.cwd!(), "lib/at_mcp/inbound/match.ex"))
    assert match_src =~ "match_subject(hits, record, tracked, :like)"
    assert match_src =~ "match_subject(hits, record, tracked, :repost)"

    inbound_src = File.read!(Path.join(File.cwd!(), "lib/at_mcp/inbound.ex"))
    assert inbound_src =~ ":inbound_like"
    assert inbound_src =~ ":inbound_repost"

    us = "did:plc:falsify-like"

    like = %{
      type: :commit,
      did: "did:plc:other",
      collection: "app.bsky.feed.like",
      record: %{"subject" => %{"uri" => "at://" <> us <> "/app.bsky.feed.post/p", "cid" => "c"}}
    }

    assert [{^us, [:like]}] = AtMcp.Inbound.Match.match_dids(like, [us])
  end

  test "claim: N-identity OTP — Identities DynamicSupervisor exists; no communal Effects" do
    app_src = File.read!(Path.join(File.cwd!(), "lib/at_mcp/application.ex"))
    assert app_src =~ "AtMcp.Identities"
    assert app_src =~ "AtMcp.Identity.Registry"
    refute app_src =~ "{AtMcp.Effects,"

    id_src = File.read!(Path.join(File.cwd!(), "lib/at_mcp/identities.ex"))
    assert id_src =~ "DynamicSupervisor"

    design = File.read!(Path.join(File.cwd!(), "docs/DESIGN.md"))
    assert design =~ "Identities" or design =~ "DynamicSupervisor"
  end

  test "claim: Deliver prefers per-DID callback over global" do
    parent = self()
    AtMcp.Deliver.clear_callback()
    AtMcp.Deliver.clear_callback(:all)

    on_exit(fn ->
      AtMcp.Deliver.clear_callback()
      AtMcp.Deliver.clear_callback(:all)
    end)

    did = "did:plc:per-did"
    AtMcp.Deliver.set_callback(fn _ -> send(parent, :global) end)
    AtMcp.Deliver.set_callback(did, fn _ -> send(parent, :per_did) end)

    assert :ok = AtMcp.Deliver.deliver(%{matched_did: did, source: :inbound})
    assert_receive :per_did, 200
    refute_receive :global, 100
  end
end
