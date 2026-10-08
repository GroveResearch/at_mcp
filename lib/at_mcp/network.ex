defmodule AtMcp.Network do
  @moduledoc """
  Which AT Protocol network AtMcp talks to, declared once.

  AT Protocol is not one network. `app.bsky.*` and `town.delve.*` are two
  application namespaces on the same protocol. Shared application endpoints use
  the same suffix; network-specific endpoints, such as membership, need their
  own capability checks. The namespace is therefore a
  single value — but it has to be a value, because an NSID is not only a name in
  a schema. It is the last segment of every XRPC method path, the collection a
  record is written to, and the `$type` on a facet or an embed. Hardcoding it
  anywhere hardcodes it everywhere.

  So one entry in `@networks` names a network, and every use derives from it:

      AtMcp.Network.collection(:post)     #=> "app.bsky.feed.post"
      AtMcp.Network.nsid("feed.getPosts") #=> "app.bsky.feed.getPosts"
      AtMcp.Network.post_limits()         #=> %{graphemes: 300, bytes: 3_000}
      AtMcp.Network.default_service()     #=> "https://bsky.social"

  Bluesky is the default, so an installation that configures no network talks to
  Bluesky.

  ## Configuration

      config :at_mcp, network: :delve

  or `AT_MCP_NETWORK=delve` in the environment. An unrecognized name raises rather
  than falling back, because a typo that kept talking to Bluesky would stay
  invisible until an agent posted to the wrong network.

  ## Where the limits come from

  The five schema differences between the namespaces include one that AtMcp
  enforces itself: `town.delve.feed.post` allows 100,000 graphemes and 500,000
  bytes where `app.bsky.feed.post` allows 300 and 3,000. Those numbers are read
  out of the lexicon files at compile time rather than transcribed here, so they
  cannot drift from the upstream declaration. The files are vendored under
  `priv/lexicons`, with a README beside them.

  ## What this does not cover

  `com.atproto.*` and `chat.bsky.*` are untouched by the rename, and are written
  as literals wherever they appear. That is correct: they are the same NSIDs on
  both networks.

  Writes derive from this module too. `AtMcp.ATProto` builds each record AtMcp
  writes and sends it with `com.atproto.repo.createRecord`, so the collection
  and the record's `$type` are this network's. Nothing in `lib/` calls
  `ProtoRune.Bsky`, whose records carry `app.bsky.*` compiled into the library.
  """

  # Each network is one namespace, the service a new account defaults to, and
  # its AppView authority and the directory its lexicons are vendored under.
  #
  # `pds.delve.town` is the delve network's PDS, per the deployment in the
  # `field-station` repository.
  @networks %{
    bluesky: %{
      namespace: "app.bsky",
      appview: "did:web:api.bsky.app#bsky_appview",
      appview_url: "https://api.bsky.app/xrpc",
      web_origin: "https://bsky.app",
      default_service: "https://bsky.social",
      lexicon_dir: "app/bsky",
      label: "Bluesky"
    },
    delve: %{
      namespace: "town.delve",
      appview: "did:web:api.delve.town#bsky_appview",
      appview_url: "https://api.delve.town/xrpc",
      web_origin: "https://delve.town",
      default_service: "https://pds.delve.town",
      lexicon_dir: "town/delve",
      label: "delve.town"
    }
  }

  @names Map.keys(@networks)

  # The record NSIDs AtMcp names. Each is a suffix within the namespace, so the
  # same table serves both networks and neither is written out twice.
  @collections %{
    post: "feed.post",
    like: "feed.like",
    repost: "feed.repost",
    follow: "graph.follow",
    block: "graph.block",
    profile: "actor.profile",
    generator: "feed.generator",
    list: "graph.list"
  }

  # The lexicon-defined types AtMcp reads off a record it did not write.
  @types %{
    mention_facet: "richtext.facet#mention",
    link_facet: "richtext.facet#link",
    tag_facet: "richtext.facet#tag",
    embed_record: "embed.record",
    embed_record_with_media: "embed.recordWithMedia",
    embed_images: "embed.images"
  }

  # Read at compile time so a release carries no runtime dependency on priv/.
  # The paths are named first so `@external_resource` can be set outside the
  # comprehension that reads them: a vendored lexicon changing must recompile
  # this module, or the numbers below become the transcription they replaced.
  @lexicon_paths Map.new(@networks, fn {name, network} ->
                   {name,
                    Path.expand(
                      Path.join([
                        __DIR__,
                        "..",
                        "..",
                        "priv",
                        "lexicons",
                        network.lexicon_dir,
                        "feed",
                        "post.json"
                      ])
                    )}
                 end)

  for {_name, path} <- @lexicon_paths do
    @external_resource path
  end

  @post_properties Map.new(@lexicon_paths, fn {name, path} ->
                     properties =
                       path
                       |> File.read!()
                       |> Jason.decode!()
                       |> get_in(["defs", "main", "record", "properties"])

                     {name, properties}
                   end)

  @limits Map.new(@post_properties, fn {name, properties} ->
            field = Map.fetch!(properties, "text")

            {name,
             %{
               graphemes: Map.fetch!(field, "maxGraphemes"),
               bytes: Map.fetch!(field, "maxLength")
             }}
          end)

  # How many images a post may embed and how large each may be, from the
  # network's `embed.images` lexicon.
  @image_lexicon_paths Map.new(@networks, fn {name, network} ->
                         {name,
                          Path.expand(
                            Path.join([
                              __DIR__,
                              "..",
                              "..",
                              "priv",
                              "lexicons",
                              network.lexicon_dir,
                              "embed",
                              "images.json"
                            ])
                          )}
                       end)

  for {_name, path} <- @image_lexicon_paths do
    @external_resource path
  end

  @image_limits Map.new(@image_lexicon_paths, fn {name, path} ->
                  defs = path |> File.read!() |> Jason.decode!() |> Map.fetch!("defs")

                  {name,
                   %{
                     count: get_in(defs, ["main", "properties", "images", "maxLength"]),
                     bytes: get_in(defs, ["image", "properties", "image", "maxSize"])
                   }}
                end)

  @language_limits Map.new(@post_properties, fn {name, properties} ->
                     {name, properties |> Map.fetch!("langs") |> Map.fetch!("maxLength")}
                   end)

  @doc """
  The configured network's name. Defaults to `:bluesky`.
  """
  @spec name() :: atom()
  def name do
    case Application.get_env(:at_mcp, :network, :bluesky) do
      name when name in @names ->
        name

      other ->
        raise ArgumentError,
              "unknown :at_mcp network #{inspect(other)}; known networks are #{inspect(@names)}"
    end
  end

  @doc "The service authority the home PDS forwards authenticated AppView calls to."
  def appview_service, do: @networks |> Map.fetch!(name()) |> Map.fetch!(:appview)

  @doc "The trusted AppView endpoint paired with this network's service authority."
  def appview_url, do: @networks |> Map.fetch!(name()) |> Map.fetch!(:appview_url)

  @doc false
  def direct_read?(method, session) do
    case Application.get_env(:at_mcp, :appview_reads, :proxy) do
      :proxy -> false
      :direct -> Map.has_key?(request_headers(method, session), "atproto-proxy")
      other -> raise ArgumentError, "unknown appview_reads mode #{inspect(other)}"
    end
  end

  @doc false
  def request_headers(method, session) do
    preferences = method in [nsid("actor.getPreferences"), nsid("actor.putPreferences")]
    home = URI.parse(ProtoRune.Session.service_url(session) || "").host
    hosted = home == URI.parse(default_service()).host

    # Preferences live on the PDS for Bluesky and town-hosted identities.
    # Delvetown's AppView stores them for external members (web clients.ts).
    if String.starts_with?(method, namespace() <> ".") and
         not (preferences and (name() == :bluesky or hosted)) do
      %{"atproto-proxy" => appview_service()}
    else
      %{}
    end
  end

  @doc "Every network AtMcp can be pointed at."
  @spec names() :: [atom()]
  def names, do: @names

  @doc """
  The configured network's application namespace, e.g. `"app.bsky"`.
  """
  @spec namespace() :: String.t()
  def namespace, do: @networks |> Map.fetch!(name()) |> Map.fetch!(:namespace)

  @doc """
  A full NSID from a suffix within the namespace.

      iex> AtMcp.Network.nsid("feed.getPosts")
      "app.bsky.feed.getPosts"
  """
  @spec nsid(String.t()) :: String.t()
  def nsid(suffix) when is_binary(suffix), do: namespace() <> "." <> suffix

  @doc """
  The collection a named record kind lives in.

      iex> AtMcp.Network.collection(:post)
      "app.bsky.feed.post"
  """
  @spec collection(atom()) :: String.t()
  def collection(kind) when is_map_key(@collections, kind),
    do: nsid(Map.fetch!(@collections, kind))

  @doc "Whether a collection names this record kind on any supported network."
  @spec collection?(String.t(), atom()) :: boolean()
  def collection?(collection, kind) when is_map_key(@collections, kind) do
    Enum.any?(@networks, fn {_name, network} ->
      collection == network.namespace <> "." <> Map.fetch!(@collections, kind)
    end)
  end

  @doc "A web permalink for a post on this network; the AT URI stays canonical."
  def post_url("at://" <> rest) do
    case String.split(rest, "/") do
      [repo, collection, rkey] when repo != "" and rkey != "" ->
        if collection == collection(:post) and
             (ProtoRune.Atproto.Identity.valid_did?(repo) or
                ProtoRune.Atproto.Identity.valid_handle?(repo)) and
             rkey not in [".", ".."] and Regex.match?(~r/\A[A-Za-z0-9._~:-]{1,512}\z/, rkey) and
             not String.contains?(rest, ["?", "#", " ", "\n"]) do
          origin = @networks |> Map.fetch!(name()) |> Map.fetch!(:web_origin)

          origin <>
            "/profile/" <>
            URI.encode(repo, &URI.char_unreserved?/1) <>
            "/post/" <> URI.encode(rkey, &URI.char_unreserved?/1)
        end

      _ ->
        nil
    end
  end

  def post_url(_), do: nil

  @doc "The collections AtMcp's inbound filter subscribes to."
  @spec inbound_collections() :: [String.t()]
  def inbound_collections, do: Enum.map([:post, :like, :repost], &collection/1)

  @doc """
  A lexicon-defined `$type` AtMcp matches on or writes: `:mention_facet`,
  `:link_facet`, `:tag_facet`, `:embed_record`, `:embed_record_with_media` or
  `:embed_images`.
  """
  @spec type(atom()) :: String.t()
  def type(kind) when is_map_key(@types, kind), do: nsid(Map.fetch!(@types, kind))

  @doc """
  The post record's text limits, read from this network's lexicon.

  Both bound the same field: `maxGraphemes` is what a person counts and
  `maxLength` is the UTF-8 byte length the service checks.
  """
  @spec post_limits() :: %{graphemes: pos_integer(), bytes: pos_integer()}
  def post_limits, do: Map.fetch!(@limits, name())

  @doc """
  How many images a post may embed and the most bytes each may have, read from
  this network's `embed.images` lexicon.
  """
  @spec post_image_limits() :: %{count: pos_integer(), bytes: pos_integer()}
  def post_image_limits, do: Map.fetch!(@image_limits, name())

  @doc "Maximum language tags on a post, read from this network's lexicon."
  @spec post_language_limit() :: non_neg_integer()
  def post_language_limit, do: Map.fetch!(@language_limits, name())

  @doc """
  The service a newly configured account defaults to.

  An account carries its own `service`; this is only what `at_mcp account add` and
  the stdio entry point assume when nobody said.
  """
  @spec default_service() :: String.t()
  def default_service, do: @networks |> Map.fetch!(name()) |> Map.fetch!(:default_service)

  @doc """
  What to call this network when telling somebody which one they are on.

  A host that receives an event has no other way to know: the namespace is a
  lexicon prefix, not a name a reader recognises, and an installation that told an
  inhabitant "on Bluesky" while it was on delve.town would be lying to it.
  """
  def label, do: @networks |> Map.fetch!(name()) |> Map.fetch!(:label)
end
