defmodule AtMcp.ModerationMarks do
  @moduledoc """
  Marks what a read returns with what the app would do with it: each post and
  account the read carries gets `moderation`, the causes the app acts on where
  it would show it (`AtMcp.ModerationDecision`), and a reply in a thread says
  where the app's thread puts it. Nothing is removed or reordered.

  The decision needs the account's preferences (its muted words, labelers and
  label settings), read once per call, and, only when the read carries labels
  from the account's labelers, those labelers' definitions, read once in one
  request. A read that cannot get them carries `moderation_unread`, saying
  why, and no marks.
  """

  alias AtMcp.ModerationDecision, as: Decision

  @doc """
  `result` marked. `kind` is what it holds: `:posts` (a page of posts),
  `{:author_feed, actor}` (a profile's posts, `actor` the profile's handle or
  DID), `:thread`, `:chain`, `:profile` or `:profiles` (a page of accounts).
  """
  def mark(backend, session, user_did, {:ok, result}, kind) when is_map(result) do
    case subjects(result, kind) do
      [] ->
        {:ok, result}

      subjects ->
        if reads_settings?(backend),
          do: marked(backend, session, user_did, result, subjects, kind),
          else: {:ok, result}
    end
  end

  def mark(_backend, _session, _user_did, other, _kind), do: other

  # A backend that does not read the account's settings (an embedder's own,
  # a test double) marks nothing.
  defp reads_settings?(backend) do
    Code.ensure_loaded?(backend) and function_exported?(backend, :moderation_preferences, 1) and
      function_exported?(backend, :labeler_definitions, 2)
  end

  defp marked(backend, session, user_did, result, subjects, kind) do
    case options(backend, session, user_did, subjects, kind) do
      {:ok, opts} -> {:ok, apply_marks(result, kind, opts)}
      {:error, :auth_refused, error} -> error
      {:error, why} -> {:ok, put(result, :moderation_unread, why)}
    end
  end

  defp options(backend, session, user_did, subjects, kind) do
    with {:ok, preferences} <-
           read(backend.moderation_preferences(session), "the account's settings") do
      labels = Enum.flat_map(subjects, &labels(&1, kind))

      case Decision.labelers_needed(labels, preferences) do
        [] ->
          {:ok, Decision.options(preferences, user_did)}

        dids ->
          with {:ok, views} <-
                 read(
                   backend.labeler_definitions(session, dids),
                   "the labelers' label definitions"
                 ),
               do: {:ok, Decision.options(preferences, user_did, views)}
      end
    end
  end

  defp labels(subject, kind) when kind in [:profile, :profiles],
    do: Enum.filter(List.wrap(get(subject, :labels)), &is_map/1)

  defp labels(subject, _kind), do: Decision.labels_of(subject)

  # A refused credential is recovered and the read made again, as for any
  # read; anything else leaves the result unmarked, saying why.
  defp read({:ok, value}, _what), do: {:ok, value}

  defp read({:error, reason} = error, what) do
    if AtMcp.Effects.Failure.kind(reason) == :auth_refused,
      do: {:error, :auth_refused, error},
      else:
        {:error,
         "What the app would hide or warn about is not marked: " <>
           what <> " could not be read" <> said(reason) <> "."}
  end

  defp said(%AtMcp.Effects.Failure{status: status, message: message}) when is_integer(status) do
    if is_binary(message) and message != "",
      do: " (the service answered " <> Integer.to_string(status) <> ": " <> message <> ")",
      else: " (the service answered " <> Integer.to_string(status) <> ")"
  end

  defp said(_reason), do: ""

  # --- what each kind of result holds ---

  defp subjects(result, {:author_feed, _actor}), do: subjects(result, :posts)

  defp subjects(result, kind) when kind in [:posts, :profiles],
    do: Enum.filter(List.wrap(get(result, :items)), &subject?/1)

  defp subjects(result, :profile), do: if(subject?(result), do: [result], else: [])

  defp subjects(result, :thread) do
    nodes(result) ++ Enum.filter(List.wrap(get(result, :hidden_replies)), &subject?/1)
  end

  defp subjects(result, :chain),
    do:
      Enum.filter(List.wrap(get(result, :chain)) ++ List.wrap(get(result, :replies)), &subject?/1)

  defp nodes(node) do
    if subject?(node) do
      [node] ++
        nodes(get(node, :parent)) ++
        Enum.flat_map(List.wrap(get(node, :replies)), &nodes/1)
    else
      []
    end
  end

  defp subject?(value), do: is_map(value) and is_binary(get(value, :uri) || get(value, :did))

  # --- marking ---

  defp apply_marks(result, :posts, opts),
    do: update(result, :items, &Enum.map(&1, fn post -> post(post, opts, :content_list) end))

  defp apply_marks(result, {:author_feed, actor}, opts),
    do: update(result, :items, &Enum.map(&1, fn post -> profile_post(post, opts, actor) end))

  defp apply_marks(result, :profiles, opts),
    do:
      update(
        result,
        :items,
        &Enum.map(&1, fn account -> account(account, opts, :profile_list) end)
      )

  defp apply_marks(result, :profile, opts), do: account(result, opts, :profile_view)

  # The post a thread is opened on is shown as a post's own view; its parents
  # and replies as a thread shows them: covered, never left out. A reply
  # covered or left out of a list moves, as the app's thread moves it.
  defp apply_marks(result, :thread, opts) do
    result
    |> post(opts, :content_view)
    |> update(:parent, &parents(&1, opts))
    |> update(:replies, &replies(&1, opts, 1, :main))
    |> update(
      :hidden_replies,
      &Enum.map(&1, fn reply -> post(reply, opts, :content_list, :thread) end)
    )
  end

  defp apply_marks(result, :chain, opts) do
    chain = List.wrap(get(result, :chain))
    last = length(chain) - 1

    result
    |> update(:chain, fn chain ->
      chain
      |> Enum.with_index()
      |> Enum.map(fn {post, index} ->
        if index == last,
          do: post(post, opts, :content_view),
          else: post(post, opts, :content_list, :thread)
      end)
    end)
    |> update(:replies, &Enum.map(&1, fn reply -> post(reply, opts, :content_list, :thread) end))
  end

  defp parents(parent, opts) do
    if subject?(parent),
      do: parent |> post(opts, :content_list, :thread) |> update(:parent, &parents(&1, opts)),
      else: parent
  end

  # The app's thread view (social-app src/state/queries/usePostThread/
  # traversal.ts:166-271 at 62b95002): a moved reply directly under the post
  # goes under "Show more replies" with the replies under it that are not
  # moved themselves, up to the first that is blocked or gone, where the
  # walk of that branch stops (traversal.ts:255-260); a moved reply deeper
  # down is left out with everything under it, shown only when its parent
  # is opened. A reply the read of left-out replies already marks
  # (`left_out`) keeps that mark alone. Each is covered as a thread covers it.
  defp replies(replies, opts, depth, branch) when is_list(replies) do
    {replies, _stopped} = walk(replies, opts, depth, branch, false)
    replies
  end

  defp replies(other, _opts, _depth, _branch), do: other

  # `stopped` carries the stop through the rest of a moved branch, in the
  # order the app walks it: each reply, then the replies under it.
  defp walk(replies, opts, depth, branch, stopped) when is_list(replies) do
    Enum.map_reduce(replies, stopped, fn reply, stopped ->
      cond do
        not available?(reply) ->
          {reply, stopped or branch == :other}

        true ->
          decision = Decision.post(reply, opts)
          moved? = Decision.moved_in_thread?(decision, get(reply, :hidden_by_threadgate) == true)

          {place, below} =
            case {branch, moved?} do
              {:dropped, _} -> {"under_left_out", :dropped}
              {:other, _} when stopped -> {"left_out", :other}
              {:main, true} when depth == 1 -> {"show_more_replies", :other}
              {:main, true} -> {"left_out", :dropped}
              {:main, false} -> {nil, :main}
              {:other, true} -> {"left_out", :dropped}
              {:other, false} -> {"show_more_replies", :other}
            end

          place = if get(reply, :left_out) == true, do: nil, else: place

          # A moved reply directly under the post starts its own walk.
          {children, stopped} =
            case get(reply, :replies) do
              list when is_list(list) and below == :other and depth == 1 ->
                {walk(list, opts, depth + 1, below, false) |> elem(0), stopped}

              list when is_list(list) ->
                walk(list, opts, depth + 1, below, stopped)

              other ->
                {other, stopped}
            end

          reply =
            reply
            |> marked(Decision.marks(decision, :content_list, :post, :thread), place)
            |> then(&if(is_list(children), do: put(&1, :replies, children), else: &1))

          {reply, stopped}
      end
    end)
  end

  defp available?(reply),
    do:
      subject?(reply) and is_binary(get(reply, :author_did)) and get(reply, :blocked) != true and
        get(reply, :not_found) != true

  defp post(post, opts, context, mode \\ :list) do
    if subject?(post) and is_binary(get(post, :author_did)),
      do: marked(post, Decision.marks(Decision.post(post, opts), context, :post, mode), nil),
      else: post
  end

  # A post on a profile by the profile's own account (`ignoreFilterFor`,
  # Profile.tsx:440,467 and post-feed.ts:303-316 at 62b95002): its mutes are
  # dropped, and nothing leaves it out.
  defp profile_post(post, opts, actor) do
    if subject?(post) and by?(post, actor) do
      decision = Decision.post(post, opts)
      decision = %{decision | causes: Enum.reject(decision.causes, &(&1.type == :muted))}
      marked(post, Decision.marks(decision, :content_list, :post, :author_feed), nil)
    else
      post(post, opts, :content_list)
    end
  end

  defp by?(post, actor) do
    actor = String.downcase(actor)

    String.downcase(get(post, :author_did) || "") == actor or
      String.downcase(get(post, :author) || "") == String.trim_leading(actor, "@")
  end

  defp account(account, opts, context) do
    if subject?(account) and is_binary(get(account, :did)),
      do:
        marked(account, Decision.marks(Decision.profile(account, opts), context, :account), nil),
      else: account
  end

  defp marked(subject, [], nil), do: subject

  defp marked(subject, causes, place) do
    put(
      subject,
      :moderation,
      if(place, do: %{causes: causes, in_thread: place}, else: %{causes: causes})
    )
  end

  # --- maps with atom or string keys ---

  defp get(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp get(_other, _key), do: nil

  defp put(map, key, value) do
    if Map.has_key?(map, Atom.to_string(key)),
      do: Map.put(map, Atom.to_string(key), value),
      else: Map.put(map, key, value)
  end

  defp update(map, key, fun) do
    cond do
      Map.has_key?(map, key) and not is_nil(map[key]) ->
        Map.update!(map, key, fun)

      Map.has_key?(map, Atom.to_string(key)) and not is_nil(map[Atom.to_string(key)]) ->
        Map.update!(map, Atom.to_string(key), fun)

      true ->
        map
    end
  end

  @doc "The schema of a post's or account's `moderation`, for the tools' output schemas."
  def schema do
    cause = %{
      "type" => "object",
      "properties" => %{
        "type" => %{
          "type" => "string",
          "description" => "label, muted_word, muted, blocking or blocked_by"
        },
        "effect" => %{
          "type" => "string",
          "description" =>
            "What the app does: hide (left out of a feed or list), cover (behind a warning a person can open), cover_media (images, or an account's avatar and banner, covered), alert or inform (a badge)"
        },
        "no_override" => %{
          "type" => "boolean",
          "description" => "True when the app offers no way to open what it covers"
        },
        "on" => %{
          "type" => "string",
          "description" =>
            "What the cause is on: post, author, quoted_post, quoted_author, account or profile"
        },
        "label" => %{"type" => "string", "description" => "The label's value"},
        "label_name" => %{
          "type" => "string",
          "description" => "The label's name, as its labeler defines it"
        },
        "setting" => %{
          "type" => "string",
          "description" => "hide or warn: what the account's settings do with the label"
        },
        "labeler" => %{
          "type" => "string",
          "description" => "DID of the labeler that applied the label"
        },
        "labeler_handle" => %{"type" => "string", "description" => "Handle of that labeler"},
        "self_label" => %{
          "type" => "boolean",
          "description" => "True when the author applied the label"
        },
        "words" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "description" => "The muted words it matches"
        },
        "list" => %{
          "type" => "string",
          "description" => "AT URI of the moderation list a mute or block comes through"
        }
      }
    }

    %{
      "type" => ["object", "null"],
      "description" =>
        "What the app would do with this, and why, from the account's own settings and its labelers: it may hide, cover or flag it. Marked only; the content is all here. Absent when the app shows it as it is",
      "properties" => %{
        "causes" => %{
          "type" => "array",
          "items" => cause,
          "description" => "Highest priority first"
        },
        "in_thread" => %{
          "type" => ["string", "null"],
          "description" =>
            "In get_thread, where the app's thread puts a reply: show_more_replies, left_out (shown only when its parent is opened) or under_left_out"
        }
      }
    }
  end

  @doc "The schema of `moderation_unread`."
  def unread_schema do
    %{
      "type" => ["string", "null"],
      "description" =>
        "Why what the app would hide or warn about could not be marked on this read"
    }
  end
end
