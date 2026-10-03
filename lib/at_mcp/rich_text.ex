defmodule AtMcp.RichText do
  @moduledoc """
  Facets, both ways: detect them in text AtMcp is about to publish, and resolve
  the ones a read returned.

  Uses ProtoRune's rich-text builder and the account PDS's handle resolver.
  Unresolvable handles remain plain text and are reported to the caller; a
  resolved mention facet is not a notification-delivery acknowledgement.
  Bare domains and cashtags are not detected. Offsets are UTF-8 bytes.

  `render/2` is the other direction, for a post AtMcp read: a facet's
  destination lives beside the text, not in it, so an agent reading only the
  text cannot tell where a shortened link goes or which account an `@handle`
  is.
  """
  alias ProtoRune.{Atproto.Identity, RichText}

  # Detection boundaries follow the official Bluesky rich-text SDK; unlike its
  # TLD-backed detector, this adapter only recognizes explicit HTTP(S) URLs.
  # https://github.com/bluesky-social/atproto/tree/main/packages/api/src/rich-text
  @mentions ~r/(?:^|\s|\()(@[a-zA-Z0-9.-]+\b)/u
  @links ~r/(?:^|\s|\()(https?:\/\/[^\s]+)/iu
  @tags ~r/(?:^|\s)(#[^\s\x{00AD}\x{2060}\x{200A}-\x{200D}\x{20e2}]+)/u

  def build(text, session, opts \\ []) when is_binary(text) do
    resolver =
      Keyword.get(
        opts,
        :resolve,
        &Identity.resolve_handle(ProtoRune.Session.service_url(session), &1)
      )

    spans =
      (spans(text, @mentions, :mention) ++ spans(text, @links, :link) ++ spans(text, @tags, :tag))
      |> Enum.sort_by(fn {start, _, _} -> start end)

    {rt, offset, _cache, unresolved} =
      Enum.reduce(spans, {RichText.new(), 0, %{}, []}, fn
        {start, _, _}, {_, offset, _, _} = state when start < offset ->
          state

        {start, token, type}, {rt, offset, cache, unresolved} ->
          rt = RichText.text(rt, binary_part(text, offset, start - offset))
          {rt, cache, unresolved} = append(rt, token, type, resolver, cache, unresolved)
          {rt, start + byte_size(token), cache, unresolved}
      end)

    {:ok, record} =
      rt |> RichText.text(binary_part(text, offset, byte_size(text) - offset)) |> RichText.build()

    {record, Enum.reverse(unresolved)}
  end

  @doc """
  Render text that arrived with facets into text a reader can act on, and the
  facets resolved beside it.

  A link facet's span is a display form — often a truncated domain — while the
  destination is in the facet, so the destination is written into the text
  after the span it belongs to. Mention and tag spans already read as
  themselves and are left alone; their DID and tag are returned in the resolved
  list.

  Offsets are UTF-8 bytes, as the lexicon defines them. A facet whose range is
  not a pair of integers inside this text, whose features are not a list, or
  whose feature names no kind AtMcp knows, is dropped and the text is returned
  as it was. A malformed facet from a remote service must degrade to the raw
  post, not raise inside a tool call.
  """
  def render(text, facets) when is_binary(text) do
    resolved =
      facets
      |> List.wrap()
      |> Enum.flat_map(&resolve_facet(&1, text))
      |> Enum.sort_by(& &1.byte_start)
      |> disjoint()

    {expand(text, resolved), Enum.map(resolved, &public/1)}
  end

  def render(_text, _facets), do: {nil, []}

  defp resolve_facet(facet, text) when is_map(facet) do
    index = value(facet, :index)
    features = value(facet, :features)
    start = offset(index, :byte_start, :byteStart)
    stop = offset(index, :byte_end, :byteEnd)

    with true <- is_list(features),
         true <- is_integer(start) and is_integer(stop),
         true <- start >= 0 and stop >= start and stop <= byte_size(text),
         # A range that cuts a character in half would splice invalid UTF-8
         # into the rendered text, which is not a string a result can be
         # encoded from. The facet is dropped instead.
         span when is_binary(span) <- valid_span(text, start, stop),
         feature when is_map(feature) <- Enum.find(features, &is_map/1),
         fields when is_map(fields) <- fields(feature) do
      [Map.merge(fields, %{byte_start: start, byte_end: stop, text: span})]
    else
      _ -> []
    end
  end

  defp resolve_facet(_facet, _text), do: []

  # A feature is read by what it says it is, and by what it carries when it
  # says nothing. The kind is the fragment after `#`, so this reads the
  # configured network's facet types without naming any of them.
  defp fields(feature) do
    uri = string(feature, :uri)
    did = string(feature, :did)
    tag = string(feature, :tag)

    case kind(feature) do
      "mention" when is_binary(did) -> %{type: "mention", did: did}
      "link" when is_binary(uri) -> %{type: "link", uri: uri}
      "tag" when is_binary(tag) -> %{type: "tag", tag: tag}
      nil when is_binary(did) -> %{type: "mention", did: did}
      nil when is_binary(uri) -> %{type: "link", uri: uri}
      nil when is_binary(tag) -> %{type: "tag", tag: tag}
      _ -> nil
    end
  end

  defp kind(feature) do
    case string(feature, :"$type") do
      type when is_binary(type) -> type |> String.split("#") |> List.last()
      _ -> nil
    end
  end

  # Facets may not overlap; one that does is a facet AtMcp cannot place, so it
  # is dropped rather than allowed to cut into the span before it.
  defp disjoint(facets) do
    facets
    |> Enum.reduce({[], 0}, fn facet, {kept, offset} ->
      if facet.byte_start >= offset,
        do: {[facet | kept], facet.byte_end},
        else: {kept, offset}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp expand(text, resolved) do
    {rendered, offset} =
      Enum.reduce(resolved, {"", 0}, fn facet, {acc, offset} ->
        span = binary_part(text, offset, facet.byte_start - offset)
        {acc <> span <> written(facet), facet.byte_end}
      end)

    rendered <> binary_part(text, offset, byte_size(text) - offset)
  end

  # The text is never replaced, only added to: a reader sees what the author
  # wrote plus where the link goes.
  defp written(%{type: "link", uri: uri, text: shown}) when uri != shown,
    do: shown <> " <" <> uri <> ">"

  defp written(%{text: shown}), do: shown

  defp public(facet), do: Map.drop(facet, [:byte_start, :byte_end])

  defp valid_span(text, start, stop) do
    span = binary_part(text, start, stop - start)
    if String.valid?(span), do: span
  end

  defp offset(index, key, alternate) when is_map(index) do
    Enum.find_value([key, alternate], fn name ->
      case value(index, name) do
        value when is_integer(value) -> value
        _ -> nil
      end
    end)
  end

  defp offset(_index, _key, _alternate), do: nil

  defp value(map, key) do
    case AtMcp.Response.fetch(map, key) do
      {:ok, value} -> value
      :error -> nil
    end
  end

  defp string(map, key) do
    case value(map, key) do
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  defp spans(text, regex, type) do
    for [_, {start, length}] <- Regex.scan(regex, text, return: :index),
        token = binary_part(text, start, length),
        token = trim(token, type),
        valid?(token, type),
        do: {start, token, type}
  end

  defp trim(token, :link) do
    token = Regex.replace(~r/[.,;:!?]$/u, token, "")

    if String.ends_with?(token, ")") and not String.contains?(token, "("),
      do: String.trim_trailing(token, ")"),
      else: token
  end

  defp trim(token, :tag), do: Regex.replace(~r/\p{P}+$/u, token, "")
  defp trim(token, _), do: token

  defp valid?("@" <> handle, :mention), do: Identity.valid_handle?(handle)

  defp valid?("#" <> tag, :tag),
    do:
      String.length(tag) in 1..64 and byte_size(tag) <= 640 and
        not String.starts_with?(tag, "\uFE0F") and
        Regex.match?(~r/[^\d\s\p{P}]/u, tag)

  defp valid?(_token, :tag), do: false

  defp valid?(token, :link), do: is_binary(URI.parse(token).host)

  # The upstream builder's `link/3` and `hashtag/2` write `app.bsky.richtext.*`
  # types into the facet, the same way its mention builder does. Every facet
  # AtMcp writes is built here instead, over `AtMcp.Network`.
  defp append(rt, token, :link, _, cache, unresolved),
    do:
      {facet(rt, token, %{"$type": AtMcp.Network.type(:link_facet), uri: token}), cache,
       unresolved}

  defp append(rt, "#" <> tag = token, :tag, _, cache, unresolved),
    do:
      {facet(rt, token, %{"$type": AtMcp.Network.type(:tag_facet), tag: tag}), cache, unresolved}

  defp append(rt, "@" <> handle = token, :mention, resolver, cache, unresolved) do
    key = String.downcase(handle)
    result = Map.get_lazy(cache, key, fn -> resolve(resolver, key) end)
    next_cache = Map.put(cache, key, result)

    case result do
      {:ok, did} ->
        # The upstream mention builder hardcodes the global resolver; this one
        # resolves through the account's own PDS.
        feature = %{"$type": AtMcp.Network.type(:mention_facet), did: did}
        {facet(rt, token, feature), next_cache, unresolved}

      :unresolved ->
        missing = if Map.has_key?(cache, key), do: unresolved, else: [handle | unresolved]
        {RichText.text(rt, token), next_cache, missing}
    end
  end

  # Facets keep the builder's internal shape — snake_case atoms over UTF-8 byte
  # offsets. `AtMcp.ATProto.post_record/1` translates them to the wire's.
  defp facet(rt, token, feature) do
    facet = %{
      index: %{
        byte_start: byte_size(rt.text),
        byte_end: byte_size(rt.text) + byte_size(token)
      },
      features: [feature]
    }

    RichText.text(%{rt | facets: rt.facets ++ [facet]}, token)
  end

  defp resolve(resolver, handle) do
    case resolver.(handle) do
      {:ok, did} when is_binary(did) ->
        if Identity.valid_did?(did), do: {:ok, did}, else: :unresolved

      _ ->
        :unresolved
    end
  rescue
    _ -> :unresolved
  catch
    :exit, _ -> :unresolved
  end
end
