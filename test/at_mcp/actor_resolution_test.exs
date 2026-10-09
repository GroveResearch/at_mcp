defmodule AtMcp.ActorResolutionTest do
  @moduledoc """
  A follow or a block names its subject by handle, and the record needs the
  subject's DID. Resolving the handle is a read that happens before any write
  is sent, so when it fails AtMcp knows the write did not happen: the result is
  a refusal that costs no write quota, never an unknown outcome that tells the
  agent the action may have completed.

  Models write handles the way people do, with a leading `@`. Every tool that
  takes a handle accepts that form.
  """
  use ExUnit.Case, async: false

  defmodule PDS do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      conn = fetch_query_params(conn)
      {:ok, raw, conn} = read_body(conn)
      body = if raw == "", do: nil, else: Jason.decode!(raw)
      "/xrpc/" <> method = conn.request_path

      Agent.update(
        opts[:calls],
        &(&1 ++
            [
              %{
                method: method,
                query: conn.query_params,
                raw: conn.query_string <> raw,
                body: body
              }
            ])
      )

      {status, response} = response(method, conn, opts[:resolve])

      conn
      |> put_resp_content_type("application/json")
      # A rate limit says when to come back; now, so the client's retries
      # finish quickly.
      |> put_resp_header("retry-after", "0")
      |> send_resp(status, Jason.encode!(response))
    end

    defp response("com.atproto.identity.resolveHandle", conn, resolve) do
      case {resolve, conn.query_params["handle"]} do
        {:down, _} ->
          {500, %{error: "InternalServerError", message: "upstream is down"}}

        {_, "alice.example"} ->
          {200, %{did: "did:plc:alice"}}

        # The lexicon's declared error for a handle no account holds.
        {_, "gone.example"} ->
          {400, %{error: "HandleNotFound", message: "Unable to resolve handle"}}

        {_, "limited.example"} ->
          {429, %{error: "RateLimitExceeded", message: "Rate Limit Exceeded"}}

        {_, "forbidden.example"} ->
          {403, %{error: "Forbidden", message: "not for you"}}

        {_, "odd.example"} ->
          {200, %{did: "not-a-did"}}

        # What the reference PDS answers for a handle it cannot resolve.
        {_, _} ->
          {400, %{error: "InvalidRequest", message: "Unable to resolve handle"}}
      end
    end

    defp response("com.atproto.repo.createRecord", _conn, _resolve),
      do: {200, %{uri: "at://did:plc:self/town.delve.graph.follow/new", cid: "bafyreinew"}}

    # Plug's decoded query map keeps one value of a repeated key. The raw query
    # string is where every `others` entry is visible. `did:plc:short` is
    # dropped so a short page can be told from one entry per account asked about.
    defp response(method, conn, _resolve) do
      if String.ends_with?(method, "graph.getRelationships") do
        others =
          conn.query_string
          |> repeated("others")
          |> Enum.reject(&(&1 == "did:plc:short"))

        {200,
         %{
           relationships:
             Enum.map(others, fn other ->
               %{did: other, following: nil, followedBy: nil, notFound: false}
             end)
         }}
      else
        {200, %{}}
      end
    end

    defp repeated(query, key) do
      query
      |> String.split("&")
      |> Enum.flat_map(fn pair ->
        case String.split(pair, "=", parts: 2) do
          [^key, value] -> [URI.decode_www_form(value)]
          _ -> []
        end
      end)
    end
  end

  defp start(resolve \\ :ok) do
    calls = start_supervised!({Agent, fn -> [] end}, id: make_ref())
    ref = :"actor_resolution_#{System.unique_integer([:positive])}"

    start_supervised!(
      Plug.Cowboy.child_spec(
        scheme: :http,
        plug: {PDS, calls: calls, resolve: resolve},
        options: [port: 0, ip: {127, 0, 0, 1}, ref: ref]
      )
    )

    session = %ProtoRune.Atproto.Session{
      access_jwt: "access",
      refresh_jwt: "refresh",
      did: "did:plc:self",
      handle: "self.example",
      service_url: "http://127.0.0.1:#{:ranch.get_port(ref)}/xrpc"
    }

    {:ok, effects} =
      AtMcp.Test.QuotaFixture.start_effects(
        backend: AtMcp.Effects.ProtoRune,
        backend_state: session,
        quota_limit: 10
      )

    %{calls: calls, effects: effects, state: %{effects: effects}}
  end

  defp sent(calls, method), do: calls |> Agent.get(& &1) |> Enum.filter(&(&1.method == method))

  defp text(result), do: Enum.find(result.content, &(&1.type == "text")).text

  # Plug keeps one value for a repeated key. The raw query string is the only
  # place every `others` value is visible.
  defp repeated(raw, key) do
    raw
    |> String.split("&")
    |> Enum.flat_map(fn pair ->
      case String.split(pair, "=", parts: 2) do
        [^key, value] -> [URI.decode_www_form(value)]
        _ -> []
      end
    end)
  end

  # Each write that names its subject, with (the end of) the method of the
  # request that carries the subject, and where the subject sits in it.
  @subject_writes [
    {"follow", "com.atproto.repo.createRecord", ["record", "subject"]},
    {"block", "com.atproto.repo.createRecord", ["record", "subject"]},
    {"mute", ".graph.muteActor", ["actor"]},
    {"unmute", ".graph.unmuteActor", ["actor"]}
  ]

  # A mute's method is in the configured network's namespace; the suffix names it.
  defp writes(calls, method),
    do: calls |> Agent.get(& &1) |> Enum.filter(&String.ends_with?(&1.method, method))

  defp refused_at_no_cost(tool, method, actor) do
    %{calls: calls, effects: effects, state: state} = start()
    used = AtMcp.Effects.quota_status(effects).used

    assert {:ok, result, ^state} =
             AtMcp.MCP.Server.handle_call_tool(tool, %{"actor" => actor}, state)

    assert result[:isError]
    assert AtMcp.Effects.quota_status(effects).used == used
    assert writes(calls, method) == []
    refute Map.has_key?(result.structuredContent, :outcome)
    refute text(result) =~ "may have completed"
    {result, calls}
  end

  for {tool, method, path} <- @subject_writes do
    test "#{tool} of a handle the service cannot resolve is refused, sends nothing and costs no write" do
      for handle <- ["nobody.example", "gone.example"] do
        {result, _calls} = refused_at_no_cost(unquote(tool), unquote(method), handle)

        assert result.structuredContent.code == "handle_not_resolved"
        assert result.structuredContent.handle == handle

        assert text(result) =~
                 "Nothing was sent: the account's service could not resolve the handle #{handle}."
      end
    end

    test "#{tool} of something that is not a handle is refused without asking the service" do
      {result, calls} = refused_at_no_cost(unquote(tool), unquote(method), "not a handle")

      assert result.structuredContent.code == "handle_not_resolved"
      assert Agent.get(calls, & &1) == []
    end

    test "#{tool} of @handle resolves the handle and sends the DID" do
      %{calls: calls, effects: effects, state: state} = start()
      used = AtMcp.Effects.quota_status(effects).used

      assert {:ok, result, ^state} =
               AtMcp.MCP.Server.handle_call_tool(
                 unquote(tool),
                 %{"actor" => "@alice.example"},
                 state
               )

      refute result[:isError]
      assert AtMcp.Effects.quota_status(effects).used == used

      assert [%{query: %{"handle" => "alice.example"}}] =
               sent(calls, "com.atproto.identity.resolveHandle")

      assert [write] = writes(calls, unquote(method))
      assert get_in(write.body, unquote(path)) == "did:plc:alice"
    end
  end

  # A rate limit or a refusal of the read is not an answer about the handle.
  # Telling an agent the handle is wrong would send it to change the handle
  # when it should wait, or report the refusal.
  test "a rate-limited resolution keeps its own kind and costs no write" do
    {result, _calls} =
      refused_at_no_cost("follow", "com.atproto.repo.createRecord", "limited.example")

    assert result.structuredContent.code == "upstream_rate_limited"
    assert result.structuredContent.http_status == 429
  end

  test "a forbidden resolution keeps its own kind and costs no write" do
    {result, _calls} =
      refused_at_no_cost("block", "com.atproto.repo.createRecord", "forbidden.example")

    assert result.structuredContent.code == "upstream_rejected"
    assert result.structuredContent.http_status == 403
  end

  test "a resolution that answers something other than a DID is never written" do
    {result, _calls} =
      refused_at_no_cost("follow", "com.atproto.repo.createRecord", "odd.example")

    assert result.structuredContent.code == "response_unreadable"
  end

  test "a service that fails resolving a handle is not an unknown write outcome" do
    %{calls: calls, effects: effects, state: state} = start(:down)
    used = AtMcp.Effects.quota_status(effects).used

    assert {:ok, result, ^state} =
             AtMcp.MCP.Server.handle_call_tool("follow", %{"actor" => "alice.example"}, state)

    # The handle may be fine; the service is not. The failure keeps its kind and
    # status, and since no write was sent it is not an unknown outcome.
    assert result.structuredContent.code == "upstream_unavailable"
    refute text(result) =~ "may have completed"
    assert AtMcp.Effects.quota_status(effects).used == used
    assert sent(calls, "com.atproto.repo.createRecord") == []
  end

  # The AppView resolves `actor` and then looks `others` up by DID. A handle in
  # `others` has to be resolved here, or the service reports an account that
  # exists as not found.
  test "get_relationships resolves a handle in others and asks about the DID" do
    %{calls: calls, state: state} = start()

    assert {:ok, result, ^state} =
             AtMcp.MCP.Server.handle_call_tool(
               "get_relationships",
               %{"actor" => "carol.example", "others" => ["@alice.example", "did:plc:bob"]},
               state
             )

    refute result[:isError]

    assert [%{query: %{"handle" => "alice.example"}}] =
             sent(calls, "com.atproto.identity.resolveHandle")

    assert [request] = writes(calls, "graph.getRelationships")
    assert request.query["actor"] == "carol.example"
    assert repeated(request.raw, "others") == ["did:plc:alice", "did:plc:bob"]

    assert result.structuredContent["count"] == 2

    assert Enum.map(result.structuredContent["items"], & &1["did"]) ==
             ["did:plc:alice", "did:plc:bob"]

    assert Enum.map(result.structuredContent["items"], & &1["not_found"]) == [false, false]
  end

  test "a handle in others the service cannot resolve is not_found beside the accounts it can" do
    %{calls: calls, state: state} = start()

    assert {:ok, result, ^state} =
             AtMcp.MCP.Server.handle_call_tool(
               "get_relationships",
               %{"actor" => "carol.example", "others" => ["gone.example", "did:plc:bob"]},
               state
             )

    refute result[:isError]
    assert [missing, found] = result.structuredContent["items"]
    assert missing["not_found"]
    assert missing["did"] == "gone.example"
    assert missing["following"] == nil
    assert missing["followed_by"] == nil
    assert found["did"] == "did:plc:bob"
    refute found["not_found"]

    assert [request] = writes(calls, "graph.getRelationships")
    assert repeated(request.raw, "others") == ["did:plc:bob"]
  end

  test "get_relationships of only unresolved handles is not_found and asks for no relationships" do
    %{calls: calls, state: state} = start()

    assert {:ok, result, ^state} =
             AtMcp.MCP.Server.handle_call_tool(
               "get_relationships",
               %{
                 "actor" => "carol.example",
                 "others" => ["gone.example", "nobody.example"]
               },
               state
             )

    refute result[:isError]

    assert Enum.map(result.structuredContent["items"], & &1["did"]) ==
             ["gone.example", "nobody.example"]

    assert Enum.all?(result.structuredContent["items"], & &1["not_found"])
    assert writes(calls, "graph.getRelationships") == []
  end

  test "a service that fails resolving a handle in others is not a missing account" do
    %{calls: calls, state: state} = start(:down)

    assert {:ok, result, ^state} =
             AtMcp.MCP.Server.handle_call_tool(
               "get_relationships",
               %{"actor" => "carol.example", "others" => ["alice.example"]},
               state
             )

    # The handle may be fine; the service is not. Reporting it not_found would
    # send an agent to change the handle when it should wait.
    assert result[:isError]
    assert result.structuredContent.code == "upstream_unavailable"
    refute text(result) =~ "not_found"
    assert writes(calls, "graph.getRelationships") == []
  end

  test "a relationships answer shorter than the accounts asked about is unreadable" do
    %{state: state} = start()

    assert {:ok, result, ^state} =
             AtMcp.MCP.Server.handle_call_tool(
               "get_relationships",
               %{"actor" => "carol.example", "others" => ["did:plc:bob", "did:plc:short"]},
               state
             )

    assert result[:isError]
    assert result.structuredContent.code == "response_unreadable"
  end

  test "a DID is used as given, without a resolution read" do
    %{calls: calls, state: state} = start()

    assert {:ok, result, ^state} =
             AtMcp.MCP.Server.handle_call_tool("follow", %{"actor" => "did:plc:bob"}, state)

    refute result[:isError]
    assert sent(calls, "com.atproto.identity.resolveHandle") == []
    assert [write] = sent(calls, "com.atproto.repo.createRecord")
    assert write.body["record"]["subject"] == "did:plc:bob"
  end

  # Every tool that takes a handle, named one by one: one left out is exactly
  # the defect a spot check of `follow` would not find.
  @handle_tools [
    {"get_author_feed", %{"actor" => "@alice.example"}},
    {"get_profile", %{"actor" => "@alice.example"}},
    {"get_profiles", %{"actors" => ["@alice.example", "@bob.example"]}},
    {"get_followers", %{"actor" => "@alice.example"}},
    {"get_follows", %{"actor" => "@alice.example"}},
    {"get_known_followers", %{"actor" => "@alice.example"}},
    {"get_suggested_follows", %{"actor" => "@alice.example"}},
    {"get_relationships", %{"actor" => "@alice.example", "others" => ["@bob.example"]}},
    {"get_actor_likes", %{"actor" => "@alice.example"}},
    {"search_posts",
     %{"query" => "hello", "author" => "@alice.example", "mentions" => "@bob.example"}},
    {"mute", %{"actor" => "@alice.example"}},
    {"unmute", %{"actor" => "@alice.example"}}
  ]

  test "every tool that takes a handle sends it without the leading @" do
    %{calls: calls, state: state} = start()

    for {tool, args} <- @handle_tools do
      Agent.update(calls, fn _ -> [] end)
      assert {:ok, _result, ^state} = AtMcp.MCP.Server.handle_call_tool(tool, args, state)

      requests = Agent.get(calls, & &1)
      assert requests != [], "#{tool} sent nothing"

      for request <- requests do
        refute request.raw =~ "%40", "#{tool} sent #{request.raw}"
        refute request.raw =~ "@", "#{tool} sent #{request.raw}"
      end
    end
  end

  test "the tool list names every tool that takes a handle" do
    {:ok, tools, nil, :state} = AtMcp.MCP.Server.handle_list_tools(nil, :state)

    takes_handle =
      for tool <- tools,
          properties = tool.inputSchema[:properties] || %{},
          Enum.any?(
            Map.keys(properties),
            &(to_string(&1) in ["actor", "actors", "others", "author", "mentions"])
          ),
          do: to_string(tool.name)

    assert Enum.sort(takes_handle) ==
             Enum.sort(["follow", "block" | Enum.map(@handle_tools, &elem(&1, 0))])
  end
end
