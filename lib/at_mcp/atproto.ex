defmodule AtMcp.ATProto do
  @moduledoc """
  Every endpoint AtMcp calls on the application namespace, declared once.

  AtMcp's application namespace is a value (`AtMcp.Network`), so each function
  here names its suffix within that namespace and its parameters, and resolves
  the NSID when it is called. proto_rune's `defquery` compiles the NSID into the
  function it generates, so it cannot serve both networks from one release.
  `com.atproto.*` methods are literals, because they are the same NSIDs on every
  network.

  Every declaration is authenticated. An unauthenticated read returns records
  with no `viewer` object, and `viewer` is the account's own relationship to a
  record — what `AtMcp.Summary` reads and an agent decides on.

  Three rules apply to a new declaration.

  - **A parameter's declared name goes on the wire verbatim.**
    `ProtoRune.XRPC.Query` runs validated parameters through
    `URI.encode_query/1` with no camelization, so a parameter takes the name the
    lexicon uses: `:parentHeight`, not `:parent_height`.

  - **A `nil` parameter is sent as an empty value.** Peri drops an absent key and
    keeps a key that is present and `nil`, so `params/1` drops the keys a caller
    did not supply.

  - **A list parameter cannot go through `read/4`.** `URI.encode_query/1` raises
    on a list value, while AT Protocol repeats the key once per element. Those
    endpoints are declared as ordinary functions over `repeated_query/3`.

  ## The records

  A write is `com.atproto.repo.createRecord` with a collection and a record
  whose `$type` equals that collection. Both come from `AtMcp.Network`, so a
  record builder here is the only thing that decides which network a write lands
  on. `ProtoRune.Bsky` is not used to build records: it compiles `app.bsky.*`
  into them and validates them through Peri schemas that drop undeclared keys —
  an `embed` handed to `Bsky.post/3` returns `{:ok, ...}` with the embed gone.
  """

  alias AtMcp.ATProto.ServiceAuth
  alias AtMcp.Network
  alias ProtoRune.Session
  alias ProtoRune.XRPC.Client
  alias ProtoRune.XRPC.Procedure
  alias ProtoRune.XRPC.Query

  # The paging parameters most list endpoints share.
  @page [limit: :integer, cursor: :string]

  def get_membership(session, params),
    do: read(session, "membership.getMembership", params)

  # --- feed reads ---

  # `ProtoRune.Bsky.get_post_thread/2` sends `parent_height`, which the lexicon
  # does not define; the AppView answers with no parents at all.
  def get_post_thread(session, params),
    do:
      read(session, "feed.getPostThread", params,
        uri: {:required, :string},
        depth: :integer,
        parentHeight: :integer
      )

  # proto_rune declares `getAuthorFeed` public-only, so its generated function
  # takes no session, reaches bsky.social rather than the account's own service,
  # and 401s there.
  def get_author_feed(session, params),
    do: read(session, "feed.getAuthorFeed", params, [actor: {:required, :string}] ++ @page)

  # A custom feed: the generator's AT URI selects the slice of the network.
  def get_feed(session, params),
    do: read(session, "feed.getFeed", params, [feed: {:required, :string}] ++ @page)

  # The posts of the accounts on one list.
  def get_list_feed(session, params),
    do: read(session, "feed.getListFeed", params, [list: {:required, :string}] ++ @page)

  # Who liked a post.
  def get_likes(session, params),
    do: read(session, "feed.getLikes", params, [uri: {:required, :string}, cid: :string] ++ @page)

  # Who quoted a post.
  def get_quotes(session, params),
    do:
      read(session, "feed.getQuotes", params, [uri: {:required, :string}, cid: :string] ++ @page)

  # Who reposted a post.
  def get_reposted_by(session, params),
    do:
      read(
        session,
        "feed.getRepostedBy",
        params,
        [uri: {:required, :string}, cid: :string] ++ @page
      )

  # What an account has liked.
  def get_actor_likes(session, params),
    do: read(session, "feed.getActorLikes", params, [actor: {:required, :string}] ++ @page)

  # The home timeline.
  def get_timeline(session, params),
    do: read(session, "feed.getTimeline", params, @page)

  # Full-text search over posts.
  def search_posts(session, params),
    do: read(session, "feed.searchPosts", params, [q: {:required, :string}] ++ @page)

  # --- actor reads ---

  def get_profile(session, params),
    do: read(session, "actor.getProfile", params, actor: {:required, :string})

  def search_actors(session, params),
    do: read(session, "actor.searchActors", params, [q: {:required, :string}] ++ @page)

  # --- notifications ---

  @doc """
  List account notifications, optionally filtering by repeated `reasons` keys.

  The notification reasons array shares the list-encoding defect documented for
  the other repeated-query endpoints below.
  """
  def list_notifications(session, params),
    do: repeated_query(session, AtMcp.Network.nsid("notification.listNotifications"), params)

  def get_unread_count(session, params),
    do: read(session, "notification.getUnreadCount", params, priority: :boolean)

  # The one write declared here. `ProtoRune.Bsky.update_seen/2` stringifies the
  # DateTime before a schema that requires a DateTime, and the XRPC client then
  # camelizes the body by recursing into every map — which a DateTime is. This
  # declares the wire type the endpoint actually takes. 0.6.0 still does both.
  # An upstream fix deletes nothing here: the runtime namespace already keeps
  # this off `ProtoRune.Bsky`.
  def update_seen(session, params),
    do: write(session, "notification.updateSeen", params, seen_at: {:required, :string})

  # --- graph writes that are methods rather than records ---

  # A mute is not a record in the repository: it is server-side state on the
  # AppView, set by an application-namespace method. So it moves with the
  # namespace like a read does, and unlike a block, which is a record.
  def mute_actor(session, params),
    do: write(session, "graph.muteActor", params, actor: {:required, :string})

  def unmute_actor(session, params),
    do: write(session, "graph.unmuteActor", params, actor: {:required, :string})

  # --- graph reads ---

  def get_followers(session, params),
    do: read(session, "graph.getFollowers", params, [actor: {:required, :string}] ++ @page)

  def get_follows(session, params),
    do: read(session, "graph.getFollows", params, [actor: {:required, :string}] ++ @page)

  # Followers of one account that this account also follows.
  def get_known_followers(session, params),
    do: read(session, "graph.getKnownFollowers", params, [actor: {:required, :string}] ++ @page)

  def get_suggested_follows_by_actor(session, params),
    do: read(session, "graph.getSuggestedFollowsByActor", params, actor: {:required, :string})

  # The requesting account's own blocks and mutes. Neither takes an actor: the
  # subject is whoever the session belongs to.
  def get_blocks(session, params),
    do: read(session, "graph.getBlocks", params, @page)

  def get_mutes(session, params),
    do: read(session, "graph.getMutes", params, @page)

  # --- endpoints whose parameters include a list ---

  @doc """
  Fetch several profiles. `actors` is repeated once per entry.

  `ProtoRune.Bsky.get_profiles/2` passes the list straight into
  `URI.encode_query/1`, which raises "values cannot be lists".
  """
  def get_profiles(session, actors) when is_list(actors),
    do: repeated_query(session, AtMcp.Network.nsid("actor.getProfiles"), %{actors: actors})

  @doc """
  Fetch several posts by AT URI. `uris` is repeated once per entry.

  `ProtoRune.Bsky.get_posts/2` both discards its session argument and raises on
  the list, so neither half of it can be used.
  """
  def get_posts(session, uris) when is_list(uris),
    do: repeated_query(session, AtMcp.Network.nsid("feed.getPosts"), %{uris: uris})

  @doc """
  Read how one account stands to each of several others.

  `others` is repeated once per entry. Declared under the real NSID: proto_rune
  spells this `getRelationShips`.
  """
  def get_relationships(session, actor, others)
      when is_binary(actor) and is_list(others),
      do:
        repeated_query(session, AtMcp.Network.nsid("graph.getRelationships"), %{
          actor: actor,
          others: others
        })

  @doc """
  Drop the parameters a caller does not have.

  Peri keeps a key whose value is `nil`, and `URI.encode_query/1` then sends it
  as an empty value — `cursor=` asks a service to continue from nowhere.
  Delete when proto_rune's `Query` leaves `nil` parameters out of the URL
  (0.6.0 still sends them).
  """
  def params(params) when is_map(params),
    do: Map.reject(params, fn {_key, value} -> is_nil(value) end)

  def params(params) when is_list(params), do: params |> Map.new() |> params()

  @doc """
  Encode a parameter map as a query list, repeating a list-valued key.

  ATProto's array parameters are repeated keys (`uris=a&uris=b`), which
  `URI.encode_query/1` expresses as repeated tuples and cannot express as a list
  value.
  """
  def flatten_query(params) when is_map(params) do
    params
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Enum.flat_map(fn
      {key, list} when is_list(list) -> Enum.map(list, &{key, &1})
      {key, value} -> [{key, value}]
    end)
  end

  def flatten_query(params) when is_list(params), do: params |> Map.new() |> flatten_query()

  # An authenticated GET with the parameters encoded rather than validated: a
  # declared parameter list cannot describe a repeated key, so these endpoints
  # skip Peri and build the query directly. Delete when proto_rune's `Query`
  # encodes a list value as repeated keys (0.6.0 still hands it to
  # `URI.encode_query/1`, which raises).
  defp repeated_query(session, method, params) do
    query =
      method
      |> Query.new(base_url: base_url(session))
      |> Map.put(:params, flatten_query(params))

    if Network.direct_read?(method, session),
      do: ServiceAuth.execute(session, query),
      else: execute(session, query, "GET")
  end

  # An authenticated read or write on the application namespace, named by its
  # suffix and declared with proto_rune's Peri parameter types.
  defp read(session, suffix, params, schema \\ []),
    do: query(session, Network.nsid(suffix), Map.new(schema), params)

  defp write(session, suffix, params, schema),
    do: procedure(session, Network.nsid(suffix), Map.new(schema), params)

  # The authenticated query and procedure every call here goes through.
  #
  # These are `ProtoRune.XRPC.query/5` and `procedure/5` with one addition that
  # proto_rune 0.6 has no option for: per-request headers. An
  # application-namespace call carries `atproto-proxy` naming this network's
  # AppView (`AtMcp.Network.request_headers/2`), which tells the account's PDS
  # where to forward it. Reads may instead go straight to the AppView with a service token
  # (`AtMcp.ATProto.ServiceAuth`); writes never do. Delete `execute/3` and call
  # `ProtoRune.XRPC.query/5` and `procedure/5` once they accept a `:headers`
  # option.
  defp query(session, method, schema, params) do
    if Network.direct_read?(method, session) do
      ServiceAuth.query(session, method, schema, params)
    else
      query = Query.new(method, from: schema, base_url: base_url(session))
      with {:ok, query} <- Query.add_params(query, params), do: execute(session, query, "GET")
    end
  end

  defp procedure(session, method, schema, params) do
    proc = Procedure.new(method, from: schema, base_url: base_url(session))

    with {:ok, proc} <- Procedure.put_body(proc, params),
         do: execute(session, proc, "POST")
  end

  defp execute(session, request, http_method) do
    url = Path.join(request.base_url, request.method)

    with {:ok, headers, session} <- Session.authorization_headers(session, http_method, url) do
      headers =
        request.headers
        |> Map.merge(headers)
        |> Map.merge(Network.request_headers(request.method, session))

      Client.execute(%{request | headers: headers}, session: session)
    end
  end

  @doc false
  # The account's own service, or the library's default. A session always
  # carries one in AtMcp, because every configured account names a service.
  def base_url(session),
    do: Session.service_url(session) || ProtoRune.Config.default_base_url()

  # --- com.atproto.repo: the methods AtMcp writes through ---
  #
  # These four NSIDs are literals, and correctly so: the rename between
  # namespaces does not touch `com.atproto.*`. What varies between networks is
  # the collection they are given and the `$type` inside the record, and both
  # come from `AtMcp.Network` through the builders below.

  @repo_write %{
    repo: {:required, :string},
    collection: {:required, :string},
    rkey: :string,
    validate: :boolean,
    record: {:required, :any}
  }

  @repo_put Map.put(@repo_write, :rkey, {:required, :string})

  @repo_delete %{
    repo: {:required, :string},
    collection: {:required, :string},
    rkey: {:required, :string}
  }

  @repo_get %{
    repo: {:required, :string},
    collection: {:required, :string},
    rkey: {:required, :string}
  }

  @doc """
  Write a new record, preserving its fields without local record-schema validation.

  This validates the request envelope, not the contents of `record`. Callers
  make selected checks, such as the network's post text limits; those are not
  full lexicon validation. We bypass `ProtoRune.Atproto.Repo.create_record/3`
  because its `app.bsky` Peri schemas discard fields they do not declare.

  The optional `validate` flag is forwarded only when supplied. Our normal
  write calls omit it. A PDS that does not know the record's lexicon, such as an
  external PDS receiving `town.delve` records, may accept the record without
  checking that schema. A successful write does not prove schema validity.
  """
  def create_record(session, params),
    do: procedure(session, "com.atproto.repo.createRecord", @repo_write, params)

  @doc "Write a record at a known rkey, creating or replacing it."
  def put_record(session, params),
    do: procedure(session, "com.atproto.repo.putRecord", @repo_put, params)

  @doc "Delete one record from a repository."
  def delete_record(session, params),
    do: procedure(session, "com.atproto.repo.deleteRecord", @repo_delete, params)

  @doc "Read one record out of a repository."
  def get_record(session, params),
    do: query(session, "com.atproto.repo.getRecord", @repo_get, params)

  @doc """
  Upload a blob and return `{:ok, %{blob: blob_ref}}`.

  The blob reference is what goes in a record's `image` field. The library's
  implementation already takes the session's own service and posts a raw body
  to `com.atproto.repo.uploadBlob`, so there is nothing network-specific in it.
  """
  def upload_blob(session, data, content_type)
      when is_binary(data) and is_binary(content_type),
      do: ProtoRune.Atproto.Repo.upload_blob(session, data, content_type)

  @doc """
  Split an AT URI into `{repo, collection, rkey}`.

  A delete names its collection in the URI it was given, so nothing about it
  depends on the configured network — the record was written on whatever
  network the URI came from.
  """
  def parse_uri("at://" <> rest) when is_binary(rest) do
    case String.split(rest, "/", parts: 3) do
      [repo, collection, rkey] when repo != "" and collection != "" and rkey != "" ->
        {:ok, {repo, collection, rkey}}

      _ ->
        {:error, :malformed_at_uri}
    end
  end

  def parse_uri(_uri), do: {:error, :invalid_at_uri_format}

  # --- the records themselves ---

  @doc """
  Build a `feed.post` record.

  Takes `:text`, and optionally `:facets` (as `AtMcp.RichText` builds them),
  `:langs`, `:reply` (`%{root: strong_ref, parent: strong_ref}`), `:images`
  (`[%{blob: blob_ref, alt: String.t()}]`), `:quote` (a strong ref) and
  `:created_at`.

  Three things this does that `ProtoRune.Bsky.post/3` cannot:

  - `$type` and the collection are `AtMcp.Network`'s, so the record lands on the
    configured network.
  - An embed survives. `images` and `quote` together become a
    `recordWithMedia`, which is the lexicon's own way of saying both.
  - `langs` is absent unless a caller gave one. The library stamps `["en"]`
    unconditionally, which made every post any agent wrote claim to be English.
    A record that says nothing about its language is correct when nobody said
    what the language is; one that names the wrong language is not.

  Keys are the wire's: string, camelCase, `$type` where the lexicon has it. The
  record this returns is the record that is sent, so a test can assert on either.
  """
  def post_record(fields) do
    %{
      "$type" => AtMcp.Network.collection(:post),
      "text" => Keyword.fetch!(fields, :text),
      "createdAt" => timestamp(Keyword.get(fields, :created_at))
    }
    |> put_present("facets", wire_facets(Keyword.get(fields, :facets)))
    |> put_present("langs", Keyword.get(fields, :langs))
    |> put_present("reply", reply_refs(Keyword.get(fields, :reply)))
    |> put_present("embed", post_embed(fields))
  end

  @doc "Build a `feed.like` record over a strong reference."
  def like_record(fields), do: subject_record(:like, fields)

  @doc "Build a `feed.repost` record over a strong reference."
  def repost_record(fields), do: subject_record(:repost, fields)

  @doc "Build a `graph.follow` record. The subject of a follow is a bare DID."
  def follow_record(fields), do: did_subject_record(:follow, fields)

  @doc "Build a `graph.block` record. The subject of a block is a bare DID."
  def block_record(fields), do: did_subject_record(:block, fields)

  @doc """
  Stamp an existing `actor.profile` record with this network's `$type`.

  A profile update reads the record it is about to replace, so the fields it
  does not mention survive; only the type is AtMcp's to say.
  """
  def profile_record(current) when is_map(current) do
    current
    |> Map.drop(["$type", :"$type"])
    |> Map.put("$type", AtMcp.Network.collection(:profile))
  end

  defp subject_record(kind, fields) do
    %{
      "$type" => AtMcp.Network.collection(kind),
      "subject" => strong_ref(Keyword.fetch!(fields, :subject)),
      "createdAt" => timestamp(Keyword.get(fields, :created_at))
    }
  end

  defp did_subject_record(kind, fields) do
    %{
      "$type" => AtMcp.Network.collection(kind),
      "subject" => Keyword.fetch!(fields, :subject),
      "createdAt" => timestamp(Keyword.get(fields, :created_at))
    }
  end

  defp timestamp(nil), do: DateTime.to_iso8601(DateTime.utc_now())
  defp timestamp(%DateTime{} = at), do: DateTime.to_iso8601(at)
  defp timestamp(at) when is_binary(at), do: at

  defp strong_ref(%{uri: uri, cid: cid}), do: %{"uri" => uri, "cid" => cid}
  defp strong_ref(%{"uri" => uri, "cid" => cid}), do: %{"uri" => uri, "cid" => cid}

  defp reply_refs(nil), do: nil

  defp reply_refs(%{root: root, parent: parent}),
    do: %{"root" => strong_ref(root), "parent" => strong_ref(parent)}

  # An embed is one field, and the lexicon's answer to "both" is a third type
  # rather than two keys. Building it here is what keeps that a fact about the
  # record instead of a rule each caller has to remember.
  defp post_embed(fields) do
    case {images_embed(Keyword.get(fields, :images)), quote_embed(Keyword.get(fields, :quote))} do
      {nil, nil} ->
        nil

      {media, nil} ->
        media

      {nil, quoted} ->
        quoted

      {media, quoted} ->
        %{
          "$type" => AtMcp.Network.type(:embed_record_with_media),
          "record" => quoted,
          "media" => media
        }
    end
  end

  defp images_embed(nil), do: nil
  defp images_embed([]), do: nil

  defp images_embed(images) when is_list(images) do
    %{
      "$type" => AtMcp.Network.type(:embed_images),
      "images" => Enum.map(images, &image/1)
    }
  end

  # Alt text defaults to empty rather than absent: the lexicon requires the
  # field, and an image with no description is a fact about the post worth
  # recording as such.
  defp image(%{blob: blob} = image) do
    %{"image" => wire_blob(blob), "alt" => Map.get(image, :alt) || ""}
    |> put_present("aspectRatio", aspect_ratio(Map.get(image, :aspect_ratio)))
  end

  # `uploadBlob` answers through the XRPC client, which snakelizes every key in
  # every response — so the reference comes back as `mime_type` and has to go
  # out as `mimeType`. `$type`, `size` and `ref.$link` have no case to lose.
  # Delete the rename when proto_rune returns response keys as the server sent
  # them (0.6.0 still snakelizes).
  defp wire_blob(blob) when is_map(blob) do
    blob
    |> deep_stringify_keys()
    |> then(fn blob ->
      case Map.pop(blob, "mime_type") do
        {nil, blob} -> blob
        {mime, blob} -> Map.put(blob, "mimeType", mime)
      end
    end)
    |> Map.put_new("$type", "blob")
  end

  defp wire_blob(blob), do: blob

  defp aspect_ratio(%{width: width, height: height}),
    do: %{"width" => width, "height" => height}

  defp aspect_ratio(_), do: nil

  defp quote_embed(nil), do: nil

  defp quote_embed(ref),
    do: %{"$type" => AtMcp.Network.type(:embed_record), "record" => strong_ref(ref)}

  # `AtMcp.RichText` builds facets in proto_rune's internal shape — snake_case
  # atoms — because the library's builder does. The wire wants `byteStart`, so
  # the translation happens here, once: a record that is only correct after
  # something downstream rewrites its keys is not a record AtMcp built.
  defp wire_facets(nil), do: nil
  defp wire_facets([]), do: nil

  defp wire_facets(facets) when is_list(facets), do: Enum.map(facets, &wire_facet/1)

  defp wire_facet(%{index: %{byte_start: start, byte_end: stop}, features: features}) do
    %{
      "index" => %{"byteStart" => start, "byteEnd" => stop},
      "features" => Enum.map(features, &stringify_keys/1)
    }
  end

  defp stringify_keys(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp deep_stringify_keys(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), deep_stringify_keys(value)} end)

  defp deep_stringify_keys(list) when is_list(list), do: Enum.map(list, &deep_stringify_keys/1)
  defp deep_stringify_keys(other), do: other

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
