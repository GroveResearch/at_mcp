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
  is not a second mechanism.

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

  @quote [
    {:status, :string, [["status"]],
     "available, not_found, blocked, detached, unhydrated or unsupported"},
    {:uri, :string, [["uri"]], "Quoted record's AT URI"},
    {:record_type, :string, [["record_type"]], "Quoted record or unavailable view type"},
    {:web_url, :string, [["web_url"]], "Quoted post's web permalink"},
    {:author, :string, [["author"]], "Quoted author's handle"},
    {:author_did, :string, [["author_did"]], "Quoted author's DID"},
    {:raw_text, :string, [["raw_text"]], "Exact quoted author's text"},
    {:text, :string, [["text"]], "Quoted text with full link destinations"},
    {:facets, {:list, @facets}, [["facets"]], "Quoted text's normalized facets"},
    {:images, {:list, @image_view}, [["images"]], "Quoted post's image metadata, not pixels"},
    {:nested_uri, :string, [["nested_uri"]], "A further quote; deliberately not expanded"}
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
     "Image alt text and available URLs, not image pixels"},
    {:embed_type, :string, [["perception", "embed_type"]],
     "Embed type, including kinds not otherwise projected"},
    {:quote, {:object, @quote}, [["perception", "quote"]],
     "One attributed quoted record; null when absent"}
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
    post: %{
      fields:
        @content ++
          [
            {:uri, :string, [["uri"]], "AT URI of the post"},
            {:cid, :string, [["cid"]], "CID of the post"},
            {:author, :string, [["author", "handle"]], "Author handle"},
            {:author_did, :string, [["author", "did"]], "Author DID"}
          ],
      viewer: [:like, :repost]
    },
    # One post as an element of a thread chain. A chain element answers
    # different questions than a timeline post: when it was written, what it
    # was a reply to, and what to call its author in a sentence. `:post` has
    # none of those, and none of them belong on a feed item.
    chain_post: %{
      fields:
        @content ++
          [
            {:uri, :string, [["uri"]], "AT URI of the post"},
            {:cid, :string, [["cid"]], "CID of the post"},
            {:author, :string, [["author", "handle"]], "Author handle"},
            {:author_did, :string, [["author", "did"]], "Author DID"},
            {:display_name, :string, [["author", "display_name"], ["author", "displayName"]],
             "Author display name, as the account set it"},
            {:created_at, :string, [["record", "created_at"], ["record", "createdAt"]],
             "When the author wrote it, as an ISO 8601 timestamp"},
            {:reply_to, :string, [["record", "reply", "parent", "uri"]],
             "AT URI of the post this one replies to; null on the root"}
          ],
      viewer: []
    },
    profile: %{
      fields: [
        {:did, :string, [["did"]], "Account DID"},
        {:handle, :string, [["handle"]], "Account handle"},
        {:display_name, :string, [["display_name"], ["displayName"]], "Display name"},
        {:description, :string, [["description"]], "Profile description"},
        {:followers, :integer, [["followers_count"], ["followersCount"]], "Follower count"},
        {:follows, :integer, [["follows_count"], ["followsCount"]], "Following count"},
        {:posts, :integer, [["posts_count"], ["postsCount"]], "Post count"}
      ],
      viewer: [:following, :blocking]
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
    %{fields: fields, viewer: relationships} = Map.fetch!(@shapes, shape)

    source =
      if shape in [:post, :chain_post, :notification],
        do: Map.put(source, "perception", AtMcp.Post.content(source)),
        else: source

    fields
    |> Map.new(fn {key, type, paths, _doc} -> {key, read(source, paths, type)} end)
    |> with_viewer(source, relationships)
  end

  def extract(_shape, other), do: %{value: opaque(other)}

  @doc "JSON Schema properties for one shape, including its viewer references."
  def properties(shape) do
    %{fields: fields, viewer: relationships} = Map.fetch!(@shapes, shape)

    properties =
      Map.new(fields, fn {key, type, _paths, doc} ->
        {Atom.to_string(key), property(type, doc)}
      end)

    if relationships == [],
      do: properties,
      else: Map.put(properties, "viewer", viewer_schema(relationships))
  end

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

  defp project(value, {:object, fields}),
    do: Map.new(fields, fn {key, type, paths, _doc} -> {key, read(value, paths, type)} end)

  defp project(value, _type), do: value

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
  defp with_viewer(summary, _source, []), do: summary

  defp with_viewer(summary, source, relationships) do
    case AtMcp.Response.dig(source, ["viewer"]) do
      viewer when is_map(viewer) ->
        Map.put(summary, :viewer, Enum.reduce(relationships, %{}, &relationship(&2, viewer, &1)))

      _ ->
        summary
    end
  end

  # A relationship the response did not mention is omitted, and an unexpected
  # value is dropped rather than published. An explicit null is retained: the
  # account has no such record, which is different from not being told.
  defp relationship(refs, viewer, key) do
    case AtMcp.Response.fetch(viewer, Atom.to_string(key)) do
      {:ok, "at://" <> _ = uri} -> Map.put(refs, key, uri)
      {:ok, nil} -> Map.put(refs, key, nil)
      _ -> refs
    end
  end

  defp viewer_schema(relationships) do
    %{
      "type" => ["object", "null"],
      "description" =>
        "The viewing account's own relationship records. An absent viewer is not evidence of no relationship.",
      "properties" =>
        Map.new(relationships, fn key ->
          {Atom.to_string(key),
           %{
             "type" => ["string", "null"],
             "description" => "The viewing account's #{key} record AT URI"
           }}
        end)
    }
  end

  defp opaque(value) when is_binary(value), do: value
  defp opaque(value), do: inspect(value, limit: 20)
end
