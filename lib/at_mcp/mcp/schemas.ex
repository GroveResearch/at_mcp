defmodule AtMcp.MCP.Schemas do
  @moduledoc """
  Declared output schemas for the MCP tool surface.

  Each tool declares one of these through `output_schema/1`; AtMcp advertises
  and validates the returned structured content without changing its outcome.
  Record shapes come
  from `AtMcp.Summary`, which the backend also reads responses with, so those
  cannot drift apart. Page, thread and result shapes are structural and are
  built here.

  These are macros because `output_schema/1` takes a compile-time literal:
  each one expands to its map where the tool is declared.

  Three rules keep validation total rather than a source of new failures:

  - Every property that a summarizer can omit or leave empty accepts `null`.
    Backends legitimately return posts without text and pages without cursors.
  - Every schema also accepts the failure fields (`code`, `outcome`) that
    the tool handler attaches to error results, and allows properties beyond
    those declared. A summarizer that grows a field must not begin failing
    validation before its schema is updated.
  - A shape promises a field only where AtMcp itself guarantees it. Pages always
    carry `count` and `items`, and the two shapes AtMcp builds without a backend
    always carry their own fields; those are required through an `anyOf` whose
    other branch is the error result, so a failure still validates. Record and
    action summaries come from a pluggable `AtMcp.Effects.Backend`, so their
    fields stay documented rather than promised.
  """

  @doc """
  The `reasons` parameter of `get_notifications`: the lexicon's reasons, so an
  unknown one is refused as an invalid argument before anything is sent.
  """
  defmacro notification_reasons do
    Macro.escape(
      description:
        "Only notifications for these reasons. The service filters after it pages, so a page can be short or empty while more remain: follow the cursor until there is none. Omit for all",
      schema: %{
        type: "array",
        items: %{type: "string", enum: AtMcp.Notifications.reasons()}
      }
    )
  end

  @doc """
  The `limit` parameter of a paged read, stated from the limits the account
  enforces (`AtMcp.Effects.page_limits/0`). `noun` names what is counted.
  """
  defmacro page_limit(noun) do
    %{min: min, max: max, default: default} = AtMcp.Effects.page_limits()

    Macro.escape(
      description: "Max #{noun} (#{min}-#{max})",
      default: default,
      schema: %{type: "integer", minimum: min, maximum: max}
    )
  end

  @doc """
  The `limit` parameter of a read whose method takes fewer than AtMcp's page
  limit: the unspecced suggestion and trend methods
  (`AtMcp.Effects.short_page_max/0`).
  """
  defmacro short_page_limit(noun) do
    %{min: min, default: default} = AtMcp.Effects.page_limits()
    max = AtMcp.Effects.short_page_max()

    Macro.escape(
      description: "Max #{noun} (#{min}-#{max})",
      default: min(default, max),
      schema: %{type: "integer", minimum: min, maximum: max}
    )
  end

  @doc """
  The `context` parameter of `get_suggested_follows`: the places in the app
  that suggest accounts, from `AtMcp.Effects.suggestion_contexts/0`.
  """
  defmacro suggestion_context do
    Macro.escape(
      description:
        "Without actor, where the app shows the suggestions: explore (the Explore page, the default), discover, see_more, onboarding (for a new account), general, or browse (a longer list read in pages with cursor).",
      schema: %{type: "string", enum: AtMcp.Effects.suggestion_contexts()}
    )
  end

  @doc "The `pronouns` parameter of `update_profile`, from `AtMcp.Effects.profile_limits/0`."
  defmacro pronouns do
    %{graphemes: graphemes} = AtMcp.Effects.profile_limits().pronouns

    Macro.escape(
      description:
        "Free-form pronouns the profile shows, at most #{graphemes} characters. Empty removes them."
    )
  end

  @doc "The `links` parameter of `update_profile`, from `AtMcp.Effects.profile_limits/0`."
  defmacro profile_links do
    %{links: max, link_title: %{graphemes: title}} = AtMcp.Effects.profile_limits()

    Macro.escape(
      description:
        "The links the profile shows, in order, replacing the ones it has: each an https url and an optional title (at most #{title} characters). At most #{max}; [] removes them all. A link given as the profile already shows it keeps its record. A URL shortener is refused: the app does not show one.",
      schema: %{
        type: "array",
        maxItems: max,
        items: %{
          type: "object",
          required: ["url"],
          properties: %{
            url: %{type: "string", description: "An https URL"},
            title: %{type: "string", description: "The link's label"}
          }
        }
      }
    )
  end

  @doc "The `duration_minutes` parameter of `set_status`, from `AtMcp.Effects.status_minutes/0`."
  defmacro status_minutes do
    first..last//_ = AtMcp.Effects.status_minutes()

    Macro.escape(
      description:
        "With live: how long it lasts, #{first} to #{last} minutes, the span the service shows a status for",
      schema: %{type: "integer", minimum: first, maximum: last}
    )
  end

  @doc """
  The `text` parameter of `save_draft`, stated from the limits the account
  enforces (`AtMcp.Effects.draft_text_limits/0`).
  """
  defmacro draft_text do
    %{graphemes: graphemes, bytes: bytes} = AtMcp.Effects.draft_text_limits()

    Macro.escape(
      required: true,
      description:
        "The draft's text: at most #{graphemes} graphemes and #{bytes} UTF-8 bytes, more than a post holds, so it can be split into posts later. Longer is refused before anything is sent."
    )
  end

  @doc """
  The `reply_rule` parameter: who may reply. Its limit comes from
  `AtMcp.Interactions`, which reads it, as do the words it lists
  (`AtMcp.Interactions.reply_rule_words/0`). `default` says what omitting it
  means.
  """
  defmacro reply_rule(default) do
    %{rules: max} = AtMcp.Interactions.limits()

    Macro.escape(
      description:
        "Who may reply. #{default} [\"everyone\"] for everyone, [] for nobody. Otherwise up to #{max} of: " <>
          ~s["mentioned" (accounts the post mentions), "following" (accounts this account follows), "followers" (accounts that follow this account), and the AT URI of a list (its members; a handle in it is resolved to the DID form the app matches).],
      schema: %{type: "array", maxItems: max, items: %{type: "string"}}
    )
  end

  @doc "The `quotes` parameter: whether others may quote the post."
  defmacro quotes(default) do
    Macro.escape(
      description: ~s("disabled": nobody may quote it. "allowed": anyone may. #{default}),
      schema: %{type: "string", enum: ["allowed", "disabled"]}
    )
  end

  @doc "`get_notifications`' `feed`: the tabs of the app's Notifications screen."
  defmacro notification_feed do
    Macro.escape(
      description:
        "With grouped: which tab of the app's Notifications screen: all (the default), people-i-follow, followers, conversations (replies) or activity",
      schema: %{type: "string", enum: AtMcp.Effects.notification_feeds()}
    )
  end

  @doc "`set_preference`'s `kind`, from `AtMcp.Preferences.kinds/0`."
  defmacro preference_kind do
    Macro.escape(
      required: true,
      description: "Which setting: " <> Enum.join(AtMcp.Preferences.kinds(), ", "),
      schema: %{type: "string", enum: AtMcp.Preferences.kinds()}
    )
  end

  @doc "`set_preference`'s `sort`: the thread sorts the app offers."
  defmacro thread_sort do
    Macro.escape(
      description:
        "threads: how replies are sorted: #{Enum.join(AtMcp.Preferences.thread_sorts(), ", ")}",
      schema: %{type: "string", enum: AtMcp.Preferences.thread_sorts()}
    )
  end

  @doc "`set_preference`'s `tags`: the interests the app offers."
  defmacro interests do
    Macro.escape(
      description:
        "interests: the account's interests, replacing those it has: the ones the app offers (" <>
          Enum.join(AtMcp.Preferences.interests(), ", ") <> "), or ones the account already has",
      schema: %{type: "array", items: %{type: "string"}}
    )
  end

  @doc "`set_preference`'s `allow`: who may subscribe to this account's posts."
  defmacro subscription_allow do
    Macro.escape(
      description:
        "activity_subscriptions: who may subscribe to this account's posts: followers (accounts that follow it), mutuals (accounts it follows that follow it) or none",
      schema: %{type: "string", enum: AtMcp.Preferences.allow_values()}
    )
  end

  @doc "`report`'s `reason`, from `AtMcp.Moderation.reasons/0`."
  defmacro report_reason do
    Macro.escape(
      required: true,
      description:
        "Why: one of the reasons the app's report dialog offers (" <>
          Enum.join(
            Enum.reject(
              AtMcp.Moderation.reasons(),
              &(&1 in ~w(spam violation misleading sexual rude))
            ),
            ", "
          ) <>
          "), or one of the lexicon's first reasons, spam, violation, misleading, sexual or rude, each sent as the app sends it (misleading_spam, rule_other, misleading_other, sexual_unlabeled, harassment_other)",
      schema: %{type: "string", enum: AtMcp.Moderation.reasons()}
    )
  end

  @doc "`mute_word`'s `duration`."
  defmacro mute_duration do
    Macro.escape(
      description: "How long: 24h, 7d, 30d or forever (the default)",
      schema: %{type: "string", enum: AtMcp.Moderation.durations()}
    )
  end

  @doc "`set_label_visibility`'s `visibility`."
  defmacro label_visibility do
    Macro.escape(
      required: true,
      description:
        "show (the app shows it as it is), warn (the app covers it with a warning to click through) or hide (the app hides it)",
      schema: %{type: "string", enum: AtMcp.Moderation.visibilities()}
    )
  end

  @doc "`set_notification_setting`'s `reason`, from `AtMcp.Preferences.notification_reasons/0`."
  defmacro notification_setting_reason do
    Macro.escape(
      required: true,
      description:
        "What the notifications are for: " <>
          Enum.join(AtMcp.Preferences.notification_reasons(), ", "),
      schema: %{type: "string", enum: AtMcp.Preferences.notification_reasons()}
    )
  end

  @doc "`set_notification_setting`'s `include`."
  defmacro notification_include do
    Macro.escape(
      description:
        "From whom: all, or follows (only accounts this account follows). Only " <>
          Enum.join(AtMcp.Preferences.filterable_reasons(), ", ") <> " take it",
      schema: %{type: "string", enum: AtMcp.Preferences.includes()}
    )
  end

  @doc "The `labels` parameter: a post's self-labels, from `AtMcp.Interactions.self_labels/0`."
  defmacro self_labels do
    labels = AtMcp.Interactions.self_labels()

    Macro.escape(
      description:
        "Content warnings the post gives itself, any of #{Enum.join(labels, ", ")}. Readers' apps hide or blur it to match.",
      schema: %{type: "array", items: %{type: "string", enum: labels}}
    )
  end

  @doc "The `link` parameter: a link card the caller describes."
  defmacro link do
    thumb = image_upload_schema([])

    Macro.escape(
      description:
        "A link card: url (http or https), and the title and description the card shows. at_mcp does not fetch the page, so they are yours to give. thumb is an optional image for the card, base64 data or a file path with its MIME type. A post carries a link card or images, not both.",
      schema: %{
        type: "object",
        required: ["url"],
        properties: %{
          url: %{type: "string", description: "The page the card links to"},
          title: %{type: "string", description: "The card's title"},
          description: %{type: "string", description: "The card's description"},
          thumb: Map.put(thumb, :description, "The card's image")
        }
      }
    )
  end

  @doc """
  The required list parameter of a batch read, stated from the batch limit
  the account enforces (`AtMcp.Effects.max_batch/0`).
  """
  defmacro batch(description) do
    max = AtMcp.Effects.max_batch()

    Macro.escape(
      required: true,
      description: "#{description}; at most #{max}",
      schema: %{type: "array", minItems: 1, maxItems: max, items: %{type: "string"}}
    )
  end

  @doc "`get_labelers`' `actors`: optional, at most a batch."
  defmacro labeler_actors do
    max = AtMcp.Effects.max_batch()

    Macro.escape(
      description:
        "Handles or DIDs of labelers, at most #{max}; omit for the labelers the app takes labels from for this account",
      schema: %{type: "array", maxItems: max, items: %{type: "string"}}
    )
  end

  @doc """
  The `actors` parameter of `create_starter_pack`, stating how many accounts
  one commit makes a pack with (`AtMcp.Effects.max_pack_actors/0`).
  """
  defmacro pack_actors(description) do
    max = AtMcp.Effects.max_pack_actors()

    Macro.escape(
      description: "#{description}; at most #{max}",
      schema: %{type: "array", maxItems: max, items: %{type: "string"}}
    )
  end

  @doc """
  A tool description with the limits it names filled in from their
  declarations: `{batch}` is the batch range, `{thread}` the shape
  `get_thread` reads.
  """
  defmacro describe(text) do
    %{parent_height: parents, depth: depth, replies: replies} =
      AtMcp.Effects.ProtoRune.thread_shape()

    text
    |> String.replace("{batch}", "1-#{AtMcp.Effects.max_batch()}")
    |> String.replace(
      "{thread}",
      "up to #{parents} parent levels and #{depth} reply levels, nested (#{replies} replies per node)"
    )
  end

  # A tool returning one post or profile can also return a failure code, so the
  # top-level shapes carry the error fields that page *items* never need.
  defmacro post_view, do: Macro.escape(object(post_view_schema()["properties"]))

  defmacro membership, do: Macro.escape(object(AtMcp.Summary.properties(:membership)))

  defmacro profile_view, do: Macro.escape(unread(object(profile_view_schema()["properties"])))

  defmacro post_page, do: Macro.escape(unread(page(post_view_schema())))

  defmacro profile_page, do: Macro.escape(unread(page(profile_view_schema())))

  defmacro bookmark_page, do: Macro.escape(unread(page(bookmark_schema())))

  defmacro draft_page, do: Macro.escape(page(record(:draft)))

  defmacro draft_result, do: Macro.escape(draft_result_schema())

  defmacro generator_page, do: Macro.escape(page(record(:generator)))

  defmacro feed_info_page, do: Macro.escape(feed_info_page_schema())

  defmacro trend_page, do: Macro.escape(trend_page_schema())

  defmacro record_view, do: Macro.escape(record_view_schema())

  defmacro invite_codes, do: Macro.escape(invite_codes_schema())

  defmacro list_page, do: Macro.escape(list_page_schema())

  defmacro lists_page, do: Macro.escape(page(with_member_item(:list)))

  defmacro starter_pack, do: Macro.escape(object(AtMcp.Summary.properties(:starter_pack)))

  defmacro starter_pack_page, do: Macro.escape(page(with_member_item(:starter_pack)))

  defmacro list_result, do: Macro.escape(list_result_schema())

  defmacro notification_page, do: Macro.escape(notification_page_schema())

  defmacro relationship_page, do: Macro.escape(relationship_page_schema())

  defmacro unread_count, do: Macro.escape(unread_count_schema())

  defmacro thread, do: Macro.escape(unread(thread_schema()))

  defmacro thread_chain, do: Macro.escape(unread(thread_chain_schema()))

  defmacro write_result, do: Macro.escape(write_result_schema())

  defmacro record_result, do: Macro.escape(record_result_schema())

  defmacro action_result, do: Macro.escape(action_result_schema())

  defmacro preferences, do: Macro.escape(preferences_schema())

  defmacro notification_settings, do: Macro.escape(notification_settings_schema())

  defmacro moderation_result, do: Macro.escape(moderation_result_schema())

  defmacro labelers, do: Macro.escape(labelers_schema())

  @doc """
  One image a tool uploads: base64 `data` or a file `path`, and its MIME type
  as `mime_type` or as `mimeType`, the AT Protocol blob's own name for it.
  Either spelling is accepted; the tool builds the blob itself.
  `alt: true` requires alt text and takes a list, as a post's images do.
  These are a `param`'s whole options, since the tool DSL reads them literally.
  """
  defmacro image_upload(description, opts \\ []) do
    image = image_upload_schema(opts)
    schema = if opts[:alt], do: %{type: "array", items: image}, else: image
    Macro.escape(description: description, schema: schema)
  end

  defmacro identity_status, do: Macro.escape(identity_status_schema())

  defmacro post_images, do: Macro.escape(post_images_schema())

  @error_properties %{
    "code" => %{
      "type" => "string",
      "description" => "Stable failure code; present only on an error result."
    },
    "outcome" => %{
      "type" => "string",
      "description" => "\"unknown\" when a write may or may not have been applied."
    },
    "ignored" => %{
      "type" => "array",
      "items" => %{"type" => "string"},
      "description" =>
        "Paths of arguments this tool does not take, present only when there were some. Nothing was done with them."
    },
    "resolved" => %{
      "type" => "array",
      "items" => %{
        "type" => "object",
        "properties" => %{
          "argument" => %{"type" => "string"},
          "link" => %{"type" => "string"},
          "value" => %{"type" => "string"}
        }
      },
      "description" =>
        "Each web link given in place of an AT URI, handle or DID, and the AT URI or DID it was read as; present only when there were some."
    },
    "problems" => %{
      "type" => "array",
      "items" => %{
        "type" => "object",
        "properties" => %{"path" => %{"type" => "string"}, "message" => %{"type" => "string"}}
      },
      "description" => "With code invalid_arguments: each argument that failed, and why."
    }
  }

  # The record shapes come from `AtMcp.Summary`, which is also what the backend
  # reads them with, so a declaration cannot describe a field the tools do not
  # return.
  defp post_view_schema, do: moderated(record(:post))

  defp profile_view_schema, do: moderated(record(:profile))

  # What the app would do with a post or an account (`AtMcp.ModerationMarks`),
  # and, on the read, why that could not be marked.
  defp moderated(schema),
    do: put_in(schema, ["properties", "moderation"], AtMcp.ModerationMarks.schema())

  defp unread(schema),
    do: put_in(schema, ["properties", "moderation_unread"], AtMcp.ModerationMarks.unread_schema())

  # Notifications one by one, or with `grouped`, in the groups the app shows.
  defp notification_page_schema do
    %{"anyOf" => [record(:notification), record(:notification_group)]}
    |> page()
    |> put_in(
      ["properties", "seen_at"],
      nullable_string(
        "grouped: when the account last marked its notifications seen, as an ISO 8601 timestamp"
      )
    )
  end

  defp relationship_page_schema, do: page(record(:relationship))

  defp record(shape) do
    %{"type" => "object", "properties" => AtMcp.Summary.properties(shape)}
  end

  # Unread notification count.
  defp unread_count_schema do
    %{"count" => %{"type" => "integer"}} |> object() |> promising(["count"])
  end

  # One post with its retained parents and replies.
  # `parent` and `replies` entries repeat this node's post fields; they are
  # declared as plain objects rather than a recursive reference, so a client
  # reads a nested node's own `uri` without resolving a schema cycle.
  defp thread_schema do
    object(
      Map.merge(post_view_schema()["properties"], %{
        "type" => nullable_string("Thread node $type"),
        "not_found" => %{"type" => ["boolean", "null"]},
        "blocked" => %{"type" => ["boolean", "null"]},
        "parent" => %{
          "type" => ["object", "null"],
          "description" => "The parent post, if retained"
        },
        "parent_omitted" => %{
          "type" => ["boolean", "null"],
          "description" => "True when a parent exists beyond the retained height"
        },
        "replies" => %{"type" => "array", "items" => %{"type" => "object"}},
        "replies_omitted" => %{
          "type" => ["integer", "null"],
          "description" => "Replies present on this node but not returned"
        },
        "context" => %{
          "type" => "object",
          "description" => "The depth, parent height and per-node reply cap applied"
        },
        "hidden_by_threadgate" => %{
          "type" => ["boolean", "null"],
          "description" =>
            "True when the thread's author hid this post; the app leaves it out of the thread. Replies repeat this flag"
        },
        "muted_by_viewer" => %{
          "type" => ["boolean", "null"],
          "description" =>
            "With include_hidden: true when the app leaves this post out because this account muted its author. Replies repeat this flag"
        },
        "left_out" => %{
          "type" => ["boolean", "null"],
          "description" =>
            "With include_hidden: true when the app leaves this post out of the thread; hidden_by_threadgate or muted_by_viewer says why when the service says, and a depth above 1 means it may be left out only because a reply above it is. Replies repeat this flag and depth"
        },
        "hidden_replies_unread" =>
          nullable_string(
            "With include_hidden: why the replies the thread leaves out could not be read. The thread is as read"
          ),
        "hidden_replies" => %{
          "type" => ["array", "null"],
          "description" =>
            "With include_hidden: the replies the app leaves out that this read did not return (those it returned are marked left_out in place). Absent otherwise",
          "items" => %{
            "type" => "object",
            "properties" =>
              Map.merge(post_view_schema()["properties"], %{
                "depth" => %{
                  "type" => ["integer", "null"],
                  "description" => "Levels below the post read: 1 is a direct reply"
                },
                "hidden_by_threadgate" => %{
                  "type" => ["boolean", "null"],
                  "description" => "True when the thread's author hid this reply"
                },
                "muted_by_viewer" => %{
                  "type" => ["boolean", "null"],
                  "description" => "True when this account muted the reply's author"
                }
              })
          }
        }
      })
    )
  end

  # One conversation from its root down to the requested post: a flat list,
  # each element the same shape, plus the replies directly under the requested
  # post. The element fields come from `AtMcp.Summary`; the flags beside them
  # are AtMcp's own reading of the node, so they are declared here.
  defp chain_post_schema do
    %{
      "type" => "object",
      "properties" =>
        Map.merge(AtMcp.Summary.properties(:chain_post), %{
          "moderation" => AtMcp.ModerationMarks.schema(),
          "is_self" => %{
            "type" => ["boolean", "null"],
            "description" => "True when this account wrote the post"
          },
          "not_found" => %{
            "type" => ["boolean", "null"],
            "description" => "True when the service reports the post deleted or missing"
          },
          "blocked" => %{
            "type" => ["boolean", "null"],
            "description" => "True when a block hides the post from this account"
          },
          "unresolved" => %{
            "type" => ["boolean", "null"],
            "description" =>
              "True when this element is only a uri: the read stopped before fetching it"
          }
        })
    }
  end

  defp thread_chain_schema do
    %{
      "root_uri" => nullable_string("AT URI of the thread root"),
      "chain" => %{
        "type" => "array",
        "description" => "The conversation root first; the last element is the requested post",
        "items" => chain_post_schema()
      },
      "chain_omitted" => %{
        "type" => ["integer", "null"],
        "description" =>
          "Ancestors read but not returned: a conversation longer than the chain keeps the elements nearest the requested post and drops this many from the root end"
      },
      "chain_truncated" => %{
        "type" => ["boolean", "null"],
        "description" =>
          "True when the chain is not known to run unbroken from the root: an element could not be read, the read stopped before reaching it, or elements were omitted"
      },
      "chain_before" =>
        nullable_string(
          "The uri to read from next to continue upward: pass it as `before` to get the page of the conversation above this one. Null means there is nowhere to resume from, not that the conversation is complete: read chain_truncated for that"
        ),
      "replies" => %{
        "type" => "array",
        "description" => "Posts replying directly to the requested post",
        "items" => chain_post_schema()
      },
      "replies_omitted" => %{
        "type" => ["integer", "null"],
        "description" => "Direct replies present but not returned"
      }
    }
    |> object()
    |> promising(["chain"])
  end

  # A created post or reply, with any handles that stayed plain text.
  defp write_result_schema do
    object(%{
      "uri" => nullable_string("AT URI of the created record"),
      "cid" => nullable_string("CID of the created record"),
      "text" => nullable_string("The text as published"),
      "reply_to" => nullable_string("Parent AT URI, for a reply"),
      "unresolved_mentions" => %{
        "type" => "array",
        "items" => %{"type" => "string"},
        "description" => "Handles published as plain text, without a mention facet"
      },
      "warning" => nullable_string(),
      "threadgate_uri" =>
        nullable_string("AT URI of the threadgate written with the post: who may reply"),
      "postgate_uri" =>
        nullable_string("AT URI of the postgate written with the post: whether it may be quoted")
    })
  end

  # A created like, repost, follow or block record, or the one already there.
  defp record_result_schema do
    object(%{
      "uri" =>
        nullable_string(
          "AT URI of the created record, or of the one already there; pass this to the inverse tool"
        ),
      "cid" => nullable_string(),
      "subject_uri" => nullable_string("AT URI this record refers to"),
      "subject_cid" => nullable_string(),
      "actor" => nullable_string("Handle or DID this record refers to"),
      "action" => nullable_string(),
      "unchanged" => %{
        "type" => ["boolean", "null"],
        "description" =>
          "True when this account already had this like, repost, follow or block (named by the AppView and found in this account's repository with this subject), so nothing was written; uri is that record"
      }
    })
  end

  # An action with no new record: removals, mutes, profile and seen updates.
  defp action_result_schema do
    object(%{
      "ok" => %{"type" => ["boolean", "null"]},
      "action" => nullable_string(),
      "uri" => nullable_string("The record AT URI this action applied to"),
      "actor" => nullable_string(),
      "display_name" => nullable_string(),
      "description" => nullable_string(),
      "avatar_cid" => nullable_string("CID of the avatar blob this update uploaded"),
      "banner_cid" => nullable_string("CID of the banner blob this update uploaded"),
      "seen_at" => nullable_string("ISO8601 timestamp"),
      "subject_uri" =>
        nullable_string("AT URI of the post this action applied to, e.g. the post pinned"),
      "replaced_uri" =>
        nullable_string(
          "AT URI of the post that was pinned before this action, if any; pin_post takes it to put it back"
        ),
      "threadgate_uri" =>
        nullable_string(
          "AT URI of the post's threadgate after this action; null when the post has none"
        ),
      "postgate_uri" =>
        nullable_string(
          "AT URI of the post's postgate after this action; null when the post has none"
        ),
      "reply_rule" => %{
        "type" => ["array", "null"],
        "items" => %{"type" => "string"},
        "description" =>
          "set_post_interactions: who may reply now, in reply_rule's words: [\"everyone\"], [] for nobody, or the rules. Null for a reply, whose thread's first post sets it"
      },
      "quotes" =>
        nullable_string(
          "set_post_interactions: whether others may quote the post now: allowed or disabled"
        ),
      "unchanged" => %{
        "type" => ["boolean", "null"],
        "description" =>
          "True when nothing would change, so nothing was written: the post already had these settings, the feed was already saved as asked, the setting or subscription was already as asked, there was no status to clear, or the record to undo was not there"
      },
      "deleted" => %{
        "type" => ["array", "null"],
        "items" => %{"type" => "string"},
        "description" =>
          "AT URIs of every record deleted. Unfollow and Unblock inventory all shared and old Town records of the same subject; Unlike and Unrepost also remove the other record named by the AppView."
      },
      "pronouns" => nullable_string("update_profile: the pronouns written; empty when removed"),
      "website" => nullable_string("update_profile: the website written; empty when removed"),
      "labels" => %{
        "type" => ["array", "null"],
        "items" => %{"type" => "string"},
        "description" => "update_profile with labels: the labels the account now gives itself"
      },
      "links" => %{
        "type" => ["array", "null"],
        "description" =>
          "update_profile with links: the links the profile now shows, in order, each with its actor.link record",
        "items" => %{
          "type" => "object",
          "properties" => %{
            "uri" => nullable_string("AT URI of the link record"),
            "url" => nullable_string(),
            "title" => nullable_string()
          }
        }
      },
      "replaced_links" => %{
        "type" => ["array", "null"],
        "description" =>
          "update_profile with links: the links the profile showed before, which links takes to put them back",
        "items" => %{
          "type" => "object",
          "properties" => %{"url" => nullable_string(), "title" => nullable_string()}
        }
      },
      "removed" => %{
        "type" => ["array", "null"],
        "items" => %{"type" => "string"},
        "description" =>
          "update_profile with links: link records deleted because the profile no longer shows them"
      },
      "left_behind" => %{
        "type" => ["array", "null"],
        "items" => %{"type" => "string"},
        "description" =>
          "update_profile with links: link records the profile no longer shows that could not be deleted; nothing shows them"
      },
      "pinned" => %{
        "type" => ["boolean", "null"],
        "description" => "save_feed: whether the feed is now pinned as a home screen tab"
      },
      "note" =>
        nullable_string(
          "save_feed, unsave_feed and set_preference: what the write could not guard against; update_seen: that seen_at is after now, and by how much; an undo of a record that is not there: that nothing was deleted; set_notification_setting and subscribe_to_activity: that the service's answer could not be read"
        ),
      "status" => nullable_string("set_status: live, or clear"),
      "duration_minutes" => %{
        "type" => ["integer", "null"],
        "description" => "set_status: how long the live status lasts"
      },
      "url" => nullable_string("set_status: where to watch"),
      "expires_at" => nullable_string("set_status: when the live status ends, ISO 8601"),
      "replaced" => %{
        "type" => ["object", "null"],
        "description" =>
          "set_status: the status this replaced or cleared, null when there was none: its url, duration_minutes and created_at",
        "properties" => %{
          "url" => nullable_string(),
          "duration_minutes" => %{"type" => ["integer", "null"]},
          "created_at" => nullable_string()
        }
      },
      "kind" =>
        nullable_string(
          "feed_feedback: show_more or show_less; set_preference: the kind of setting it changed"
        ),
      "changed" => %{
        "type" => ["array", "null"],
        "items" => %{"type" => "string"},
        "description" =>
          "set_preference and set_notification_setting: the fields whose value changed; empty when unchanged"
      },
      "previous" => %{
        "type" => ["object", "null"],
        "description" =>
          "set_preference, set_notification_setting and subscribe_to_activity: every field of the setting or subscription before this call, which the same tool takes to put it back"
      },
      "now" => %{
        "type" => ["object", "null"],
        "description" =>
          "set_preference, set_notification_setting and subscribe_to_activity: every field of the setting or subscription after this call; for set_notification_setting and subscribe_to_activity, as the service answered"
      },
      "reason" => nullable_string("set_notification_setting: the reason whose setting changed"),
      "handle" => nullable_string("subscribe_to_activity: the account's handle")
    })
  end

  # The account's settings as the app shows them (`AtMcp.Preferences`).
  defp preferences_schema do
    object(%{
      "home_feed" =>
        settings(
          "The Following feed's settings. The app applies them when it shows the Following feed and lists; get_timeline returns the timeline as the service serves it",
          %{
            "hide_replies" => boolean("Hide replies"),
            "hide_reposts" => boolean("Hide reposts"),
            "hide_quotes" => boolean("Hide quote posts"),
            "saved_feed_samples" =>
              boolean("Show samples of the saved feeds in the Following feed (an experiment)")
          }
        ),
      "threads" =>
        settings("How the app shows a thread", %{
          "sort" => nullable_string("How replies are sorted: top, oldest or newest"),
          "tree_view" => boolean("Show replies as a tree")
        }),
      "interaction_defaults" =>
        settings(
          "Who may reply to and quote a new post: the app's composer starts each new post with these; post does not read them",
          %{
            "reply_rule" => %{
              "type" => ["array", "null"],
              "items" => %{"type" => "string"},
              "description" => "In the words post's reply_rule takes"
            },
            "quotes" => nullable_string("allowed or disabled")
          }
        ),
      "adult_content" =>
        settings("Whether the app shows adult content", %{
          "enabled" => boolean("Adult content is on"),
          "birth_date_set" =>
            boolean("The account has a birth date; the date itself is not read out"),
          "declared_over_18" =>
            boolean(
              "The birth date makes the account 18 or over; the app shows adult content to no other"
            )
        }),
      "interests" =>
        settings("The account's interests", %{
          "tags" => %{"type" => ["array", "null"], "items" => %{"type" => "string"}}
        }),
      "verification" =>
        settings("Verification checks", %{
          "hide_badges" =>
            boolean("The app hides verification checks; reads still carry verification")
        }),
      "discoverable" =>
        settings("The account's content visibility declaration", %{
          "hide_from_recommendations" =>
            boolean("The account asks apps to keep its posts out of algorithmic recommendations")
        }),
      "activity_subscriptions" =>
        settings("The account's notification declaration", %{
          "allow" =>
            nullable_string(
              "Who may subscribe to this account's posts: followers, mutuals or none"
            )
        }),
      "muted_words" => %{
        "type" => ["array", "null"],
        "description" =>
          "The muted words and tags, as the app reads them; mute_word and unmute_word change them",
        "items" => muted_word_schema()
      },
      "labelers" => %{
        "type" => ["array", "null"],
        "items" => %{"type" => "string"},
        "description" =>
          "DIDs of the labelers the app takes labels from: the network's own moderation service, then those the account subscribes to; get_labelers reads them in detail"
      },
      "content_labels" =>
        settings(
          "What the app does with posts and accounts carrying each of the labels of its moderation screen, whichever labeler applied them: show, warn or hide. set_label_visibility changes them",
          %{
            "porn" => nullable_string(),
            "sexual" => nullable_string(),
            "graphic-media" => nullable_string(),
            "nudity" => nullable_string()
          }
        ),
      "saved_feeds" => %{
        "type" => ["array", "null"],
        "description" =>
          "The saved feeds, pinned first, as the app shows them; save_feed and unsave_feed change them",
        "items" => %{
          "type" => "object",
          "properties" => %{
            "type" => nullable_string("feed, list or timeline"),
            "value" =>
              nullable_string("The feed's or list's AT URI, or following for the Following feed"),
            "pinned" => boolean("Pinned as a home screen tab")
          }
        }
      }
    })
  end

  # A muted word as `get_preferences` and the muted word tools report it.
  defp muted_word_schema do
    %{
      "type" => "object",
      "properties" => %{
        "id" => nullable_string("The muted word's id"),
        "value" => nullable_string("The word, tag or phrase"),
        "targets" => %{
          "type" => ["array", "null"],
          "items" => %{"type" => "string"},
          "description" => "Where it is muted, as stored: tag and content"
        },
        "tags_only" => boolean("Muted only as a hashtag, not in post text"),
        "only_non_followed" =>
          boolean("Muted only in posts by accounts this account does not follow"),
        "expires_at" =>
          nullable_string("When the mute ends, as an ISO 8601 timestamp; null for ever"),
        "expired" => boolean("The mute has ended; the app no longer applies it")
      }
    }
  end

  # What a moderation write did: a report, a muted word, a list mute or
  # block, a labeler subscription or a label setting.
  defp moderation_result_schema do
    object(%{
      "ok" => %{"type" => ["boolean", "null"]},
      "action" => nullable_string(),
      "id" => %{
        "type" => ["integer", "null"],
        "description" => "report: the report's id at the moderation service"
      },
      "labeler" =>
        nullable_string(
          "report: DID of the moderation service the report went to; set_label_visibility: the labeler whose label this sets, null for every labeler's"
        ),
      "labeler_handle" => nullable_string("report: handle of that moderation service"),
      "subject" => nullable_string("report: the AT URI or DID reported"),
      "reason" => nullable_string("report: the reason, in report's words"),
      "reason_type" => nullable_string("report: the reason type sent"),
      "created_at" => nullable_string("report: when the service recorded it"),
      "value" => nullable_string("mute_word, unmute_word: the word, as stored"),
      "removed" => %{
        "type" => ["array", "null"],
        "items" => muted_word_schema(),
        "description" => "unmute_word: each muted word removed, as it was"
      },
      "list" => nullable_string("The list, in DID form"),
      "name" => nullable_string("The list's name"),
      "muted" => boolean("mute_list, unmute_list: whether the list is now muted"),
      "uri" =>
        nullable_string(
          "block_list, unblock_list: the list block record written, kept or deleted"
        ),
      "deleted" => %{
        "type" => ["array", "null"],
        "items" => %{"type" => "string"},
        "description" => "unblock_list: AT URIs of the list blocks deleted"
      },
      "actor" => nullable_string("subscribe_labeler, unsubscribe_labeler: the labeler's DID"),
      "handle" => nullable_string("The labeler's handle"),
      "label" => nullable_string("set_label_visibility: the label"),
      "previous" => %{
        "description" =>
          "What it was before: the muted words of this value, whether the list was muted, whether the labeler was subscribed to, or the label's setting"
      },
      "now" => %{"description" => "What it is now, in the same terms as previous"},
      "unchanged" => boolean("Already as asked, so nothing was written or sent"),
      "note" => nullable_string("What else to know about this result")
    })
  end

  # Labelers in detail, with this account's settings for each.
  defp labelers_schema do
    label = %{
      "type" => "object",
      "properties" => %{
        "identifier" => nullable_string("The label's value, as it appears in labels"),
        "name" => nullable_string("Its name, in English where the labeler gives one"),
        "description" => nullable_string("What it means"),
        "severity" => nullable_string("inform, alert or none"),
        "blurs" => nullable_string("content, media or none"),
        "default" => nullable_string("What the app does with it unless set: show, warn or hide"),
        "global" =>
          boolean(
            "One of the app's adult content filters, set for every labeler at once: set_label_visibility without labeler"
          ),
        "adult_only" => boolean("Its setting shows only while adult content is on"),
        "setting" =>
          nullable_string(
            "What the app shows it set to for this account: show, warn or hide; null when the account does not take this labeler's labels"
          )
      }
    }

    item = %{
      "type" => "object",
      "properties" => %{
        "did" => nullable_string("The labeler's DID"),
        "handle" => nullable_string(),
        "display_name" => nullable_string(),
        "web_url" =>
          nullable_string(
            "Web link of its account's profile, where the app shows the labeler; the AT URI stays what tools take"
          ),
        "uri" => nullable_string("AT URI of its labeler record; like takes it"),
        "cid" => nullable_string(),
        "like_count" => %{"type" => ["integer", "null"]},
        "like" => nullable_string("This account's like of it, if any"),
        "built_in" => boolean("The network's own moderation service, which every account has"),
        "subscribed" => boolean("This account subscribes to it"),
        "label_values" => %{
          "type" => ["array", "null"],
          "items" => %{"type" => "string"},
          "description" => "Every label it applies, its own and global ones"
        },
        "labels" => %{
          "type" => ["array", "null"],
          "items" => label,
          "description" =>
            "The labels its page in the app lists: its own, which set_label_visibility sets with labeler, and the adult content filters it applies (global)"
        },
        "reason_types" => %{
          "type" => ["array", "null"],
          "items" => %{"type" => "string"},
          "description" => "The report reasons it takes; null for any"
        },
        "subject_types" => %{
          "type" => ["array", "null"],
          "items" => %{"type" => "string"},
          "description" => "What it takes reports on (account, record); null for any"
        },
        "subject_collections" => %{
          "type" => ["array", "null"],
          "items" => %{"type" => "string"},
          "description" => "The record types it takes reports on; null for any"
        }
      }
    }

    page(item)
    |> put_in(["properties", "missing"], %{
      "type" => ["array", "null"],
      "items" => %{"type" => "string"},
      "description" => "DIDs asked for that run no labeler the AppView knows of"
    })
  end

  # Each reason's notification setting.
  defp notification_settings_schema do
    object(%{
      "settings" => %{
        "type" => ["array", "null"],
        "description" => "One setting per reason, in the app's order",
        "items" => %{
          "type" => "object",
          "properties" => %{
            "reason" => nullable_string("What the notification is for"),
            "include" =>
              nullable_string(
                "From whom: all, or follows (accounts this account follows); null for a reason without it"
              ),
            "list" => boolean("The app lists them in the account's notifications"),
            "push" => boolean("They are pushed to phones signed in to the account")
          }
        }
      }
    })
  end

  defp settings(description, properties),
    do: %{"type" => ["object", "null"], "description" => description, "properties" => properties}

  defp boolean(description), do: %{"type" => ["boolean", "null"], "description" => description}

  # A saved or deleted draft: its id, and the draft as it was saved or as it
  # was before it was deleted, so a deletion can be undone by saving it again.
  defp draft_result_schema do
    object(%{
      "ok" => %{"type" => ["boolean", "null"]},
      "action" => nullable_string(),
      "id" => nullable_string("The draft's id"),
      "draft" =>
        record(:draft)
        |> Map.put("type", ["object", "null"])
        |> Map.put(
          "description",
          "The draft as saved; for delete_draft, as it was before it was deleted"
        )
    })
  end

  # A page of a list's members, with the list itself beside them.
  defp list_page_schema do
    schema = page(record(:list_member))

    put_in(schema, ["properties", "list"], %{
      "type" => ["object", "null"],
      "description" => "The list these accounts are on",
      "properties" => AtMcp.Summary.properties(:list)
    })
  end

  # A list or starter pack, and, when it was read with `contains`, the list
  # item that puts that account in it.
  defp with_member_item(shape) do
    %{
      "type" => "object",
      "properties" =>
        Map.put(
          AtMcp.Summary.properties(shape),
          "member_item",
          nullable_string(
            "With contains: AT URI of the list item that puts that account in this; null when it is not. Absent without contains"
          )
        )
    }
  end

  # What a list or starter pack write did: the record it wrote or deleted, and
  # the list it applies to.
  defp list_result_schema do
    object(%{
      "ok" => %{"type" => ["boolean", "null"]},
      "action" => nullable_string(),
      "uri" =>
        nullable_string(
          "AT URI of the record this wrote, or of the one it deleted: the list, list item, starter pack or opt-out"
        ),
      "cid" => nullable_string("CID of the record this wrote"),
      "list" => nullable_string("AT URI of the list this applies to"),
      "actor" => nullable_string("DID of the account added to or removed from the list"),
      "name" => nullable_string("The name written, when this set one"),
      "purpose" => nullable_string("curate or moderation, for a list this made"),
      "opted_out" => %{
        "type" => ["boolean", "null"],
        "description" => "Whether this account is now opted out of the list"
      },
      "deleted" => %{
        "type" => ["array", "null"],
        "items" => %{"type" => "string"},
        "description" => "AT URIs of every record this deleted"
      },
      "unchanged" => %{
        "type" => ["boolean", "null"],
        "description" => "True when the account already stood as asked, so nothing was written"
      }
    })
  end

  # Feeds read by AT URI: each as a page of feeds shows it, with whether its
  # service is online, and the uris the service did not know.
  defp feed_info_page_schema do
    item = record(:generator)

    item =
      Map.update!(item, "properties", fn props ->
        Map.merge(props, %{
          "is_online" => %{
            "type" => ["boolean", "null"],
            "description" =>
              "Whether the feed's service has been online recently. Read only when one feed is asked for; null otherwise"
          },
          "is_valid" => %{
            "type" => ["boolean", "null"],
            "description" =>
              "Whether the feed's service matches what its record declares. Read only when one feed is asked for; null otherwise"
          }
        })
      end)

    put_in(page(item), ["properties", "not_found"], %{
      "type" => ["array", "null"],
      "items" => %{"type" => "string"},
      "description" => "AT URIs asked for that the service does not know"
    })
  end

  # Trends, or trending topics with the topics suggested beside them.
  defp trend_page_schema do
    put_in(page(record(:trend)), ["properties", "suggested"], %{
      "type" => ["array", "null"],
      "items" => record(:trend),
      "description" => "With kind topics: topics the service suggests beside the trending ones"
    })
  end

  # One record as its repository holds it.
  defp record_view_schema do
    %{
      "uri" => nullable_string("AT URI of the record, in DID form"),
      "cid" => nullable_string("CID of the record"),
      "value" => %{
        "type" => ["object", "null"],
        "description" => "The record exactly as its repository holds it, keys as written"
      }
    }
    |> object()
    |> promising(["uri", "value"])
  end

  # This account's town invitation codes.
  defp invite_codes_schema do
    %{
      "count" => %{"type" => "integer", "description" => "Codes listed"},
      "items" => %{"type" => "array", "items" => record(:invite_code)},
      "collection" =>
        nullable_string(
          "Whether the town issues this account earned codes: enabled, disabled, unconfigured, or external (an account hosted elsewhere gets only codes assigned to it)"
        )
    }
    |> object()
    |> promising(["count", "items"])
  end

  # A bookmarked post, or the placeholder the service sends for one that is
  # deleted or hidden by a block, with when it was bookmarked.
  defp bookmark_schema do
    %{
      "type" => "object",
      "properties" =>
        Map.merge(AtMcp.Summary.properties(:post), %{
          "moderation" => AtMcp.ModerationMarks.schema(),
          "not_found" => %{
            "type" => ["boolean", "null"],
            "description" =>
              "True when the service reports the bookmarked post deleted or missing"
          },
          "blocked" => %{
            "type" => ["boolean", "null"],
            "description" => "True when a block hides the bookmarked post from this account"
          },
          "bookmarked_at" =>
            nullable_string("When this account bookmarked it, as an ISO 8601 timestamp")
        })
    }
  end

  # Atom keys, like the schemas written inline in `AtMcp.MCP.Server`.
  defp image_upload_schema(opts) do
    alt = %{type: "string", description: "Alt text describing the image"}

    properties = %{
      data: %{type: "string", description: "The image bytes, base64-encoded"},
      path: %{
        type: "string",
        description:
          "Instead of data: an image file the server reads, inside its media directory (AT_MCP_MEDIA_DIR). Off unless that is set."
      },
      mime_type: %{
        type: "string",
        description: "MIME type, e.g. image/png or image/jpeg. Needed, here or as mimeType."
      },
      mimeType: %{
        type: "string",
        description: "Instead of mime_type, under the AT Protocol blob's name. Give one."
      }
    }

    # Neither is required here: the tool refuses an image with neither as
    # invalid_image. An `anyOf` requiring one of them was tried, and some
    # models then left the MIME type out of every call.
    schema = %{type: "object", properties: properties}

    if opts[:alt],
      do: schema |> put_in([:properties, :alt], alt) |> Map.put(:required, ["alt"]),
      else: schema
  end

  # The account's login state and its write quota.
  defp identity_status_schema do
    object(%{
      "logged_in" => %{"type" => "boolean"},
      "did" => nullable_string("Account DID"),
      "handle" => nullable_string("Account handle"),
      "login_count" => %{"type" => "integer"},
      "write_quota" => %{
        "type" => "object",
        "description" =>
          "The account's write quota: how many attempted writes the account may make per window, shared by every client, when one is in force.",
        "properties" => %{
          "limit" => %{"type" => "integer"},
          "window_seconds" => %{"type" => "integer"},
          "used" => %{"type" => "integer"},
          "resets_at" =>
            nullable_string("ISO8601 time the window ends; null before the first write")
        }
      },
      "network" => %{
        "type" => "object",
        "description" =>
          "The AT Protocol network this account acts on, and the limits its record lexicons declare.",
        "properties" => %{
          "name" => %{"type" => "string"},
          "label" => %{
            "type" => "string",
            "description" => "What a reader calls this network, e.g. \"delve.town\""
          },
          "namespace" => %{
            "type" => "string",
            "description" => "Application NSID prefix, e.g. \"app.bsky\""
          },
          "post_limits" => %{
            "type" => "object",
            "description" => "What a post record's text may be, on this network",
            "properties" => %{
              "graphemes" => %{"type" => "integer"},
              "bytes" => %{"type" => "integer"}
            }
          }
        }
      }
    })
    |> promising(["logged_in", "login_count"])
  end

  # The text block of `get_post_images`: every image on the post, by index,
  # whether or not its picture follows as image content.
  defp post_images_schema do
    object(%{
      "uri" => nullable_string("AT URI of the post"),
      "count" => %{"type" => "integer", "description" => "Images attached to the post"},
      "images" => %{
        "type" => "array",
        "items" => %{
          "type" => "object",
          "properties" => %{
            "index" => %{"type" => "integer", "description" => "Position in the post, from 1"},
            "alt" => %{
              "type" => "string",
              "description" => "The image's alt text; empty when the author wrote none"
            },
            "status" => %{
              "type" => "string",
              "description" =>
                "attached: its image content follows, in index order; unavailable: see reason"
            },
            "mime_type" => nullable_string("MIME type of the attached image"),
            "bytes" => %{
              "type" => ["integer", "null"],
              "description" => "Size of the attached image"
            },
            "reason" => nullable_string("Why an unavailable image is not attached")
          }
        }
      }
    })
    |> promising(["count", "images"])
  end

  defp page(item_schema) do
    %{
      "count" => %{"type" => "integer", "description" => "Items on this page"},
      "items" => %{"type" => "array", "items" => item_schema},
      "cursor" => nullable_string("Pass to the next call to continue; null or absent at the end")
    }
    |> object()
    |> promising(["count", "items"])
  end

  # A successful result carries these fields; an error result carries its code
  # instead. Declaring both branches keeps the promise enforceable without
  # turning a reported failure into a validation failure.
  defp promising(schema, required) do
    Map.put(schema, "anyOf", [%{"required" => required}, %{"required" => ["code"]}])
  end

  defp object(properties) do
    %{"type" => "object", "properties" => Map.merge(properties, @error_properties)}
  end

  defp nullable_string(description \\ nil) do
    schema = %{"type" => ["string", "null"]}
    if description, do: Map.put(schema, "description", description), else: schema
  end
end
