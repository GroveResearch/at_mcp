defmodule AtMcp.Test.MockBackend do
  @moduledoc false
  @behaviour AtMcp.Effects.Backend

  @impl true
  def login(_opts) do
    {:ok, %{mock: true, posts: [], did: "did:plc:mock"}}
  end

  @impl true
  def refresh(state) do
    if Map.get(state, :refresh_fails) do
      {:error, :refresh_failed}
    else
      {:ok, state |> Map.put(:refreshed, true) |> Map.delete(:profile_error)}
    end
  end

  @impl true
  def list_notifications(state, opts) do
    limit = Keyword.get(opts, :limit, 20)

    {:ok,
     %{
       count: 1,
       items: [
         %{
           reason: "mention",
           uri: "at://did:plc:test/app.bsky.feed.post/1",
           author: "alice.bsky.social",
           indexed_at: DateTime.to_iso8601(DateTime.utc_now()),
           is_read: false
         }
       ],
       limit: limit,
       mock: true,
       session_keys: Map.keys(state)
     }}
  end

  @impl true
  def get_membership(_state), do: {:ok, %{enabled: true, membership: nil}}

  @impl true
  def get_unread_count(_state), do: {:ok, %{count: 1}}

  @impl true
  def get_thread(_state, uri) do
    {:ok,
     %{
       uri: uri,
       cid: "bafyTHREADCID",
       text: "hello from thread SECRET_TOKEN_X",
       author: "alice.bsky.social"
     }}
  end

  @impl true
  def get_thread_chain(_state, uri, _opts) do
    {:ok,
     %{
       root_uri: "at://did:plc:mock/app.bsky.feed.post/root",
       chain: [
         %{
           uri: "at://did:plc:mock/app.bsky.feed.post/root",
           cid: "bafyROOTCID",
           text: "the first post",
           author: "alice.bsky.social",
           author_did: "did:plc:alice",
           display_name: "Alice",
           created_at: "2026-09-15T00:00:00.000Z",
           reply_to: nil,
           facets: [],
           is_self: false,
           not_found: false,
           blocked: false,
           unresolved: false
         },
         %{
           uri: uri,
           cid: "bafyTHREADCID",
           text: "hello from thread SECRET_TOKEN_X",
           author: "alice.bsky.social",
           author_did: "did:plc:alice",
           display_name: "Alice",
           created_at: "2026-09-15T00:01:00.000Z",
           reply_to: "at://did:plc:mock/app.bsky.feed.post/root",
           facets: [%{type: "mention", text: "@mock.test", did: "did:plc:mock"}],
           is_self: false,
           not_found: false,
           blocked: false,
           unresolved: false
         }
       ],
       chain_omitted: 0,
       chain_truncated: false,
       chain_before: nil,
       replies: [],
       replies_omitted: 0
     }}
  end

  @impl true
  def get_timeline(_state, opts) do
    {:ok, %{count: 0, items: [], limit: Keyword.get(opts, :limit, 20)}}
  end

  @impl true
  def get_author_feed(_state, actor, _opts) do
    {:ok, %{count: 0, items: [], actor: actor}}
  end

  @impl true
  def get_profile(state, actor) do
    case Map.get(state, :profile_error) do
      nil ->
        {:ok,
         %{
           did: "did:plc:test",
           handle: actor,
           display_name: "Mock",
           description: "mock profile",
           followers: 0,
           follows: 0,
           posts: 0
         }}

      reason ->
        {:error, reason}
    end
  end

  @impl true
  def get_profiles(_state, actors) do
    {:ok,
     %{
       count: length(actors),
       items: Enum.map(actors, fn a -> %{handle: a, did: "did:plc:#{a}"} end)
     }}
  end

  @impl true
  def get_posts(_state, uris) do
    {:ok,
     %{
       count: length(uris),
       items:
         Enum.map(uris, fn uri ->
           %{uri: uri, cid: "bafyPOST", text: "mock", author: "alice.bsky.social"}
         end)
     }}
  end

  @impl true
  def search_posts(_state, query, opts) do
    {:ok,
     %{
       count: 0,
       items: [],
       query: query,
       author: Keyword.get(opts, :author),
       mentions: Keyword.get(opts, :mentions),
       sort: Keyword.get(opts, :sort),
       since: Keyword.get(opts, :since),
       until: Keyword.get(opts, :until),
       lang: Keyword.get(opts, :lang),
       limit: Keyword.get(opts, :limit, 20)
     }}
  end

  @impl true
  def search_actors(_state, query, opts) do
    {:ok, %{count: 0, items: [], query: query, limit: Keyword.get(opts, :limit, 20)}}
  end

  @impl true
  def get_followers(_state, actor, opts), do: {:ok, actor_page(actor, opts)}

  @impl true
  def get_follows(_state, actor, opts), do: {:ok, actor_page(actor, opts)}

  @impl true
  def get_known_followers(_state, actor, opts), do: {:ok, actor_page(actor, opts)}

  @impl true
  def get_suggested_follows(_state, actor), do: {:ok, actor_page(actor, [])}

  @impl true
  def get_blocks(_state, opts), do: {:ok, actor_page("blocked.test", opts)}

  @impl true
  def get_mutes(_state, opts), do: {:ok, actor_page("muted.test", opts)}

  @impl true
  def get_relationships(_state, _actor, others) do
    {:ok,
     %{
       count: length(others),
       items:
         Enum.map(others, fn other ->
           %{
             did: "did:plc:#{other}",
             following: "at://did:plc:mock/app.bsky.graph.follow/1",
             followed_by: nil,
             not_found: false
           }
         end),
       cursor: nil
     }}
  end

  @impl true
  def get_likes(_state, _uri, opts), do: {:ok, actor_page("liker.test", opts)}

  @impl true
  def get_reposted_by(_state, _uri, opts), do: {:ok, actor_page("reposter.test", opts)}

  @impl true
  def get_quotes(_state, uri, opts), do: {:ok, post_page(uri, opts)}

  @impl true
  def get_actor_likes(_state, _actor, opts),
    do: {:ok, post_page("at://did:plc:mock/app.bsky.feed.post/liked", opts)}

  @impl true
  def get_feed(_state, feed, opts), do: {:ok, post_page(feed, opts)}

  @impl true
  def get_suggested_feeds(_state, opts) do
    {:ok, generator_page("at://did:plc:mock/app.bsky.feed.generator/whats-hot", opts)}
  end

  @impl true
  def get_list_feed(_state, list, opts), do: {:ok, post_page(list, opts)}

  defp actor_page(actor, opts) do
    %{
      count: 1,
      items: [%{did: "did:plc:#{actor}", handle: actor, display_name: "Mock"}],
      cursor: nil,
      limit: Keyword.get(opts, :limit, 20)
    }
  end

  defp post_page(subject, opts) do
    %{
      count: 1,
      items: [
        %{
          uri: "at://did:plc:mock/app.bsky.feed.post/1",
          cid: "bafyPOST",
          text: "about #{subject}",
          author: "alice.bsky.social"
        }
      ],
      cursor: nil,
      limit: Keyword.get(opts, :limit, 20)
    }
  end

  defp generator_page(uri, opts) do
    %{
      count: 1,
      items: [
        %{
          uri: uri,
          cid: "bafyGEN",
          did: "did:web:feeds.example",
          display_name: "What's hot",
          description: "suggested #{uri}",
          creator: "alice.bsky.social",
          creator_did: "did:plc:alice",
          like_count: 3,
          indexed_at: "2026-09-13T12:34:56.123Z"
        }
      ],
      cursor: nil,
      limit: Keyword.get(opts, :limit, 20)
    }
  end

  # This mock reads nothing, so it resolves nothing. What an unreadable
  # reference costs is a claim about the real backend, and
  # `AtMcp.ReplyReferenceTest` makes it against a fake PDS.
  @impl true
  def prepare_post(session, _text, opts), do: resolve_references(session, opts)

  @impl true
  def resolve_references(_state, opts), do: {:ok, opts}

  @impl true
  def post(state, text, opts \\ []) do
    case Keyword.get(opts, :reply) do
      nil ->
        {:ok,
         %{
           uri: "at://did:plc:test/app.bsky.feed.post/new",
           cid: "bafyPOST",
           text: text,
           mock: true,
           state: Map.take(state, [:mock])
         }}

      uri ->
        {:ok,
         %{
           uri: "at://did:plc:test/app.bsky.feed.post/reply",
           cid: "bafyREPLY",
           text: text,
           reply_to: uri
         }}
    end
  end

  @impl true
  def like(_state, uri, cid) do
    {:ok,
     %{
       uri: "at://did:plc:test/app.bsky.feed.like/1",
       cid: "bafyLIKE",
       subject_uri: uri,
       subject_cid: cid,
       action: :like
     }}
  end

  @impl true
  def unlike(_state, like_uri), do: {:ok, %{ok: true, uri: like_uri, action: :unlike}}

  @impl true
  def repost(_state, uri, cid) do
    {:ok,
     %{
       uri: "at://did:plc:test/app.bsky.feed.repost/1",
       cid: "bafyRP",
       subject_uri: uri,
       subject_cid: cid,
       action: :repost
     }}
  end

  @impl true
  def unrepost(_state, repost_uri), do: {:ok, %{ok: true, uri: repost_uri, action: :unrepost}}

  @impl true
  def resolve_actor(_state, "did:" <> _ = did), do: {:ok, did}
  def resolve_actor(_state, handle), do: {:ok, "did:plc:" <> handle}

  @impl true
  def follow(_state, actor) do
    {:ok,
     %{
       uri: "at://did:plc:test/app.bsky.graph.follow/1",
       cid: "bafyFL",
       actor: actor,
       action: :follow
     }}
  end

  @impl true
  def unfollow(_state, follow_uri), do: {:ok, %{ok: true, uri: follow_uri, action: :unfollow}}

  @impl true
  def block(_state, actor) do
    {:ok,
     %{
       uri: "at://did:plc:test/app.bsky.graph.block/1",
       cid: "bafyBL",
       actor: actor,
       action: :block
     }}
  end

  @impl true
  def unblock(_state, block_uri), do: {:ok, %{ok: true, uri: block_uri, action: :unblock}}

  @impl true
  def mute(_state, actor), do: {:ok, %{ok: true, actor: actor, action: :mute}}

  @impl true
  def unmute(_state, actor), do: {:ok, %{ok: true, actor: actor, action: :unmute}}

  @impl true
  def delete_post(_state, post_uri), do: {:ok, %{ok: true, uri: post_uri, action: :delete_post}}

  @impl true
  def update_profile(_state, updates) do
    {:ok,
     %{
       ok: true,
       action: :update_profile,
       display_name: Keyword.get(updates, :display_name),
       description: Keyword.get(updates, :description),
       uri: "at://did:plc:test/app.bsky.actor.profile/self"
     }}
  end

  @impl true
  def update_seen(_state, %DateTime{} = seen_at) do
    {:ok, %{ok: true, action: :update_seen, seen_at: DateTime.to_iso8601(seen_at)}}
  end

  # A post reads as its own thread root, unless the mock's state names one.
  @impl true
  def resolve_post(state, uri) do
    {:ok, %{uri: uri, cid: "bafyPOST", root: Map.get(state, :thread_root, uri)}}
  end

  @impl true
  def prepare_pin(state, uri) do
    {:ok, %{pinned: uri, previous: Map.get(state, :pinned)}}
  end

  @impl true
  def pin(_state, %{pinned: nil, previous: nil}),
    do: {:ok, %{ok: true, action: :unpin_post, uri: nil, subject_uri: nil, replaced_uri: nil}}

  def pin(_state, %{pinned: pinned, previous: previous}) do
    {:ok,
     %{
       ok: true,
       action: if(pinned, do: :pin_post, else: :unpin_post),
       uri: "at://did:plc:mock/app.bsky.actor.profile/self",
       subject_uri: pinned,
       replaced_uri: previous
     }}
  end

  @impl true
  def mute_thread(_state, root), do: {:ok, %{ok: true, action: :mute_thread, uri: root}}

  @impl true
  def unmute_thread(_state, root), do: {:ok, %{ok: true, action: :unmute_thread, uri: root}}

  @impl true
  def bookmark(_state, %{uri: uri}), do: {:ok, %{ok: true, action: :bookmark, uri: uri}}

  @impl true
  def unbookmark(_state, uri), do: {:ok, %{ok: true, action: :unbookmark, uri: uri}}

  @impl true
  def get_bookmarks(_state, opts) do
    page = post_page("a bookmark", opts)

    {:ok,
     %{
       page
       | items:
           Enum.map(page.items, &Map.put(&1, :bookmarked_at, "2026-10-18T00:00:00.000Z")) ++
             [
               %{
                 uri: "at://did:plc:gone/app.bsky.feed.post/1",
                 not_found: true,
                 blocked: false
               }
             ],
         count: 2
     }}
  end

  @impl true
  def get_drafts(_state, opts) do
    {:ok,
     %{
       count: 1,
       items: [
         %{
           id: "3mockdraft",
           created_at: "2026-10-18T00:00:00.000Z",
           updated_at: "2026-10-18T00:00:00.000Z",
           posts: [%{text: "not yet", images: []}],
           device_name: nil
         }
       ],
       cursor: nil,
       limit: Keyword.get(opts, :limit, 20)
     }}
  end

  # The mock has the one draft get_drafts lists, unless its state names others.
  @impl true
  def find_draft(state, id) do
    drafts = Map.get(state, :drafts, %{"3mockdraft" => %{"posts" => [%{"text" => "not yet"}]}})

    case Map.fetch(drafts, id) do
      {:ok, draft} -> {:ok, draft}
      :error -> {:error, {:invalid_argument, "id", "this account has no draft with id #{id}"}}
    end
  end

  @impl true
  def save_draft(_state, id, draft) do
    id = id || "3newdraft"

    {:ok,
     %{
       ok: true,
       action: :save_draft,
       id: id,
       draft: AtMcp.Summary.extract(:draft, %{"id" => id, "draft" => draft})
     }}
  end

  @impl true
  def delete_draft(_state, id, draft) do
    {:ok,
     %{
       ok: true,
       action: :delete_draft,
       id: id,
       draft: AtMcp.Summary.extract(:draft, %{"id" => id, "draft" => draft})
     }}
  end
end
