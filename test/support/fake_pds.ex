defmodule AtMcp.Test.FakePDS do
  @moduledoc """
  A PDS on localhost that keeps records and records every request, for tests
  that check the bytes `AtMcp.Effects.ProtoRune` sends.

  `start/1` takes the records the repository holds, as
  `%{"at://repo/collection/rkey" => value}`, and `answers`, a map from an XRPC
  method to `{status, body}` that replaces the default answer. `getRecord`
  answers from the records, and 400 `RecordNotFound` for one it does not hold.
  Records are kept under DID-form addresses; `getRecord` named by a handle in
  `handles` (`%{handle => did}`, the session's own handle included) answers
  with the DID-form uri, as a real PDS does, and `resolveHandle` resolves them.
  `listRecords` answers one page of a collection's, by DID-form uri.
  `createRecord`, `putRecord`, `deleteRecord` and `applyWrites` change them, so a
  test can read back what a write left. Any other method answers `{}`.
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
             answers: Keyword.get(opts, :answers, %{})
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

  @doc "Every request with this method, oldest first: `%{method, query, body}`."
  def sent(state, method),
    do: state |> Agent.get(& &1.calls) |> Enum.filter(&(&1.method == method))

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
    call = %{method: method, query: conn.query_params, body: body}
    Agent.update(state, &%{&1 | calls: &1.calls ++ [call]})

    {status, answer} =
      case Agent.get(state, &Map.fetch(&1.answers, method)) do
        {:ok, answer} -> answer
        :error -> Agent.get_and_update(state, &answer(method, call, &1))
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

  defp answer("com.atproto.repo.putRecord", %{body: b}, state) do
    uri = "at://#{b["repo"]}/#{b["collection"]}/#{b["rkey"]}"
    {{200, %{uri: uri, cid: cid(uri)}}, put_in(state.records[uri], b["record"])}
  end

  defp answer("com.atproto.repo.deleteRecord", %{body: b}, state) do
    uri = "at://#{b["repo"]}/#{b["collection"]}/#{b["rkey"]}"
    {{200, %{}}, %{state | records: Map.delete(state.records, uri)}}
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

    {{200, %{results: results}}, %{state | records: records}}
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

  defp answer("com.atproto.identity.resolveHandle", %{query: %{"handle" => handle}}, state) do
    case Map.fetch(state.handles, handle) do
      {:ok, did} -> {{200, %{did: did}}, state}
      :error -> {{400, %{error: "InvalidRequest", message: "Unable to resolve handle"}}, state}
    end
  end

  defp answer(_method, _call, state), do: {{200, %{}}, state}

  @doc "The CID the PDS gives the record at `uri`."
  def cid(uri),
    do: "bafy" <> Base.encode32(:crypto.hash(:sha256, uri), case: :lower, padding: false)
end
