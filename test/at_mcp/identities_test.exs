defmodule AtMcp.IdentitiesTest do
  use ExUnit.Case, async: false

  setup do
    unless Process.whereis(AtMcp.Listen.Registry) do
      {:ok, _} = Registry.start_link(keys: :duplicate, name: AtMcp.Listen.Registry)
    end

    unless Process.whereis(AtMcp.Identity.Registry) do
      {:ok, _} = Registry.start_link(keys: :unique, name: AtMcp.Identity.Registry)
    end

    unless Process.whereis(AtMcp.Identities) do
      {:ok, _} = AtMcp.Identities.start_link([])
    end

    on_exit(fn ->
      for id <- ["alice", "bob", "solo", "eager", "eager2"] do
        _ = AtMcp.Identities.stop_identity(id)
      end

      AtMcp.Deliver.clear_callback()
      AtMcp.Deliver.clear_callback(:all)
    end)

    :ok
  end

  test "N identities supervised with distinct Effects; both Inbound.track" do
    inbound_name = :"id_inbound_#{System.unique_integer([:positive])}"
    js_name = :"id_js_#{System.unique_integer([:positive])}"

    {:ok, inbound} =
      AtMcp.Inbound.start_link(
        name: inbound_name,
        enabled: true,
        stream: AtMcp.Test.FakeStream,
        stream_name: js_name
      )

    # Temporarily point Identity Listen at our inbound via manual track after start.
    # Identity boots Listen against AtMcp.Inbound (app); we prove Effects+supervisor
    # and call Inbound.track on the test inbound with each session DID.
    assert {:ok, _} =
             AtMcp.Identities.start_identity(
               id: "alice",
               notifications_enabled: false,
               backend: AtMcp.Test.MockBackend,
               backend_state: %{did: "did:plc:alice", mock: true},
               effects_name: :"effects_alice_#{System.unique_integer([:positive])}",
               did_poll_ms: 50
             )

    assert {:ok, _} =
             AtMcp.Identities.start_identity(
               id: "bob",
               notifications_enabled: false,
               backend: AtMcp.Test.MockBackend,
               backend_state: %{did: "did:plc:bob", mock: true},
               effects_name: :"effects_bob_#{System.unique_integer([:positive])}",
               did_poll_ms: 50
             )

    assert "alice" in AtMcp.Identities.list_ids()
    assert "bob" in AtMcp.Identities.list_ids()

    effects_a = AtMcp.Identity.effects_name("alice")
    effects_b = AtMcp.Identity.effects_name("bob")
    assert is_atom(effects_a) or is_pid(effects_a) or match?({:via, _, _}, effects_a)
    assert effects_a != effects_b
    assert AtMcp.Effects.session_did(effects_a) == "did:plc:alice"
    assert AtMcp.Effects.session_did(effects_b) == "did:plc:bob"
    # Distinct sessions: identities never share a login.
    assert AtMcp.Effects.login_count(effects_a) == 1
    assert AtMcp.Effects.login_count(effects_b) == 1

    assert :ok = AtMcp.Inbound.track(inbound, "did:plc:alice", %{id: "alice"})
    assert :ok = AtMcp.Inbound.track(inbound, "did:plc:bob", %{id: "bob"})
    tracked = AtMcp.Inbound.tracked_dids(inbound)
    assert "did:plc:alice" in tracked
    assert "did:plc:bob" in tracked
  end

  test "per-DID Deliver routes only to matching identity callback" do
    inbound_name = :"deliver_inbound_#{System.unique_integer([:positive])}"
    js_name = :"deliver_js_#{System.unique_integer([:positive])}"

    {:ok, inbound} =
      AtMcp.Inbound.start_link(
        name: inbound_name,
        enabled: true,
        stream: AtMcp.Test.FakeStream,
        stream_name: js_name
      )

    alice = "did:plc:deliver-alice"
    bob = "did:plc:deliver-bob"
    parent = self()

    AtMcp.Deliver.set_callback(alice, fn e -> send(parent, {:alice, e}) end)
    AtMcp.Deliver.set_callback(bob, fn e -> send(parent, {:bob, e}) end)

    assert :ok = AtMcp.Inbound.track(inbound, alice)
    assert :ok = AtMcp.Inbound.track(inbound, bob)

    :ok =
      AtMcp.Inbound.inject(inbound, %{
        type: :commit,
        did: "did:plc:other",
        collection: "app.bsky.feed.post",
        rkey: "r1",
        record: %{
          "text" => "hi",
          "reply" => %{
            "parent" => %{"uri" => "at://#{alice}/app.bsky.feed.post/p", "cid" => "c"},
            "root" => %{"uri" => "at://#{alice}/app.bsky.feed.post/p", "cid" => "c"}
          }
        }
      })

    assert_receive {:alice, %{matched_did: ^alice, inbound?: true}}, 500
    refute_receive {:bob, _}, 200
  end

  test "Identity start with credentials tracks Inbound without a tool call" do
    inbound_name = :"eager_inbound_#{System.unique_integer([:positive])}"
    js_name = :"eager_js_#{System.unique_integer([:positive])}"

    {:ok, inbound} =
      AtMcp.Inbound.start_link(
        name: inbound_name,
        enabled: true,
        stream: AtMcp.Test.FakeStream,
        stream_name: js_name
      )

    effects_name = :"effects_eager_#{System.unique_integer([:positive])}"

    assert {:ok, _} =
             AtMcp.Identities.start_identity(
               id: "eager",
               handle: "eager.bsky.social",
               password: "app-password-xxxx",
               notifications_enabled: false,
               backend: AtMcp.Test.MockBackend,
               effects_name: effects_name,
               did_poll_ms: 50,
               listen_enabled: true,
               inbound: inbound
             )

    # An identity logs in at boot, without waiting for a tool call.
    assert AtMcp.Effects.logged_in?(effects_name)
    assert AtMcp.Effects.session_did(effects_name) == "did:plc:mock"
    assert AtMcp.Effects.login_count(effects_name) >= 1

    # Listen tracks the DID without waiting for a tool login.
    assert wait_tracked(inbound, "did:plc:mock", 2_000)
    assert "did:plc:mock" in AtMcp.Inbound.tracked_dids(inbound)
  end

  test "second identity with credentials also tracks Inbound without a tool call" do
    inbound_name = :"eager2_inbound_#{System.unique_integer([:positive])}"
    js_name = :"eager2_js_#{System.unique_integer([:positive])}"

    {:ok, inbound} =
      AtMcp.Inbound.start_link(
        name: inbound_name,
        enabled: true,
        stream: AtMcp.Test.FakeStream,
        stream_name: js_name
      )

    effects_name = :"effects_eager2_#{System.unique_integer([:positive])}"

    assert {:ok, _} =
             AtMcp.Identities.start_identity(
               id: "eager2",
               handle: "eager2.bsky.social",
               password: "app-password-yyyy",
               notifications_enabled: false,
               backend: AtMcp.Test.MockBackend,
               effects_name: effects_name,
               did_poll_ms: 50,
               listen_enabled: true,
               inbound: inbound
             )

    assert AtMcp.Effects.logged_in?(effects_name)
    assert wait_tracked(inbound, "did:plc:mock", 2_000)
  end

  defp wait_tracked(inbound, did, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    Stream.repeatedly(fn ->
      if did in AtMcp.Inbound.tracked_dids(inbound) do
        true
      else
        Process.sleep(25)
        false
      end
    end)
    |> Enum.find(fn ok -> ok or System.monotonic_time(:millisecond) >= deadline end)
    |> case do
      true -> true
      _ -> flunk("DID #{did} not tracked on Inbound within #{timeout_ms}ms")
    end
  end
end
