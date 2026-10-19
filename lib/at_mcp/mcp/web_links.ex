defmodule AtMcp.MCP.WebLinks do
  @moduledoc """
  A web link pasted where a tool takes an AT URI, a handle or a DID.

  A person shares a post, an account, a list, a feed or a starter pack by its
  web link (`AtMcp.WebLink`), so an agent is handed one. Each argument below
  takes such a link in place of the value it names: the link is read back to
  the record's AT URI, or to the account's DID, its handle resolved to a DID,
  before the tool runs. The result says what each link was read as, in a
  `resolved` line and in the structured content. A link to something the
  argument does not take is refused before anything is sent. Any other value
  is passed on untouched.
  """

  alias AtMcp.WebLink

  @post [:post]
  @account [:profile]
  @list [:list]
  @feed [:feed]
  @pack [:starter_pack]
  @embeddable [:post, :feed, :list, :starter_pack]
  # A like, repost, follow or block record, or a list block: the AT URI of a
  # record no page shows, which no web link names.
  @record []

  @takes %{
    "get_author_feed" => %{"actor" => @account},
    "get_thread" => %{"uri" => @post},
    "get_thread_chain" => %{"uri" => @post, "before" => @post},
    "get_posts" => %{"uris" => @post},
    "get_post_images" => %{"uri" => @post},
    "get_profile" => %{"actor" => @account},
    "get_profiles" => %{"actors" => @account},
    "search_posts" => %{
      "author" => @account,
      "mentions" => @account,
      "exclude_authors" => @account,
      "exclude_mentions" => @account,
      "embeds" => @embeddable,
      "exclude_embeds" => @embeddable,
      "reply_to" => @post,
      "thread_root" => @post
    },
    "get_followers" => %{"actor" => @account},
    "get_follows" => %{"actor" => @account},
    "get_known_followers" => %{"actor" => @account},
    "get_suggested_follows" => %{"actor" => @account},
    "get_relationships" => %{"actor" => @account, "others" => @account},
    "get_likes" => %{"uri" => @post},
    "get_reposted_by" => %{"uri" => @post},
    "get_quotes" => %{"uri" => @post},
    "get_actor_likes" => %{"actor" => @account},
    "get_feed" => %{"feed" => @feed},
    "get_feed_info" => %{"uris" => @feed},
    "get_actor_feeds" => %{"actor" => @account},
    "get_list_feed" => %{"list" => @list},
    "get_list" => %{"uri" => @list},
    "get_lists" => %{"actor" => @account, "contains" => @account},
    "get_starter_pack" => %{"uri" => @pack},
    "get_starter_packs" => %{"actor" => @account, "contains" => @account},
    "update_list" => %{"uri" => @list},
    "delete_list" => %{"uri" => @list},
    "add_to_list" => %{"list" => @list ++ @pack, "actor" => @account},
    "remove_from_list" => %{"list" => @list ++ @pack, "actor" => @account},
    "create_starter_pack" => %{"actors" => @account, "feeds" => @feed},
    "update_starter_pack" => %{"uri" => @pack, "feeds" => @feed},
    "delete_starter_pack" => %{"uri" => @pack},
    "set_list_opt_out" => %{"list" => @pack ++ @list},
    "set_preference" => %{"reply_rule" => @list},
    "set_label_visibility" => %{"labeler" => @account},
    "post" => %{"quote" => @embeddable, "reply_rule" => @list},
    "reply" => %{"uri" => @post, "quote" => @embeddable},
    "like" => %{"uri" => @post ++ @feed},
    "unlike" => %{"uri" => @record},
    "repost" => %{"uri" => @post},
    "unrepost" => %{"uri" => @record},
    "follow" => %{"actor" => @account},
    "unfollow" => %{"uri" => @record},
    "block" => %{"actor" => @account},
    "unblock" => %{"uri" => @record},
    "mute" => %{"actor" => @account},
    "unmute" => %{"actor" => @account},
    "delete_post" => %{"uri" => @post},
    "set_post_interactions" => %{"uri" => @post, "reply_rule" => @list},
    "hide_reply" => %{"uri" => @post},
    "unhide_reply" => %{"uri" => @post},
    "detach_quote" => %{"uri" => @post},
    "reattach_quote" => %{"uri" => @post},
    "save_feed" => %{"uri" => @feed ++ @list},
    "unsave_feed" => %{"uri" => @feed ++ @list},
    "feed_feedback" => %{"feed" => @feed, "uri" => @post},
    "subscribe_to_activity" => %{"actor" => @account},
    "report" => %{"subject" => @embeddable ++ @account, "labeler" => @account},
    "mute_list" => %{"uri" => @list},
    "unmute_list" => %{"uri" => @list},
    "block_list" => %{"uri" => @list},
    "unblock_list" => %{"uri" => @list},
    "get_labelers" => %{"actors" => @account},
    "subscribe_labeler" => %{"actor" => @account},
    "unsubscribe_labeler" => %{"actor" => @account},
    "pin_post" => %{"uri" => @post},
    "mute_thread" => %{"uri" => @post},
    "unmute_thread" => %{"uri" => @post},
    "bookmark" => %{"uri" => @post},
    "unbookmark" => %{"uri" => @post},
    "get_record" => %{"uri" => @embeddable}
  }

  @doc "The arguments of each tool that take a web link, and what each may name."
  def takes, do: @takes

  @doc """
  The arguments with each web link read back to what it names, and what each
  was read as; or the error to refuse the call with. `effects` is called only
  when a link names an account by handle.
  """
  def resolve(tool, arguments, effects) when is_map(arguments) do
    takes = Map.get(@takes, tool, %{})

    Enum.reduce_while(arguments, {:ok, arguments, []}, fn {key, value}, {:ok, args, resolved} ->
      case Map.fetch(takes, to_string(key)) do
        {:ok, kinds} ->
          case value(to_string(key), value, kinds, effects) do
            {:ok, value, notes} -> {:cont, {:ok, Map.put(args, key, value), resolved ++ notes}}
            error -> {:halt, error}
          end

        :error ->
          {:cont, {:ok, args, resolved}}
      end
    end)
  end

  def resolve(_tool, arguments, _effects), do: {:ok, arguments, []}

  defp value(path, values, kinds, effects) when is_list(values) do
    values
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, [], []}, fn {value, i}, {:ok, done, notes} ->
      case value("#{path}/#{i}", value, kinds, effects) do
        {:ok, value, more} -> {:cont, {:ok, done ++ [value], notes ++ more}}
        error -> {:halt, error}
      end
    end)
  end

  defp value(path, link, kinds, effects) when is_binary(link) do
    case WebLink.parse(link) do
      :not_a_link ->
        {:ok, link, []}

      {:error, why} ->
        refuse(path, "#{link} #{why}")

      {:ok, target} ->
        kind = elem(target, 0)

        if kind in kinds do
          with {:ok, did} <- AtMcp.Effects.actor_did(effects(effects), elem(target, 1)) do
            value =
              if kind == :profile,
                do: did,
                else: "at://#{did}/#{WebLink.collection(kind)}/#{elem(target, 2)}"

            {:ok, value, [%{argument: path, link: link, value: value}]}
          end
        else
          refuse(path, "#{link} is a link to #{WebLink.word(kind)}; this takes #{wanted(kinds)}")
        end
    end
  end

  defp value(_path, value, _kinds, _effects), do: {:ok, value, []}

  defp effects(%{effects: effects}), do: effects
  defp effects(effects), do: effects

  defp wanted([]), do: "the AT URI of a record no web link names"

  defp wanted(kinds) do
    words = Enum.map(kinds, &WebLink.word/1)

    case words do
      [one] -> one
      words -> Enum.join(Enum.drop(words, -1), ", ") <> " or " <> List.last(words)
    end
  end

  defp refuse(path, message), do: {:error, {:invalid_argument, path, message}}

  @doc "The result, saying what each web link given to it was read as."
  def note(result, []), do: result

  def note(result, resolved) do
    AtMcp.MCP.Input.note(
      result,
      :resolved,
      resolved,
      Enum.map_join(resolved, "\n", &"resolved: #{&1.argument} #{&1.link} is #{&1.value}")
    )
  end
end
