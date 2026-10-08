defmodule AtMcp.Effects.ProtoRune do
  @moduledoc """
  The real network backend: one `ProtoRune.login/2`, then reuse that session.
  Returns structured summary maps — never session inspect dumps.

  Reads and writes both go through `AtMcp.ATProto`, so every method name, and
  every record's collection and `$type`, derive from `AtMcp.Network`.
  `ProtoRune.Bsky` is not called: it compiles `app.bsky.*` into method names and
  records, and validates records through Peri schemas that drop keys they do not
  declare.

  What this module owns about a write is the part that is not the record:
  resolving an actor to a DID, reading a parent post to build a reply's strong
  references, and turning a result into a summary or one of AtMcp's failure
  kinds.
  """

  @behaviour AtMcp.Effects.Backend

  @impl true
  def requires_credentials?, do: true

  @impl true
  def login(opts) do
    handle = Keyword.fetch!(opts, :handle)
    password = Keyword.fetch!(opts, :password)

    case ProtoRune.login(handle, password, Keyword.take(opts, [:service])) do
      {:ok, session} -> {:ok, session}
      {:error, reason} -> {:error, failure(reason)}
    end
  end

  @impl true
  def refresh(session) do
    # Hex proto_rune 0.5.3 POSTs `json: %{}` for refreshSession; Bluesky
    # replies 400 "A request body was provided when none was expected".
    # Empty-body POST with the refresh JWT, then parse like login.
    refresh_jwt = Map.get(session, :refresh_jwt)

    if not is_binary(refresh_jwt) or refresh_jwt == "" do
      {:error, AtMcp.Effects.Failure.new(:auth_refused, detail: :missing_refresh_jwt)}
    else
      base_url =
        Map.get(session, :service_url) || ProtoRune.XRPC.Config.default_base_url()

      url = Path.join(base_url, "com.atproto.server.refreshSession")

      case ProtoRune.HTTPClient.request(:post, url,
             headers: [{"authorization", "Bearer #{refresh_jwt}"}]
           ) do
        {:ok, %{status: status, body: body}} when status in [200, 201] ->
          data = body |> decode_json_body() |> ProtoRune.Case.snakelize_enum()

          {:ok, fresh} = ProtoRune.Atproto.Session.parse(data)
          service_url = Map.get(fresh, :service_url) || Map.get(session, :service_url)
          {:ok, Map.put(fresh, :service_url, service_url)}

        {:ok, %{status: status, body: body} = resp} when status >= 400 ->
          decoded = decode_json_body(body)

          {:error, failure(ProtoRune.XRPC.Error.from(%{resp | body: decoded}))}

        {:error, reason} ->
          {:error, failure(reason)}
      end
    end
  end

  @impl true
  def get_membership(session) do
    if AtMcp.Network.name() == :delve do
      case AtMcp.ATProto.get_membership(session, %{}) do
        {:ok, response} when is_map(response) ->
          summary = AtMcp.Summary.extract(:membership, response)
          member = summary.membership

          valid_member =
            is_nil(member) or
              (Enum.all?(Map.values(member), &(not is_nil(&1))) and
                 member.status in ["active", "withdrawn"] and member.did == session.did)

          if is_boolean(summary.enabled) and valid_member and
               (is_nil(AtMcp.Response.dig(response, ["membership"])) or is_map(member)),
             do: {:ok, summary},
             else: {:error, unreadable("membership status", response)}

        {:ok, response} ->
          {:error, unreadable("membership status", response)}

        {:error, reason} ->
          {:error, failure(reason)}
      end
    else
      {:error,
       AtMcp.Effects.Failure.new(:refused,
         detail: :membership_not_supported
       )}
    end
  end

  @impl true
  def list_notifications(session, opts) do
    pr_opts =
      opts
      |> Keyword.take([:limit, :cursor, :reasons])
      |> Keyword.put_new(:limit, 20)

    case AtMcp.ATProto.list_notifications(session, AtMcp.ATProto.params(Map.new(pr_opts))) do
      {:ok, notifs} -> page(notifs, :notifications, &notif_item/1)
      {:error, reason} -> {:error, failure(reason)}
    end
  end

  @impl true
  def get_unread_count(session) do
    case AtMcp.ATProto.get_unread_count(session, %{}) do
      {:ok, response} when is_map(response) ->
        case AtMcp.Response.fetch(response, :count) do
          {:ok, count} when is_integer(count) -> {:ok, %{count: count}}
          _ -> {:error, unreadable("an unread count", response)}
        end

      {:error, reason} ->
        {:error, failure(reason)}
    end
  end

  # What `get_thread/2` returns per node, and what its `context` says it
  # returns per node: one number, because a reader acts on the second and gets
  # the first. This is not @chain_max_replies — that one bounds a different
  # read, and the two are free to differ.
  @thread_max_replies 20

  # How far `get_thread/2` reads around a post: two levels of parents, two of
  # replies. The tool's description states these through `thread_shape/0`.
  @thread_parent_height 2
  @thread_depth 2

  @doc "What `get_thread/2` reads around a post, for the tool that describes it."
  def thread_shape,
    do: %{
      parent_height: @thread_parent_height,
      depth: @thread_depth,
      replies: @thread_max_replies
    }

  @impl true
  def get_thread(session, uri) when is_binary(uri) do
    case AtMcp.ATProto.get_post_thread(session, %{
           uri: uri,
           depth: @thread_depth,
           parentHeight: @thread_parent_height
         }) do
      {:ok, thread} -> {:ok, summarize_thread(thread)}
      {:error, reason} -> {:error, failure(reason)}
    end
  end

  # The chain becomes a woken resident's context for one turn, so its length is
  # the input size that matters. 100 elements of ordinary posts is on the order
  # of 50 KB of JSON; a conversation taller than that is cut to its last 100
  # elements — the ones nearest the post being answered — and the number
  # dropped is reported in `chain_omitted`. Nothing downstream bounds this
  # read: `AtMcp.Effects.page_options/1` caps feeds, not threads.
  @chain_max_elements 100

  # `town.delve.feed.getPostThread` and `app.bsky.feed.getPostThread` both
  # declare `parentHeight` minimum 0, maximum 1000. Neither lexicon is vendored
  # here — priv/lexicons/README.md keeps only each network's `feed/post.json`,
  # deliberately — so that range is read from
  # delvetown-sdk/lexicons/town/delve/feed/getPostThread.json. Asking for more
  # ancestors than the chain can carry only moves bytes that are then dropped,
  # so the request asks for exactly the cap.
  @chain_parent_height @chain_max_elements

  # One level of replies: the posts directly under the requested one. A
  # resident answering a notification is placed in the conversation it was
  # named in, not handed the subtree below it.
  @chain_depth 1
  @chain_max_replies 20

  # A response cannot be followed upward forever: a parent link chain longer
  # than this is not a conversation, and reading stops there. The chain then
  # does not start at the root, which `chain_truncated` reports.
  @chain_read_limit 5_000

  # A service that caps `parentHeight` below what it was asked for answers with
  # a partial chain, so the walk asks again from the top of what it got. Each
  # further call climbs another @chain_parent_height ancestors. The chain
  # reports where it stopped rather than climbing without a bound.
  @chain_walk_limit 4

  @doc """
  The conversation leading to one post, root first, as a flat list.

  `get_thread/2` answers "what is around this post": two levels up, two levels
  down, nested. This answers the other question — "what was said before this
  was said to me" — and the shapes differ because the uses do. A chain element
  carries what a reader of a conversation needs and a feed item does not: when
  it was written, what it replied to, whether this account wrote it, and the
  destinations its facets point at.

  The chain always ends at the post it was asked for. It begins at the thread
  root whenever the read can reach it; when it cannot, the first element names
  the uri where reading stopped and `chain_truncated` is true, rather than a
  shorter chain that silently does not start where the conversation did. It
  carries at most #{@chain_max_elements} elements: a taller conversation keeps
  the ones nearest the requested post, `chain_omitted` counts the rest, and
  `chain_truncated` is true.

  A cut chain says where to carry on. `chain_before` is the parent of the
  element the cut left at the head. Passing it back as `:before` reads the page
  above: the chain then ends at that uri instead of at the requested post, so a
  conversation of any height is readable in pages that neither repeat a post
  nor skip one. A page read this way carries no replies; the replies belong to
  the post the caller asked about, and returning an ancestor's would put a post
  in two pages.

  `chain_before` is `nil` whenever there is no uri to read next that would
  bring the caller anything new: a chain that runs from the root, a head that
  could not be read and so names no parent, a head whose parent the page
  already holds, and a walk that turned back on itself and stopped at a uri it
  had already read. Nil is not "the conversation is complete" — that is what
  `chain_truncated` answers — it is "nowhere to resume". A caller that wants to
  try past a head the walk could not read has that head's own uri in the chain,
  flagged `unresolved`.

  The chain never repeats a post. A response whose parent links do not converge
  on the root — a reply whose declared root is not its topmost ancestor, or two
  records naming each other as parent — ends the walk instead of prepending
  ancestors it has already read.
  """
  @impl true
  def get_thread_chain(session, uri, opts \\ []) when is_binary(uri) do
    # `AtMcp.Effects.get_thread_chain/3` refuses anything else before a session
    # is taken, so a `before` that reaches here is a uri or nothing. The third
    # clause is still here because a cursor comes back from whoever holds it,
    # and a backend that raises on a bad argument is a harder failure than one
    # that refuses it.
    case Keyword.get(opts, :before) do
      nil -> chain_ending_at(session, uri, @chain_depth, :with_replies)
      before when is_binary(before) -> chain_ending_at(session, before, 0, :chain_only)
      _other -> {:error, :invalid_before}
    end
  end

  defp chain_ending_at(session, uri, depth, replies) do
    with {:ok, node} <- fetch_thread(session, uri, depth) do
      did = Map.get(session, :did)
      declared = AtMcp.Response.dig(node, [:post, :record, :reply, :root, :uri])
      root_uri = if is_binary(declared), do: declared, else: uri

      {walked, truncated, stop} =
        reach_root(session, chain_elements(node, did), root_uri, did, @chain_walk_limit)

      {chain, chain_omitted} = cap_chain(walked)
      {replies, replies_omitted} = chain_replies(node, did, replies)
      truncated = truncated or chain_omitted > 0 or Enum.any?(chain, &unreadable_element?/1)

      {:ok,
       %{
         root_uri: root_uri,
         chain: chain,
         chain_omitted: chain_omitted,
         chain_truncated: truncated,
         chain_before: chain_before(chain, truncated, stop),
         replies: replies,
         replies_omitted: replies_omitted
       }}
    end
  end

  # Where a caller resumes, and nil wherever resuming would hand it a post it
  # already has. A chain that runs from the root has nothing above it. A head
  # that could not be read names no parent, so there is no uri to read next
  # that is not one of these; the head element carries its own uri and says it
  # is unresolved, which is what a caller reads to decide whether to try it.
  # And a head whose parent is already in the page is a walk that turned back
  # on itself — two records naming each other as parent, or a declared root
  # below the topmost ancestor — where resuming would return this page again,
  # forever.
  defp chain_before(_chain, false, _stop), do: nil
  defp chain_before(_chain, true, :turned_back), do: nil
  defp chain_before([], _truncated, _stop), do: nil

  defp chain_before([head | _rest] = chain, true, _stop) do
    if not head.unresolved and is_binary(head.reply_to) and
         not Enum.any?(chain, &(&1.uri == head.reply_to)),
       do: head.reply_to
  end

  @impl true
  def get_timeline(session, opts) do
    limit = Keyword.get(opts, :limit, 20)

    case AtMcp.ATProto.get_timeline(
           session,
           AtMcp.ATProto.params(%{limit: limit, cursor: Keyword.get(opts, :cursor)})
         ) do
      {:ok, feed} -> page(feed, :feed, &feed_item/1)
      {:error, reason} -> {:error, failure(reason)}
    end
  end

  @impl true
  def get_author_feed(session, actor, opts) when is_binary(actor) do
    session
    |> AtMcp.ATProto.get_author_feed(paging(opts, %{actor: actor}))
    |> read(:feed, &feed_item/1)
  end

  @impl true
  def get_profile(session, actor) when is_binary(actor) do
    case AtMcp.ATProto.get_profile(session, %{actor: actor}) do
      {:ok, profile} -> {:ok, summarize_profile(profile)}
      {:error, reason} -> {:error, failure(reason)}
    end
  end

  @impl true
  def get_profiles(session, actors) when is_list(actors) do
    session
    |> AtMcp.ATProto.get_profiles(actors)
    |> read(:profiles, &summarize_profile/1)
  end

  @impl true
  def get_posts(session, uris) when is_list(uris) do
    session
    |> AtMcp.ATProto.get_posts(uris)
    |> read(:posts, &post_view/1)
  end

  @impl true
  def search_posts(session, query, opts) when is_binary(query) do
    limit = Keyword.get(opts, :limit, 20)

    case AtMcp.ATProto.search_posts(
           session,
           AtMcp.ATProto.params(%{q: query, limit: limit, cursor: Keyword.get(opts, :cursor)})
         ) do
      {:ok, raw} -> page(raw, :posts, &post_view/1)
      {:error, reason} -> {:error, failure(reason)}
    end
  end

  @impl true
  def search_actors(session, query, opts) when is_binary(query) do
    limit = Keyword.get(opts, :limit, 20)

    case AtMcp.ATProto.search_actors(
           session,
           AtMcp.ATProto.params(%{q: query, limit: limit, cursor: Keyword.get(opts, :cursor)})
         ) do
      {:ok, raw} -> page(raw, :actors, &summarize_profile/1)
      {:error, reason} -> {:error, failure(reason)}
    end
  end

  # --- graph reads ---

  @impl true
  def get_followers(session, actor, opts) when is_binary(actor) do
    session
    |> AtMcp.ATProto.get_followers(paging(opts, %{actor: actor}))
    |> read(:followers, &summarize_profile/1)
  end

  @impl true
  def get_follows(session, actor, opts) when is_binary(actor) do
    session
    |> AtMcp.ATProto.get_follows(paging(opts, %{actor: actor}))
    |> read(:follows, &summarize_profile/1)
  end

  @impl true
  def get_known_followers(session, actor, opts) when is_binary(actor) do
    session
    |> AtMcp.ATProto.get_known_followers(paging(opts, %{actor: actor}))
    |> read(:followers, &summarize_profile/1)
  end

  @impl true
  def get_suggested_follows(session, actor) when is_binary(actor) do
    session
    |> AtMcp.ATProto.get_suggested_follows_by_actor(%{actor: actor})
    |> read(:suggestions, &summarize_profile/1)
  end

  @impl true
  def get_blocks(session, opts) do
    session
    |> AtMcp.ATProto.get_blocks(paging(opts, %{}))
    |> read(:blocks, &summarize_profile/1)
  end

  @impl true
  def get_mutes(session, opts) do
    session
    |> AtMcp.ATProto.get_mutes(paging(opts, %{}))
    |> read(:mutes, &summarize_profile/1)
  end

  @impl true
  def get_relationships(session, actor, others) when is_binary(actor) and is_list(others) do
    session
    |> AtMcp.ATProto.get_relationships(actor, others)
    |> read(:relationships, &relationship_item/1)
  end

  # --- engagement reads ---

  # A like is a record about an actor, the way a feed item is a record about a
  # post. The affordance is who liked this, so the actor is what is summarized.
  @impl true
  def get_likes(session, uri, opts) when is_binary(uri) do
    session
    |> AtMcp.ATProto.get_likes(paging(opts, %{uri: uri}))
    |> read(:likes, &actor_item/1)
  end

  @impl true
  def get_reposted_by(session, uri, opts) when is_binary(uri) do
    session
    |> AtMcp.ATProto.get_reposted_by(paging(opts, %{uri: uri}))
    |> read(:reposted_by, &summarize_profile/1)
  end

  @impl true
  def get_quotes(session, uri, opts) when is_binary(uri) do
    session
    |> AtMcp.ATProto.get_quotes(paging(opts, %{uri: uri}))
    |> read(:posts, &post_view/1)
  end

  @impl true
  def get_actor_likes(session, actor, opts) when is_binary(actor) do
    session
    |> AtMcp.ATProto.get_actor_likes(paging(opts, %{actor: actor}))
    |> read(:feed, &feed_item/1)
  end

  # --- feeds ---

  @impl true
  def get_feed(session, feed, opts) when is_binary(feed) do
    session
    |> AtMcp.ATProto.get_feed(paging(opts, %{feed: feed}))
    |> read(:feed, &feed_item/1)
  end

  @impl true
  def get_list_feed(session, list, opts) when is_binary(list) do
    session
    |> AtMcp.ATProto.get_list_feed(paging(opts, %{list: list}))
    |> read(:feed, &feed_item/1)
  end

  @doc """
  Publish a post. `opts` carries what a post can hold beyond its text:
  `:reply` (a parent AT URI), `:images`, `:quote` and `:langs`.

  `:images` entries are `%{data: binary, mime_type: String.t(), alt: String.t()}`;
  each is uploaded as a blob before the record is built, because the record
  references a blob rather than carrying one. A quote is an AT URI, whose CID
  is read from the record it names — a strong reference has to be strong, and
  the caller has only the URI.
  """
  @impl true
  def prepare_post(session, text, opts) do
    with :ok <- validate_post_languages(opts),
         {rich_text, unresolved} = AtMcp.RichText.build(text, session),
         {:ok, opts} <- resolve_references(session, opts),
         {:ok, images} <- upload_images(session, Keyword.get(opts, :images)) do
      record =
        AtMcp.ATProto.post_record(
          text: rich_text.text,
          facets: rich_text.facets,
          langs: Keyword.get(opts, :langs),
          reply: Keyword.get(opts, :reply_ref),
          images: images,
          quote: Keyword.get(opts, :quote_ref)
        )

      {:ok, %{record: record, unresolved: unresolved, reply: Keyword.get(opts, :reply)}}
    else
      {:error, {:referenced_record_unreadable, _uri}} = error -> error
      {:error, reason} -> {:error, failure(reason)}
    end
  rescue
    error ->
      {:error,
       AtMcp.Effects.Failure.new(:refused,
         message: "The post could not be prepared. No post was sent.",
         detail: error
       )}
  end

  # This is a targeted lexicon-derived check, not full record validation.
  # proto_rune 0.5.3's generator drops array bounds, emits unresolved refs that
  # Peri rejects, and expects DateTime structs where records carry ISO strings.
  # Peri also projects away undeclared fields. Keep the original record intact;
  # retire this check only when schema validation preserves it and these bounds.
  # Run before reference reads or blob uploads, as well as quota and dispatch.
  defp validate_post_languages(opts) do
    langs = Keyword.get(opts, :langs)
    maximum = AtMcp.Network.post_language_limit()

    if is_list(langs) and length(langs) > maximum do
      {:error,
       AtMcp.Effects.Failure.new(:refused,
         message: "A post can have at most #{maximum} language tags. No post was sent."
       )}
    else
      :ok
    end
  end

  # The direct backend API and Effects use the same preparation path. Effects
  # calls it before reserving quota; this convenience entry point has no quota.
  def post(session, text, opts \\ [])

  def post(session, text, opts) when is_binary(text) and is_list(opts) do
    with {:ok, prepared} <- prepare_post(session, text, opts),
         do: post(session, text, prepared)
  end

  @impl true
  def post(session, text, %{record: record, unresolved: unresolved, reply: reply}) do
    case create(session, :post, record) do
      {:ok, result} ->
        summary = summarize_write(result, text)
        summary = if reply, do: Map.put(summary, :reply_to, reply), else: summary
        {:ok, mention_warnings(summary, unresolved)}

      {:error, reason} ->
        {:error, failure(reason)}
    end
  end

  @impl true
  def like(session, uri, cid) when is_binary(uri) and is_binary(cid) do
    case create(session, :like, AtMcp.ATProto.like_record(subject: %{uri: uri, cid: cid})) do
      {:ok, result} ->
        {:ok,
         Map.merge(summarize_record(result), %{subject_uri: uri, subject_cid: cid, action: :like})}

      {:error, reason} ->
        {:error, failure(reason)}
    end
  end

  @impl true
  def unlike(session, like_uri) when is_binary(like_uri),
    do: delete(session, like_uri, :unlike, :like)

  @impl true
  def repost(session, uri, cid) when is_binary(uri) and is_binary(cid) do
    case create(session, :repost, AtMcp.ATProto.repost_record(subject: %{uri: uri, cid: cid})) do
      {:ok, result} ->
        {:ok,
         Map.merge(summarize_record(result), %{
           subject_uri: uri,
           subject_cid: cid,
           action: :repost
         })}

      {:error, reason} ->
        {:error, failure(reason)}
    end
  end

  @impl true
  def unrepost(session, repost_uri) when is_binary(repost_uri),
    do: delete(session, repost_uri, :unrepost, :repost)

  @impl true
  def follow(session, "did:" <> _ = did) do
    case create(session, :follow, AtMcp.ATProto.follow_record(subject: did)) do
      {:ok, result} -> {:ok, Map.merge(summarize_record(result), %{actor: did, action: :follow})}
      {:error, reason} -> {:error, failure(reason)}
    end
  end

  @impl true
  def unfollow(session, follow_uri) when is_binary(follow_uri),
    do: delete(session, follow_uri, :unfollow, :follow)

  @impl true
  def block(session, "did:" <> _ = did) do
    case create(session, :block, AtMcp.ATProto.block_record(subject: did)) do
      {:ok, result} -> {:ok, Map.merge(summarize_record(result), %{actor: did, action: :block})}
      {:error, reason} -> {:error, failure(reason)}
    end
  end

  @impl true
  def unblock(session, block_uri) when is_binary(block_uri),
    do: delete(session, block_uri, :unblock, :block)

  # A mute is server-side state rather than a record, so it is a method call
  # and not a write to the repository.
  @impl true
  def mute(session, "did:" <> _ = did) do
    case AtMcp.ATProto.mute_actor(session, %{actor: did}) do
      {:ok, _} -> {:ok, %{ok: true, actor: did, action: :mute}}
      {:error, reason} -> {:error, failure(reason)}
    end
  end

  @impl true
  def unmute(session, "did:" <> _ = did) do
    case AtMcp.ATProto.unmute_actor(session, %{actor: did}) do
      {:ok, _} -> {:ok, %{ok: true, actor: did, action: :unmute}}
      {:error, reason} -> {:error, failure(reason)}
    end
  end

  @impl true
  def delete_post(session, post_uri) when is_binary(post_uri),
    do: delete(session, post_uri, :delete_post, :post)

  @impl true
  def update_profile(session, updates) when is_list(updates) do
    # Avatar blobs are out of scope for these tools; only text fields.
    safe = Keyword.take(updates, [:display_name, :description])

    with {:ok, current} <- current_profile(session),
         record = AtMcp.ATProto.profile_record(merge_profile(current, safe)),
         {:ok, result} <-
           AtMcp.ATProto.put_record(session, %{
             repo: session.did,
             collection: AtMcp.Network.collection(:profile),
             rkey: "self",
             record: record
           }) do
      {:ok,
       %{
         ok: true,
         action: :update_profile,
         display_name: Keyword.get(safe, :display_name),
         description: Keyword.get(safe, :description),
         uri: Map.get(result, :uri) || Map.get(result, "uri")
       }}
    else
      {:error, reason} -> {:error, failure(reason)}
    end
  end

  @impl true
  def update_seen(session, %DateTime{} = seen_at) do
    case AtMcp.ATProto.update_seen(session, %{seen_at: DateTime.to_iso8601(seen_at)}) do
      {:ok, _} -> {:ok, %{ok: true, action: :update_seen, seen_at: DateTime.to_iso8601(seen_at)}}
      :ok -> {:ok, %{ok: true, action: :update_seen, seen_at: DateTime.to_iso8601(seen_at)}}
      {:error, reason} -> {:error, failure(reason)}
    end
  end

  # --- the write half ---

  # Every record AtMcp creates goes through here, so the collection and the
  # record's `$type` cannot disagree: both are `AtMcp.Network`'s answer for the
  # same kind.
  defp create(session, kind, record) do
    AtMcp.ATProto.create_record(session, %{
      repo: session.did,
      collection: AtMcp.Network.collection(kind),
      record: record
    })
  end

  # The URI selects the network, but the tool selects the record kind. An
  # account may delete records from either supported network after reconfiguring;
  # undoing a repost must never delete the original post instead. Repository
  # ownership (including handle references) is still enforced by the home PDS.
  defp delete(session, uri, action, kind) do
    with {:ok, {repo, collection, rkey}} <- AtMcp.ATProto.parse_uri(uri),
         :ok <- require_record_kind(collection, kind, action),
         {:ok, _} <-
           AtMcp.ATProto.delete_record(session, %{
             repo: repo,
             collection: collection,
             rkey: rkey
           }) do
      {:ok, %{ok: true, uri: uri, action: action}}
    else
      {:error, reason} -> {:error, failure(reason)}
    end
  end

  defp require_record_kind(collection, kind, action) do
    if AtMcp.Network.collection?(collection, kind) do
      :ok
    else
      {:error,
       AtMcp.Effects.Failure.new(:refused,
         message:
           "#{action} requires a #{kind} record URI from a supported network; nothing was sent",
         detail: {:wrong_record_kind, kind, collection}
       )}
    end
  end

  @doc """
  Resolve a handle to the DID a follow or block record names, through the
  account's own service. A DID is returned as given.

  A string that is not a handle is refused before anything is sent, and a
  service that answers the resolution with a 400 naming `HandleNotFound` (the
  lexicon's error) or `InvalidRequest` (what the reference PDS answers both for
  a handle it cannot find and when its own lookup fails) could not resolve it;
  both are `{:handle_not_resolved, actor}`. Any other failure keeps its own
  kind: a rate limit or an outage says nothing about the handle, and an agent
  told to wait should not be told the handle is wrong. An answer that is not a
  DID is not one either, and is never passed on to build a record.
  """
  @impl true
  def resolve_actor(_session, "did:" <> _ = did), do: {:ok, did}

  def resolve_actor(session, handle) when is_binary(handle) do
    case ProtoRune.Atproto.Identity.resolve_handle(
           ProtoRune.Session.service_url(session),
           handle
         ) do
      {:ok, "did:" <> _ = did} ->
        {:ok, did}

      {:error, :invalid_format} ->
        {:error, {:handle_not_resolved, handle}}

      {:error, %ProtoRune.XRPC.Error{http_status: 400, reason: reason}}
      when reason in [:handle_not_found, :invalid_request] ->
        {:error, {:handle_not_resolved, handle}}

      {:error, reason} ->
        {:error, failure(reason)}

      {:ok, not_a_did} ->
        {:error, unreadable("a handle resolution", %{did: not_a_did})}
    end
  end

  @doc """
  Read the records a write refers to, and return the options carrying them.

  A reply and a quote both need a strong reference — a uri and the record's
  CID — and a CID is not derivable from a uri, so building either record means
  reading the record it points at. That read can fail, and it fails for
  ordinary reasons: the post was deleted, or it is not indexed yet, or the uri
  names something that is not a post. AtMcp runs it before the write quota
  is charged so a refusal that never reached the network costs nothing.

  Already-resolved options pass through: resolving twice would spend two reads
  on one write.
  """
  @impl true
  def resolve_references(session, opts) when is_list(opts) do
    if Keyword.has_key?(opts, :reply_ref) and Keyword.has_key?(opts, :quote_ref) do
      {:ok, opts}
    else
      with {:ok, reply} <- reply_refs(session, Keyword.get(opts, :reply)),
           {:ok, quoted} <- strong_ref_for(session, Keyword.get(opts, :quote)) do
        {:ok, opts |> Keyword.put(:reply_ref, reply) |> Keyword.put(:quote_ref, quoted)}
      end
    end
  end

  # A reply's root is the parent's own root when the parent is itself a reply,
  # and the parent otherwise. Both references carry a CID, which is why the
  # parent record has to be read rather than assumed from its URI.
  defp reply_refs(_session, nil), do: {:ok, nil}

  defp reply_refs(session, uri) when is_binary(uri) do
    with {:ok, parent, response} <- fetch_strong_ref(session, uri) do
      {:ok, %{root: root_of(response) || parent, parent: parent}}
    end
  end

  # A quote is given as an AT URI, and a strong reference needs the CID too.
  defp strong_ref_for(_session, nil), do: {:ok, nil}

  defp strong_ref_for(session, uri) when is_binary(uri) do
    with {:ok, ref, _response} <- fetch_strong_ref(session, uri), do: {:ok, ref}
  end

  # A record's CID is not derivable from its URI, so a strong reference to
  # anything means reading it first. A response without one is not a reference
  # AtMcp can weaken: it is a read it could not complete.
  defp fetch_strong_ref(session, uri) do
    with {:ok, {repo, collection, rkey}} <- AtMcp.ATProto.parse_uri(uri),
         {:ok, response} <-
           AtMcp.ATProto.get_record(session, %{repo: repo, collection: collection, rkey: rkey}),
         {:ok, cid} when is_binary(cid) <- AtMcp.Response.fetch(response, :cid) do
      {:ok, %{uri: uri, cid: cid}, response}
    else
      # An answer arrived and carried no CID: the record is unusable as a
      # reference whatever else it is.
      :error -> {:error, {:referenced_record_unreadable, uri}}
      {:ok, _not_a_cid} -> {:error, {:referenced_record_unreadable, uri}}
      {:error, reason} -> reference_error(uri, failure(reason))
    end
  end

  # A service that refuses to hand over one record is saying something about
  # that record: it is deleted, not indexed yet, or not what the uri claims,
  # and the caller's move is to reference something else. A transport failure,
  # an outage, or a credential the service rejected says nothing about the
  # record at all, and a caller told "it may be deleted" about a post that is
  # still there stops trying instead of retrying. So only a refusal becomes
  # `referenced_record_unreadable`; everything else keeps its own kind.
  defp reference_error(uri, %AtMcp.Effects.Failure{kind: :refused}),
    do: {:error, {:referenced_record_unreadable, uri}}

  defp reference_error(_uri, %AtMcp.Effects.Failure{} = failure), do: {:error, failure}

  defp root_of(response) do
    with {:ok, value} when is_map(value) <- AtMcp.Response.fetch(response, :value),
         {:ok, reply} when is_map(reply) <- AtMcp.Response.fetch(value, :reply),
         {:ok, root} when is_map(root) <- AtMcp.Response.fetch(reply, :root),
         {:ok, uri} when is_binary(uri) <- AtMcp.Response.fetch(root, :uri),
         {:ok, cid} when is_binary(cid) <- AtMcp.Response.fetch(root, :cid) do
      %{uri: uri, cid: cid}
    else
      _ -> nil
    end
  end

  # A record references a blob; it does not carry one. So the bytes are
  # uploaded first, and the record is built around what the service gives back.
  defp upload_images(_session, nil), do: {:ok, nil}
  defp upload_images(_session, []), do: {:ok, nil}

  defp upload_images(session, images) when is_list(images) do
    Enum.reduce_while(images, {:ok, []}, fn image, {:ok, acc} ->
      case AtMcp.ATProto.upload_blob(
             session,
             Map.fetch!(image, :data),
             Map.get(image, :mime_type, "application/octet-stream")
           ) do
        {:ok, response} ->
          case AtMcp.Response.fetch(response, :blob) do
            {:ok, blob} when is_map(blob) ->
              {:cont, {:ok, acc ++ [%{blob: blob, alt: Map.get(image, :alt)}]}}

            _ ->
              {:halt, {:error, :blob_not_returned}}
          end

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  # A profile update starts from the record it is about to replace, so a field
  # nobody mentioned survives it. A repository with no profile record yet is
  # not an error: the account simply has no profile, and this writes the first.
  defp current_profile(session) do
    case AtMcp.ATProto.get_record(session, %{
           repo: session.did,
           collection: AtMcp.Network.collection(:profile),
           rkey: "self"
         }) do
      {:ok, response} ->
        case AtMcp.Response.fetch(response, :value) do
          {:ok, value} when is_map(value) -> {:ok, value}
          _ -> {:ok, %{}}
        end

      {:error, %ProtoRune.XRPC.Error{reason: reason}}
      when reason in [:not_found, :record_not_found] ->
        {:ok, %{}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The read came back snakelized; the write goes out camelCase. Naming the two
  # profile fields once here is what keeps `displayName` from being written as
  # `display_name` and silently becoming a field the lexicon does not define.
  @profile_fields %{display_name: "displayName", description: "description"}

  defp merge_profile(current, updates) do
    current = Map.new(current, fn {key, value} -> {to_string(key), value} end)

    current =
      Map.new(current, fn {key, value} ->
        {Map.get(@profile_fields, String.to_atom(key), key), value}
      end)

    Enum.reduce(@profile_fields, current, fn {key, wire}, record ->
      case Keyword.get(updates, key) do
        nil -> record
        value -> Map.put(record, wire, value)
      end
    end)
  end

  # The one place a client library's failures become AtMcp's three kinds. Above
  # this line, no module needs to know what ProtoRune or its transport return.
  @auth_reasons [:expired_token, :invalid_token, :unauthorized, :token_required]

  defp failure(%AtMcp.Effects.Failure{} = failure), do: failure

  defp failure(%ProtoRune.XRPC.Error{} = error) do
    kind =
      cond do
        error.reason in @auth_reasons and error.http_status in [400, 401] -> :auth_refused
        error.reason in @auth_reasons -> :auth_refused
        is_integer(error.http_status) and error.http_status in 400..499 -> :refused
        true -> :indeterminate
      end

    AtMcp.Effects.Failure.new(kind,
      status: error.http_status,
      message: error.message,
      detail: error.reason
    )
  end

  # Request validation runs before anything is sent, so the action did not happen.
  defp failure([%Peri.Error{} | _] = errors),
    do: AtMcp.Effects.Failure.new(:refused, message: AtMcp.MCP.Tools.format_reason(errors))

  defp failure(%Peri.Error{} = error),
    do: AtMcp.Effects.Failure.new(:refused, message: AtMcp.MCP.Tools.format_reason(error))

  defp failure(reason) when reason in [:malformed_at_uri, :invalid_at_uri_format],
    do: AtMcp.Effects.Failure.new(:refused, message: "the record reference is not a valid AT URI")

  defp failure(reason) when reason in @auth_reasons,
    do: AtMcp.Effects.Failure.new(:auth_refused, detail: reason)

  # A lost or unrecognized response says nothing about whether the action ran.
  defp failure(reason), do: AtMcp.Effects.Failure.new(:indeterminate, detail: reason)

  defp decode_json_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      _ -> %{}
    end
  end

  defp decode_json_body(body) when is_map(body), do: body
  defp decode_json_body(_), do: %{}

  # --- summarizers ---

  # Every page the AppView returns is one shape under a different name for the
  # list: a count, its items and a cursor. One reader serves all of them, and it
  # matches atom and string keys alike.
  #
  # A response that does not carry the list is not an empty page. It is a
  # response AtMcp could not read, and the read is reported as unknown rather
  # than as a result the caller would believe.
  # Every paged read takes the same two options. A parameter the caller did not
  # give is left out rather than sent empty: `cursor=` asks a service to
  # continue from nowhere.
  defp paging(opts, params) do
    AtMcp.ATProto.params(
      Map.merge(params, %{
        limit: Keyword.get(opts, :limit, 20),
        cursor: Keyword.get(opts, :cursor)
      })
    )
  end

  # One endpoint result becomes one page, or one failure of AtMcp's three kinds.
  defp read({:ok, response}, key, item_fun), do: page(response, key, item_fun)
  defp read({:error, reason}, _key, _item_fun), do: {:error, failure(reason)}

  defp page(list, _key, item_fun) when is_list(list) do
    {:ok, %{count: length(list), items: Enum.map(list, item_fun), cursor: nil}}
  end

  defp page(source, key, item_fun) when is_map(source) do
    case AtMcp.Response.fetch(source, key) do
      {:ok, list} when is_list(list) ->
        {:ok,
         %{
           count: length(list),
           items: Enum.map(list, item_fun),
           cursor: cursor_of(source)
         }}

      _ ->
        {:error, unreadable("a page of #{key}", source)}
    end
  end

  defp page(other, key, _item_fun), do: {:error, unreadable("a page of #{key}", other)}

  defp cursor_of(source) do
    case AtMcp.Response.fetch(source, :cursor) do
      {:ok, cursor} when is_binary(cursor) -> cursor
      _ -> nil
    end
  end

  # The service answered; AtMcp could not read the answer. That is neither a
  # refusal nor an unknown outcome at the service, and it is not worth retrying,
  # because the limit is this parser. The message names the shape for an
  # operator without publishing the response.
  defp unreadable(what, source) do
    AtMcp.Effects.Failure.new(:unreadable,
      message: "The service returned #{what} in a shape AtMcp does not recognize.",
      detail: {:unrecognized_shape, keys_of(source)}
    )
  end

  defp notif_item(n), do: AtMcp.Summary.extract(:notification, n)

  defp fetch_thread(session, uri, depth) do
    params = %{uri: uri, depth: depth, parentHeight: @chain_parent_height}

    case AtMcp.ATProto.get_post_thread(session, params) do
      {:ok, response} ->
        case field(response, :thread) do
          node when is_map(node) ->
            if thread_node?(node),
              do: {:ok, node},
              else: {:error, unreadable("a thread", response)}

          _ ->
            {:error, unreadable("a thread", response)}
        end

      {:error, reason} ->
        {:error, failure(reason)}
    end
  end

  # A thread node is either a post view or one of the placeholders that carry a
  # uri and nothing else. A map with neither says nothing about any post, and
  # reading it as an element would put a uri-less placeholder in the chain and
  # leave the walk with nowhere to go but the uri it started from.
  defp thread_node?(node) do
    is_map(of_type(node, :post, &is_map/1)) or is_binary(field(node, :uri))
  end

  # The chain the service returned, root first: each node's `parent` link
  # walked up, then read back down. The counter is not a policy, it is a
  # terminator — a response deeper than the @chain_parent_height it was asked
  # for must not take the caller with it. What is over the cap is cut once, by
  # `cap_chain/1`, where the count it reports is taken.
  defp chain_elements(node, did), do: chain_elements(node, did, [], @chain_read_limit)

  defp chain_elements(node, did, acc, remaining) when is_map(node) and remaining > 0 do
    acc = [chain_element(node, did) | acc]

    case field(node, :parent) do
      parent when is_map(parent) -> chain_elements(parent, did, acc, remaining - 1)
      _ -> acc
    end
  end

  defp chain_elements(_node, _did, acc, _remaining), do: acc

  # Whether the chain begins where the conversation did. The requested post
  # names its own root, so arriving is checkable rather than assumed: a service
  # that answered with fewer parents than it was asked for is indistinguishable
  # from a short thread without this.
  #
  # The walk also says why it stopped, because a caller cannot resume from
  # every stop. `:turned_back` is the one that matters: the uri above the head
  # is one this walk has already read and refused, so reading from it returns
  # what the caller already has.
  defp reach_root(session, chain, root_uri, did, calls_left) do
    reach_root(session, chain, root_uri, did, calls_left, seen(chain))
  end

  defp reach_root(session, chain, root_uri, did, calls_left, seen) do
    top = hd(chain)

    cond do
      top.uri == root_uri ->
        {chain, false, :root}

      # The chain already carries all it can. Ancestors read now would only be
      # cut again, so the reads are not spent.
      length(chain) >= @chain_max_elements ->
        {chain, true, :cap}

      calls_left == 0 ->
        {[unresolved(top.reply_to || root_uri) | chain], true, :walk_limit}

      true ->
        # A post that could not be read does not name its own parents, so the
        # only uri left to try is the root the requested post declared: read it
        # by uri, and report that what sits between is not known.
        {next, jumped} =
          if is_binary(top.reply_to), do: {top.reply_to, false}, else: {root_uri, true}

        # Reading a post the chain already holds cannot bring it closer to the
        # root, and prepending it again would hand the caller a conversation
        # that never happened. Two shapes arrive here: a reply whose declared
        # root is not its topmost ancestor, so `root_uri` sits below the head
        # and is never reached, and records that name each other as parent.
        if MapSet.member?(seen, next) do
          {chain, true, :turned_back}
        else
          climb(session, chain, next, root_uri, did, calls_left, jumped, seen)
        end
    end
  end

  defp climb(session, chain, uri, root_uri, did, calls_left, jumped, seen) do
    with {:ok, node} <- fetch_thread(session, uri, 0),
         fresh = chain_elements(node, did),
         false <- Enum.any?(fresh, &MapSet.member?(seen, &1.uri)) do
      {chain, truncated, stop} =
        reach_root(
          session,
          fresh ++ chain,
          root_uri,
          did,
          calls_left - 1,
          Enum.reduce(fresh, seen, &put_seen(&2, &1.uri))
        )

      {chain, truncated or jumped, stop}
    else
      # The response repeats a post the chain already holds: stop here rather
      # than read the same ancestors again. This uri has now been read and
      # refused, so it is not a place to resume either.
      true -> {chain, true, :turned_back}
      {:error, _reason} -> {[unresolved(uri) | chain], true, :walk_limit}
    end
  end

  defp seen(chain), do: Enum.reduce(chain, MapSet.new(), &put_seen(&2, &1.uri))

  defp put_seen(set, uri) when is_binary(uri), do: MapSet.put(set, uri)
  defp put_seen(set, _uri), do: set

  # Root first, so what is cut is what is furthest from the post being
  # answered, and the count is what the caller is told it is missing.
  defp cap_chain(chain) do
    case length(chain) - @chain_max_elements do
      extra when extra > 0 -> {Enum.drop(chain, extra), extra}
      _ -> {chain, 0}
    end
  end

  defp unreadable_element?(element) do
    element.not_found or element.blocked or element.unresolved
  end

  # A page read from `before` carries no replies at all. Asking for depth 0 is
  # not enough to promise that: a service free to answer with more than it was
  # asked for would put a post in two pages, and the promise is AtMcp's to keep.
  defp chain_replies(_node, _did, :chain_only), do: {[], 0}

  defp chain_replies(node, did, :with_replies) do
    replies = of_type(node, :replies, &is_list/1) || []
    visible = Enum.take(replies, @chain_max_replies)
    {Enum.map(visible, &chain_element(&1, did)), length(replies) - length(visible)}
  end

  defp chain_element(node, did) when is_map(node) do
    case of_type(node, :post, &is_map/1) do
      post when is_map(post) -> post_element(node, post, did)
      _ -> node_placeholder(node)
    end
  end

  defp chain_element(_node, _did), do: placeholder(nil)

  defp post_element(node, post, did) do
    base = AtMcp.Summary.extract(:chain_post, post)

    Map.merge(base, %{
      # A handle is a name the account can change; the DID is the account.
      is_self: is_binary(did) and base.author_did == did,
      not_found: flag(node, [:not_found, :notFound]),
      blocked: flag(node, [:blocked]),
      unresolved: false
    })
  end

  # `notFoundPost` and `blockedPost` carry a uri and nothing else worth
  # reading. The element keeps its place in the chain: a resident that cannot
  # see one post of a conversation is somewhere different from one reading a
  # conversation that is one post shorter.
  defp node_placeholder(node) do
    author_did = AtMcp.Response.dig(node, [:author, :did])

    node
    |> field(:uri)
    |> placeholder()
    |> Map.put(:author_did, if(is_binary(author_did), do: author_did))
    |> Map.put(:not_found, flag(node, [:not_found, :notFound]))
    |> Map.put(:blocked, flag(node, [:blocked]))
  end

  defp unresolved(uri), do: uri |> placeholder() |> Map.put(:unresolved, true)

  defp placeholder(uri) do
    %{
      uri: if(is_binary(uri), do: uri),
      cid: nil,
      text: nil,
      author: nil,
      author_did: nil,
      display_name: nil,
      created_at: nil,
      reply_to: nil,
      facets: [],
      is_self: false,
      not_found: false,
      blocked: false,
      unresolved: false
    }
  end

  defp summarize_thread(thread) when is_map(thread) do
    node = field(thread, :thread) || thread

    node
    |> thread_node(2, 2)
    |> Map.put(:context, %{depth: 2, parent_height: 2, max_replies_per_node: @thread_max_replies})
  end

  defp summarize_thread(other), do: %{value: to_string_safe(other)}

  defp thread_node(node, parents, depth) when is_map(node) do
    post = of_type(node, :post, &is_map/1) || node
    replies = of_type(node, :replies, &is_list/1) || []
    parent = field(node, :parent)
    visible = if depth > 0, do: Enum.take(replies, @thread_max_replies), else: []

    post_view(post)
    |> Map.put(:type, field(node, :"$type"))
    |> Map.put(:not_found, flag(node, [:not_found, :notFound]))
    |> Map.put(:blocked, flag(node, [:blocked]))
    |> Map.put(:parent, if(parent && parents > 0, do: thread_node(parent, parents - 1, 0)))
    |> Map.put(:parent_omitted, not is_nil(parent) and parents == 0)
    |> Map.put(:replies, Enum.map(visible, &thread_node(&1, 0, depth - 1)))
    |> Map.put(:replies_omitted, length(replies) - length(visible))
  end

  # `false` is a value. Read through a chain of `||` fallbacks it becomes the same
  # answer as a key the response never sent, so an unread notification would
  # report an unknown state. These two flags want `false` in both cases, so they
  # are read once and explicitly here rather than by a fallback the next flag
  # would inherit.
  defp flag(node, keys) do
    Enum.reduce_while(keys, false, fn key, default ->
      case AtMcp.Response.fetch(node, key) do
        {:ok, value} when is_boolean(value) -> {:halt, value}
        _ -> {:cont, default}
      end
    end)
  end

  defp of_type(map, key, predicate) do
    value = field(map, key)
    if predicate.(value), do: value
  end

  defp field(map, key) do
    case AtMcp.Response.fetch(map, key) do
      {:ok, value} -> value
      :error -> nil
    end
  end

  defp feed_item(item) when is_map(item) do
    post =
      case AtMcp.Response.fetch(item, :post) do
        {:ok, post} when is_map(post) -> post
        _ -> item
      end

    post_view(post)
  end

  defp feed_item(other), do: %{value: to_string_safe(other)}

  # `getLikes` returns the like record, not the account; the account is inside
  # it. Unwrapping here is the same move `feed_item/1` makes for `post`.
  defp actor_item(item) when is_map(item) do
    case AtMcp.Response.fetch(item, :actor) do
      {:ok, actor} when is_map(actor) -> summarize_profile(actor)
      _ -> summarize_profile(item)
    end
  end

  defp actor_item(other), do: %{value: to_string_safe(other)}

  defp relationship_item(item), do: AtMcp.Summary.extract(:relationship, item)

  defp post_view(post), do: AtMcp.Summary.extract(:post, post)

  defp summarize_profile(p), do: AtMcp.Summary.extract(:profile, p)

  defp mention_warnings(result, []), do: result

  defp mention_warnings(result, handles) do
    Map.merge(result, %{
      unresolved_mentions: handles,
      warning:
        "These handles could not be resolved. They were published as plain text, without mention facets."
    })
  end

  defp summarize_write(result, text) when is_map(result) do
    %{
      uri: Map.get(result, :uri) || Map.get(result, "uri"),
      cid: Map.get(result, :cid) || Map.get(result, "cid"),
      text: text
    }
  end

  defp summarize_write(result, text), do: %{result: to_string_safe(result), text: text}

  defp summarize_record(result) when is_map(result) do
    %{
      uri: Map.get(result, :uri) || Map.get(result, "uri"),
      cid: Map.get(result, :cid) || Map.get(result, "cid")
    }
  end

  defp summarize_record(result), do: %{result: to_string_safe(result)}

  defp keys_of(map) when is_map(map), do: Map.keys(map) |> Enum.map(&to_string/1) |> Enum.take(20)
  defp keys_of(_), do: []

  defp to_string_safe(v) when is_binary(v), do: v
  defp to_string_safe(v), do: inspect(v, limit: 20)
end
