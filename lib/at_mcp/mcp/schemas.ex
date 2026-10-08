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

  defmacro profile_view, do: Macro.escape(object(profile_view_schema()["properties"]))

  defmacro post_page, do: Macro.escape(page(post_view_schema()))

  defmacro profile_page, do: Macro.escape(page(profile_view_schema()))

  defmacro notification_page, do: Macro.escape(notification_page_schema())

  defmacro relationship_page, do: Macro.escape(relationship_page_schema())

  defmacro unread_count, do: Macro.escape(unread_count_schema())

  defmacro thread, do: Macro.escape(thread_schema())

  defmacro thread_chain, do: Macro.escape(thread_chain_schema())

  defmacro write_result, do: Macro.escape(write_result_schema())

  defmacro record_result, do: Macro.escape(record_result_schema())

  defmacro action_result, do: Macro.escape(action_result_schema())

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
    }
  }

  # The record shapes come from `AtMcp.Summary`, which is also what the backend
  # reads them with, so a declaration cannot describe a field the tools do not
  # return.
  defp post_view_schema, do: record(:post)

  defp profile_view_schema, do: record(:profile)

  defp notification_page_schema, do: page(record(:notification))

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
      "warning" => nullable_string()
    })
  end

  # A created like, repost, follow or block record.
  defp record_result_schema do
    object(%{
      "uri" => nullable_string("AT URI of the created record; pass this to the inverse tool"),
      "cid" => nullable_string(),
      "subject_uri" => nullable_string("AT URI this record refers to"),
      "subject_cid" => nullable_string(),
      "actor" => nullable_string("Handle or DID this record refers to"),
      "action" => nullable_string()
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
      "seen_at" => nullable_string("ISO8601 timestamp")
    })
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
