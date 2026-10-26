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
       limit: Keyword.get(opts, :limit, 20),
       filters: Map.new(Keyword.drop(opts, [:limit, :cursor]))
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

  @impl true
  def get_feed_info(_state, uris) do
    items =
      for uri <- uris do
        "at://did:plc:mock/app.bsky.feed.generator/whats-hot"
        |> generator_page([])
        |> Map.fetch!(:items)
        |> hd()
        |> Map.merge(%{uri: uri, is_online: length(uris) == 1 || nil, is_valid: nil})
      end

    {:ok, %{count: length(items), items: items, cursor: nil, not_found: []}}
  end

  @impl true
  def get_actor_feeds(_state, actor, opts),
    do:
      {:ok,
       Map.put(generator_page("at://#{actor}/app.bsky.feed.generator/f", opts), :actor, actor)}

  @impl true
  def search_feeds(_state, query, opts),
    do:
      {:ok,
       Map.put(
         generator_page("at://did:plc:mock/app.bsky.feed.generator/cats", opts),
         :query,
         query
       )}

  @impl true
  def get_suggested_accounts(_state, suffix, opts),
    do:
      {:ok,
       "suggested.test"
       |> actor_page(opts)
       |> Map.merge(%{method: suffix, category: Keyword.get(opts, :category)})}

  @impl true
  def get_suggested_starter_packs(_state, suffix, _opts),
    do:
      {:ok,
       %{
         count: 1,
         items: [mock_pack("at://did:plc:mock/app.bsky.graph.starterpack/p1")],
         cursor: nil,
         method: suffix
       }}

  @impl true
  def get_trends(_state, suffix, _opts) do
    trend = %{
      topic: "gliders",
      display_name: "Gliders",
      description: "Glider season",
      link: "/search?q=gliders",
      started_at: "2026-10-18T00:00:00Z",
      post_count: 12,
      status: "hot",
      category: "sports",
      actors: [%{did: "did:plc:alice", handle: "alice.test", display_name: "Alice"}]
    }

    page = %{count: 1, items: [trend], cursor: nil, method: suffix}

    {:ok,
     if(suffix == "unspecced.getTrendingTopics",
       do: Map.put(page, :suggested, [trend]),
       else: page
     )}
  end

  @impl true
  def get_record(_state, uri),
    do:
      {:ok,
       %{
         uri: uri,
         cid: "bafyrecord",
         value: %{
           "$type" => "app.bsky.feed.post",
           "text" => "hi",
           "createdAt" => "2026-10-18T00:00:00Z"
         }
       }}

  @impl true
  def get_invite_codes(_state),
    do:
      {:ok,
       %{
         count: 1,
         collection: "enabled",
         items: [
           %{
             code: "town-abcde",
             available: 1,
             disabled: false,
             for_account: "did:plc:mock",
             created_by: "admin",
             created_at: "2026-10-18T00:00:00Z",
             uses: []
           }
         ]
       }}

  @mock_list "at://did:plc:mock/app.bsky.graph.list/l1"
  @mock_pack "at://did:plc:mock/app.bsky.graph.starterpack/p1"

  @impl true
  def get_list(_state, uri, opts) do
    {:ok,
     %{
       count: 1,
       items: [
         %{
           item_uri: "at://did:plc:mock/app.bsky.graph.listitem/i1",
           did: "did:plc:alice",
           handle: "alice.test",
           display_name: "Alice",
           opted_out: nil
         }
       ],
       cursor: nil,
       list: mock_list(uri),
       limit: Keyword.get(opts, :limit, 20)
     }}
  end

  @impl true
  def get_lists(_state, actor, opts) do
    {:ok,
     %{
       count: 1,
       items: [mock_list(@mock_list)],
       cursor: nil,
       actor: actor,
       purposes: Keyword.get(opts, :purposes)
     }}
  end

  @impl true
  def get_lists_with_membership(_state, actor, opts) do
    {:ok,
     %{
       count: 1,
       items: [Map.put(mock_list(@mock_list), :member_item, nil)],
       cursor: nil,
       contains: actor,
       purposes: Keyword.get(opts, :purposes)
     }}
  end

  @impl true
  def get_starter_pack(_state, uri), do: {:ok, mock_pack(uri)}

  @impl true
  def get_actor_starter_packs(_state, actor, _opts),
    do:
      {:ok,
       %{
         count: 1,
         items: [mock_pack("at://did:plc:mock/app.bsky.graph.starterpack/p1")],
         cursor: nil,
         actor: actor
       }}

  @impl true
  def search_starter_packs(_state, query, _opts),
    do:
      {:ok,
       %{
         count: 1,
         items: [mock_pack("at://did:plc:mock/app.bsky.graph.starterpack/p1")],
         cursor: nil,
         query: query
       }}

  @impl true
  def get_starter_packs_with_membership(_state, actor, _opts) do
    {:ok,
     %{
       count: 1,
       items: [Map.put(mock_pack(@mock_pack), :member_item, nil)],
       cursor: nil,
       contains: actor
     }}
  end

  # This mock reads nothing: the request it is handed is what it writes, and
  # `test/at_mcp/lists_test.exs` checks the records against a fake PDS.
  @impl true
  def prepare_list_write(_state, request), do: {:ok, request}

  @impl true
  def write_list(_state, request) do
    {action, fields} =
      case request do
        {:create_list, f} ->
          {:create_list, %{uri: @mock_list, name: f.name}}

        {:create_starter_pack, f} ->
          {:create_starter_pack, %{uri: @mock_pack, list: @mock_list, name: f.name}}

        {:add_to_list, list, did} ->
          {:add_to_list,
           %{uri: "at://did:plc:mock/app.bsky.graph.listitem/i1", list: list, actor: did}}

        {:remove_from_list, list, did} ->
          {:remove_from_list, %{list: list, actor: did}}

        {:set_list_opt_out, list, opted_out} ->
          {:set_list_opt_out, %{list: list, opted_out: opted_out}}

        {verb, uri} ->
          {verb, %{uri: uri, deleted: [uri]}}

        {verb, uri, changes} ->
          {verb, %{uri: uri, name: changes[:name]}}
      end

    {:ok, Map.merge(%{ok: true, action: action, request: inspect(request)}, fields)}
  end

  defp mock_list(uri) do
    %{
      uri: uri,
      cid: "bafyLIST",
      name: "Mock list",
      purpose: "curate",
      description: "accounts about #{uri}",
      creator: "mock.test",
      creator_did: "did:plc:mock",
      item_count: 1
    }
  end

  defp mock_pack(uri) do
    %{
      uri: uri,
      cid: "bafyPACK",
      name: "Mock pack",
      description: "a pack at #{uri}",
      list: @mock_list,
      creator: "mock.test",
      creator_did: "did:plc:mock",
      item_count: 1,
      feeds: [
        %{
          uri: "at://did:plc:mock/app.bsky.feed.generator/f",
          display_name: "F",
          creator: "mock.test"
        }
      ],
      members_sample: [%{did: "did:plc:alice", handle: "alice.test", display_name: "Alice"}]
    }
  end

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
          accepts_interactions: true,
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
    with {:ok, result} <- written_post(state, text, opts) do
      gates =
        [
          if(Keyword.has_key?(opts, :reply_rule),
            do: {:threadgate_uri, "at://did:plc:test/app.bsky.feed.threadgate/new"}
          ),
          if(Keyword.get(opts, :quotes) == :disabled,
            do: {:postgate_uri, "at://did:plc:test/app.bsky.feed.postgate/new"}
          )
        ]
        |> Enum.reject(&is_nil/1)

      {:ok, Map.merge(result, Map.new(gates))}
    end
  end

  defp written_post(state, text, opts) do
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
  def resolve_actor(_state, "did:" <> _ = did), do: {:ok, did}
  def resolve_actor(%{handle: handle, did: did}, handle), do: {:ok, did}
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
  def block(_state, actor) do
    {:ok,
     %{
       uri: "at://did:plc:test/app.bsky.graph.block/1",
       cid: "bafyBL",
       actor: actor,
       action: :block
     }}
  end

  # The mock account has no like, repost, follow or block yet, and an undo
  # deletes the one record it names.
  @impl true
  def viewer_record(_state, _action, _subject), do: {:ok, nil}

  # The mock has no AppView: it knows no subject's current CID.
  @impl true
  def subject_view(_state, _action, _subject), do: {:ok, %{record: nil, cid: nil}}

  @impl true
  def prepare_undo(_state, action, uri), do: {:ok, %{action: action, uri: uri}}

  @impl true
  def undo(_state, %{action: action, uri: uri}),
    do: {:ok, %{ok: true, uri: uri, action: action, deleted: [uri]}}

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
       pronouns: Keyword.get(updates, :pronouns),
       website: Keyword.get(updates, :website),
       labels: Keyword.get(updates, :labels),
       uri: "at://did:plc:test/app.bsky.actor.profile/self"
     }
     |> Map.merge(
       case Keyword.fetch(updates, :links) do
         {:ok, links} ->
           %{
             links:
               links
               |> Enum.with_index()
               |> Enum.map(fn {link, i} ->
                 Map.put(link, :uri, "at://did:plc:test/app.bsky.actor.link/#{i}")
               end),
             replaced_links: [],
             removed: [],
             left_behind: []
           }

         :error ->
           %{}
       end
     )}
  end

  @impl true
  def prepare_saved_feed(_state, {verb, uri, pinned}),
    do: {:ok, %{verb: verb, uri: uri, pinned: pinned}}

  # Moderation (#90): the request each tool builds comes back as its result;
  # `test/at_mcp/moderation_test.exs` checks the preferences against a fake PDS.
  @impl true
  def prepare_report(_state, request), do: {:ok, %{report: request}}

  @impl true
  def send_report(_state, %{report: request}) do
    {:ok,
     %{
       ok: true,
       action: :report,
       id: 1,
       labeler: request.labeler,
       subject: inspect(request.subject),
       reason: request.reason
     }}
  end

  @impl true
  def prepare_moderation_preference(_state, request), do: {:ok, %{moderation: request}}

  @impl true
  def prepare_list_mute(_state, {verb, uri}), do: {:ok, %{verb: verb, list: uri}}

  @impl true
  def mute_list(_state, %{verb: verb, list: list}),
    do: {:ok, %{ok: true, action: verb, list: list, muted: verb == :mute_list}}

  @impl true
  def get_moderation_lists(_state, kind, _opts),
    do: {:ok, %{count: 1, items: [mock_list(@mock_list)], cursor: nil, kind: kind}}

  @impl true
  def get_labelers(_state, dids), do: {:ok, %{count: 0, items: [], missing: dids || []}}

  @impl true
  def write_preferences(_state, %{moderation: request}) do
    action = elem(request, 0)
    {:ok, %{ok: true, action: action, request: inspect(request), unchanged: false}}
  end

  @impl true
  def write_preferences(_state, %{verb: verb, uri: uri, pinned: pinned}),
    do: {:ok, %{ok: true, action: verb, uri: uri, pinned: pinned, unchanged: false}}

  @impl true
  def get_grouped_notifications(_state, opts) do
    {:ok,
     %{
       count: 1,
       items: [
         AtMcp.Summary.extract(:notification_group, %{
           "id" => "g1",
           "kind" => "likeGroup",
           "count" => 3,
           "isRead" => false,
           "indexedAt" => "2026-10-18T00:00:00.000Z",
           "actors" => [%{"did" => "did:plc:alice", "handle" => "alice.test"}],
           "posts" => [%{"uri" => "at://did:plc:mock/app.bsky.feed.post/1", "text" => "hello"}]
         })
       ],
       cursor: nil,
       seen_at: nil,
       feed: Keyword.get(opts, :feed)
     }}
  end

  @impl true
  def get_preferences(_state) do
    {:ok,
     []
     |> AtMcp.Preferences.view()
     |> Map.merge(%{
       saved_feeds: [%{type: "timeline", value: "following", pinned: true}],
       discoverable: AtMcp.Preferences.record_view("discoverable", nil),
       activity_subscriptions: AtMcp.Preferences.record_view("activity_subscriptions", nil)
     })}
  end

  @impl true
  def prepare_preference(_state, {kind, changes}), do: {:ok, %{kind: kind, changes: changes}}

  @impl true
  def write_preference(_state, %{kind: kind, changes: changes}) do
    {:ok,
     %{
       ok: true,
       action: :set_preference,
       kind: kind,
       changed: Enum.map(Map.keys(changes), &to_string/1),
       previous: %{},
       now: changes,
       unchanged: false
     }}
  end

  @impl true
  def get_notification_settings(_state),
    do: {:ok, %{settings: AtMcp.Preferences.notification_view(%{})}}

  @impl true
  def prepare_notification_setting(_state, {reason, changes}),
    do: {:ok, %{reason: reason, changes: changes}}

  @impl true
  def write_notification_setting(_state, %{reason: reason, changes: changes}) do
    before = AtMcp.Preferences.notification_setting(%{}, reason)

    {:ok,
     %{
       ok: true,
       action: :set_notification_setting,
       reason: reason,
       changed: Enum.map(Map.keys(changes), &to_string/1),
       previous: before,
       now: Map.merge(before, changes),
       unchanged: false
     }}
  end

  @impl true
  def prepare_activity_subscription(_state, did, asked), do: {:ok, %{did: did, asked: asked}}

  @impl true
  def put_activity_subscription(_state, %{did: did, asked: asked}) do
    {:ok,
     %{
       ok: true,
       action: :subscribe_to_activity,
       actor: did,
       handle: "subject.test",
       previous: %{posts: false, replies: false},
       now: asked,
       unchanged: false
     }}
  end

  @impl true
  def get_activity_subscriptions(_state, opts), do: {:ok, actor_page("subscribed.test", opts)}

  @impl true
  def prepare_status(_state, request), do: {:ok, %{request: request}}

  @impl true
  def write_status(_state, %{request: :clear}),
    do:
      {:ok,
       %{
         ok: true,
         action: :set_status,
         status: "clear",
         uri: "at://did:plc:mock/app.bsky.actor.status/self",
         replaced: nil,
         unchanged: true
       }}

  def write_status(_state, %{request: {:live, fields}}),
    do:
      {:ok,
       %{
         ok: true,
         action: :set_status,
         status: "live",
         uri: "at://did:plc:mock/app.bsky.actor.status/self",
         url: fields.url,
         duration_minutes: fields.minutes,
         expires_at: "2026-10-18T01:00:00Z",
         replaced: nil,
         unchanged: false
       }}

  @impl true
  def prepare_feed_feedback(_state, request), do: {:ok, request}

  @impl true
  def send_feed_feedback(_state, request),
    do:
      {:ok,
       %{
         ok: true,
         action: :feed_feedback,
         uri: request.item,
         subject_uri: request.feed,
         kind: request.kind
       }}

  @impl true
  def update_seen(_state, %DateTime{} = seen_at) do
    {:ok, %{ok: true, action: :update_seen, seen_at: DateTime.to_iso8601(seen_at)}}
  end

  # A post reads as its own thread root, unless the mock's state names one.
  # Like a real service, the read answers with the DID-form address.
  @impl true
  def resolve_post(state, uri) do
    uri = did_form(state, uri)
    {:ok, %{uri: uri, cid: "bafyPOST", root: Map.get(state, :thread_root, uri)}}
  end

  @impl true
  def prepare_pin(state, uri) do
    {:ok, %{pinned: uri && did_form(state, uri), previous: Map.get(state, :pinned)}}
  end

  defp did_form(state, "at://" <> rest = uri) do
    case String.split(rest, "/", parts: 2) do
      [repo, path] ->
        {:ok, did} = resolve_actor(state, repo)
        "at://#{did}/#{path}"

      _ ->
        uri
    end
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

  # The mock reads nothing, so an edit to a post's gates names what it would
  # change and changes nothing; `AtMcp.PostGatesTest` checks the real records.
  @impl true
  def prepare_gates(_state, {:interactions, uri, _allow, _quotes}),
    do: {:ok, %{action: :set_post_interactions, uri: uri, threadgate_uri: nil, postgate_uri: nil}}

  def prepare_gates(_state, {:hide_reply, uri, hide?}),
    do:
      {:ok,
       %{
         action: if(hide?, do: :hide_reply, else: :unhide_reply),
         uri: uri,
         subject_uri: "at://did:plc:mock/app.bsky.feed.post/root",
         threadgate_uri: "at://did:plc:mock/app.bsky.feed.threadgate/root"
       }}

  def prepare_gates(_state, {:detach_quote, uri, detach?}),
    do:
      {:ok,
       %{
         action: if(detach?, do: :detach_quote, else: :reattach_quote),
         uri: uri,
         subject_uri: "at://did:plc:mock/app.bsky.feed.post/1",
         postgate_uri: "at://did:plc:mock/app.bsky.feed.postgate/1"
       }}

  @impl true
  def write_gates(_state, result), do: {:ok, Map.put(result, :ok, true)}

  @impl true
  def get_hidden_replies(_state, uri) do
    {:ok,
     [
       %{
         uri: "at://did:plc:muted/app.bsky.feed.post/hidden",
         cid: "bafyHIDDEN",
         text: "under #{uri}",
         author: "muted.test",
         reply_to: uri,
         depth: 1,
         hidden_by_threadgate: true,
         muted_by_viewer: false
       }
     ]}
  end

  # No settings and no labelers: nothing a read returns is marked.
  @impl true
  def moderation_preferences(_state), do: {:ok, []}

  @impl true
  def labeler_definitions(_state, _dids), do: {:ok, []}
end
