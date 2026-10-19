defmodule AtMcp.Post do
  @moduledoc """
  Read the content already present in a post response. No fetches, blob URL
  guesses or recursive quote hydration: one quoted post is shown, and its next
  quote remains a reference. Summary owns the public shape and schema.
  """
  alias AtMcp.{Network, Response, RichText}

  def content(source) do
    record = get(source, [:record]) || %{}
    {text, facets} = RichText.render(get(record, [:text]), get(record, [:facets]))
    embed = get(source, [:embed]) || get(record, [:embed])

    %{
      text: text,
      raw_text: get(record, [:text]),
      facets: facets,
      web_url: Network.post_url(get(source, [:uri])),
      images: images(embed),
      embed_type: get(embed, [:"$type"]),
      quote: quote_view(quoted(embed), quoted(get(record, [:embed])))
    }
  end

  @doc """
  What a feed says about a post beside the post itself
  (`app.bsky.feed.defs#feedViewPost`): why it is in the feed, and who the reply
  answers. The app shows both above the post. Each is nil when the feed did not
  say: a post read anywhere but a feed has neither.
  """
  def feed_context(item) do
    %{
      reason: reason(get(item, [:reason])),
      reply_parent: reply_post(get(item, [:reply, :parent])),
      reply_root: reply_post(get(item, [:reply, :root]))
    }
  end

  defp reason(reason) when is_map(reason) do
    type = get(reason, [:"$type"])

    cond do
      type == Network.type(:reason_repost) ->
        %{
          type: "repost",
          by: get(reason, [:by, :handle]),
          by_did: get(reason, [:by, :did]),
          by_display_name: either(reason, [:by, :display_name], [:by, :displayName]),
          at: either(reason, [:indexed_at], [:indexedAt]),
          uri: get(reason, [:uri])
        }

      type == Network.type(:reason_pin) ->
        %{type: "pin"}

      # A reason this version does not know is still a reason: its type is
      # kept so a reader can tell the post did not arrive on its own.
      is_binary(type) ->
        %{type: type}

      true ->
        nil
    end
  end

  defp reason(_none), do: nil

  # The parent or root of a reply in a feed is a full post view, or a
  # `notFoundPost` / `blockedPost` carrying its uri (and, when blocked, the
  # author's DID). The union's `$type` decides; a member this version does not
  # know is `unsupported`, not a post. A view without `$type` is read by its
  # flags.
  defp reply_post(post) when is_map(post) do
    type = get(post, [:"$type"])

    status =
      cond do
        type == Network.type(:post_view) -> "available"
        type == Network.type(:not_found_post) -> "not_found"
        type == Network.type(:blocked_post) -> "blocked"
        is_binary(type) -> "unsupported"
        get(post, [:not_found]) == true or get(post, [:notFound]) == true -> "not_found"
        get(post, [:blocked]) == true -> "blocked"
        true -> "available"
      end

    %{
      status: status,
      uri: get(post, [:uri]),
      author: get(post, [:author, :handle]),
      author_did: get(post, [:author, :did]),
      display_name: either(post, [:author, :display_name], [:author, :displayName])
    }
  end

  defp reply_post(_none), do: nil

  defp either(source, snake, camel), do: get(source, snake) || get(source, camel)

  defp quoted(embed) do
    case get(embed, [:"$type"]) do
      type when is_binary(type) ->
        cond do
          type in [Network.type(:embed_record), Network.type(:embed_record) <> "#view"] ->
            get(embed, [:record])

          type in [
            Network.type(:embed_record_with_media),
            Network.type(:embed_record_with_media) <> "#view"
          ] ->
            get(embed, [:record, :record])

          true ->
            nil
        end

      _ ->
        nil
    end
  end

  defp quote_view(nil, nil), do: nil

  defp quote_view(view, raw) do
    view = view || raw
    uri = get(view, [:uri]) || get(raw, [:uri])
    type = get(view, [:"$type"])
    value = get(view, [:value])

    status =
      cond do
        type == Network.type(:embed_record) <> "#viewNotFound" ->
          "not_found"

        type == Network.type(:embed_record) <> "#viewBlocked" ->
          "blocked"

        type == Network.type(:embed_record) <> "#viewDetached" ->
          "detached"

        type == Network.type(:embed_record) <> "#viewRecord" and
            get(value, [:"$type"]) == Network.collection(:post) ->
          "available"

        is_nil(type) and is_binary(uri) ->
          "unhydrated"

        true ->
          "unsupported"
      end

    base = %{
      status: status,
      uri: uri,
      web_url: Network.post_url(uri),
      record_type: get(value, [:"$type"]) || type
    }

    if status == "available" do
      {text, facets} = RichText.render(get(value, [:text]), get(value, [:facets]))
      embeds = get(view, [:embeds])
      hydrated_images = if is_list(embeds), do: Enum.find_value(embeds, &images/1)
      nested = quoted(get(value, [:embed]))

      Map.merge(base, %{
        author: get(view, [:author, :handle]),
        author_did: get(view, [:author, :did]),
        raw_text: get(value, [:text]),
        text: text,
        facets: facets,
        images: hydrated_images || images(get(value, [:embed])),
        nested_uri: get(nested, [:uri])
      })
    else
      base
    end
  end

  defp images(embed) do
    entries = get(embed, [:images]) || get(embed, [:media, :images])

    if is_list(entries) do
      for entry <- entries, is_map(entry) do
        thumb = get(entry, [:thumb])
        fullsize = get(entry, [:fullsize])
        blob = get(entry, [:image])
        ref = get(blob, [:ref])
        cid = if is_binary(ref), do: ref, else: get(ref, [:"$link"])

        %{
          alt: get(entry, [:alt]),
          thumb: thumb,
          fullsize: fullsize,
          blob_cid: cid,
          mime_type: get(blob, [:mimeType]) || get(blob, [:mime_type]),
          size: get(blob, [:size]),
          availability:
            if(is_binary(thumb) or is_binary(fullsize), do: "available", else: "unhydrated")
        }
      end
    end
  end

  defp get(source, path), do: Response.dig(source, path)
end
