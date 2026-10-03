defmodule AtMcp.PostPerceptionTest do
  use ExUnit.Case, async: false
  alias AtMcp.{Network, Summary}
  @fixture Path.expand("../fixtures/fieldnote-post.json", __DIR__)

  setup do
    old = Application.get_env(:at_mcp, :network)
    Application.put_env(:at_mcp, :network, :delve)

    on_exit(fn ->
      if old,
        do: Application.put_env(:at_mcp, :network, old),
        else: Application.delete_env(:at_mcp, :network)
    end)

    %{post: Jason.decode!(File.read!(@fixture))}
  end

  test "real shortened link and hydrated quote survive every shared projection", %{post: post} do
    for shape <- [:post, :chain_post, :notification] do
      p = Summary.extract(shape, post)
      assert p.raw_text == post["record"]["text"]
      assert p.text =~ "<https://delve.town/profile/fieldnote.delve.town/post/3mwsmr4x3nk2m>"
      assert p.quote.status == "available"
      assert p.quote.author == "fieldnote.delve.town"
      assert p.quote.author_did == post["embed"]["record"]["author"]["did"]
      assert p.quote.text =~ "I can take a public verification role"
      refute p.text =~ "I can take a public verification role"
      assert p.web_url =~ "https://delve.town/profile/"
      assert p.quote.web_url =~ "/post/3mwsmr4x3nk2m"
      assert Map.has_key?(Summary.properties(shape), "quote")
      assert Map.has_key?(Summary.properties(shape), "facets")

      assert AtMcp.Test.Schema.valid?(Jason.decode!(Jason.encode!(p)), %{
               "type" => "object",
               "properties" => Summary.properties(shape)
             })
    end
  end

  test "raw notification references are unhydrated, not missing", %{post: post} do
    p = Summary.extract(:notification, Map.delete(post, "embed"))
    assert p.quote.status == "unhydrated"
    assert p.quote.uri == post["record"]["embed"]["record"]["uri"]
    assert p.quote.text == nil
  end

  test "quote availability comes from each explicit view discriminant", %{post: post} do
    for {kind, status} <- [
          {"viewNotFound", "not_found"},
          {"viewBlocked", "blocked"},
          {"viewDetached", "detached"}
        ] do
      source =
        put_in(post, ["embed", "record"], %{
          "$type" => Network.type(:embed_record) <> "#" <> kind,
          "uri" => post["uri"]
        })

      p = Summary.extract(:post, source)
      assert p.quote.status == status
      assert p.quote.text == nil
    end

    source = put_in(post, ["embed", "record", "value", "$type"], Network.collection(:generator))
    assert Summary.extract(:post, source).quote.status == "unsupported"
  end

  test "recordWithMedia keeps distinct quoted and quoting images and stops at next quote", %{
    post: post
  } do
    view = post["embed"]
    nested = post["record"]["embed"]

    quoted =
      view["record"]
      |> put_in(["value", "embed"], nested)
      |> Map.put("embeds", [
        %{"images" => [%{"alt" => "quoted", "fullsize" => "https://cdn.example/q"}]}
      ])

    source =
      Map.put(post, "embed", %{
        "$type" => Network.type(:embed_record_with_media) <> "#view",
        "record" => Map.put(view, "record", quoted),
        "media" => %{"images" => [%{"alt" => "outer", "fullsize" => "https://cdn.example/o"}]}
      })

    p = Summary.extract(:chain_post, source)
    assert [%{alt: "outer", availability: "available"}] = p.images
    assert [%{alt: "quoted"}] = p.quote.images
    assert p.quote.nested_uri == nested["record"]["uri"]
    refute Map.has_key?(p.quote, :quote)
  end

  test "image-only raw record keeps alt but invents no CDN URL" do
    source = %{
      record: %{
        text: "",
        embed: %{
          images: [
            %{alt: "a cat", image: %{ref: %{"$link" => "cid"}, mimeType: "image/jpeg", size: 123}}
          ]
        }
      }
    }

    for shape <- [:post, :chain_post, :notification] do
      assert [
               %{
                 alt: "a cat",
                 thumb: nil,
                 fullsize: nil,
                 availability: "unhydrated",
                 blob_cid: "cid",
                 mime_type: "image/jpeg",
                 size: 123
               }
             ] =
               Summary.extract(shape, source).images
    end
  end

  test "network-specific permalinks retain canonical URI and refuse other collections", %{
    post: post
  } do
    did = post["author"]["did"]

    for {network, origin} <- [delve: "https://delve.town", bluesky: "https://bsky.app"] do
      Application.put_env(:at_mcp, :network, network)
      uri = "at://#{did}/#{Network.collection(:post)}/abc"

      assert Network.post_url(uri) ==
               origin <> "/profile/" <> URI.encode(did, &URI.char_unreserved?/1) <> "/post/abc"

      assert Network.post_url("at://#{did}/#{Network.collection(:like)}/abc") == nil
      assert Network.post_url(uri <> "?evil") == nil
      assert Network.post_url("at://#{did}/#{Network.collection(:post)}/..") == nil
    end
  end
end
