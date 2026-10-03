defmodule AtMcp.Stream.JetstreamTest do
  use ExUnit.Case, async: false

  alias AtMcp.Stream.Event

  defmodule Client do
    def start_link(opts) do
      send(Application.fetch_env!(:at_mcp, :jetstream_client_observer), {:client_opts, opts})
      Agent.start_link(fn -> opts end)
    end
  end

  setup do
    Application.put_env(:at_mcp, :jetstream_client, Client)
    Application.put_env(:at_mcp, :jetstream_client_observer, self())

    on_exit(fn ->
      Application.delete_env(:at_mcp, :jetstream_client)
      Application.delete_env(:at_mcp, :jetstream_client_observer)
    end)

    :ok
  end

  test "an inbox cannot be a DID filter: the subscription asks for collections only" do
    {:ok, _} =
      AtMcp.Stream.Jetstream.start_link(
        handler: self(),
        collections: ["app.bsky.feed.post"],
        cursor: nil,
        name: nil
      )

    assert_receive {:client_opts, opts}
    # A mention of this account is a commit in somebody else's repository.
    assert opts[:wanted_dids] == []
    assert opts[:wanted_collections] == ["app.bsky.feed.post"]
    assert opts[:handler] == self()
    refute Keyword.has_key?(opts, :cursor)
  end

  test "a resume position is sent only when there is one" do
    for {cursor, expected} <- [{123_456, 123_456}, {0, nil}, {nil, nil}] do
      {:ok, _} =
        AtMcp.Stream.Jetstream.start_link(
          handler: self(),
          collections: ["app.bsky.feed.post"],
          cursor: cursor,
          name: nil
        )

      assert_receive {:client_opts, opts}
      assert opts[:cursor] == expected
    end
  end

  test "its client's messages become AtMcp events, and other messages are left alone" do
    payload = %{
      "kind" => "commit",
      "did" => "did:plc:author",
      "collection" => "app.bsky.feed.post",
      "rkey" => "3l",
      "operation" => "create",
      "time_us" => 1_788_000_000_000_000,
      "record" => %{"text" => "hello"}
    }

    assert {:ok, %Event{kind: :commit, did: "did:plc:author", cursor: 1_788_000_000_000_000}} =
             AtMcp.Stream.Jetstream.decode({:jetstream, payload})

    assert :ignore = AtMcp.Stream.Jetstream.decode(:timeout)
    assert :ignore = AtMcp.Stream.Jetstream.decode({:tcp_closed, :socket})
  end
end
