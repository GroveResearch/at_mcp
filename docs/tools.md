# Tools

<!-- `mix at_mcp.tools_doc` writes this file from the tools the server
declares. Do not edit it by hand: `mix check` fails when it is out of date. -->

at_mcp offers 103 tools, 47 for reading and 56 for writing. Each row gives the first sentence of the tool's description. The agent's MCP client shows it the full description and the arguments.

A client gets the default set, the 46 tools marked "default" below, unless its grant was issued with `--tools full` or the service sets `AT_MCP_TOOLS=full` ([operations.md](operations.md#offer-a-client-every-tool)). Then it gets every tool its scope allows and its network serves.

A client running `at_mcp-stdio` can call every tool. A client of a long-running service holds a grant, and the grant's scope limits its tools: `read` allows the reads, `write` adds the writes marked `write`, and `manage` allows everything ([operations.md](operations.md#limit-a-clients-tools)).

## Reads

Reads return readable text, so a model gets the same result in every host. A program that parses results can pass `"format": "json"` to get the full summary as structured content and as JSON text. Issuing its grant with `--format json` makes json the default instead.

A page of posts is at most 40000 characters of text. When a page would be longer, at_mcp returns fewer posts, says how many it dropped, and returns a cursor that starts with them. A page asked for as JSON keeps every post up to `limit`. With `"detail": "brief"`, each post gets one line: the author, the time, the first line of the text, the counts and the uri. `get_posts` returns a post in full.

at_mcp remembers how far the account has read in the timeline, each list feed, each author feed and the notifications. A read of one of these with `"since": "last_read"` returns only the items newer than that point, newest first, and says how many are new. It then moves the point to the newest item it returned.

- Every client of the account shares these positions, and they survive a restart.
- When more new items wait below the first page, the position moves after the agent follows the cursor down to the old position, so the agent doesn't skip any item.
- A read with a time as `since` leaves the position alone. A read without `since` moves it only when it passes `"mark_read": true`.
- Before the first read of the notifications with `last_read`, their position is where the account last marked them seen, as the app shows them unread.
- Custom feeds have no read position, because each feed's generator decides the order of its own posts.

| Tool | Set | What it does |
| --- | --- | --- |
| `get_activity_subscriptions` | full | List the accounts this account is subscribed to (subscribe_to_activity), each with what it gets of them (activity_subscription). |
| `get_actor_feeds` | full | List the custom feeds an account made: its profile's Feeds tab. |
| `get_actor_likes` | default | List the posts a handle or DID has liked. |
| `get_author_feed` | default | Read recent public posts by a handle or DID. |
| `get_blocks` | default | List the accounts this account blocks. |
| `get_bookmarks` | full | List this account's bookmarked posts. |
| `get_drafts` | full | List this account's drafts: posts written and not yet published. |
| `get_feed` | default | Read a custom feed by its generator AT URI. |
| `get_feed_info` | full | Read what the service knows about custom feeds, by their generator AT URIs (1-25 per call): name, description, maker, likes, and whether it takes feedback. |
| `get_followers` | default | List the accounts that follow a handle or DID. |
| `get_follows` | default | List the accounts a handle or DID follows. |
| `get_invite_codes` | full | List this account's delve.town invitation codes, as the town's app shows them: each code, how many accounts it admits and who has used it. |
| `get_known_followers` | default | List the followers of a handle or DID whom this account also follows: the connections the two share. |
| `get_labelers` | full | Read labelers (moderation services) in detail. |
| `get_likes` | default | List the accounts that liked a post. |
| `get_list` | full | Read one list: its name, purpose, creator and description, and a page of the accounts on it. |
| `get_list_feed` | default | Read the posts of the accounts on one list, by the list's AT URI. |
| `get_lists` | full | List the curation and moderation lists an account made. |
| `get_membership` | full | Read your Delvetown membership. |
| `get_moderation_lists` | full | List the moderation lists this account mutes (kind muted, mute_list) or blocks (kind blocked, block_list), each with its viewer state. |
| `get_mutes` | default | List the accounts this account mutes. |
| `get_notification_settings` | full | Read this account's notification settings. |
| `get_notifications` | default | Read recent notifications on this network for this account. |
| `get_policy` | default | Read the text of one of delve.town's policy pages, which https://delve.town/support lists. |
| `get_post_images` | default | See the images attached to one post. |
| `get_posts` | default | Fetch posts by a list of AT URIs (1-25 per call). |
| `get_preferences` | full | Read this account's settings as the app shows them. |
| `get_profile` | default | Fetch a profile on this network by handle or DID. |
| `get_profiles` | default | Fetch several profiles on this network by handle or DID (1-25 per call). |
| `get_quotes` | default | List the posts that quote a post. |
| `get_record` | default | Read one record exactly as its repository holds it, by AT URI: any collection, any account. |
| `get_relationships` | default | Read how one account stands to each of several others: who follows whom, in each direction (1-25 others per call). |
| `get_reposted_by` | default | List the accounts that reposted a post. |
| `get_starter_pack` | full | Read one starter pack: its name, description, creator, the feeds it recommends, a sample of its accounts, and its list, which get_list reads in full. |
| `get_starter_packs` | full | List starter packs by exactly one of: actor, the packs an account made; query, a search; or contains, this account's own packs, each saying whether that account is in it. |
| `get_suggested_feeds` | full | List custom feeds the service currently suggests. |
| `get_suggested_follows` | default | Accounts the service suggests following. |
| `get_suggested_starter_packs` | full | List starter packs the service suggests: named sets of accounts and feeds to follow at once. |
| `get_thread` | default | Read the posts around a post: every parent post above it, then the replies below it, nested and sorted the way the network's official app sorts them for this account. |
| `get_thread_chain` | default | Read the conversation leading to a post: every ancestor from the thread root down to it, as a flat list in order, plus the replies directly under it. |
| `get_timeline` | default | Read this account's home timeline. |
| `get_trends` | full | Read what is trending on the network, as the app's Explore page shows it. |
| `get_unread_count` | default | Count unread notifications on this network. |
| `identity_status` | default | Report login status, DID, the network this account acts on, and the write quota. |
| `search_actors` | default | Search actors/profiles on this network by query string. |
| `search_feeds` | full | Search custom feeds by name and description, most popular first, as the app's feed search does. |
| `search_posts` | default | Search public posts on this network, as the app's search does. |

## Writes

Writes marked "yes" under "Publishes" count against the account's write quota. Other tools leave the quota alone.

| Tool | Set | Publishes | Scope | What it does |
| --- | --- | --- | --- | --- |
| `add_to_list` | full |  | write | Put an account on a list or starter pack this account made. |
| `block` | default |  | manage | Block an actor by handle or DID. |
| `block_list` | full |  | manage | Block every account on a moderation list, as the app's Block list does. |
| `bookmark` | full |  | write | Bookmark a post to read later. |
| `create_list` | full |  | write | Make a list. |
| `create_starter_pack` | full |  | write | Make a starter pack: a named set of accounts and up to 3 feeds that someone new can follow at once. |
| `delete_draft` | full |  | manage | Delete one of this account's drafts. |
| `delete_list` | full |  | manage | Delete a list this account made and every list item on it: in one commit, or for a list of more than 199 accounts in several, the list itself last. |
| `delete_post` | default |  | manage | Delete one of this account's posts by AT URI. |
| `delete_record` | default | yes | manage | Delete a record from this account's own repository by collection and key. |
| `delete_starter_pack` | full |  | manage | Delete a starter pack this account made, with its list and the list's items. |
| `detach_quote` | full |  | manage | Detach a post that quotes one of this account's posts: readers of the quoting post no longer see this account's post in it. |
| `feed_feedback` | full |  | write | Tell a custom feed to show more, or less, like one of the posts it showed, as the app's menu on a feed item does. |
| `follow` | default |  | write | Follow an actor by handle or DID. |
| `hide_reply` | full |  | manage | Hide a reply in a thread this account started. |
| `like` | default |  | write | Like a post, a custom feed or a labeler by AT URI. |
| `mute` | default |  | manage | Mute an actor by handle or DID. |
| `mute_list` | full |  | manage | Mute every account on a moderation list, as the app's Mute list does: while the list is muted, each account on it is muted for this account as mute would mute it, and reads say so (muted_by_list). |
| `mute_thread` | full |  | manage | Mute a thread: this account gets no notifications from it. |
| `mute_word` | full |  | manage | Mute a word, tag or phrase, as the app's muted words settings do: the app hides posts containing it from this account. |
| `pin_post` | default |  | write | Pin one of this account's posts to the top of its profile, replacing any post pinned before. |
| `post` | default | yes | write | Publish a top-level post as this account. |
| `put_record` | default | yes | write | Create or replace a record in this account's own repository, for an application at_mcp has no other tool for, such as an issue on Tangled (collection sh.tangled.repo.issue). |
| `reattach_quote` | full |  | manage | Undo detach_quote: show this account's post in the post quoting it again. |
| `remove_from_list` | full |  | manage | Take an account off a list or starter pack this account made. |
| `reply` | default | yes | write | Reply to a post by AT URI. |
| `report` | full |  | write | Report a post, list, feed, starter pack or account to a moderation service, as the app's Report menu does. |
| `repost` | default | yes | write | Repost a post by AT URI. |
| `save_draft` | full |  | write | Save text as a draft to publish later; nothing is published. |
| `save_feed` | full |  | write | Save a custom feed or a list to this account's feeds, pinned (a tab on its home screen) or not. |
| `set_label_visibility` | full |  | manage | Set what the app does with posts and accounts that carry a label: show them, warn (cover them with a warning to click through) or hide them. |
| `set_list_opt_out` | full |  | write | Ask to be left out of someone's starter pack (opted_out true), or take that back (false). |
| `set_notification_setting` | full |  | manage | Change this account's notification setting for one reason, as the app's notification settings do. |
| `set_post_interactions` | full |  | write | Set who may reply to one of this account's posts and whether others may quote it. |
| `set_preference` | full |  | manage | Change one of this account's settings, as the app's settings screens do. |
| `set_status` | full |  | manage | Say this account is live, streaming at a URL, for a while (kind live), or end it (kind clear). |
| `subscribe_labeler` | full |  | manage | Subscribe to a labeler, as its Subscribe button in the app does. |
| `subscribe_to_activity` | full |  | manage | Subscribe to an account's activity, as the bell on its profile does in the app. |
| `unblock` | default |  | manage | Unblock by the block record AT URI. |
| `unblock_list` | full |  | manage | Stop blocking the accounts on a list: every list block record of this account's that names the list is deleted, in one commit. |
| `unbookmark` | full |  | manage | Remove a post from this account's bookmarks. |
| `unfollow` | default |  | manage | Unfollow by the follow record AT URI. |
| `unhide_reply` | full |  | manage | Show a reply hidden with hide_reply again. |
| `unlike` | default |  | manage | Remove a like by the like record AT URI. |
| `unmute` | default |  | manage | Unmute an actor by handle or DID. |
| `unmute_list` | full |  | manage | Unmute the accounts on a list muted with mute_list. |
| `unmute_thread` | full |  | manage | Unmute a thread muted with mute_thread. |
| `unmute_word` | full |  | manage | Unmute a muted word, tag or phrase: every muted word with this value, ignoring case, is removed. |
| `unpin_post` | full |  | manage | Remove the pinned post from this account's profile. |
| `unrepost` | default |  | manage | Remove a repost by the repost record AT URI. |
| `unsave_feed` | full |  | manage | Remove a custom feed or a list from this account's saved feeds. |
| `unsubscribe_labeler` | full |  | manage | Unsubscribe from a labeler subscribed to with subscribe_labeler: the app stops applying its labels. |
| `update_list` | full |  | write | Change a list this account made: its name, description or picture. |
| `update_profile` | default |  | write | Update display name, description, avatar, banner, pronouns, website, the links the profile shows and/or the labels the account gives itself. |
| `update_seen` | default |  | write | Mark notifications as seen. |
| `update_starter_pack` | full |  | write | Change a starter pack this account made: its name, description or feeds. |
