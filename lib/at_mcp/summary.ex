defmodule AtMcp.Summary do
  @moduledoc """
  The record shapes AtMcp reads out of application responses, declared once.

  Each field names the key an agent receives, the JSON type it receives, the
  response paths to read it from, and what it means. `extract/2` builds the
  summary `AtMcp.Effects.ProtoRune` returns; `properties/1` builds the JSON
  Schema `AtMcp.MCP.Schemas` declares. Both come from one list, so a tool cannot
  describe a field it does not return, or return one it does not describe.

  Paths are tried in order and the first value of the declared type wins, which
  is how one declaration covers responses that arrive with atom keys, snake_case
  string keys or camelCase string keys. A value of another type reads as absent
  rather than as a result that contradicts the declared schema.

  A field's type is `:string`, `:integer`, `:boolean`, `{:object, fields}` or
  `{:list, fields}` — declared the same way, one level down, so a nested shape
  is not a second mechanism. `{:list, fields, :omit_null}` is a list whose
  entries leave out the keys the response did not carry.

  A shape's `viewer` relationships are read from the response's `viewer`, or
  from its `viewer_path` where the view nests them: a list member's are on the
  account, a starter pack's on its list.

  Write and action results are built from what the caller supplied rather than
  read out of a response, so they are not declared here.
  """

  # What an AppView returns for an image on a post it hydrated. These are URLs
  # it already hosts, not blobs to fetch: reading them is surfacing what the
  # response already carried.
  @image_view [
    {:alt, :string, [["alt"]],
     "The image's alt text; an empty string when the author wrote none"},
    {:thumb, :string, [["thumb"]], "URL of the AppView's thumbnail of the image"},
    {:fullsize, :string, [["fullsize"]], "URL of the AppView's full-size copy of the image"},
    {:blob_cid, :string, [["blob_cid"]], "Raw image blob CID when provided"},
    {:mime_type, :string, [["mime_type"]], "Raw image MIME type when provided"},
    {:size, :integer, [["size"]], "Raw image byte count when provided"},
    {:availability, :string, [["availability"]],
     "available URLs or unhydrated raw image reference"}
  ]

  @facets (for {key, doc} <- [
                 type: "link, mention or tag",
                 text: "Authored span",
                 uri: "Full link destination",
                 did: "Mentioned DID",
                 tag: "Hashtag"
               ] do
             {key, :string, [[Atom.to_string(key)]], doc}
           end)

  # A link card as the AppView hydrated it, or as a raw record wrote it.
  @link [
    {:uri, :string, [["uri"]], "The link's destination"},
    {:title, :string, [["title"]], "The card's title"},
    {:description, :string, [["description"]], "The card's description"},
    {:thumb, :string, [["thumb"]], "URL of the AppView's copy of the card's image"}
  ]

  @video [
    {:alt, :string, [["alt"]], "The video's alt text; null or empty when the author wrote none"},
    {:thumbnail, :string, [["thumbnail"]], "URL of the AppView's thumbnail of the video"},
    {:playlist, :string, [["playlist"]], "URL of the AppView's HLS playlist for the video"}
  ]

  @quote [
    {:status, :string, [["status"]],
     "available, not_found, blocked, detached, unhydrated or unsupported"},
    {:kind, :string, [["kind"]],
     "What an available quote is: post, feed, list, starter_pack or labeler"},
    {:uri, :string, [["uri"]], "Quoted record's AT URI"},
    {:record_type, :string, [["record_type"]], "Quoted record or unavailable view type"},
    {:web_url, :string, [["web_url"]], "Quoted post's web permalink"},
    {:author, :string, [["author"]], "Quoted author's handle"},
    {:author_did, :string, [["author_did"]], "Quoted author's DID"},
    {:display_name, :string, [["display_name"]], "Quoted author's display name"},
    {:created_at, :string, [["created_at"]],
     "When the quoted post was written, as an ISO 8601 timestamp"},
    {:raw_text, :string, [["raw_text"]], "Exact quoted author's text"},
    {:text, :string, [["text"]], "Quoted text with full link destinations"},
    {:facets, {:list, @facets}, [["facets"]], "Quoted text's normalized facets"},
    {:images, {:list, @image_view}, [["images"]], "Quoted post's image metadata, not pixels"},
    {:link, {:object, @link}, [["link"]], "Quoted post's link card"},
    {:video, {:object, @video}, [["video"]], "Quoted post's video"},
    {:nested_uri, :string, [["nested_uri"]], "A further quote; deliberately not expanded"},
    {:name, :string, [["name"]], "A quoted feed's, list's or starter pack's name"},
    {:description, :string, [["description"]],
     "A quoted feed's, list's or starter pack's description"},
    {:creator, :string, [["creator"]],
     "Handle of the account that made the quoted feed, list, starter pack or labeler"},
    {:creator_did, :string, [["creator_did"]], "DID of that account"}
  ]

  # A label as the AppView returns it on a post or an account: what it says and
  # who applied it. A label an account applied to itself has its own DID as src.
  # A key the service did not send is left out of the label rather than sent as
  # null: most labels carry neither `neg` nor `exp`.
  @label [
    {:val, :string, [["val"]], "The label's value, such as bot or porn"},
    {:src, :string, [["src"]], "DID of the account or labeler that applied it"},
    {:neg, :boolean, [["neg"]], "True when this label removes an earlier one"},
    {:exp, :string, [["exp"]], "When the label expires, as an ISO 8601 timestamp"}
  ]

  # The viewing account's relationship, read from a response's `viewer`. Each
  # entry names the key an agent receives, what kind of value it is, the keys
  # the service may send it under, and what it means. A `:record` is the AT URI
  # of the account's own record (the uri an undo tool takes), a `:list` is the
  # AT URI of the list a relationship comes through, and a `:boolean` is a state
  # the service reports that has no record of this account's behind it.
  @post_viewer [
    {:like, :record, ["like"], "The viewing account's like record AT URI"},
    {:repost, :record, ["repost"], "The viewing account's repost record AT URI"},
    {:reply_disabled, :boolean, ["replyDisabled", "reply_disabled"],
     "True when the service says the viewing account cannot reply to this post"},
    {:embedding_disabled, :boolean, ["embeddingDisabled", "embedding_disabled"],
     "True when the service says the viewing account cannot quote this post"},
    {:thread_muted, :boolean, ["threadMuted", "thread_muted"],
     "True when the viewing account has muted this post's thread"}
  ]

  @actor_viewer [
    {:following, :record, ["following"], "The viewing account's follow record AT URI"},
    {:followed_by, :record, ["followedBy", "followed_by"],
     "AT URI of their follow record for the viewing account"},
    {:blocking, :record, ["blocking"], "The viewing account's block record AT URI"},
    {:blocking_by_list, :list, ["blockingByList", "blocking_by_list"],
     "AT URI of the moderation list through which the viewing account blocks them"},
    {:blocked_by, :boolean, ["blockedBy", "blocked_by"],
     "True when they block the viewing account"},
    {:muted, :boolean, ["muted"], "True when the viewing account has muted them"},
    {:muted_by_list, :list, ["mutedByList", "muted_by_list"],
     "AT URI of the moderation list through which the viewing account mutes them"}
  ]

  # Computed content is declared once for reads, chains and notifications.
  @content [
    {:text, :string, [["perception", "text"]], "Post text with full link destinations"},
    {:raw_text, :string, [["perception", "raw_text"]],
     "Exact author text, without appended observations"},
    {:facets, {:list, @facets}, [["perception", "facets"]],
     "Normalized link, mention and tag destinations"},
    {:web_url, :string, [["perception", "web_url"]],
     "Web permalink; the AT URI remains canonical"},
    {:images, {:list, @image_view}, [["perception", "images"]],
     "Image alt text and available URLs, not image pixels; a gallery's images too"},
    {:link, {:object, @link}, [["perception", "link"]], "The post's link card; null when absent"},
    {:video, {:object, @video}, [["perception", "video"]], "The post's video; null when absent"},
    {:embed_type, :string, [["perception", "embed_type"]],
     "Embed type, including kinds not otherwise projected"},
    {:quote, {:object, @quote}, [["perception", "quote"]],
     "One attributed quoted record: a post, feed, list, starter pack or labeler; null when absent"}
  ]

  # Why a feed shows a post, read from the feed item around it
  # (`AtMcp.Post.feed_context/1`).
  @reason [
    {:type, :string, [["type"]],
     "repost or pin; another value is a reason type this version does not read"},
    {:by, :string, [["by"]], "Handle of the account that reposted it"},
    {:by_did, :string, [["by_did"]], "DID of the account that reposted it"},
    {:by_display_name, :string, [["by_display_name"]],
     "Display name of the account that reposted it"},
    {:at, :string, [["at"]], "When it was reposted, as an ISO 8601 timestamp"},
    {:uri, :string, [["uri"]],
     "AT URI of the repost record; `unrepost` takes it when the repost is the account's own"}
  ]

  # The post a reply in a feed answers, or its thread's root.
  @reply_post [
    {:status, :string, [["status"]],
     "available, not_found, blocked, or unsupported for a view this version does not read"},
    {:uri, :string, [["uri"]], "AT URI of the post"},
    {:author, :string, [["author"]], "Author handle"},
    {:author_did, :string, [["author_did"]], "Author DID"},
    {:display_name, :string, [["display_name"]], "Author display name"}
  ]

  @post [
    {:uri, :string, [["uri"]], "AT URI of the post"},
    {:cid, :string, [["cid"]], "CID of the post"},
    {:author, :string, [["author", "handle"]], "Author handle"},
    {:author_did, :string, [["author", "did"]], "Author DID"},
    {:display_name, :string, [["author", "display_name"], ["author", "displayName"]],
     "Author display name, as the account set it"},
    {:created_at, :string, [["record", "created_at"], ["record", "createdAt"]],
     "When the author wrote it, as an ISO 8601 timestamp"},
    {:reply_to, :string, [["record", "reply", "parent", "uri"]],
     "AT URI of the post this one replies to; null on the root"},
    {:reason, {:object, @reason}, [["feed_context", "reason"]],
     "Why a feed shows this post: someone reposted it, or the author pinned it. Null when it is there as a post, and outside feeds"},
    {:reply_parent, {:object, @reply_post}, [["feed_context", "reply_parent"]],
     "Who the reply answers, as the feed reported it. Null on a root post and outside feeds"},
    {:reply_root, {:object, @reply_post}, [["feed_context", "reply_root"]],
     "The root of the reply's thread, as the feed reported it. Null on a root post and outside feeds"},
    {:like_count, :integer, [["like_count"], ["likeCount"]],
     "How many likes the service counts on the post"},
    {:repost_count, :integer, [["repost_count"], ["repostCount"]],
     "How many reposts the service counts on the post"},
    {:reply_count, :integer, [["reply_count"], ["replyCount"]],
     "How many replies the service counts to the post"},
    {:quote_count, :integer, [["quote_count"], ["quoteCount"]],
     "How many posts the service counts quoting the post"},
    {:labels, {:list, @label, :omit_null}, [["labels"]],
     "Labels on the post, as the service returned them"},
    {:author_labels, {:list, @label, :omit_null}, [["author", "labels"]],
     "Labels on the author's account, including any it applied to itself"}
  ]

  # The viewing account's relationship to a list: a mute or block of the
  # accounts on it, and its own opt-out from a starter pack's list.
  @list_viewer [
    {:muted, :boolean, ["muted"],
     "True when the viewing account mutes the accounts on this list"},
    {:blocked, :record, ["blocked"],
     "AT URI of the viewing account's block of the accounts on this list"},
    {:opted_out, :record, ["referenceListOptOut", "reference_list_opt_out"],
     "AT URI of the viewing account's opt-out from this starter pack's list; set_list_opt_out with opted_out false deletes it"}
  ]

  # A feed a starter pack recommends, as its view hydrates it or its record
  # names it.
  @pack_feed [
    {:uri, :string, [["uri"]], "AT URI of the feed generator; get_feed takes it"},
    {:display_name, :string, [["display_name"], ["displayName"]], "Feed display name"},
    {:creator, :string, [["creator", "handle"]], "Handle of the account that made the feed"}
  ]

  @pack_member [
    {:did, :string, [["subject", "did"]], "Account DID"},
    {:handle, :string, [["subject", "handle"]], "Account handle"},
    {:display_name, :string, [["subject", "display_name"], ["subject", "displayName"]],
     "Display name"}
  ]

  @shapes %{
    membership: %{
      fields: [
        {:enabled, :boolean, [["enabled"]], "Whether this network admits accounts by membership"},
        {:membership,
         {:object,
          [
            {:did, :string, [["did"]], "Account DID"},
            {:status, :string, [["status"]], "active or withdrawn"},
            {:suspended, :boolean, [["suspended"]], "Whether participation is suspended"},
            {:revision, :integer, [["revision"]], "Membership revision"},
            {:joined, :boolean, [["joined"]], "Whether this account has joined"}
          ]}, [["membership"]], "Account membership, or null if none exists"}
      ],
      viewer: []
    },
    # A post wherever it is read: in a feed, a thread or a chain. A reader of
    # any of them needs who wrote it, when, and what it answers, as every
    # client shows on each post; the chain adds only its own flags beside these.
    post: %{fields: @content ++ @post, viewer: @post_viewer, author_viewer: @actor_viewer},
    chain_post: %{fields: @content ++ @post, viewer: [], author_viewer: @actor_viewer},
    profile: %{
      fields: [
        {:did, :string, [["did"]], "Account DID"},
        {:handle, :string, [["handle"]], "Account handle"},
        {:display_name, :string, [["display_name"], ["displayName"]], "Display name"},
        {:description, :string, [["description"]], "Profile description"},
        {:followers, :integer, [["followers_count"], ["followersCount"]], "Follower count"},
        {:follows, :integer, [["follows_count"], ["followsCount"]], "Following count"},
        {:posts, :integer, [["posts_count"], ["postsCount"]], "Post count"},
        {:labels, {:list, @label, :omit_null}, [["labels"]],
         "Labels on the account, including any it applied to itself"}
      ],
      viewer: @actor_viewer
    },
    generator: %{
      fields: [
        {:uri, :string, [["uri"]], "AT URI of the feed generator record"},
        {:cid, :string, [["cid"]], "CID of the feed generator record"},
        {:did, :string, [["did"]], "DID of the feed generator service"},
        {:display_name, :string, [["display_name"], ["displayName"]], "Feed display name"},
        {:description, :string, [["description"]], "Feed description"},
        {:creator, :string, [["creator", "handle"]], "Creator handle"},
        {:creator_did, :string, [["creator", "did"]], "Creator DID"},
        {:like_count, :integer, [["like_count"], ["likeCount"]],
         "How many accounts like this feed"},
        {:indexed_at, :string, [["indexed_at"], ["indexedAt"]],
         "When the service indexed this generator, as an ISO 8601 timestamp"}
      ],
      viewer: [{:like, :record, ["like"], "The viewing account's like record AT URI"}]
    },
    # A list as the service shows it: `graph.defs#listView`, and the basic
    # view a starter pack carries. `purpose` is read as the token's name;
    # `AtMcp.Effects.ProtoRune` says it in the words the list tools take.
    list: %{
      fields: [
        {:uri, :string, [["uri"]], "AT URI of the list record"},
        {:cid, :string, [["cid"]], "CID of the list record"},
        {:name, :string, [["name"]], "The list's name"},
        {:purpose, :string, [["purpose"]],
         "curate, moderation or reference (a starter pack's list); another value is a purpose this version does not name"},
        {:description, :string, [["description"]], "The list's description"},
        {:creator, :string, [["creator", "handle"]], "Handle of the account that made the list"},
        {:creator_did, :string, [["creator", "did"]], "DID of the account that made the list"},
        {:creator_display_name, :string,
         [["creator", "display_name"], ["creator", "displayName"]],
         "Display name of the account that made the list"},
        {:item_count, :integer, [["list_item_count"], ["listItemCount"]],
         "How many accounts are on the list, as the service counts them"},
        {:labels, {:list, @label, :omit_null}, [["labels"]],
         "Labels on the list, as the service returned them"}
      ],
      viewer: @list_viewer
    },
    # One account on a list: `graph.defs#listItemView`, the account and the
    # list item record that puts it there.
    list_member: %{
      fields: [
        {:item_uri, :string, [["uri"]],
         "AT URI of the list item record that puts this account on the list"},
        {:did, :string, [["subject", "did"]], "Account DID"},
        {:handle, :string, [["subject", "handle"]], "Account handle"},
        {:display_name, :string, [["subject", "display_name"], ["subject", "displayName"]],
         "Display name"},
        {:description, :string, [["subject", "description"]], "Profile description"},
        {:labels, {:list, @label, :omit_null}, [["subject", "labels"]],
         "Labels on the account, including any it applied to itself"},
        {:opted_out, :boolean, [["subject_opted_out"], ["subjectOptedOut"]],
         "True when the account asked to be left out of this starter pack's list; only its owner is told"}
      ],
      viewer: @actor_viewer,
      viewer_path: ["subject", "viewer"]
    },
    # A starter pack: `graph.defs#starterPackView`, or the basic view a list
    # of packs carries, which has no feeds or sample of its accounts.
    starter_pack: %{
      fields: [
        {:uri, :string, [["uri"]], "AT URI of the starter pack record"},
        {:cid, :string, [["cid"]], "CID of the starter pack record"},
        {:name, :string, [["record", "name"]], "The starter pack's name"},
        {:description, :string, [["record", "description"]], "The starter pack's description"},
        {:created_at, :string, [["record", "created_at"], ["record", "createdAt"]],
         "When it was made, as an ISO 8601 timestamp"},
        {:list, :string, [["list", "uri"], ["record", "list"]],
         "AT URI of its list of accounts; get_list reads every one, add_to_list and remove_from_list take it or the pack's uri"},
        {:creator, :string, [["creator", "handle"]], "Handle of the account that made it"},
        {:creator_did, :string, [["creator", "did"]], "DID of the account that made it"},
        {:creator_display_name, :string,
         [["creator", "display_name"], ["creator", "displayName"]],
         "Display name of the account that made it"},
        {:item_count, :integer,
         [
           ["list", "list_item_count"],
           ["list", "listItemCount"],
           ["list_item_count"],
           ["listItemCount"]
         ], "How many accounts are in it, as the service counts them"},
        {:joined_week_count, :integer, [["joined_week_count"], ["joinedWeekCount"]],
         "How many accounts joined the network through it in the last week"},
        {:joined_all_time_count, :integer, [["joined_all_time_count"], ["joinedAllTimeCount"]],
         "How many accounts joined the network through it"},
        {:feeds, {:list, @pack_feed}, [["feeds"], ["record", "feeds"]],
         "The feeds it recommends, at most 3"},
        {:members_sample, {:list, @pack_member}, [["list_items_sample"], ["listItemsSample"]],
         "Up to 12 of its accounts, as the service chose them; get_list with `list` reads them all. Null in a list of starter packs"},
        {:labels, {:list, @label, :omit_null}, [["labels"]],
         "Labels on the starter pack, as the service returned them"}
      ],
      viewer: Enum.filter(@list_viewer, &(elem(&1, 0) == :opted_out)),
      viewer_path: ["list", "viewer"]
    },
    relationship: %{
      fields: [
        {:did, :string, [["did"]], "The other account's DID"},
        {:following, :string, [["following"]],
         "AT URI of this account's follow record for the other account; null when it does not follow"},
        {:followed_by, :string, [["followed_by"], ["followedBy"]],
         "AT URI of the other account's follow record for this account; null when it does not follow back"},
        {:not_found, :boolean, [["not_found"], ["notFound"]],
         "True when the service could not resolve the account at all"}
      ],
      viewer: []
    },
    notification: %{
      fields:
        @content ++
          [
            {:reason, :string, [["reason"]], "Why this notification was delivered"},
            {:uri, :string, [["uri"]], "AT URI of the notification record"},
            {:cid, :string, [["cid"]], "CID of the notification record"},
            {:indexed_at, :string, [["indexed_at"], ["indexedAt"]],
             "When the service indexed this notification, as an ISO 8601 timestamp"},
            {:subject_uri, :string, [["reason_subject"], ["reasonSubject"]],
             "AT URI of the record this activity addresses, when provided"},
            {:reply_parent_uri, :string, [["record", "reply", "parent", "uri"]],
             "AT URI of the immediate parent of a reply"},
            {:reply_root_uri, :string, [["record", "reply", "root", "uri"]],
             "AT URI of the root of a reply thread"},
            {:author, :string, [["author", "handle"], ["author"]], "Author handle"},
            {:author_did, :string, [["author", "did"]], "Author DID"},
            {:is_read, :boolean, [["is_read"], ["isRead"]], "Whether the account has seen it"}
          ],
      viewer: []
    }
  }

  @doc "The shapes declared here."
  def shapes, do: Map.keys(@shapes)

  @doc """
  Build one summary record from an application response.

  A response that is not a map has no declared fields to read; it is retained
  as an opaque value rather than reported as an empty record.
  """
  def extract(shape, source) when is_map(source) do
    %{fields: fields, viewer: relationships} = declared = Map.fetch!(@shapes, shape)

    source =
      if shape in [:post, :chain_post, :notification],
        do: Map.put(source, "perception", AtMcp.Post.content(source)),
        else: source

    fields
    |> Map.new(fn {key, type, paths, _doc} -> {key, read(source, paths, type)} end)
    |> with_viewer(:viewer, source, Map.get(declared, :viewer_path, ["viewer"]), relationships)
    |> with_viewer(:author_viewer, source, ["author", "viewer"], author_viewer(declared))
  end

  def extract(_shape, other), do: %{value: opaque(other)}

  @doc "JSON Schema properties for one shape, including its viewer relationships."
  def properties(shape) do
    %{fields: fields, viewer: relationships} = declared = Map.fetch!(@shapes, shape)

    fields
    |> Map.new(fn {key, type, _paths, doc} -> {Atom.to_string(key), property(type, doc)} end)
    |> with_viewer_schema(
      "viewer",
      "The viewing account's relationship to this, as the service reported it",
      relationships
    )
    |> with_viewer_schema(
      "author_viewer",
      "The viewing account's relationship to the author, as the service reported it",
      author_viewer(declared)
    )
  end

  defp author_viewer(declared), do: Map.get(declared, :author_viewer, [])

  # The first path holding a value of the declared type wins. `false` is such a
  # value: `is_read: false` means unread, and reading it through `||` fallbacks
  # would publish it as null — a record claiming not to know what it knew.
  defp read(source, paths, type) do
    Enum.reduce_while(paths, nil, fn path, absent ->
      value = AtMcp.Response.dig(source, path)
      if matches?(value, type), do: {:halt, project(value, type)}, else: {:cont, absent}
    end)
  end

  defp matches?(value, {:object, _fields}), do: is_map(value)
  defp matches?(value, {:list, _fields}), do: is_list(value)
  defp matches?(value, {:list, _fields, :omit_null}), do: is_list(value)
  defp matches?(value, :string), do: is_binary(value)
  defp matches?(value, :integer), do: is_integer(value)
  defp matches?(value, :boolean), do: is_boolean(value)

  # A nested shape is read by the same rule as a top-level one. An entry that is
  # not a map has no declared fields to read and is dropped rather than
  # published as a record whose every field is null.
  defp project(values, {:list, fields}) do
    values
    |> Enum.filter(&is_map/1)
    |> Enum.map(fn value ->
      Map.new(fields, fn {key, type, paths, _doc} -> {key, read(value, paths, type)} end)
    end)
  end

  defp project(values, {:list, fields, :omit_null}) do
    values
    |> project({:list, fields})
    |> Enum.map(fn entry -> Map.reject(entry, fn {_key, value} -> is_nil(value) end) end)
  end

  defp project(value, {:object, fields}),
    do: Map.new(fields, fn {key, type, paths, _doc} -> {key, read(value, paths, type)} end)

  defp project(value, _type), do: value

  defp property({:list, fields, :omit_null}, doc), do: property({:list, fields}, doc)

  defp property({:list, fields}, doc) do
    %{
      "type" => ["array", "null"],
      "description" => doc,
      "items" => %{
        "type" => "object",
        "properties" =>
          Map.new(fields, fn {key, type, _paths, doc} ->
            {Atom.to_string(key), property(type, doc)}
          end)
      }
    }
  end

  defp property({:object, fields}, doc) do
    %{
      "type" => ["object", "null"],
      "description" => doc,
      "properties" =>
        Map.new(fields, fn {key, type, _paths, desc} ->
          {Atom.to_string(key), property(type, desc)}
        end)
    }
  end

  defp property(type, doc), do: %{"type" => [json_type(type), "null"], "description" => doc}

  defp json_type(:string), do: "string"
  defp json_type(:integer), do: "integer"
  defp json_type(:boolean), do: "boolean"

  # An omitted viewer stays omitted: a public response is not evidence that the
  # authenticated account has no relationship with this record.
  defp with_viewer(summary, _key, _source, _path, []), do: summary

  defp with_viewer(summary, key, source, path, relationships) do
    case AtMcp.Response.dig(source, path) do
      viewer when is_map(viewer) ->
        Map.put(summary, key, Enum.reduce(relationships, %{}, &relationship(&2, viewer, &1)))

      _ ->
        summary
    end
  end

  # A relationship the response did not mention is omitted, and an unexpected
  # value is dropped rather than published. An explicit null is retained: the
  # account has no such record, which is different from not being told.
  defp relationship(refs, viewer, {key, kind, names, _doc}) do
    sent =
      Enum.find_value(names, fn name ->
        case AtMcp.Response.fetch(viewer, name) do
          {:ok, value} -> {value}
          :error -> nil
        end
      end)

    case sent do
      {nil} -> Map.put(refs, key, nil)
      {value} -> keep(refs, key, kind, value)
      nil -> refs
    end
  end

  defp keep(refs, key, :record, "at://" <> _ = uri), do: Map.put(refs, key, uri)
  defp keep(refs, key, :boolean, value) when is_boolean(value), do: Map.put(refs, key, value)

  defp keep(refs, key, :list, list) when is_map(list) do
    case AtMcp.Response.dig(list, ["uri"]) do
      "at://" <> _ = uri -> Map.put(refs, key, uri)
      _ -> refs
    end
  end

  defp keep(refs, _key, _kind, _value), do: refs

  defp with_viewer_schema(properties, _name, _description, []), do: properties

  defp with_viewer_schema(properties, name, description, relationships) do
    Map.put(properties, name, %{
      "type" => ["object", "null"],
      "description" =>
        description <>
          ". Absent when the service gave none, which is not evidence of no relationship.",
      "properties" =>
        Map.new(relationships, fn {key, kind, _names, doc} ->
          type = if kind == :boolean, do: "boolean", else: "string"
          {Atom.to_string(key), %{"type" => [type, "null"], "description" => doc}}
        end)
    })
  end

  defp opaque(value) when is_binary(value), do: value
  defp opaque(value), do: inspect(value, limit: 20)
end
