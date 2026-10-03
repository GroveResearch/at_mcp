defmodule AtMcp.ATProto do
  @moduledoc """
  Every endpoint AtMcp calls on the application namespace, declared once.

  AtMcp's application namespace is a value (`AtMcp.Network`), so each declaration
  here names the suffix within that namespace, its parameters and its
  authentication. `AtMcp.ATProto.DSL` generates the functions. `com.atproto.*`
  methods are declared as literals, because they are the same NSIDs on every
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

  - **A list parameter cannot go through the DSL.** `URI.encode_query/1` raises
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

  import AtMcp.ATProto.DSL

  alias AtMcp.ATProto.DSL
  alias ProtoRune.XRPC.Client
  alias ProtoRune.XRPC.Query

  defread "membership.getMembership" do
  end

  # --- feed reads ---

  # `ProtoRune.Bsky.get_post_thread/2` sends `parent_height`, which the lexicon
  # does not define; the AppView answers with no parents at all.
  defread "feed.getPostThread" do
    param(:uri, {:required, :string})
    param(:depth, :integer)
    param(:parentHeight, :integer)
  end

  # proto_rune declares `getAuthorFeed` public-only, so its generated function
  # takes no session, reaches bsky.social rather than the account's own service,
  # and 401s there.
  defread "feed.getAuthorFeed" do
    param(:actor, {:required, :string})
    param(:limit, :integer)
    param(:cursor, :string)
  end

  # A custom feed: the generator's AT URI selects the slice of the network.
  defread "feed.getFeed" do
    param(:feed, {:required, :string})
    param(:limit, :integer)
    param(:cursor, :string)
  end

  # The posts of the accounts on one list.
  defread "feed.getListFeed" do
    param(:list, {:required, :string})
    param(:limit, :integer)
    param(:cursor, :string)
  end

  # Who liked a post.
  defread "feed.getLikes" do
    param(:uri, {:required, :string})
    param(:cid, :string)
    param(:limit, :integer)
    param(:cursor, :string)
  end

  # Who quoted a post.
  defread "feed.getQuotes" do
    param(:uri, {:required, :string})
    param(:cid, :string)
    param(:limit, :integer)
    param(:cursor, :string)
  end

  # Who reposted a post.
  defread "feed.getRepostedBy" do
    param(:uri, {:required, :string})
    param(:cid, :string)
    param(:limit, :integer)
    param(:cursor, :string)
  end

  # What an account has liked.
  defread "feed.getActorLikes" do
    param(:actor, {:required, :string})
    param(:limit, :integer)
    param(:cursor, :string)
  end

  # The home timeline.
  defread "feed.getTimeline" do
    param(:limit, :integer)
    param(:cursor, :string)
  end

  # Full-text search over posts.
  defread "feed.searchPosts" do
    param(:q, {:required, :string})
    param(:limit, :integer)
    param(:cursor, :string)
  end

  # --- actor reads ---

  defread "actor.getProfile" do
    param(:actor, {:required, :string})
  end

  defread "actor.searchActors" do
    param(:q, {:required, :string})
    param(:limit, :integer)
    param(:cursor, :string)
  end

  # --- notifications ---

  @doc """
  List account notifications, optionally filtering by repeated `reasons` keys.

  The notification reasons array shares the DSL encoding defect documented for
  the other repeated-query endpoints below.
  """
  def list_notifications(session, params),
    do: repeated_query(session, AtMcp.Network.nsid("notification.listNotifications"), params)

  defread "notification.getUnreadCount" do
    param(:priority, :boolean)
  end

  # The one write declared here. `ProtoRune.Bsky.update_seen/2` stringifies the
  # DateTime before a schema that requires a DateTime, and the XRPC client then
  # camelizes the body by recursing into every map — which a DateTime is. This
  # declares the wire type the endpoint actually takes.
  defwrite "notification.updateSeen" do
    param(:seen_at, {:required, :string})
  end

  # --- graph writes that are methods rather than records ---

  # A mute is not a record in the repository: it is server-side state on the
  # AppView, set by an application-namespace method. So it moves with the
  # namespace like a read does, and unlike a block, which is a record.
  defwrite "graph.muteActor" do
    param(:actor, {:required, :string})
  end

  defwrite "graph.unmuteActor" do
    param(:actor, {:required, :string})
  end

  # --- graph reads ---

  defread "graph.getFollowers" do
    param(:actor, {:required, :string})
    param(:limit, :integer)
    param(:cursor, :string)
  end

  defread "graph.getFollows" do
    param(:actor, {:required, :string})
    param(:limit, :integer)
    param(:cursor, :string)
  end

  # Followers of one account that this account also follows.
  defread "graph.getKnownFollowers" do
    param(:actor, {:required, :string})
    param(:limit, :integer)
    param(:cursor, :string)
  end

  defread "graph.getSuggestedFollowsByActor" do
    param(:actor, {:required, :string})
  end

  # The requesting account's own blocks and mutes. Neither takes an actor: the
  # subject is whoever the session belongs to.
  defread "graph.getBlocks" do
    param(:limit, :integer)
    param(:cursor, :string)
  end

  defread "graph.getMutes" do
    param(:limit, :integer)
    param(:cursor, :string)
  end

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

  # The same authenticated GET the DSL generates, with the parameters encoded
  # rather than validated: a declared parameter list cannot describe a repeated
  # key, so these endpoints skip Peri and build the query directly.
  defp repeated_query(session, method, params) do
    base_url = AtMcp.ATProto.DSL.base_url(session)
    url = Path.join(base_url, method)

    query =
      method
      |> Query.new(base_url: base_url)
      |> Map.put(:params, flatten_query(params))

    with {:ok, headers, session} <- ProtoRune.Session.authorization_headers(session, "GET", url) do
      Client.execute(
        %{
          query
          | headers:
              query.headers
              |> Map.merge(headers)
              |> Map.merge(AtMcp.Network.request_headers(method, session))
        },
        session: session
      )
    end
  end

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
    do: DSL.authenticated_procedure(session, "com.atproto.repo.createRecord", @repo_write, params)

  @doc "Write a record at a known rkey, creating or replacing it."
  def put_record(session, params),
    do: DSL.authenticated_procedure(session, "com.atproto.repo.putRecord", @repo_put, params)

  @doc "Delete one record from a repository."
  def delete_record(session, params),
    do:
      DSL.authenticated_procedure(session, "com.atproto.repo.deleteRecord", @repo_delete, params)

  @doc "Read one record out of a repository."
  def get_record(session, params),
    do: DSL.authenticated_query(session, "com.atproto.repo.getRecord", @repo_get, params)

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
