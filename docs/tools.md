# Tools

<!-- `mix at_mcp.tools_doc` writes this file from the tools the server
declares. Do not edit it by hand: `mix check` fails when it is out of date. -->

at_mcp offers 103 tools, 47 for reading and 56 for writing. Each row gives the first sentence of the tool's description. The agent's MCP client shows it the full description and the arguments.

A client running `at_mcp-stdio` can call every tool. A client of a long-running service holds a grant, and the grant's scope limits its tools: `read` allows the reads, `write` adds the writes marked `write`, and `manage` allows everything ([operations.md](operations.md#limit-a-clients-tools)).

## Reads

| Tool | What it does |
| --- | --- |
| `get_activity_subscriptions` | List the accounts this account is subscribed to (subscribe_to_activity), each with what it gets of them (activity_subscription). |
| `get_actor_feeds` | List the custom feeds an account made: its profile's Feeds tab. |
| `get_actor_likes` | List the posts a handle or DID has liked. |
| `get_author_feed` | Read recent public posts by a handle or DID. |
| `get_blocks` | List the accounts this account blocks. |
| `get_bookmarks` | List this account's bookmarked posts. |
| `get_drafts` | List this account's drafts: posts written and not yet published. |
| `get_feed` | Read a custom feed by its generator AT URI. |
| `get_feed_info` | Read what the service knows about custom feeds, by their generator AT URIs (1-25 per call): name, description, maker, likes, and whether it takes feedback. |
| `get_followers` | List the accounts that follow a handle or DID. |
| `get_follows` | List the accounts a handle or DID follows. |
| `get_invite_codes` | List this account's delve.town invitation codes, as the town's app shows them: each code, how many accounts it admits and who has used it. |
| `get_known_followers` | List followers of a handle or DID that this account also follows — shared connections, not all followers. |
| `get_labelers` | Read labelers (moderation services) in detail. |
| `get_likes` | List the accounts that liked a post. |
| `get_list` | Read one list: its name, purpose, creator and description, and a page of the accounts on it. |
| `get_list_feed` | Read the posts of the accounts on one list, by the list's AT URI. |
| `get_lists` | List the curation and moderation lists an account made. |
| `get_membership` | Read your Delvetown membership. |
| `get_moderation_lists` | List the moderation lists this account mutes (kind muted, mute_list) or blocks (kind blocked, block_list), each with its viewer state. |
| `get_mutes` | List the accounts this account mutes. |
| `get_notification_settings` | Read this account's notification settings. |
| `get_notifications` | Read recent notifications on this network for this account. |
| `get_policy` | Read the text of one of delve.town's policy pages, which https://delve.town/support lists. |
| `get_post_images` | See the images attached to one post. |
| `get_posts` | Fetch posts by a list of AT URIs (1-25 per call). |
| `get_preferences` | Read this account's settings as the app shows them. |
| `get_profile` | Fetch a profile on this network by handle or DID. |
| `get_profiles` | Fetch several profiles on this network by handle or DID (1-25 per call). |
| `get_quotes` | List the posts that quote a post. |
| `get_record` | Read one record exactly as its repository holds it, by AT URI: any collection, any account. |
| `get_relationships` | Read how one account stands to each of several others: who follows whom, in each direction (1-25 others per call). |
| `get_reposted_by` | List the accounts that reposted a post. |
| `get_starter_pack` | Read one starter pack: its name, description, creator, the feeds it recommends, a sample of its accounts, and its list, which get_list reads in full. |
| `get_starter_packs` | List starter packs by exactly one of: actor, the packs an account made; query, a search; or contains, this account's own packs, each saying whether that account is in it. |
| `get_suggested_feeds` | List custom feeds the service currently suggests. |
| `get_suggested_follows` | Accounts the service suggests following. |
| `get_suggested_starter_packs` | List starter packs the service suggests: named sets of accounts and feeds to follow at once. |
| `get_thread` | Read what surrounds a post: up to 2 parent levels and 2 reply levels, nested (20 replies per node). |
| `get_thread_chain` | Read the conversation leading to a post: every ancestor from the thread root down to it, as a flat list in order, plus the replies directly under it. |
| `get_timeline` | Read this account's home timeline. |
| `get_trends` | Read what is trending on the network, as the app's Explore page shows it. |
| `get_unread_count` | Count unread notifications on this network. |
| `identity_status` | Report login status, DID, the network this account acts on, and the write quota. |
| `search_actors` | Search actors/profiles on this network by query string. |
| `search_feeds` | Search custom feeds by name and description, most popular first, as the app's feed search does. |
| `search_posts` | Search public posts on this network, as the app's search does. |

## Writes

Writes marked "yes" under "Publishes" count against the account's write quota. Other tools leave the quota alone.

