defmodule AtMcp.DraftsTest do
  @moduledoc """
  Drafts (#88): `get_drafts`, `save_draft` and `delete_draft`.

  Over the mock backend, through the MCP surface: what is refused before
  anything is sent, naming the argument. Against a fake PDS with the real
  backend: what reaches the wire, that a save to an existing draft keeps every
  part of it but the first post's text, and that each procedure's input
  matches its lexicon.
  """
  use ExUnit.Case, async: false

  alias AtMcp.Test.FakePDS
  alias AtMcp.Test.Lexicon

  defp call(state, name, arguments) do
    {:ok, result, ^state} = AtMcp.MCP.Server.handle_call_tool(name, arguments, state)
    result
  end

  describe "through the tools, over the mock backend" do
    setup do
      {:ok, effects} =
        AtMcp.Test.QuotaFixture.start_effects(
          backend: AtMcp.Test.MockBackend,
          backend_state: %{mock: true, did: "did:plc:mock"}
        )

      %{state: %{effects: effects}, effects: effects}
    end

    test "a draft longer than the lexicon allows is refused, naming text", %{state: state} do
      %{graphemes: graphemes} = AtMcp.Effects.draft_text_limits()
      result = call(state, "save_draft", %{"text" => String.duplicate("a", graphemes + 1)})

      assert result.isError
      assert %{code: "invalid_arguments", problems: [%{path: "text"}]} = result.structuredContent

      # Longer than a post may be, and still a draft.
      refute call(state, "save_draft", %{"text" => String.duplicate("a", graphemes)})[:isError]
    end

    test "an id this account has no draft for is refused, naming id", %{state: state} do
      for name <- ["save_draft", "delete_draft"] do
        result = call(state, name, %{"id" => "3nosuch", "text" => "x"})
        assert result.isError
        assert %{code: "invalid_arguments", problems: [%{path: "id"}]} = result.structuredContent
        assert hd(result.content).text =~ "no draft with id 3nosuch"
      end
    end

    test "an empty id is a new draft", %{state: state} do
      result = call(state, "save_draft", %{"text" => "new", "id" => ""})
      assert %{"action" => "save_draft", "id" => "3newdraft"} = result.structuredContent
    end

    test "delete_draft returns the draft it deleted", %{state: state} do
      result = call(state, "delete_draft", %{"id" => "3mockdraft"})

      assert %{"id" => "3mockdraft", "draft" => %{"posts" => [%{"text" => "not yet"}]}} =
               result.structuredContent
    end
  end

  describe "on the wire" do
    setup context do
      Application.put_env(:at_mcp, :network, context[:network] || :bluesky)
      on_exit(fn -> Application.delete_env(:at_mcp, :network) end)
      :ok
    end

    defp pds(answers, drafts \\ [], opts \\ []) do
      {session, pds} = FakePDS.start([answers: answers, drafts: drafts] ++ opts)

      effects =
        start_supervised!(
          {AtMcp.Effects,
           backend: AtMcp.Effects.ProtoRune,
           backend_state: session,
           write_quota: AtMcp.Test.QuotaFixture.quota(10)},
          id: make_ref()
        )

      %{effects: effects, pds: pds}
    end

    # A thread draft as the app saves one: two posts, an image on the first
    # (a file on the device that wrote it), languages and reply settings.
    @held %{
      "posts" => [
        %{
          "text" => "first, before",
          "embedImages" => [%{"localRef" => %{"path" => "/photos/1.jpg"}, "alt" => "a kite"}]
        },
        %{"text" => "second"}
      ],
      "langs" => ["en"],
      "deviceName" => "phone",
      "threadgateAllow" => [%{"$type" => "app.bsky.feed.threadgate#mentionRule"}]
    }

    defp drafts(drafts, cursor \\ nil) do
      {200, Map.reject(%{drafts: drafts, cursor: cursor}, fn {_, v} -> is_nil(v) end)}
    end

    defp view(id, draft),
      do: %{
        id: id,
        draft: draft,
        createdAt: "2026-10-01T00:00:00.000Z",
        updatedAt: "2026-10-02T00:00:00.000Z"
      }

    test "a new draft is one post with the text" do
      %{effects: effects, pds: pds} = pds(%{"app.bsky.draft.createDraft" => {200, %{id: "3new"}}})

      assert {:ok, %{action: :save_draft, id: "3new", draft: %{posts: [%{text: "later"}]}}} =
               AtMcp.Effects.save_draft(effects, "later")

      [create] = FakePDS.sent(pds, "app.bsky.draft.createDraft")
      assert create.body == %{"draft" => %{"posts" => [%{"text" => "later"}]}}
      assert Lexicon.problems(create.body, "app.bsky.draft.createDraft") == []
    end

    test "saving to an existing draft replaces its first post's text and keeps the rest" do
      %{effects: effects, pds: pds} =
        pds(%{}, [view("3other", %{"posts" => []}), view("3held", @held)])

      assert {:ok, %{id: "3held", draft: draft}} =
               AtMcp.Effects.save_draft(effects, "first, after", "3held")

      # The draft is read again after the update, to check it still exists.
      assert length(FakePDS.sent(pds, "app.bsky.draft.getDrafts")) == 2

      assert [%{text: "first, after", images: [%{alt: "a kite"}]}, %{text: "second"}] =
               draft.posts

      [update] = FakePDS.sent(pds, "app.bsky.draft.updateDraft")

      assert update.body == %{
               "draft" => %{
                 "id" => "3held",
                 "draft" => put_in(@held, ["posts", Access.at(0), "text"], "first, after")
               }
             }

      assert Lexicon.problems(update.body, "app.bsky.draft.updateDraft") == []
    end

    # The service queues an update and applies it later, so getDrafts can
    # still show the old text; the result is the draft as sent.
    test "a saved draft is reported as sent while the service has not applied it yet" do
      %{effects: effects} = pds(%{}, [view("3held", @held)], drafts_lag: true)

      assert {:ok, %{id: "3held", draft: %{posts: [%{text: "first, after"} | _]}}} =
               AtMcp.Effects.save_draft(effects, "first, after", "3held")
    end

    # updateDraft ignores an id it does not hold and answers success anyway.
    test "a draft deleted between the read and the update is reported unsaved" do
      %{effects: effects, pds: pds} =
        pds(%{
          "app.bsky.draft.getDrafts" => [drafts([view("3held", @held)]), drafts([])]
        })

      state = %{effects: effects}

      {:ok, result, ^state} =
        AtMcp.MCP.Server.handle_call_tool(
          "save_draft",
          %{"text" => "first, after", "id" => "3held"},
          state
        )

      assert result.isError
      assert %{code: "draft_not_found", id: "3held"} = result.structuredContent
      assert hd(result.content).text =~ "nothing was saved"
      assert [_] = FakePDS.sent(pds, "app.bsky.draft.updateDraft")
    end

    test "a draft the account does not have is refused, and nothing is updated" do
      %{effects: effects, pds: pds} =
        pds(%{"app.bsky.draft.getDrafts" => drafts([view("3other", @held)])})

      assert {:error, {:invalid_argument, "id", _}} =
               AtMcp.Effects.save_draft(effects, "x", "3nosuch")

      assert {:error, {:invalid_argument, "id", _}} =
               AtMcp.Effects.delete_draft(effects, "3nosuch")

      assert FakePDS.sent(pds, "app.bsky.draft.updateDraft") == []
      assert FakePDS.sent(pds, "app.bsky.draft.deleteDraft") == []
    end

    test "delete_draft sends the id and returns what it deleted" do
      %{effects: effects, pds: pds} =
        pds(%{"app.bsky.draft.getDrafts" => drafts([view("3held", @held)])})

      assert {:ok, %{action: :delete_draft, id: "3held", draft: %{posts: [first, _]}}} =
               AtMcp.Effects.delete_draft(effects, "3held")

      assert first.text == "first, before"
      [delete] = FakePDS.sent(pds, "app.bsky.draft.deleteDraft")
      assert delete.body == %{"id" => "3held"}
      assert Lexicon.problems(delete.body, "app.bsky.draft.deleteDraft") == []
    end

    test "get_drafts reads each draft's posts" do
      %{effects: effects} =
        pds(%{"app.bsky.draft.getDrafts" => drafts([view("3held", @held)], "c2")})

      assert {:ok, %{count: 1, cursor: "c2", items: [item]}} = AtMcp.Effects.get_drafts(effects)

      assert %{
               id: "3held",
               updated_at: "2026-10-02T00:00:00.000Z",
               device_name: "phone",
               posts: [%{text: "first, before"}, %{text: "second"}]
             } = item
    end

    @tag network: :delve
    test "on delve.town the methods are its own, and a 501 is reported as not implemented" do
      %{effects: effects, pds: pds} =
        pds(%{
          "town.delve.draft.createDraft" =>
            {501, %{error: "MethodNotImplemented", message: "Method Not Implemented"}}
        })

      state = %{effects: effects}
      result = call(state, "save_draft", %{"text" => "later"})

      assert FakePDS.methods(pds) == ["town.delve.draft.createDraft"]
      assert result.structuredContent.code == "upstream_not_implemented"
      refute Map.has_key?(result.structuredContent, :outcome)
    end
  end
end
