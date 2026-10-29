defmodule AtMcp.Interactions do
  @moduledoc """
  Who may reply to a post and who may quote it, what a post says about itself,
  and its link card: the arguments as a caller gives them, read into what
  `AtMcp.ATProto` builds records from.

  A thread's reply rule is a `feed.threadgate` record and a post's quote rule
  is a `feed.postgate` record. Each has the post's record key and sits in the
  same repository as the post. The app sets both rules in one dialog, so
  `set_post_interactions` sets both, and `post` can write them with the post.

  A reply rule is `nil` or `:everyone` (everyone may reply; `:everyone` is the
  argument `["everyone"]` said outright), `[]`
  (nobody may) or a list of `:mention`, `:following`, `:followers` and
  `{:list, uri}`. A quote rule is `:allowed` or `:disabled`.

  Everything here runs before a session is taken, so a refusal costs nothing
  and sends nothing. A refusal is `{:error, {:invalid_argument, path, message}}`,
  naming the argument the way the input schema's own refusals do.
  """

  # `feed.threadgate`'s `allow` holds at most five rules, `hiddenReplies` at
  # most 300 uris, and `feed.postgate`'s `detachedEmbeddingUris` at most 50.
  @max_rules 5
  @max_hidden 300
  @max_detached 50

  @doc "How many replies a threadgate can hide and quotes a postgate can detach."
  def limits,
    do: %{rules: @max_rules, hidden_replies: @max_hidden, detached_quotes: @max_detached}

  @reply_rules %{"mentioned" => :mention, "following" => :following, "followers" => :followers}

  @doc "The words `reply_rule` takes besides a list's AT URI and `\"everyone\"`."
  def reply_rule_words, do: Map.keys(@reply_rules) |> Enum.sort()

  @doc """
  A threadgate's `allow` as `reply_rule` words: `["everyone"]` when the gate
  sets no rule, `[]` for nobody, and a list's AT URI for a list rule. A rule
  this does not know, or a list rule that names no list, is given by its
  `$type`, so it reads as a rule that could not be read rather than as nobody.
  """
  def reply_rule_words(nil), do: ["everyone"]

  def reply_rule_words(%{"allow" => allow}) when is_list(allow) do
    words =
      Map.new(@reply_rules, fn {word, rule} -> {AtMcp.Network.type(rule_type(rule)), word} end)

    Enum.map(allow, fn rule ->
      type = rule["$type"]

      cond do
        type == AtMcp.Network.type(:list_rule) and is_binary(rule["list"]) -> rule["list"]
        Map.has_key?(words, type) -> Map.fetch!(words, type)
        is_binary(type) -> type
        true -> "unknown"
      end
    end)
  end

  def reply_rule_words(%{}), do: ["everyone"]

  defp rule_type(:mention), do: :mention_rule
  defp rule_type(:following), do: :following_rule
  defp rule_type(:followers), do: :follower_rule

  @doc "A postgate's quote rule now: `\"disabled\"` when it holds a disable rule."
  def quotes_word(%{"embeddingRules" => rules}) when is_list(rules) do
    if Enum.any?(rules, &(&1["$type"] == AtMcp.Network.type(:disable_rule))),
      do: "disabled",
      else: "allowed"
  end

  def quotes_word(_postgate), do: "allowed"

  @self_labels ["sexual", "nudity", "porn", "graphic-media"]

  @doc "The self-labels a post may carry: the values the app offers as content warnings."
  def self_labels, do: @self_labels

  @doc """
  Read a `reply_rule` argument. `nil` is everyone; a list is the rules, each a
  word from `reply_rule_words/0` or the AT URI of a list record.
  """
  def reply_rule(nil), do: {:ok, nil}
  # Said, not left out: a reply refuses it as it refuses any other rule.
  def reply_rule(["everyone"]), do: {:ok, :everyone}

  def reply_rule(rules) when is_list(rules) do
    rules
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {rule, i}, {:ok, acc} ->
      case reply_rule_entry(rule) do
        {:ok, rule} -> {:cont, {:ok, acc ++ [rule]}}
        {:error, message} -> {:halt, invalid("reply_rule/#{i}", message)}
      end
    end)
    |> case do
      # Kept in the order given, duplicates too, so an entry resolved later
      # (a list named by handle) is refused by its own index. The record
      # builder writes each rule once.
      {:ok, rules} ->
        if length(Enum.uniq(rules)) > @max_rules,
          do: invalid("reply_rule", "at most #{@max_rules} rules"),
          else: {:ok, rules}

      error ->
        error
    end
  end

  def reply_rule(_other), do: invalid("reply_rule", "must be a list")

  defp reply_rule_entry("at://" <> _ = uri) do
    case AtMcp.ATProto.parse_uri(uri) do
      {:ok, {_repo, collection, _rkey}} ->
        if AtMcp.Network.collection?(collection, :list),
          do: {:ok, {:list, uri}},
          else: {:error, "a list's AT URI names a graph.list record; #{uri} is a #{collection}"}

      _ ->
        {:error, "#{uri} is not an AT URI"}
    end
  end

  defp reply_rule_entry("everyone"),
    do: {:error, ~s("everyone" stands alone: ["everyone"] lets anyone reply)}

  defp reply_rule_entry(word) when is_map_key(@reply_rules, word),
    do: {:ok, Map.fetch!(@reply_rules, word)}

  defp reply_rule_entry(other),
    do:
      {:error,
       "must be #{Enum.join(reply_rule_words(), ", ")}, or a list's AT URI; got #{inspect(other)}"}

  @doc "Read a `quotes` argument: `allowed`, `disabled`, or nil when not given."
  def quotes(nil), do: {:ok, nil}
  def quotes("allowed"), do: {:ok, :allowed}
  def quotes("disabled"), do: {:ok, :disabled}
  def quotes(other), do: invalid("quotes", "must be allowed or disabled; got #{inspect(other)}")

  @doc "Read a `labels` argument: self-labels from `self_labels/0`, each once."
  def labels(nil), do: {:ok, nil}
  def labels([]), do: {:ok, nil}

  def labels(labels) when is_list(labels) do
    case Enum.find_index(labels, &(&1 not in @self_labels)) do
      nil ->
        {:ok, Enum.uniq(labels)}

      i ->
        invalid(
          "labels/#{i}",
          "must be one of #{Enum.join(@self_labels, ", ")}; got #{inspect(Enum.at(labels, i))}"
        )
    end
  end

  def labels(_other), do: invalid("labels", "must be a list")

  @doc """
  Read a `link` argument into a link card: `%{url, title, description, thumb}`.
  The url must be http or https. at_mcp does not fetch the page; the title and
  description are the caller's, empty when not given.
  """
  def link(nil), do: {:ok, nil}

  def link(%{} = link) do
    url = Map.get(link, :url)
    uri = if is_binary(url), do: URI.parse(url)

    cond do
      not is_binary(url) ->
        invalid("link/url", "is required: the page the card links to")

      uri.scheme not in ["http", "https"] or uri.host in [nil, ""] ->
        invalid("link/url", "must be an http or https URL; got #{inspect(url)}")

      not optional_string?(Map.get(link, :title)) ->
        invalid("link/title", "must be a string")

      not optional_string?(Map.get(link, :description)) ->
        invalid("link/description", "must be a string")

      true ->
        {:ok,
         %{
           url: url,
           title: Map.get(link, :title) || "",
           description: Map.get(link, :description) || "",
           thumb: Map.get(link, :thumb)
         }}
    end
  end

  def link(_other), do: invalid("link", "must be an object with url")

  defp optional_string?(value), do: is_nil(value) or is_binary(value)

  @doc """
  Read the options `post` and `reply` take beyond the text, before anything is
  sent. A reply cannot set who may reply: a thread's reply rule belongs to its
  first post, and a threadgate on a reply is never read. A post carries one
  kind of media, so images and a link card together are refused. `facets` is
  `:detect` (the default) or `:none`; anything else is refused.
  """
  def post_options(verb, opts) do
    with :ok <- no_reply_rule(verb, Keyword.get(opts, :reply_rule)),
         :ok <- facets(Keyword.get(opts, :facets)),
         # `:everyone` and `:allowed` are kept: said, they stand in for the
         # account's saved interaction settings, which a rule left out takes
         # (`AtMcp.Effects.ProtoRune.prepare_post/3`).
         {:ok, reply_rule} <- reply_rule(Keyword.get(opts, :reply_rule)),
         {:ok, quotes} <- quotes(Keyword.get(opts, :quotes)),
         {:ok, labels} <- labels(Keyword.get(opts, :labels)),
         {:ok, link} <- link(Keyword.get(opts, :link)),
         :ok <- one_media(Keyword.get(opts, :images), link) do
      {:ok,
       opts
       |> Keyword.merge(reply_rule: reply_rule, quotes: quotes, labels: labels, link: link)
       # An option given as nothing is not given. `reply_rule: []` is nobody,
       # which is not nil: it stays.
       |> Enum.reject(fn {key, value} ->
         key in [:reply_rule, :quotes, :labels, :link] and is_nil(value)
       end)}
    end
  end

  defp no_reply_rule(:reply, rule) when not is_nil(rule),
    do:
      invalid(
        "reply_rule",
        "applies to a thread's first post; a reply cannot set who may reply to the thread"
      )

  defp no_reply_rule(_verb, _rule), do: :ok

  defp one_media(images, link) when is_list(images) and images != [] and not is_nil(link),
    do: invalid("link", "a post carries images or a link card, not both")

  defp one_media(_images, _link), do: :ok

  # Whether AtMcp detects mentions, links and tags in the text (`:detect`, the
  # default) or publishes the text with no facets (`:none`), for a caller whose
  # text is not its own: a program that quotes untrusted text would otherwise
  # mention, and notify, whoever that text names.
  defp facets(value) when value in [nil, :detect, :none], do: :ok

  defp facets(other),
    do: invalid("facets", "must be :detect or :none; got #{inspect(other)}")

  @doc """
  Whether `repo`, the authority of an AT URI, is the session's own account,
  by DID or by the handle the session holds.
  """
  def own_repo?(session, repo) do
    did = Map.get(session, :did) || Map.get(session, "did")
    handle = Map.get(session, :handle) || Map.get(session, "handle")
    is_binary(repo) and (repo == did or (is_binary(handle) and repo == handle))
  end

  @doc """
  The `hiddenReplies` a threadgate holds after hiding (`true`) or unhiding
  `uri`. Refused when hiding would take it past the lexicon's limit.
  """
  def hidden_replies(current, uri, true), do: add(current, uri, @max_hidden, "uri", "replies")
  def hidden_replies(current, uri, false), do: {:ok, List.delete(current, uri)}

  @doc "The `detachedEmbeddingUris` a postgate holds after detaching or reattaching `uri`."
  def detached_quotes(current, uri, true), do: add(current, uri, @max_detached, "uri", "quotes")
  def detached_quotes(current, uri, false), do: {:ok, List.delete(current, uri)}

  defp add(current, uri, max, field, what) do
    cond do
      uri in current -> {:ok, current}
      length(current) >= max -> invalid(field, "a post can have at most #{max} #{what} set apart")
      true -> {:ok, current ++ [uri]}
    end
  end

  defp invalid(path, message), do: {:error, {:invalid_argument, path, message}}
end
