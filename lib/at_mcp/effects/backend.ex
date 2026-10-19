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

  @doc """
  A page of notification groups (`notification.getGroupedNotifications`),
  each hydrated from the response's related views. `opts` carries `:feed`.
  """
  @callback get_grouped_notifications(state(), opts :: keyword()) ::
              {:ok, summary()} | {:error, reason()}
  @callback get_thread(state(), uri :: String.t()) :: {:ok, summary()} | {:error, reason()}
  @callback get_thread_chain(state(), uri :: String.t(), opts :: keyword()) ::
              {:ok, summary()} | {:error, reason()}
  @callback get_timeline(state(), opts :: keyword()) :: {:ok, summary()} | {:error, reason()}
  @callback get_author_feed(state(), actor :: String.t(), opts :: keyword()) ::
              {:ok, summary()} | {:error, reason()}
  @callback get_profile(state(), actor :: String.t()) :: {:ok, summary()} | {:error, reason()}
  @callback get_profiles(state(), actors :: [String.t()]) :: {:ok, summary()} | {:error, reason()}
  @callback get_posts(state(), uris :: [String.t()]) :: {:ok, summary()} | {:error, reason()}
  @callback search_posts(state(), query :: String.t() | nil, opts :: keyword()) ::
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
  @callback get_suggested_feeds(state(), opts :: keyword()) ::
              {:ok, summary()} | {:error, reason()}
  @callback get_list_feed(state(), list :: String.t(), opts :: keyword()) ::
              {:ok, summary()} | {:error, reason()}

  # Feeds and discovery. `suffix` names the method within the namespace,
  # chosen by `AtMcp.Effects` from the place in the app the caller named.
  @callback get_feed_info(state(), uris :: [String.t()]) :: {:ok, summary()} | {:error, reason()}
  @callback get_actor_feeds(state(), actor :: String.t(), opts :: keyword()) ::
              {:ok, summary()} | {:error, reason()}
  @callback search_feeds(state(), query :: String.t() | nil, opts :: keyword()) ::
              {:ok, summary()} | {:error, reason()}
  @callback get_suggested_accounts(state(), suffix :: String.t(), opts :: keyword()) ::
              {:ok, summary()} | {:error, reason()}
  @callback get_suggested_starter_packs(state(), suffix :: String.t(), opts :: keyword()) ::
              {:ok, summary()} | {:error, reason()}
  @callback get_trends(state(), suffix :: String.t(), opts :: keyword()) ::
              {:ok, summary()} | {:error, reason()}
  @callback get_record(state(), uri :: String.t()) :: {:ok, summary()} | {:error, reason()}
  @callback get_invite_codes(state()) :: {:ok, summary()} | {:error, reason()}

  @doc """
  Read the account's preferences and build them with one feed saved,
  re-pinned or removed: `{:save_feed, uri, pinned}` or `{:unsave_feed, uri,
  nil}`, `uri` in DID form. The result is passed to `write_preferences/2`;
  it carries `preferences: nil` when nothing would change.
  """
  @callback prepare_saved_feed(state(), request :: tuple()) :: {:ok, map()} | {:error, reason()}
  @callback write_preferences(state(), prepared :: map()) :: {:ok, summary()} | {:error, reason()}

  @doc """
  The account's settings as the app shows them: each preference kind of
  `AtMcp.Preferences`, the saved feeds, and the two declaration records.
  """
  @callback get_preferences(state()) :: {:ok, summary()} | {:error, reason()}

  @doc """
  Read what a `set_preference` request `{kind, changes}` (from
  `AtMcp.Preferences.request/2`) changes, and build the change: `{:unchanged,
  summary}` when the setting is already as asked, so nothing is written. A list
  in a reply rule named by a handle is resolved here. The result is passed to
  `write_preference/2`.
  """
  @callback prepare_preference(state(), request :: tuple()) ::
              {:ok, term()} | {:error, reason()}
  @callback write_preference(state(), prepared :: term()) :: {:ok, summary()} | {:error, reason()}

  @doc "The account's notification settings, one per reason."
  @callback get_notification_settings(state()) :: {:ok, summary()} | {:error, reason()}

  @doc """
  Read the notification settings and build the change of one reason's
  (`{reason, changes}`, from `AtMcp.Preferences.notification_request/2`), or
  `{:unchanged, summary}`. The result is passed to
  `write_notification_setting/2`.
  """
  @callback prepare_notification_setting(state(), request :: tuple()) ::
              {:ok, term()} | {:error, reason()}
  @callback write_notification_setting(state(), prepared :: term()) ::
              {:ok, summary()} | {:error, reason()}

  @doc """
  Read the account `did` and build the subscription `%{posts, replies}` to its
  activity, refusing one its own setting does not allow, or `{:unchanged,
  summary}`. The result is passed to `put_activity_subscription/2`.
  """
  @callback prepare_activity_subscription(state(), did :: String.t(), subscription :: map()) ::
              {:ok, term()} | {:error, reason()}
  @callback put_activity_subscription(state(), prepared :: term()) ::
              {:ok, summary()} | {:error, reason()}

  @doc "A page of the accounts this account is subscribed to."
  @callback get_activity_subscriptions(state(), opts :: keyword()) ::
              {:ok, summary()} | {:error, reason()}

  @doc """
  Read what a report names and build it: `request` is `%{subject, reason,
  details, labeler}`, `subject` `{:account, did}` or `{:record, uri,
  collection}` and `labeler` a DID. The labeler is read for the reports it
  takes and the preferences for whether this account has it, and a record
  for its CID. The result is passed to `send_report/2`.
  """
  @callback prepare_report(state(), request :: map()) :: {:ok, term()} | {:error, reason()}
  @callback send_report(state(), prepared :: term()) :: {:ok, summary()} | {:error, reason()}

  @doc """
  Read the preferences and build a moderation change of them
  (`AtMcp.Moderation`): `{:mute_word, word}`, `{:unmute_word, value}`,
  `{:subscribe_labeler, did}`, `{:unsubscribe_labeler, did}` or
  `{:set_label_visibility, label, visibility, labeler}`. Answers what
  `write_preferences/2` takes, or `{:unchanged, summary}`.
  """
  @callback prepare_moderation_preference(state(), request :: tuple()) ::
              {:ok, term()} | {:error, reason()}

  @doc """
  Read the list a `{:mute_list, uri}` or `{:unmute_list, uri}` names (DID
  form) and build the change, refusing a mute of a list that is not a
  moderation list. The result is passed to `mute_list/2`.
  """
  @callback prepare_list_mute(state(), request :: tuple()) :: {:ok, term()} | {:error, reason()}
  @callback mute_list(state(), prepared :: term()) :: {:ok, summary()} | {:error, reason()}

  @doc "A page of the moderation lists this account mutes (`\"muted\"`) or blocks (`\"blocked\"`)."
  @callback get_moderation_lists(state(), kind :: String.t(), opts :: keyword()) ::
              {:ok, summary()} | {:error, reason()}

  @doc """
  Labelers by DID in detail, with this account's settings for each; `nil`
  reads the labelers this account takes labels from.
  """
  @callback get_labelers(state(), dids :: [String.t()] | nil) ::
              {:ok, summary()} | {:error, reason()}

  @doc """
  Read the account's status record and build what replaces it: `{:live,
  %{url, minutes, title, description}}` or `:clear`. `write_status/2` writes it.
  """
  @callback prepare_status(state(), request :: term()) :: {:ok, map()} | {:error, reason()}
  @callback write_status(state(), prepared :: map()) :: {:ok, summary()} | {:error, reason()}

  @doc """
  Read the feed a feedback is about and build the interaction:
  `%{feed, item, event, kind, feed_context, req_id}`, the uris in DID form. A
  feed that takes no feedback is `{:error, {:invalid_argument, "feed", why}}`.
  `send_feed_feedback/2` sends it to the feed's own service.
  """
  @callback prepare_feed_feedback(state(), request :: map()) :: {:ok, map()} | {:error, reason()}
  @callback send_feed_feedback(state(), prepared :: map()) ::
              {:ok, summary()} | {:error, reason()}

  # Lists and starter packs. `opts` of a list read also carries `:purposes`,
  # the list purpose tokens to keep (`"curatelist"`, `"modlist"`), empty for all.
  @callback get_list(state(), uri :: String.t(), opts :: keyword()) ::
              {:ok, summary()} | {:error, reason()}
  @callback get_lists(state(), actor :: String.t(), opts :: keyword()) ::
              {:ok, summary()} | {:error, reason()}
  @callback get_lists_with_membership(state(), actor :: String.t(), opts :: keyword()) ::
              {:ok, summary()} | {:error, reason()}
  @callback get_starter_pack(state(), uri :: String.t()) :: {:ok, summary()} | {:error, reason()}
  @callback get_actor_starter_packs(state(), actor :: String.t(), opts :: keyword()) ::
              {:ok, summary()} | {:error, reason()}
  @callback search_starter_packs(state(), query :: String.t(), opts :: keyword()) ::
              {:ok, summary()} | {:error, reason()}
  @callback get_starter_packs_with_membership(state(), actor :: String.t(), opts :: keyword()) ::
              {:ok, summary()} | {:error, reason()}

  @doc """
  Read what a list or starter pack write keeps or removes, and build every
  record it sends, before anything is sent. `request` is one of:

    * `{:create_list, %{name, purpose, description, avatar}}`, `purpose` a
      token (`:curatelist`, `:modlist`), `avatar` `%{data, mime_type}` or nil
    * `{:update_list, uri, changes}` and `{:update_starter_pack, uri, changes}`,
      `changes` holding only the fields that change (`:name`, `:description`,
      `:avatar`, `:feeds`); `""` and `[]` remove a field
    * `{:delete_list, uri}` and `{:delete_starter_pack, uri}`
    * `{:add_to_list, uri, did}` and `{:remove_from_list, uri, did}`, `uri` a
      list or a starter pack
    * `{:create_starter_pack, %{name, description, actors, feeds}}`, `actors`
      DIDs
    * `{:set_list_opt_out, uri, opted_out}`, `uri` anyone's starter pack or
      its list

  Every `uri` but the last's is this account's, in DID form. A record the
  request cannot apply to (no list there, a starter pack's list given to
  `delete_list`, an account that is not on the list) is
  `{:invalid_argument, field, message}`. The result is passed to
  `write_list/2` unchanged.
  """
  @callback prepare_list_write(state(), request :: tuple()) :: {:ok, term()} | {:error, reason()}
  @callback write_list(state(), prepared :: term()) :: {:ok, summary()} | {:error, reason()}

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
  @callback repost(state(), uri :: String.t(), cid :: String.t()) ::
              {:ok, summary()} | {:error, reason()}
  # `follow`, `block`, `mute` and `unmute` take the DID `resolve_actor/2` returned.
  @callback follow(state(), did :: String.t()) :: {:ok, summary()} | {:error, reason()}
  @callback block(state(), did :: String.t()) :: {:ok, summary()} | {:error, reason()}

  @doc """
  This account's `:like`, `:repost`, `:follow` or `:block` record for
  `subject` (an AT URI, or for a follow or block a DID), as the AppView's
  viewer state names it and the account's repository confirms it, or nil. Read before a like, repost, follow or block
  is written, with no quota slot taken.
  """
  @callback viewer_record(state(), action :: atom(), subject :: String.t()) ::
              {:ok, String.t() | nil} | {:error, reason()}

  @doc """
  The one read before a `:like` or `:repost` of `subject` (an AT URI): `record`,
  this account's record of it as `viewer_record/3` names it, and `cid`, the
  subject's current CID as the AppView has it. Either is nil when the AppView
  has no view of the subject. No quota slot is taken.
  """
  @callback subject_view(state(), action :: :like | :repost, subject :: String.t()) ::
              {:ok, %{record: String.t() | nil, cid: String.t() | nil}} | {:error, reason()}

  @doc """
  Read what `:unlike`, `:unrepost`, `:unfollow` or `:unblock` of the record at
  `uri` deletes: that record, and the one `viewer_record/3` names for the same
  subject when it is another. Nothing is sent. `{:ok, {:unchanged, summary}}` when there is
  nothing to delete; otherwise the prepared value `undo/2` takes.
  """
  @callback prepare_undo(state(), action :: atom(), uri :: String.t()) ::
              {:ok, term()} | {:error, reason()}
  @callback undo(state(), prepared :: term()) :: {:ok, summary()} | {:error, reason()}
  @callback mute(state(), did :: String.t()) :: {:ok, summary()} | {:error, reason()}
  @callback unmute(state(), did :: String.t()) :: {:ok, summary()} | {:error, reason()}
  @callback delete_post(state(), post_uri :: String.t()) :: {:ok, summary()} | {:error, reason()}
  @callback update_profile(state(), updates :: keyword()) :: {:ok, summary()} | {:error, reason()}
  @callback update_seen(state(), seen_at :: DateTime.t()) :: {:ok, summary()} | {:error, reason()}

  @doc """
  Read one post before a write that names it: `%{uri, cid, root}`, where
  `root` is the uri of its thread's first post (its own uri when it is not a
  reply). Like `resolve_references/2`, it runs before anything is sent, and a
  post the service will not hand over is `{:referenced_record_unreadable, uri}`.
  """
  @callback resolve_post(state(), uri :: String.t()) :: {:ok, map()} | {:error, reason()}

  @doc """
  Build the profile record that pins the post at `uri`, or that pins nothing
  when `uri` is nil, keeping every other field. Nothing is sent; the result
  is passed to `pin/2` unchanged.
  """
  @callback prepare_pin(state(), uri :: String.t() | nil) :: {:ok, term()} | {:error, reason()}
  @callback pin(state(), prepared :: term()) :: {:ok, summary()} | {:error, reason()}

  # `mute_thread` and `unmute_thread` take the root uri `resolve_post/2` returned.
  @callback mute_thread(state(), root :: String.t()) :: {:ok, summary()} | {:error, reason()}
  @callback unmute_thread(state(), root :: String.t()) :: {:ok, summary()} | {:error, reason()}
  # `bookmark` takes the strong reference `resolve_post/2` returned.
  @callback bookmark(state(), ref :: map()) :: {:ok, summary()} | {:error, reason()}
  @callback unbookmark(state(), uri :: String.t()) :: {:ok, summary()} | {:error, reason()}
  @callback get_bookmarks(state(), opts :: keyword()) :: {:ok, summary()} | {:error, reason()}

  @callback get_drafts(state(), opts :: keyword()) :: {:ok, summary()} | {:error, reason()}

  @doc """
  The draft with this id as the service holds it, in the keys it is written
  with, so a save can keep what it does not change. A draft the account does
  not have is `{:error, {:invalid_argument, "id", message}}`.
  """
  @callback find_draft(state(), id :: String.t()) :: {:ok, map()} | {:error, reason()}

  @doc "Create a draft (`id` nil) or replace the one with this id. `draft` is `AtMcp.ATProto.draft/2`'s."
  @callback save_draft(state(), id :: String.t() | nil, draft :: map()) ::
              {:ok, summary()} | {:error, reason()}

  @doc "Delete a draft. `draft` is the one `find_draft/2` read, for the result to carry."
  @callback delete_draft(state(), id :: String.t(), draft :: map()) ::
              {:ok, summary()} | {:error, reason()}

  @doc """
  Build an edit to a post's gates, reading the records it changes so it keeps
  what it does not change: `{:interactions, uri, allow, quotes}`,
  `{:hide_reply, uri, hide?}` or `{:detach_quote, uri, detach?}`. Nothing is
  sent; an edit that cannot succeed (a post of another account's, a reply that
  is not one) is `{:error, {:invalid_argument, path, message}}`. The result is
  passed to `write_gates/2` unchanged.
  """
  @callback prepare_gates(state(), edit :: tuple()) :: {:ok, term()} | {:error, reason()}
  @callback write_gates(state(), prepared :: term()) :: {:ok, summary()} | {:error, reason()}

  @doc "The replies a thread read leaves out under `uri`, each saying why."
  @callback get_hidden_replies(state(), uri :: String.t()) :: {:ok, [map()]} | {:error, reason()}
end
