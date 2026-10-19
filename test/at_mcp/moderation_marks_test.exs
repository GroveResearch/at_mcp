defmodule AtMcp.ModerationMarksTest do
  use ExUnit.Case, async: true

  alias AtMcp.ModerationMarks
  alias AtMcp.Network

  @me "did:plc:me"
  @them "did:plc:them"
  @labeler "did:plc:labeler"

  # A backend that answers with what the test put in the session, and
  # reports each read it was asked for.
  defmodule Backend do
    def moderation_preferences(%{test: test} = session) do
      send(test, :preferences_read)
      session.preferences
    end

    def labeler_definitions(%{test: test} = session, dids) do
      send(test, {:labelers_read, dids})
      session.labelers
    end
  end

  defp session(preferences, labelers \\ {:ok, []}),
    do: %{test: self(), preferences: preferences, labelers: labelers}

  defp muted(words) do
    %{
      "$type" => Network.type(:muted_words_pref),
      "items" => Enum.map(words, &%{"value" => &1, "targets" => ["content", "tag"]})
    }
  end

  defp post(n, text, fields \\ %{}) do
    Map.merge(
      %{
        uri: "at://#{@them}/app.bsky.feed.post/#{n}",
        author_did: @them,
        raw_text: text,
        labels: [],
        author_labels: []
      },
      fields
    )
  end

  defp mark(session, result, kind),
    do: ModerationMarks.mark(Backend, session, @me, {:ok, result}, kind)

  test "a page of posts: the muted word is marked, the content is kept, and only the settings are read" do
    page = %{items: [post(1, "a spoiler here"), post(2, "nothing")], count: 2}

    assert {:ok, %{items: [first, second]}} =
             mark(session({:ok, [muted(["spoiler"])]}), page, :posts)

    assert first.raw_text == "a spoiler here"

    assert %{causes: [%{type: "muted_word", effect: "hide", words: ["spoiler"]}]} =
             first.moderation

    refute Map.has_key?(second, :moderation)
    assert_received :preferences_read
    refute_received {:labelers_read, _}
  end

  test "labelers are read once, for the account's labelers whose labels the read carries" do
    definition = %{
      "identifier" => "spam",
      "severity" => "inform",
      "blurs" => "content",
      "defaultSetting" => "hide",
      "locales" => [%{"lang" => "en", "name" => "Spam", "description" => "d"}]
    }

    view = %{
      "creator" => %{"did" => @labeler, "handle" => "labeler.example"},
      "policies" => %{"labelValues" => ["spam"], "labelValueDefinitions" => [definition]}
    }

    prefs = [%{"$type" => Network.type(:labelers_pref), "labelers" => [%{"did" => @labeler}]}]
    labelled = %{val: "spam", src: @labeler, uri: "at://#{@them}/app.bsky.feed.post/1"}
    stranger = %{val: "spam", src: "did:plc:stranger", uri: "at://#{@them}/app.bsky.feed.post/2"}

    page = %{
      items: [
        post(1, "x", %{labels: [labelled]}),
        post(2, "y", %{labels: [stranger]}),
        post(3, "z", %{labels: [labelled]})
      ]
    }

    assert {:ok, %{items: [one, two, three]}} =
             mark(session({:ok, prefs}, {:ok, [view]}), page, :posts)

    assert_received {:labelers_read, [@labeler]}
    refute_received {:labelers_read, _}

    assert %{causes: [%{label: "spam", labeler_handle: "labeler.example", effect: "hide"}]} =
             one.moderation

    refute Map.has_key?(two, :moderation)
    assert three.moderation == one.moderation
  end

  test "settings that cannot be read leave the read unmarked, saying why; a refused credential is passed on" do
    failure = %AtMcp.Effects.Failure{kind: :refused, status: 500, message: "down"}
    page = %{items: [post(1, "spoiler")]}

    assert {:ok, %{items: [post], moderation_unread: why}} =
             mark(session({:error, failure}), page, :posts)

    refute Map.has_key?(post, :moderation)
    assert why =~ "the account's settings could not be read (the service answered 500: down)"

    refused = %AtMcp.Effects.Failure{kind: :auth_refused, status: 401}
    assert {:error, ^refused} = mark(session({:error, refused}), page, :posts)
  end

  test "an empty read reads nothing" do
    assert {:ok, %{items: []}} = mark(session({:ok, []}), %{items: []}, :posts)
    refute_received :preferences_read
  end

  test "a thread: replies the app moves are marked where they stand, the post itself in its own view" do
    reply = fn n, text, replies -> Map.put(post(n, text), :replies, replies) end

    thread =
      post(0, "spoiler at the top")
      |> Map.put(:parent, post(9, "spoiler parent"))
      |> Map.put(:replies, [
        reply.(1, "spoiler", [
          reply.(11, "fine", []),
          reply.(12, "spoiler again", [reply.(121, "fine", [])])
        ]),
        reply.(2, "fine", [
          reply.(21, "spoiler", [reply.(211, "fine", [])]),
          reply.(22, "fine", [])
        ]),
        Map.put(reply.(3, "fine", []), :hidden_by_threadgate, true),
        Map.put(reply.(4, "spoiler", []), :author_did, @me)
      ])

    assert {:ok, marked} = mark(session({:ok, [muted(["spoiler"])]}), thread, :thread)

    # The post the thread is opened on is covered, not left out; a parent is
    # shown as in a list.
    assert %{causes: [%{effect: "cover"}]} = marked.moderation
    assert %{causes: [%{effect: "cover"}]} = marked.parent.moderation

    [one, two, three, four] = marked.replies
    assert %{in_thread: "show_more_replies", causes: [%{type: "muted_word"}]} = one.moderation
    [eleven, twelve] = one.replies
    assert %{in_thread: "show_more_replies", causes: []} = eleven.moderation
    assert %{in_thread: "left_out"} = twelve.moderation
    assert %{in_thread: "under_left_out"} = hd(twelve.replies).moderation

    refute Map.has_key?(two, :moderation)
    [twenty_one, twenty_two] = two.replies
    assert %{in_thread: "left_out"} = twenty_one.moderation
    assert %{in_thread: "under_left_out"} = hd(twenty_one.replies).moderation
    refute Map.has_key?(twenty_two, :moderation)

    assert %{in_thread: "show_more_replies"} = three.moderation
    refute Map.has_key?(four, :moderation)

    assert AtMcp.ModerationDecision.line(stringify(one.moderation)) ==
             "Under \"Show more replies\" in the app · Behind a warning in the app: matches your muted word \"spoiler\""
  end

  test "a moved branch stops at the first reply that is blocked or gone, as the app's walk does" do
    reply = fn n, text, replies -> Map.put(post(n, text), :replies, replies) end
    blocked = %{uri: "at://did:plc:x/app.bsky.feed.post/b", blocked: true, replies: []}

    thread =
      post(0, "root")
      |> Map.put(:replies, [
        reply.(1, "spoiler", [
          reply.(11, "fine", []),
          Map.put(blocked, :replies, []),
          reply.(12, "fine", [reply.(121, "fine", [])])
        ])
      ])

    assert {:ok, marked} = mark(session({:ok, [muted(["spoiler"])]}), thread, :thread)
    [one] = marked.replies
    [eleven, _blocked, twelve] = one.replies
    assert %{in_thread: "show_more_replies"} = eleven.moderation
    assert %{in_thread: "left_out"} = twelve.moderation
    assert %{in_thread: "left_out"} = hd(twelve.replies).moderation
  end

  test "a profile's posts by its own account: mutes dropped, nothing left out; others' as in a feed" do
    page = %{
      items: [
        post(1, "a spoiler", %{author_viewer: %{muted: true}}),
        post(2, "a spoiler", %{author_did: "did:plc:other", author_viewer: %{muted: true}})
      ]
    }

    assert {:ok, %{items: [own, other]}} =
             mark(session({:ok, [muted(["spoiler"])]}), page, {:author_feed, @them})

    assert %{causes: [%{type: "muted_word", effect: "cover"}]} = own.moderation
    assert %{causes: causes} = other.moderation
    assert Enum.all?(causes, &(&1.effect == "hide"))
    assert Enum.any?(causes, &(&1.type == "muted"))
  end

  defp stringify(value), do: value |> Jason.encode!() |> Jason.decode!()
end
