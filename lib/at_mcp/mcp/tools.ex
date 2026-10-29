defmodule AtMcp.MCP.Tools do
  @moduledoc """
  A tool's result, and its refusals, as text and structured content.

  The text of a refusal is built as `AtMcp.Reading`'s is, from
  `AtMcp.Reading.Text` pieces only: AtMcp's own words are `~L` constants, and
  every value that came from elsewhere goes through a renderer. What a
  service said (a refusal's message, which for a custom feed or a labeler is
  a third party's words passed on by the PDS) is one quoted literal, so it
  can never read as a line of AtMcp's own. `test/at_mcp/reading_text_test.exs`
  holds this module to that.
  """
  import AtMcp.Reading.Text

  def respond({:ok, summary}, state), do: {:ok, encode(summary), state}

  def respond(
        {:error, %AtMcp.Effects.Failure{kind: :refused, detail: :membership_not_supported}},
        state
      ),
      do:
        error(
          state,
          "membership_not_supported",
          ~L"Membership status is available through the Delvetown backend. This connection does not support it; no request was sent."
        )

  def respond(
        {:error, %AtMcp.Effects.Failure{kind: :refused, detail: :invite_codes_not_supported}},
        state
      ),
      do:
        error(
          state,
          "invite_codes_not_supported",
          cat([
            ~L"error: Invitation codes are delve.town's, and this account is on ",
            ident(AtMcp.Network.label()),
            ~L". Nothing was sent."
          ])
        )

  def respond(
        {:error, %AtMcp.Effects.Failure{kind: :refused, detail: :policies_not_published}},
        state
      ),
      do:
        error(
          state,
          "policies_not_published",
          cat([
            ~L"error: The policy pages are delve.town's, and this account is on ",
            ident(AtMcp.Network.label()),
            ~L". Nothing was sent."
          ])
        )

  # A web page of the network's, such as a policy page, that could not be
  # read. The account's service took no part.
  def respond({:error, %AtMcp.Effects.Failure{detail: {:web_page, address}} = failure}, state) do
    {code, what} =
      case failure do
        %{kind: :unreadable} ->
          {"page_unreadable",
           ~L" answered, and its text could not be read from the answer. Retrying will return the same result."}

        %{status: status} when is_integer(status) ->
          {"page_unavailable", cat([~L" answered HTTP ", int(status), ~L"."])}

        _ ->
          {"page_unavailable", ~L" did not answer."}
      end

    error(
      state,
      code,
      cat([~L"error: ", url(address), what, ~L" Nothing else was sent."]),
      Map.reject(%{http_status: failure.status}, fn {_, v} -> is_nil(v) end)
    )
  end

  # A method this network's deployment is known not to serve
  # (`AtMcp.Endpoints.deployments/0`), refused before anything was sent.
  def respond({:error, {:not_served, nsid, evidence}}, state),
    do:
      error(
        state,
        "not_served",
        cat([
          ~L"error: ",
          ident(AtMcp.Network.label()),
          ~L" does not serve ",
          ident(nsid),
          ~L": ",
          literal(evidence),
          ~L". Nothing was sent and nothing was counted against the write quota."
        ]),
        %{method: nsid}
      )

  # The same refusal, followed by what the caller can use instead.
  def respond({:error, {:not_served, nsid, evidence, :ungrouped_notifications}}, state),
    do:
      error(
        state,
        "not_served",
        cat([
          ~L"error: ",
          ident(AtMcp.Network.label()),
          ~L" does not serve ",
          ident(nsid),
          ~L": ",
          literal(evidence),
          ~L". Nothing was sent and nothing was counted against the write quota. ",
          ~L"get_notifications without grouped reads the same notifications one at a time."
        ]),
        %{method: nsid}
      )

  # A refusal whose message AtMcp composed elsewhere, from its own words and,
  # for a partial deletion, the service's: the message is one literal.
  def respond(
        {:error,
         %AtMcp.Effects.Failure{kind: :refused, detail: {:wrong_record_kind, _, _}} = failure},
        state
      ),
      do: error(state, "wrong_record_kind", composed(failure))

  # A compare-and-swap write the service refused because the record changed
  # after AtMcp read it. Nothing was written; the message says what changed.
  def respond(
        {:error,
         %AtMcp.Effects.Failure{kind: :refused, detail: {:changed_meanwhile, _}} = failure},
        state
      ),
      do: error(state, "changed_meanwhile", composed(failure))

  # A deletion too large for one commit that stopped part way: the commits
  # that landed deleted `deleted`, and the message says what became of the
  # next one, in the service's words.
  def respond(
        {:error,
         %AtMcp.Effects.Failure{kind: :refused, detail: {:partially_written, deleted, _}} =
           failure},
        state
      ),
      do:
        error(
          state,
          "partially_written",
          composed(failure),
          Map.reject(%{deleted: deleted, http_status: failure.status}, fn {_, v} -> is_nil(v) end)
        )

  def respond(
        {:error, %AtMcp.Effects.Failure{kind: :refused, detail: {:draft_gone, id}} = failure},
        state
      ),
      do: error(state, "draft_not_found", composed(failure), %{id: id})

  # A read of a record, list or starter pack the service says does not exist.
  def respond(
        {:error, %AtMcp.Effects.Failure{kind: :refused, detail: {:not_found, what, uri}}},
        state
      ),
      do:
        error(
          state,
          "not_found",
          cat([
            ~L"error: there is no ",
            ident(what),
            ~L" at ",
            ident(uri),
            ~L": it was deleted, taken down, or never existed. Nothing was changed."
          ]),
          %{uri: uri}
        )

  def respond({:error, :not_connected}, state),
    do:
      error(
        state,
        "not_connected",
        ~L"error: this account is not connected: it has no credentials. Configure it in at_mcp's accounts file."
      )

  # A profile write with links whose outcome is unknown: the new link records
  # were written, and the profile, which would name them and stop naming the
  # old ones, may or may not have been.
  def respond(
        {:error,
         {:write_outcome_unknown,
          %AtMcp.Effects.Failure{detail: {:profile_links, created, removed}}}},
        state
      ) do
    error(
      state,
      "write_outcome_unknown",
      cat([
        ~L"error: write outcome unknown; the profile may or may not have been changed. Its new link records were written: ",
        join(Enum.map(created, &ident/1), :comma),
        ~L". If the profile was not changed, nothing shows them. The link records it would stop showing were not deleted: ",
        join(Enum.map(removed, &ident/1), :comma),
        ~L". Read the profile record before deciding whether to retry. AtMcp did not retry this uncertain write."
      ]),
      %{outcome: "unknown", created: created, not_removed: removed}
    )
  end

  def respond(
        {:error,
         {:write_outcome_unknown,
          %AtMcp.Effects.Failure{detail: {:identity_authority_unconfirmed, written}}}},
        state
      ) do
    error(
      state,
      "write_outcome_unknown",
      cat([
        ~L"error: the record was written at ",
        ident(written.uri),
        ~L", but whether it takes effect could not be confirmed. Read the account's identity state and visible result before deciding whether to retry. AtMcp did not retry this uncertain write."
      ]),
      %{outcome: "unknown", written: Map.take(written, [:uri, :cid])}
    )
  end

  def respond({:error, {:write_outcome_unknown, _reason}}, state) do
    error(
      state,
      "write_outcome_unknown",
      ~L"error: write outcome unknown; the action may have completed. Inspect the account's current records before deciding whether to retry. AtMcp did not retry this uncertain write.",
      %{outcome: "unknown"}
    )
  end

  # AtMcp stopped the call at its deadline before anything was sent that could
  # change the account; a write that had been sent is `write_outcome_unknown`.
  def respond({:error, :call_deadline_exceeded}, state) do
    seconds = div(AtMcp.Effects.call_deadline() + 999, 1000)

    error(
      state,
      "call_deadline_exceeded",
      cat([
        ~L"error: AtMcp stopped waiting after ",
        int(seconds),
        ~L" seconds: the account's service, or an earlier request on this account, did not answer in time. Nothing was changed. Retrying later may succeed."
      ])
    )
  end

  @account_errors %{
    account_disconnected:
      ~L"This account is disconnected. Reconnect it through at_mcp's account controls; opening another client does not reconnect it.",
    account_identity_changed:
      ~L"The login identity does not match this connection's expected account. Stop using this connection and repair its account configuration.",
    account_runtime_unavailable:
      ~L"The account runtime is unavailable. Inspect the account status with at_mcp-accounts. If a write was in progress, inspect the account records before retrying it.",
    account_authentication_failed:
      ~L"The account's credential was refused and could not be renewed, so this account is logged out. Nothing was applied. Check the app password and reconnect; retrying the same request will not help.",
    invalid_image:
      ~L"An image could not be read. Each entry needs either base64 `data` or a file `path`, a `mime_type` (or `mimeType`, not two that differ), and for a post `alt` text; nothing was sent.",
    media_dir_unset:
      ~L"This server does not read image files: its operator has not set AT_MCP_MEDIA_DIR. Send the image as base64 `data` instead; nothing was sent.",
    invalid_post_text:
      ~L"Post/reply text must be valid UTF-8. Nothing was attempted and nothing was counted against the write quota.",
    empty_batch: ~L"Supply at least one URI or actor. Nothing was attempted."
  }

  def respond({:error, :batch_too_large}, state),
    do:
      error(
        state,
        "batch_too_large",
        cat([
          ~L"error: Ask for at most ",
          int(AtMcp.Effects.max_batch()),
          ~L" URIs or actors in one call. Nothing was attempted; split the list and call again."
        ])
      )

  def respond({:error, {:media_path_refused, path}}, state) do
    error(
      state,
      "media_path_refused",
      cat([
        ~L"error: ",
        literal(path),
        ~L" is not a regular file inside the media directory ",
        literal(AtMcp.MediaFile.dir()),
        ~L". A path is relative to that directory, or absolute and inside it. Nothing was sent."
      ]),
      %{path: path}
    )
  end

  def respond({:error, {:media_too_large, bytes}}, state),
    do:
      error(
        state,
        "media_too_large",
        cat([~L"error: an image file may be at most ", int(bytes), ~L" bytes. Nothing was sent."])
      )

  def respond({:error, reason}, state) when is_map_key(@account_errors, reason),
    do:
      error(
        state,
        Atom.to_string(reason),
        cat([~L"error: ", Map.fetch!(@account_errors, reason)])
      )

  # The numbers in this one are the configured network's, not Bluesky's. An
  # agent told "at most 300 graphemes" on a network that takes 100,000 has been
  # given a reason it cannot act on.
  def respond({:error, :post_text_too_long}, state) do
    %{graphemes: graphemes, bytes: bytes} = AtMcp.Network.post_limits()

    error(
      state,
      "post_text_too_long",
      cat([
        ~L"error: Post/reply text must be at most ",
        int(graphemes),
        ~L" Unicode graphemes and ",
        int(bytes),
        ~L" UTF-8 bytes. Nothing was attempted and nothing was counted against the write quota."
      ])
    )
  end

  # A cursor comes back from the caller, so it can come back as anything. This
  # is AtMcp refusing the argument, not the service refusing the read.
  def respond({:error, :invalid_before}, state),
    do:
      error(
        state,
        "invalid_before",
        ~L"error: before must be the AT URI a previous call returned in chain_before. Nothing was read."
      )

  def respond({:error, :invalid_search_sort}, state),
    do:
      error(
        state,
        "invalid_search_sort",
        ~L"error: sort must be latest or top. Nothing was read."
      )

  def respond({:error, :invalid_search_filter}, state),
    do:
      error(
        state,
        "invalid_search_filter",
        ~L"error: author, mentions, since, until and lang must be strings when set. Nothing was read."
      )

  def respond({:error, :write_quota_unavailable}, state),
    do:
      error(
        state,
        "write_quota_unavailable",
        ~L"error: account write quota unavailable; writes remain paused until AtMcp recovers"
      )

  # A like or repost whose CID was left out, of a subject the AppView has no
  # view of: there is no current CID to take.
  def respond({:error, {:subject_cid_unknown, uri}}, state) do
    error(
      state,
      "subject_cid_unknown",
      cat([
        ~L"error: the AppView has no view of ",
        ident(uri),
        ~L" (not indexed yet, deleted, or hidden by a block), so its CID could not be read. Nothing was sent. Check the URI, or pass cid if you have it (get_record gives it)."
      ]),
      %{uri: uri}
    )
  end

  # A like or repost whose given CID is neither the AppView's nor the one the
  # record itself has. The caller decides which version it meant.
  def respond({:error, {:subject_cid_mismatch, uri, given, current}}, state) do
    error(
      state,
      "subject_cid_mismatch",
      cat([
        ~L"error: ",
        ident(given),
        ~L" is not the CID of ",
        ident(uri),
        ~L"; the record's CID is ",
        ident(current),
        ~L". Nothing was sent. Pass cid ",
        ident(current),
        ~L", or leave cid out to use the AppView's CID for it."
      ]),
      %{uri: uri, cid: given, current_cid: current}
    )
  end

  # A reply or a quote names a record AtMcp has to read to build the write. That
  # read runs before the write quota is charged, so this refusal costs nothing —
  # and saying so is the difference between a caller that tries a different
  # post and one that believes it has spent a write it has not.
  # The refusal says what the service said about the record, since each cause
  # calls for a different move: a record that is not there means referencing
  # another; any other refusal is passed on in the service's own words.
  def respond({:error, {:referenced_record_unreadable, uri, cause}}, state) do
    {why, details} = unreadable_cause(cause)

    error(
      state,
      "referenced_record_unreadable",
      cat([
        ~L"error: the record at ",
        ident(uri),
        ~L" could not be read, so the reference could not be built: ",
        why,
        ~L". Nothing was written and nothing was counted against the write quota."
      ]),
      Map.merge(%{uri: uri}, details)
    )
  end

  # A reply the thread's reply rule does not let this account make, refused
  # before anything was written.
  def respond({:error, {:reply_disabled, uri}}, state) do
    error(
      state,
      "reply_disabled",
      cat([
        ~L"error: the thread's reply rule (its threadgate) does not let this account reply to ",
        ident(uri),
        ~L"; the app disables reply to it too. Nothing was written and nothing was counted against the write quota."
      ]),
      %{uri: uri}
    )
  end

  # A follow, block or mute names its subject by handle, and the handle is
  # resolved before the write quota is charged. One the service could not
  # resolve is a refusal: the write was never sent.
  def respond({:error, {:handle_not_resolved, handle}}, state) do
    error(
      state,
      "handle_not_resolved",
      cat([
        ~L"error: Nothing was sent: the account's service could not resolve the handle ",
        ident(handle),
        ~L". Nothing was counted against the write quota."
      ]),
      %{handle: handle}
    )
  end

  # An argument the input schema accepts and AtMcp still cannot act on: a post
  # in another account's repository, a list URI that is not a list. It is the
  # same refusal as a schema mismatch, naming the argument, and it is decided
  # before anything is sent. The message can hold what the caller gave, so it
  # is a literal.
  def respond({:error, {:invalid_argument, path, message}}, state) do
    error(
      state,
      "invalid_arguments",
      cat([
        ~L"error: ",
        ident(path),
        ~L": ",
        literal(message),
        ~L". Nothing was sent and nothing was counted against the write quota."
      ]),
      %{problems: [%{path: path, message: message}]}
    )
  end

  def respond({:error, {:write_quota_exhausted, resets_at}}, state) do
    reset = iso8601(resets_at)

    error(
      state,
      "write_quota_exhausted",
      cat([~L"error: account write quota exhausted; resets at ", time(reset)]),
      %{resets_at: reset}
    )
  end

  # An application service refusing or failing a request is an ordinary outcome
  # an agent must be able to act on. Report what it said and whether retrying
  # could help, without publishing the internals of the client library.
  # AtMcp could not read what the service sent. Saying "the request did not
  # complete" would be false twice over — it completed, and the service answered
  # — and it would send an agent into a retry loop against a condition that is
  # deterministic in AtMcp's own parser.
  def respond({:error, %AtMcp.Effects.Failure{kind: :unreadable} = upstream}, state) do
    error(
      state,
      "response_unreadable",
      cat([
        ~L"error: ",
        literal(upstream.message),
        ~L" Nothing was applied and nothing was read. Retrying will return the same result; report this rather than repeating it."
      ]),
      Map.reject(%{http_status: upstream.status}, fn {_, v} -> is_nil(v) end)
    )
  end

  def respond({:error, %AtMcp.Effects.Failure{kind: kind} = upstream}, state)
      when kind in [:refused, :auth_refused, :indeterminate] do
    status = upstream.status
    detail = upstream_detail(upstream)

    {code, guidance} =
      cond do
        status == 501 ->
          {"upstream_not_implemented",
           ~L"The account's service reports that this operation is not implemented. Repeating the same request is not expected to help; check which operations the service supports."}

        status == 429 ->
          {"upstream_rate_limited",
           ~L"The account's service is rate limiting this client. Wait before retrying."}

        is_integer(status) and status >= 500 ->
          {"upstream_unavailable",
           ~L"The account's service is unavailable. The request was not applied; retrying later may succeed."}

        is_integer(status) and status in 400..499 ->
          {"upstream_rejected",
           ~L"The account's service rejected this request. Check the request before retrying it unchanged."}

        true ->
          {"upstream_failed", ~L"The request to the account's service did not complete."}
      end

    error(
      state,
      code,
      cat([~L"error: ", detail, ~L" ", guidance]),
      Map.reject(%{http_status: status, upstream_message: upstream.message}, fn {_, v} ->
        is_nil(v)
      end)
    )
  end

  def respond({:error, reason}, state),
    do:
      {:ok, ExMCP.Server.DSL.Result.error(to_text(cat([~L"error: ", reason_text(reason)]))),
       state}

  def respond(other, state), do: {:ok, encode(other), state}

  @doc """
  `respond/2` for a read made of posts, accounts, lists, starter packs, feeds,
  trends or invitation codes. The structured content is the same; the text a
  model reads is `AtMcp.Reading`'s `reading` of it (`:posts`, `:notifications`,
  `:thread`, `:chain`, `:profile`, `:profiles`, `:list`, `:lists`,
  `:starter_pack`, `:starter_packs`, `:feeds`, `:trends`, `:invite_codes`,
  `:preferences`, `:notification_settings`, `:labelers` or `:policy`)
  instead of the serialized JSON. A
  result that reading does not recognize keeps the JSON text.
  """
  def respond({:ok, summary}, state, reading) do
    case encode(summary) do
      %{structuredContent: data} = result ->
        case apply(AtMcp.Reading, reading, [data]) do
          text when is_binary(text) ->
            {:ok, %{result | content: [%{type: "text", text: text}]}, state}

          nil ->
            {:ok, result, state}
        end

      other ->
        {:ok, other, state}
    end
  end

  def respond(result, state, _reading), do: respond(result, state)

  @doc """
  `respond/3` for a page of posts or notifications, read by `fetch`, a
  function of the limit to ask the service for (`nil` for the caller's) and
  the cursor.

  `detail: "brief"` reads it with `AtMcp.Reading.brief_posts/1`. A page whose
  reading would pass `AtMcp.Reading.page_chars/0` is asked for again with the
  number of items that fit, and the second answer is taken only when it
  plainly begins the first (`bounded/4`). A page asked for as JSON is for a
  program, which pages by count, and is bounded by its `limit` alone.

  `feed`, for a feed whose read position is held (`AtMcp.ReadPositions.key/2`),
  takes `since` and `mark_read`: see `positioned/6`.
  """
  def page(fetch, args, state, reading, feed \\ nil) do
    reading = if Map.get(args, :detail) == "brief", do: :brief_posts, else: reading
    json? = AtMcp.MCP.DSL.format(args, state) == "json"
    cursor = Map.get(args, :cursor)
    started = System.monotonic_time(:millisecond)

    case valid_since(Map.get(args, :since), feed) do
      :ok ->
        result = fetch.(Map.get(args, :limit), cursor)

        if(json?, do: result, else: bounded(result, &fetch.(&1, cursor), reading, started))
        |> positioned(args, state, feed, fetch, started)
        |> respond(state, reading)

      error ->
        respond(error, state)
    end
  end

  @doc """
  `respond/3` for `get_thread`, its reading bounded as a page's is
  (`AtMcp.Reading.page_chars/0`). A thread that would read longer keeps its
  first direct replies, each whole with the replies under it, in the order
  the service gave them, and says how many it left out; the post's
  `replies_omitted` counts them. A thread asked for as JSON is whole.
  """
  def thread(result, args, state) do
    if AtMcp.MCP.DSL.format(args, state) == "json",
      do: respond(result, state, :thread),
      else: result |> bounded_thread() |> respond(state, :thread)
  end

  defp bounded_thread({:ok, %{replies: [_ | _] = replies} = thread} = result) do
    data = Jason.decode!(Jason.encode!(thread))
    count = length(replies)

    reads_in? = fn kept ->
      cut =
        Map.merge(data, %{
          "replies" => Enum.take(data["replies"], kept),
          "replies_cut" => count - kept
        })

      String.length(AtMcp.Reading.thread(cut) || "") <= AtMcp.Reading.page_chars()
    end

    case most(0, count, reads_in?) do
      ^count ->
        result

      kept ->
        {:ok,
         Map.merge(thread, %{
           replies: Enum.take(replies, kept),
           replies_omitted: (thread[:replies_omitted] || 0) + count - kept,
           replies_cut: count - kept
         })}
    end
  end

  defp bounded_thread(result), do: result

  # The largest n in low..high for which fits?.(n) holds, fits? holding for
  # every n below one it holds for; `low` when none does.
  defp most(low, high, _fits?) when low >= high, do: low

  defp most(low, high, fits?) do
    mid = div(low + high + 1, 2)
    if fits?.(mid), do: most(mid, high, fits?), else: most(low, mid - 1, fits?)
  end

  # The cut page is the service's second answer, so it is taken only when it
  # is plainly the first page's beginning: the same first posts, in order, and
  # a cursor of its own. A custom feed's generator need not honour `limit`,
  # and the AppView then cuts its skeleton and passes the generator's cursor
  # on unchanged, which would skip every post between the cut and that
  # cursor; a feed that changed between the two reads, or that answers each
  # read differently, gives other posts. Either way the first page is
  # returned whole, saying it is longer than the bound. So is a page whose
  # second read would not answer before the endpoint stops waiting.
  defp bounded({:ok, %{} = page} = result, fetch, reading, started) do
    with {:ok, json} <- Jason.encode(page),
         %{"items" => [_, _ | _] = items} = data <- Jason.decode!(json),
         fit when fit < length(items) <- fitting(data, items, reading) do
      case cut(page, fetch, fit, items, started) do
        {:ok, smaller} -> {:ok, smaller}
        :error -> {:ok, Map.put(page, :over_bound, true)}
      end
    else
      _ -> result
    end
  end

  defp bounded(result, _fetch, _reading, _started), do: result

  defp cut(page, fetch, fit, items, started) do
    with true <- time_left?(started),
         {:ok, %{items: [_ | _] = shown} = smaller} <- fetch.(fit),
         true <- length(shown) < length(items),
         true <- uris(shown) == uris(Enum.take(page.items, length(shown))),
         cursor when is_binary(cursor) <- smaller[:cursor],
         true <- cursor != page[:cursor] do
      {:ok, Map.put(smaller, :left_out, length(items) - length(shown))}
    else
      _ -> :error
    end
  end

  defp uris(items), do: Enum.map(items, &(&1[:uri] || &1["uri"]))

  # An account call answers within `AtMcp.Effects.answered_within/0`, and the
  # endpoint waits `AtMcp.MCP.HTTP.handler_call_timeout/0` for the whole tool
  # call, which is sized for one. A read makes a second only while the
  # endpoint would still be waiting when it answered, so every call is still
  # answered by AtMcp rather than abandoned by ExMCP.
  @result_margin_ms 3_000

  defp time_left?(started) do
    elapsed = System.monotonic_time(:millisecond) - started

    elapsed + AtMcp.Effects.answered_within() + @result_margin_ms <=
      AtMcp.MCP.HTTP.handler_call_timeout()
  end

  # How many of the page's first items its reading holds within the bound;
  # at least one.
  defp fitting(data, items, reading) do
    fits? = fn n ->
      page = Map.merge(data, %{"items" => Enum.take(items, n), "left_out" => length(items) - n})
      text = apply(AtMcp.Reading, reading, [page])
      not is_binary(text) or String.length(text) <= AtMcp.Reading.page_chars()
    end

    if fits?.(length(items)),
      do: length(items),
      else: Enum.find(length(items)..2//-1, 1, fits?)
  end

  # `since` is read only on a feed whose position is held; `search_posts` has
  # a `since` of its own, which the service applies.
  defp valid_since(nil, _feed), do: :ok
  defp valid_since(_since, nil), do: :ok
  defp valid_since("last_read", _feed), do: :ok

  defp valid_since(at, _feed) do
    case DateTime.from_iso8601(at) do
      {:ok, _, _} ->
        :ok

      _ ->
        {:error,
         {:invalid_argument, "since",
          "must be last_read or a time such as 2026-10-29T08:00:00Z; nothing was read"}}
    end
  end

  # The read position, after the read: the account has a session by then, so
  # its DID is known. `since` keeps only the items newer than the position
  # (`last_read`) or the time given. A read moves the position only when it
  # asks to (`marks?/1`), and only once it has reached the position it read
  # from: a page that is all newer, whose older items are still unread, holds
  # its newest time as pending, and the read that reaches the position (the
  # same `since: "last_read"` with the cursor) commits it. So no read, cut
  # short or interrupted, moves the position past items not yet returned.
  defp positioned({:ok, %{items: items} = page}, args, state, feed, fetch, started)
       when is_binary(feed) and is_list(items) do
    did = account(state)
    asked = Map.get(args, :since)

    case did && AtMcp.ReadPositions.get(did, feed) do
      {:ok, %{at: held}} ->
        since = if asked == "last_read", do: held, else: asked
        reached? = reached?(page, held)

        page
        |> newer(since, asked, fetch, started)
        |> mark(marks?(args) && reached?, marks?(args), did, feed)

      nil ->
        # The read itself logs in, so this is an account that has no session
        # even after it: say so rather than read as if no position were held.
        {:error, :not_connected}

      {:error, why} ->
        {:ok,
         Map.merge(page, %{
           since: if(asked == "last_read", do: nil, else: asked),
           since_asked: asked,
           since_unread: if(asked == "last_read", do: inspect(why)),
           read_position_unsaved: if(marks?(args), do: inspect(why))
         })}
    end
  end

  defp positioned(result, _args, _state, _feed, _fetch, _started), do: result

  defp account(%{effects: effects}), do: AtMcp.Effects.account_did(effects)
  defp account(_state), do: nil

  # Whether this read moves the position. A read since a time looks back and
  # never marks; otherwise as `mark_read` says, else when it asked for what
  # is new since the position.
  defp marks?(%{since: since}) when is_binary(since) and since != "last_read", do: false
  defp marks?(%{mark_read: mark}) when is_boolean(mark), do: mark
  defp marks?(args), do: Map.get(args, :since) == "last_read"

  # Whether a page reaches back to the position: it holds an item at or before
  # it, or nothing comes after it. With no position held, any page does.
  defp reached?(_page, nil), do: true

  defp reached?(page, held),
    do: not is_binary(page[:cursor]) or Enum.any?(page.items, &(not later?(&1, held)))

  # How many items past a page a read with `since` counts, to say how many are
  # new: four more pages of the largest size.
  @count_pages 4

  # Only the page's items newer than `since`, newest first as the service
  # sends them. When the whole page is newer, it reads on only to count how
  # many are, and keeps its cursor, which continues into them with the same
  # `since`; otherwise there is no more to read.
  defp newer(page, since, asked, fetch, started) when is_binary(since) do
    new = Enum.filter(page.items, &later?(&1, since))
    rest? = length(new) == length(page.items) and is_binary(page[:cursor])

    {more, exact?} =
      if rest?,
        do: count_newer(fetch, page[:cursor], since, @count_pages, started),
        else: {0, true}

    Map.merge(page, %{
      items: new,
      count: length(new),
      cursor: if(rest?, do: page[:cursor]),
      since: since,
      since_asked: asked,
      new_total: length(new) + more,
      new_total_exact: exact?
    })
  end

  # `last_read` with no position held: everything is new, and this is the
  # newest page.
  defp newer(page, nil, "last_read", _fetch, _started),
    do: Map.merge(page, %{since: nil, since_asked: "last_read"})

  defp newer(page, _since, _asked, _fetch, _started), do: page

  defp count_newer(_fetch, _cursor, _at, 0, _started), do: {0, false}

  defp count_newer(fetch, cursor, at, pages, started) do
    with true <- time_left?(started),
         {:ok, %{items: items} = page} when is_list(items) <-
           fetch.(AtMcp.Effects.page_limits().max, cursor) do
      new = Enum.count(items, &later?(&1, at))

      if new < length(items) or not is_binary(page[:cursor]) do
        {new, true}
      else
        {more, exact?} = count_newer(fetch, page[:cursor], at, pages - 1, started)
        {new + more, exact?}
      end
    else
      _ -> {0, false}
    end
  end

  defp later?(item, at) do
    case when_listed(item) do
      time when is_binary(time) -> AtMcp.ReadPositions.later?(time, at)
      _ -> false
    end
  end

  # Where an item sits in its feed's order: a repost at the repost's time;
  # anything else at the earlier of when it says it was made and when the
  # service indexed it, as the AppView sorts a feed (`sortAt`).
  defp when_listed(item) when is_map(item) do
    reason = item[:reason]

    case {is_map(reason) && reason[:at], item[:created_at], item[:indexed_at]} do
      {at, _, _} when is_binary(at) -> at
      {_, made, indexed} when is_binary(made) and is_binary(indexed) -> earlier(made, indexed)
      {_, made, indexed} -> indexed || made
    end
  end

  defp when_listed(_item), do: nil

  defp earlier(a, b), do: if(AtMcp.ReadPositions.later?(a, b), do: b, else: a)

  # Commit the newest item returned when the read reached the position, or
  # hold it as pending when it did not; nothing when the read does not mark.
  defp mark(page, commit?, marks?, did, feed) do
    newest = page.items |> Enum.map(&when_listed/1) |> Enum.reduce(nil, &newest/2)

    cond do
      not marks? or is_nil(newest) ->
        {:ok, page}

      true ->
        case AtMcp.ReadPositions.advance(did, feed, newest, commit?) do
          {:ok, %{at: at}} -> {:ok, Map.put(page, :read_position, at)}
          {:error, reason} -> {:ok, Map.put(page, :read_position_unsaved, inspect(reason))}
        end
    end
  end

  defp newest(at, nil) when is_binary(at),
    do: if(match?({:ok, _, _}, DateTime.from_iso8601(at)), do: at)

  defp newest(at, max) when is_binary(at),
    do: if(AtMcp.ReadPositions.later?(at, max), do: at, else: max)

  defp newest(_at, max), do: max

  # What a refusal's message says, which AtMcp composed from its own words
  # and, at times, the service's: one literal.
  defp composed(%{message: message}), do: cat([~L"error: ", literal(message)])

  # A reason with no shape of its own: an atom is AtMcp's word, anything else
  # (a schema error, a service's string) a literal.
  defp reason_text(reason) when is_atom(reason), do: ident(Atom.to_string(reason))
  defp reason_text(reason), do: literal(format_reason(reason))

  defp upstream_detail(%{message: message, status: status})
       when is_binary(message) and message != "" and is_integer(status),
       do:
         cat([~L"the account's service answered ", int(status), ~L": ", literal(message), ~L"."])

  defp upstream_detail(%{message: message}) when is_binary(message) and message != "",
    do: cat([~L"the account's service answered: ", literal(message), ~L"."])

  defp upstream_detail(%{status: status}) when is_integer(status),
    do: cat([~L"the account's service answered ", int(status), ~L"."])

  defp upstream_detail(_), do: ~L"the account's service did not answer."

  @doc """
  A handle or DID as a tool argument names it. Models write handles the way
  people do, `@alice.example`, and neither a handle nor a DID starts with `@`,
  so one leading `@` is dropped; anything else is passed on as given.
  """
  def actor("@" <> actor), do: actor
  def actor(actor), do: actor

  @doc "An optional handle or DID: omit, empty, and whitespace are all absent."
  def optional_actor(actor) when is_binary(actor) do
    case String.trim(actor) do
      "" -> nil
      trimmed -> actor(trimmed)
    end
  end

  def optional_actor(_), do: nil

  @doc "An optional argument: omitted, empty and whitespace-only are all absent (nil)."
  def optional(value), do: if(absent?(value), do: nil, else: value)

  @doc "Several handles or DIDs, each read as `actor/1` reads one."
  def actors(actors), do: actors |> List.wrap() |> Enum.map(&actor/1)

  def get_profile(effects, actor) do
    actor =
      case actor do
        nil -> AtMcp.Effects.session_did(effects) || AtMcp.Effects.session_handle(effects)
        "" -> AtMcp.Effects.session_did(effects) || AtMcp.Effects.session_handle(effects)
        other -> other
      end

    cond do
      not is_binary(actor) or actor == "" ->
        {:error, "no actor and this identity is not connected"}

      true ->
        AtMcp.Effects.get_profile(effects, actor)
    end
  end

  @doc """
  The images on the post at `uri`, as `AtMcp.PostImages.result/2` builds them.
  The post is read through the account like any other read; its pictures are
  fetched from the URLs that read returned, outside the account's call.
  """
  def get_post_images(effects, uri, state) do
    case AtMcp.Effects.get_posts(effects, [uri]) do
      {:ok, %{items: [post | _]}} ->
        {:ok, AtMcp.PostImages.result(uri, post), state}

      {:ok, _} ->
        error(
          state,
          "post_not_found",
          cat([
            ~L"error: no post at ",
            ident(uri),
            ~L" could be read. It may be deleted, not indexed yet, or not a post. No image was fetched."
          ]),
          %{uri: uri}
        )

      other ->
        respond(other, state)
    end
  end

  def update_profile(effects, args) when is_map(args) do
    updates =
      []
      |> maybe_kw(:display_name, Map.get(args, :display_name) || Map.get(args, "display_name"))
      |> maybe_kw(:description, Map.get(args, :description) || Map.get(args, "description"))

    # Pronouns and a website given empty are removed, so "" is kept for them.
    updates =
      Enum.reduce([:pronouns, :website], updates, fn key, updates ->
        case Map.get(args, key, Map.get(args, Atom.to_string(key))) do
          value when is_binary(value) -> Keyword.put(updates, key, String.trim(value))
          _ -> updates
        end
      end)

    updates =
      case Map.get(args, :links, Map.get(args, "links")) do
        links when is_list(links) ->
          Keyword.put(updates, :links, Enum.map(links, &profile_link/1))

        _ ->
          updates
      end

    updates =
      case Map.get(args, :labels, Map.get(args, "labels")) do
        labels when is_list(labels) -> Keyword.put(updates, :labels, labels)
        _ -> updates
      end

    with {:ok, updates} <- profile_image(updates, :avatar, args),
         {:ok, updates} <- profile_image(updates, :banner, args) do
      if updates == [] do
        {:error,
         "provide display_name, description, avatar, banner, pronouns, website, links and/or labels"}
      else
        AtMcp.Effects.update_profile(effects, updates)
      end
    end
  end

  # One profile link as `AtMcp.Effects.update_profile/2` takes it. Anything
  # that is not `{url, title}` is passed on for it to refuse by name.
  defp profile_link(%{} = link) do
    title = field(link, "title")

    %{
      url: field(link, "url"),
      title: if(is_binary(title) and String.trim(title) != "", do: String.trim(title))
    }
  end

  defp profile_link(other), do: other

  @doc """
  The fields of a list or starter pack write, from tool arguments: the given
  `keys`, leaving out any not given, and an `avatar` read into bytes here, as
  a post's images are, so a bad one refuses the call before anything is sent.
  """
  def list_fields(args, keys) when is_map(args) do
    fields =
      for key <- keys, key != :avatar, Map.has_key?(args, key), into: %{}, do: {key, args[key]}

    if :avatar in keys do
      case Map.get(args, :avatar) do
        image when image in [nil, %{}] ->
          {:ok, fields}

        image ->
          with {:ok, image} <- decode_image(image), do: {:ok, Map.put(fields, :avatar, image)}
      end
    else
      {:ok, fields}
    end
  end

  # An avatar or banner is read here, before anything is sent, like a post's
  # images: a bad one refuses the whole update.
  defp profile_image(updates, key, args) do
    case Map.get(args, key) || Map.get(args, Atom.to_string(key)) do
      image when image in [nil, %{}] ->
        {:ok, updates}

      image ->
        with {:ok, image} <- decode_image(image), do: {:ok, Keyword.put(updates, key, image)}
    end
  end

  def identity_status(effects) do
    status = %{
      logged_in: AtMcp.Effects.logged_in?(effects),
      did: AtMcp.Effects.session_did(effects),
      login_count: AtMcp.Effects.login_count(effects),
      handle: AtMcp.Effects.session_handle(effects),
      # Which network this account acts on, and what its post record allows.
      # Read here rather than written into a tool description, because a
      # description is frozen when the module compiles and this is not.
      network: %{
        name: Atom.to_string(AtMcp.Network.name()),
        label: AtMcp.Network.label(),
        namespace: AtMcp.Network.namespace(),
        post_limits: AtMcp.Network.post_limits()
      }
    }

    case AtMcp.Effects.quota_status(effects) do
      {:error, _} = error ->
        error

      quota ->
        {:ok,
         status
         |> Map.put(:write_quota, quota_view(quota))}
    end
  end

  # The tool surface reports one time format. `AtMcp.WriteQuota` keeps unix
  # seconds for embedding hosts and its own ledger.
  # The ledger keeps unix seconds; an agent reads a time.
  defp quota_view(quota) do
    {unix, quota} = Map.pop!(quota, :resets_at_unix)
    Map.put(quota, :resets_at, iso8601(unix))
  end

  defp iso8601(nil), do: nil

  defp iso8601(seconds) when is_integer(seconds),
    do: seconds |> DateTime.from_unix!() |> DateTime.to_iso8601()

  defp unreadable_cause(:not_found),
    do:
      {~L"the service has no record there (RecordNotFound); it was deleted, taken down, never existed, or is not indexed yet (records on another server are read through the AppView)",
       %{cause: "not_found"}}

  defp unreadable_cause(:unusable_answer),
    do: {~L"the service answered without the record's CID", %{cause: "unusable_answer"}}

  defp unreadable_cause({:refused, nil, nil}),
    do:
      {~L"the service refused to read it and said nothing more; it may be deleted, not indexed yet, or not what the URI names",
       %{cause: "refused"}}

  defp unreadable_cause({:refused, name, message}) do
    {cat([
       ~L"the service refused to read it (",
       join([ident(name), literal(message)], :colon),
       ~L")"
     ]), Map.reject(%{cause: "refused", service_error: name}, fn {_, v} -> is_nil(v) end)}
  end

  # `message` is a piece; `to_text/1` takes nothing else.
  defp error(state, code, message, details \\ %{}) do
    result = ExMCP.Server.DSL.Result.error(to_text(message))
    {:ok, Map.put(result, :structuredContent, Map.merge(%{code: code}, details)), state}
  end

  defp maybe_kw(kw, _key, nil), do: kw
  defp maybe_kw(kw, key, value), do: Keyword.put(kw, key, value)

  # Backends own page limits and summaries. Keep their complete values here:
  # slicing serialized JSON loses records, continuation cursors, and valid syntax.
  defp encode(value) when is_binary(value), do: value

  defp encode(value) when is_map(value) or is_list(value) do
    case Jason.encode(value) do
      {:ok, json} -> structured(json)
      _ -> inspect(value, pretty: false, limit: 30)
    end
  end

  defp encode(value), do: inspect(value, limit: 30)

  # A summary is returned twice: as the JSON text every MCP client can read,
  # and as structured content for clients that validate against the tool's
  # declared output schema. Both carry the same JSON values, so a client
  # reading either sees one result. Only objects can be structured content.
  # `respond/3` replaces the text with a reading of the same structured
  # content for results made of posts.
  defp structured(json) do
    case Jason.decode(json) do
      {:ok, data} when is_map(data) ->
        %{content: [%{type: "text", text: json}], structuredContent: data}

      _ ->
        json
    end
  end

  @doc """
  Read the optional halves of a post out of tool arguments.

  Image bytes arrive base64-encoded because JSON has no other way to carry
  them; this is where they stop being text. A string that is not base64 is
  refused here, before the write quota is charged and before anything is sent.
  """
  def post_options(args) when is_map(args) do
    with {:ok, images} <- decode_images(Map.get(args, :images)),
         {:ok, link} <- decode_link(Map.get(args, :link)) do
      {:ok,
       Enum.reject(
         [
           langs: Map.get(args, :langs),
           quote: Map.get(args, :quote),
           images: images,
           quotes: Map.get(args, :quotes),
           labels: Map.get(args, :labels),
           link: link
         ],
         fn {_key, value} -> absent?(value) end
       ) ++ reply_rule(Map.get(args, :reply_rule))}
    end
  end

  # `[]` is a rule: nobody may reply. Only an omitted rule is absent.
  defp reply_rule(nil), do: []
  defp reply_rule(rule), do: [reply_rule: rule]

  # A link card's fields as given, and its thumbnail's bytes. Whether the url
  # is one is `AtMcp.Interactions.link/1`'s to say.
  defp decode_link(link) when link in [nil, %{}], do: {:ok, nil}

  defp decode_link(link) when is_map(link) do
    thumb =
      case AtMcp.Response.fetch(link, "thumb") do
        {:ok, image} when image not in [nil, %{}] -> decode_image(image)
        _ -> {:ok, nil}
      end

    with {:ok, thumb} <- thumb do
      {:ok,
       %{
         url: field(link, "url"),
         title: field(link, "title"),
         description: field(link, "description"),
         thumb: thumb
       }}
    end
  end

  defp decode_link(other), do: {:ok, other}

  defp field(map, key) do
    case AtMcp.Response.fetch(map, key) do
      {:ok, value} -> value
      :error -> nil
    end
  end

  # An optional field a caller filled in with nothing is a field it did not fill
  # in. Models routinely send `""` and `[]` for options they are not using, and
  # an empty string is not an AT URI: treating only `nil` as absent lets
  # `quote: ""` reach the record builder, and the service refuses the whole post.
  defp absent?(nil), do: true
  defp absent?(""), do: true
  defp absent?([]), do: true
  defp absent?(value) when is_binary(value), do: String.trim(value) == ""
  defp absent?(_), do: false

  defp decode_images(nil), do: {:ok, nil}
  defp decode_images([]), do: {:ok, nil}

  defp decode_images(images) when is_list(images) do
    Enum.reduce_while(images, {:ok, []}, fn image, {:ok, acc} ->
      with {:ok, alt} <- string_field(image, "alt"),
           {:ok, image} <- decode_image(image) do
        {:cont, {:ok, acc ++ [Map.put(image, :alt, alt)]}}
      else
        {:error, _} = error -> {:halt, error}
        _ -> {:halt, {:error, :invalid_image}}
      end
    end)
  end

  defp decode_images(_other), do: {:error, :invalid_image}

  # One image's bytes: base64 `data`, or a `path` the server reads itself
  # (`AtMcp.MediaFile`), never both. Either way they leave here as bytes.
  defp decode_image(image) do
    with {:ok, mime_type} <- mime_type(image),
         {:ok, data} <- image_bytes(string_field(image, "data"), string_field(image, "path")) do
      {:ok, %{data: data, mime_type: mime_type}}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_image}
    end
  end

  # `mime_type`, or `mimeType` as the AT Protocol blob names it. Both is fine
  # when they agree; two different types is not a choice to make for the caller.
  defp mime_type(image) do
    case {string_field(image, "mime_type"), string_field(image, "mimeType")} do
      {{:ok, a}, {:ok, b}} when a != b -> :error
      {{:ok, a}, _} -> {:ok, a}
      {:error, other} -> other
    end
  end

  defp image_bytes({:ok, encoded}, :error), do: Base.decode64(encoded)
  defp image_bytes(:error, {:ok, path}), do: AtMcp.MediaFile.read(path)
  defp image_bytes(_data, _path), do: :error

  defp string_field(map, key) when is_map(map) do
    case AtMcp.Response.fetch(map, key) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      _ -> :error
    end
  end

  defp string_field(_map, _key), do: :error

  def format_reason(reason) when is_binary(reason), do: reason
  def format_reason(reason) when is_atom(reason), do: Atom.to_string(reason)

  def format_reason([%{__struct__: Peri.Error} | _] = errors),
    do: Enum.map_join(errors, "; ", &format_reason/1)

  def format_reason(%{__struct__: Peri.Error, path: path, message: message}) when is_list(path),
    do: "invalid " <> Enum.map_join(path, ".", &to_string/1) <> ": " <> message

  def format_reason(%{__struct__: Peri.Error, message: message}), do: message
  def format_reason(reason), do: inspect(reason, limit: 20)
end
