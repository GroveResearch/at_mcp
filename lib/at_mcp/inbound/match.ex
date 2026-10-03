defmodule AtMcp.Inbound.Match do
  @moduledoc """
  Pure inbound filter for repository commit events.

  A reply/mention/quote aimed at DID D is almost always a commit in *another*
  repo. `wanted_dids: [D]` therefore cannot be the inbox. This module inspects
  post records (and like/repost subjects when present) and returns which
  tracked DIDs were addressed.

  ## Match reasons

  - `:mention` — a richtext mention facet naming our DID
  - `:reply` — `reply.parent` / `reply.root` AT-URI repo is our DID
  - `:quote` — embed record / recordWithMedia AT-URI repo is our DID
  - `:like` — a like record whose subject AT-URI repo is our DID
  - `:repost` — a repost record whose subject AT-URI repo is our DID
  - `:own_repo` — commit author DID is tracked (optional outbound echo)
  """

  # The reasons whose record is a post, and so the only ones that carry a thread.
  # A like or a repost record is not a post: its uri names the like or the repost.
  @post_reasons [:mention, :reply, :quote]
  @post_reason_strings Enum.map(@post_reasons, &Atom.to_string/1)

  @doc """
  The match reasons whose record is a post.

  Both collectors gate thread context on this one list, so the two cannot drift
  apart: `AtMcp.Inbound` holds reason atoms, `AtMcp.Notifications` holds the
  reason strings the application returns.
  """
  def post_reasons, do: @post_reasons

  @doc "Whether a reason, as an atom or as the application's string, carries a post."
  def post_reason?(reason) when is_atom(reason), do: reason in @post_reasons
  def post_reason?(reason) when is_binary(reason), do: reason in @post_reason_strings
  def post_reason?(_), do: false

  @doc """
  The AT URI of the record this record addresses, read from the record itself.

  This is the repo-commit counterpart of a notification's `reasonSubject`: the
  liked or reposted post for a like or a repost, the quoted post for a quote.
  `nil` when the record addresses nothing.
  """
  def subject_uri(collection, record) when is_map(record) do
    cond do
      collection == AtMcp.Network.collection(:like) -> subject_ref_uri(record)
      collection == AtMcp.Network.collection(:repost) -> subject_ref_uri(record)
      true -> embed_record_uri(record)
    end
  end

  def subject_uri(_collection, _record), do: nil

  @doc """
  The thread a host should read to answer, for one delivered event.

  Only a reason whose record is a post carries a thread: a like or a repost's
  uri is the like or repost itself, so publishing it as a thread root would send
  the host to fetch a record that is not a post. For those, and for an own-repo
  echo, this is `%{}`.

  A reply's root is the thread it belongs to. A record may declare a parent and
  no root, and then the parent is the nearest ancestor known to be in the
  thread. A top-level mention or quote declares no reply at all and is itself
  the root, which a host reads as `thread_root_uri == uri`. A record that names
  itself as its own parent or root declares an impossible ancestor; that
  reference is dropped rather than sent back to the host.

  `reasons` is one reason or a list, as atoms or as the application's strings.
  `reply_root_uri` and `reply_parent_uri` keep their own meaning ("this record
  declared X") on the event and are not touched here.
  """
  def thread_refs(reasons, declared_root, declared_parent, uri) do
    if reasons |> List.wrap() |> Enum.any?(&post_reason?/1) do
      parent = unless_self(declared_parent, uri)

      %{
        thread_root_uri: unless_self(declared_root, uri) || parent || uri,
        thread_parent_uri: parent
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()
    else
      %{}
    end
  end

  defp unless_self(uri, uri), do: nil
  defp unless_self(ref, _uri), do: ref

  @doc """
  Return `[{matched_did, reasons}]` for tracked DIDs addressed by `event`.

  `tracked_dids` is an enumerable of DID strings. Empty input → `[]`.
  """
  def match_dids(event, tracked_dids) do
    tracked =
      tracked_dids
      |> Enum.filter(&(is_binary(&1) and &1 != ""))
      |> MapSet.new()

    if MapSet.size(tracked) == 0 do
      []
    else
      do_match(normalize(event), tracked)
    end
  end

  @doc "Extract the repo DID from an AT-URI (`at://did:.../collection/rkey`)."
  def did_from_at_uri("at://" <> rest) when is_binary(rest) do
    case String.split(rest, "/", parts: 2) do
      [did | _] when did != "" -> did
      _ -> nil
    end
  end

  def did_from_at_uri(_), do: nil

  defp do_match(%{type: type} = event, tracked) when type not in [:commit, "commit", nil] do
    # identity/account — only own_repo echo if author tracked
    own_repo_only(event, tracked)
  end

  defp do_match(event, tracked) do
    author = event_did(event)
    record = event_record(event)
    collection = event_collection(event)

    hits = %{}

    hits =
      if is_binary(author) and MapSet.member?(tracked, author) do
        add_hit(hits, author, :own_repo)
      else
        hits
      end

    hits =
      cond do
        collection == AtMcp.Network.collection(:post) ->
          match_post(hits, record, tracked)

        collection == AtMcp.Network.collection(:like) ->
          match_subject(hits, record, tracked, :like)

        collection == AtMcp.Network.collection(:repost) ->
          match_subject(hits, record, tracked, :repost)

        true ->
          match_post(hits, record, tracked)
      end

    hits
    |> Enum.map(fn {did, reasons} -> {did, Enum.reverse(reasons)} end)
    |> Enum.sort_by(fn {did, _} -> did end)
  end

  defp own_repo_only(event, tracked) do
    author = event_did(event)

    if is_binary(author) and MapSet.member?(tracked, author) do
      [{author, [:own_repo]}]
    else
      []
    end
  end

  defp match_post(hits, record, tracked) when is_map(record) do
    hits
    |> match_mentions(record, tracked)
    |> match_reply(record, tracked)
    |> match_embed(record, tracked)
  end

  defp match_post(hits, _, _), do: hits

  defp match_subject(hits, record, tracked, reason)
       when is_map(record) and reason in [:like, :repost] do
    case did_from_at_uri(subject_ref_uri(record)) do
      did when is_binary(did) ->
        if MapSet.member?(tracked, did), do: add_hit(hits, did, reason), else: hits

      _ ->
        hits
    end
  end

  defp match_subject(hits, _, _, _), do: hits

  defp match_mentions(hits, record, tracked) do
    facets = dig(record, ["facets"]) || dig(record, [:facets]) || []

    Enum.reduce(List.wrap(facets), hits, fn facet, acc ->
      features = dig(facet, ["features"]) || dig(facet, [:features]) || []

      Enum.reduce(List.wrap(features), acc, fn feature, acc2 ->
        type = dig(feature, ["$type"]) || dig(feature, [:"$type"])
        did = dig(feature, ["did"]) || dig(feature, [:did])

        if type == AtMcp.Network.type(:mention_facet) and is_binary(did) and
             MapSet.member?(tracked, did) do
          add_hit(acc2, did, :mention)
        else
          acc2
        end
      end)
    end)
  end

  defp match_reply(hits, record, tracked) do
    reply = dig(record, ["reply"]) || dig(record, [:reply])

    uris =
      [
        dig(reply, ["parent", "uri"]) || dig(reply, [:parent, :uri]),
        dig(reply, ["root", "uri"]) || dig(reply, [:root, :uri])
      ]
      |> Enum.filter(&is_binary/1)

    Enum.reduce(uris, hits, fn uri, acc ->
      case did_from_at_uri(uri) do
        did when is_binary(did) ->
          if MapSet.member?(tracked, did), do: add_hit(acc, did, :reply), else: acc

        _ ->
          acc
      end
    end)
  end

  defp match_embed(hits, record, tracked) do
    case did_from_at_uri(embed_record_uri(record)) do
      did when is_binary(did) ->
        if MapSet.member?(tracked, did), do: add_hit(hits, did, :quote), else: hits

      _ ->
        hits
    end
  end

  defp subject_ref_uri(record) when is_map(record) do
    dig(record, ["subject", "uri"]) || dig(record, [:subject, :uri])
  end

  defp subject_ref_uri(_), do: nil

  defp embed_record_uri(record) when is_map(record) do
    embed = dig(record, ["embed"]) || dig(record, [:embed])
    type = dig(embed, ["$type"]) || dig(embed, [:"$type"])

    cond do
      type == AtMcp.Network.type(:embed_record) ->
        dig(embed, ["record", "uri"]) || dig(embed, [:record, :uri])

      type == AtMcp.Network.type(:embed_record_with_media) ->
        dig(embed, ["record", "record", "uri"]) ||
          dig(embed, [:record, :record, :uri]) ||
          dig(embed, ["record", "uri"]) ||
          dig(embed, [:record, :uri])

      true ->
        # Some payloads nest strongly-ref under embed.record without $type yet
        dig(embed, ["record", "uri"]) || dig(embed, [:record, :uri])
    end
  end

  defp embed_record_uri(_), do: nil

  defp add_hit(hits, did, reason) do
    Map.update(hits, did, [reason], fn rs ->
      if reason in rs, do: rs, else: [reason | rs]
    end)
  end

  defp normalize(%AtMcp.Stream.Event{} = event) do
    %{
      type: event.kind,
      did: event.did,
      collection: event.collection,
      rkey: event.rkey,
      operation: event.operation,
      cid: event.cid,
      rev: event.rev,
      time_us: event.cursor,
      record: event.record
    }
  end

  defp normalize(event) when is_map(event), do: event
  defp normalize(_), do: %{}

  defp event_did(event), do: dig(event, [:did]) || dig(event, ["did"])
  defp event_collection(event), do: dig(event, [:collection]) || dig(event, ["collection"])
  defp event_record(event), do: dig(event, [:record]) || dig(event, ["record"])

  defdelegate dig(value, path), to: AtMcp.Response
end
