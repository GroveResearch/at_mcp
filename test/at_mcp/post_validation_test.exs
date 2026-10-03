defmodule AtMcp.PostValidationTest do
  use ExUnit.Case, async: false

  defmodule Backend do
    # References are read before the write quota is charged; nothing here
    # refers to another record.
    def prepare_post(session, _text, opts), do: resolve_references(session, opts)

    def resolve_references(_state, opts), do: {:ok, opts}

    def post(session, text, opts \\ []) do
      send(session.observer, {:backend, :post, text, Keyword.get(opts, :reply)})
      {:ok, %{text: text}}
    end
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "at_mcp-text-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    quota = start_supervised!({AtMcp.WriteQuota, name: nil, state_dir: dir, limit: 20})

    effects =
      start_supervised!(
        {AtMcp.Effects,
         backend: Backend,
         backend_state: %{did: "did:plc:text", observer: self()},
         write_quota: quota}
      )

    %{effects: effects, quota: quota}
  end

  test "invalid post and reply text never reaches backend or counts against the shared write quota",
       ctx do
    for text <- [String.duplicate("a", 301), "a" <> String.duplicate("\u0301", 1500)] do
      assert {:error, :post_text_too_long} = AtMcp.Effects.post(ctx.effects, text)
      assert {:error, :post_text_too_long} = AtMcp.Effects.reply(ctx.effects, "at://parent", text)
    end

    assert {:error, :invalid_post_text} = AtMcp.Effects.post(ctx.effects, <<255>>)
    assert {:error, :invalid_post_text} = AtMcp.Effects.reply(ctx.effects, "at://parent", <<255>>)
    refute_received {:backend, _, _, _}
    assert AtMcp.Effects.quota_status(ctx.effects).used == 0
    assert %{used: 0} = AtMcp.WriteQuota.status(ctx.quota, "did:plc:text")
  end

  test "exact grapheme and byte boundaries and empty text remain unchanged", ctx do
    texts = [String.duplicate("🪁", 300), "a" <> String.duplicate("\u0301", 1499) <> "b", ""]
    assert byte_size(Enum.at(texts, 1)) == 3000
    assert String.length(Enum.at(texts, 1)) == 2

    for text <- texts do
      assert {:ok, %{text: ^text}} = AtMcp.Effects.post(ctx.effects, text)
      assert_received {:backend, :post, ^text, nil}
      assert {:ok, %{text: ^text}} = AtMcp.Effects.reply(ctx.effects, "at://parent", text)
      assert_received {:backend, :post, ^text, "at://parent"}
    end

    assert %{used: 6} = AtMcp.WriteQuota.status(ctx.quota, "did:plc:text")
  end

  test "invalid text leaves the entire write quota for a valid write" do
    effects =
      start_supervised!(
        {AtMcp.Effects,
         backend: Backend,
         backend_state: %{did: "did:plc:validation", observer: self()},
         name: :quota_text_effects,
         write_quota: AtMcp.Test.QuotaFixture.quota(1)}
      )

    assert {:error, :post_text_too_long} = AtMcp.Effects.post(effects, String.duplicate("a", 301))
    assert AtMcp.Effects.quota_status(effects).used == 0
    assert {:ok, _} = AtMcp.Effects.post(effects, "valid")
    assert AtMcp.Effects.quota_status(effects).used == 1
    assert {:error, {:write_quota_exhausted, _}} = AtMcp.Effects.post(effects, "over quota")
  end
end
