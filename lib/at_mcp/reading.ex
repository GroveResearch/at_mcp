defmodule AtMcp.Reading do
  @moduledoc """
  The text a model reads for a result made of posts, and for accounts, lists,
  starter packs, feeds, trends, invitation codes and the account's settings.

  A tool result has two halves in MCP: `content`, text and images, which most
  clients give a model, and `structuredContent`, which a program reads. For
  posts and notifications the two readers want different things. A program wants every field, `null`s included, so it can tell absent
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
  structured content: author DIDs, `raw_text`, facets, image, video and link-card image URLs and
  blob metadata, which labeler applied a label, the record URIs of likes,
  reposts and follows (which no tool takes), read notifications' `is_read`, and
  the read limits of a thread.

  Nothing a result carries can read as a line or a word of AtMcp's own. The
  text is built only from `AtMcp.Reading.Text` pieces, and every value from a
  result goes through one of its renderers: a post's text is fenced, every
  line of it after `> `, which no line AtMcp writes starts with; other free
  text someone else wrote (a quoted post's text, a display name, alt text, a
  card's, publication's, list's, feed's or starter pack's name or
  description, a label's name) is one double-quoted literal on one line, `"`
  and backslash escaped; an identifier (a DID, handle, AT URI, CID, cursor,
  label value, or a word the service chose) is bare only when it is nothing
  but an identifier's characters, and a literal otherwise; a web address is
  percent-encoded so it cannot close a bracket or hold a blank; a timestamp
  is bare only when it is one. AtMcp's own words are `~L` constants. A raw
  string given to the joiners is refused under test and quoted elsewhere, and
  `test/at_mcp/reading_text_test.exs` fails if this module interpolates a
  string or makes a piece itself. In a post's `text`
  (`AtMcp.RichText.render/2`) the author's `<` and backslash are escaped too,
  so an unescaped `<…>` is always a link or mention marker AtMcp added; a
  post whose text, or quoted text, holds such an escape says so in one line
  under it.

  It only drops what is absent. A post's text is never shortened, except on
  one line of a brief page (`brief_posts/1`), which says so; every uri
  and cid a write tool takes is kept, and a cursor or a `before` uri for the
  next page is stated with the argument to pass it as. Beside the uri of each
  post, account, list, feed, starter pack and labeler is its `link:`, the web
  link a person opens and shares in the app.
  """
  import AtMcp.Reading.Text

  # The most characters of text a page of posts may have, when it can be cut
  # (`AtMcp.MCP.Tools.page/4`). Claude Code puts a result over 50,000
  # characters in a file instead of in front of the model. A recorded 50-post
  # author feed is about 35,000 characters (#203), so a page is cut only when
  # its posts are long, and the notes `AtMcp.MCP.Input` and
  # `AtMcp.MCP.WebLinks` append after the page still fit under 50,000.
  @page_chars 40_000

  @doc "The most characters of text a page of posts may have, when it can be cut."
  def page_chars, do: @page_chars

  @doc "A page of posts: timelines, feeds, search results, `get_posts`."
  def posts(page), do: post_page(page, ~L"post", ~L"posts")

  @doc """
  A page of posts with one line per post, for skimming (`detail: "brief"`).
  Each line has the author, the time, the first line of the text, the counts
  and the uri, which `get_posts` takes to return the whole post. This is the
  only reading that shortens a post's text, and the line marks where it was
  cut.
  """
  def brief_posts(%{"items" => items} = page) when is_list(items) do
    header =
      cat([
        count(length(items), ~L"post", ~L"posts"),
        ~L", one line each. Pass a uri to get_posts to read the whole post.",
        news(page),
        left_out(page, ~L"post", ~L"posts"),
        next_page(page),
        unsaved(page)
      ])

    lines =
      items
      |> Enum.with_index(1)
      |> Enum.map(fn {post, n} -> brief(post, numbered(n)) end)

    to_text(join([header, shown(page["moderation_unread"]) | lines], :line))
  end

  def brief_posts(_other), do: nil

  @doc """
  This account's bookmarks: each post as a page of posts shows it, or one line
  for a bookmarked post that is deleted or hidden by a block.
  """
  def bookmarks(page), do: post_page(page, ~L"bookmark", ~L"bookmarks")

  defp post_page(%{"items" => items} = page, one, many) when is_list(items) do
    header =
      cat([
        count(length(items), one, many),
        ~L".",
        news(page),
        left_out(page, one, many),
        next_page(page),
        unsaved(page)
      ])

    blocks =
      items
      |> Enum.with_index(1)
      |> Enum.map(fn {post, n} -> post(post, numbered(n)) end)

    to_text(join([header, shown(page["moderation_unread"]) | blocks], :blank))
  end

  defp post_page(_other, _one, _many), do: nil

  @doc "A page of notifications, newest first as the service sends them."
  def notifications(%{"items" => items} = page) when is_list(items) do
    {one, many} =
      if Enum.any?(items, &Map.has_key?(&1, "kind")),
        do: {~L"notification group", ~L"notification groups"},
        else: {~L"notification", ~L"notifications"}

    header =
      cat([
        count(length(items), one, many),
        ~L".",
        if(is_binary(page["seen_at"]),
          do: cat([~L" Seen in the app up to ", time(page["seen_at"]), ~L"."])
        ),
        notification_news(page),
        still_unread(page),
        left_out(page, one, many),
        next_page(page),
        unsaved(page)
      ])

    blocks =
      items
      |> Enum.with_index(1)
      |> Enum.map(fn {item, n} -> notification(item, numbered(n)) end)

    to_text(join([header | blocks], :blank))
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
        post(parent, cat([parent_label(count - index), op_run(parent)]))
      end)

    omitted =
      case parents do
        [%{"parent_omitted" => true} | _] ->
          [~L"(The conversation goes further up. get_thread_chain reads all of it.)"]

        _ ->
          []
      end

    to_text(
      join(
        [shown(node["moderation_unread"])] ++
          omitted ++
          above ++
          [post(node, cat([~L"[this post]", op_run(node)]))] ++
          replies(node, []) ++ cut_replies(node) ++ hidden(node) ++ others(node),
        :blank
      )
    )
  end

  def thread(_other), do: nil

  # A post in the original poster's own series of posts from the root,
  # numbered from 1 as the service numbers it.
  defp op_run(%{"op_thread_index" => n, "op_thread_count" => of})
       when is_integer(n) and is_integer(of) and of > 1,
       do:
         cat([~L" (post ", int(n), ~L" of ", int(of), ~L" in the original poster's own thread)"])

  defp op_run(_post), do: nil

  # Direct replies left out to keep the thread under `@page_chars`.
  defp cut_replies(%{"replies_cut" => n}) when is_integer(n) and n > 0,
    do: [
      cat([
        ~L"(",
        int(n),
        if(n == 1, do: ~L" more direct reply was", else: ~L" more direct replies were"),
        ~L" left out to keep this under ",
        int(@page_chars),
        ~L" characters. To read more of them, call get_thread again with a smaller depth or breadth, or call get_thread on a single reply to read the replies under it.)"
      ])
    ]

  defp cut_replies(_node), do: []

  # Replies hidden from the thread, when include_hidden was not asked for.
  defp others(%{"other_replies" => true} = node) when not is_map_key(node, "hidden_replies"),
    do: [
      ~L"(Some replies to this thread are hidden, either by its author or by this account's settings. Call get_thread with include_hidden set to true to read them.)"
    ]

  defp others(_node), do: []

  # Asked for with `include_hidden`: the replies the app leaves out of the
  # thread. Those the read returned are marked where they stand; the rest are
  # listed after it, each saying why. Not asked for, there is no
  # `hidden_replies` and no line.
  defp hidden(%{"hidden_replies_unread" => why}) when is_binary(why), do: [shown(why)]

  defp hidden(%{"hidden_replies" => hidden} = node) when is_list(hidden) do
    in_place = count_left_out(node)

    marked =
      if in_place > 0,
        do: [
          cat([
            ~L"Replies above that the app leaves out of the thread, each marked where it stands: ",
            int(in_place),
            ~L"."
          ])
        ],
        else: []

    case hidden do
      [] when in_place == 0 ->
        [~L"No replies under this post are left out."]

      [] ->
        marked

      hidden ->
        marked ++
          [
            cat([
              ~L"Replies under this post left out of the thread: ",
              int(length(hidden)),
              ~L"."
            ])
            | hidden
              |> Enum.with_index(1)
              |> Enum.map(fn {reply, n} -> post(reply, cat([~L"[left out ", int(n), ~L"]"])) end)
          ]
    end
  end

  defp hidden(_node), do: []

  defp count_left_out(node) do
    node
    |> Map.get("replies")
    |> List.wrap()
    |> Enum.map(fn reply ->
      if(reply["left_out"] == true, do: 1, else: 0) + count_left_out(reply)
    end)
    |> Enum.sum()
  end

  @doc """
  What `get_thread_chain` read: a conversation from its root down to one post,
  then the replies directly under that post.
  """
  def chain(%{"chain" => chain} = result) when is_list(chain) do
    total = length(chain)

    header =
      cat([
        ~L"A conversation of ",
        count(total, ~L"post", ~L"posts"),
        ~L", oldest first. The last is the post asked about.",
        cut(result)
      ])

    elements =
      chain
      |> Enum.with_index(1)
      |> Enum.map(fn {element, n} -> post(element, numbered(n)) end)

    replies = List.wrap(result["replies"])
    more = omitted(result["replies_omitted"])

    under =
      case {replies, more} do
        {[], nil} ->
          []

        {replies, more} ->
          [
            cat([~L"Replies to it: ", int(length(replies)), more, ~L"."])
            | replies
              |> Enum.with_index(1)
              |> Enum.map(fn {reply, n} -> post(reply, cat([~L"[reply ", int(n), ~L"]"])) end)
          ]
      end

    to_text(join([header, shown(result["moderation_unread"]) | elements] ++ under, :blank))
  end

  def chain(_other), do: nil

  @doc """
  What `get_list` read: the list as its page in the app heads it, then the
  accounts on this page, each with the list item that puts it there.
  """
  def list(%{"list" => %{} = list, "items" => items} = page) when is_list(items) do
    header =
      cat([count(length(items), ~L"account", ~L"accounts"), ~L" on this page.", next_page(page)])

    members =
      items
      |> Enum.with_index(1)
      |> Enum.map(fn {member, n} -> member(member, numbered(n)) end)

    to_text(join([list_heading(list, ~L"List"), header | members], :blank))
  end

  def list(_other), do: nil

  @doc "A page of lists, from `get_lists`."
  def lists(%{"items" => items} = page) when is_list(items) do
    header = cat([count(length(items), ~L"list", ~L"lists"), ~L".", next_page(page)])

    blocks =
      items
      |> Enum.with_index(1)
      |> Enum.map(fn {list, n} -> join([list_heading(list, numbered(n)), on_it(list)], :line) end)

    to_text(join([header | blocks], :blank))
  end

  def lists(_other), do: nil

  @doc "One starter pack, from `get_starter_pack`."
  def starter_pack(%{"uri" => uri} = pack) when is_binary(uri),
    do: to_text(pack(pack, ~L"Starter pack"))

  def starter_pack(_other), do: nil

  @doc "A page of starter packs, from `get_starter_packs`."
  def starter_packs(%{"items" => items} = page) when is_list(items) do
    header =
      cat([count(length(items), ~L"starter pack", ~L"starter packs"), ~L".", next_page(page)])

    blocks =
      items
      |> Enum.with_index(1)
      |> Enum.map(fn {pack, n} -> join([pack(pack, numbered(n)), on_it(pack)], :line) end)

    to_text(join([header | blocks], :blank))
  end

  def starter_packs(_other), do: nil

  @doc """
  One account, from `get_profile`, as its profile page in the app heads it:
  who it is and the badges beside its name, how it relates to this account,
  its description, counts and links, and what it has pinned or made.
  """
  def profile(%{"handle" => handle} = profile) when is_binary(handle),
    do: to_text(account_card(profile, ~L"Profile", :full))

  def profile(_other), do: nil

  @doc """
  A page of accounts: followers, follows, search results, suggestions,
  blocks, mutes, likers and reposters, and `get_profiles`.
  """
  def profiles(%{"items" => items} = page) when is_list(items) do
    header = cat([count(length(items), ~L"account", ~L"accounts"), ~L".", next_page(page)])

    blocks =
      items
      |> Enum.with_index(1)
      |> Enum.map(fn {account, n} -> account_card(account, numbered(n), :brief) end)

    to_text(join([header, shown(page["moderation_unread"]) | blocks], :blank))
  end

  def profiles(_other), do: nil

  # An account wherever a read returns one. A page shows each with its
  # description on one line, as the app's account lists do.
  defp account_card(%{"handle" => handle} = account, label, form) when is_binary(handle) do
    viewer = if is_map(account["viewer"]), do: account["viewer"], else: %{}

    name =
      who(%{
        "author" => handle,
        "display_name" => account["display_name"],
        "author_verification" => account["verification"],
        "author_status" => account["status"],
        "author_viewer" => viewer,
        "author_labels" => account["labels"]
      })

    made =
      join(
        [
          counted(account["lists"], ~L"list", ~L"lists"),
          counted(account["feeds"], ~L"feed", ~L"feeds"),
          counted(account["starter_packs"], ~L"starter pack", ~L"starter packs")
        ],
        :dot
      )

    join(
      [
        cat([
          label,
          ~L" ",
          join(
            [
              name,
              shown(account["pronouns"]),
              if(account["labeler"] == true, do: ~L"runs a labeler")
            ],
            :dot
          )
        ]),
        relation(viewer),
        if(form == :full, do: fence(account["description"]), else: shown(account["description"])),
        join(
          [
            counted(account["followers"], ~L"follower", ~L"followers"),
            counted(account["follows"], ~L"following", ~L"following"),
            counted(account["posts"], ~L"post", ~L"posts"),
            if(is_binary(account["created_at"]),
              do: cat([~L"joined ", time(account["created_at"])])
            )
          ],
          :dot
        ),
        if(not empty?(made), do: cat([~L"Made: ", made])),
        if(is_binary(account["website"]), do: cat([~L"Website: ", url(account["website"])])),
        case List.wrap(account["links"]) do
          [] ->
            nil

          links ->
            cat([
              ~L"Links: ",
              join(
                Enum.map(links, fn link ->
                  address = url(link["url"])

                  case nonempty(link["title"]) do
                    nil -> address
                    title -> join([title, address && cat([~L"(", address, ~L")"])], :space)
                  end
                end),
                :semi
              )
            ])
        end,
        if(is_binary(account["pinned_post"]),
          do: cat([~L"Pinned post: ", ident(account["pinned_post"])])
        ),
        live_line(account["status"], viewer, account["labels"]),
        if(form == :full,
          do:
            join(
              [
                if(is_binary(account["avatar"]), do: cat([~L"Avatar: ", url(account["avatar"])])),
                if(is_binary(account["banner"]), do: cat([~L"Banner: ", url(account["banner"])]))
              ],
              :dot
            )
        ),
        verified_by(account["verification"]),
        labelled(%{"labels" => account["labels"], "author_did" => account["did"]}),
        AtMcp.ModerationDecision.line(account["moderation"]),
        shown(account["moderation_unread"]),
        known_followers(account["known_followers"]),
        joined_via(account["joined_via"]),
        messages_from(account["messages_from"]),
        subscriptions_from(account["subscriptions_from"]),
        subscribed(account["activity_subscription"]),
        if(is_binary(account["did"]), do: cat([~L"did: ", ident(account["did"])])),
        web(account)
      ],
      :line
    )
  end

  defp account_card(other, label, _form), do: unknown(other, label)

  # A shape this version does not read, as its JSON in one literal.
  defp unknown(other, label), do: cat([label, ~L" ", literal(Jason.encode!(other))])

  defp counted(n, one, many) when is_integer(n) and n > 0, do: count(n, one, many)
  defp counted(_n, _one, _many), do: nil

  # How the account relates to this one, with the record URIs `unfollow` and
  # `unblock` take, and the list a block or mute comes through. A block
  # through a list puts the list's URI in `blocking`, which `unblock` refuses,
  # so only the list is named then.
  defp relation(viewer) do
    join(
      [
        if(is_binary(viewer["following"]),
          do: cat([~L"You follow them: ", ident(viewer["following"])])
        ),
        if(is_binary(viewer["followed_by"]), do: ~L"Follows you"),
        cond do
          is_binary(viewer["blocking_by_list"]) ->
            cat([~L"You blocked them via a list: ", ident(viewer["blocking_by_list"])])

          is_binary(viewer["blocking"]) ->
            cat([~L"You blocked them: ", ident(viewer["blocking"])])

          true ->
            nil
        end,
        if(viewer["blocked_by"] == true, do: ~L"They blocked you"),
        cond do
          is_binary(viewer["muted_by_list"]) ->
            cat([~L"You muted them via a list: ", ident(viewer["muted_by_list"])])

          viewer["muted"] == true ->
            ~L"You muted them"

          true ->
            nil
        end,
        # The app's "Reposts Hidden" pill on a profile and an account card.
        if(viewer["muted_reposts"] == true, do: ~L"You hid their reposts")
      ],
      :dot
    )
  end

  defp live_line(status, viewer, labels) do
    if live?(status, viewer, labels) do
      join(
        [
          ~L"Live:",
          shown(status["title"]),
          url(status["url"]),
          if(is_binary(status["expires_at"]), do: cat([~L"until ", time(status["expires_at"])]))
        ],
        :space
      )
    end
  end

  defp verified_by(%{"status" => "valid", "by" => [_ | _] = by}) do
    case for(%{"valid" => true} = v <- by, do: v) do
      [] ->
        nil

      valid ->
        cat([
          ~L"Verified by: ",
          join(
            Enum.map(valid, fn v ->
              who(%{
                "author" => v["issuer_handle"],
                "author_did" => v["issuer"],
                "display_name" => v["issuer_display_name"]
              })
            end),
            :comma
          )
        ])
    end
  end

  defp verified_by(_verification), do: nil

  # The app's "Followed by A, B and 3 others".
  defp known_followers(%{"followers" => [_ | _] = shown} = known) do
    names = join(Enum.map(shown, &who(account(&1))), :comma)
    others = if is_integer(known["count"]), do: known["count"] - length(shown), else: 0

    cat([
      ~L"Followed by ",
      names,
      if(others > 0, do: cat([~L" and ", count(others, ~L"other", ~L"others")]))
    ])
  end

  defp known_followers(_known), do: nil

  # The app's "Liked by A and B" under a post: at most two of the accounts
  # this one follows that liked it (KnownLikers in social-app).
  # The app leaves out of it an account its moderation filters from a list
  # of accounts: one blocked either way or muted.
  defp known_likers(%{"actors" => [_ | _] = actors}) do
    case actors
         |> Enum.reject(&filtered?(&1["viewer"]))
         |> Enum.take(2)
         |> Enum.map(&who(account(&1))) do
      [] -> nil
      [one] -> cat([~L"Liked by ", one])
      [one, two] -> cat([~L"Liked by ", one, ~L" and ", two])
    end
  end

  defp known_likers(_known), do: nil

  defp filtered?(%{} = viewer),
    do:
      is_binary(viewer["blocking"]) or is_binary(viewer["blocking_by_list"]) or
        viewer["blocked_by"] == true or viewer["muted"] == true or
        is_binary(viewer["muted_by_list"])

  defp filtered?(_viewer), do: false

  defp joined_via(%{"uri" => uri} = pack) when is_binary(uri),
    do:
      cat([
        ~L"Joined through the starter pack ",
        join([shown(pack["name"]), by(pack["creator"], nil), ident(uri)], :space)
      ])

  defp joined_via(_pack), do: nil

  defp messages_from("all"), do: ~L"Takes messages from everyone"
  defp messages_from("following"), do: ~L"Takes messages from people they follow"
  defp messages_from("none"), do: ~L"Takes no messages"

  defp messages_from(other) when is_binary(other),
    do: cat([~L"Takes messages from: ", ident(other)])

  defp messages_from(_none), do: nil

  # Who may subscribe to the account's posts; followers, which no
  # declaration also means, goes without saying.
  defp subscriptions_from("mutuals"), do: ~L"Lets only mutuals subscribe to its posts"
  defp subscriptions_from("none"), do: ~L"Lets no one subscribe to its posts"
  defp subscriptions_from(_followers), do: nil

  defp subscribed(%{"posts" => true, "replies" => true}),
    do: ~L"You are subscribed to its posts and replies"

  defp subscribed(%{"posts" => true}), do: ~L"You are subscribed to its posts"
  defp subscribed(_none), do: nil

  @doc """
  A page of custom feeds: suggested, searched, an account's, or read by uri.
  Each with its name, maker, likes and whether it takes feedback, then what it
  is for, and the uri and cid `get_feed` and `like` take. Suggested feeds end
  with the feeds the app pins for every account, when the page carries them.
  """
  def feeds(%{"items" => items} = page) when is_list(items) do
    header = cat([count(length(items), ~L"feed", ~L"feeds"), ~L".", next_page(page)])

    blocks =
      items
      |> Enum.with_index(1)
      |> Enum.map(fn {feed, n} -> feed(feed, numbered(n)) end)

    missing =
      case page["not_found"] do
        [_ | _] = uris ->
          [cat([~L"The service does not know: ", join(Enum.map(uris, &ident/1), :comma)])]

        _ ->
          []
      end

    pinned =
      for feed <- List.wrap(page["app_pinned_feeds"]),
          do: feed(feed, ~L"Pinned by the app for every account:")

    to_text(join([header | blocks] ++ missing ++ pinned, :blank))
  end

  def feeds(_other), do: nil

  defp feed(%{} = feed, label) do
    viewer = if is_map(feed["viewer"]), do: feed["viewer"], else: %{}

    join(
      [
        cat([
          label,
          ~L" ",
          join(
            [
              shown(feed["display_name"]),
              by(feed["creator"], feed["creator_display_name"]),
              if(is_integer(feed["like_count"]),
                do: count(feed["like_count"], ~L"like", ~L"likes")
              ),
              if(AtMcp.Effects.takes_feedback?(feed["uri"], feed["accepts_interactions"]),
                do: ~L"takes feedback"
              ),
              online(feed)
            ],
            :dot
          )
        ]),
        shown(feed["description"]),
        labelled(%{"labels" => feed["labels"], "author_did" => feed["creator_did"]}),
        if(is_binary(viewer["like"]), do: cat([~L"You liked this: ", ident(viewer["like"])])),
        if(is_binary(feed["avatar"]), do: cat([~L"Avatar: ", url(feed["avatar"])])),
        ids(feed),
        web(feed)
      ],
      :line
    )
  end

  defp feed(other, label), do: unknown(other, label)

  defp online(%{"is_online" => false}), do: ~L"its service is offline"
  defp online(%{"is_valid" => false}), do: ~L"its service does not match its record"
  defp online(%{"is_online" => true}), do: ~L"online"
  defp online(_feed), do: nil

  @doc """
  Trends or trending topics: what each is called, how hot and how big, what it
  is about, some of the accounts posting, and the link the app opens for it.
  """
  def trends(%{"items" => items} = page) when is_list(items) do
    header = cat([count(length(items), ~L"trend", ~L"trends"), ~L"."])

    blocks =
      items
      |> Enum.with_index(1)
      |> Enum.map(fn {trend, n} -> trend(trend, numbered(n)) end)

    suggested =
      case page["suggested"] do
        [_ | _] = topics ->
          [
            cat([
              ~L"Suggested beside them: ",
              join(
                Enum.map(topics, fn topic ->
                  join([shown(topic["display_name"] || topic["topic"]), url(topic["link"])], :dot)
                end),
                :semi
              )
            ])
          ]

        _ ->
          []
      end

    to_text(join([header | blocks] ++ suggested, :blank))
  end

  def trends(_other), do: nil

  defp trend(%{} = trend, label) do
    join(
      [
        cat([
          label,
          ~L" ",
          join(
            [
              shown(trend["display_name"] || trend["topic"]),
              ident(trend["status"]),
              ident(trend["category"]),
              if(is_integer(trend["post_count"]),
                do: count(trend["post_count"], ~L"post", ~L"posts")
              ),
              if(is_binary(trend["started_at"]), do: cat([~L"since ", time(trend["started_at"])]))
            ],
            :dot
          )
        ]),
        shown(trend["description"]),
        case List.wrap(trend["actors"]) do
          [] -> nil
          actors -> cat([~L"Posting: ", join(Enum.map(actors, &who(account(&1))), :comma)])
        end,
        if(is_binary(trend["link"]), do: cat([~L"link: ", url(trend["link"])]))
      ],
      :line
    )
  end

  defp trend(other, label), do: unknown(other, label)

  @doc "This account's invitation codes: each, how many uses it has left, and who used it."
  def invite_codes(%{"items" => items} = result) when is_list(items) do
    header =
      join(
        [
          cat([count(length(items), ~L"invitation code", ~L"invitation codes"), ~L"."]),
          if(is_binary(result["collection"]),
            do: cat([~L"Earned codes: ", ident(result["collection"]), ~L"."])
          )
        ],
        :space
      )

    blocks =
      items
      |> Enum.with_index(1)
      |> Enum.map(fn {code, n} -> invite_code(code, numbered(n)) end)

    to_text(join([header | blocks], :blank))
  end

  def invite_codes(_other), do: nil

  @doc """
  One of the network's policy pages: its title and address, then its text,
  fenced as a post's is, since the words are the town's.
  """
  def policy(%{"text" => text} = page) when is_binary(text) do
    to_text(
      join(
        [
          cat([
            shown(page["title"]),
            ~L", published at ",
            url(page["url"]),
            ~L". Its text, quoted:"
          ]),
          fence(text)
        ],
        :line
      )
    )
  end

  def policy(_other), do: nil

  @doc """
  The account's settings, one line per kind, as `get_preferences` returns
  them.
  """
  def preferences(%{} = p) do
    home = p["home_feed"] || %{}
    threads = p["threads"] || %{}
    defaults = p["interaction_defaults"] || %{}
    adult = p["adult_content"] || %{}

    to_text(
      join(
        [
          ~L"Settings. set_preference changes each kind; save_feed and unsave_feed the saved feeds.",
          cat([
            ~L"home_feed (the Following feed, as the app shows it): ",
            on_off([
              {~L"hide_replies", home["hide_replies"]},
              {~L"hide_reposts", home["hide_reposts"]},
              {~L"hide_quotes", home["hide_quotes"]},
              {~L"saved_feed_samples", home["saved_feed_samples"]}
            ])
          ]),
          cat([
            ~L"threads: sort ",
            ident(threads["sort"]),
            ~L", ",
            on_off([{~L"tree_view", threads["tree_view"]}])
          ]),
          cat([
            ~L"interaction_defaults (each new post in the app starts with): reply_rule ",
            ident_list(defaults["reply_rule"]),
            ~L", quotes ",
            ident(defaults["quotes"])
          ]),
          cat([
            ~L"adult_content: ",
            on_off([{~L"enabled", adult["enabled"]}]),
            ~L"; birth date ",
            cond do
              adult["declared_over_18"] == true -> ~L"set, 18 or over"
              adult["birth_date_set"] == true -> ~L"set, under 18"
              true -> ~L"not set"
            end
          ]),
          cat([
            ~L"interests: ",
            case List.wrap(get_in(p, ["interests", "tags"])) do
              [] -> ~L"none"
              tags -> join(Enum.map(tags, &ident/1), :comma)
            end
          ]),
          cat([
            ~L"verification: ",
            on_off([{~L"hide_badges", get_in(p, ["verification", "hide_badges"])}])
          ]),
          cat([
            ~L"discoverable: ",
            on_off([
              {~L"hide_from_recommendations",
               get_in(p, ["discoverable", "hide_from_recommendations"])}
            ])
          ]),
          cat([
            ~L"activity_subscriptions: allow ",
            ident(get_in(p, ["activity_subscriptions", "allow"]))
          ]),
          cat([
            ~L"content_labels (set_label_visibility): ",
            join(
              (p["content_labels"] || %{})
              |> Enum.sort()
              |> Enum.map(fn {label, visibility} ->
                join([ident(label), ident(visibility)], :space)
              end),
              :comma
            )
          ]),
          cat([
            ~L"Labelers the app takes labels from (get_labelers): ",
            case List.wrap(p["labelers"]) do
              [] -> ~L"none"
              dids -> join(Enum.map(dids, &ident/1), :comma)
            end
          ]),
          case List.wrap(p["muted_words"]) do
            [] ->
              ~L"Muted words: none"

            words ->
              join(
                [
                  ~L"Muted words (mute_word, unmute_word):"
                  | Enum.map(words, fn word ->
                      cat([
                        ~L"- ",
                        join(
                          [
                            literal(word["value"]),
                            if(word["tags_only"] == true,
                              do: ~L"tags only",
                              else: ~L"text and tags"
                            ),
                            if(word["only_non_followed"] == true,
                              do: ~L"only accounts not followed"
                            ),
                            cond do
                              word["expired"] == true ->
                                cat([~L"expired ", time(word["expires_at"])])

                              is_binary(word["expires_at"]) ->
                                cat([~L"until ", time(word["expires_at"])])

                              true ->
                                nil
                            end
                          ],
                          :dot
                        )
                      ])
                    end)
                ],
                :line
              )
          end,
          case List.wrap(p["saved_feeds"]) do
            [] ->
              ~L"Saved feeds: none"

            feeds ->
              join([~L"Saved feeds:" | Enum.map(feeds, &saved_feed/1)], :line)
          end,
          case List.wrap(p["app_pinned_feeds"]) do
            [] ->
              nil

            feeds ->
              join(
                [~L"Pinned by the app for every account:" | Enum.map(feeds, &saved_feed/1)],
                :line
              )
          end
        ],
        :line
      )
    )
  end

  def preferences(_other), do: nil

  defp saved_feed(feed) do
    cat([
      ~L"- ",
      join(
        [
          ident(feed["value"]),
          ident(feed["type"]),
          if(feed["pinned"] == true, do: ~L"pinned")
        ],
        :dot
      )
    ])
  end

  # A list of identifiers as JSON writes one: `["following", "at://…"]`.
  defp ident_list(values) when is_list(values),
    do: cat([~L"[", join(Enum.map(values, &cat([~L("), ident(&1), ~L(")])), :comma), ~L"]"])

  defp ident_list(nil), do: ~L"null"
  defp ident_list(other), do: literal(Jason.encode!(other))

  @doc "Labelers in detail, from `get_labelers`."
  def labelers(%{"items" => items} = page) when is_list(items) do
    header =
      cat([
        count(length(items), ~L"labeler", ~L"labelers"),
        ~L".",
        case List.wrap(page["missing"]) do
          [] ->
            nil

          missing ->
            cat([~L" Running no labeler: ", join(Enum.map(missing, &ident/1), :comma), ~L"."])
        end
      ])

    blocks =
      Enum.map(items, fn labeler ->
        join(
          [
            join(
              [
                cat([
                  shown(labeler["display_name"] || labeler["handle"]),
                  ~L" (@",
                  ident(labeler["handle"]),
                  ~L", ",
                  ident(labeler["did"]),
                  ~L")"
                ]),
                cond do
                  labeler["built_in"] == true -> ~L"the network's own moderation service"
                  labeler["subscribed"] == true -> ~L"subscribed"
                  true -> ~L"not subscribed"
                end
              ],
              :dot
            ),
            web(labeler),
            case List.wrap(labeler["labels"]) do
              [] ->
                ~L"Defines no labels of its own."

              labels ->
                join(
                  [
                    ~L"Labels it defines:"
                    | Enum.map(labels, fn label ->
                        cat([
                          ~L"- ",
                          join(
                            [
                              ident(label["identifier"]),
                              shown(label["name"]),
                              if(label["global"] == true,
                                do: ~L"adult content filter, set without labeler"
                              ),
                              if(label["setting"],
                                do: cat([~L"set to ", ident(label["setting"])]),
                                else: cat([~L"default ", ident(label["default"])])
                              ),
                              if(label["adult_only"] == true, do: ~L"adult content")
                            ],
                            :dot
                          ),
                          if(is_binary(label["description"]),
                            do: cat([~L": ", shown(label["description"])])
                          )
                        ])
                      end)
                  ],
                  :line
                )
            end,
            cat([
              ~L"Takes reports: ",
              join(
                [
                  cat([~L"reasons ", any(labeler["reason_types"])]),
                  cat([~L"on ", any(labeler["subject_types"])]),
                  cat([~L"records ", any(labeler["subject_collections"])])
                ],
                :comma
              )
            ])
          ],
          :line
        )
      end)

    to_text(join([header | blocks], :blank))
  end

  def labelers(_other), do: nil

  defp any(values) when is_list(values), do: join(Enum.map(values, &ident/1), :comma)
  defp any(_values), do: ~L"any"

  defp on_off(settings),
    do:
      join(
        Enum.map(settings, fn {name, on} ->
          cat([name, if(on == true, do: ~L" on", else: ~L" off")])
        end),
        :comma
      )

  @doc "The account's notification settings, one line per reason."
  def notification_settings(%{"settings" => settings}) when is_list(settings) do
    to_text(
      join(
        [
          ~L"Notification settings. set_notification_setting changes one reason's."
          | Enum.map(settings, fn setting ->
              cat([
                ident(setting["reason"]),
                ~L": ",
                join(
                  [
                    if(is_binary(setting["include"]),
                      do: cat([~L"from ", ident(setting["include"])])
                    ),
                    on_off([{~L"list", setting["list"]}, {~L"push", setting["push"]}])
                  ],
                  :comma
                )
              ])
            end)
        ],
        :line
      )
    )
  end

  def notification_settings(_other), do: nil

  defp invite_code(%{} = code, label) do
    uses = List.wrap(code["uses"])

    left =
      if is_integer(code["available"]),
        do:
          cat([
            int(max(code["available"] - length(uses), 0)),
            ~L" of ",
            int(code["available"]),
            ~L" uses left"
          ])

    join(
      [
        cat([
          label,
          ~L" ",
          join([ident(code["code"]), left, if(code["disabled"] == true, do: ~L"disabled")], :dot)
        ]),
        case uses do
          [] ->
            nil

          uses ->
            cat([
              ~L"Used by: ",
              join(
                Enum.map(uses, &cat([ident(&1["used_by"]), ~L" at ", time(&1["used_at"])])),
                :comma
              )
            ])
        end
      ],
      :line
    )
  end

  defp invite_code(other, label), do: unknown(other, label)

  # A list's name, kind, size and maker on one line, then what it is for, then
  # its uri and where this account stands with it.
  defp list_heading(list, label) do
    viewer = if is_map(list["viewer"]), do: list["viewer"], else: %{}

    join(
      [
        cat([
          label,
          ~L" ",
          join(
            [
              shown(list["name"]),
              purpose(list["purpose"]),
              if(is_integer(list["item_count"]),
                do: count(list["item_count"], ~L"account", ~L"accounts")
              ),
              by(list["creator"], list["creator_display_name"])
            ],
            :dot
          )
        ]),
        shown(list["description"]),
        labelled(%{"labels" => list["labels"], "author_did" => list["creator_did"]}),
        join(
          [
            if(viewer["muted"] == true, do: ~L"You mute the accounts on it"),
            if(is_binary(viewer["blocked"]),
              do: cat([~L"You block the accounts on it: ", ident(viewer["blocked"])])
            ),
            opted_out(viewer)
          ],
          :dot
        ),
        cat([~L"uri: ", ident(list["uri"])]),
        web(list)
      ],
      :line
    )
  end

  # A starter pack: its name, maker, size and who joined through it, what it
  # is for, the feeds it recommends, some of its accounts, and its list.
  defp pack(pack, label) do
    joined =
      case {pack["joined_week_count"], pack["joined_all_time_count"]} do
        {week, all} when is_integer(week) and is_integer(all) ->
          cat([int(all), ~L" joined through it, ", int(week), ~L" this week"])

        {_week, all} when is_integer(all) ->
          cat([int(all), ~L" joined through it"])

        _ ->
          nil
      end

    feeds =
      case List.wrap(pack["feeds"]) do
        [] ->
          nil

        feeds ->
          cat([
            ~L"Feeds: ",
            join(
              Enum.map(feeds, fn feed ->
                join(
                  [shown(feed["display_name"]), by(feed["creator"], nil), ident(feed["uri"])],
                  :dot
                )
              end),
              :semi
            )
          ])
      end

    sample =
      case List.wrap(pack["members_sample"]) do
        [] ->
          nil

        members ->
          cat([~L"Some of its accounts: ", join(Enum.map(members, &who(account(&1))), :comma)])
      end

    viewer = if is_map(pack["viewer"]), do: pack["viewer"], else: %{}

    join(
      [
        cat([
          label,
          ~L" ",
          join(
            [
              shown(pack["name"]),
              by(pack["creator"], pack["creator_display_name"]),
              if(is_integer(pack["item_count"]),
                do: count(pack["item_count"], ~L"account", ~L"accounts")
              ),
              joined
            ],
            :dot
          )
        ]),
        shown(pack["description"]),
        feeds,
        sample,
        labelled(%{"labels" => pack["labels"], "author_did" => pack["creator_did"]}),
        opted_out(viewer),
        if(is_binary(pack["list"]),
          do: cat([~L"list: ", ident(pack["list"]), ~L" (get_list reads every account)"])
        ),
        cat([~L"uri: ", ident(pack["uri"])]),
        web(pack)
      ],
      :line
    )
  end

  # One account on a list: who it is, the list item that puts it there, and
  # whether it asked to be left out.
  defp member(%{} = member, label) do
    join(
      [
        cat([
          label,
          ~L" ",
          join(
            [
              who(account(member)),
              if(member["opted_out"] == true, do: ~L"asked to be left out of this list")
            ],
            :dot
          )
        ]),
        shown(member["description"]),
        standing(%{"author_viewer" => member["viewer"]}),
        cat([~L"item: ", ident(member["item_uri"])]),
        web(member)
      ],
      :line
    )
  end

  defp member(other, label), do: unknown(other, label)

  # Read with contains: whether that account is in the list or pack.
  defp on_it(%{"member_item" => item}) when is_binary(item),
    do: cat([~L"Contains the account: ", ident(item)])

  defp on_it(%{} = item) when is_map_key(item, "member_item"),
    do: ~L"Does not contain the account"

  defp on_it(_item), do: nil

  defp opted_out(%{"opted_out" => uri}) when is_binary(uri),
    do: cat([~L"You opted out of it: ", ident(uri)])

  defp opted_out(_viewer), do: nil

  defp account(%{} = account),
    do: %{
      "author" => account["handle"],
      "author_did" => account["did"],
      "display_name" => account["display_name"]
    }

  defp by(handle, name) when is_binary(handle),
    do: cat([~L"by ", who(%{"author" => handle, "display_name" => name})])

  defp by(_handle, _name), do: nil

  defp purpose("curate"), do: ~L"curate list"
  defp purpose("moderation"), do: ~L"moderation list"
  defp purpose("reference"), do: ~L"reference list"
  defp purpose(purpose) when is_binary(purpose), do: cat([~L"list for ", ident(purpose)])
  defp purpose(_purpose), do: nil

  # One post: why a feed shows it, when that is not just that it was posted; a
  # header line saying who, when and what it answers; the text; what is
  # attached to it; then the identifiers to act on it with.
  defp post(%{} = post, label) do
    case unavailable(post) do
      nil ->
        header = join([who(post), posted(post), replying(post)], :dot)

        top =
          case reason(post["reason"]) do
            nil -> [cat([label, ~L" ", header])]
            why -> [cat([label, ~L" ", why]), header]
          end

        join(
          top ++
            body(post) ++
            [
              engagement(post),
              known_likers(post["known_likers"]),
              labelled(post),
              AtMcp.ModerationDecision.line(post["moderation"]),
              standing(post),
              who_can_reply(post),
              ids(post),
              web(post)
            ] ++
            viewer(post) ++ [feed_given(post)],
          :line
        )

      why ->
        cat([label, ~L" ", why])
    end
  end

  defp post(other, label), do: unknown(other, label)

  # A post on one line: why a feed shows it, who, when, the first line of its
  # text, its counts, whether moderation marks it, and its uri.
  defp brief(%{} = post, label) do
    case unavailable(post) do
      nil ->
        cat([
          label,
          ~L" ",
          join(
            [
              brief_reason(post["reason"]),
              brief_who(post["author"], post["author_did"]),
              time(post["indexed_at"] || post["created_at"]),
              if(is_binary(post["reply_to"]), do: ~L"a reply"),
              first_line(post["raw_text"] || post["text"]),
              engagement(post),
              if(AtMcp.ModerationDecision.line(post["moderation"]), do: ~L"marked by moderation"),
              ident(post["uri"])
            ],
            :dot
          )
        ])

      why ->
        cat([label, ~L" ", why])
    end
  end

  defp brief(other, label), do: unknown(other, label)

  defp brief_reason(%{"type" => "repost"} = reason),
    do:
      cat([~L"reposted by ", who(%{"author" => reason["by"], "author_did" => reason["by_did"]})])

  defp brief_reason(%{"type" => "pin"}), do: ~L"pinned"
  defp brief_reason(_reason), do: nil

  defp brief_who(handle, _did) when is_binary(handle), do: cat([~L"@", ident(handle)])
  defp brief_who(_handle, did), do: ident(did)

  @first_line 120

  # The text's first non-blank line, at most @first_line characters, quoted;
  # what is cut is said outside the quotes. It is read from the text as
  # written (`raw_text`): cut from the rendered text, a link or mention marker
  # could be cut in half, and inside one quoted literal no marker is needed.
  defp first_line(text) when is_binary(text) do
    lines = text |> String.split(~r/\R/u) |> Enum.map(&one_line/1) |> Enum.reject(&(&1 == ""))

    case lines do
      [] ->
        nil

      [line | rest] ->
        shortened = String.slice(line, 0, @first_line)

        if rest == [] and shortened == line,
          do: literal(line),
          else: cat([literal(shortened), ~L" (continues)"])
    end
  end

  defp first_line(_text), do: nil

  defp unavailable(%{"blocked" => true} = post),
    do: cat([where(post), ~L" is hidden by a block."])

  defp unavailable(%{"not_found" => true} = post),
    do: cat([where(post), ~L" is deleted or missing."])

  defp unavailable(%{"unresolved" => true} = post), do: cat([where(post), ~L" was not read."])
  defp unavailable(_post), do: nil

  defp where(%{"uri" => uri}) when is_binary(uri), do: cat([~L"The post ", ident(uri)])
  defp where(_post), do: ~L"A post"

  # A group of notifications, as the app's Notifications screen shows it: who
  # acted and what they did, then each post it is about with its uri, which
  # the write tools take. A reply, quote or mention the group carries whole
  # reads as a post reads in any other read, as the app shows it as a post.
  defp notification(%{"kind" => kind, "actors" => actors} = group, label)
       when is_binary(kind) or is_list(actors) do
    actors = List.wrap(actors)
    posts = List.wrap(group["posts"])
    count = group["count"]
    whole? = Enum.any?(posts, &is_map(&1["post"]))

    header =
      cat([
        label,
        ~L" ",
        join(
          [
            join(
              [
                who_acted(actors, count, kind),
                group_verb(kind, if(is_integer(count), do: count, else: length(posts)))
              ],
              :space
            ),
            time(group["indexed_at"]),
            if(group["is_read"] == false, do: ~L"unread")
          ],
          :dot
        )
      ])

    join(
      [header] ++
        Enum.map(posts, fn
          %{"post" => %{} = whole} ->
            post(whole, ~L"The post:")

          post ->
            cat([
              ~L"  ",
              join(
                [
                  ident(post["uri"]),
                  web(post),
                  shown(post["text"]),
                  if(is_binary(post["via_repost"]),
                    do: cat([~L"via your repost ", ident(post["via_repost"])])
                  ),
                  if(is_binary(post["parent"]),
                    do: cat([~L"replying to ", ident(post["parent"])])
                  )
                ],
                :dot
              )
            ])
        end) ++
        [
          if(is_binary(group["parent"]) and not whole?,
            do: cat([~L"  replying to ", ident(group["parent"])])
          ),
          if(is_binary(group["starter_pack"]),
            do: cat([~L"  starter pack: ", ident(group["starter_pack"])])
          ),
          if(is_binary(group["generator"]), do: cat([~L"  feed: ", ident(group["generator"])]))
        ],
      :line
    )
  end

  defp notification(%{} = item, label) do
    header =
      cat([
        label,
        ~L" ",
        join(
          [
            join([ident(item["reason"]), ~L"from", who(item)], :space),
            time(item["indexed_at"]),
            if(is_binary(item["text"]), do: archived(item["created_at"], item["indexed_at"])),
            if(item["is_read"] == false, do: ~L"unread")
          ],
          :dot
        )
      ])

    if is_binary(item["text"]) do
      reply_to = item["reply_parent_uri"]
      replying = if is_binary(reply_to), do: cat([~L"replying to ", ident(reply_to)])

      join(
        [join([header, replying], :dot) | body(item)] ++
          [labelled(item), standing(item), ids(item), web(item)],
        :line
      )
    else
      # A like, repost or follow has no text to read and nothing to answer: its
      # own record is not something any tool takes, so it is one line saying
      # what it was about, and anything the app shows about who it is from.
      join(
        [
          header,
          about(item),
          joined_through(item["starter_pack"]),
          labelled(item),
          standing(item)
        ],
        :dot
      )
    end
  end

  # "alice.test, bob.test and 3 others": the accounts the group names, and
  # how many more it holds. A group whose kind is about several posts by one
  # account counts posts, not accounts.
  defp who_acted(actors, count, kind) do
    names = Enum.map(actors, &ident(&1["handle"] || &1["did"]))

    # A group of several posts by one account counts its posts, not accounts:
    # the multiPost groups, and subscribed posts, which the service groups by
    # their author (`groupingKey` in its notification grouping).
    others =
      if is_integer(count) and not one_actor?(kind),
        do: count - length(names),
        else: 0

    case {names, others} do
      {[], _} ->
        nil

      {names, n} when n > 0 ->
        cat([join(names, :comma), ~L" and ", count(n, ~L"other", ~L"others")])

      {[one], _} ->
        one

      {names, _} ->
        cat([join(Enum.drop(names, -1), :comma), ~L" and ", List.last(names)])
    end
  end

  @group_verbs %{
    "likeGroup" => ~L"liked your post",
    "repostGroup" => ~L"reposted your post",
    "likeViaRepostGroup" => ~L"liked your repost",
    "repostViaRepostGroup" => ~L"reposted your repost",
    "followGroup" => ~L"followed you",
    "generatorLikeGroup" => ~L"liked your feed",
    "replyNotification" => ~L"replied",
    "quoteNotification" => ~L"quoted your post",
    "mentionNotification" => ~L"mentioned you",
    "followBackNotification" => ~L"followed you back",
    "verifiedNotification" => ~L"verified your account",
    "unverifiedNotification" => ~L"removed your account's verification",
    "starterPackJoinedNotification" => ~L"joined through your starter pack",
    "contactMatchNotification" => ~L"joined: a contact of yours"
  }

  @multi_verbs %{
    "multiPostLikeGroup" => {~L"liked", ~L"of your posts"},
    "multiPostRepostGroup" => {~L"reposted", ~L"of your posts"},
    "multiPostLikeViaRepostGroup" => {~L"liked", ~L"of your reposts"},
    "multiPostRepostViaRepostGroup" => {~L"reposted", ~L"of your reposts"}
  }

  defp one_actor?(kind),
    do: String.starts_with?(to_string(kind), "multiPost") or kind == "subscribedPostGroup"

  defp group_verb("subscribedPostGroup", 1), do: ~L"posted (you are subscribed)"

  defp group_verb("subscribedPostGroup", posts),
    do: cat([~L"posted ", int(posts), ~L" times (you are subscribed)"])

  defp group_verb(kind, posts) do
    case Map.fetch(@multi_verbs, kind) do
      {:ok, {verb, what}} -> join([verb, int(posts), what], :space)
      :error -> Map.get(@group_verbs, kind) || ident(kind)
    end
  end

  defp joined_through(%{"uri" => uri} = pack) when is_binary(uri),
    do: cat([~L"through the starter pack ", join([shown(pack["name"]), ident(uri)], :space)])

  defp joined_through(_pack), do: nil

  # The time the app shows on a post: when the service first saw it, which
  # the author cannot set. The author's own date goes beside it when it is
  # more than a day earlier. The app says so ("Archived from") on a thread's
  # main post only (`BackdatedPostIndicator` in social-app's
  # ThreadItemAnchor.tsx); here a post reads the same in every read.
  defp posted(post) do
    join(
      [
        time(post["indexed_at"] || post["created_at"]),
        archived(post["created_at"], post["indexed_at"])
      ],
      :dot
    )
  end

  @day_ms 24 * 60 * 60 * 1000

  defp archived(created, indexed) when is_binary(created) and is_binary(indexed) do
    with {:ok, created_dt, _} <- DateTime.from_iso8601(created),
         {:ok, indexed_dt, _} <- DateTime.from_iso8601(indexed),
         true <- DateTime.diff(indexed_dt, created_dt, :millisecond) > @day_ms do
      cat([~L"archived from ", time(created)])
    else
      _ -> nil
    end
  end

  defp archived(_created, _indexed), do: nil

  # What a like, repost or follow is about. A like or repost that came
  # through this account's repost names that repost as its subject; the app
  # shows the post itself, which the record names.
  defp about(%{"reason" => reason, "subject_uri" => repost, "subject_post_uri" => post})
       when reason in ["like-via-repost", "repost-via-repost"] and is_binary(repost) and
              is_binary(post),
       do: cat([~L"on ", ident(post), ~L" via your repost ", ident(repost)])

  defp about(%{"subject_uri" => uri}) when is_binary(uri), do: cat([~L"on ", ident(uri)])
  defp about(_item), do: nil

  # An account as the app names it: its display name, as a literal, then its
  # handle and the badges beside it.
  defp who(%{"author" => handle} = post) when is_binary(handle) do
    name = one_line(post["display_name"])
    you = if post["is_self"] == true, do: ~L" (you)"
    badges = badges(post)
    at = cat([~L"@", ident(handle)])

    if is_binary(name) and name != "" and name != handle,
      do: cat([literal(name), ~L" (", join([at | badges], :comma), ~L")", you]),
      else: cat([at, if(badges != [], do: cat([~L" (", join(badges, :comma), ~L")"])), you])
  end

  defp who(%{"author_did" => did}) when is_binary(did), do: ident(did)
  defp who(_post), do: ~L"unknown author"

  # What the app shows beside a name: its verification check, the
  # trusted-verifier badge, and the Live badge.
  defp badges(post) do
    verification =
      if is_map(post["author_verification"]), do: post["author_verification"], else: %{}

    Enum.reject(
      [
        if(verification["status"] == "valid", do: ~L"verified"),
        if(verification["trusted_verifier"] == "valid", do: ~L"trusted verifier"),
        if(live?(post["author_status"], post["author_viewer"], post["author_labels"]),
          do: ~L"live"
        )
      ],
      &is_nil/1
    )
  end

  # The hosts the app shows a Live badge for, and its rule for showing one,
  # as bluesky-social/social-app has them at 24e0ebbcd18b794934d617de20477c82a37ac2f0:
  # `DEFAULT_ALLOWED_DOMAINS`, `useActorStatus` and `isStatusValidForViewers`
  # in src/features/liveNow/index.tsx, `getLiveNowHost` and
  # `isStatusStillActive` in src/features/liveNow/utils.ts, and `moderateStatus`
  # (packages/api/src/moderation/subjects/status.ts in bluesky-social/atproto
  # at 9f66a7e). The badge shows for a live status whose AT URI is set, whose
  # link is an external embed on one of these hosts (its registrable domain),
  # that is not disabled and has not expired by this machine's clock (the app
  # checks `expiresAt`, not the service's `isActive`), and that moderation does
  # not filter from a content list: no block either way, no mute, no label in
  # effect on the status, and no `!hide` or `!takedown` on the account. The app
  # can add hosts by remote configuration and hide for labels the viewer's
  # moderation preferences hide; neither is visible here, so this can only be
  # stricter on hosts and looser on preference-hidden account labels.
  @live_hosts ~w(twitch.tv stream.place bluecast.app youtube.com substack.com beehiiv.com)

  defp live?(status, viewer, account_labels) do
    viewer = if is_map(viewer), do: viewer, else: %{}

    is_map(status) and is_binary(status["kind"]) and
      status["kind"] == AtMcp.Network.type(:status_live) and is_binary(status["uri"]) and
      status["disabled"] != true and live_host?(status["url"]) and
      future?(status["expires_at"]) and not labelled?(status["labels"]) and
      not is_binary(viewer["blocking"]) and not is_binary(viewer["blocking_by_list"]) and
      viewer["blocked_by"] != true and viewer["muted"] != true and
      not is_binary(viewer["muted_by_list"]) and
      not Enum.any?(List.wrap(account_labels), fn label ->
        is_map(label) and label["val"] in ["!hide", "!takedown"] and label["neg"] != true
      end)
  end

  defp live_host?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
        host = String.downcase(host)
        Enum.any?(@live_hosts, &(host == &1 or String.ends_with?(host, "." <> &1)))

      _ ->
        false
    end
  end

  defp live_host?(_url), do: false

  defp future?(at) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, at, _offset} -> DateTime.compare(at, DateTime.utc_now()) == :gt
      _ -> false
    end
  end

  defp future?(_at), do: false

  # Whether any label is in effect: not expired and not removed by a negation.
  # Unlike the labels line, a `!` value counts: it is an instruction to hide.
  defp labelled?(labels) when is_list(labels) do
    now = DateTime.utc_now()

    current =
      Enum.filter(labels, &(is_map(&1) and is_binary(&1["val"]) and not expired?(&1, now)))

    negated = for %{"neg" => true, "val" => val} <- current, into: MapSet.new(), do: val
    Enum.any?(current, &(&1["neg"] != true and &1["val"] not in negated))
  end

  defp labelled?(_labels), do: false

  # The line the app shows under a gated post: who may reply. Said only when
  # it is not everyone; a post with no gate on it has no line.
  defp who_can_reply(%{"reply_rule" => rule} = post) when is_list(rule) do
    lists = Map.new(List.wrap(post["reply_lists"]), &{&1["uri"], &1["name"]})

    case rule do
      ["everyone"] ->
        nil

      [] ->
        ~L"Who can reply: nobody"

      rules ->
        cat([
          ~L"Who can reply: ",
          join(
            Enum.map(rules, fn
              "mentioned" ->
                ~L"people mentioned"

              "following" ->
                ~L"people they follow"

              "followers" ->
                ~L"their followers"

              "at://" <> _ = uri ->
                join([~L"members of", shown(lists[uri]), ident(uri)], :space)

              other ->
                cat([~L"a rule this version cannot read (", ident(other), ~L")"])
            end),
            :comma
          )
        ])
    end
  end

  defp who_can_reply(_post), do: nil

  # The line the app puts above a post in a feed: "Reposted by" or "Pinned".
  # The repost record's uri is in the structured content.
  defp reason(%{"type" => "repost"} = reason) do
    by =
      who(%{
        "author" => reason["by"],
        "author_did" => reason["by_did"],
        "display_name" => reason["by_display_name"]
      })

    join([cat([~L"Reposted by ", by]), time(reason["at"])], :dot)
  end

  defp reason(%{"type" => "pin"}), do: ~L"Pinned"

  defp reason(%{"type" => type}) when is_binary(type),
    do: cat([~L"In this feed because: ", ident(type)])

  defp reason(_reason), do: nil

  # What a reply answers: the parent's uri, and, when a feed said so, whose post
  # that is and whose thread it is in when the root's author is someone else.
  defp replying(%{"reply_to" => uri} = post) when is_binary(uri) do
    parent = post["reply_parent"]
    root = post["reply_root"]

    in_thread =
      if is_map(root) and root["status"] == "available" and is_binary(root["author"]) and
           root["author_did"] != (is_map(parent) && parent["author_did"]),
         do: cat([~L" in a thread by @", ident(root["author"])])

    cat([~L"replying to ", answered(parent, ident(uri)), in_thread])
  end

  defp replying(_post), do: nil

  defp answered(%{"status" => "available", "author" => handle}, uri) when is_binary(handle),
    do: cat([~L"@", ident(handle), ~L" (", uri, ~L")"])

  defp answered(%{"status" => "not_found"}, uri),
    do: cat([~L"a deleted or missing post (", uri, ~L")"])

  defp answered(%{"status" => "blocked"}, uri),
    do: cat([~L"a post hidden by a block (", uri, ~L")"])

  defp answered(_parent, uri), do: uri

  defp body(post) do
    ([fence(post["text"]) | attachments(post)] ++ [escapes(post)])
    |> Enum.reject(&empty?/1)
  end

  # The author's `<` and backslash are escaped in a post's text
  # (`AtMcp.RichText.render/2`) so that an unescaped `<…>` is always where a
  # link or mention points. A reader that meets an escape is told so, once
  # under the post, so it neither takes the backslash for the author's nor
  # copies it into what it writes.
  defp escapes(post) do
    quote = if is_map(post["quote"]), do: post["quote"]["text"]

    if Enum.any?(
         [post["text"], quote],
         &(is_binary(&1) and String.contains?(&1, ["\\<", "\\\\"]))
       ),
       do:
         ~L"(In post text, \< is the author's < and \\ the author's \; an unescaped <…> is where the link or mention before it points.)"
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
      |> Enum.map(fn {image, n} ->
        cat([~L"[image ", int(n), ~L" of ", int(length(images)), ~L": ", alt(image), ~L"]"])
      end)

    link = link(post["link"], :card)
    video = video(post["video"])
    quote = quoted(post["quote"])

    other =
      if images == [] and Enum.all?([link, video, quote], &is_nil/1) and
           is_binary(post["embed_type"]),
         do: cat([~L"[embed: ", ident(post["embed_type"]), ~L"]"])

    image_lines ++ [link, video, quote, other]
  end

  # Alt text on one line: what the author wrote cannot start a line of its own
  # that reads as another post.
  defp alt(%{"alt" => alt}), do: nonempty(alt) || ~L"no alt text"
  defp alt(_image), do: ~L"no alt text"

  # "[link: "Title" — "description" (https://...)]", leaving out what the card
  # does not have. Inside a quote, the description is left out.
  defp link(%{"uri" => uri} = link, form) when is_binary(uri) do
    said =
      join(
        [nonempty(link["title"]), if(form == :card, do: nonempty(capped(link["description"])))],
        :dash
      )

    address = url(uri)
    card = if empty?(said), do: address, else: cat([said, ~L" (", address, ~L")"])
    cat([~L"[link: ", join([card | publication(link)], :dot), ~L"]"])
  end

  defp link(_link, _form), do: nil

  # What the app adds to a card built from standard.site records: the publish
  # date and reading time on an article's card, then the publication and the
  # account it names as the author.
  defp publication(link) do
    standard =
      Enum.any?(
        List.wrap(link["records"]),
        &(is_binary(&1) and &1 =~ ~r"^at://[^/]+/site\.standard\.")
      )

    pub = if is_map(link["publication"]), do: link["publication"], else: %{}
    author = if is_map(link["author"]), do: link["author"], else: %{}

    [
      if(standard and is_binary(link["published_at"]),
        do: cat([~L"published ", time(link["published_at"])])
      ),
      if(standard and is_integer(link["reading_time"]) and link["reading_time"] > 0,
        do: cat([int(link["reading_time"]), ~L" min read"])
      ),
      if(standard and is_binary(pub["title"]),
        do:
          join(
            [
              ~L"publication",
              shown(pub["title"]),
              if(is_binary(pub["uri"]), do: cat([~L"(", url(pub["uri"]), ~L")"]))
            ],
            :space
          )
      ),
      if(standard and is_binary(author["handle"]), do: cat([~L"by @", ident(author["handle"])]))
    ]
  end

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

  defp video(%{} = video), do: cat([~L"[video: ", alt(video), ~L"]"])
  defp video(_video), do: nil

  defp quoted(%{"status" => "available", "kind" => kind} = quote)
       when kind in ["feed", "list", "starter_pack", "labeler"] do
    what =
      case kind do
        "feed" -> ~L"feed"
        "list" -> ~L"list"
        "starter_pack" -> ~L"starter pack"
        "labeler" -> ~L"labeler"
      end

    name = nonempty(quote["name"])
    by = if is_binary(quote["creator"]), do: cat([~L"by @", ident(quote["creator"])])
    about = nonempty(quote["description"])

    cat([
      ~L"[quoting ",
      join([what, name, by], :space),
      ~L", ",
      ident(quote["uri"]),
      in_brackets(web(quote)),
      if(about, do: cat([~L": ", about])),
      ~L"]"
    ])
  end

  defp quoted(%{"status" => "available"} = quote) do
    images = length(List.wrap(quote["images"]))
    pictures = if images > 0, do: cat([~L" [", count(images, ~L"image", ~L"images"), ~L"]"])

    media =
      for attached <- [link(quote["link"], :quote), video(quote["video"])],
          attached != nil,
          do: cat([~L" ", attached])

    author =
      if is_binary(quote["author"]),
        do:
          who(
            Map.take(quote, [
              "author",
              "display_name",
              "author_verification",
              "author_status",
              "author_viewer",
              "author_labels"
            ])
          ),
        else: ~L"a post"

    # The quoted post's labels and any block or mute with its author, in the
    # words the post's own lines use.
    notes = join([labelled(quote), standing(%{"author_viewer" => quote["author_viewer"]})], :dot)
    notes = if not empty?(notes), do: cat([~L" · ", notes])

    cat(
      [
        ~L"[quoting ",
        join([author, posted(quote)], :dot),
        ~L", ",
        ident(quote["uri"]),
        in_brackets(web(quote)),
        ~L": ",
        shown(quote["text"] || ""),
        pictures
      ] ++ media ++ [notes, ~L"]"]
    )
  end

  defp quoted(%{"status" => status} = quote) when is_binary(status),
    do: cat([~L"[quoting ", ident(quote["uri"]), ~L": ", ident(status), ~L"]"])

  defp quoted(_quote), do: nil

  # What the service counts on the post, in the words a client shows under it.
  # A zero is left out of the text, and a post nobody has engaged with has no
  # line at all; the structured content keeps every count, zeros included.
  defp engagement(post) do
    counts =
      for {key, one, many} <- [
            {"like_count", ~L"like", ~L"likes"},
            {"repost_count", ~L"repost", ~L"reposts"},
            {"reply_count", ~L"reply", ~L"replies"},
            {"quote_count", ~L"quote", ~L"quotes"}
          ],
          is_integer(post[key]) and post[key] > 0,
          do: count(post[key], one, many)

    join(counts, :dot)
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
      {[], []} ->
        nil

      {values, []} ->
        cat([~L"Labels: ", join(values, :comma)])

      {[], values} ->
        cat([~L"Labels: author: ", join(values, :comma)])

      {own, theirs} ->
        cat([~L"Labels: ", join(own, :comma), ~L"; author: ", join(theirs, :comma)])
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
    |> Enum.map(&cat([ident(&1), if(&1 in self, do: ~L" (self)")]))
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

    join(
      [
        cond do
          is_binary(author["blocking_by_list"]) -> ~L"You blocked them via a list"
          is_binary(author["blocking"]) -> ~L"You blocked them"
          true -> nil
        end,
        if(author["blocked_by"] == true, do: ~L"They blocked you"),
        cond do
          is_binary(author["muted_by_list"]) -> ~L"You muted them via a list"
          author["muted"] == true or post["muted_by_viewer"] == true -> ~L"You muted them"
          true -> nil
        end,
        if(post["hidden_by_threadgate"] == true, do: ~L"Hidden by the thread's author"),
        left_out_reason(post),
        if(viewer["reply_disabled"] == true, do: ~L"You cannot reply to this post"),
        if(viewer["embedding_disabled"] == true, do: ~L"You cannot quote this post"),
        if(viewer["thread_muted"] == true, do: ~L"You muted this thread")
      ],
      :dot
    )
  end

  # A left-out reply the service gave no reason for. The read of left-out
  # replies also returns the replies under one it leaves out, and replies left
  # out for reasons it does not name (moderation, a rule), so no reason is
  # claimed: only that the app leaves it out, or that it sits under a reply
  # the app leaves out.
  defp left_out_reason(%{"left_out" => true} = post) do
    cond do
      post["hidden_by_threadgate"] == true or post["muted_by_viewer"] == true ->
        nil

      is_integer(post["depth"]) and post["depth"] > 1 ->
        ~L"Under a reply the app leaves out of the thread"

      true ->
        ~L"Left out of the thread by the app"
    end
  end

  defp left_out_reason(_post), do: nil

  defp ids(post) do
    join(
      [
        if(is_binary(post["uri"]), do: cat([~L"uri: ", ident(post["uri"])])),
        if(is_binary(post["cid"]), do: cat([~L"cid: ", ident(post["cid"])]))
      ],
      :dot
    )
  end

  # The web link a person opens and shares, beside the uri tools take.
  defp web(%{"web_url" => address}) when is_binary(address), do: cat([~L"link: ", url(address)])
  defp web(_item), do: nil

  defp in_brackets(nil), do: nil
  defp in_brackets(said), do: cat([~L" (", said, ~L")"])

  # What a custom feed gave the item, which `feed_feedback` hands back.
  defp feed_given(post) do
    given =
      join(
        [
          if(is_binary(post["feed_context"]),
            do: cat([~L"feed_context: ", literal(post["feed_context"])])
          ),
          if(is_binary(post["req_id"]), do: cat([~L"req_id: ", literal(post["req_id"])]))
        ],
        :dot
      )

    if not empty?(given), do: cat([~L"For feed_feedback: ", given])
  end

  # The viewing account's own like or repost of the post: the uri `unlike` and
  # `unrepost` take, and the reason not to like it twice. Then whether it has
  # bookmarked the post or pinned it to its profile, which the app shows on
  # the bookmark button and in the post's menu.
  defp viewer(%{"viewer" => %{} = viewer}) do
    [
      if(is_binary(viewer["like"]), do: cat([~L"You liked this: ", ident(viewer["like"])])),
      if(is_binary(viewer["repost"]),
        do: cat([~L"You reposted this: ", ident(viewer["repost"])])
      ),
      if(viewer["bookmarked"] == true, do: ~L"You bookmarked this"),
      if(viewer["pinned"] == true, do: ~L"You pinned this to your profile")
    ]
  end

  defp viewer(_post), do: []

  defp ancestors(%{} = parent, acc), do: ancestors(parent["parent"], [parent | acc])
  defp ancestors(_none, acc), do: acc

  defp numbered(n), do: cat([~L"[", int(n), ~L"]"])

  defp parent_label(1), do: ~L"[parent]"
  defp parent_label(up), do: cat([~L"[parent, ", int(up), ~L" up]"])

  # Replies under a node, each labelled by its place: `[reply 2]`, `[reply 2.1]`.
  defp replies(node, path) do
    replies = List.wrap(node["replies"])

    shown =
      replies
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {reply, n} ->
        place = path ++ [n]
        label = cat([~L"[reply ", join(Enum.map(place, &int/1), :period), ~L"]", op_run(reply)])
        [post(reply, label) | replies(reply, place)]
      end)

    case node["replies_omitted"] do
      n when is_integer(n) and n > 0 ->
        shown ++
          [
            cat([
              ~L"(",
              int(n),
              if(n == 1, do: ~L" more reply to ", else: ~L" more replies to "),
              ident(node["uri"]),
              # Under the post itself, the cut's own note says how to read
              # more; under a reply, its own thread is where the rest are, as
              # the app opens it.
              if(path == [],
                do: ~L" not shown)",
                else: ~L" not shown. Call get_thread with that uri to read them.)"
              )
            ])
          ]

      _ ->
        shown
    end
  end

  defp omitted(n) when is_integer(n) and n > 0, do: cat([~L" (", int(n), ~L" more not shown)"])
  defp omitted(_n), do: nil

  defp cut(%{"chain_before" => before} = result) when is_binary(before),
    do:
      cat([
        ~L" ",
        earlier(result["chain_omitted"]),
        ~L"To read further up, call get_thread_chain again with before: ",
        ident(before)
      ])

  defp cut(%{"chain_truncated" => true} = result),
    do:
      cat([
        ~L" ",
        earlier(result["chain_omitted"]),
        ~L"It does not reach the root: an earlier post could not be read."
      ])

  defp cut(_result), do: nil

  defp earlier(n) when is_integer(n) and n > 0,
    do:
      cat([
        int(n),
        if(n == 1, do: ~L" earlier post is not shown. ", else: ~L" earlier posts are not shown. ")
      ])

  defp earlier(_n), do: nil

  defp left_out(%{"left_out" => n}, one, many) when is_integer(n) and n > 0,
    do:
      cat([
        ~L" ",
        int(n),
        ~L" more ",
        if(n == 1, do: one, else: many),
        ~L" did not fit in ",
        int(@page_chars),
        ~L" characters. The cursor below starts with them."
      ])

  defp left_out(%{"over_bound" => true}, _one, _many),
    do:
      cat([
        ~L" This page is longer than ",
        int(@page_chars),
        ~L" characters."
      ])

  defp left_out(_page, _one, _many), do: nil

  # A read asked for what is newer than a position: how many are new, or why
  # it read the newest page instead.
  defp news(%{"since" => at} = page) when is_binary(at) do
    n = if is_integer(page["new_total"]), do: page["new_total"], else: length(page["items"])

    cat([
      ~L" ",
      if(page["new_total_exact"] == false, do: cat([~L"At least ", int(n)]), else: int(n)),
      ~L" new since ",
      time(at),
      ~L"."
    ])
  end

  defp news(%{"since" => nil, "since_unread" => why}) when is_binary(why),
    do:
      cat([
        ~L" at_mcp could not load this account's read position for this feed (",
        ident(why),
        ~L"), so this page starts from the newest item and may repeat items the account has read."
      ])

  defp news(%{"since" => nil}),
    do:
      ~L" This was the first read of this feed with last_read, so the page starts from the newest item. To read further back, pass the cursor without since."

  defp news(_page), do: nil

  # The notifications have two times: the network's seen marker (what the app
  # counts as unread) and at_mcp's read position, kept in its state folder.
  defp notification_news(%{"since" => at, "since_asked" => "last_read"} = page)
       when is_binary(at) do
    n = if is_integer(page["new_total"]), do: page["new_total"], else: length(page["items"])

    cat([
      ~L" ",
      if(page["new_total_exact"] == false, do: cat([~L"At least ", int(n)]), else: int(n)),
      ~L" new since this account last read here at ",
      time(at),
      ~L"."
    ])
  end

  defp notification_news(page), do: news(page)

  # A last_read read moves only at_mcp's position; the app's seen marker stays
  # behind until update_seen. Each item says whether the app counts it read.
  defp still_unread(%{"since_asked" => "last_read", "items" => items}) when is_list(items) do
    case Enum.count(items, &(&1["is_read"] == false)) do
      0 ->
        nil

      n when n == length(items) ->
        ~L" The app still counts them unread; update_seen marks them seen."

      n ->
        cat([
          ~L" The app still counts ",
          int(n),
          ~L" of them unread; update_seen marks them seen."
        ])
    end
  end

  defp still_unread(_page), do: nil

  defp unsaved(%{"read_position_unsaved" => why}) when is_binary(why),
    do:
      cat([
        ~L" at_mcp could not save the read position (",
        ident(why),
        ~L"), so the next read with last_read returns these items again."
      ])

  defp unsaved(_page), do: nil

  defp next_page(%{"cursor" => cursor, "since" => at} = page)
       when is_binary(cursor) and is_binary(at),
       do:
         cat([
           ~L" To get the rest of the new items, pass cursor: ",
           ident(cursor),
           ~L" with since: ",
           if(page["since_asked"] == "last_read", do: ~L"last_read", else: time(at))
         ])

  defp next_page(%{"cursor" => cursor}) when is_binary(cursor),
    do: cat([~L" For the next page, pass cursor: ", ident(cursor)])

  defp next_page(_page), do: nil
end
