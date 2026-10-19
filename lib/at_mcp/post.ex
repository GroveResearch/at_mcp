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
      langs: get(record, [:langs]),
      tags: get(record, [:tags]),
      facets: facets,
      web_url: AtMcp.WebLink.record(get(source, [:uri]), get(source, [:author, :handle])),
      images: images(embed),
      link: link(embed),
      video: video(embed),
      embed_type: get(embed, [:"$type"]),
      quote: quote_view(quoted(embed), quoted(get(record, [:embed]))),
      reply_rule: reply_rule(get(source, [:threadgate]))
    }
  end

  # Who may reply, from the gate on the post's view, in the words
  # `set_post_interactions` takes. The AppView puts a thread's gate on its
  # first post only; elsewhere there is none to read, which is not "everyone".
  defp reply_rule(gate) when is_map(gate) do
    record = get(gate, [:record]) || %{}

    case get(record, [:allow]) do
      allow when is_list(allow) ->
        AtMcp.Interactions.reply_rule_words(%{
          "allow" =>
            for(
              rule <- allow,
              is_map(rule),
              do: %{"$type" => get(rule, [:"$type"]), "list" => get(rule, [:list])}
            )
        })

      _ ->
        ["everyone"]
    end
  end

  defp reply_rule(_none), do: nil

  @doc """
  What a feed says about a post beside the post itself
  (`app.bsky.feed.defs#feedViewPost`): why it is in the feed, and who the reply
  answers, which the app shows above the post; and the context and request id
  a custom feed gave the item, which feedback on it hands back. Each is nil
  when the feed did not say: a post read anywhere but a feed has none.
  """
  def feed_context(item) do
    %{
      reason: reason(get(item, [:reason])),
      reply_parent: reply_post(get(item, [:reply, :parent])),
      reply_root: reply_post(get(item, [:reply, :root])),
      # What a custom feed's generator said about the item when it served it,
      # which feedback on the item hands back (`feed_feedback`).
      feed_context: string(either(item, [:feed_context], [:feedContext])),
      req_id: string(either(item, [:req_id], [:reqId]))
    }
  end

  defp string(value) when is_binary(value), do: value
  defp string(_value), do: nil

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
      web_url: quote_link(record_kind(type), uri, view),
      record_type: get(value, [:"$type"]) || type
    }

    cond do
      # A blocked quote names its author and where the account stands with
      # them, which the app's moderation reads (`decideBlockedQuotedPost`).
      status == "blocked" ->
        Map.merge(base, %{
          author_did: get(view, [:author, :did]),
          author_viewer: get(view, [:author, :viewer])
        })

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
          indexed_at: get(view, [:indexed_at]) || get(view, [:indexedAt]),
          created_at: get(value, [:created_at]) || get(value, [:createdAt]),
          raw_text: get(value, [:text]),
          langs: get(value, [:langs]),
          tags: get(value, [:tags]),
          text: text,
          facets: facets,
          images: Enum.find_value(embeds, &images/1) || images(raw),
          link: Enum.find_value(embeds, &link/1) || link(raw),
          video: Enum.find_value(embeds, &video/1) || video(raw),
          nested_uri: get(nested, [:uri]),
          # What the app shows on the quote as on any post: its labels, its
          # author's, and where the account stands with the author.
          labels: get(view, [:labels]),
          author_labels: get(view, [:author, :labels]),
          author_viewer: get(view, [:author, :viewer]),
          author_verification: get(view, [:author, :verification]),
          author_status: get(view, [:author, :status])
        })
    end
  end

  # The quoted record's link: a post's names its author by handle when the
  # view has it; a labeler's is its account's profile, where the app shows it.
  defp quote_link("labeler", _uri, view),
    do: AtMcp.WebLink.profile(get(view, [:creator, :handle]), get(view, [:creator, :did]))

  defp quote_link(_kind, uri, view), do: AtMcp.WebLink.record(uri, get(view, [:author, :handle]))

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
  # which is not read. A card the AppView built from standard.site records
  # (`embed.external#viewExternal`) also names the publication, its author,
  # the publish date and the reading time, which the app shows on the card
  # (StandardSiteEmbed in bluesky-social/social-app at 62b95002).
  defp link(embed) do
    case get(media(embed), [:external]) do
      external when is_map(external) ->
        thumb = get(external, [:thumb])
        source = get(external, [:source])

        records =
          for ref <-
                List.wrap(get(external, [:associated_refs]) || get(external, [:associatedRefs])),
              uri = get(ref, [:uri]),
              is_binary(uri),
              do: uri

        %{
          uri: get(external, [:uri]),
          title: get(external, [:title]),
          description: get(external, [:description]),
          thumb: if(is_binary(thumb), do: thumb),
          published_at: either(external, [:created_at], [:createdAt]),
          reading_time: either(external, [:reading_time], [:readingTime]),
          publication:
            if(is_map(source),
              do: %{
                uri: get(source, [:uri]),
                title: get(source, [:title]),
                description: get(source, [:description])
              }
            ),
          author: card_author(external, records),
          records: if(records != [], do: records)
        }

      _ ->
        nil
    end
  end

  # The account the app names on a standard.site card as "by @handle"
  # (StandardSiteMetaRow), found among the card's associated profiles: the
  # owner of its publication record where the card shows the publication, or
  # of its document record where it shows none. The collections are
  # standard.site's own lexicon, which no network rename touches.
  defp card_author(external, records) do
    kind = if is_map(get(external, [:source])), do: "publication", else: "document"

    profiles =
      List.wrap(get(external, [:associated_profiles]) || get(external, [:associatedProfiles]))

    with "at://" <> rest <-
           Enum.find(
             records,
             &String.starts_with?(record_collection(&1) || "", "site.standard." <> kind)
           ),
         [did | _] <- String.split(rest, "/"),
         profile when is_map(profile) <- Enum.find(profiles, &(get(&1, [:did]) == did)) do
      profile
    else
      _ -> nil
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
