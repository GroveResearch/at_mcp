# Changelog

Each entry lists the changes in a release, newest first. Entries with an
**Upgrade** section need action before or after you upgrade, or before you
roll back. [operations.md](docs/operations.md#upgrade) describes the upgrade
itself.

## Unreleased

- The service no longer reads the header `x-kite-account-did`, and write
  tools no longer carry the annotation `kite/publicWrite`. Use
  `x-at-mcp-account-did` and `at_mcp/publicWrite`, which 0.2.16 introduced.
  Account descriptors now carry the new header only.

## 0.2.17

- `get_thread_chain` takes `include_replies`. Given `false`, at_mcp reads the
  ancestors and the requested post without fetching the replies under it.
  Left out, the tool returns the replies as before. When at_mcp leaves the
  replies out, it also skips the labelers that only those replies needed, so
  such a labeler failing can't break the chain's moderation or start a new
  login.
- The old header `x-kite-account-did` and annotation `kite/publicWrite` still
  work. 0.2.18 drops them.

### Upgrade

Upgrade the server before any client sends `include_replies`, because 0.2.16
doesn't know the argument. To roll back, move clients back first.

## 0.2.16

- `update_profile` takes `labels`, the account's self-labels, such as `bot`:
  - a list replaces the account's labels
  - `[]` removes them all
  - leaving `labels` out keeps them

  On Delvetown, at_mcp writes the labels to the account's Bluesky profile
  record, creating the record if needed, and leaves its other fields alone.
  When a call changes profile fields and labels together, at_mcp writes both
  in a single commit. It refuses more than 10 labels, an empty or repeated
  label, or a label longer than 128 bytes.
- The header for confirming an account's DID is `x-at-mcp-account-did`, and
  the annotation marking writes counted against the quota is
  `at_mcp/publicWrite`. The service still accepts the old header,
  `x-kite-account-did`, and write tools still carry the old annotation,
  `kite/publicWrite`.
- New grants start with `at_mcp-`. at_mcp looks up a grant by its hash, so
  existing grants keep working.
- at_mcp stops looking for data in the default folders of the project's
  earlier name.
- Security: a client's `logging/setLevel` request leaves the server's log
  level alone (GHSA-5vm6-rrjx-3496). ex_mcp moves to 1.7.3, which also clears
  cancellation records for unknown request ids (GHSA-22m7-hr37-pxg3).

### Upgrade

Move clients to the new header and annotation before 0.2.18. Upgrade an
installation older than 0.2.15 to 0.2.15 first.

## 0.2.15

- On Delvetown, `follow` and `block` write the same follow and block records
  Bluesky uses, for every account. `unfollow` and `unblock` remove those
  records along with any older Delvetown-only record for the same account, in
  a single commit. If the account changes in the meantime, they remove
  nothing.
- On Delvetown, `update_profile` saves the account's whole Delvetown profile,
  including fields left empty on purpose, and leaves the Bluesky profile
  alone.
- For embedding: `AtMcp.Effects.get_own_profile/1` reads the same profile
  `update_profile` edits.

### Upgrade

Embedding applications should move to the 0.2.15 Hex package before
switching their running release. Avoid rolling a Delvetown installation back
to 0.2.14. Its `update_profile` can change the Bluesky profile. Its `follow`
and `block` also depend on an account check dropped in 0.2.15.

## 0.2.14

- Each account on a service can have its own write limit, with
  `at_mcp-accounts write-quota`.
- On Delvetown, before writing a profile, a follow or a block, at_mcp asks
  Delvetown for the account's record types, and stops if Delvetown fails to
  answer.
- For embedding: `post` and `reply` accept `facets: :none`, which posts the
  text exactly as given, with no mentions, links or tags detected.
- A grouped notification for a reply, quote or mention carries the whole post.
- Reads ask for labels from every labeler the account subscribes to, as the
  app does.
- A post's text in a read marks escaped `<` and backslash characters with an
  explanatory line.

### Upgrade

Setting an account's own write limit adds a `write_quota` field to the
accounts file, and 0.2.13 refuses to start with it. Before rolling back, run
`at_mcp-accounts write-quota NAME --default` for each account with a limit,
then `reload`, while 0.2.14 is still installed.

## 0.2.13

- `update_seen` with a time in the future sends it as given, and adds a note
  giving the gap from now.

## 0.2.12

- A post's `text` adds each mention's DID in angle brackets after the mention,
  and escapes the author's own `<` and backslash characters. `raw_text` keeps
  the text exactly as written. A receiver matching on `text` should switch to
  `raw_text`.
- In the text for the model, at_mcp quotes every name, alt text and title,
  and fences each post's text, so a model can tell an author's words from
  at_mcp's.
  Quotation marks resembling `"` inside quoted text become `\u` escapes.
- A post's time is the time the app shows, with the author's own date beside
  it when more than a day earlier.
- New fields: `indexed_at`, `viewer.bookmarked`, `viewer.pinned`,
  `known_likers`, `muted_reposts`, `muted_quotes`, notification `created_at`
  and `subject_post_uri`, and more detail on link cards.

## 0.2.11

- `like` and `repost` take `cid` as optional. at_mcp looks it up when left
  out.
- A reply or quote of an unreadable record fails with the reason: not found,
  or the service's own refusal.
- at_mcp loads its input checks at startup, so the first call of a session
  avoids a validation timeout.

## 0.2.10

- Moderation tools: `report`, `mute_word`, `unmute_word`,
  `subscribe_labeler`, `unsubscribe_labeler`, `set_label_visibility`,
  `mute_list`, `unmute_list`, `block_list`, `unblock_list`,
  `get_moderation_lists` and `get_labelers`.

## 0.2.9

- Settings tools: `get_preferences`, `set_preference`,
  `get_notification_settings`, `set_notification_setting`,
  `subscribe_to_activity` and `get_activity_subscriptions`.
  `get_notifications` takes `grouped` and `feed`.
- When at_mcp creates a record, it refuses to overwrite a record created by
  another client in the meantime.

## 0.2.8

- Reads of accounts return plain text in place of JSON, with pronouns,
  website, links, join date, pinned post, verification and live status.
- Posts and notifications carry the author's badges, labels and relationship
  to the account.

## 0.2.7

- `like`, `repost`, `follow` and `block` return the existing record as
  `unchanged` when the account already has one for the subject.
- `reply` refuses a reply excluded by the thread's reply rule.
- `repost` by a handle-form address writes a working repost.
- `update_seen` keeps milliseconds.
- A deleted record reads as `not_found`.

## 0.2.6

- Feed and discovery tools: `get_feed_info`, `get_actor_feeds`,
  `search_feeds`, `get_suggested_starter_packs`, `get_trends`, `get_record`
  and `get_invite_codes`.
- `search_posts` uses the newer search method.
- `save_feed`, `unsave_feed`, `set_status` and `feed_feedback`.
  `update_profile` takes `pronouns`, `website` and `links`.
- `get_profile` returns avatar and banner addresses.

## 0.2.5

- Pins, thread mutes and bookmarks: `pin_post`, `unpin_post`, `mute_thread`,
  `unmute_thread`, `bookmark`, `unbookmark` and `get_bookmarks`.
- Drafts: `get_drafts`, `save_draft` and `delete_draft`.
- `post` takes reply and quote rules, self-labels and a link card.
  `set_post_interactions`, `hide_reply` and `detach_quote` change rules later.
- Lists and starter packs: create, read, update and delete.
- Every edit checks the record is unchanged since at_mcp read it, and refuses
  with `changed_meanwhile` otherwise.

## 0.2.4

- Feed reads say why a post appears, such as a repost or a pin, and give a
  reply's parent and thread.
- Link cards, videos and quoted feeds, lists and starter packs read with
  their details.

## 0.2.3

- Post reads carry like, repost, reply and quote counts and labels.
- Profiles and posts carry block and mute state.

## 0.2.2

- Each account on a service can have its own delivery receiver, with
  `at_mcp-accounts delivery`.
- at_mcp checks a delivery token file before using it and keeps the token out
  of its logs.
- A refused call lists each failing argument. Images accept `mimeType` as well
  as `mime_type`. A result lists the arguments at_mcp ignored.

### Upgrade

Setting a per-account receiver adds a `delivery` field to every account in
the accounts file, and 0.2.1 refuses to start with it. Before rolling back,
stop the service, keep a copy of the accounts file, and remove the `delivery`
field from every account. If your 0.2.1 logs contain a delivery error quoting
`Bearer`, change that token.

## 0.2.1

- Reads made of posts return readable text in `content`. `structuredContent`
  still holds the full result. A client parsing `content` as JSON should read
  `structuredContent`.
- `get_post_images` returns a post's pictures. `get_suggested_feeds` lists
  suggested feeds.
- `search_posts` takes `author`, `mentions`, `sort`, `since`, `until` and
  `lang`. `update_profile` takes `avatar` and `banner`.
- New settings: `AT_MCP_IMAGE_MAX_BYTES`, `AT_MCP_IMAGE_FETCH_SECONDS` and
  `AT_MCP_MEDIA_DIR`.

## 0.2.0

- at_mcp checks every setting at startup and refuses to start on an unknown
  `AT_MCP_` variable or an invalid value.
- `BLUESKY_HANDLE`, `BLUESKY_APP_PASSWORD` and `BLUESKY_SERVICE` become
  `AT_MCP_HANDLE`, `AT_MCP_APP_PASSWORD` and `AT_MCP_SERVICE`. The old names
  still work with a warning.
- New settings for the write quota, the notification queue, the polling
  interval and direct reads.
- at_mcp lists only the tools in a client's grant scope.

### Upgrade

Before switching to 0.2.0, check the service's settings with the new release:

```sh
AT_MCP_ENV_FILE=~/at_mcp/at_mcp.env ~/at_mcp/releases/at_mcp-0.2.0/bin/at_mcp eval 'AtMcp.CLI.settings()'
```

Embedding applications change their requirement to `{:at_mcp, "~> 0.2.0"}`
and pass settings through the application environment, because at_mcp stops
reading environment variables itself. at_mcp requires `proto_rune ~> 0.6.0`.

