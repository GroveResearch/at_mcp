defmodule AtMcp.Reading do
  @moduledoc """
  The text a model reads for a result made of posts, and for accounts, lists,
  starter packs, feeds, trends, invitation codes and the account's settings.

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
    header =
      if Map.has_key?(page, "seen_at") do
        count(length(items), "notification group", "notification groups") <>
          "." <>
          if(is_binary(page["seen_at"]), do: " Seen up to #{page["seen_at"]}.", else: "") <>
          next_page(page)
      else
        count(length(items), "notification", "notifications") <> "." <> next_page(page)
      end

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
      omitted ++
        above ++ [post(node, "[this post]")] ++ replies(node, "reply ") ++ hidden(node),
      "\n\n"
    )
  end

  def thread(_other), do: nil

  # Asked for with `include_hidden`: the replies the app leaves out of the
  # thread. Those the read returned are marked where they stand; the rest are
  # listed after it, each saying why. Not asked for, there is no
  # `hidden_replies` and no line.
  defp hidden(%{"hidden_replies_unread" => why}) when is_binary(why), do: [why]

  defp hidden(%{"hidden_replies" => hidden} = node) when is_list(hidden) do
    in_place = count_left_out(node)

    marked =
      if in_place > 0,
        do: [
          "Replies above that the app leaves out of the thread, each marked where it stands: #{in_place}."
        ],
        else: []

    case hidden do
      [] when in_place == 0 ->
        ["No replies under this post are left out."]

      [] ->
        marked

      hidden ->
        marked ++
          [
            "Replies under this post left out of the thread: #{length(hidden)}."
            | hidden
              |> Enum.with_index(1)
              |> Enum.map(fn {reply, n} -> post(reply, "[left out #{n}]") end)
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

  @doc """
  One account, from `get_profile`, as its profile page in the app heads it:
  who it is and the badges beside its name, how it relates to this account,
  its description, counts and links, and what it has pinned or made.
  """
  def profile(%{"handle" => handle} = profile) when is_binary(handle),
    do: account_card(profile, "Profile", :full)

  def profile(_other), do: nil

  @doc """
  A page of accounts: followers, follows, search results, suggestions,
  blocks, mutes, likers and reposters, and `get_profiles`.
  """
  def profiles(%{"items" => items} = page) when is_list(items) do
    header = count(length(items), "account", "accounts") <> "." <> next_page(page)

    blocks =
      items
      |> Enum.with_index(1)
      |> Enum.map(fn {account, n} -> account_card(account, "[#{n}]", :brief) end)

    lines([header | blocks], "\n\n")
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

    lines(
      [
        label <>
          " " <>
          lines(
            [
              name,
              one_line(account["pronouns"]),
              if(account["labeler"] == true, do: "runs a labeler")
            ],
            " · "
          ),
        relation(viewer),
        if(form == :full, do: account["description"], else: one_line(account["description"])),
        lines(
          [
            counted(account["followers"], "follower", "followers"),
            counted(account["follows"], "following", "following"),
            counted(account["posts"], "post", "posts"),
            if(is_binary(account["created_at"]), do: "joined #{account["created_at"]}")
          ],
          " · "
        ),
        lines(
          [
            counted(account["lists"], "list", "lists"),
            counted(account["feeds"], "feed", "feeds"),
            counted(account["starter_packs"], "starter pack", "starter packs")
          ],
          " · "
        )
        |> then(&if(&1 != "", do: "Made: " <> &1)),
        if(is_binary(account["website"]), do: "Website: #{escape_uri(account["website"])}"),
        case List.wrap(account["links"]) do
          [] ->
            nil

          links ->
            "Links: " <>
              Enum.map_join(links, "; ", fn link ->
                url = if is_binary(link["url"]), do: escape_uri(link["url"])

                case one_line(link["title"]) do
                  title when title not in [nil, ""] -> lines([title, url && "(#{url})"], " ")
                  _ -> url
                end
              end)
        end,
        if(is_binary(account["pinned_post"]), do: "Pinned post: #{account["pinned_post"]}"),
        live_line(account["status"], viewer, account["labels"]),
        if(form == :full,
          do:
            lines(
              [
                if(is_binary(account["avatar"]), do: "Avatar: #{escape_uri(account["avatar"])}"),
                if(is_binary(account["banner"]), do: "Banner: #{escape_uri(account["banner"])}")
              ],
              " · "
            )
        ),
        verified_by(account["verification"]),
        labelled(%{"labels" => account["labels"], "author_did" => account["did"]}),
        known_followers(account["known_followers"]),
        joined_via(account["joined_via"]),
        messages_from(account["messages_from"]),
        subscriptions_from(account["subscriptions_from"]),
        subscribed(account["activity_subscription"]),
        if(is_binary(account["did"]), do: "did: #{account["did"]}")
      ],
      "\n"
    )
  end

  defp account_card(other, label, _form), do: "#{label} #{Jason.encode!(other)}"

  defp counted(n, one, many) when is_integer(n) and n > 0, do: count(n, one, many)
  defp counted(_n, _one, _many), do: nil

  # How the account relates to this one, with the record URIs `unfollow` and
  # `unblock` take, and the list a block or mute comes through. A block
  # through a list puts the list's URI in `blocking`, which `unblock` refuses,
  # so only the list is named then.
  defp relation(viewer) do
    lines(
      [
        if(is_binary(viewer["following"]), do: "You follow them: #{viewer["following"]}"),
        if(is_binary(viewer["followed_by"]), do: "Follows you"),
        cond do
          is_binary(viewer["blocking_by_list"]) ->
            "You blocked them via a list: #{viewer["blocking_by_list"]}"

          is_binary(viewer["blocking"]) ->
            "You blocked them: #{viewer["blocking"]}"

          true ->
            nil
        end,
        if(viewer["blocked_by"] == true, do: "They blocked you"),
        cond do
          is_binary(viewer["muted_by_list"]) ->
            "You muted them via a list: #{viewer["muted_by_list"]}"

          viewer["muted"] == true ->
            "You muted them"

          true ->
            nil
        end
      ],
      " · "
    )
  end

  defp live_line(status, viewer, labels) do
    if live?(status, viewer, labels) do
      lines(
        [
          "Live:",
          one_line(status["title"]),
          if(is_binary(status["url"]), do: escape_uri(status["url"])),
          if(is_binary(status["expires_at"]), do: "until #{status["expires_at"]}")
        ],
        " "
      )
    end
  end

  defp verified_by(%{"status" => "valid", "by" => [_ | _] = by}) do
    case for(%{"valid" => true} = v <- by, do: v) do
      [] ->
        nil

      valid ->
        "Verified by: " <>
          Enum.map_join(valid, ", ", fn v ->
            who(%{
              "author" => v["issuer_handle"],
              "author_did" => v["issuer"],
              "display_name" => v["issuer_display_name"]
            })
          end)
    end
  end

  defp verified_by(_verification), do: nil

  # The app's "Followed by A, B and 3 others".
  defp known_followers(%{"followers" => [_ | _] = shown} = known) do
    names = Enum.map(shown, &who(account(&1)))
    others = if is_integer(known["count"]), do: known["count"] - length(shown), else: 0

    "Followed by " <>
      case others do
        n when n > 0 -> Enum.join(names, ", ") <> " and #{count(n, "other", "others")}"
        _ -> Enum.join(names, ", ")
      end
  end

  defp known_followers(_known), do: nil

  defp joined_via(%{"uri" => uri} = pack) when is_binary(uri),
    do:
      "Joined through the starter pack " <>
        lines([named(pack["name"]), by(pack["creator"], nil), uri], " ")

  defp joined_via(_pack), do: nil

  defp messages_from("all"), do: "Takes messages from everyone"
  defp messages_from("following"), do: "Takes messages from people they follow"
  defp messages_from("none"), do: "Takes no messages"
  defp messages_from(other) when is_binary(other), do: "Takes messages from: #{other}"
  defp messages_from(_none), do: nil

  # Who may subscribe to the account's posts; followers, which no
  # declaration also means, goes without saying.
  defp subscriptions_from("mutuals"), do: "Lets only mutuals subscribe to its posts"
  defp subscriptions_from("none"), do: "Lets no one subscribe to its posts"
  defp subscriptions_from(_followers), do: nil

  defp subscribed(%{"posts" => true, "replies" => true}),
    do: "You are subscribed to its posts and replies"

  defp subscribed(%{"posts" => true}), do: "You are subscribed to its posts"
  defp subscribed(_none), do: nil

  @doc """
  A page of custom feeds: suggested, searched, an account's, or read by uri.
  Each with its name, maker, likes and whether it takes feedback, then what it
  is for, and the uri and cid `get_feed` and `like` take.
  """
  def feeds(%{"items" => items} = page) when is_list(items) do
    header = count(length(items), "feed", "feeds") <> "." <> next_page(page)

    blocks =
      items
      |> Enum.with_index(1)
      |> Enum.map(fn {feed, n} -> feed(feed, "[#{n}]") end)

    missing =
      case page["not_found"] do
        [_ | _] = uris -> ["The service does not know: " <> Enum.join(uris, ", ")]
        _ -> []
      end

    lines([header | blocks] ++ missing, "\n\n")
  end

  def feeds(_other), do: nil

  defp feed(%{} = feed, label) do
    viewer = if is_map(feed["viewer"]), do: feed["viewer"], else: %{}

    lines(
      [
        label <>
          " " <>
          lines(
            [
              named(feed["display_name"]),
              by(feed["creator"], feed["creator_display_name"]),
              if(is_integer(feed["like_count"]), do: count(feed["like_count"], "like", "likes")),
              if(AtMcp.Effects.takes_feedback?(feed["uri"], feed["accepts_interactions"]),
                do: "takes feedback"
              ),
              online(feed)
            ],
            " · "
          ),
        one_line(feed["description"]),
        labelled(%{"labels" => feed["labels"], "author_did" => feed["creator_did"]}),
        if(is_binary(viewer["like"]), do: "You liked this: #{viewer["like"]}"),
        if(is_binary(feed["avatar"]), do: "Avatar: #{escape_uri(feed["avatar"])}"),
        ids(feed)
      ],
      "\n"
    )
  end

  defp feed(other, label), do: "#{label} #{Jason.encode!(other)}"

  defp online(%{"is_online" => false}), do: "its service is offline"
  defp online(%{"is_valid" => false}), do: "its service does not match its record"
  defp online(%{"is_online" => true}), do: "online"
  defp online(_feed), do: nil

  @doc """
  Trends or trending topics: what each is called, how hot and how big, what it
  is about, some of the accounts posting, and the link the app opens for it.
  """
  def trends(%{"items" => items} = page) when is_list(items) do
    header = count(length(items), "trend", "trends") <> "."

    blocks =
      items
      |> Enum.with_index(1)
      |> Enum.map(fn {trend, n} -> trend(trend, "[#{n}]") end)

    suggested =
      case page["suggested"] do
        [_ | _] = topics ->
          [
            "Suggested beside them: " <>
              Enum.map_join(topics, "; ", fn topic ->
                lines([topic["display_name"] || topic["topic"], topic["link"]], " · ")
              end)
          ]

        _ ->
          []
      end

    lines([header | blocks] ++ suggested, "\n\n")
  end

  def trends(_other), do: nil

  defp trend(%{} = trend, label) do
    lines(
      [
        label <>
          " " <>
          lines(
            [
              one_line(trend["display_name"] || trend["topic"]),
              trend["status"],
              trend["category"],
              if(is_integer(trend["post_count"]),
                do: count(trend["post_count"], "post", "posts")
              ),
              if(is_binary(trend["started_at"]), do: "since #{trend["started_at"]}")
            ],
            " · "
          ),
        one_line(trend["description"]),
        case List.wrap(trend["actors"]) do
          [] -> nil
          actors -> "Posting: " <> Enum.map_join(actors, ", ", &who(account(&1)))
        end,
        if(is_binary(trend["link"]), do: "link: #{trend["link"]}")
      ],
      "\n"
    )
  end

  defp trend(other, label), do: "#{label} #{Jason.encode!(other)}"

  @doc "This account's invitation codes: each, how many uses it has left, and who used it."
  def invite_codes(%{"items" => items} = result) when is_list(items) do
    header =
      lines(
        [
          count(length(items), "invitation code", "invitation codes") <> ".",
          if(is_binary(result["collection"]), do: "Earned codes: #{result["collection"]}.")
        ],
        " "
      )

    blocks =
      items
      |> Enum.with_index(1)
      |> Enum.map(fn {code, n} -> invite_code(code, "[#{n}]") end)

    lines([header | blocks], "\n\n")
  end

  def invite_codes(_other), do: nil

  @doc """
  The account's settings, one line per kind, as `get_preferences` returns
  them.
  """
  def preferences(%{} = p) do
    home = p["home_feed"] || %{}
    threads = p["threads"] || %{}
    defaults = p["interaction_defaults"] || %{}
    adult = p["adult_content"] || %{}

    lines(
      [
        "Settings. set_preference changes each kind; save_feed and unsave_feed the saved feeds.",
        "home_feed (the Following feed, as the app shows it): " <>
          on_off([
            {"hide_replies", home["hide_replies"]},
            {"hide_reposts", home["hide_reposts"]},
            {"hide_quotes", home["hide_quotes"]},
            {"saved_feed_samples", home["saved_feed_samples"]}
          ]),
        "threads: sort #{threads["sort"]}, " <> on_off([{"tree_view", threads["tree_view"]}]),
        "interaction_defaults (each new post in the app starts with): reply_rule " <>
          Jason.encode!(defaults["reply_rule"]) <> ", quotes #{defaults["quotes"]}",
        "adult_content: " <>
          on_off([{"enabled", adult["enabled"]}]) <>
          "; birth date " <>
          cond do
            adult["declared_over_18"] == true -> "set, 18 or over"
            adult["birth_date_set"] == true -> "set, under 18"
            true -> "not set"
          end,
        "interests: " <>
          case List.wrap(get_in(p, ["interests", "tags"])) do
            [] -> "none"
            tags -> Enum.join(tags, ", ")
          end,
        "verification: " <> on_off([{"hide_badges", get_in(p, ["verification", "hide_badges"])}]),
        "discoverable: " <>
          on_off([
            {"hide_from_recommendations",
             get_in(p, ["discoverable", "hide_from_recommendations"])}
          ]),
        "activity_subscriptions: allow #{get_in(p, ["activity_subscriptions", "allow"])}",
        "content_labels (set_label_visibility): " <>
          ((p["content_labels"] || %{})
           |> Enum.sort()
           |> Enum.map_join(", ", fn {label, visibility} -> "#{label} #{visibility}" end)),
        "Labelers the app takes labels from (get_labelers): " <>
          case List.wrap(p["labelers"]) do
            [] -> "none"
            dids -> Enum.join(dids, ", ")
          end,
        case List.wrap(p["muted_words"]) do
          [] ->
            "Muted words: none"

          words ->
            "Muted words (mute_word, unmute_word):\n" <>
              Enum.map_join(words, "\n", fn word ->
                "- " <>
                  lines(
                    [
                      inspect(word["value"]),
                      if(word["tags_only"] == true, do: "tags only", else: "text and tags"),
                      if(word["only_non_followed"] == true,
                        do: "only accounts not followed"
                      ),
                      cond do
                        word["expired"] == true -> "expired #{word["expires_at"]}"
                        is_binary(word["expires_at"]) -> "until #{word["expires_at"]}"
                        true -> nil
                      end
                    ],
                    " · "
                  )
              end)
        end,
        case List.wrap(p["saved_feeds"]) do
          [] ->
            "Saved feeds: none"

          feeds ->
            "Saved feeds:\n" <>
              Enum.map_join(feeds, "\n", fn feed ->
                "- " <>
                  lines(
                    [feed["value"], feed["type"], if(feed["pinned"] == true, do: "pinned")],
                    " · "
                  )
              end)
        end
      ],
      "\n"
    )
  end

  def preferences(_other), do: nil

  @doc "Labelers in detail, from `get_labelers`."
  def labelers(%{"items" => items} = page) when is_list(items) do
    header =
      count(length(items), "labeler", "labelers") <>
        "." <>
        case List.wrap(page["missing"]) do
          [] -> ""
          missing -> " Running no labeler: #{Enum.join(missing, ", ")}."
        end

    blocks =
      Enum.map(items, fn labeler ->
        lines(
          [
            lines(
              [
                "#{labeler["display_name"] || labeler["handle"]} (@#{labeler["handle"]}, #{labeler["did"]})",
                cond do
                  labeler["built_in"] == true -> "the network's own moderation service"
                  labeler["subscribed"] == true -> "subscribed"
                  true -> "not subscribed"
                end
              ],
              " · "
            ),
            case List.wrap(labeler["labels"]) do
              [] ->
                "Defines no labels of its own."

              labels ->
                "Labels it defines:\n" <>
                  Enum.map_join(labels, "\n", fn label ->
                    "- " <>
                      lines(
                        [
                          label["identifier"],
                          label["name"],
                          if(label["global"] == true,
                            do: "adult content filter, set without labeler"
                          ),
                          if(label["setting"],
                            do: "set to #{label["setting"]}",
                            else: "default #{label["default"]}"
                          ),
                          if(label["adult_only"] == true, do: "adult content")
                        ],
                        " · "
                      ) <>
                      if(is_binary(label["description"]),
                        do: ": #{label["description"]}",
                        else: ""
                      )
                  end)
            end,
            "Takes reports: " <>
              lines(
                [
                  "reasons #{any(labeler["reason_types"])}",
                  "on #{any(labeler["subject_types"])}",
                  "records #{any(labeler["subject_collections"])}"
                ],
                ", "
              )
          ],
          "\n"
        )
      end)

    lines([header | blocks], "\n\n")
  end

  def labelers(_other), do: nil

  defp any(values) when is_list(values), do: Enum.join(values, ", ")
  defp any(_values), do: "any"

  defp on_off(settings),
    do:
      Enum.map_join(settings, ", ", fn {name, on} ->
        "#{name} #{if on == true, do: "on", else: "off"}"
      end)

  @doc "The account's notification settings, one line per reason."
  def notification_settings(%{"settings" => settings}) when is_list(settings) do
    lines(
      [
        "Notification settings. set_notification_setting changes one reason's."
        | Enum.map(settings, fn setting ->
            "#{setting["reason"]}: " <>
              lines(
                [
                  if(is_binary(setting["include"]), do: "from #{setting["include"]}"),
                  on_off([{"list", setting["list"]}, {"push", setting["push"]}])
                ],
                ", "
              )
          end)
      ],
      "\n"
    )
  end

  def notification_settings(_other), do: nil

  defp invite_code(%{} = code, label) do
    uses = List.wrap(code["uses"])

    left =
      if is_integer(code["available"]),
        do: "#{max(code["available"] - length(uses), 0)} of #{code["available"]} uses left"

    lines(
      [
        label <>
          " " <>
          lines([code["code"], left, if(code["disabled"] == true, do: "disabled")], " · "),
        case uses do
          [] ->
            nil

          uses ->
            "Used by: " <> Enum.map_join(uses, ", ", &"#{&1["used_by"]} at #{&1["used_at"]}")
        end
      ],
      "\n"
    )
  end

  defp invite_code(other, label), do: "#{label} #{Jason.encode!(other)}"

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
            [engagement(post), labelled(post), standing(post), who_can_reply(post), ids(post)] ++
            viewer(post) ++ [feed_given(post)],
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

  # A group of notifications, as the app's Notifications screen shows it: who
  # acted and what they did, then each post it is about with its uri, which
  # the write tools take.
  defp notification(%{"kind" => kind, "actors" => actors} = group, label)
       when is_binary(kind) or is_list(actors) do
    actors = List.wrap(actors)
    posts = List.wrap(group["posts"])
    count = group["count"]

    header =
      label <>
        " " <>
        lines(
          [
            lines(
              [
                who_acted(actors, count, kind),
                group_verb(kind, if(is_integer(count), do: count, else: length(posts)))
              ],
              " "
            ),
            group["indexed_at"],
            if(group["is_read"] == false, do: "unread")
          ],
          " · "
        )

    lines(
      [header] ++
        Enum.map(posts, fn post ->
          "  " <>
            lines(
              [
                post["uri"],
                if(is_binary(post["text"]), do: inspect(one_line(post["text"]))),
                if(is_binary(post["via_repost"]), do: "via your repost #{post["via_repost"]}"),
                if(is_binary(post["parent"]), do: "replying to #{post["parent"]}")
              ],
              " · "
            )
        end) ++
        [
          if(is_binary(group["parent"]), do: "  replying to #{group["parent"]}"),
          if(is_binary(group["starter_pack"]), do: "  starter pack: #{group["starter_pack"]}"),
          if(is_binary(group["generator"]), do: "  feed: #{group["generator"]}")
        ],
      "\n"
    )
  end

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

      lines(
        [lines([header, replying], " · ") | body(item)] ++
          [labelled(item), standing(item), ids(item)],
        "\n"
      )
    else
      # A like, repost or follow has no text to read and nothing to answer: its
      # own record is not something any tool takes, so it is one line saying
      # what it was about, and anything the app shows about who it is from.
      lines(
        [
          header,
          about(item["subject_uri"]),
          joined_through(item["starter_pack"]),
          labelled(item),
          standing(item)
        ],
        " · "
      )
    end
  end

  # "alice.test, bob.test and 3 others": the accounts the group names, and
  # how many more it holds. A group whose kind is about several posts by one
  # account counts posts, not accounts.
  defp who_acted(actors, count, kind) do
    names = Enum.map(actors, &(&1["handle"] || &1["did"]))

    # A group of several posts by one account counts its posts, not accounts:
    # the multiPost groups, and subscribed posts, which the service groups by
    # their author (`groupingKey` in its notification grouping).
    others =
      if is_integer(count) and not one_actor?(kind),
        do: count - length(names),
        else: 0

    case {names, others} do
      {[], _} -> nil
      {names, n} when n > 0 -> Enum.join(names, ", ") <> " and #{count(n, "other", "others")}"
      {[one], _} -> one
      {names, _} -> Enum.join(Enum.drop(names, -1), ", ") <> " and " <> List.last(names)
    end
  end

  @group_verbs %{
    "likeGroup" => "liked your post",
    "repostGroup" => "reposted your post",
    "likeViaRepostGroup" => "liked your repost",
    "repostViaRepostGroup" => "reposted your repost",
    "followGroup" => "followed you",
    "generatorLikeGroup" => "liked your feed",
    "replyNotification" => "replied",
    "quoteNotification" => "quoted your post",
    "mentionNotification" => "mentioned you",
    "followBackNotification" => "followed you back",
    "verifiedNotification" => "verified your account",
    "unverifiedNotification" => "removed your account's verification",
    "starterPackJoinedNotification" => "joined through your starter pack",
    "contactMatchNotification" => "joined: a contact of yours"
  }

  @multi_verbs %{
    "multiPostLikeGroup" => {"liked", "of your posts"},
    "multiPostRepostGroup" => {"reposted", "of your posts"},
    "multiPostLikeViaRepostGroup" => {"liked", "of your reposts"},
    "multiPostRepostViaRepostGroup" => {"reposted", "of your reposts"}
  }

  defp one_actor?(kind),
    do: String.starts_with?(to_string(kind), "multiPost") or kind == "subscribedPostGroup"

  defp group_verb("subscribedPostGroup", 1), do: "posted (you are subscribed)"

  defp group_verb("subscribedPostGroup", posts),
    do: "posted #{posts} times (you are subscribed)"

  defp group_verb(kind, posts) do
    case Map.fetch(@multi_verbs, kind) do
      {:ok, {verb, what}} -> "#{verb} #{posts} #{what}"
      :error -> Map.get(@group_verbs, kind, kind)
    end
  end

  defp joined_through(%{"uri" => uri} = pack) when is_binary(uri),
    do: "through the starter pack " <> lines([named(pack["name"]), uri], " ")

  defp joined_through(_pack), do: nil

  defp about(uri) when is_binary(uri), do: "on #{uri}"
  defp about(_uri), do: nil

  defp who(%{"author" => handle} = post) when is_binary(handle) do
    name = post["display_name"]
    you = if post["is_self"] == true, do: " (you)", else: ""
    badges = badges(post)

    if is_binary(name) and String.trim(name) != "" and name != handle,
      do: "#{name} (#{Enum.join(["@" <> handle | badges], ", ")})#{you}",
      else: "@#{handle}#{if badges != [], do: " (#{Enum.join(badges, ", ")})"}#{you}"
  end

  defp who(%{"author_did" => did}) when is_binary(did), do: did
  defp who(_post), do: "unknown author"

  # What the app shows beside a name: its verification check, the
  # trusted-verifier badge, and the Live badge.
  defp badges(post) do
    verification =
      if is_map(post["author_verification"]), do: post["author_verification"], else: %{}

    Enum.reject(
      [
        if(verification["status"] == "valid", do: "verified"),
        if(verification["trusted_verifier"] == "valid", do: "trusted verifier"),
        if(live?(post["author_status"], post["author_viewer"], post["author_labels"]),
          do: "live"
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
        "Who can reply: nobody"

      rules ->
        "Who can reply: " <>
          Enum.map_join(rules, ", ", fn
            "mentioned" -> "people mentioned"
            "following" -> "people they follow"
            "followers" -> "their followers"
            "at://" <> _ = uri -> lines(["members of", named(lists[uri]), uri], " ")
            other -> "a rule this version cannot read (#{other})"
          end)
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
        else: "a post"

    # The quoted post's labels and any block or mute with its author, in the
    # words the post's own lines use.
    notes =
      case lines([labelled(quote), standing(%{"author_viewer" => quote["author_viewer"]})], " · ") do
        "" -> ""
        notes -> " · " <> notes
      end

    "[quoting #{author}, #{quote["uri"]}: #{quote["text"]}#{pictures}#{media}#{notes}]"
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
          author["muted"] == true or post["muted_by_viewer"] == true -> "You muted them"
          true -> nil
        end,
        if(post["hidden_by_threadgate"] == true, do: "Hidden by the thread's author"),
        left_out_reason(post),
        if(viewer["reply_disabled"] == true, do: "You cannot reply to this post"),
        if(viewer["embedding_disabled"] == true, do: "You cannot quote this post"),
        if(viewer["thread_muted"] == true, do: "You muted this thread")
      ],
      " · "
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
        "Under a reply the app leaves out of the thread"

      true ->
        "Left out of the thread by the app"
    end
  end

  defp left_out_reason(_post), do: nil

  defp ids(post) do
    lines(
      [
        if(is_binary(post["uri"]), do: "uri: #{post["uri"]}"),
        if(is_binary(post["cid"]), do: "cid: #{post["cid"]}")
      ],
      " · "
    )
  end

  # What a custom feed gave the item, which `feed_feedback` hands back.
  defp feed_given(post) do
    case lines(
           [
             if(is_binary(post["feed_context"]), do: "feed_context: #{post["feed_context"]}"),
             if(is_binary(post["req_id"]), do: "req_id: #{post["req_id"]}")
           ],
           " · "
         ) do
      "" -> nil
      given -> "For feed_feedback: " <> given
    end
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
