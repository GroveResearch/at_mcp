defmodule AtMcp.ModerationDecision do
  @moduledoc """
  What the app would do with a post or an account, and why: the decision
  the app's moderation module makes (`moderatePost`, `moderateProfile`),
  from the account's own settings and the labelers' definitions. The app
  runs `@bsky/sdk` 1.2.0 (bluesky-social/bsky packages/sdk at 4d511036),
  whose moderation logic is that of `@atproto/api` at bluesky-social/atproto
  9f66a7e (packages/api/src/moderation); the file and line references here
  are to the latter. The app reads it to
  hide, cover or flag what it shows (social-app's ContentHider and
  PostAlerts); here it is marked, never applied, so a model reads what a
  person sees and can still read what the app would cover.

  The logic is ported as it is, line for line where it decides anything;
  each part names the source it follows. The decision is made from the
  summaries `AtMcp.Summary` builds, which carry every fact it reads: labels
  with their source and subject, the author's relationship to the account,
  the text, tags, languages, image alt text and link card a muted word is
  matched against, and the same for a quoted post.

  Left out, as in `AtMcp.Moderation`: hidden posts (`hiddenPostsPref`), which
  the app keeps on the device and never reads from the preferences.
  """

  alias AtMcp.Moderation

  # moderation/types.ts:21-55.
  @block_behavior %{
    profile_list: :blur,
    profile_view: :alert,
    avatar: :blur,
    banner: :blur,
    content_list: :blur,
    content_view: :blur
  }
  @mute_behavior %{
    profile_list: :inform,
    profile_view: :alert,
    content_list: :blur,
    content_view: :inform
  }
  @muteword_behavior %{content_list: :blur, content_view: :blur}

  # The labels every labeler's labels are read against
  # (packages/api/definitions/labels.json, from which
  # moderation/const/labels.ts is generated).
  @hide_all %{
    account: %{
      profile_list: :blur,
      profile_view: :blur,
      avatar: :blur,
      banner: :blur,
      display_name: :blur,
      content_list: :blur,
      content_view: :blur
    },
    profile: %{avatar: :blur, banner: :blur, display_name: :blur},
    content: %{content_list: :blur, content_view: :blur}
  }
  @media %{
    account: %{avatar: :blur, banner: :blur},
    profile: %{avatar: :blur, banner: :blur},
    content: %{content_media: :blur}
  }
  @global %{
    "!hide" => %{
      configurable: false,
      default: "hide",
      flags: ["no-override", "no-self"],
      behaviors: @hide_all
    },
    "!warn" => %{
      configurable: false,
      default: "warn",
      flags: ["no-self"],
      behaviors: put_in(@hide_all, [:account, :display_name], nil)
    },
    "!no-unauthenticated" => %{
      configurable: false,
      default: "hide",
      flags: ["no-override", "unauthed"],
      behaviors: @hide_all
    },
    "porn" => %{configurable: true, default: "hide", flags: ["adult"], behaviors: @media},
    "sexual" => %{configurable: true, default: "warn", flags: ["adult"], behaviors: @media},
    "nudity" => %{configurable: true, default: "ignore", flags: [], behaviors: @media},
    "graphic-media" => %{configurable: true, default: "warn", flags: ["adult"], behaviors: @media}
  }

  # `CUSTOM_LABEL_VALUE_RE` (types.ts:15).
  @custom_value ~r/^[a-z-]+$/

  @doc """
  The settings a decision is made with (`ModerationOpts`, types.ts:180-187),
  from the account's stored preferences and the detailed views of the
  labelers whose labels are to be read. As the app builds them: the label
  settings and labelers as `getPreferences` reads them (agent.ts:583-786,
  `AtMcp.Moderation.label_settings/1`), adult content as set, the muted
  words, and each labeler's definitions as `interpretLabelValueDefinitions`
  reads them (util.ts:106-111).
  """
  def options(preferences, user_did, labeler_views \\ []) do
    {global, by_labeler} = Moderation.label_settings(preferences)

    labelers =
      for did <- Moderation.labelers(preferences),
          do: %{did: did, labels: Map.get(by_labeler, did, %{})}

    views = Enum.filter(labeler_views, &is_map/1)

    %{
      user_did: user_did,
      adult: AtMcp.Preferences.kind_view(preferences, "adult_content").enabled == true,
      labels: global,
      labelers: labelers,
      muted_words: Moderation.muted_words(preferences),
      defs:
        Map.new(views, fn view ->
          did = get_in(view, ["creator", "did"])
          policies = if is_map(view["policies"]), do: view["policies"], else: %{}

          {did,
           policies["labelValueDefinitions"]
           |> List.wrap()
           |> Enum.filter(&Moderation.valid_definition?/1)
           |> Enum.map(&interpret(&1, did))}
        end),
      names: Map.new(views, &{get_in(&1, ["creator", "did"]), get_in(&1, ["creator", "handle"])})
    }
  end

  @doc """
  The labelers whose definitions a decision on `labels` needs: their sources
  that are among the account's labelers. Labels with no such source need no
  labeler read.
  """
  def labelers_needed(labels, preferences) do
    mine = MapSet.new(Moderation.labelers(preferences))

    labels
    |> Enum.map(&get(&1, :src))
    |> Enum.filter(&(is_binary(&1) and MapSet.member?(mine, &1)))
    |> Enum.uniq()
  end

  @doc "Every label on a summary of a post or account, its quote's included."
  def labels_of(summary) when is_map(summary) do
    quote = get(summary, :quote)
    quote = if is_map(quote), do: quote, else: %{}

    Enum.flat_map(
      [summary, quote],
      &(List.wrap(get(&1, :labels)) ++ List.wrap(get(&1, :author_labels)))
    )
    |> Enum.filter(&is_map/1)
  end

  def labels_of(_other), do: []

  # `interpretLabelValueDefinition` (util.ts:26-104).
  defp interpret(definition, did) do
    alert_or_inform =
      case definition["severity"] do
        "alert" -> :alert
        "inform" -> :inform
        _ -> nil
      end

    content_view = if definition["adultOnly"] == true, do: :blur, else: alert_or_inform
    shown = %{profile_list: alert_or_inform, profile_view: alert_or_inform}

    behaviors =
      case definition["blurs"] do
        "content" ->
          %{
            account: Map.merge(shown, %{content_list: :blur, content_view: content_view}),
            profile: shown,
            content: %{content_list: :blur, content_view: content_view}
          }

        "media" ->
          %{
            account: Map.merge(shown, %{avatar: :blur, banner: :blur}),
            profile: Map.merge(shown, %{avatar: :blur, banner: :blur}),
            content: %{content_media: :blur}
          }

        "none" ->
          %{
            account:
              Map.merge(shown, %{content_list: alert_or_inform, content_view: alert_or_inform}),
            profile: shown,
            content: %{content_list: alert_or_inform, content_view: alert_or_inform}
          }

        _ ->
          %{account: %{}, profile: %{}, content: %{}}
      end

    %{
      identifier: definition["identifier"],
      defined_by: did,
      configurable: true,
      default: Moderation.default_setting(definition),
      flags: ["no-self"] ++ if(definition["adultOnly"] == true, do: ["adult"], else: []),
      behaviors: behaviors,
      name: locale_name(definition["locales"])
    }
  end

  defp locale_name(locales) when is_list(locales) do
    locale =
      Enum.find(locales, &(is_map(&1) and &1["lang"] == "en")) ||
        Enum.find(locales, &is_map/1)

    if locale, do: locale["name"]
  end

  defp locale_name(_locales), do: nil

  # --- subjects ---

  @doc """
  The causes the app finds on a post (`decidePost`, subjects/post.ts:17-27):
  the post's own labels and the muted words it matches, its quoted post's
  (downgraded, so they cover nothing but may still hide), and its author's
  account and profile labels and relationship to the account.
  """
  def post(summary, opts) when is_map(summary) do
    author = get(summary, :author_did)
    me? = author == opts.user_did

    subject =
      Enum.flat_map(List.wrap(get(summary, :labels)), &label(:content, &1, author, opts)) ++
        if(me?, do: [], else: muted_word(match_all_mute_words(summary, opts.muted_words)))

    embedded =
      summary |> get(:quote) |> embedded(opts) |> Enum.map(&Map.put(&1, :downgraded, true))

    %{
      me?: me?,
      causes:
        subject ++
          embedded ++
          account(author, get(summary, :author_viewer), get(summary, :author_labels), opts) ++
          profile(author, get(summary, :author_labels), opts)
    }
  end

  @doc "The causes the app finds on an account (`moderateProfile`, index.ts:27-35)."
  def profile(summary, opts) when is_map(summary) do
    did = get(summary, :did)

    %{
      me?: did == opts.user_did,
      causes:
        account(did, get(summary, :viewer), get(summary, :labels), opts) ++
          profile(did, get(summary, :labels), opts)
    }
  end

  # `decideQuotedPost` and `decideBlockedQuotedPost` (subjects/post.ts:84-131).
  defp embedded(%{} = quote, opts) do
    author = get(quote, :author_did)

    case get(quote, :status) do
      "available" ->
        if get(quote, :kind) in [nil, "post"] do
          Enum.flat_map(List.wrap(get(quote, :labels)), &label(:content, &1, author, opts)) ++
            account(author, get(quote, :author_viewer), get(quote, :author_labels), opts) ++
            profile(author, get(quote, :author_labels), opts)
        else
          []
        end

      "blocked" ->
        relationship(get(quote, :author_viewer))

      _ ->
        []
    end
    |> Enum.map(&Map.put(&1, :in_quote, true))
  end

  defp embedded(_quote, _opts), do: []

  # `decideAccount` with `filterAccountLabels` (subjects/account.ts:8-47).
  defp account(did, viewer, labels, opts) do
    relationship(viewer) ++
      (labels
       |> List.wrap()
       |> Enum.filter(&(not on_profile?(&1) or get(&1, :val) == "!no-unauthenticated"))
       |> Enum.flat_map(&label(:account, &1, did, opts)))
  end

  # `decideProfile` with `filterProfileLabels` (subjects/profile.ts:8-30).
  defp profile(did, labels, opts) do
    labels
    |> List.wrap()
    |> Enum.filter(&on_profile?/1)
    |> Enum.flat_map(&label(:profile, &1, did, opts))
  end

  defp on_profile?(label) do
    case get(label, :uri) do
      uri when is_binary(uri) -> String.ends_with?(uri, "/app.bsky.actor.profile/self")
      _ -> false
    end
  end

  # The muted and blocking causes, as `decideAccount` adds them
  # (subjects/account.ts:17-30; decision.ts:229-266, 365-383).
  defp relationship(viewer) when is_map(viewer) do
    muted =
      cond do
        get(viewer, :muted) == true and is_binary(get(viewer, :muted_by_list)) ->
          [%{type: :muted, list: get(viewer, :muted_by_list), priority: 6}]

        get(viewer, :muted) == true ->
          [%{type: :muted, priority: 6}]

        true ->
          []
      end

    blocking =
      cond do
        not is_binary(get(viewer, :blocking)) ->
          []

        is_binary(get(viewer, :blocking_by_list)) ->
          [%{type: :blocking, list: get(viewer, :blocking_by_list), priority: 3}]

        true ->
          [%{type: :blocking, priority: 3}]
      end

    blocked_by =
      if get(viewer, :blocked_by) == true, do: [%{type: :blocked_by, priority: 4}], else: []

    muted ++ blocking ++ blocked_by
  end

  defp relationship(_viewer), do: []

  defp muted_word(nil), do: []
  defp muted_word(matches), do: [%{type: :muted_word, matches: matches, priority: 6}]

  # `addLabel` (decision.ts:268-363).
  defp label(target, label, subject_did, opts) when is_map(label) do
    val = get(label, :val)
    src = get(label, :src)

    definition =
      if is_binary(val) do
        if Regex.match?(@custom_value, val),
          do:
            Enum.find(Map.get(opts.defs, src, []), &(&1.identifier == val)) ||
              global(val),
          else: global(val)
      end

    self? = src == subject_did
    labeler = if not self?, do: Enum.find(opts.labelers, &(&1.did == src))

    cond do
      is_nil(definition) -> []
      not self? and is_nil(labeler) -> []
      self? and "no-self" in definition.flags -> []
      true -> labelled(target, label, definition, self?, labeler, opts)
    end
  end

  defp label(_target, _label, _did, _opts), do: []

  defp labelled(target, label, definition, self?, labeler, opts) do
    adult_hidden? = "adult" in definition.flags and not opts.adult

    setting =
      cond do
        not definition.configurable ->
          definition.default || "hide"

        adult_hidden? ->
          "hide"

        labeler && Map.has_key?(labeler.labels, definition.identifier) ->
          labeler.labels[definition.identifier]

        Map.has_key?(opts.labels, definition.identifier) ->
          opts.labels[definition.identifier]

        true ->
          definition.default || "ignore"
      end

    behavior = Map.get(definition.behaviors, target) || %{}

    cond do
      setting == "ignore" ->
        []

      "unauthed" in definition.flags and is_binary(opts.user_did) ->
        []

      true ->
        no_override = "no-override" in definition.flags or adult_hidden?

        priority =
          cond do
            no_override -> 1
            setting == "hide" -> 2
            behavior[:profile_view] == :blur or behavior[:content_view] == :blur -> 5
            behavior[:content_list] == :blur or behavior[:content_media] == :blur -> 7
            true -> 8
          end

        [
          %{
            type: :label,
            label: get(label, :val),
            name: definition[:name],
            labeler: if(self? or is_nil(labeler), do: nil, else: labeler.did),
            labeler_handle: if(labeler, do: Map.get(opts.names, labeler.did)),
            self_label: self?,
            target: target,
            setting: setting,
            behavior: behavior,
            no_override: no_override,
            priority: priority
          }
        ]
    end
  end

  # A global label's definition. An old name (labels.json's `alias`) is a
  # copy under that name, as labels.ts is generated
  # (packages/api/scripts/code/labels.js:30-46).
  defp global("gore"), do: %{global("graphic-media") | identifier: "gore"}

  defp global(val) do
    case Map.fetch(@global, val) do
      {:ok, definition} -> Map.put(definition, :identifier, val)
      :error -> nil
    end
  end

  # --- what the app shows ---

  @doc """
  What the app does with each cause in one place it shows the subject
  (`ModerationDecision.ui`, decision.ts:78-187): `:content_list` (a feed or a
  reply in a thread), `:content_view` (the post a thread is opened on),
  `:profile_list` or `:profile_view`. Each cause it acts on comes back with
  its `effect`: `:hide` (left out of the list), `:cover` (behind a cover the
  person can open, unless `no_override`), `:cover_media` (images, or an
  account's avatar and banner, covered), `:alert` or `:inform` (a badge),
  highest priority first. A cause the app shows nothing for is dropped.
  """
  def ui(decision, context, mode \\ :list)

  def ui(%{me?: me?, causes: causes}, context, mode) do
    causes
    |> Enum.flat_map(fn cause ->
      case effect(cause, context, me?, mode) do
        nil -> []
        {effect, no_override} -> [Map.merge(cause, %{effect: effect, no_override: no_override})]
      end
    end)
    |> Enum.sort_by(& &1.priority)
  end

  defp effect(%{type: type}, _context, true, _mode)
       when type in [:blocking, :blocked_by, :muted, :muted_word],
       do: nil

  defp effect(%{type: type} = cause, context, _me?, mode) when type in [:blocking, :blocked_by] do
    shown(
      cause,
      context in [:profile_list, :content_list],
      Map.get(@block_behavior, context),
      true,
      mode
    )
  end

  defp effect(%{type: :muted} = cause, context, _me?, mode),
    do:
      shown(
        cause,
        context in [:profile_list, :content_list],
        Map.get(@mute_behavior, context),
        false,
        mode
      )

  defp effect(%{type: :muted_word} = cause, context, _me?, mode),
    do:
      shown(
        cause,
        context == :content_list,
        Map.get(@muteword_behavior, context),
        false,
        mode
      )

  defp effect(%{type: :label} = cause, context, me?, mode) do
    filter? =
      cause.setting == "hide" and not me? and
        ((context == :profile_list and cause.target == :account) or
           (context == :content_list and cause.target in [:account, :content]))

    media =
      if context in [:content_list, :content_view],
        do: cause.behavior[:content_media],
        else: cause.behavior[:avatar] || cause.behavior[:banner]

    no_override = cause.no_override and not me?

    case shown(cause, filter?, cause.behavior[context], no_override, mode) do
      nil when media == :blur and not is_map_key(cause, :downgraded) ->
        {:cover_media, no_override}

      other ->
        other
    end
  end

  # A cause in a list may be left out of it; one not downgraded is then
  # covered, flagged or noted as its behavior says.
  #
  # `mode` is where the list is. `:list` is a feed (decision.ts:78-187 as
  # post-feed.ts:303-316 at 62b95002 applies it: a filtered post is left
  # out). `:thread` is a thread's reply or parent, which is never left out:
  # PostHider with `interpretFilterAsBlur` (ThreadItemPost.tsx:266-275,
  # PostHider.tsx:58-60, 155-157) covers it for the first cause that blurs,
  # or else for the first that filters and is not downgraded, so a quoted
  # post's cause covers nothing there. `:author_feed` is a profile's posts
  # by that profile's account, which the app shows whatever filters them
  # (`ignoreFilterFor`, Profile.tsx:440,467 and post-feed.ts:303-316).
  defp shown(cause, filter?, behavior, no_override, mode) do
    downgraded? = Map.get(cause, :downgraded, false)
    filter? = filter? and mode != :author_feed

    cond do
      filter? and mode == :list -> {:hide, behavior == :blur and not downgraded? and no_override}
      downgraded? -> nil
      behavior == :blur or filter? -> {:cover, no_override}
      behavior in [:alert, :inform] -> {behavior, false}
      true -> nil
    end
  end

  @doc """
  The marks a summary carries for a decision shown in `context`: each cause
  the app acts on there, highest priority first, with what it does and why,
  ready for the structured content. `subject` is `:post` or `:account`.
  """
  def marks(decision, context, subject \\ :post, mode \\ :list) do
    decision
    |> ui(context, mode)
    |> Enum.map(fn cause ->
      %{
        type: Atom.to_string(cause.type),
        effect: Atom.to_string(cause.effect),
        on: on(cause, subject)
      }
      |> put_if(:no_override, cause.no_override == true)
      |> Map.merge(
        case cause.type do
          :label ->
            %{label: cause.label, setting: cause.setting}
            |> put_present(:label_name, cause.name)
            |> put_present(:labeler, cause.labeler)
            |> put_present(:labeler_handle, cause.labeler_handle)
            |> put_if(:self_label, cause.self_label)

          :muted_word ->
            %{words: cause.matches}

          _ ->
            put_present(%{}, :list, Map.get(cause, :list))
        end
      )
    end)
  end

  defp on(cause, :account),
    do: if(Map.get(cause, :target) == :profile, do: "profile", else: "account")

  defp on(cause, :post) do
    author? = cause.type != :label or cause.target != :content
    quote? = Map.get(cause, :in_quote, false)

    case {quote?, author?} do
      {false, false} -> "post"
      {false, true} -> "author"
      {true, false} -> "quoted_post"
      {true, true} -> "quoted_author"
    end
  end

  defp put_if(map, key, true), do: Map.put(map, key, true)
  defp put_if(map, _key, _false), do: map

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  @effects [
    {"hide", "Hidden by the app"},
    {"cover", "Behind a warning in the app"},
    {"cover_media", "Media behind a warning in the app"},
    {"alert", "Warning in the app"},
    {"inform", "Note in the app"}
  ]

  @doc """
  The line a reading shows for a post's or an account's `moderation`, as the
  structured content carries it (string keys): where a thread puts it, then
  what the app does and why, one group per effect. Nil when there is nothing
  to mark.
  """
  def line(%{} = moderation) do
    causes = Enum.filter(List.wrap(moderation["causes"]), &is_map/1)

    place =
      case moderation["in_thread"] do
        "show_more_replies" -> "Under \"Show more replies\" in the app"
        "left_out" -> "Left out of this thread by the app; shown when its parent is opened"
        "under_left_out" -> "Under a reply the app leaves out of this thread"
        _ -> nil
      end

    groups =
      for {effect, heading} <- @effects,
          group = Enum.filter(causes, &(&1["effect"] == effect)),
          group != [] do
        locked =
          if effect in ["hide", "cover", "cover_media"] and
               Enum.any?(group, &(&1["no_override"] == true)),
             do: " (it cannot be opened)",
             else: ""

        heading <> locked <> ": " <> Enum.map_join(group, "; ", &why/1)
      end

    case Enum.reject([place | groups], &is_nil/1) do
      [] -> nil
      parts -> Enum.join(parts, " · ")
    end
  end

  def line(_other), do: nil

  defp why(%{"type" => "label"} = cause) do
    whose =
      case cause["on"] do
        "author" -> "author labeled"
        "quoted_post" -> "quoted post labeled"
        "quoted_author" -> "quoted post's author labeled"
        "profile" -> "profile labeled"
        _ -> "labeled"
      end

    # A name is the labeler's own text, quoted so it cannot pass for a line
    # of the reading.
    name = if is_binary(cause["label_name"]), do: " (#{inspect(cause["label_name"])})", else: ""

    by =
      cond do
        cause["self_label"] == true -> "by its author"
        is_binary(cause["labeler_handle"]) -> "by " <> cause["labeler_handle"]
        is_binary(cause["labeler"]) -> "by " <> cause["labeler"]
        true -> nil
      end

    Enum.join(Enum.reject([whose, "'#{cause["label"]}'#{name}", by], &is_nil/1), " ")
  end

  defp why(%{"type" => "muted_word", "words" => words}) when is_list(words) do
    quoted = Enum.map_join(words, ", ", &inspect/1)

    if length(words) == 1,
      do: "matches your muted word " <> quoted,
      else: "matches your muted words " <> quoted
  end

  defp why(%{"type" => type} = cause) do
    whom =
      case cause["on"] do
        "quoted_author" -> "the quoted post's author"
        "account" -> "this account"
        _ -> "the author"
      end

    via = if is_binary(cause["list"]), do: " via a list", else: ""

    case type do
      "muted" -> "you muted #{whom}#{via}"
      "blocking" -> "you blocked #{whom}#{via}"
      "blocked_by" -> "#{whom} blocked you"
      other -> other
    end
  end

  defp why(_cause), do: ""

  @doc """
  Whether a reply in a thread is moved out of the thread's main list, as the
  app's thread view decides it (social-app src/state/queries/usePostThread/
  views.ts:71-77 at 62b95002): it is covered or left out in a list, its
  author is muted, or the thread's author hid it; never the account's own.
  """
  def moved_in_thread?(decision, hidden_by_threadgate?) do
    list = ui(decision, :content_list)

    (hidden_by_threadgate? or Enum.any?(list, &(&1.effect in [:hide, :cover]))) and
      not decision.me?
  end

  # --- muted words ---

  # `matchAllMuteWords` (subjects/post.ts:182-433), read from a post's
  # summary: its text, tags and languages, its images' alt text, a link card,
  # and a quoted post's text, images and link card, in the order the library
  # tries them.
  defp match_all_mute_words(_summary, []), do: nil

  defp match_all_mute_words(summary, words) do
    author = get(summary, :author_viewer)
    langs = List.wrap(get(summary, :langs))
    embed = embed_kind(get(summary, :embed_type))
    quote = quoted_post(get(summary, :quote))

    own =
      [
        fn ->
          match_mute_words(
            words,
            get(summary, :raw_text),
            get(summary, :facets),
            get(summary, :tags),
            langs,
            author
          )
        end
      ] ++
        if embed in [:images, :gallery],
          do: alts(summary, words, langs, author),
          else: []

    embedded =
      cond do
        embed == :record and quote ->
          quoted(quote, words)

        embed == :external ->
          [fn -> card(get(summary, :link), words, author) end]

        embed == :record_with_media and quote ->
          quote_author = get(quote, :author_viewer)

          [
            fn ->
              match_mute_words(
                words,
                get(quote, :raw_text),
                get(quote, :facets),
                get(quote, :tags),
                List.wrap(get(quote, :langs)),
                quote_author
              )
            end
          ] ++
            alts(summary, words, langs, quote_author) ++
            [fn -> card(get(summary, :link), words, quote_author) end]

        true ->
          []
      end

    Enum.find_value(own ++ embedded, & &1.())
  end

  # A quote the app reads a muted word in: an available quoted post.
  defp quoted_post(%{} = quote) do
    if get(quote, :status) == "available" and get(quote, :kind) in [nil, "post"], do: quote
  end

  defp quoted_post(_quote), do: nil

  defp quoted(quote, words) do
    author = get(quote, :author_viewer)
    langs = List.wrap(get(quote, :langs))

    [
      fn ->
        match_mute_words(
          words,
          get(quote, :raw_text),
          get(quote, :facets),
          get(quote, :tags),
          langs,
          author
        )
      end
    ] ++
      alts(quote, words, image_langs(quote, langs), author) ++
      [fn -> card(get(quote, :link), words, author) end]
  end

  # A quoted post's images are matched in its languages, except those beside
  # a post it quotes in turn (a record with media), which are matched in
  # none: the library reads them from `embeddedPost.record`, which a post
  # record does not have (subjects/post.ts:313-318). A quoted post with both
  # images and a quote of its own has them that way.
  defp image_langs(quote, langs) do
    if is_binary(get(quote, :nested_uri)), do: [], else: langs
  end

  defp alts(subject, words, langs, author) do
    for image <- List.wrap(get(subject, :images)), is_map(image) do
      fn -> match_mute_words(words, get(image, :alt), nil, nil, langs, author) end
    end
  end

  defp card(link, words, author) when is_map(link),
    do:
      match_mute_words(
        words,
        "#{get(link, :title)} #{get(link, :description)}",
        nil,
        nil,
        [],
        author
      )

  defp card(_link, _words, _author), do: nil

  defp embed_kind(type) when is_binary(type) do
    cond do
      String.ends_with?(type, ".embed.images#view") -> :images
      String.ends_with?(type, ".embed.gallery#view") -> :gallery
      String.ends_with?(type, ".embed.external#view") -> :external
      String.ends_with?(type, ".embed.recordWithMedia#view") -> :record_with_media
      String.ends_with?(type, ".embed.record#view") -> :record
      true -> nil
    end
  end

  defp embed_kind(_type), do: nil

  # Languages written without spaces between words, matched by substring
  # (mutewords.ts:17-23).
  @language_exceptions ~w(ja zh ko th vi)

  @doc """
  The muted words `text` matches, as `matchMuteWords` matches them
  (mutewords.ts:48-162), or nil: each word that has not expired, and, for a
  word muted only for accounts the account does not follow, only when it
  does not follow the author (`viewer` is the author's relationship to it).
  """
  def match_mute_words(words, text, facets, outline_tags, languages, viewer, now \\ now()) do
    text = if is_binary(text), do: text, else: ""
    exception? = List.first(List.wrap(languages)) in @language_exceptions

    tags =
      (List.wrap(outline_tags) ++
         for(
           facet <- List.wrap(facets),
           is_map(facet) and get(facet, :type) == "tag",
           tag = get(facet, :tag),
           is_binary(tag),
           do: tag
         ))
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.downcase/1)

    following? = is_map(viewer) and get(viewer, :following) not in [nil, false]
    post_text = String.downcase(text)

    matches =
      for word <- words,
          is_map(word) and is_binary(word["value"]),
          not (is_binary(word["expiresAt"]) and word["expiresAt"] < now),
          not (word["actorTarget"] == "exclude-following" and following?),
          match = match_word(word, String.downcase(word["value"]), post_text, tags, exception?),
          do: match

    if matches == [], do: nil, else: matches
  end

  defp match_word(word, muted, post_text, tags, exception?) do
    cond do
      muted in tags ->
        word["value"]

      "content" not in List.wrap(word["targets"]) ->
        nil

      (js_length(muted) == 1 or exception?) and String.contains?(post_text, muted) ->
        word["value"]

      js_length(muted) > js_length(post_text) ->
        nil

      muted == post_text ->
        word["value"]

      Regex.match?(~r/(?:\s|\p{P})+?/u, muted) and String.contains?(post_text, muted) ->
        word["value"]

      true ->
        post_text
        |> String.split(~r/\s/u)
        |> Enum.reduce_while(nil, fn part, nil ->
          case match_part(part, muted) do
            :match -> {:halt, word["value"]}
            :stop -> {:halt, nil}
            :next -> {:cont, nil}
          end
        end)
    end
  end

  # One whitespace-separated part of the text (mutewords.ts:115-155).
  defp match_part(part, muted) do
    trimmed = Regex.replace(~r/(?:^\p{P}+|\p{P}+$)/u, part, "")

    cond do
      part == muted ->
        :match

      muted == trimmed ->
        :match

      js_length(muted) > js_length(trimmed) ->
        :next

      not Regex.match?(~r/\p{P}+/u, trimmed) ->
        :next

      String.contains?(trimmed, "/") ->
        :stop

      true ->
        spaced = Regex.replace(~r/\p{P}+/u, trimmed, " ")

        cond do
          spaced == muted -> :match
          Regex.replace(~r/\s/u, spaced, "") == muted -> :match
          muted in Regex.split(~r/\p{P}+/u, trimmed) -> :match
          true -> :next
        end
    end
  end

  # A JavaScript string's length: its UTF-16 code units.
  defp js_length(string),
    do: div(byte_size(:unicode.characters_to_binary(string, :utf8, :utf16)), 2)

  # `new Date().toISOString()`, which an `expiresAt` is compared with as a string.
  defp now do
    DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
  end

  defp get(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp get(_other, _key), do: nil
end
