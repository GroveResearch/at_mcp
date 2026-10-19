defmodule AtMcp.Reading do
  @moduledoc """
  The text a model reads for a result made of posts, and for lists and
  starter packs.

  A tool result has two halves in MCP: `content`, text and images, which most
  clients give a model, and `structuredContent`, which a client validates
  against the tool's output schema and a program reads. For posts and
  notifications the two readers want different things. A program wants every field, `null`s included, so it can tell absent
  from empty. A model reading a page of posts wants what a person scrolling a
  client sees: why a feed shows it (a repost or a pin), who wrote it, when,
  whose post it replies to, what it says, and the
  identifiers it needs to act on it (`reply` takes the uri, `like` and `repost`
  take the uri and cid), with the counts and labels a client shows beside it
  and any block or mute between the account and the author. Serialized JSON repeats every key on every post, gives
  each post's text twice (`text` and `raw_text`), and spends most of a page on
  DIDs, image URLs, facet arrays and `null`s a model never uses.

  Each function here takes the structured content exactly as it is sent and
  returns that text. It reads the result, never the service, so it cannot say
  anything the structured content does not. What it leaves out is still in the
  structured content: author DIDs, `raw_text`, facets, web URLs, image, video and link-card image URLs and
  blob metadata, which labeler applied a label, the record URIs of likes,
  reposts and follows (which no tool takes), read notifications' `is_read`, and
  the read limits of a thread.

  It only drops what is absent. A post's text is never shortened, every uri
  and cid a write tool takes is kept, and a cursor or a `before` uri for the
  next page is stated with the argument to pass it as.
  """

  @doc "A page of posts: timelines, feeds, search results, `get_posts`."
  def posts(page), do: post_page(page, "post", "posts")

  @doc """
  This account's bookmarks: each post as a page of posts shows it, or one line
  for a bookmarked post that is deleted or hidden by a block.
  """
  def bookmarks(page), do: post_page(page, "bookmark", "bookmarks")

  defp post_page(%{"items" => items} = page, one, many) when is_list(items) do
    header = count(length(items), one, many) <> "." <> next_page(page)

    blocks =
      items
      |> Enum.with_index(1)
      |> Enum.map(fn {post, n} -> post(post, "[#{n}]") end)

    lines([header | blocks], "\n\n")
  end

  defp post_page(_other, _one, _many), do: nil

  @doc "A page of notifications, newest first as the service sends them."
  def notifications(%{"items" => items} = page) when is_list(items) do
    header = count(length(items), "notification", "notifications") <> "." <> next_page(page)

    blocks =
      items
      |> Enum.with_index(1)
      |> Enum.map(fn {item, n} -> notification(item, "[#{n}]") end)

    lines([header | blocks], "\n\n")
  end

  def notifications(_other), do: nil

  @doc """
  What `get_thread` read around one post: its parents, oldest first, the post,
  then its replies, each labelled with where it sits.
  """
  def thread(%{"uri" => uri} = node) when is_binary(uri) do
    parents = ancestors(node["parent"], [])
    count = length(parents)

    above =
      parents
      |> Enum.with_index()
      |> Enum.map(fn {parent, index} ->
        post(parent, parent_label(count - index))
      end)

    omitted =
      case parents do
        [%{"parent_omitted" => true} | _] ->
          ["(The conversation goes further up. get_thread_chain reads all of it.)"]

        _ ->
          []
      end

    lines(
      omitted ++ above ++ [post(node, "[this post]")] ++ replies(node, "reply "),
      "\n\n"
    )
  end

  def thread(_other), do: nil

  @doc """
  What `get_thread_chain` read: a conversation from its root down to one post,
  then the replies directly under that post.
  """
  def chain(%{"chain" => chain} = result) when is_list(chain) do
    total = length(chain)

    header =
      "A conversation of #{count(total, "post", "posts")}, oldest first. " <>
        "The last is the post asked about." <> cut(result)

    elements =
      chain
      |> Enum.with_index(1)
      |> Enum.map(fn {element, n} -> post(element, "[#{n}]") end)

    replies = List.wrap(result["replies"])

    under =
      case {replies, omitted(result["replies_omitted"])} do
        {[], ""} ->
          []

        {replies, more} ->
          [
            "Replies to it: #{length(replies)}#{more}."
            | replies
              |> Enum.with_index(1)
              |> Enum.map(fn {reply, n} -> post(reply, "[reply #{n}]") end)
          ]
      end

    lines([header | elements] ++ under, "\n\n")
  end

  def chain(_other), do: nil

  @doc """
  What `get_list` read: the list as its page in the app heads it, then the
  accounts on this page, each with the list item that puts it there.
  """
  def list(%{"list" => %{} = list, "items" => items} = page) when is_list(items) do
    header =
      count(length(items), "account", "accounts") <> " on this page." <> next_page(page)

    members =
      items
      |> Enum.with_index(1)
      |> Enum.map(fn {member, n} -> member(member, "[#{n}]") end)

    lines([list_heading(list, "List"), header | members], "\n\n")
  end

  def list(_other), do: nil

  @doc "A page of lists, from `get_lists`."
  def lists(%{"items" => items} = page) when is_list(items) do
    header = count(length(items), "list", "lists") <> "." <> next_page(page)

    blocks =
      items
      |> Enum.with_index(1)
      |> Enum.map(fn {list, n} -> lines([list_heading(list, "[#{n}]"), on_it(list)], "\n") end)

    lines([header | blocks], "\n\n")
  end

  def lists(_other), do: nil

  @doc "One starter pack, from `get_starter_pack`."
  def starter_pack(%{"uri" => uri} = pack) when is_binary(uri), do: pack(pack, "Starter pack")
  def starter_pack(_other), do: nil

  @doc "A page of starter packs, from `get_starter_packs`."
  def starter_packs(%{"items" => items} = page) when is_list(items) do
    header = count(length(items), "starter pack", "starter packs") <> "." <> next_page(page)

    blocks =
      items
      |> Enum.with_index(1)
      |> Enum.map(fn {pack, n} -> lines([pack(pack, "[#{n}]"), on_it(pack)], "\n") end)

    lines([header | blocks], "\n\n")
  end

  def starter_packs(_other), do: nil

  # A list's name, kind, size and maker on one line, then what it is for, then
  # its uri and where this account stands with it.
  defp list_heading(list, label) do
    viewer = if is_map(list["viewer"]), do: list["viewer"], else: %{}

    lines(
      [
        label <>
          " " <>
          lines(
            [
              named(list["name"]),
              purpose(list["purpose"]),
              if(is_integer(list["item_count"]),
                do: count(list["item_count"], "account", "accounts")
              ),
              by(list["creator"], list["creator_display_name"])
            ],
            " · "
          ),
        one_line(list["description"]),
        labelled(%{"labels" => list["labels"], "author_did" => list["creator_did"]}),
        lines(
          [
            if(viewer["muted"] == true, do: "You mute the accounts on it"),
            if(is_binary(viewer["blocked"]),
              do: "You block the accounts on it: #{viewer["blocked"]}"
            ),
            opted_out(viewer)
          ],
          " · "
        ),
        "uri: #{list["uri"]}"
      ],
      "\n"
    )
  end

  # A starter pack: its name, maker, size and who joined through it, what it
  # is for, the feeds it recommends, some of its accounts, and its list.
  defp pack(pack, label) do
    joined =
      case {pack["joined_week_count"], pack["joined_all_time_count"]} do
        {week, all} when is_integer(week) and is_integer(all) ->
          "#{all} joined through it, #{week} this week"

        {_week, all} when is_integer(all) ->
          "#{all} joined through it"

        _ ->
          nil
      end

    feeds =
      case List.wrap(pack["feeds"]) do
        [] ->
          nil

        feeds ->
          "Feeds: " <>
            Enum.map_join(feeds, "; ", fn feed ->
              lines([named(feed["display_name"]), by(feed["creator"], nil), feed["uri"]], " · ")
            end)
      end

    sample =
      case List.wrap(pack["members_sample"]) do
        [] -> nil
        members -> "Some of its accounts: " <> Enum.map_join(members, ", ", &who(account(&1)))
      end

    viewer = if is_map(pack["viewer"]), do: pack["viewer"], else: %{}

    lines(
      [
        label <>
          " " <>
          lines(
            [
              named(pack["name"]),
              by(pack["creator"], pack["creator_display_name"]),
              if(is_integer(pack["item_count"]),
                do: count(pack["item_count"], "account", "accounts")
              ),
              joined
            ],
            " · "
          ),
        one_line(pack["description"]),
        feeds,
        sample,
        labelled(%{"labels" => pack["labels"], "author_did" => pack["creator_did"]}),
        opted_out(viewer),
        if(is_binary(pack["list"]), do: "list: #{pack["list"]} (get_list reads every account)"),
        "uri: #{pack["uri"]}"
      ],
      "\n"
    )
  end

  # One account on a list: who it is, the list item that puts it there, and
  # whether it asked to be left out.
  defp member(%{} = member, label) do
    lines(
      [
        label <>
          " " <>
          lines(
            [
              who(account(member)),
              if(member["opted_out"] == true, do: "asked to be left out of this list")
            ],
            " · "
          ),
        one_line(member["description"]),
        standing(%{"author_viewer" => member["viewer"]}),
        "item: #{member["item_uri"]}"
      ],
      "\n"
    )
  end

  defp member(other, label), do: "#{label} #{Jason.encode!(other)}"

  # Read with contains: whether that account is in the list or pack.
  defp on_it(%{"member_item" => item}) when is_binary(item), do: "Contains the account: #{item}"
  defp on_it(%{} = item) when is_map_key(item, "member_item"), do: "Does not contain the account"
  defp on_it(_item), do: nil

  defp opted_out(%{"opted_out" => uri}) when is_binary(uri), do: "You opted out of it: #{uri}"
  defp opted_out(_viewer), do: nil

  defp account(%{} = account),
    do: %{
      "author" => account["handle"],
      "author_did" => account["did"],
      "display_name" => account["display_name"]
    }

  defp named(name) when is_binary(name), do: ~s("#{one_line(name)}")
  defp named(_name), do: nil

  defp by(handle, name) when is_binary(handle),
    do: "by " <> who(%{"author" => one_line(handle), "display_name" => name})

  defp by(_handle, _name), do: nil

  defp purpose(purpose) when purpose in ["curate", "moderation", "reference"],
    do: "#{purpose} list"

  defp purpose(purpose) when is_binary(purpose), do: "list for #{purpose}"
  defp purpose(_purpose), do: nil

  # One post: why a feed shows it, when that is not just that it was posted; a
  # header line saying who, when and what it answers; the text; what is
  # attached to it; then the identifiers to act on it with.
  defp post(%{} = post, label) do
    case unavailable(post) do
      nil ->
        header = lines([who(post), post["created_at"], replying(post)], " · ")

        top =
          case reason(post["reason"]) do
            nil -> [label <> " " <> header]
            why -> [label <> " " <> why, header]
          end

        lines(
          top ++
            body(post) ++
            [engagement(post), labelled(post), standing(post), ids(post) | viewer(post)],
          "\n"
        )

      why ->
        "#{label} #{why}"
    end
  end

  defp post(other, label), do: "#{label} #{Jason.encode!(other)}"

  defp unavailable(%{"blocked" => true} = post), do: "#{where(post)} is hidden by a block."
  defp unavailable(%{"not_found" => true} = post), do: "#{where(post)} is deleted or missing."
  defp unavailable(%{"unresolved" => true} = post), do: "#{where(post)} was not read."
  defp unavailable(_post), do: nil

  defp where(%{"uri" => uri}) when is_binary(uri), do: "The post #{uri}"
  defp where(_post), do: "A post"

  defp notification(%{} = item, label) do
    header =
      label <>
        " " <>
        lines(
          [
            lines([item["reason"], "from", who(item)], " "),
            item["indexed_at"],
            if(item["is_read"] == false, do: "unread")
          ],
          " · "
        )

    if is_binary(item["text"]) do
      reply_to = item["reply_parent_uri"]
      replying = if is_binary(reply_to), do: "replying to #{reply_to}"

      lines([lines([header, replying], " · ") | body(item)] ++ [ids(item)], "\n")
    else
      # A like, repost or follow has no text to read and nothing to answer: its
      # own record is not something any tool takes, so it is one line saying
      # what it was about.
      lines([header, about(item["subject_uri"])], " · ")
    end
  end

  defp about(uri) when is_binary(uri), do: "on #{uri}"
  defp about(_uri), do: nil

  defp who(%{"author" => handle} = post) when is_binary(handle) do
    name = post["display_name"]
    you = if post["is_self"] == true, do: " (you)", else: ""

    if is_binary(name) and String.trim(name) != "" and name != handle,
      do: "#{name} (@#{handle})#{you}",
      else: "@#{handle}#{you}"
  end

  defp who(%{"author_did" => did}) when is_binary(did), do: did
  defp who(_post), do: "unknown author"

  # The line the app puts above a post in a feed: "Reposted by" or "Pinned".
  # The repost record's uri is in the structured content.
  defp reason(%{"type" => "repost"} = reason) do
    by =
      who(%{
        "author" => reason["by"],
        "author_did" => reason["by_did"],
        "display_name" => reason["by_display_name"]
      })

    lines(["Reposted by " <> by, reason["at"]], " · ")
  end

  defp reason(%{"type" => "pin"}), do: "Pinned"

  defp reason(%{"type" => type}) when is_binary(type),
    do: "In this feed because: " <> String.replace(type, ~r/\s+/u, " ")

  defp reason(_reason), do: nil

  # What a reply answers: the parent's uri, and, when a feed said so, whose post
  # that is and whose thread it is in when the root's author is someone else.
  defp replying(%{"reply_to" => uri} = post) when is_binary(uri) do
    parent = post["reply_parent"]
    root = post["reply_root"]

    in_thread =
      if is_map(root) and root["status"] == "available" and is_binary(root["author"]) and
           root["author_did"] != (is_map(parent) && parent["author_did"]),
         do: " in a thread by @#{root["author"]}",
         else: ""

    "replying to " <> answered(parent, uri) <> in_thread
  end

  defp replying(_post), do: nil

  defp answered(%{"status" => "available", "author" => handle}, uri) when is_binary(handle),
    do: "@#{handle} (#{uri})"

  defp answered(%{"status" => "not_found"}, uri), do: "a deleted or missing post (#{uri})"
  defp answered(%{"status" => "blocked"}, uri), do: "a post hidden by a block (#{uri})"
  defp answered(_parent, uri), do: uri

  defp body(post) do
    [post["text"] | attachments(post)]
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
  end

  # Images by their alt text, a link card, a video by its alt text, what a
  # quote points at, and the kind of any other embed, so a reader knows
  # something is attached that the text does not say. `get_post_images` shows
  # the pictures themselves.
  defp attachments(post) do
    images = List.wrap(post["images"])

    image_lines =
      images
      |> Enum.with_index(1)
      |> Enum.map(fn {image, n} -> "[image #{n} of #{length(images)}: #{alt(image)}]" end)

    link = link(post["link"], :card)
    video = video(post["video"])
    quote = quoted(post["quote"])

    other =
      if images == [] and Enum.all?([link, video, quote], &is_nil/1) and
           is_binary(post["embed_type"]),
         do: "[embed: #{post["embed_type"]}]"

    image_lines ++ [link, video, quote, other]
  end

  # Alt text on one line: what the author wrote cannot start a line of its own
  # that reads as another post.
  defp alt(%{"alt" => alt}) when is_binary(alt) do
    case one_line(alt) do
      "" -> "no alt text"
      alt -> alt
    end
  end

  defp alt(_image), do: "no alt text"

  # "[link: Title — description (https://...)]", leaving out what the card does
  # not have. Inside a quote, the description is left out.
  defp link(%{"uri" => uri} = link, form) when is_binary(uri) do
    said =
      lines(
        [one_line(link["title"]), if(form == :card, do: capped(link["description"]))],
        " — "
      )

    uri = escape_uri(uri)
    if said == "", do: "[link: #{uri}]", else: "[link: #{said} (#{uri})]"
  end

  defp link(_link, _form), do: nil

  # A card's title or description on one line, as the app's card shows it.
  defp one_line(text) when is_binary(text),
    do: text |> String.replace(~r/\s+/u, " ") |> String.trim()

  defp one_line(_text), do: nil

  @description_limit 300

  # A card's description, on one line and at most 300
  # characters: a page's summary, not the page. The structured content keeps it
  # whole.
  defp capped(text) do
    case one_line(text) do
      text when is_binary(text) ->
        if String.length(text) > @description_limit,
          do: String.slice(text, 0, @description_limit - 1) <> "…",
          else: text

      other ->
        other
    end
  end

  # A URL has no whitespace; one that arrives with some has it percent-encoded,
  # so it stays one URL on one line.
  defp escape_uri(uri), do: String.replace(uri, ~r/\s/u, &URI.encode/1)

  defp video(%{} = video), do: "[video: #{alt(video)}]"
  defp video(_video), do: nil

  defp quoted(%{"status" => "available", "kind" => kind} = quote)
       when kind in ["feed", "list", "starter_pack", "labeler"] do
    name = one_line(quote["name"])
    name = if name not in [nil, ""], do: ~s( "#{name}")
    by = if is_binary(quote["creator"]), do: " by @#{one_line(quote["creator"])}"
    about = one_line(quote["description"])
    about = if about not in [nil, ""], do: ": #{about}"

    "[quoting #{String.replace(kind, "_", " ")}#{name}#{by}, #{quote["uri"]}#{about}]"
  end

  defp quoted(%{"status" => "available"} = quote) do
    images = length(List.wrap(quote["images"]))
    pictures = if images > 0, do: " [#{count(images, "image", "images")}]", else: ""

    media =
      Enum.map_join([link(quote["link"], :quote), video(quote["video"])], fn
        nil -> ""
        attached -> " " <> attached
      end)

    author =
      if is_binary(quote["author"]),
        do: who(%{"author" => quote["author"], "display_name" => quote["display_name"]}),
        else: "a post"

    "[quoting #{author}, #{quote["uri"]}: #{quote["text"]}#{pictures}#{media}]"
  end

  defp quoted(%{"status" => status} = quote) when is_binary(status),
    do: "[quoting #{quote["uri"]}: #{status}]"

  defp quoted(_quote), do: nil

  # What the service counts on the post, in the words a client shows under it.
  # A zero is left out of the text, and a post nobody has engaged with has no
  # line at all; the structured content keeps every count, zeros included.
  defp engagement(post) do
    counts =
      for {key, one, many} <- [
            {"like_count", "like", "likes"},
            {"repost_count", "repost", "reposts"},
            {"reply_count", "reply", "replies"},
            {"quote_count", "quote", "quotes"}
          ],
          is_integer(post[key]) and post[key] > 0,
          do: count(post[key], one, many)

    lines(counts, " · ")
  end

  # Labels by value, each once: "Labels: graphic-media; author: bot (self)".
  # Who applied a label is in the structured content; the one distinction kept
  # here is a label the author applied to itself, such as an account saying it
  # is a bot. Left out of the text, and kept in the structured content: an
  # expired label, a value a negation removes, and a `!` value, which is an
  # instruction to clients (such as `!no-unauthenticated`) rather than a
  # description of the post.
  defp labelled(post) do
    author = post["author_did"]
    on_post = labels(post["labels"], author)
    on_author = labels(post["author_labels"], author)

    case {on_post, on_author} do
      {[], []} -> nil
      {values, []} -> "Labels: " <> Enum.join(values, ", ")
      {[], values} -> "Labels: author: " <> Enum.join(values, ", ")
      {own, theirs} -> "Labels: #{Enum.join(own, ", ")}; author: #{Enum.join(theirs, ", ")}"
    end
  end

  defp labels(labels, author) when is_list(labels) do
    now = DateTime.utc_now()

    current =
      Enum.filter(labels, &(is_map(&1) and is_binary(&1["val"]) and not expired?(&1, now)))

    negated = for %{"neg" => true, "val" => val} <- current, into: MapSet.new(), do: val

    shown =
      Enum.reject(current, fn %{"val" => val} = label ->
        label["neg"] == true or val in negated or String.starts_with?(val, "!")
      end)

    self = for %{"src" => ^author, "val" => val} <- shown, into: MapSet.new(), do: val

    shown
    |> Enum.map(& &1["val"])
    |> Enum.uniq()
    |> Enum.map(&if(&1 in self, do: &1 <> " (self)", else: &1))
  end

  defp labels(_labels, _author), do: []

  defp expired?(%{"exp" => exp}, now) when is_binary(exp) do
    case DateTime.from_iso8601(exp) do
      {:ok, at, _offset} -> DateTime.compare(at, now) != :gt
      _ -> false
    end
  end

  defp expired?(_label, _now), do: false

  # Where the account stands with the author, said only when it is not the
  # ordinary case: a block either way, a mute, or a post the service says the
  # account cannot reply to or quote. Follows are on almost every timeline post and stay
  # in the structured content.
  defp standing(post) do
    author = if is_map(post["author_viewer"]), do: post["author_viewer"], else: %{}
    viewer = if is_map(post["viewer"]), do: post["viewer"], else: %{}

    lines(
      [
        cond do
          is_binary(author["blocking_by_list"]) -> "You blocked them via a list"
          is_binary(author["blocking"]) -> "You blocked them"
          true -> nil
        end,
        if(author["blocked_by"] == true, do: "They blocked you"),
        cond do
          is_binary(author["muted_by_list"]) -> "You muted them via a list"
          author["muted"] == true -> "You muted them"
          true -> nil
        end,
        if(viewer["reply_disabled"] == true, do: "You cannot reply to this post"),
        if(viewer["embedding_disabled"] == true, do: "You cannot quote this post"),
        if(viewer["thread_muted"] == true, do: "You muted this thread")
      ],
      " · "
    )
  end

  defp ids(post) do
    lines(
      [
        if(is_binary(post["uri"]), do: "uri: #{post["uri"]}"),
        if(is_binary(post["cid"]), do: "cid: #{post["cid"]}")
      ],
      " · "
    )
  end

  # The viewing account's own like or repost of the post: the uri `unlike` and
  # `unrepost` take, and the reason not to like it twice.
  defp viewer(%{"viewer" => %{} = viewer}) do
    for {key, verb} <- [{"like", "You liked this"}, {"repost", "You reposted this"}],
        is_binary(viewer[key]),
        do: "#{verb}: #{viewer[key]}"
  end

  defp viewer(_post), do: []

  defp ancestors(%{} = parent, acc), do: ancestors(parent["parent"], [parent | acc])
  defp ancestors(_none, acc), do: acc

  defp parent_label(1), do: "[parent]"
  defp parent_label(up), do: "[parent, #{up} up]"

  defp replies(node, prefix) do
    replies = List.wrap(node["replies"])

    shown =
      replies
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {reply, n} ->
        label = "#{prefix}#{n}"
        [post(reply, "[#{label}]") | replies(reply, label <> ".")]
      end)

    case node["replies_omitted"] do
      n when is_integer(n) and n > 0 ->
        shown ++ ["(#{n} more replies to #{node["uri"]} not shown)"]

      _ ->
        shown
    end
  end

  defp omitted(n) when is_integer(n) and n > 0, do: " (#{n} more not shown)"
  defp omitted(_n), do: ""

  defp cut(%{"chain_before" => before} = result) when is_binary(before),
    do:
      " #{earlier(result["chain_omitted"])}To read further up, call get_thread_chain again with before: #{before}"

  defp cut(%{"chain_truncated" => true} = result),
    do:
      " #{earlier(result["chain_omitted"])}It does not reach the root: an earlier post could not be read."

  defp cut(_result), do: ""

  defp earlier(n) when is_integer(n) and n > 0, do: "#{n} earlier posts are not shown. "
  defp earlier(_n), do: ""

  defp next_page(%{"cursor" => cursor}) when is_binary(cursor),
    do: " For the next page, pass cursor: #{cursor}"

  defp next_page(_page), do: ""

  defp count(1, one, _many), do: "1 #{one}"
  defp count(n, _one, many), do: "#{n} #{many}"

  defp lines(parts, separator) do
    parts
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.join(separator)
  end
end
