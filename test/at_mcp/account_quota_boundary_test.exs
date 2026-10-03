defmodule AtMcp.AccountQuotaBoundaryTest do
  use ExUnit.Case, async: false
  @moduletag :tmp_dir

  defmodule Backend do
    # References are read before the write quota is charged; nothing here
    # refers to another record.
    def prepare_post(session, _text, opts), do: resolve_references(session, opts)

    def resolve_references(_state, opts), do: {:ok, opts}

    def post(state, _text, _opts) do
      Agent.update(state.calls, &(&1 + 1))
      {:ok, %{uri: "at://did:plc:quota-boundary/app.bsky.feed.post/fixture"}}
    end
  end

  test "configured account clients cannot exceed or reset their shared quota", %{tmp_dir: root} do
    path = Path.join(root, "accounts.json")

    File.write!(
      path,
      Jason.encode!(%{
        version: 1,
        accounts: [
          %{
            id: "quota-boundary",
            did: "did:plc:quota-boundary",
            handle: "fixture.example",
            password: "fixture-only",
            service: "https://example.invalid"
          }
        ]
      })
    )

    File.chmod!(path, 0o600)
    {:ok, [spec]} = AtMcp.Identities.named_identity_specs(path)
    refute Keyword.has_key?(spec, :host_token)
    calls = start_supervised!({Agent, fn -> 0 end})
    quota = AtMcp.Test.QuotaFixture.quota(2)

    {:ok, _} =
      AtMcp.Identities.start_identity(
        Keyword.merge(spec,
          listen_enabled: false,
          backend: Backend,
          write_quota: quota,
          backend_state: %{did: "did:plc:quota-boundary", calls: calls}
        )
      )

    on_exit(fn -> AtMcp.Identities.stop_identity("quota-boundary") end)
    effects = AtMcp.Identity.effects_name("quota-boundary")

    {:ok, sibling} =
      AtMcp.Effects.start_link(
        backend: Backend,
        write_quota: quota,
        backend_state: %{did: "did:plc:quota-boundary", calls: calls}
      )

    assert {:ok, _} = AtMcp.Effects.post(effects, "first client")
    assert {:ok, _} = AtMcp.Effects.post(sibling, "second client")

    assert {:error, {:write_quota_exhausted, _}} =
             AtMcp.Effects.post(effects, "must never dispatch")

    assert Agent.get(calls, & &1) == 2
    assert %{used: 2} = AtMcp.Effects.quota_status(sibling)
    refute function_exported?(AtMcp.Effects, :begin_turn, 1)
    refute function_exported?(AtMcp.Effects, :reset_turn_budget, 1)
    {client, token} = AtMcp.Test.Grant.client("quota-boundary")
    {:ok, catalog} = ExMCP.Client.list_tools(client)
    tools = if is_map(catalog), do: catalog["tools"] || catalog[:tools], else: catalog
    seen = Enum.find(tools, fn tool -> (tool["name"] || tool[:name]) == "update_seen" end)
    annotations = seen["annotations"] || seen[:annotations]
    assert annotations["kite/publicWrite"] == false
    assert annotations["readOnlyHint"] == false

    response =
      Req.post!(String.replace_suffix(AtMcp.Test.Grant.url(), "/mcp", "/turns"),
        headers: AtMcp.Test.Grant.headers(token),
        json: %{},
        retry: false
      )

    assert response.status == 400
    refute Map.has_key?(response.body, "turn_id")
    assert Agent.get(calls, & &1) == 2
    assert Process.alive?(client)
  end

  test "embedding default is account quota and nil cannot disable it" do
    {:ok, effects} = AtMcp.Effects.start_link(backend_state: %{did: "did:plc:embedding-default"})
    assert AtMcp.Effects.write_quota(effects) == AtMcp.WriteQuota

    assert_raise ArgumentError, ~r/write_quota/, fn ->
      AtMcp.Effects.start_link(write_quota: nil)
    end
  end
end
