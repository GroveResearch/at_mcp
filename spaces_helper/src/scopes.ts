// Read-only space grants, checked with the protocol's own scope parser.
//
// A `space:` scope's actions default to read, create, update and delete when
// none is given, and a scope may name several actions or manage
// operations, so only the parser says what one allows. A scope here passes
// only when it is `atproto` or a space permission for one of `types`, under
// `authority` (or `self`), that reads and nothing else: actions within
// read and read_self, no manage, no collections to write.

import { SpacePermission } from '@atproto/oauth-scopes'

export type ScopeCheck = {
  ok: boolean
  allowed: string[]
  refused: { scope: string; why: string }[]
}

export function readOnlySpaces(scope: string, types: string[], authority?: string): ScopeCheck {
  const allowed: string[] = []
  const refused: { scope: string; why: string }[] = []
  for (const s of scope.split(/\s+/).filter(Boolean)) {
    if (s === 'atproto') {
      allowed.push(s)
      continue
    }
    const p = SpacePermission.fromString(s)
    if (!p) {
      refused.push({ scope: s, why: 'not a space permission' })
      continue
    }
    if (p.spaceType === '*' || !types.includes(p.spaceType)) {
      refused.push({ scope: s, why: `space type ${p.spaceType} isn't one of ${types.join(', ')}` })
    } else if (!(p.authority === 'self' || (authority && p.authority === authority))) {
      refused.push({ scope: s, why: `authority ${p.authority} isn't ${authority ?? 'self'}` })
    } else if (p.manage) {
      refused.push({ scope: s, why: `manages the space (${p.manage.join(', ')})` })
    } else if (!p.action.every((a) => a === 'read' || a === 'read_self')) {
      refused.push({ scope: s, why: `allows ${p.action.filter((a) => a !== 'read' && a !== 'read_self').join(', ')}` })
    } else {
      allowed.push(s)
    }
  }
  return { ok: refused.length === 0 && allowed.some((s) => s !== 'atproto'), allowed, refused }
}
