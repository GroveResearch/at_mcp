defmodule AtMcp.Preferences do
  @moduledoc """
  The account's settings screens: the preferences the app keeps in one
  document (`actor.getPreferences` / `actor.putPreferences`) and the two
  declaration records it writes beside them. Each is read the way the app
  reads it and changed the way the app's library changes it (`Agent` in
  `@atproto/api` at 9f66a7e, packages/api/src/agent.ts, whose actions
  `@bsky/sdk` repeats): the last valid preference of a type is the one that
  counts, a change starts from it, every other preference of that type is
  dropped, and the changed one goes last. Every preference of another type is
  kept exactly as stored.

  A kind is one settings screen, and `set_preference` changes one kind:

    * `home_feed`: the Following feed's settings (`feedViewPref` for the feed
      `home`): `hide_replies`, `hide_reposts`, `hide_quotes`, and the
      experimental `saved_feed_samples` (`lab_mergeFeedEnabled`, "Show samples
      of your saved feeds in your Following feed"). The app applies them on the
      device when it shows the Following feed and lists; the service does not,
      so `get_timeline` returns the timeline as served.
    * `threads`: how the app shows a thread: `sort` (`top`, `oldest` or
      `newest`, the three it offers; it reads any other stored value as `top`)
      and `tree_view` (`lab_treeViewEnabled`).
    * `interaction_defaults`: who may reply to and quote a new post
      (`postInteractionSettingsPref`), in the words `post` takes. The app's
      composer starts each new post from them; `post` does not read them.
    * `adult_content`: `enabled` (`adultContentPref`). The app shows adult
      content only to an account whose declared age is 18 or over, and not in
      regions that require age assurance; `enabled: true` is refused for an
      account that has declared no such age.
    * `interests`: `tags`, each one the app offers or one the account already
      has (the app's screen keeps stored tags)
      (`interestsPref`).
    * `verification`: `hide_badges` (`verificationPrefs`), whether the app
      hides verification checks. Reads still carry verification.
    * `discoverable`: `hide_from_recommendations`, the
      `actor.contentVisibilityDeclaration` record: whether the account asks
      apps to keep its posts out of algorithmic recommendations.
    * `activity_subscriptions`: `allow`, the `notification.declaration`
      record: who may subscribe to this account's posts (`followers`,
      `mutuals` or `none`).

  Left out, each for a reason:

    * `hideRepliesByUnfollowed` and `hideRepliesByLikeCount` in `feedViewPref`:
      the app ignores both ("Legacy, ignored" in social-app's
      src/state/queries/preferences/const.ts at 485405a), so a change would
      show nowhere.
    * `personalDetailsPref`, the birth date: never written. `get_preferences`
      says whether one is set and whether it declares 18 or over, and never
      returns it.
    * `bskyAppStatePref` (the app's nudges, progress guides and beta opt-in)
      and `liveEventPreferences` (which live-event banners it shows): the
      app's state about itself, which changes nothing an agent reads or does.
    * Muted words, content labels and labelers are `AtMcp.Moderation`'s,
      which also says why hidden posts are left out; saved feeds are
      `save_feed` and `unsave_feed`.

  Everything here is pure: `AtMcp.Effects` validates a request with
  `request/2` before a session is taken, and the backend reads with `view/1`
  and changes with `change/3`.
  """

  alias AtMcp.Network

  @kinds %{
    "home_feed" => [:hide_replies, :hide_reposts, :hide_quotes, :saved_feed_samples],
    "threads" => [:sort, :tree_view],
    "interaction_defaults" => [:reply_rule, :quotes],
    "adult_content" => [:enabled],
    "interests" => [:tags],
    "verification" => [:hide_badges],
    "discoverable" => [:hide_from_recommendations],
    "activity_subscriptions" => [:allow]
  }

  # The kinds that are a record of the account's, not a preference.
  @records %{
    "discoverable" => {:content_visibility, "hideFromAlgorithmicRecommendations"},
    "activity_subscriptions" => {:notification_declaration, "allowSubscriptions"}
  }

  # The home feed's settings and the keys the app stores them under.
  @home %{
    hide_replies: "hideReplies",
    hide_reposts: "hideReposts",
    hide_quotes: "hideQuotePosts",
    saved_feed_samples: "lab_mergeFeedEnabled"
  }

  # The sorts the app's thread settings offer (`normalizeSort` in
  # social-app's src/state/queries/preferences/useThreadPreferences.ts).
  @thread_sorts ["top", "oldest", "newest"]

  # Who may subscribe to this account's posts: `notification.declaration`'s
  # known values, the three the app's settings offer. No record means
  # followers.
  @allow ["followers", "mutuals", "none"]

  # The interests the app offers (`interests` in social-app's
  # src/lib/interests.ts at 485405a). Its settings screen shows and selects
  # only these.
  @interests ~w(animals art books comedy comics culture dev education finance food gaming
    journalism movies music nature news pets photography politics science sports tech tv writers)

  # `interestsPref.tags`: at most 100.
  @max_interests 100

  @doc "The kinds `set_preference` takes."
  def kinds, do: @kinds |> Map.keys() |> Enum.sort()

  @doc "The fields of one kind, in order."
  def fields(kind), do: Map.fetch!(@kinds, kind)

  @doc "Every field any kind takes."
  def all_fields, do: @kinds |> Map.values() |> List.flatten() |> Enum.uniq()

  @doc "The thread sorts the app offers."
  def thread_sorts, do: @thread_sorts

  @doc "Who may subscribe to this account's posts: the values `allow` takes."
  def allow_values, do: @allow

  @doc "The interests the app offers."
  def interests, do: @interests

  @doc """
  The record a kind is, `{collection kind, field}`, or nil for a kind that is
  a preference.
  """
  def record(kind), do: Map.get(@records, kind)

  @doc """
  Read a `set_preference` request: `kind` and the fields given (`nil` is not
  given). Answers `{:ok, kind, changes}`, `changes` a map from each field given
  to its value read (`reply_rule` as `AtMcp.Interactions` reads it, `quotes`
  as `:allowed` or `:disabled`, `tags` each once), or the first invalid
  argument.
  """
  def request(kind, args) when is_map(args) do
    given = for {field, value} <- args, not is_nil(value), into: %{}, do: {field, value}

    with {:ok, fields} <- kind_fields(kind),
         :ok <- only_fields_of(kind, fields, given),
         :ok <- some_field(kind, fields, given) do
      Enum.reduce_while(fields, {:ok, %{}}, fn field, {:ok, acc} ->
        case Map.fetch(given, field) do
          :error ->
            {:cont, {:ok, acc}}

          {:ok, value} ->
            case read_field(field, value) do
              {:ok, read} -> {:cont, {:ok, Map.put(acc, field, read)}}
              error -> {:halt, error}
            end
        end
      end)
      |> case do
        {:ok, changes} -> {:ok, kind, changes}
        error -> error
      end
    end
  end

  defp kind_fields(kind) when is_map_key(@kinds, kind), do: {:ok, Map.fetch!(@kinds, kind)}

  defp kind_fields(_kind), do: invalid("kind", "must be one of #{Enum.join(kinds(), ", ")}")

  defp only_fields_of(kind, fields, given) do
    case Enum.find(Map.keys(given), &(&1 not in fields)) do
      nil ->
        :ok

      field ->
        owner = Enum.find(kinds(), &(field in Map.fetch!(@kinds, &1)))
        invalid(to_string(field), "is a setting of kind #{owner}, not #{kind}")
    end
  end

  defp some_field(kind, fields, given) do
    if Enum.any?(fields, &Map.has_key?(given, &1)),
      do: :ok,
      else: invalid("kind", "#{kind} takes #{Enum.join(fields, ", ")}; give at least one")
  end

  @booleans [
    :hide_replies,
    :hide_reposts,
    :hide_quotes,
    :saved_feed_samples,
    :tree_view,
    :enabled,
    :hide_badges,
    :hide_from_recommendations
  ]

  defp read_field(field, value) when field in @booleans do
    if is_boolean(value),
      do: {:ok, value},
      else: invalid(to_string(field), "must be true or false")
  end

  defp read_field(:sort, sort) when sort in @thread_sorts, do: {:ok, sort}

  defp read_field(:sort, _sort),
    do: invalid("sort", "must be #{Enum.join(@thread_sorts, ", ")}, the sorts the app offers")

  defp read_field(:reply_rule, rules), do: AtMcp.Interactions.reply_rule(rules)
  defp read_field(:quotes, quotes), do: AtMcp.Interactions.quotes(quotes)

  # Each tag within `interestsPref`'s limits. Whether the app offers it is
  # checked against the stored tags too (`interests_offered/2`), after the
  # preferences are read: the app keeps a stored tag it does not offer.
  defp read_field(:tags, tags) when is_list(tags) do
    cond do
      length(tags) > @max_interests ->
        invalid("tags", "at most #{@max_interests}")

      bad = Enum.find(tags, &(not tag?(&1))) ->
        invalid("tags", "#{inspect(bad)} is not an interest: at most 64 characters and 640 bytes")

      true ->
        {:ok, Enum.uniq(tags)}
    end
  end

  defp read_field(:tags, _tags), do: invalid("tags", "must be a list of interests")

  defp read_field(:allow, allow) when allow in @allow, do: {:ok, allow}

  defp read_field(:allow, _allow), do: invalid("allow", "must be #{Enum.join(@allow, ", ")}")

  defp tag?(tag),
    do:
      is_binary(tag) and String.valid?(tag) and String.length(tag) <= 64 and
        byte_size(tag) <= 640

  @doc """
  Whether each tag is one the app offers or one the account already has: the
  app's interests screen offers its own list and keeps any stored tag. The
  first tag that is neither is named.
  """
  def interests_offered(preferences, tags) do
    stored = kind_view(preferences, "interests").tags

    case Enum.find(tags, &(&1 not in @interests and &1 not in stored)) do
      nil ->
        :ok

      other ->
        invalid(
          "tags",
          "#{inspect(other)} is not an interest the app offers or one the account has; it offers #{Enum.join(@interests, ", ")}"
        )
    end
  end

  # --- reading ---

  @doc """
  The settings as the app shows them, from the preferences as stored: one map
  per preference kind, each field as `get_preferences` reports it, and
  `adult_content` with whether a birth date is set (`birth_date_set`) and
  whether the account's declared age is 18 or over (`declared_over_18`); and
  the moderation settings `AtMcp.Moderation.view/1` reads.
  """
  def view(preferences) when is_list(preferences) do
    %{
      home_feed: kind_view(preferences, "home_feed"),
      threads: kind_view(preferences, "threads"),
      interaction_defaults: kind_view(preferences, "interaction_defaults"),
      adult_content:
        Map.merge(kind_view(preferences, "adult_content"), %{
          birth_date_set: birth_date_set?(preferences),
          declared_over_18: declared_over_18?(preferences)
        }),
      interests: kind_view(preferences, "interests"),
      verification: kind_view(preferences, "verification")
    }
    |> Map.merge(AtMcp.Moderation.view(preferences))
  end

  @doc "The fields of one preference kind as the app shows them."
  def kind_view(preferences, "home_feed") do
    home = last_valid(preferences, :feed_view_pref, &(&1["feed"] == "home")) || %{}
    Map.new(@home, fn {field, key} -> {field, truthy?(home[key])} end)
  end

  # Unlike the other kinds, the library merges every valid thread preference
  # in order rather than taking the last.
  def kind_view(preferences, "threads") do
    merged =
      preferences
      |> Enum.filter(&valid?(:thread_view_pref, &1))
      |> Enum.reduce(%{}, &Map.merge(&2, &1))

    %{sort: normalize_sort(merged["sort"]), tree_view: truthy?(merged["lab_treeViewEnabled"])}
  end

  def kind_view(preferences, "interaction_defaults") do
    pref = last_valid(preferences, :post_interaction_settings_pref) || %{}

    %{
      reply_rule:
        case pref["threadgateAllowRules"] do
          rules when is_list(rules) -> AtMcp.Interactions.reply_rule_words(%{"allow" => rules})
          _ -> ["everyone"]
        end,
      quotes:
        AtMcp.Interactions.quotes_word(%{"embeddingRules" => pref["postgateEmbeddingRules"]})
    }
  end

  def kind_view(preferences, "adult_content") do
    pref = last_valid(preferences, :adult_content_pref) || %{}
    %{enabled: pref["enabled"] == true}
  end

  def kind_view(preferences, "interests") do
    merged =
      preferences
      |> Enum.filter(&valid?(:interests_pref, &1))
      |> Enum.reduce(%{}, &Map.merge(&2, &1))

    %{tags: Map.get(merged, "tags", [])}
  end

  def kind_view(preferences, "verification") do
    pref = last_valid(preferences, :verification_prefs) || %{}
    %{hide_badges: truthy?(pref["hideBadges"])}
  end

  @doc """
  The field of a record kind as the app shows it, from the record's value, or
  nil when the account has no such record: none hides nothing from
  recommendations, and no declaration lets followers subscribe.
  """
  def record_view("discoverable", value),
    do: %{hide_from_recommendations: is_map(value) and value[field("discoverable")] == true}

  def record_view("activity_subscriptions", value) do
    allow =
      case is_map(value) && value[field("activity_subscriptions")] do
        allow when is_binary(allow) -> allow
        _ -> "followers"
      end

    %{allow: allow}
  end

  defp field(kind), do: kind |> record() |> elem(1)

  @doc """
  The record a record kind writes: the one read (nil when there is none) with
  its field set and every other field kept.
  """
  def record_value(kind, current, changes) do
    {collection, key} = record(kind)
    [{_field, value}] = Map.to_list(changes)

    (current || %{})
    |> Map.put("$type", Network.collection(collection))
    |> Map.put(key, value)
  end

  # The PDS adds `declaredAgePref` to what it answers when the account has a
  # birth date, for every session; `personalDetailsPref`, the date itself, only
  # a session with full access sees, which an app password is not.
  defp birth_date_set?(preferences) do
    Enum.any?(preferences, fn pref ->
      of_type?(pref, :declared_age_pref) or
        (of_type?(pref, :personal_details_pref) and is_binary(pref["birthDate"]))
    end)
  end

  defp declared_over_18?(preferences) do
    case last_valid(preferences, :declared_age_pref) do
      %{"isOverAge18" => true} -> true
      _ -> false
    end
  end

  @doc "Whether the account's declared age is 18 or over, as the app reads it."
  def declared_over_18(preferences), do: declared_over_18?(preferences)

  defp normalize_sort(sort) when sort in ["oldest", "newest"], do: sort
  defp normalize_sort(_sort), do: "top"

  # The app tests these settings for truth the way JavaScript does.
  defp truthy?(value), do: value not in [nil, false, 0, ""]

  # --- changing ---

  @doc """
  The preferences with one preference kind changed as the app's library
  changes it, every other preference kept as stored. `changes` is what
  `request/2` read, with any list in `reply_rule` already in DID form.
  """
  def change(preferences, "home_feed", changes) do
    existing = last_valid(preferences, :feed_view_pref, &(&1["feed"] == "home"))

    set =
      for {field, value} <- changes, into: %{}, do: {Map.fetch!(@home, field), value}

    replace(
      preferences,
      &(of_type?(&1, :feed_view_pref) and &1["feed"] == "home"),
      (existing || %{})
      |> Map.merge(set)
      |> Map.put("$type", Network.type(:feed_view_pref))
      |> Map.put("feed", "home")
    )
  end

  # The app saves both settings at once, from what it shows (the merged
  # preferences, the sort normalized), over the last thread preference
  # (`savePrefs` in social-app's useThreadPreferences.ts, then
  # `setThreadViewPrefs`), so changing one never resets the other.
  def change(preferences, "threads", changes) do
    existing = last_valid(preferences, :thread_view_pref) || %{}
    shown = kind_view(preferences, "threads")
    %{sort: sort, tree_view: tree} = Map.merge(shown, changes)

    replace(
      preferences,
      &of_type?(&1, :thread_view_pref),
      Map.merge(existing, %{
        "$type" => Network.type(:thread_view_pref),
        "sort" => sort,
        "lab_treeViewEnabled" => tree
      })
    )
  end

  # The app's library writes both rules at once; a rule not given keeps what
  # is stored, as the app's form starts from the current settings. Everyone
  # may reply when there is no reply rule at all.
  def change(preferences, "interaction_defaults", changes) do
    existing =
      last_valid(preferences, :post_interaction_settings_pref) ||
        %{"$type" => Network.type(:post_interaction_settings_pref)}

    pref =
      Enum.reduce(changes, existing, fn
        {:reply_rule, :everyone}, pref ->
          Map.delete(pref, "threadgateAllowRules")

        {:reply_rule, rules}, pref ->
          Map.put(pref, "threadgateAllowRules", AtMcp.ATProto.reply_rules(rules))

        {:quotes, :disabled}, pref ->
          Map.put(pref, "postgateEmbeddingRules", [
            %{"$type" => Network.type(:disable_rule)}
          ])

        {:quotes, :allowed}, pref ->
          Map.put(pref, "postgateEmbeddingRules", [])
      end)

    replace(preferences, &of_type?(&1, :post_interaction_settings_pref), pref)
  end

  def change(preferences, "adult_content", %{enabled: enabled}) do
    existing =
      last_valid(preferences, :adult_content_pref) ||
        %{"$type" => Network.type(:adult_content_pref)}

    replace(
      preferences,
      &of_type?(&1, :adult_content_pref),
      Map.put(existing, "enabled", enabled)
    )
  end

  def change(preferences, "interests", %{tags: tags}) do
    existing = last_valid(preferences, :interests_pref) || %{}

    replace(
      preferences,
      &of_type?(&1, :interests_pref),
      existing
      |> Map.merge(%{
        "$type" => Network.type(:interests_pref),
        "tags" => tags,
        "updatedAt" =>
          DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
      })
    )
  end

  def change(preferences, "verification", %{hide_badges: hide}) do
    existing =
      last_valid(preferences, :verification_prefs) ||
        %{"$type" => Network.type(:verification_prefs), "hideBadges" => false}

    replace(
      preferences,
      &of_type?(&1, :verification_prefs),
      Map.put(existing, "hideBadges", hide)
    )
  end

  # Every preference `drop?` names goes, and `pref` goes last.
  defp replace(preferences, drop?, pref),
    do: Enum.reject(preferences, &(is_map(&1) and drop?.(&1))) ++ [pref]

  @doc """
  The fields of `kind` whose value differs between two views of it, in the
  kind's order.
  """
  def changed(kind, before, now),
    do: for(field <- fields(kind), not same?(field, before[field], now[field]), do: field)

  # Interests are a set: the same tags in another order are no change, and
  # the app writes nothing for them.
  defp same?(:tags, before, now) when is_list(before) and is_list(now),
    do: MapSet.new(before) == MapSet.new(now)

  defp same?(_field, before, now), do: before == now

  # --- notification settings ---

  # Each reason the app's notification settings show, the key it is kept
  # under (`notification.defs#preferences`), and whether it filters by who
  # acted (`include`). In the app's order.
  @notification_settings [
    {"like", "like", true},
    {"follow", "follow", true},
    {"reply", "reply", true},
    {"mention", "mention", true},
    {"quote", "quote", true},
    {"repost", "repost", true},
    {"subscribed_post", "subscribedPost", false},
    {"like_via_repost", "likeViaRepost", true},
    {"repost_via_repost", "repostViaRepost", true},
    {"starterpack_joined", "starterpackJoined", false},
    {"verified", "verified", false},
    {"unverified", "unverified", false}
  ]

  @includes ["all", "follows"]

  @doc "The reasons `set_notification_setting` takes, in the app's order."
  def notification_reasons, do: Enum.map(@notification_settings, &elem(&1, 0))

  @doc "The reasons whose setting has `include`."
  def filterable_reasons, do: for({reason, _key, true} <- @notification_settings, do: reason)

  @doc "What `include` takes."
  def includes, do: @includes

  @doc """
  Read a `set_notification_setting` request: `reason`, and `include`, `list`
  and `push` in `opts`, nil when not given. Answers `{:ok, reason, changes}`
  or the first invalid argument.
  """
  def notification_request("chat", _opts),
    do:
      invalid(
        "reason",
        "chat's notification settings belong to the chat service (chat.bsky.notification), which at_mcp does not reach; notification.putPreferencesV2 does not keep them"
      )

  def notification_request(reason, opts) do
    given =
      for {key, value} <- opts,
          key in [:include, :list, :push],
          not is_nil(value),
          into: %{},
          do: {key, value}

    case List.keyfind(@notification_settings, reason, 0) do
      nil ->
        invalid("reason", "must be one of #{Enum.join(notification_reasons(), ", ")}")

      {_reason, _key, filterable?} ->
        cond do
          given == %{} ->
            invalid("reason", "give include, list or push to change")

          Map.has_key?(given, :include) and not filterable? ->
            invalid(
              "include",
              "#{reason} notifications are not filtered by who acted; only #{Enum.join(filterable_reasons(), ", ")} take include"
            )

          Map.has_key?(given, :include) and given.include not in @includes ->
            invalid("include", "must be all or follows")

          bad =
              Enum.find([:list, :push], &(Map.has_key?(given, &1) and not is_boolean(given[&1]))) ->
            invalid(to_string(bad), "must be true or false")

          true ->
            {:ok, reason, given}
        end
    end
  end

  @doc """
  Each reason's setting as the service answered it, in the app's order:
  `%{reason, include, list, push}`, `include` nil for a reason without one. A
  setting the answer lacks reads as the service's default: everyone, listed
  and pushed.
  """
  def notification_view(settings) when is_map(settings) do
    for {reason, _key, _filterable?} <- @notification_settings,
        do: Map.put(notification_setting(settings, reason), :reason, reason)
  end

  @doc "One reason's setting: `%{include, list, push}`."
  def notification_setting(settings, reason) do
    {_reason, key, filterable?} = List.keyfind(@notification_settings, reason, 0)
    current = if is_map(settings[key]), do: settings[key], else: %{}

    %{
      include: if(filterable?, do: string_or(current["include"], "all")),
      list: boolean_or(current["list"], true),
      push: boolean_or(current["push"], true)
    }
  end

  @doc """
  What `notification.putPreferencesV2` takes to give `reason` the setting
  `setting` (`%{include, list, push}`): that reason alone, under its key.
  """
  def notification_input(reason, setting) do
    {_reason, key, filterable?} = List.keyfind(@notification_settings, reason, 0)
    value = %{"list" => setting.list, "push" => setting.push}
    value = if filterable?, do: Map.put(value, "include", setting.include), else: value
    %{key => value}
  end

  defp string_or(value, _default) when is_binary(value), do: value
  defp string_or(_value, default), do: default

  defp boolean_or(value, _default) when is_boolean(value), do: value
  defp boolean_or(_value, default), do: default

  # --- the preferences of a type, and which of them the app reads ---

  defp of_type?(pref, type), do: is_map(pref) and pref["$type"] == Network.type(type)

  defp last_valid(preferences, type, also \\ fn _ -> true end) do
    preferences
    |> Enum.reverse()
    |> Enum.find(&(valid?(type, &1) and also.(&1)))
  end

  # Whether a preference is valid by its lexicon, as far as the fields read
  # here go; the library reads only valid ones.
  defp valid?(type, pref) do
    of_type?(pref, type) and valid_fields?(type, pref)
  end

  defp valid_fields?(:feed_view_pref, pref) do
    is_binary(pref["feed"]) and
      Enum.all?(
        ~w(hideReplies hideRepliesByUnfollowed hideReposts hideQuotePosts),
        &optional?(pref[&1], :boolean)
      ) and optional?(pref["hideRepliesByLikeCount"], :integer)
  end

  defp valid_fields?(:thread_view_pref, pref), do: optional?(pref["sort"], :string)

  defp valid_fields?(:interests_pref, pref),
    do: is_list(pref["tags"]) and Enum.all?(pref["tags"], &is_binary/1)

  defp valid_fields?(:adult_content_pref, pref), do: is_boolean(pref["enabled"])

  defp valid_fields?(:post_interaction_settings_pref, pref),
    do:
      optional?(pref["threadgateAllowRules"], :list) and
        optional?(pref["postgateEmbeddingRules"], :list)

  defp valid_fields?(:verification_prefs, pref), do: optional?(pref["hideBadges"], :boolean)

  defp valid_fields?(:declared_age_pref, _pref), do: true

  defp optional?(nil, _type), do: true
  defp optional?(value, :boolean), do: is_boolean(value)
  defp optional?(value, :integer), do: is_integer(value)
  defp optional?(value, :string), do: is_binary(value)
  defp optional?(value, :list), do: is_list(value)

  defp invalid(field, message), do: {:error, {:invalid_argument, field, message}}
end
