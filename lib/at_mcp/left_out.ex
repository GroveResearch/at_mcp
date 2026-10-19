defmodule AtMcp.LeftOut do
  @moduledoc """
  What the AppView returns that no summary passes on, and why.

  `AtMcp.Summary` declares what a read keeps. This is the other half: every
  field of a recorded AppView response that reaches no summary is named here,
  with the reason it is left out or the issue that will pass it on.
  `test/at_mcp/field_coverage_test.exs` changes each field of the recorded
  responses in `test/fixtures/appview` one at a time. A field whose change does
  not change the summary has been dropped, and the test fails unless an entry
  here names it. An entry whose fields are all read after all fails too, so the
  list cannot go stale in either direction.

  A pattern is a field path as the lexicon spells it, with `[]` for a list
  element. `*` stands for one segment, and a leading `**.` stands for any
  prefix, including none. A pattern names a subtree: everything under it is
  covered, and anything under it that a summary does read is still read.

  A reason is a sentence, or `{:todo, issue}` for a drop that hides something a
  person sees in the app and is waiting on that GroveResearch/at_mcp issue.
  """

  @profile_todo 79

  @entries [
    # Why a post is in a feed, and who a reply answers.
    {"feed[].reason", {:todo, 76}},
    {"feed[].reply", {:todo, 76}},
    {"feed[].opThreadPostIndex", {:todo, 76}},
    {"feed[].opThreadPostCount", {:todo, 76}},

    # Who may reply.
    {"threadgate", {:todo, 77}},
    {"**.post.threadgate", {:todo, 77}},

    # Embeds other than images and one quoted post.
    {"**.external", {:todo, 78}},
    {"**.embed.alt", {:todo, 78}},
    {"**.embed.cid", {:todo, 78}},
    {"**.embed.playlist", {:todo, 78}},
    {"**.embed.thumbnail", {:todo, 78}},
    {"**.embed.presentation", {:todo, 78}},
    {"**.media.$type", {:todo, 78}},
    {"**.media.alt", {:todo, 78}},
    {"**.media.cid", {:todo, 78}},
    {"**.media.playlist", {:todo, 78}},
    {"**.media.thumbnail", {:todo, 78}},
    {"**.media.presentation", {:todo, 78}},
    {"**.embeds[].$type", {:todo, 78}},
    {"**.embeds[].alt", {:todo, 78}},
    {"**.embeds[].cid", {:todo, 78}},
    {"**.embeds[].playlist", {:todo, 78}},
    {"**.embeds[].thumbnail", {:todo, 78}},
    {"**.embeds[].presentation", {:todo, 78}},
    {"**.embed.record.creator", {:todo, 78}},
    {"**.embed.record.joinedWeekCount", {:todo, 78}},
    {"**.embed.record.joinedAllTimeCount", {:todo, 78}},
    {"**.embed.record.record.name", {:todo, 78}},
    {"**.embed.record.record.description", {:todo, 78}},
    {"**.embed.record.record.list", {:todo, 78}},
    {"**.embed.record.record.createdAt", {:todo, 78}},
    {"**.record.author.displayName", {:todo, 78}},
    {"**.value.createdAt", {:todo, 78}},

    # A quoted post's labels.
    {"**.record.author.labels", {:todo, 73}},
    {"**.record.labels", {:todo, 73}},

    # What the app shows about an account.
    {"avatar", {:todo, 49}},
    {"banner", {:todo, 49}},
    {"**.avatar", {:todo, 49}},
    {"pinnedPost", {:todo, @profile_todo}},
    {"createdAt", {:todo, @profile_todo}},
    {"**.associated", {:todo, @profile_todo}},
    {"**.verification", {:todo, @profile_todo}},
    {"**.status", {:todo, @profile_todo}},
    {"**.author.createdAt", {:todo, @profile_todo}},
    {"**.actor.createdAt", {:todo, @profile_todo}},
    {"**.creator.createdAt", {:todo, @profile_todo}},
    {"feeds[].creator.displayName", {:todo, @profile_todo}},
    {"feeds[].creator.description", {:todo, @profile_todo}},
    {"feeds[].acceptsInteractions", {:todo, @profile_todo}},

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
    {"**.labels[].uri", "The labelled subject, which is the record it is read on"},
    {"**.labels[].ver", "The label format's version"},
    {"**.aspectRatio", "Layout only: the shape to draw an image or video at"},
    {"**.post.record.$type", "The post record's type; the read already says it is a post"},
    {"**.facets[].$type", "The facet's type tag; each feature's own kind is read"},
    {"**.langs[]",
     "The languages the author tagged; the text itself is read, and the app shows them only to offer translation"},
    {"**.post.record.embed",
     "The embed as the author wrote it; the AppView's hydrated view under `post.embed` is read instead"},
    {"**.value.embed",
     "A quoted post's embed as written; its hydrated view under `embeds` is read instead, and a further quote stays `nested_uri`"},
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

  @doc "The entry whose pattern covers a field path, or nil."
  def entry(path) do
    Enum.find_value(@compiled, fn {pattern, regex} ->
      if Regex.match?(Regex.compile!(regex), path), do: pattern
    end)
  end

  @doc "Whether an entry covers a field path."
  def listed?(path), do: not is_nil(entry(path))
end