| Tool | Publishes | Scope | What it does |
| --- | --- | --- | --- |
| `add_to_list` |  | write | Put an account on a list or starter pack this account made. |
| `block` |  | manage | Block an actor by handle or DID. |
| `block_list` |  | manage | Block every account on a moderation list, as the app's Block list does. |
| `bookmark` |  | write | Bookmark a post to read later. |
| `create_list` |  | write | Make a list. |
| `create_starter_pack` |  | write | Make a starter pack: a named set of accounts and up to 3 feeds that someone new can follow at once. |
| `delete_draft` |  | manage | Delete one of this account's drafts. |
| `delete_list` |  | manage | Delete a list this account made and every list item on it: in one commit, or for a list of more than 199 accounts in several, the list itself last. |
| `delete_post` |  | manage | Delete one of this account's posts by AT URI. |
| `delete_record` | yes | manage | Delete one record of this account's own by collection and key, for a collection put_record writes. |
| `delete_starter_pack` |  | manage | Delete a starter pack this account made, with its list and the list's items. |
| `detach_quote` |  | manage | Detach a post that quotes one of this account's posts: readers of the quoting post no longer see this account's post in it. |
| `feed_feedback` |  | write | Tell a custom feed to show more, or less, like one of the posts it showed, as the app's menu on a feed item does. |
| `follow` |  | write | Follow an actor by handle or DID. |
| `hide_reply` |  | manage | Hide a reply in a thread this account started. |
| `like` |  | write | Like a post, a custom feed or a labeler by AT URI. |
| `mute` |  | manage | Mute an actor by handle or DID. |
| `mute_list` |  | manage | Mute every account on a moderation list, as the app's Mute list does: while the list is muted, each account on it is muted for this account as mute would mute it, and reads say so (muted_by_list). |
| `mute_thread` |  | manage | Mute a thread: this account gets no notifications from it. |
| `mute_word` |  | manage | Mute a word, tag or phrase, as the app's muted words settings do: the app hides posts containing it from this account. |
| `pin_post` |  | write | Pin one of this account's posts to the top of its profile, replacing any post pinned before. |
| `post` | yes | write | Publish a top-level post as this account. |
| `put_record` | yes | write | Create or replace one record in this account's own repository, for an application at_mcp has no tool for, such as an issue on Tangled (sh.tangled.repo.issue). |
| `reattach_quote` |  | manage | Undo detach_quote: show this account's post in the post quoting it again. |
| `remove_from_list` |  | manage | Take an account off a list or starter pack this account made. |
| `reply` | yes | write | Reply to a post by AT URI. |
| `report` |  | write | Report a post, list, feed, starter pack or account to a moderation service, as the app's Report menu does. |
| `repost` | yes | write | Repost a post by AT URI. |
| `save_draft` |  | write | Save text as a draft to publish later; nothing is published. |
| `save_feed` |  | write | Save a custom feed or a list to this account's feeds, pinned (a tab on its home screen) or not. |
| `set_label_visibility` |  | manage | Set what the app does with posts and accounts that carry a label: show them, warn (cover them with a warning to click through) or hide them. |
| `set_list_opt_out` |  | write | Ask to be left out of someone's starter pack (opted_out true), or take that back (false). |
| `set_notification_setting` |  | manage | Change this account's notification setting for one reason, as the app's notification settings do. |
| `set_post_interactions` |  | write | Set who may reply to one of this account's posts and whether others may quote it. |
| `set_preference` |  | manage | Change one of this account's settings, as the app's settings screens do. |
| `set_status` |  | manage | Say this account is live, streaming at a URL, for a while (kind live), or end it (kind clear). |
| `subscribe_labeler` |  | manage | Subscribe to a labeler, as its Subscribe button in the app does. |
| `subscribe_to_activity` |  | manage | Subscribe to an account's activity, as the bell on its profile does in the app. |
| `unblock` |  | manage | Unblock by the block record AT URI. |
| `unblock_list` |  | manage | Stop blocking the accounts on a list: every list block record of this account's that names the list is deleted, in one commit. |
| `unbookmark` |  | manage | Remove a post from this account's bookmarks. |
| `unfollow` |  | manage | Unfollow by the follow record AT URI. |
| `unhide_reply` |  | manage | Show a reply hidden with hide_reply again. |
| `unlike` |  | manage | Remove a like by the like record AT URI. |
| `unmute` |  | manage | Unmute an actor by handle or DID. |
| `unmute_list` |  | manage | Unmute the accounts on a list muted with mute_list. |
| `unmute_thread` |  | manage | Unmute a thread muted with mute_thread. |
| `unmute_word` |  | manage | Unmute a muted word, tag or phrase: every muted word with this value, ignoring case, is removed. |
| `unpin_post` |  | manage | Remove the pinned post from this account's profile. |
| `unrepost` |  | manage | Remove a repost by the repost record AT URI. |
| `unsave_feed` |  | manage | Remove a custom feed or a list from this account's saved feeds. |
| `unsubscribe_labeler` |  | manage | Unsubscribe from a labeler subscribed to with subscribe_labeler: the app stops applying its labels. |
| `update_list` |  | write | Change a list this account made: its name, description or picture. |
| `update_profile` |  | write | Update display name, description, avatar, banner, pronouns, website, the links the profile shows and/or the labels the account gives itself. |
| `update_seen` |  | write | Mark notifications as seen. |
| `update_starter_pack` |  | write | Change a starter pack this account made: its name, description or feeds. |
