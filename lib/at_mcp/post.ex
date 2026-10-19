defmodule AtMcp.Post do
  @moduledoc """
  Read the content already present in a post response. No fetches, blob URL
  guesses or recursive quote hydration: one quoted record is shown, and a quoted
  post's own quote remains a reference. What is attached is read the way the
  app shows it: images (a gallery's too) by alt text, a link card, a video by
  its alt text, and a quoted post, feed, list, starter pack or labeler. Summary
  owns the public shape and schema.
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
      link: link(embed),
      video: video(embed),
      embed_type: get(embed, [:"$type"]),
      quote: quote_view(quoted(embed), quoted(get(record, [:embed])))
    }
  end

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

        is_binary(record_kind(type)) ->
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

    cond do
      status != "available" ->
        base

      kind = record_kind(type) ->
        Map.merge(base, record_card(kind, view))

      true ->
        {text, facets} = RichText.render(get(value, [:text]), get(value, [:facets]))
        embeds = List.wrap(get(view, [:embeds]))
        raw = get(value, [:embed])
        nested = quoted(raw)

        Map.merge(base, %{
          kind: "post",
          author: get(view, [:author, :handle]),
          author_did: get(view, [:author, :did]),
          display_name: get(view, [:author, :display_name]) || get(view, [:author, :displayName]),
          created_at: get(value, [:created_at]) || get(value, [:createdAt]),
          raw_text: get(value, [:text]),
          text: text,
          facets: facets,
          images: Enum.find_value(embeds, &images/1) || images(raw),
          link: Enum.find_value(embeds, &link/1) || link(raw),
          video: Enum.find_value(embeds, &video/1) || video(raw),
          nested_uri: get(nested, [:uri])
        })
    end
  end

  # A quoted record that is not a post: the AppView hydrates a feed, list,
  # starter pack or labeler into its own view, and the app shows it as a card.
  defp record_kind(type) do
    cond do
      type == Network.type(:generator_view) -> "feed"
      type == Network.type(:list_view) -> "list"
      type == Network.type(:starter_pack_view) -> "starter_pack"
      type == Network.type(:labeler_view) -> "labeler"
      true -> nil
    end
  end

  # A feed and a list carry their name and description in the view; a starter
  # pack carries them in its record; a labeler is named by the account that
  # runs it, so it has no name of its own here.
  defp record_card(kind, view) do
    named = if kind == "starter_pack", do: get(view, [:record]), else: view

    %{
      kind: kind,
      record_type: record_collection(get(view, [:uri])),
      name: get(named, [:display_name]) || get(named, [:displayName]) || get(named, [:name]),
      description: get(named, [:description]),
      creator: get(view, [:creator, :handle]),
      creator_did: get(view, [:creator, :did])
    }
  end

  defp record_collection("at://" <> rest) do
    case String.split(rest, "/") do
      [_repo, collection | _] -> collection
      _ -> nil
    end
  end

  defp record_collection(_uri), do: nil

  # The embed itself, or the media beside a quote.
  defp media(embed) do
    case get(embed, [:media]) do
      media when is_map(media) -> media
      _ -> embed
    end
  end

  # A link card. The hydrated view's `thumb` is a URL; a raw record's is a blob,
  # which is not read.
  defp link(embed) do
    case get(media(embed), [:external]) do
      external when is_map(external) ->
        thumb = get(external, [:thumb])

        %{
          uri: get(external, [:uri]),
          title: get(external, [:title]),
          description: get(external, [:description]),
          thumb: if(is_binary(thumb), do: thumb)
        }

      _ ->
        nil
    end
  end

  # A video: its alt text, and the AppView's thumbnail and playlist URLs when
  # it hydrated them. A raw record has the alt text only.
  defp video(embed) do
    media = media(embed)

    if get(media, [:"$type"]) in [
         Network.type(:embed_video),
         Network.type(:embed_video) <> "#view"
       ] do
      %{
        alt: get(media, [:alt]),
        thumbnail: get(media, [:thumbnail]),
        playlist: get(media, [:playlist])
      }
    end
  end

  # Images, and a gallery's items, which are images under another key whose
  # thumbnail is `thumbnail` rather than `thumb`.
  defp images(embed) do
    media = media(embed)

    gallery =
      get(media, [:"$type"]) in [
        Network.type(:embed_gallery),
        Network.type(:embed_gallery) <> "#view"
      ]

    entries = if gallery, do: get(media, [:items]), else: get(media, [:images])

    # A gallery item is a union; only its image members are images.
    image_types = [
      Network.type(:embed_gallery) <> "#viewImage",
      Network.type(:embed_gallery) <> "#image"
    ]

    if is_list(entries) do
      for entry <- entries,
          is_map(entry),
          not gallery or get(entry, [:"$type"]) in image_types do
        thumb = get(entry, [:thumb]) || get(entry, [:thumbnail])
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
