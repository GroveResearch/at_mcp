defmodule AtMcp.LeftOut do
  @moduledoc """
  What the AppView returns that no summary passes on, and why.

  `AtMcp.Summary` declares what a read keeps. This is the other half: every
  field of a recorded AppView response that reaches no summary is named here,
  with the reason it is left out or the issue that will pass it on.
  `test/at_mcp/field_coverage_test.exs` changes each field of the recorded
  responses in `test/fixtures/appview` one at a time. A field whose change does
  not change the summary has been dropped, and the test fails unless an entry
  here names it. It also fails on a `{:todo, issue}` entry that covers any field
  that is read (the fix landed, so the entry narrows), on a reason entry all of
  whose fields are read, and on a field two entries cover.

  A pattern is a field path as the lexicon spells it, with `[]` for a list
  element. `*` stands for one segment, and a leading `**.` stands for any
  prefix, including none. A pattern names a subtree. A reason entry may cover
  a subtree some of whose fields are read, and its reason says which; a TODO
  entry covers only fields that are dropped.

  A reason is a sentence, or `{:todo, issue}` for a drop that hides something a
  person sees in the app and is waiting on that GroveResearch/at_mcp issue.
  """

  @entries [
    # Why a post is in a feed, and who a reply answers.
    {"feed[].reply.parent",
     "The parent post's content and counts; `reply_parent` keeps its uri and author, and `get_posts` reads the rest"},
    {"feed[].reply.root",
     "The thread root's content and counts; `reply_root` keeps its uri and author, and `get_thread_chain` reads the conversation"},
    {"feed[].reply.grandparentAuthor",
     "Who the parent itself answered; the app shows only whose post the reply answers"},
    {"feed[].reason.cid",
     "The repost record's CID; `unrepost` takes its uri, which `reason` keeps"},
    {"feed[].reason.by.createdAt",
     "When the reposter's account was made; `reason` names who reposted"},
    {"feed[].opThreadPostIndex",
     "The post's place in its author's self-thread (the app's 1/3); `reply_to` and `get_thread_chain` place it"},
    {"feed[].opThreadPostCount",
     "The length of the author's self-thread (the app's 1/3); `get_thread_chain` reads it"},

    # Who may reply.
    {"threadgate",
     "The thread's gate beside the thread: get_thread marks the replies it hides, and `reply_rule` reads who may reply from the same gate on the first post's view; its uri, cid and time are not what the app shows"},
    {"**.post.threadgate",
     "The gate on a thread's first post beyond who may reply, which `reply_rule` and `reply_lists` read: get_thread marks the replies it hides, and its uri, cid and time are not what the app shows"},

    # What a link card, video or quoted record carries beyond what the app shows.
    {"**.external.source",
     "The publication behind a link card (its name, icon and colours); `link` keeps the card's own title, description and destination"},
    {"**.external.associatedRefs",
     "Records that back a link card's view; `link` keeps the destination the app opens"},
    {"**.external.associatedProfiles",
     "Accounts associated with a link card's site; the app's card shows the link, not them"},
    {"**.external.createdAt",
     "When the linked page was published; the app's card does not show it"},
    {"**.embed.cid", "The video blob's CID; `video` keeps its playlist and thumbnail URLs"},
    {"**.embeds[].cid",
     "The quoted video's blob CID; `video` keeps its playlist and thumbnail URLs"},
    {"**.media.cid", "The video blob's CID; `video` keeps its playlist and thumbnail URLs"},
    {"**.presentation", "A hint to draw a video as a gif; `video` keeps its alt text and URLs"},
    {"feed[].post.embed.media.$type",
     "The kind of media beside a quote; whichever of `images`, `link` or `video` is set says it"},
    {"**.record.embeds[].$type",
     "The kind of a quoted post's attachment; whichever of the quote's `images`, `link` or `video` is set says it"},
    {"**.record.embeds[].media.$type",
     "The kind of media beside a quoted post's own quote; its `images`, `link` or `video` says it"},
    {"**.embed.record.creator.displayName",
     "The display name of a quoted feed's, list's or starter pack's creator; `creator` keeps the handle"},
    {"**.embed.record.joinedAllTimeCount", "How many joined through a quoted starter pack"},
    {"**.embed.record.joinedWeekCount",
     "How many joined through a quoted starter pack this week"},
    {"**.embed.record.record.createdAt", "When a quoted starter pack was made"},
    {"**.embed.record.record.list",
     "The list behind a quoted starter pack; the quote's uri is what the app opens"},

    # What the app shows about an account beside its name: its avatar. A
    # profile read gives its URL, in the structured content and the text, as
    # it gives the banner's; beside a post, a name or a list it is a picture,
    # which no text says.
    {"**.author.avatar", "The author's avatar picture; get_profile reads its URL"},
    {"**.creator.avatar", "The creator's avatar picture; get_profile reads its URL"},
    {"feed[].reason.by.avatar", "The reposter's avatar picture; get_profile reads its URL"},
    {"items[].subject.avatar", "A list member's avatar picture; get_profile reads its URL"},
    {"trends[].actors[].avatar", "An avatar picture; get_profile reads its URL"},
    {"pinnedPost.cid", "The pinned post's CID; get_posts with `pinned_post` reads it"},
    {"**.associated",
     "What an account has made, whether it runs a labeler, who may message it and who may subscribe to its posts: a profile reads these (`lists`, `feeds`, `starter_packs`, `labeler`, `messages_from`, `subscriptions_from`), and get_profile reads them for an account met elsewhere. Who may add it to a group chat (`chat.allowGroupInvites`) is not read: at_mcp has no direct messages (#92). A third-party messaging button is not read"},
    {"**.verification",
     "Whether the app shows an account as verified: a profile (`verification`, with who verified it) and a post's or quote's author (`author_verification`) read it, and get_profile reads it for an account met elsewhere"},
    {"**.status.*",
     "An account's status, the app's Live badge: a profile (`status`) and a post's or quote's author (`author_status`) read its kind, whether it is on, when it ends, where it links, its AT URI and its own labels (the app hides the badge when moderation filters them), and get_profile reads it for an account met elsewhere. Its record, CID and the link card's description and picture are not what the badge shows"},
    {"**.author.createdAt", "When the author's account was made; get_profile reads it"},
    {"**.creator.createdAt", "When the creator's account was made; get_profile reads it"},
    {"**.creator.description", "The creator's profile description; get_profile reads it"},

    # The accounts posting about a trend.
    {"trends[].actors[].createdAt", "When the account was made; get_profile reads it"},
    {"trends[].actors[].pronouns", "The account's pronouns; get_profile reads them"},
    {"trends[].actors[].labels",
     "Labels on an account posting about a trend; get_profile reads them"},

    # Lists and starter packs.
    {"**.creator.labels",
     "Labels on the account that made a list or starter pack; get_profile reads them"},
    {"**.subject.createdAt", "When a list member's account was made; get_profile reads it"},
    {"**.subject.indexedAt", "When the AppView indexed the account; not what the app shows"},
    {"list.indexedAt", "When the AppView indexed the list; not what the app shows"},
    {"lists[].indexedAt", "When the AppView indexed the list; not what the app shows"},
    {"starterPack.indexedAt",
     "When the AppView indexed the starter pack; `created_at` is when it was made"},
    {"starterPacks[].indexedAt",
     "When the AppView indexed the starter pack; `created_at` is when it was made"},
    {"*.list",
     "A starter pack's list beyond its uri and size, which `list` and `item_count` keep: its name is the pack's, and get_list reads the rest"},
    {"*.listItemsSample",
     "A sample of a starter pack's accounts beyond who they are, which `members_sample` keeps; get_list reads every account with its list item"},
    {"*.feeds[]",
     "A feed a starter pack recommends beyond its uri, name and maker, which `feeds` keeps; get_feed reads its posts"},
    {"*.record.feeds",
     "The feeds as the starter pack's record names them; `feeds` reads the hydrated view, and the record only where a view has none"},
    {"*.record.list",
     "The list's uri as the starter pack's record names it; `list` reads the view's, and the record's only where a view has none"},
    {"*.record.$type", "The starter pack record's type; the read already says it is one"},
    {"*.record.updatedAt", "When the starter pack was last edited; the app does not show it"},
    {"*.record.descriptionFacets",
     "Where a starter pack description's links and mentions point; `description` keeps the text"},

    # Left out on purpose.
    {"indexedAt",
     "When the AppView indexed the account; nothing a reader acts on, and not what the app shows"},
    {"**.actor.indexedAt", "When the AppView indexed the account; not what the app shows"},
    {"**.creator.indexedAt", "When the AppView indexed the account; not what the app shows"},
    {"**.post.indexedAt",
     "When the AppView indexed the post; `created_at`, when the author wrote it, is what the app shows"},
    {"**.record.indexedAt",
     "When the AppView indexed the quoted post; the app shows when it was written"},
    {"**.post.bookmarkCount",
     "Not decided: a count of private saves, added to the lexicon after #71 chose the four public counts"},
    {"**.labels[].cts", "When the label was signed; its value and who applied it are kept"},
    {"**.labels[].cid",
     "Which record version the label applies to; its value and source are kept"},
    {"**.labels[].ver", "The label format's version"},
    {"**.aspectRatio", "Layout only: the shape to draw an image or video at"},
    {"**.post.record.$type", "The post record's type; the read already says it is a post"},
    {"**.facets[].$type", "The facet's type tag; each feature's own kind is read"},
    {"**.post.record.embed",
     "The embed as the author wrote it; the AppView's hydrated view under `post.embed` is read instead"},
    {"**.value.embed",
     "A quoted post's embed as written: its hydrated view under `embeds` is read instead, except `value.embed.record.uri`, which is read as `nested_uri`"},
    {"**.embeds[].record",
     "A quote inside a quoted post stays a `nested_uri` rather than expanding (docs/DESIGN.md)"},
    {"**.record.reply.parent.cid",
     "Half of the reply's strong reference; `reply_to` keeps the parent's uri, and `reply` builds its own references"},
    {"**.record.reply.root",
     "The thread root's reference; `get_thread_chain` reads the conversation to its root"},
    {"**.value.reply",
     "Whether a quoted post is itself a reply; the app does not show it on a quote"},
    {"**.record.cid",
     "The quoted record's CID; `get_posts` with its uri returns it for `like` and `repost`"},
    {"**.record.likeCount", "The quoted post's count; `get_posts` with its uri reads it"},
    {"**.record.repostCount", "The quoted post's count; `get_posts` with its uri reads it"},
    {"**.record.replyCount", "The quoted post's count; `get_posts` with its uri reads it"},
    {"**.record.quoteCount", "The quoted post's count; `get_posts` with its uri reads it"},
    {"**.embed.record.opThreadPostIndex", "The quoted post's place in its author's self-thread"},
    {"**.embed.record.opThreadPostCount", "The quoted post's place in its author's self-thread"},
    {"uri", "The post `get_likes` was asked about, which the caller passed"},
    {"likes[].createdAt",
     "When each like was made; the app's list of likers shows the accounts, not the times"},
    {"likes[].indexedAt", "When the AppView indexed each like"}
  ]

  @doc "Every entry: a field pattern and why it is left out."
  def entries, do: @entries

  @compiled Enum.map(@entries, fn {pattern, _reason} ->
              body =
                pattern
                |> Regex.escape()
                |> String.replace("\\*\\*\\.", "(?:.*\\.)?")
                |> String.replace("\\*", "[^.]+")

              {pattern, "^" <> body <> "(?:$|[.\\[])"}
            end)

  @doc """
  Every entry pattern that covers a field path, outermost first: the entry
  naming the largest subtree that holds the field comes first.
  """
  def entries_for(path) do
    @compiled
    |> Enum.flat_map(fn {pattern, regex} ->
      case Regex.run(Regex.compile!(regex), path) do
        [match] -> [{pattern, String.length(match)}]
        nil -> []
      end
    end)
    |> Enum.sort_by(&elem(&1, 1))
  end

  @doc """
  The entry pattern that covers a field path, or nil. Where entries nest, the
  outer one decides: a nested quote's author is left out because the nested
  quote is, not for the reasons an author's fields are. A test refuses two
  entries that cover the same field at the same depth.
  """
  def entry(path) do
    case entries_for(path) do
      [{pattern, _depth} | _] -> pattern
      [] -> nil
    end
  end

  @doc "Whether an entry covers a field path."
  def listed?(path), do: not is_nil(entry(path))
end
