defmodule AtMcp.Effects.Backend do
  @moduledoc """
  Bluesky capability boundary. Real ProtoRune or a test mock.

  Every verb returns `{:ok, summary_map} | {:error, reason}` — never a raw
  session inspect dump.

  A backend owns both halves of that result. Summaries are built with
  `AtMcp.Summary`, so a tool describes what it returns. Failures are
  `AtMcp.Effects.Failure` values, because only the backend knows whether its
  service refused the action, refused the credential, or left the outcome
  unknown — and AtMcp's write policy, session recovery and tool results are
  written against those kinds rather than against any client library's
  error terms. (`AtMcp.Effects.Failure` has a fourth, `:unreadable`, which is not a
  classification of a service's error: a backend returns it when its own
  parsing cannot read an answer the service did give.) A reason of any other shape is read as indeterminate, which for
  a write means an unknown outcome that AtMcp will not retry.
  """

  @optional_callbacks requires_credentials?: 0

  @type state :: term()
  @type summary :: map()
  @type reason :: AtMcp.Effects.Failure.t() | term()

  @doc """
  Whether this backend needs credentials before it can log in.

  A real service does; a mock with a preloaded session does not. AtMcp asks
  rather than checking which module it holds, so adding a backend never means
  editing a condition in the policy layer.
  """
  @callback requires_credentials?() :: boolean()

  @callback login(opts :: keyword()) :: {:ok, state()} | {:error, reason()}

  @doc """
  Read the records a post refers to, before the write quota is charged.

  A reply or a quote is a strong reference — a uri and the record's CID — and
  the CID has to be read from the record. Doing that inside the write means a
  parent that cannot be read costs a quota slot for a write that never
  left the machine, and AtMcp does not refund a write whose outcome is unknown.
  So AtMcp asks for the references first, with a session but no slot taken, and
  a backend that cannot read one answers `{:error, {:referenced_record_unreadable, uri}}`.

  The returned options feed `prepare_post/3`; no post has been sent.
  """
  @callback resolve_references(state(), opts :: keyword()) ::
              {:ok, keyword()} | {:error, reason()}

  @doc """
  Resolve a handle or DID to the DID a follow, block, mute or unmute names,
  before the write quota is charged.

  The resolution is a read, and it fails for ordinary reasons: no account holds
  the handle, or the string is not a handle at all. Either way no write was
  sent, so AtMcp reports a refusal that costs nothing rather than a write whose
  outcome is unknown. A backend answers `{:error, {:handle_not_resolved, actor}}`
  when the service could not resolve the handle, and a `AtMcp.Effects.Failure`
  when the read itself failed. A DID resolves to itself.
  """
  @callback resolve_actor(state(), actor :: String.t()) :: {:ok, String.t()} | {:error, reason()}
  @callback refresh(state()) :: {:ok, state()} | {:error, reason()}

  @callback get_membership(state()) :: {:ok, summary()} | {:error, reason()}
  @optional_callbacks get_membership: 1

  # Reads
  @callback list_notifications(state(), opts :: keyword()) ::
              {:ok, summary()} | {:error, reason()}
  @callback get_unread_count(state()) :: {:ok, summary()} | {:error, reason()}
  @callback get_thread(state(), uri :: String.t()) :: {:ok, summary()} | {:error, reason()}
  @callback get_thread_chain(state(), uri :: String.t(), opts :: keyword()) ::
              {:ok, summary()} | {:error, reason()}
  @callback get_timeline(state(), opts :: keyword()) :: {:ok, summary()} | {:error, reason()}
  @callback get_author_feed(state(), actor :: String.t(), opts :: keyword()) ::
              {:ok, summary()} | {:error, reason()}
  @callback get_profile(state(), actor :: String.t()) :: {:ok, summary()} | {:error, reason()}
  @callback get_profiles(state(), actors :: [String.t()]) :: {:ok, summary()} | {:error, reason()}
  @callback get_posts(state(), uris :: [String.t()]) :: {:ok, summary()} | {:error, reason()}
  @callback search_posts(state(), query :: String.t(), opts :: keyword()) ::
              {:ok, summary()} | {:error, reason()}
  @callback search_actors(state(), query :: String.t(), opts :: keyword()) ::
              {:ok, summary()} | {:error, reason()}

  # Graph reads. An account that can follow and block but cannot read its own
  # graph does not know who its audience is.
  @callback get_followers(state(), actor :: String.t(), opts :: keyword()) ::
              {:ok, summary()} | {:error, reason()}
  @callback get_follows(state(), actor :: String.t(), opts :: keyword()) ::
              {:ok, summary()} | {:error, reason()}
  @callback get_known_followers(state(), actor :: String.t(), opts :: keyword()) ::
              {:ok, summary()} | {:error, reason()}
  @callback get_suggested_follows(state(), actor :: String.t()) ::
              {:ok, summary()} | {:error, reason()}
  @callback get_blocks(state(), opts :: keyword()) :: {:ok, summary()} | {:error, reason()}
  @callback get_mutes(state(), opts :: keyword()) :: {:ok, summary()} | {:error, reason()}
  @callback get_relationships(state(), actor :: String.t(), others :: [String.t()]) ::
              {:ok, summary()} | {:error, reason()}

  # Engagement reads: the effect of the account's own writing.
  @callback get_likes(state(), uri :: String.t(), opts :: keyword()) ::
              {:ok, summary()} | {:error, reason()}
  @callback get_reposted_by(state(), uri :: String.t(), opts :: keyword()) ::
              {:ok, summary()} | {:error, reason()}
  @callback get_quotes(state(), uri :: String.t(), opts :: keyword()) ::
              {:ok, summary()} | {:error, reason()}
  @callback get_actor_likes(state(), actor :: String.t(), opts :: keyword()) ::
              {:ok, summary()} | {:error, reason()}

  # Feeds other than the home timeline.
  @callback get_feed(state(), feed :: String.t(), opts :: keyword()) ::
              {:ok, summary()} | {:error, reason()}
  @callback get_list_feed(state(), list :: String.t(), opts :: keyword()) ::
              {:ok, summary()} | {:error, reason()}

  @doc """
  Build a complete post before its quota reservation and dispatch mark.

  Resolve references and rich text and prepare any blobs here. No post record
  may be created in this phase. A preparation failure says the post was not
  sent, even if a blob was uploaded; it costs no publishing quota. Return a
  refused failure for local build errors. The prepared value is passed to
  `post/3` unchanged and reused after an explicit authentication refusal.
  """
  @callback prepare_post(state(), String.t(), keyword()) :: {:ok, term()} | {:error, reason()}

  # Writes (counted against the write quota, except update_seen)

  # One verb writes posts. A reply is a post with a parent, a quote post is a
  # post with an embed, and a picture is a post with another — the record has
  # one shape and `opts` says which of its optional fields this post uses:
  # `:reply` (a parent AT URI), `:quote` (an AT URI), `:images`
  # (`[%{data: binary, mime_type: String.t(), alt: String.t()}]`) and `:langs`.
  # AtMcp.Effects still exposes `reply` as its own function, because the tool
  # surface names the affordance; a backend does not need to.
  @callback post(state(), text :: String.t(), prepared :: term()) ::
              {:ok, summary()} | {:error, reason()}
  @callback like(state(), uri :: String.t(), cid :: String.t()) ::
              {:ok, summary()} | {:error, reason()}
  @callback unlike(state(), like_uri :: String.t()) :: {:ok, summary()} | {:error, reason()}
  @callback repost(state(), uri :: String.t(), cid :: String.t()) ::
              {:ok, summary()} | {:error, reason()}
  @callback unrepost(state(), repost_uri :: String.t()) :: {:ok, summary()} | {:error, reason()}
  # `follow`, `block`, `mute` and `unmute` take the DID `resolve_actor/2` returned.
  @callback follow(state(), did :: String.t()) :: {:ok, summary()} | {:error, reason()}
  @callback unfollow(state(), follow_uri :: String.t()) :: {:ok, summary()} | {:error, reason()}
  @callback block(state(), did :: String.t()) :: {:ok, summary()} | {:error, reason()}
  @callback unblock(state(), block_uri :: String.t()) :: {:ok, summary()} | {:error, reason()}
  @callback mute(state(), did :: String.t()) :: {:ok, summary()} | {:error, reason()}
  @callback unmute(state(), did :: String.t()) :: {:ok, summary()} | {:error, reason()}
  @callback delete_post(state(), post_uri :: String.t()) :: {:ok, summary()} | {:error, reason()}
  @callback update_profile(state(), updates :: keyword()) :: {:ok, summary()} | {:error, reason()}
  @callback update_seen(state(), seen_at :: DateTime.t()) :: {:ok, summary()} | {:error, reason()}
end
