defmodule AtMcp.LanguageLimitTest do
  use ExUnit.Case, async: false

  defmodule PDS do
    import Plug.Conn
    def init(opts), do: opts

    def call(conn, ledger) do
      Agent.update(ledger, &[conn.request_path | &1])

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(404, ~s({"error":"NotFound"}))
    end
  end

  setup do
    previous = Application.get_env(:at_mcp, :network)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:at_mcp, :network, previous),
        else: Application.delete_env(:at_mcp, :network)
    end)

    ledger = start_supervised!({Agent, fn -> [] end})
    ref = make_ref()

    start_supervised!(
      Plug.Cowboy.child_spec(
        scheme: :http,
        plug: {PDS, ledger},
        options: [port: 0, ip: {127, 0, 0, 1}, ref: ref]
      )
    )

    session = %ProtoRune.Atproto.Session{
      did: "did:plc:fixture",
      handle: "fixture.example",
      access_jwt: "fixture",
      service_url: "http://127.0.0.1:#{:ranch.get_port(ref)}/xrpc"
    }

    quota = AtMcp.Test.QuotaFixture.quota(100)

    effects =
      start_supervised!({AtMcp.Effects, backend_state: session, write_quota: quota})

    %{session: session, effects: effects, ledger: ledger, quota: quota}
  end

  for {network, path} <- [bluesky: "app/bsky", delve: "town/delve"] do
    @network network
    @path path
    test "#{network}: excess languages refuse before preparation requests and quota", ctx do
      Application.put_env(:at_mcp, :network, @network)
      maximum = maximum(@path)
      langs = List.duplicate("en", maximum + 1)

      opts = [
        langs: langs,
        images: [%{data: "fixture", mime_type: "image/png", alt: "image"}],
        quote: "at://did:plc:other/app.bsky.feed.post/quote"
      ]

      assert {:error, %AtMcp.Effects.Failure{kind: :refused}} =
               AtMcp.Effects.ProtoRune.prepare_post(ctx.session, "@someone.example hello", opts)

      assert {:error, %AtMcp.Effects.Failure{kind: :refused, message: message}} =
               AtMcp.Effects.post(ctx.effects, "@someone.example hello", opts)

      assert message =~ "#{maximum} language"
      assert message =~ "No post was sent"

      assert {:error, %AtMcp.Effects.Failure{kind: :refused}} =
               AtMcp.Effects.reply(
                 ctx.effects,
                 "at://did:plc:other/app.bsky.feed.post/parent",
                 "reply",
                 opts
               )

      assert Agent.get(ctx.ledger, & &1) == []
      assert AtMcp.WriteQuota.status(ctx.quota, ctx.session.did).used == 0
    end

    test "#{network}: allowed and omitted language arrays are preserved", ctx do
      Application.put_env(:at_mcp, :network, @network)

      for langs <- [[], ["fr", "en"], List.duplicate("en", maximum(@path))] do
        assert {:ok, %{record: record}} =
                 AtMcp.Effects.ProtoRune.prepare_post(ctx.session, "hello #tag", langs: langs)

        assert record["langs"] == langs
        assert record["text"] == "hello #tag"
        assert record["facets"] != []
        assert record["$type"] == AtMcp.Network.collection(:post)
      end

      assert {:ok, %{record: record}} =
               AtMcp.Effects.ProtoRune.prepare_post(ctx.session, "hello", [])

      refute Map.has_key?(record, "langs")
      assert Agent.get(ctx.ledger, & &1) == []
    end
  end

  defp maximum(path) do
    lexicon =
      Path.join(["priv/lexicons", path, "feed/post.json"]) |> File.read!() |> Jason.decode!()

    get_in(lexicon, ["defs", "main", "record", "properties", "langs", "maxLength"])
  end
end
