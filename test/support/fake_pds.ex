defmodule AtMcp.Test.FakePDS do
  @moduledoc """
  A PDS on localhost that keeps records and records every request, for tests
  that check the bytes `AtMcp.Effects.ProtoRune` sends.

  `start/1` takes the records the repository holds, as
  `%{"at://repo/collection/rkey" => value}`, and `answers`, a map from an XRPC
  method to `{status, body}` that replaces the default answer, or to a list of
  them answered in turn, the last one repeating. `getRecord`
  answers from the records, and 400 `RecordNotFound` for one it does not hold.
  Records are kept under DID-form addresses; `getRecord` named by a handle in
  `handles` (`%{handle => did}`, the session's own handle included) answers
  with the DID-form uri, as a real PDS does, and `resolveHandle` resolves them.
  `listRecords` answers one page of a collection's, by DID-form uri.
  `createRecord`, `putRecord`, `deleteRecord` and `applyWrites` change them, so a
  test can read back what a write left. `getLatestCommit` answers a commit that
  any change to the records moves, and `applyWrites` with a `swapCommit` that
  is not it answers 400 `InvalidSwap`. `uploadBlob` answers a blob reference
  for the bytes it was sent. `drafts` is the account's drafts, as
  `getDrafts` lists them (`%{id, draft, ...}`); `createDraft`, `updateDraft` and
  `deleteDraft` change them, and an update to an id it does not hold is ignored
  and answered `{}`, as the lexicon says. With `drafts_lag: true` an update is
  accepted and not applied yet, as a service that queues it does. Any other
  method answers `{}`. `preferences` is the account's preferences, which
  `getPreferences` answers and `putPreferences` replaces.
  `notification_preferences` is the account's notification settings by
  reason, which `notification.getPreferences` answers with the service's
  defaults for the rest and `putPreferencesV2` changes reason by reason;
  `putActivitySubscription` keeps subscriptions (`subscriptions/1`). A `putRecord` whose
  `swapRecord` is not the record's CID, or is null where a record exists,
  answers 400 `InvalidSwap`. An answer given as a list is taken one per call, the
  last staying; `:default` in it stands for the PDS's own answer.
  """
  import Plug.Conn

  @doc "Start the PDS under the test's supervisor; returns a session for it and its state."
  def start(opts \\ []) do
    state =
      ExUnit.Callbacks.start_supervised!(
        {Agent,
         fn ->
           %{
             calls: [],
             records: Keyword.get(opts, :records, %{}),
             handles:
               Map.merge(%{"self.example" => "did:plc:self"}, Keyword.get(opts, :handles, %{})),
             answers: Keyword.get(opts, :answers, %{}),
             drafts: Keyword.get(opts, :drafts, []),
             preferences: Keyword.get(opts, :preferences, []),
             notification_preferences: Keyword.get(opts, :notification_preferences, %{}),
             subscriptions: %{},
             drafts_lag: Keyword.get(opts, :drafts_lag, false)
           }
         end},
        id: make_ref()
      )

    ref = :"fake_pds_#{System.unique_integer([:positive])}"

    ExUnit.Callbacks.start_supervised!(
      Plug.Cowboy.child_spec(
        scheme: :http,
        plug: {__MODULE__, state: state},
        options: [port: 0, ip: {127, 0, 0, 1}, ref: ref]
      ),
      id: ref
    )

    session = %ProtoRune.Atproto.Session{
      access_jwt: "access",
      refresh_jwt: "refresh",
      did: "did:plc:self",
      handle: "self.example",
      service_url: "http://127.0.0.1:#{:ranch.get_port(ref)}/xrpc"
    }

    {session, state}
  end

  @doc """
  Every request with this method, oldest first: `%{method, query, raw, body,
  proxy, labelers}`. `query` keeps one value of a repeated key; `raw` is the
  query string as sent; `proxy` is the `atproto-proxy` header and `labelers`
  the `atproto-accept-labelers` header, if any.
  """
  def sent(state, method),
    do: state |> Agent.get(& &1.calls) |> Enum.filter(&(&1.method == method))

  @doc "The account's preferences, as the PDS now holds them."
  def preferences(state), do: Agent.get(state, & &1.preferences)

  @doc "Every method called, in order."
  def methods(state), do: state |> Agent.get(& &1.calls) |> Enum.map(& &1.method)

  @doc "The record at an AT URI, as the PDS now holds it."
  def record(state, uri), do: Agent.get(state, &Map.get(&1.records, uri))

  def init(opts), do: opts

  def call(conn, opts) do
    state = opts[:state]
    conn = fetch_query_params(conn)
    {:ok, raw, conn} = read_body(conn)

    body =
      case get_req_header(conn, "content-type") do
        ["image/" <> _] -> raw
        _ -> if raw == "", do: nil, else: Jason.decode!(raw)
      end

    "/xrpc/" <> method = conn.request_path

    call = %{
      method: method,
      query: conn.query_params,
      raw: conn.query_string,
      body: body,
      proxy: conn |> get_req_header("atproto-proxy") |> List.first(),
      labelers: conn |> get_req_header("atproto-accept-labelers") |> List.first()
    }

    Agent.update(state, &%{&1 | calls: &1.calls ++ [call]})

    {status, answer} =
      case Agent.get(state, &Map.fetch(&1.answers, method)) do
        {:ok, [answer]} ->
          answer

        {:ok, [:default | rest]} ->
          Agent.update(state, &put_in(&1.answers[method], rest))
          Agent.get_and_update(state, &answer(method, call, &1))

        {:ok, [answer | rest]} ->
          Agent.update(state, &put_in(&1.answers[method], rest))
          answer

        {:ok, answer} ->
          answer

        :error ->
          Agent.get_and_update(state, &answer(method, call, &1))
      end

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(answer))
  end

  defp answer("com.atproto.repo.getRecord", %{query: q}, state) do
    repo = Map.get(state.handles, q["repo"], q["repo"])
    uri = "at://#{repo}/#{q["collection"]}/#{q["rkey"]}"

    case Map.fetch(state.records, uri) do
      {:ok, value} ->
        {{200, %{uri: uri, cid: cid(uri), value: value}}, state}

      :error ->
        {{400, %{error: "RecordNotFound", message: "Could not locate record: #{uri}"}}, state}
    end
  end

  defp answer("com.atproto.repo.createRecord", %{body: b}, state) do
    uri = "at://#{b["repo"]}/#{b["collection"]}/#{b["rkey"] || "new"}"
    {{200, %{uri: uri, cid: cid(uri)}}, put_in(state.records[uri], b["record"])}
  end

  # A `swapRecord` names the version the write must replace; the PDS refuses
  # one that is not the record's current CID.
  defp answer("com.atproto.repo.putRecord", %{body: b}, state) do
    uri = "at://#{b["repo"]}/#{b["collection"]}/#{b["rkey"]}"

    # A null swap says there must be no record yet, as the reference PDS
    # reads it.
    if (is_binary(b["swapRecord"]) and
          (not Map.has_key?(state.records, uri) or b["swapRecord"] != cid(uri))) or
         (Map.has_key?(b, "swapRecord") and is_nil(b["swapRecord"]) and
            Map.has_key?(state.records, uri)) do
      {{400, %{error: "InvalidSwap", message: "Record was at another version"}}, state}
    else
      {{200, %{uri: uri, cid: cid(uri)}}, put_in(state.records[uri], b["record"])}
    end
  end

  defp answer("com.atproto.repo.deleteRecord", %{body: b}, state) do
    uri = "at://#{b["repo"]}/#{b["collection"]}/#{b["rkey"]}"
    {{200, %{}}, %{state | records: Map.delete(state.records, uri)}}
  end

  # The repository's commit is a digest of its records, so any write moves it.
  defp answer("com.atproto.sync.getLatestCommit", _call, state),
    do: {{200, %{cid: commit(state), rev: "rev"}}, state}

  defp answer("com.atproto.repo.applyWrites", %{body: %{"swapCommit" => swap} = call_body}, state)
       when is_binary(swap) do
    if swap == commit(state),
      do:
        answer(
          "com.atproto.repo.applyWrites",
          %{body: Map.delete(call_body, "swapCommit")},
          state
        ),
      else: {{400, %{error: "InvalidSwap", message: "Commit was at #{commit(state)}"}}, state}
  end

  defp answer("com.atproto.repo.applyWrites", %{body: b}, state) do
    {results, records} =
      Enum.map_reduce(b["writes"], state.records, fn write, records ->
        uri = "at://#{b["repo"]}/#{write["collection"]}/#{write["rkey"]}"

        case write["$type"] do
          "com.atproto.repo.applyWrites#delete" ->
            {%{"$type" => "com.atproto.repo.applyWrites#deleteResult"}, Map.delete(records, uri)}

          type ->
            result = type <> "Result"
            {%{"$type" => result, uri: uri, cid: cid(uri)}, Map.put(records, uri, write["value"])}
        end
      end)

    state = %{state | records: records}
    {{200, %{results: results, commit: %{cid: commit(state), rev: "rev"}}}, state}
  end

  defp answer("com.atproto.repo.listRecords", %{query: q}, state) do
    prefix = "at://#{Map.get(state.handles, q["repo"], q["repo"])}/#{q["collection"]}/"

    # One page of `limit` (default 50) after the uri `cursor` names.
    limit = String.to_integer(q["limit"] || "50")

    all =
      for {uri, value} <- Enum.sort(state.records),
          String.starts_with?(uri, prefix),
          q["cursor"] in [nil, ""] or uri > q["cursor"],
          do: %{uri: uri, cid: cid(uri), value: value}

    {page, rest} = Enum.split(all, limit)
    cursor = if rest != [], do: List.last(page).uri

    {{200, Map.reject(%{records: page, cursor: cursor}, fn {_, v} -> is_nil(v) end)}, state}
  end

  defp answer("com.atproto.repo.uploadBlob", %{body: bytes}, state) do
    blob = %{
      "$type" => "blob",
      "ref" => %{"$link" => cid(bytes)},
      "mimeType" => "image/png",
      "size" => byte_size(bytes)
    }

    {{200, %{blob: blob}}, state}
  end

  defp answer("com.atproto.identity.resolveHandle", %{query: %{"handle" => handle}}, state) do
    case Map.fetch(state.handles, handle) do
      {:ok, did} -> {{200, %{did: did}}, state}
      :error -> {{400, %{error: "InvalidRequest", message: "Unable to resolve handle"}}, state}
    end
  end

  defp answer(method, call, state) do
    cond do
      method == "town.delve.identity.getState" ->
        {{200, %{activated: false}}, state}

      String.ends_with?(method, ".actor.getPreferences") ->
        {{200, %{preferences: state.preferences}}, state}

      String.ends_with?(method, ".actor.putPreferences") ->
        {{200, %{}}, %{state | preferences: call.body["preferences"]}}

      String.ends_with?(method, ".notification.getPreferences") ->
        {{200, %{preferences: notification_preferences(state)}}, state}

      String.ends_with?(method, ".notification.putPreferencesV2") ->
        state = %{
          state
          | notification_preferences: Map.merge(state.notification_preferences, call.body)
        }

        {{200, %{preferences: notification_preferences(state)}}, state}

      String.ends_with?(method, ".notification.putActivitySubscription") ->
        %{"subject" => subject, "activitySubscription" => subscription} = call.body
        enabled? = subscription["post"] == true or subscription["reply"] == true

        subscriptions =
          if enabled?,
            do: Map.put(state.subscriptions, subject, subscription),
            else: Map.delete(state.subscriptions, subject)

        answer =
          if enabled?,
            do: %{subject: subject, activitySubscription: subscription},
            else: %{subject: subject}

        {{200, answer}, %{state | subscriptions: subscriptions}}

      true ->
        other(method, call, state)
    end
  end

  defp other(method, call, state) do
    case String.split(method, ".draft.") do
      [_namespace, op] -> draft(op, call, state)
      _ -> {{200, %{}}, state}
    end
  end

  defp draft("getDrafts", _call, state), do: {{200, %{drafts: state.drafts}}, state}

  defp draft("createDraft", %{body: b}, state) do
    id = "3draft#{length(state.drafts) + 1}"
    {{200, %{id: id}}, %{state | drafts: state.drafts ++ [%{id: id, draft: b["draft"]}]}}
  end

  defp draft("updateDraft", _call, %{drafts_lag: true} = state), do: {{200, %{}}, state}

  defp draft("updateDraft", %{body: %{"draft" => %{"id" => id, "draft" => draft}}}, state) do
    drafts = Enum.map(state.drafts, &if(&1.id == id, do: %{&1 | draft: draft}, else: &1))
    {{200, %{}}, %{state | drafts: drafts}}
  end

  defp draft("deleteDraft", %{body: %{"id" => id}}, state),
    do: {{200, %{}}, %{state | drafts: Enum.reject(state.drafts, &(&1.id == id))}}

  defp draft(_op, _call, state), do: {{200, %{}}, state}

  # Every reason's setting, the service's defaults where none was set, as the
  # AppView answers (`ensurePreferences` in its notification/util.ts).
  defp notification_preferences(state) do
    filterable = %{"include" => "all", "list" => true, "push" => true}
    plain = %{"list" => true, "push" => true}

    defaults =
      Map.merge(
        Map.new(
          ~w(follow like likeViaRepost mention quote reply repost repostViaRepost),
          &{&1, filterable}
        ),
        Map.new(~w(starterpackJoined subscribedPost unverified verified), &{&1, plain})
      )
      |> Map.put("chat", %{"include" => "all", "push" => true})

    Map.merge(defaults, state.notification_preferences)
  end

  @doc "The accounts subscribed to, by DID, with what the subscription asks for."
  def subscriptions(state), do: Agent.get(state, & &1.subscriptions)

  @doc "The repository's current commit CID: a digest of every record it holds."
  def commit(%{records: records}),
    do: cid(:erlang.term_to_binary(records |> Map.to_list() |> Enum.sort()))

  @doc "The CID the PDS gives the record at `uri`, or the blob of these bytes."
  def cid(source),
    do: "bafy" <> Base.encode32(:crypto.hash(:sha256, source), case: :lower, padding: false)
end
