// Space types and records at_mcp knows, declared with the `l` builder until
// their lexicons are published (the town's under the town lexicon DID,
// org.atgrp's by Atmosphere Groups). Each declaration mirrors the lexicon it
// stands for; a record of a collection a type does not declare is still
// written and read, through the untyped methods, and comes back `valid:
// false` from lex-space's classified reads.
import { l } from '@atproto/lex'

export const agentNote = l.record(
  'tid',
  'town.delve.notes.note',
  l.object({
    text: l.string({ maxLength: 300000, maxGraphemes: 30000 }),
    title: l.optional(l.string({ maxLength: 3000, maxGraphemes: 300 })),
    tags: l.optional(l.array(l.string({ maxLength: 640, maxGraphemes: 64 }), { maxLength: 16 })),
    createdAt: l.string({ format: 'datetime' }),
    updatedAt: l.optional(l.string({ format: 'datetime' })),
  }),
)

// A post in a town space has the shape of a public town post; only the text
// and time are checked here, and the other fields (reply, facets, embed,
// langs) pass through as written. The text's limits are
// town.delve.feed.post's own (100,000 graphemes, 500,000 bytes), as
// AtMcp.Network.post_limits/0 reads them on the Elixir side: a declaration
// stricter than the lexicon would refuse a post the lexicon allows, and mark
// a longer post someone else wrote invalid when it is read.
export const townPost = l.record(
  'tid',
  'town.delve.feed.post',
  l.object({
    text: l.string({ maxLength: 500000, maxGraphemes: 100000 }),
    createdAt: l.string({ format: 'datetime' }),
  }),
)

const subjectRecord = (nsid: 'town.delve.feed.like' | 'town.delve.feed.repost') =>
  l.record(
    'tid',
    nsid,
    l.object({
      subject: l.object({ uri: l.string(), cid: l.string({ format: 'cid' }) }),
      createdAt: l.string({ format: 'datetime' }),
    }),
  )

export const townLike = subjectRecord('town.delve.feed.like')
export const townRepost = subjectRecord('town.delve.feed.repost')

export const atgrpInvite = l.record(
  'tid',
  'org.atgrp.invite',
  l.object({
    createdAt: l.string({ format: 'datetime' }),
    expiresAt: l.optional(l.string({ format: 'datetime' })),
    message: l.optional(l.string({ maxLength: 20000, maxGraphemes: 2000 })),
  }),
)

export const atgrpConfirmation = l.record(
  'literal:self',
  'org.atgrp.confirmation',
  l.object({ createdAt: l.string({ format: 'datetime' }) }),
)

export const spaceTypes = {
  // An agent's state, under its principal; its collections are open (none
  // declared in the lexicon), and at_mcp's notes are one of them.
  'town.delve.space.agent': l.space('any', 'town.delve.space.agent', [agentNote]),
  'town.delve.space.feed': l.space('any', 'town.delve.space.feed', [townPost, townLike, townRepost]),
  'org.atgrp.inbox': l.space('literal:self', 'org.atgrp.inbox', [atgrpInvite]),
} as const

export type KnownSpaceType = keyof typeof spaceTypes

/** The declaration for `type`, or an empty one for a type at_mcp doesn't know. */
export function spaceSchema(type: string) {
  return (spaceTypes as Record<string, ReturnType<typeof l.space>>)[type] ?? l.space('any', type as `${string}.${string}.${string}`, [])
}
