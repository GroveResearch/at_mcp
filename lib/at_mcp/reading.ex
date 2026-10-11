defmodule AtMcp.Reading do
  @moduledoc """
  The text a model reads for a result made of posts.

  A tool result has two halves in MCP: `content`, text and images, which most
  clients give a model, and `structuredContent`, which a client validates
  against the tool's output schema and a program reads. For posts and
  notifications the two readers want different things. A program wants every field, `null`s included, so it can tell absent
  from empty. A model reading a page of posts wants what a person scrolling a
  client sees: who wrote it, when, what it replies to, what it says, and the
  identifiers it needs to act on it (`reply` takes the uri, `like` and `repost`
  take the uri and cid). Serialized JSON repeats every key on every post, gives
  each post's text twice (`text` and `raw_text`), and spends most of a page on
  DIDs, image URLs, facet arrays and `null`s a model never uses.

  Each function here takes the structured content exactly as it is sent and
  returns that text. It reads the result, never the service, so it cannot say
  anything the structured content does not. What it leaves out is still in the
  structured content: author DIDs, `raw_text`, facets, web URLs, image URLs and
  blob metadata, the record URIs of likes, reposts and follows (which no tool
  takes), read notifications' `is_read`, and the read limits of a thread.

  It only drops what is absent. A post's text is never shortened, every uri
  and cid a write tool takes is kept, and a cursor or a `before` uri for the
  next page is stated with the argument to pass it as.
  """

  @doc "A page of posts: timelines, feeds, search results, `get_posts`."
  def posts(%{"items" => items} = page) when is_list(items) do
    header = count(length(items), "post", "posts") <> "." <> next_page(page)

    blocks =
      items
      |> Enum.with_index(1)
      |> Enum.map(fn {post, n} -> post(post, "[#{n}]") end)

    lines([header | blocks], "\n\n")
  end

  def posts(_other), do: nil

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

  # One post: a header line saying who, when and what it answers, the text,
  # what is attached to it, then the identifiers to act on it with.
  defp post(%{} = post, label) do
    case unavailable(post) do
      nil ->
        lines(
          [
            label <> " " <> lines([who(post), post["created_at"], replying(post)], " · ")
            | body(post)
          ] ++ [ids(post) | viewer(post)],
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

  defp replying(%{"reply_to" => uri}) when is_binary(uri), do: "replying to #{uri}"
  defp replying(_post), do: nil

  defp body(post) do
    [post["text"] | attachments(post)]
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
  end

  # Images by their alt text, the post a quote points at, and the kind of any
  # other embed, so a reader knows something is attached that the text does
  # not say. `get_post_images` shows the pictures themselves.
  defp attachments(post) do
    images = List.wrap(post["images"])

    image_lines =
      images
      |> Enum.with_index(1)
      |> Enum.map(fn {image, n} -> "[image #{n} of #{length(images)}: #{alt(image)}]" end)

    quote = quoted(post["quote"])

    other =
      if images == [] and is_nil(quote) and is_binary(post["embed_type"]),
        do: "[embed: #{post["embed_type"]}]"

    image_lines ++ [quote, other]
  end

  defp alt(%{"alt" => alt}) when is_binary(alt) and alt != "", do: alt
  defp alt(_image), do: "no alt text"

  defp quoted(%{"status" => "available"} = quote) do
    images = length(List.wrap(quote["images"]))
    pictures = if images > 0, do: " [#{count(images, "image", "images")}]", else: ""
    author = if is_binary(quote["author"]), do: "@#{quote["author"]}", else: "a post"

    "[quoting #{author}, #{quote["uri"]}: #{quote["text"]}#{pictures}]"
  end

  defp quoted(%{"status" => status} = quote) when is_binary(status),
    do: "[quoting #{quote["uri"]}: #{status}]"

  defp quoted(_quote), do: nil

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
