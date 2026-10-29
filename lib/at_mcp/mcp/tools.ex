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
          ~L"Membership status is available through the Delvetown backend. This connection does not support it; no request was sent.",
          stop()
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
          ]),
          stop()
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
          ]),
          stop()
        )

  # A web page of the network's, such as a policy page, that could not be
  # read. The account's service took no part.
  def respond({:error, %AtMcp.Effects.Failure{detail: {:web_page, address}} = failure}, state) do
    {code, what, advice} =
      case failure do
        %{kind: :unreadable} ->
          {"page_unreadable", ~L" answered, and its text could not be read from the answer.",
           stop(
             ~L"Trying again will return the same result. Tell the account's operator about this error."
           )}

        %{status: status} when is_integer(status) and status in 400..499 ->
          {"page_unavailable", cat([~L" answered HTTP ", int(status), ~L"."]), stop()}

        %{status: status} when is_integer(status) ->
          {"page_unavailable", cat([~L" answered HTTP ", int(status), ~L"."]), wait(60)}

        _ ->
          {"page_unavailable", ~L" did not answer.", wait(60)}
      end

    error(
      state,
      code,
      cat([~L"error: ", url(address), what, ~L" Nothing else was sent."]),
      advice,
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
        stop(),
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
          ~L". Nothing was sent and nothing was counted against the write quota."
        ]),
        change(
          "grouped",
          ~L"Call get_notifications again without grouped: it reads the same notifications one at a time."
        ),
        %{method: nsid}
      )

  # A refusal whose message AtMcp composed elsewhere, from its own words and,
  # for a partial deletion, the service's: the message is one literal.
  def respond(
        {:error,
         %AtMcp.Effects.Failure{kind: :refused, detail: {:wrong_record_kind, _, _}} = failure},
        state
      ),
      do: error(state, "wrong_record_kind", composed(failure), change("uri"))

  # A compare-and-swap write the service refused because the record changed
  # after AtMcp read it. Nothing was written; the message says what changed.
  def respond(
        {:error,
         %AtMcp.Effects.Failure{kind: :refused, detail: {:changed_meanwhile, _}} = failure},
        state
      ),
      do:
        error(
          state,
          "changed_meanwhile",
          composed(failure),
          now(~L"Read it again, then try again now if the change still applies.")
        )

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
          now(~L"Call it again now to delete what is left."),
          Map.reject(%{deleted: deleted, http_status: failure.status}, fn {_, v} -> is_nil(v) end)
        )

  def respond(
        {:error, %AtMcp.Effects.Failure{kind: :refused, detail: {:draft_gone, id}} = failure},
        state
      ),
      do:
        error(
          state,
          "draft_not_found",
          composed(failure),
          change("id", ~L"Call save_draft without id to keep the text as a new draft."),
          %{id: id}
        )

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
          stop(),
          %{uri: uri}
        )

  def respond({:error, :not_connected}, state),
    do:
      error(
        state,
        "not_connected",
        ~L"error: this account is not connected: it has no credentials.",
        stop(
          ~L"Trying again will not help until its operator configures it in at_mcp's accounts file."
        )
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
        ~L". AtMcp did not retry it."
      ]),
      check_first(
        ~L"Don't retry until you have read the profile record, because the change may already be saved."
      ),
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
        ~L", but whether it takes effect could not be confirmed. AtMcp did not retry it."
      ]),
      check_first(
        ~L"Don't retry until you have read the account's identity state and the visible result."
      ),
      %{outcome: "unknown", written: Map.take(written, [:uri, :cid])}
    )
  end

  def respond({:error, {:write_outcome_unknown, reason}}, state) do
    error(
      state,
      "write_outcome_unknown",
      cat([
        ~L"error: write outcome unknown: ",
        unknown_cause(reason),
        ~L" The action may have completed, and AtMcp did not retry it."
      ]),
      check_first(),
      %{outcome: "unknown"}
    )
  end

  # AtMcp stopped the call at its deadline before anything was sent that could
  # change the account; a write that had been sent is `write_outcome_unknown`.
  # A read says whether its request went to the service.
  def respond({:error, :call_deadline_exceeded}, state) do
    error(
      state,
      "call_deadline_exceeded",
      cat([
        ~L"error: AtMcp stopped waiting after ",
        int(deadline_seconds()),
        ~L" seconds. The request was not sent: it was still waiting for this account's session (a login or refresh) or for an earlier write on the account. Nothing was changed."
      ]),
      now(),
      %{sent: false}
    )
  end

  def respond({:error, {:call_deadline_exceeded, :sent}}, state) do
    error(
      state,
      "call_deadline_exceeded",
      cat([
        ~L"error: AtMcp sent this read to the account's service and stopped waiting after ",
        int(deadline_seconds()),
        ~L" seconds without an answer. Nothing was changed, and no results were read."
      ]),
      now(
        ~L"Trying again now is safe. If this tool takes a limit, a smaller one may get an answer sooner."
      ),
      %{sent: true}
    )
  end

  @account_errors %{
    account_disconnected:
      {~L"This account is disconnected. Its operator can reconnect it through at_mcp's account controls.",
       {:stop, ~L"Until then, trying again will not help."}},
    account_identity_changed:
      {~L"The login identity does not match this connection's expected account.",
       {:stop,
        ~L"Trying again will not help: stop using this connection and repair its account configuration."}},
    account_runtime_unavailable:
      {~L"The account runtime is unavailable. at_mcp-accounts shows the account's status.",
       {:check_first,
        ~L"If you were writing, read the account's records before you try again, because the write may have been saved."}},
    account_authentication_failed:
      {~L"The account's credential was refused and could not be renewed, so this account is logged out. Nothing was applied.",
       {:stop,
        ~L"Trying again will not help until the app password is checked and the account reconnected."}},
    invalid_image:
      {~L"An image could not be read. Each entry needs either base64 `data` or a file `path`, a `mime_type` (or `mimeType`, not two that differ), and for a post `alt` text; nothing was sent.",
       {:change, "images"}},
    media_dir_unset:
      {~L"This server does not read image files: its operator has not set AT_MCP_MEDIA_DIR. Nothing was sent.",
       {:change, "path", ~L"Send the image as base64 data instead of a path."}},
    invalid_post_text:
      {~L"Post/reply text must be valid UTF-8. Nothing was attempted and nothing was counted against the write quota.",
       {:change, "text"}},
    empty_batch:
      {~L"The list of URIs or actors is empty. Nothing was attempted.",
       {:change_any, ~L"Pass at least one URI or actor in the list and try again."}}
  }

  def respond({:error, :batch_too_large}, state),
    do:
      error(
        state,
        "batch_too_large",
        cat([
          ~L"error: Ask for at most ",
          int(AtMcp.Effects.max_batch()),
          ~L" URIs or actors in one call. Nothing was attempted."
        ]),
        change_any(~L"Split the list and call again with each part.")
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
      change("path"),
      %{path: path}
    )
  end

  def respond({:error, {:media_too_large, bytes}}, state),
    do:
      error(
        state,
        "media_too_large",
        cat([
          ~L"error: an image file may be at most ",
          int(bytes),
          ~L" bytes. Nothing was sent."
        ]),
        change("path")
      )

  def respond({:error, reason}, state) when is_map_key(@account_errors, reason) do
    {message, advice} = Map.fetch!(@account_errors, reason)
    error(state, Atom.to_string(reason), cat([~L"error: ", message]), advice(advice))
  end

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
      ]),
      change("text")
    )
  end

  # A cursor comes back from the caller, so it can come back as anything. This
  # is AtMcp refusing the argument, not the service refusing the read.
  def respond({:error, :invalid_before}, state),
    do:
      error(
        state,
        "invalid_before",
        ~L"error: before must be the AT URI a previous call returned in chain_before. Nothing was read.",
        change("before")
      )

  def respond({:error, :invalid_search_sort}, state),
    do:
      error(
        state,
        "invalid_search_sort",
        ~L"error: sort must be latest or top. Nothing was read.",
        change("sort")
      )

  def respond({:error, :invalid_search_filter}, state),
    do:
      error(
        state,
        "invalid_search_filter",
        ~L"error: author, mentions, since, until and lang must be strings when set. Nothing was read.",
        change_any(~L"Change those arguments and try again.")
      )

  def respond({:error, :write_quota_unavailable}, state),
    do:
      error(
        state,
        "write_quota_unavailable",
        ~L"error: account write quota unavailable; writes are paused until AtMcp recovers it. Nothing was sent.",
        wait(60)
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
        ~L" (not indexed yet, deleted, or hidden by a block), so its CID could not be read. Nothing was sent."
      ]),
      change("cid", ~L"Check the URI, or pass cid (get_record gives it) and try again."),
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
        ~L". Nothing was sent."
      ]),
      change(
        "cid",
        cat([
          ~L"Pass cid ",
          ident(current),
          ~L", or leave cid out to use the AppView's, and try again."
        ])
      ),
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
      change_any(~L"Refer to another record, or check the URI, and try again."),
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
      stop(~L"Trying again will not help unless the thread's author changes the rule."),
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
      change("actor"),
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
      change(path),
      %{problems: [%{path: path, message: message}]}
    )
  end

  def respond({:error, {:write_quota_exhausted, resets_at}}, state) do
    reset = iso8601(resets_at)

    error(
      state,
      "write_quota_exhausted",
      ~L"error: account write quota exhausted. Nothing was sent.",
      later(reset),
      %{resets_at: reset}
    )
  end

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
        ~L" Nothing was applied and nothing was read."
      ]),
      stop(
        ~L"Trying again will return the same result. Tell the account's operator about this error."
      ),
      Map.reject(%{http_status: upstream.status}, fn {_, v} -> is_nil(v) end)
    )
  end

  # An application service refusing or failing a request is an ordinary outcome
  # an agent must be able to act on. Report what it said and whether retrying
  # could help, without publishing the internals of the client library. When
  # the service fails a read, this clause reports an error with no items, so a
  # search that got no answer doesn't look like a search with no matches.
  def respond({:error, %AtMcp.Effects.Failure{kind: kind} = upstream}, state)
      when kind in [:refused, :auth_refused, :indeterminate] do
    status = upstream.status
    detail = upstream_detail(upstream)

    {code, guidance, advice} =
      cond do
        status == 501 ->
          {"upstream_not_implemented",
           ~L"The account's service does not implement this operation.",
           stop(~L"Trying again will not help: the service does not offer it.")}

        status == 429 ->
          {"upstream_rate_limited", ~L"The account's service is rate limiting this client.",
           wait(60)}

        is_integer(status) and status >= 500 ->
          {"upstream_unavailable",
           ~L"The account's service is unavailable. The request was not applied.", wait(30)}

        is_integer(status) and status in 400..499 ->
          {"upstream_rejected", ~L"The account's service rejected this request.",
           change_any(
             ~L"Change the request before trying again, because the same request will be refused again."
           )}

        # A failure with no status: a read that got no answer, or a request
        # refused before it was sent (a write that may have been sent is a
        # write_outcome_unknown, not this).
        kind == :indeterminate ->
          {"upstream_failed",
           ~L"The request to the account's service did not complete, so nothing was changed and no results were read.",
           now()}

        true ->
          {"upstream_rejected", ~L"The request was refused before it was applied.",
           change_any(
             ~L"Change the request before trying again, because the same request will be refused again."
           )}
      end

    error(
      state,
      code,
      cat([~L"error: ", detail, ~L" ", guidance]),
      advice,
      Map.reject(%{http_status: status, upstream_message: upstream.message}, fn {_, v} ->
        is_nil(v)
      end)
    )
  end

  # A reason with no shape of its own. A string is AtMcp refusing an argument
  # in its own words; an atom names a refusal of AtMcp's.
  def respond({:error, reason}, state) when is_binary(reason),
    do:
      error(
        state,
        "invalid_arguments",
        cat([~L"error: ", literal(reason), ~L"."]),
        change_any(~L"Change the arguments and try again.")
      )

  def respond({:error, :invalid_include_replies}, state),
    do:
      error(
        state,
        "invalid_arguments",
        ~L"error: include_replies must be true or false. Nothing was read.",
        change("include_replies")
      )

  # A reason AtMcp did not classify. Writes whose outcome is unknown arrive as
  # `write_outcome_unknown` above, so this is not one; but AtMcp cannot say
  # whether trying again will help.
  def respond({:error, reason}, state),
    do:
      error(
        state,
        "failed",
        cat([~L"error: ", reason_text(reason), ~L"."]),
        %{
          retry: "unknown",
          sentence:
            ~L"AtMcp did not recognize this failure, so it can't say whether trying again will help.",
          fields: %{}
        }
      )

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
  `respond/3` for a page of posts. `fetch` reads the page; it takes the limit
  to ask the service for (`nil` means the caller's limit).

  With `detail: "brief"` the page is shown with `AtMcp.Reading.brief_posts/1`.
  When the text would be longer than `AtMcp.Reading.page_chars/0`, the page is
  read again with the number of posts that fit. The cursor is then the
  service's own and starts with the first post that was dropped, and the page
  says how many were dropped. A post hidden from the page is not counted, so
  the cursor never skips a post, though it may repeat one. If the second read
  fails or does not return fewer posts, the whole first page is returned: a
  page that is too long is better than lost posts. If not even one post fits,
  the page has that one post.
  """
  def page(fetch, args, state, reading) do
    reading = if Map.get(args, :detail) == "brief", do: :brief_posts, else: reading
    started = System.monotonic_time(:millisecond)
    result = fetch.(Map.get(args, :limit))

    # JSON is for programs, which page by count: only the reading is bounded.
    if AtMcp.MCP.DSL.format(args, state) == "json",
      do: respond(result, state, reading),
      else: result |> bounded(fetch, reading, started) |> respond(state, reading)
  end

  @doc """
  Responds to `get_thread`. For a text reading longer than
  `AtMcp.Reading.page_chars/0`, it keeps as many direct replies as fit, in
  the service's order and each with its own replies, adds the rest to the
  post's `replies_omitted`, and sets `replies_cut`. JSON output is not cut.
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
          "replies_omitted" => (data["replies_omitted"] || 0) + count - kept,
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

  # Binary search for the largest n in low..high where fits?.(n) is true.
  # It assumes fits? is true for every n below one where it is true, and
  # returns `low` when fits? is false everywhere.
  defp most(low, high, _fits?) when low >= high, do: low

  defp most(low, high, fits?) do
    mid = div(low + high + 1, 2)
    if fits?.(mid), do: most(mid, high, fits?), else: most(low, mid - 1, fits?)
  end

  # The shorter page comes from a second read, so it is used only when it
  # starts the same way as the first page: the same first posts, in the same
  # order, with a different cursor. A custom feed's generator may ignore
  # `limit`. The AppView then cuts the generator's posts to the limit but
  # passes on the generator's cursor unchanged, and that cursor skips every
  # post between the cut and the cursor. A feed that changed between the two
  # reads, or answers each read differently, gives different posts. In either
  # case the first page is returned whole, with a note that it is longer than
  # the limit. The same happens when the second read would not finish before
  # the endpoint stops waiting.
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
          change("uri"),
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

  # Every error ends with one sentence saying what the agent can do about it,
  # and says the same in `retry` (with `retry_after` or `argument` where it
  # names one), so an agent reading either half of the result can act:
  #
  #   * `now`: trying again now is safe and may succeed;
  #   * `after`: try again later, after `retry_after` when the write quota gave
  #     a time, otherwise after the wait the sentence states;
  #   * `change_argument`: change the arguments and try again, the one named
  #     in `argument` when one caused the error;
  #   * `check_first`: a write's outcome is unknown, so read before retrying;
  #   * `no`: trying again will not help;
  #   * `unknown`: AtMcp did not recognize the failure.
  #
  # The structured result carries the whole text as `message` too: some hosts
  # give the model only the structured half.
  #
  # `message` is a piece; `to_text/1` takes nothing else.
  defp error(state, code, message, %{retry: _} = advice, details \\ %{}) do
    text = to_text(cat([message, ~L" ", advice.sentence]))

    structured =
      %{code: code, message: text, retry: advice.retry}
      |> Map.merge(advice.fields)
      |> Map.merge(details)

    {:ok, Map.put(ExMCP.Server.DSL.Result.error(text), :structuredContent, structured), state}
  end

  @doc false
  # The advice for a refusal made outside this module (`AtMcp.MCP.Input`), as
  # the sentence's text and the structured fields to merge.
  def advice_for({:change, argument}) do
    advice =
      if argument,
        do: change(argument),
        else: change_any(~L"Change the arguments and try again.")

    {to_text(advice.sentence), Map.put(advice.fields, :retry, advice.retry)}
  end

  def advice_for(:check_first) do
    advice = check_first()
    {to_text(advice.sentence), %{retry: advice.retry}}
  end

  defp advice({:stop, sentence}), do: stop(sentence)
  defp advice({:check_first, sentence}), do: check_first(sentence)
  defp advice({:change, argument}), do: change(argument)
  defp advice({:change, argument, sentence}), do: change(argument, sentence)
  defp advice({:change_any, sentence}), do: change_any(sentence)

  defp now(sentence \\ ~L"Trying again now is safe and may succeed."),
    do: %{retry: "now", sentence: sentence, fields: %{}}

  # A wait AtMcp chose, with no time the service gave: the sentence says
  # roughly how long, and no `retry_after` is given, since none is known.
  defp wait(seconds) do
    how_long = if seconds >= 60, do: ~L"about a minute", else: ~L"about half a minute"
    %{retry: "after", sentence: cat([~L"Wait ", how_long, ~L", then try again."]), fields: %{}}
  end

  defp later(at),
    do: %{
      retry: "after",
      sentence: cat([~L"Try again after ", time(at), ~L"."]),
      fields: %{retry_after: at}
    }

  defp change(argument),
    do: change(argument, cat([~L"Change ", ident(argument), ~L" and try again."]))

  defp change(argument, sentence),
    do: %{retry: "change_argument", sentence: sentence, fields: %{argument: argument}}

  # An argument should change, and no one argument can be named.
  defp change_any(sentence), do: %{retry: "change_argument", sentence: sentence, fields: %{}}

  defp check_first(
         sentence \\ ~L"Don't retry until you have read the account's records: the write may have happened."
       ),
       do: %{retry: "check_first", sentence: sentence, fields: %{}}

  defp stop(sentence \\ ~L"Trying again will not help."),
    do: %{retry: "no", sentence: sentence, fields: %{}}

  defp deadline_seconds, do: div(AtMcp.Effects.call_deadline() + 999, 1000)

  # What left a write's outcome unknown, as far as AtMcp knows it.
  defp unknown_cause(:call_deadline_exceeded),
    do:
      cat([
        ~L"the write was sent and no answer came within ",
        int(deadline_seconds()),
        ~L" seconds."
      ])

  defp unknown_cause(:account_runtime_stopped),
    do: ~L"the account's runtime stopped after the write was sent."

  defp unknown_cause(%AtMcp.Effects.Failure{} = failure),
    do: cat([upstream_detail(failure), ~L" The answer doesn't say whether the write was saved."])

  defp unknown_cause(_reason), do: ~L"the answer to the write was lost."

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

  # `encode/1` puts the summary in both halves of a result: the JSON text, and
  # the structured content a client validates against the tool's output
  # schema. `respond/3` swaps the text for `AtMcp.Reading`'s text of the same
  # summary, and `AtMcp.MCP.Output.shape/3` then removes the structured content
  # from a read unless the caller asked for json. Only an object can be
  # structured content.
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
