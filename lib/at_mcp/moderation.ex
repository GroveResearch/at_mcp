defmodule AtMcp.Moderation do
  @moduledoc """
  The account's moderation settings that live in its preferences, and the
  report reasons the app offers. Each preference is read the way the app reads
  it and changed the way the app's library changes it (`Agent` in
  `@atproto/api` at 9f66a7e, packages/api/src/agent.ts): `getPreferences` for
  reading, `addMutedWord`, `updateMutedWord`, `removeMutedWord`, `addLabeler`,
  `removeLabeler` and `setContentLabelPref` for changing. The last valid
  preference of a type is the one that counts, a change starts from it, every
  other preference of that type is dropped, the changed one goes last, and
  every preference of another type is kept exactly as stored.

    * Muted words (`mutedWordsPref`). The app's muted words dialog (social-app
      src/components/dialogs/MutedWords.tsx at 485405a) mutes a word in post
      text and tags (`targets` `["tag", "content"]`) or in tags only
      (`["tag"]`), for everyone or only accounts the account does not follow
      (`actorTarget` `exclude-following`), for 24 hours, 7 days, 30 days or
      for ever (`expiresAt`). The app hides a post that matches on the device;
      the service does not, so at_mcp's reads return it.
    * Labelers (`labelersPref`): the moderation services the account
      subscribes to, besides the network's own (`AtMcp.Network.moderation_service/0`),
      which every account has. The app takes labels only from these, and lets
      an account subscribe to at most 20 counting the network's own
      (`MAX_LABELERS` in social-app src/lib/constants.ts).
    * Content labels (`contentLabelPref`): what the app does with a post or
      account that carries a label: show it, warn (blur it behind a warning)
      or hide it. The four labels of the app's moderation screen apply to
      every labeler's (`porn`, `sexual`, `graphic-media`, `nudity`; the app
      shows them only while adult content is on); a label one labeler defines
      is set for that labeler, on its page in the app.

  Left out, for a reason: hidden posts (`hiddenPostsPref`). The app's "Hide
  post for me" keeps the posts on the device, not in the preferences
  (social-app src/state/preferences/hidden-posts.tsx and moderation-opts.tsx
  at 485405a, "TODO move this into pds-stored prefs"), and reads nothing
  from `hiddenPostsPref`; a post written there would be hidden nowhere.
  """

  alias AtMcp.Network

  @doc """
  The moderation settings `get_preferences` reports: the muted words, the
  labelers the app takes labels from, and what the app does with each label
  of its moderation screen.
  """
  def view(preferences) when is_list(preferences) do
    {global, _by_labeler} = label_settings(preferences)

    %{
      muted_words: Enum.map(muted_words(preferences), &word_view/1),
      labelers: labelers(preferences),
      content_labels: Map.new(global_labels(), &{&1, visibility_word(Map.fetch!(global, &1))})
    }
  end

  # --- muted words ---

  @durations %{"24h" => 1, "7d" => 7, "30d" => 30, "forever" => nil}

  @doc "The durations `mute_word` takes, as the app's dialog offers them."
  def durations, do: ["24h", "7d", "30d", "forever"]

  # `mutedWord.value`: at most 10,000 bytes and 1,000 graphemes.
  @word_bytes 10_000
  @word_graphemes 1_000

  @doc """
  A muted word's value as the app's library stores it (`sanitizeMutedWordValue`
  in @atproto/api's util.ts): trimmed, without one leading `#` (unless it is
  the start of an emoji), and without the first run of line breaks and
  invisible characters.
  """
  def sanitize_word(value) when is_binary(value) do
    value
    |> String.trim()
    |> then(&Regex.replace(~r/^#(?!\x{FE0F})/u, &1, ""))
    |> then(
      &Regex.replace(~r/[\r\n\x{00AD}\x{2060}\x{200D}\x{200C}\x{200B}]+/u, &1, "", global: false)
    )
  end

  @doc """
  Read a `mute_word` request: `value`, and in `opts` `tags_only`, `targets`,
  `duration`, `expires_at` and `only_non_followed`, nil when not given.
  `targets` (the stored targets, any the lexicon allows) is the other way to
  say `tags_only`, and `expires_at` (a datetime) the other way to say
  `duration`, so a word `unmute_word` returned can be muted again exactly as
  it was. Answers `{:ok, word}` (`%{value, targets, actor_target, days,
  expires_at}`, `days` and `expires_at` nil for ever), or the first invalid
  argument.
  """
  def word_request(value, opts) do
    tags_only = Keyword.get(opts, :tags_only)
    targets = Keyword.get(opts, :targets)
    only_non_followed = Keyword.get(opts, :only_non_followed)
    expires_at = Keyword.get(opts, :expires_at)
    duration = Keyword.get(opts, :duration)

    with {:ok, value} <- word_value(value),
         :ok <- optional_boolean(tags_only, "tags_only"),
         :ok <- optional_boolean(only_non_followed, "only_non_followed"),
         :ok <- one_of(tags_only, targets, "targets", "tags_only"),
         :ok <- one_of(duration, expires_at, "expires_at", "duration"),
         {:ok, targets} <- targets(targets, tags_only),
         {:ok, days} <- duration(duration || "forever"),
         {:ok, expires_at} <- expires_at(expires_at) do
      {:ok,
       %{
         value: value,
         targets: targets,
         actor_target: if(only_non_followed == true, do: "exclude-following", else: "all"),
         days: days,
         expires_at: expires_at
       }}
    end
  end

  defp one_of(nil, _other, _field, _first), do: :ok
  defp one_of(_given, nil, _field, _first), do: :ok

  defp one_of(_given, _other, field, first),
    do: invalid(field, "give #{field} or #{first}, not both")

  # As the app's dialog writes them, or as given: `mutedWordTarget`s, each at
  # most 640 bytes and 64 graphemes, at least one, as the dialog requires.
  defp targets(nil, true), do: {:ok, ["tag"]}
  defp targets(nil, _tags_only), do: {:ok, ["tag", "content"]}

  defp targets(targets, _tags_only) when is_list(targets) and targets != [] do
    if Enum.all?(targets, &(is_binary(&1) and byte_size(&1) <= 640 and String.length(&1) <= 64)),
      do: {:ok, Enum.uniq(targets)},
      else: invalid("targets", "must be targets such as content and tag")
  end

  defp targets(_targets, _tags_only),
    do: invalid("targets", "must be a non-empty list, such as [\"tag\", \"content\"]")

  defp expires_at(nil), do: {:ok, nil}

  defp expires_at(at) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, _datetime, _offset} -> {:ok, at}
      _ -> invalid("expires_at", "must be an ISO 8601 datetime, such as 2026-10-20T12:00:00.000Z")
    end
  end

  defp expires_at(_at), do: invalid("expires_at", "must be an ISO 8601 datetime")

  @doc "Read an `unmute_word` request: the word's value, sanitized."
  def unmute_request(value), do: word_value(value)

  defp word_value(value) when is_binary(value) do
    sanitized = if String.valid?(value), do: sanitize_word(value), else: ""

    cond do
      not String.valid?(value) ->
        invalid("value", "must be valid UTF-8")

      sanitized == "" ->
        invalid("value", "must be a word, tag or phrase; this is empty once trimmed")

      byte_size(sanitized) > @word_bytes ->
        invalid("value", "may be at most #{@word_bytes} bytes")

      String.length(sanitized) > @word_graphemes ->
        invalid("value", "may be at most #{@word_graphemes} characters")

      true ->
        {:ok, sanitized}
    end
  end

  defp word_value(_value), do: invalid("value", "must be a string")

  defp duration(duration) when is_map_key(@durations, duration),
    do: {:ok, Map.fetch!(@durations, duration)}

  defp duration(_duration), do: invalid("duration", "must be #{Enum.join(durations(), ", ")}")

  defp optional_boolean(nil, _field), do: :ok
  defp optional_boolean(value, _field) when is_boolean(value), do: :ok
  defp optional_boolean(_value, field), do: invalid(field, "must be true or false")

  @doc """
  The muted words as the app reads them: the last valid `mutedWordsPref`'s,
  each `actorTarget` read as `all` when it has none.
  """
  def muted_words(preferences) do
    case last_valid(preferences, :muted_words_pref) do
      nil -> []
      pref -> Enum.map(pref["items"], &Map.put_new(&1, "actorTarget", "all"))
    end
  end

  @doc "One muted word as `get_preferences` reports it."
  def word_view(word, now \\ DateTime.utc_now()) do
    targets = word["targets"] || []
    expires = word["expiresAt"]

    %{
      id: word["id"],
      value: word["value"],
      targets: targets,
      tags_only: "content" not in targets,
      only_non_followed: word["actorTarget"] == "exclude-following",
      expires_at: expires,
      expired: is_binary(expires) and expired?(expires, now)
    }
  end

  defp expired?(expires, now) do
    case DateTime.from_iso8601(expires) do
      {:ok, at, _offset} -> DateTime.compare(at, now) == :lt
      _ -> false
    end
  end

  @doc """
  The preferences with `word` muted, and what the change was: `{updated,
  previous, now}`, `updated` nil when the word is already muted exactly as
  asked. A word not yet muted is added as `addMutedWord` adds it; one muted
  already (the same value, ignoring case, as the app matches words) is changed
  as `updateMutedWord` changes it, keeping its id, so it is not muted twice.
  Either way the library then gives every muted word without an id one.
  `previous` is the matching words before, `now` after, both as stored.
  """
  def mute_word(preferences, word, now \\ DateTime.utc_now()) do
    pref = last_valid(preferences, :muted_words_pref)
    items = if pref, do: pref["items"], else: []
    expires = Map.get(word, :expires_at) || expires_at(word.days, now)
    {matching, _rest} = Enum.split_with(items, &same_word?(&1, word.value))

    {items, changed} =
      case matching do
        [] ->
          new =
            %{
              "id" => tid(),
              "value" => word.value,
              "targets" => word.targets,
              "actorTarget" => word.actor_target
            }
            |> put_present("expiresAt", expires)

          {items ++ [new], [new]}

        _found ->
          rebuilt =
            Enum.map(items, fn item ->
              if same_word?(item, word.value) do
                %{
                  "id" => item["id"] || tid(),
                  "value" => sanitize_word(item["value"]) |> blank_or(item["value"]),
                  "targets" => word.targets,
                  "actorTarget" => word.actor_target
                }
                |> put_present("expiresAt", expires)
              else
                item
              end
            end)

          {rebuilt, Enum.filter(rebuilt, &same_word?(&1, word.value))}
      end

    if matching != [] and same_words?(matching, changed) do
      {nil, matching, matching}
    else
      pref =
        Map.put(pref || %{"$type" => Network.type(:muted_words_pref)}, "items", with_ids(items))

      updated = replace(preferences, &of_type?(&1, :muted_words_pref), pref)
      {updated, matching, Enum.filter(pref["items"], &same_word?(&1, word.value))}
    end
  end

  # A word already muted as asked: the same targets, the same accounts and the
  # same expiry, with an id. A duration counts from now, so a word muted for
  # one is renewed, as the app renews one.
  defp same_words?(before, now) do
    length(before) == length(now) and
      Enum.zip(before, now)
      |> Enum.all?(fn {old, new} ->
        is_binary(old["id"]) and old["targets"] == new["targets"] and
          Map.get(old, "actorTarget", "all") == new["actorTarget"] and
          old["expiresAt"] == new["expiresAt"]
      end)
  end

  @doc """
  The preferences with every muted word of `value` removed, as
  `removeMutedWord` removes each, and the words removed: `{updated, removed}`,
  `updated` nil when no muted word has that value. The library gives every
  muted word left without an id one.
  """
  def unmute_word(preferences, value) do
    case last_valid(preferences, :muted_words_pref) do
      nil ->
        {nil, []}

      pref ->
        {removed, kept} = Enum.split_with(pref["items"], &same_word?(&1, value))

        if removed == [] do
          {nil, []}
        else
          pref = Map.put(pref, "items", with_ids(kept))
          {replace(preferences, &of_type?(&1, :muted_words_pref), pref), removed}
        end
    end
  end

  # The app matches a muted word without regard to case (`matchMuteWords` in
  # @atproto/api's moderation/mutewords.ts lowercases both sides).
  defp same_word?(item, value),
    do: is_binary(item["value"]) and String.downcase(item["value"]) == String.downcase(value)

  # `migrateLegacyMutedWordsItems`: a muted word without an id gets one.
  defp with_ids(items), do: Enum.map(items, &Map.put(&1, "id", &1["id"] || tid()))

  defp blank_or("", fallback), do: fallback
  defp blank_or(value, _fallback), do: value

  # As the app's dialog writes it: now plus whole days, in milliseconds.
  defp expires_at(nil, _now), do: nil

  defp expires_at(days, now) do
    now
    |> DateTime.add(days * 86_400, :second)
    |> DateTime.truncate(:millisecond)
    |> DateTime.to_iso8601()
  end

  defp tid, do: hd(AtMcp.ATProto.tids(1))

  # --- labelers ---

  # The most labelers the app lets an account have, counting the network's
  # own.
  @max_labelers 20

  @doc "The most labelers an account can have in the app, the network's own included."
  def max_labelers, do: @max_labelers

  @doc """
  The labelers the app takes labels from: the network's own moderation
  service, then those the last valid `labelersPref` names.
  """
  def labelers(preferences), do: app_labelers() ++ subscribed(preferences)

  @doc "The labelers the account subscribes to, by DID, as stored."
  def subscribed(preferences) do
    case last_valid(preferences, :labelers_pref) do
      nil -> []
      pref -> Enum.map(pref["labelers"], & &1["did"])
    end
  end

  @doc "The labelers every account of this network has, whether it subscribes or not."
  def app_labelers, do: List.wrap(Network.moderation_service())

  @doc """
  The preferences with `did` subscribed to (`addLabeler`) or not
  (`removeLabeler`), or nil when it already stands so.
  """
  def subscribe(preferences, did, subscribe?) do
    pref =
      last_valid(preferences, :labelers_pref) ||
        %{"$type" => Network.type(:labelers_pref), "labelers" => []}

    present? = Enum.any?(pref["labelers"], &(&1["did"] == did))

    cond do
      subscribe? == present? ->
        nil

      subscribe? ->
        replace(
          preferences,
          &of_type?(&1, :labelers_pref),
          Map.put(pref, "labelers", pref["labelers"] ++ [%{"did" => did}])
        )

      true ->
        replace(
          preferences,
          &of_type?(&1, :labelers_pref),
          Map.put(pref, "labelers", Enum.reject(pref["labelers"], &(&1["did"] == did)))
        )
    end
  end

  # --- content labels ---

  # The labels of the app's moderation screen and what each is set to by
  # default (`DEFAULT_LABEL_SETTINGS` in @atproto/api's moderation/const/labels.ts).
  @global_labels %{
    "porn" => "hide",
    "sexual" => "warn",
    "graphic-media" => "warn",
    "nudity" => "ignore"
  }

  # The library writes each of these labels a second time under its old name
  # and reads the old name over the new (`setContentLabelPref` and
  # `remapLegacyLabels`).
  @legacy %{"graphic-media" => "gore", "porn" => "nsfw", "sexual" => "suggestive"}

  @visibilities %{"show" => "ignore", "warn" => "warn", "hide" => "hide"}

  @doc "The labels of the app's moderation screen, which apply to every labeler's labels."
  def global_labels, do: @global_labels |> Map.keys() |> Enum.sort()

  @doc "What `set_label_visibility` takes: show, warn or hide."
  def visibilities, do: ["show", "warn", "hide"]

  @doc "The value `contentLabelPref.visibility` stores for a visibility (`show` is `ignore`)."
  def stored_visibility(visibility), do: Map.fetch(@visibilities, visibility)

  @doc "A stored visibility in the words the tools use: `ignore`, and the legacy `show`, are show."
  def visibility_word(stored) when stored in ["ignore", "show"], do: "show"
  def visibility_word(stored), do: stored

  @doc """
  The label settings as the app reads them: `{global, by_labeler}`, `global`
  a map from each label to its stored visibility over the defaults, and
  `by_labeler` a map from each labeler the app takes labels from to the
  labels set for it. A setting for a labeler the account does not subscribe
  to is not read, as the app does not read it.
  """
  def label_settings(preferences) do
    labelers = labelers(preferences)

    {global, by_labeler} =
      preferences
      |> Enum.filter(&valid?(:content_label_pref, &1))
      |> Enum.reduce({@global_labels, Map.new(labelers, &{&1, %{}})}, fn pref, {global, by} ->
        visibility = if pref["visibility"] == "show", do: "ignore", else: pref["visibility"]

        case pref["labelerDid"] do
          nil ->
            {Map.put(global, pref["label"], visibility), by}

          did ->
            if Map.has_key?(by, did),
              do: {global, put_in(by, [did, pref["label"]], visibility)},
              else: {global, by}
        end
      end)

    remapped =
      Enum.reduce(@legacy, global, fn {new, old}, acc ->
        if Map.has_key?(global, old), do: Map.put(acc, new, global[old]), else: acc
      end)

    {remapped, by_labeler}
  end

  @doc """
  What the app does with `label` (from `labeler`, nil for the moderation
  screen's) as the preferences stand, given the label's default.
  """
  def label_visibility(preferences, label, labeler, default) do
    {global, by_labeler} = label_settings(preferences)

    case labeler do
      nil -> Map.get(global, label, default)
      did -> get_in(by_labeler, [did, label]) || default
    end
  end

  @doc """
  The preferences with `label` (for `labeler`, nil for every labeler's) set
  to `visibility` as stored, as `setContentLabelPref` sets it: the last valid
  preference for that label and labeler is kept and changed, and, for a
  label with an old name, that name is written too.
  """
  def set_label(preferences, label, labeler, visibility) do
    pref =
      find_label_pref(preferences, label, labeler) ||
        put_present(
          %{"$type" => Network.type(:content_label_pref), "label" => label},
          "labelerDid",
          labeler
        )

    pref = Map.put(pref, "visibility", visibility)

    updated =
      Enum.reject(preferences, &label_pref?(&1, label, labeler)) ++ [pref]

    case labeler == nil && Map.get(@legacy, label) do
      old when is_binary(old) ->
        legacy =
          (find_label_pref(preferences, old, nil) ||
             %{"$type" => Network.type(:content_label_pref), "label" => old})
          |> Map.put("visibility", visibility)

        Enum.reject(updated, &label_pref?(&1, old, nil)) ++ [legacy]

      _ ->
        updated
    end
  end

  defp find_label_pref(preferences, label, labeler) do
    preferences
    |> Enum.filter(&valid?(:content_label_pref, &1))
    |> Enum.reverse()
    |> Enum.find(&(&1["label"] == label and &1["labelerDid"] == labeler))
  end

  defp label_pref?(pref, label, labeler),
    do:
      of_type?(pref, :content_label_pref) and pref["label"] == label and
        pref["labelerDid"] == labeler

  # --- a labeler's labels, as its page in the app lists them ---

  # The global labels the app lets an account configure (`configurable` in
  # @atproto/api's moderation/const/labels.ts); `!hide`, `!warn` and
  # `!no-unauthenticated` are not.
  @configurable_global ~w(porn sexual nudity graphic-media gore)

  @doc """
  The labels a labeler's page in the app lists, in order (social-app
  src/screens/Profile/Sections/Labels.tsx at 485405a): each of its
  `labelValues` once, looked up as `lookupLabelValueDefinition` looks it up
  (src/lib/moderation.ts) among its own definitions that pass the lexicon's
  `validateLabelValueDefinition` (`interpretLabelValueDefinitions` in
  @atproto/api's moderation/util.ts), unless it starts with `!`, and
  otherwise among the global labels, keeping those the app lets an account
  configure. Each is `{:custom, definition}`, set for that labeler, or
  `{:global, label}`, which the app sets in its moderation screen instead.
  """
  def labeler_labels(view) when is_map(view) do
    policies = if is_map(view["policies"]), do: view["policies"], else: %{}
    definitions = Enum.filter(List.wrap(policies["labelValueDefinitions"]), &valid_definition?/1)

    policies["labelValues"]
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
    |> Enum.flat_map(fn value ->
      custom =
        if String.starts_with?(value, "!"),
          do: nil,
          else: Enum.find(definitions, &(&1["identifier"] == value))

      cond do
        custom -> [{:custom, custom}]
        value in @configurable_global -> [{:global, value}]
        true -> []
      end
    end)
  end

  # `com.atproto.label.defs#labelValueDefinition`, as the lexicon validates it.
  defp valid_definition?(%{} = d) do
    string?(d["identifier"], 100, 100) and is_binary(d["severity"]) and is_binary(d["blurs"]) and
      (is_nil(d["defaultSetting"]) or is_binary(d["defaultSetting"])) and
      (is_nil(d["adultOnly"]) or is_boolean(d["adultOnly"])) and is_list(d["locales"]) and
      Enum.all?(d["locales"], fn locale ->
        is_map(locale) and is_binary(locale["lang"]) and string?(locale["name"], 640, 64) and
          string?(locale["description"], 100_000, 10_000)
      end)
  end

  defp valid_definition?(_definition), do: false

  defp string?(value, bytes, graphemes),
    do: is_binary(value) and byte_size(value) <= bytes and String.length(value) <= graphemes

  @doc """
  What a labeler's label is set to unless the account sets it: its
  `defaultSetting` when that is `hide` or `ignore`, otherwise `warn`
  (`interpretLabelValueDefinition`).
  """
  def default_setting(%{"defaultSetting" => setting}) when setting in ["hide", "ignore"],
    do: setting

  def default_setting(_definition), do: "warn"

  @doc "Whether the app offers `warn` for a label: one that blurs or warns at all."
  def can_warn?(definition),
    do: not (definition["blurs"] == "none" and definition["severity"] == "none")

  @doc """
  A labeler's label setting as its page in the app shows it
  (`LabelerLabelPreference` in social-app's LabelPreference.tsx): `hide` for
  an adult-only label while adult content is off, `show` for `warn` on a
  label that neither blurs nor warns, otherwise the setting, in the tools'
  words.
  """
  def shown_setting(stored, definition, adult?) do
    cond do
      definition["adultOnly"] == true and not adult? -> "hide"
      stored == "warn" and not can_warn?(definition) -> "show"
      true -> visibility_word(stored)
    end
  end

  # --- reports ---

  # The reasons the app's report dialog offers, in its order (`useReportOptions`
  # in social-app src/components/moderation/ReportDialog/utils at 485405a),
  # each by its `tools.ozone.report.defs` token.
  @reasons [
    {"misleading_spam", "MisleadingSpam"},
    {"misleading_scam", "MisleadingScam"},
    {"misleading_bot", "MisleadingBot"},
    {"misleading_impersonation", "MisleadingImpersonation"},
    {"misleading_elections", "MisleadingElections"},
    {"misleading_other", "MisleadingOther"},
    {"sexual_unlabeled", "SexualUnlabeled"},
    {"sexual_abuse_content", "SexualAbuseContent"},
    {"sexual_ncii", "SexualNCII"},
    {"sexual_deepfake", "SexualDeepfake"},
    {"sexual_animal", "SexualAnimal"},
    {"sexual_other", "SexualOther"},
    {"harassment_troll", "HarassmentTroll"},
    {"harassment_targeted", "HarassmentTargeted"},
    {"harassment_hate_speech", "HarassmentHateSpeech"},
    {"harassment_doxxing", "HarassmentDoxxing"},
    {"harassment_other", "HarassmentOther"},
    {"violence_animal", "ViolenceAnimal"},
    {"violence_threats", "ViolenceThreats"},
    {"violence_graphic_content", "ViolenceGraphicContent"},
    {"violence_glorification", "ViolenceGlorification"},
    {"violence_extremist_content", "ViolenceExtremistContent"},
    {"violence_trafficking", "ViolenceTrafficking"},
    {"violence_other", "ViolenceOther"},
    {"child_safety_csam", "ChildSafetyCSAM"},
    {"child_safety_groom", "ChildSafetyGroom"},
    {"child_safety_privacy", "ChildSafetyPrivacy"},
    {"child_safety_harassment", "ChildSafetyHarassment"},
    {"child_safety_other", "ChildSafetyOther"},
    {"self_harm_content", "SelfHarmContent"},
    {"self_harm_ed", "SelfHarmED"},
    {"self_harm_stunts", "SelfHarmStunts"},
    {"self_harm_substances", "SelfHarmSubstances"},
    {"self_harm_other", "SelfHarmOther"},
    {"rule_site_security", "RuleSiteSecurity"},
    {"rule_prohibited_sales", "RuleProhibitedSales"},
    {"rule_ban_evasion", "RuleBanEvasion"},
    {"rule_other", "RuleOther"},
    {"other", "Other"}
  ]

  # The lexicon's first reasons, each read as the finer reason the app sends
  # for it (`OLD_TO_NEW_REASONS_MAP` in the dialog's const.ts).
  @short %{
    "spam" => "misleading_spam",
    "violation" => "rule_other",
    "misleading" => "misleading_other",
    "sexual" => "sexual_unlabeled",
    "rude" => "harassment_other"
  }

  # Each finer reason's first-version reason (`NEW_TO_OLD_REASONS_MAP`), sent
  # instead to a service that declares it takes the first and not the finer.
  @older %{
    "other" => "Other",
    "misleading_spam" => "Spam",
    "harassment" => "Rude",
    "misleading" => "Misleading",
    "sexual" => "Sexual",
    "violence" => "Violation",
    "child_safety" => "Violation",
    "rule" => "Violation",
    "self_harm" => "Violation"
  }

  # Reasons and subjects the app sends to the network's own moderation
  # service alone (`BSKY_LABELER_ONLY_REPORT_REASONS`).
  @own_service_only ~w(child_safety_csam child_safety_groom child_safety_other violence_extremist_content)

  @doc "The reasons `report` takes: the app's, then the lexicon's first ones."
  def reasons, do: Enum.map(@reasons, &elem(&1, 0)) ++ Map.keys(@short)

  @doc "The finer reason a reason name stands for, or an invalid argument."
  def reason(name) when is_binary(name) do
    name = Map.get(@short, name, name)

    if List.keymember?(@reasons, name, 0),
      do: {:ok, name},
      else:
        invalid(
          "reason",
          "must be one of the reasons the app offers: #{Enum.join(Enum.map(@reasons, &elem(&1, 0)), ", ")}; or spam, violation, misleading, sexual or rude"
        )
  end

  def reason(_name), do: invalid("reason", "must be a string")

  @doc "Whether the app sends a reason to the network's own moderation service alone."
  def own_service_only?(reason), do: reason in @own_service_only

  @doc "The `tools.ozone.report.defs` token of a reason."
  def reason_type(reason) do
    {_name, token} = List.keyfind(@reasons, reason, 0)
    "tools.ozone.report.defs#reason" <> token
  end

  @doc "The `com.atproto.moderation.defs` token the app falls back to for a reason."
  def older_reason_type(reason) do
    key =
      cond do
        Map.has_key?(@older, reason) -> reason
        true -> reason |> String.split("_") |> fallback_key()
      end

    "com.atproto.moderation.defs#reason" <> Map.fetch!(@older, key)
  end

  defp fallback_key(["misleading" | _]), do: "misleading"
  defp fallback_key(["sexual" | _]), do: "sexual"
  defp fallback_key(["harassment" | _]), do: "harassment"
  defp fallback_key(["violence" | _]), do: "violence"
  defp fallback_key(["child", "safety" | _]), do: "child_safety"
  defp fallback_key(["self", "harm" | _]), do: "self_harm"
  defp fallback_key(["rule" | _]), do: "rule"

  @doc """
  The reason type the app sends a service that declares `reason_types` (nil
  when it declares none): the finer one, unless the service takes only the
  first-version one. Nil when the service takes neither.
  """
  def reason_type_for(reason, reason_types) do
    finer = reason_type(reason)
    older = older_reason_type(reason)

    cond do
      not is_list(reason_types) -> finer
      finer in reason_types -> finer
      older in reason_types -> older
      true -> nil
    end
  end

  # --- the preferences of a type, and which of them the app reads ---

  defp of_type?(pref, type), do: is_map(pref) and pref["$type"] == Network.type(type)

  defp replace(preferences, drop?, pref),
    do: Enum.reject(preferences, &(is_map(&1) and drop?.(&1))) ++ [pref]

  defp last_valid(preferences, type) do
    preferences |> Enum.reverse() |> Enum.find(&valid?(type, &1))
  end

  defp valid?(type, pref), do: of_type?(pref, type) and valid_fields?(type, pref)

  defp valid_fields?(:muted_words_pref, pref),
    do: is_list(pref["items"]) and Enum.all?(pref["items"], &muted_word?/1)

  defp valid_fields?(:labelers_pref, pref),
    do:
      is_list(pref["labelers"]) and
        Enum.all?(pref["labelers"], &(is_map(&1) and is_binary(&1["did"])))

  defp valid_fields?(:content_label_pref, pref),
    do:
      is_binary(pref["label"]) and is_binary(pref["visibility"]) and
        (is_nil(pref["labelerDid"]) or is_binary(pref["labelerDid"]))

  defp muted_word?(word),
    do:
      is_map(word) and is_binary(word["value"]) and is_list(word["targets"]) and
        Enum.all?(word["targets"], &is_binary/1) and optional_string?(word["id"]) and
        optional_string?(word["actorTarget"]) and optional_string?(word["expiresAt"])

  defp optional_string?(value), do: is_nil(value) or is_binary(value)

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp invalid(field, message), do: {:error, {:invalid_argument, field, message}}
end
