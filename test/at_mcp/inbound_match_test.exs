defmodule AtMcp.Inbound.MatchTest do
  use ExUnit.Case, async: true

  alias AtMcp.Inbound.Match

  @us "did:plc:us"
  @other "did:plc:other"
  @stranger "did:plc:stranger"

  test "did_from_at_uri extracts repo DID" do
    assert Match.did_from_at_uri("at://did:plc:us/app.bsky.feed.post/abc") == @us
    assert Match.did_from_at_uri("not-an-uri") == nil
  end

  test "reply to our post matches :reply (other-DID commit)" do
    event =
      post_event(@other, %{
        "reply" => %{
          "parent" => %{"uri" => "at://#{@us}/app.bsky.feed.post/parent1", "cid" => "bafy1"},
          "root" => %{"uri" => "at://#{@us}/app.bsky.feed.post/root1", "cid" => "bafy0"}
        },
        "text" => "hi"
      })

    assert Match.match_dids(event, [@us, @stranger]) == [{@us, [:reply]}]
  end

  test "mention facet matches :mention" do
    event =
      post_event(@other, %{
        "text" => "@us hello",
        "facets" => [
          %{
            "features" => [
              %{"$type" => "app.bsky.richtext.facet#mention", "did" => @us}
            ]
          }
        ]
      })

    assert Match.match_dids(event, [@us]) == [{@us, [:mention]}]
  end

  test "quote embed matches :quote" do
    event =
      post_event(@other, %{
        "text" => "quoting",
        "embed" => %{
          "$type" => "app.bsky.embed.record",
          "record" => %{"uri" => "at://#{@us}/app.bsky.feed.post/q1", "cid" => "bafyq"}
        }
      })

    assert Match.match_dids(event, [@us]) == [{@us, [:quote]}]
  end

  test "unrelated other-DID post does not match" do
    event = post_event(@other, %{"text" => "weather is fine"})
    assert Match.match_dids(event, [@us]) == []
  end

  test "own-repo commit echoes :own_repo" do
    event = post_event(@us, %{"text" => "I posted"})
    assert Match.match_dids(event, [@us]) == [{@us, [:own_repo]}]
  end

  test "reply+mention combine reasons; fanout only matched DIDs" do
    event =
      post_event(@other, %{
        "text" => "@us and @stranger",
        "reply" => %{
          "parent" => %{"uri" => "at://#{@us}/app.bsky.feed.post/p", "cid" => "c"},
          "root" => %{"uri" => "at://#{@us}/app.bsky.feed.post/p", "cid" => "c"}
        },
        "facets" => [
          %{
            "features" => [
              %{"$type" => "app.bsky.richtext.facet#mention", "did" => @us},
              %{"$type" => "app.bsky.richtext.facet#mention", "did" => @stranger}
            ]
          }
        ]
      })

    assert Match.match_dids(event, [@us]) == [{@us, [:mention, :reply]}]

    both = Match.match_dids(event, [@us, @stranger])
    assert {@us, [:mention, :reply]} in both
    assert {@stranger, [:mention]} in both
  end

  test "empty tracked set yields no matches" do
    event =
      post_event(@other, %{
        "facets" => [
          %{"features" => [%{"$type" => "app.bsky.richtext.facet#mention", "did" => @us}]}
        ]
      })

    assert Match.match_dids(event, []) == []
  end

  test "like of our post matches :like not :reply" do
    event = %{
      type: :commit,
      did: @other,
      collection: "app.bsky.feed.like",
      rkey: "like1",
      record: %{"subject" => %{"uri" => "at://#{@us}/app.bsky.feed.post/p", "cid" => "c"}}
    }

    assert Match.match_dids(event, [@us]) == [{@us, [:like]}]
    [{_did, reasons}] = Match.match_dids(event, [@us])
    refute :reply in reasons
  end

  test "repost of our post matches :repost not :reply" do
    event = %{
      type: :commit,
      did: @other,
      collection: "app.bsky.feed.repost",
      rkey: "rp1",
      record: %{"subject" => %{"uri" => "at://#{@us}/app.bsky.feed.post/p", "cid" => "c"}}
    }

    assert Match.match_dids(event, [@us]) == [{@us, [:repost]}]
  end

  defp post_event(author_did, record) do
    %{
      type: :commit,
      did: author_did,
      collection: "app.bsky.feed.post",
      rkey: "rkey1",
      operation: :create,
      cid: "bafytest",
      record: record
    }
  end
end
