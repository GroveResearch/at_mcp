defmodule AtMcp.WebLink do
  @moduledoc """
  The web link a person sees and shares for a post, an account, a list, a
  custom feed or a starter pack, and the way back from one to its AT URI.

  The links are built as the app's share and copy-link actions build them, on
  the configured network's web origin (`AtMcp.Network.web_origin/0`), in
  bluesky-social/social-app at 4ba2e7a4134b5a362172549856b8bbdde8b4b480:

    * an account: `/profile/<handle>`, or its DID when the handle is
      `handle.invalid` (`makeProfileLink`, src/lib/routes/links.ts, which the
      profile menu's share uses);
    * a post: `/profile/<author handle>/post/<rkey>`, the author named the same
      way (`makeProfileLink(post.author, 'post', rkey)` in
      src/components/PostControls/ShareMenu/index.tsx);
    * a list: `/profile/<creator DID>/lists/<rkey>`
      (src/screens/ProfileList/components/MoreOptionsMenu.tsx);
    * a custom feed: `/profile/<creator DID>/feed/<rkey>`, the feed's route in
      src/state/queries/feed.ts, which its header's share uses;
    * a starter pack: `/start/<creator DID>/<rkey>` (`makeStarterPackLink`,
      which src/screens/StarterPack/StarterPackScreen.tsx shares, before the
      app shortens it).

  A labeler has no page of its own: the app shows it on its account's profile,
  so its link is the account's.

  The AT URI stays what every tool takes. A web link given to a tool is read
  back by `parse/1`, which knows the app's routes for each of these (a starter
  pack also at `/starter-pack/<name>/<rkey>`, its page).
  """

  alias AtMcp.Network

  @doc "An account's link: by its handle when it has a valid one, else by its DID."
  def profile(handle, did) do
    case name(handle, did) do
      nil -> nil
      name -> Network.web_origin() <> "/profile/" <> encode(name)
    end
  end

  @doc """
  The link of the record an AT URI names, when it is a post, list, feed or
  starter pack. `handle` names a post's author when known.
  """
  def record(uri, handle \\ nil)

  def record("at://" <> _ = uri, handle) do
    with {:ok, {repo, kind, rkey}} <- parts(uri) do
      origin = Network.web_origin()

      case kind do
        :post -> "#{origin}/profile/#{encode(name(handle, repo))}/post/#{encode(rkey)}"
        :list -> "#{origin}/profile/#{encode(repo)}/lists/#{encode(rkey)}"
        :generator -> "#{origin}/profile/#{encode(repo)}/feed/#{encode(rkey)}"
        :starter_pack -> "#{origin}/start/#{encode(repo)}/#{encode(rkey)}"
      end
    else
      _ -> nil
    end
  end

  def record(_uri, _handle), do: nil

  @kinds [:post, :list, :generator, :starter_pack]

  # The repository, kind and rkey of an AT URI of one of the kinds that have
  # a page; anything else, including a URI with a query or a fragment, is not.
  defp parts("at://" <> rest) do
    with [repo, collection, rkey] <- String.split(rest, "/"),
         true <- did?(repo) or valid_handle?(repo),
         true <- rkey?(rkey),
         kind when not is_nil(kind) <-
           Enum.find(@kinds, &(collection == Network.collection(&1))) do
      {:ok, {repo, kind, rkey}}
    else
      _ -> :error
    end
  end

  defp rkey?(rkey),
    do: rkey not in [".", ".."] and Regex.match?(~r/\A[A-Za-z0-9._~:-]{1,512}\z/, rkey)

  # An account as the app names it in a link: by its handle, unless that is
  # missing or `handle.invalid`, and then by its DID (or by whatever handle
  # the AT URI itself names it by).
  defp name(handle, repo) do
    cond do
      handle?(handle) -> handle
      did?(repo) or handle?(repo) -> repo
      true -> nil
    end
  end

  defp handle?(handle),
    do: is_binary(handle) and handle != "handle.invalid" and valid_handle?(handle)

  # The handle and DID syntax of the AT Protocol specification. A handle's
  # label may be one character (`a.test`).
  defp valid_handle?(handle),
    do:
      byte_size(handle) <= 253 and
        Regex.match?(
          ~r/\A([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\z/,
          handle
        )

  defp did?(did),
    do: is_binary(did) and Regex.match?(~r/\Adid:[a-z]+:[a-zA-Z0-9._:%-]*[a-zA-Z0-9._-]\z/, did)

  defp encode(segment), do: URI.encode(segment, &URI.char_unreserved?/1)

  @doc """
  What a web link names: `{:ok, {:profile, name}}`, or `{:ok, {kind, name,
  rkey}}` where kind is `:post`, `:list`, `:feed` or `:starter_pack` and name
  is a handle or a DID. `:not_a_link` for a string that is not an http(s) URL,
  so it is passed on unchanged; `{:error, message}` for a link that names
  none of these on this network.
  """
  def parse(value) when is_binary(value) do
    case URI.new(String.trim(value)) do
      {:ok, %URI{scheme: scheme, host: host} = uri}
      when scheme in ["http", "https"] and is_binary(host) ->
        if String.downcase(host) == URI.parse(Network.web_origin()).host,
          do: route(uri),
          else: {:error, "is a link to #{host}, not to #{Network.web_origin()}"}

      _ ->
        :not_a_link
    end
  end

  def parse(_value), do: :not_a_link

  defp route(%URI{path: path}) do
    segments =
      (path || "")
      |> String.split("/", trim: true)
      |> Enum.map(&URI.decode/1)

    case segments do
      ["profile", name] -> named({:profile, name})
      ["profile", name, "post", rkey] -> named({:post, name, rkey})
      ["profile", name, "lists", rkey] -> named({:list, name, rkey})
      ["profile", name, "feed", rkey] -> named({:feed, name, rkey})
      ["start", name, rkey] -> named({:starter_pack, name, rkey})
      ["starter-pack", name, rkey] -> named({:starter_pack, name, rkey})
      _ -> {:error, "is not a link to a post, account, list, feed or starter pack"}
    end
  end

  defp named(target) do
    name = elem(target, 1)
    rkey = if tuple_size(target) == 3, do: elem(target, 2)

    cond do
      not (did?(name) or valid_handle?(String.trim_leading(name, "@"))) ->
        {:error, "does not name an account by handle or DID"}

      is_binary(rkey) and not rkey?(rkey) ->
        {:error, "does not name a record"}

      true ->
        {:ok, put_elem(target, 1, String.trim_leading(name, "@"))}
    end
  end

  @doc "The collection a parsed link's kind lives in."
  def collection(:feed), do: Network.collection(:generator)
  def collection(kind), do: Network.collection(kind)

  @doc "What to call a kind in a sentence."
  def word(:profile), do: "an account"
  def word(:post), do: "a post"
  def word(:list), do: "a list"
  def word(:feed), do: "a feed"
  def word(:starter_pack), do: "a starter pack"
end
