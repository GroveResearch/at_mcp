// Space reads and writes for one account, through its OAuth session.
//
// lex-space does the protocol: delegation tokens, space credentials (the pass
// exchange), request signing and MAC checks. This module maps the helper's
// requests onto it and answers JSON at_mcp can read.
import { Client, lexToJson, jsonToLex, type LexValue } from '@atproto/lex'
import {
  MemberspacePolicyManager,
  SpaceClient,
  SpaceManager,
  listSpaces,
  memberspace,
  personalspace,
  type SpaceReader,
} from '@atproto/lex-space'
import { createDidResolver } from '@atproto-labs/did-resolver'
import { createHash } from 'node:crypto'
import { refused } from './errors.ts'
import type { OAuthSessions } from './oauth.ts'
import { FileStore } from './store.ts'
import { spaceSchema } from './types.ts'

export type SpaceArg = string | { type: string; authority?: string; skey?: string }

export type SpacesConfig = {
  stateDir: string
  fetch: typeof globalThis.fetch
  plcDirectoryUrl?: string
  /** Read-only members every new inbox gets (the town AppView). */
  inboxReaders: string[]
}

type SyncCopy = {
  head?: { rev: string; state: string }
  records: Record<string, { cid: string; record: unknown }>
}

const json = (value: unknown) => lexToJson(value as LexValue)

export class Spaces {
  #open = new Map<string, SpaceClient>()
  readonly didResolver: ReturnType<typeof createDidResolver>
  readonly sync: FileStore<SyncCopy>

  constructor(
    readonly config: SpacesConfig,
    readonly oauth: OAuthSessions,
  ) {
    this.didResolver = createDidResolver({
      fetch: config.fetch,
      plcDirectoryUrl: config.plcDirectoryUrl,
    } as Parameters<typeof createDidResolver>[0])
    this.sync = new FileStore(`${config.stateDir}/space-sync.json`)
  }

  async client(did: string): Promise<Client> {
    return new Client(await this.oauth.session(did))
  }

  #uri(did: string, space: SpaceArg): { uri: string; type: string } {
    if (typeof space === 'string') {
      const m = /^at:space\/([^/]+)\/([^/]+)\/([^/]+)$/.exec(space)
      if (!m) throw refused('invalid_space', `${space} is not an at:space/ URI`)
      return { uri: space, type: m[2] }
    }
    const authority = space.authority ?? did
    const skey = space.skey ?? 'self'
    return { uri: `at:space/${authority}/${space.type}/${skey}`, type: space.type }
  }

  /** One SpaceClient per account and space, so its credential is reused. */
  async open(did: string, space: SpaceArg): Promise<SpaceClient> {
    const { uri, type } = this.#uri(did, space)
    const key = `${did} ${uri}`
    const known = this.#open.get(key)
    if (known) return known
    const client = await this.client(did)
    const opened = SpaceClient.openSpace(spaceSchema(type), uri as never, {
      agent: client.agent,
      fetch: this.config.fetch,
      didResolver: this.didResolver,
    } as Parameters<typeof SpaceClient.openSpace>[2])
    this.#open.set(key, opened)
    return opened
  }

  /**
   * Creates a space with `did` as its authority. `personal` uses the
   * personal-space policy (only the account reads it); `member` a member
   * list. An `org.atgrp.inbox` is always a member space open to writes by
   * any group, with the configured readers added read-only.
   */
  async create(
    did: string,
    { type, skey, policy = 'personal', members = [], publicWrite }: {
      type: string
      skey?: string
      policy?: 'personal' | 'member'
      members?: { did: string; read?: boolean; write?: boolean }[]
      publicWrite?: boolean
    },
  ) {
    const client = await this.client(did)
    const inbox = type === 'org.atgrp.inbox'
    const built = inbox
      ? memberspace.policy.$build({ publicWrite: true })
      : policy === 'member'
        ? memberspace.policy.$build(publicWrite ? { publicWrite: true } : {})
        : personalspace.policy.$build({})
    const space = await SpaceClient.createSpace(
      client.agent,
      spaceSchema(type),
      { policy: built, ...(skey ? { skey } : {}) } as never,
      { fetch: this.config.fetch, didResolver: this.didResolver } as never,
    )
    const readers = inbox ? this.config.inboxReaders.map((d) => ({ did: d, read: true, write: false })) : []
    const all = [...members, ...readers]
    if (all.length) {
      const manager = await SpaceManager.open(client.agent, space.uri, { policies: [MemberspacePolicyManager] })
      await manager.putMembers(all.map((m) => ({ did: m.did, read: m.read ?? true, write: m.write ?? false })) as never)
    }
    this.#open.set(`${did} ${space.uri}`, space)
    return { space: space.uri.toString(), members: all }
  }

  /**
   * The account's inbox, made if it has none, with the configured readers
   * among its members (added again if an earlier attempt stopped before it
   * could add them).
   */
  async ensureInbox(did: string) {
    const uri = `at:space/${did}/org.atgrp.inbox/self`
    const client = await this.client(did)
    let created = false
    try {
      await new SpaceManager(client.agent as never, uri as never).getSpace()
    } catch (err) {
      if ((err as { error?: string }).error !== 'SpaceNotFound') throw err
      await SpaceClient.createSpace(
        client.agent,
        spaceSchema('org.atgrp.inbox'),
        { policy: memberspace.policy.$build({ publicWrite: true }) } as never,
        { fetch: this.config.fetch, didResolver: this.didResolver } as never,
      )
      created = true
    }
    const readers = this.config.inboxReaders
    if (readers.length) {
      const manager = await SpaceManager.open(client.agent, uri as never, { policies: [MemberspacePolicyManager] })
      const have = new Set<string>()
      for await (const m of manager.members()) have.add((m as { did: string }).did)
      const missing = readers.filter((d) => !have.has(d))
      if (missing.length) await manager.putMembers(missing.map((d) => ({ did: d, read: true, write: false })) as never)
      return { space: uri, created, readers, added: missing }
    }
    return { space: uri, created, readers, added: [] }
  }

  async list(did: string, { type, authority, cursor, limit }: { type?: string; authority?: string; cursor?: string; limit?: number } = {}) {
    const client = await this.client(did)
    const out = await listSpaces(client, {
      ...(type ? { spaceType: type } : {}),
      ...(authority ? { spaceDid: authority } : {}),
      ...(cursor ? { cursor } : {}),
      ...(limit ? { limit } : {}),
    } as never)
    return json(out)
  }

  async getSpace(did: string, space: SpaceArg) {
    const client = await this.client(did)
    const { uri } = this.#uri(did, space)
    const manager = new SpaceManager(client.agent as never, uri as never)
    return json(await manager.getSpace())
  }

  async createRecord(did: string, space: SpaceArg, collection: string, record: Record<string, unknown>, rkey?: string) {
    const s = await this.open(did, space)
    const value = jsonToLex({ ...record, $type: collection } as never)
    const res = await s.createRecord(value as never, rkey)
    return json(res.body)
  }

  async putRecord(did: string, space: SpaceArg, collection: string, rkey: string, record: Record<string, unknown>) {
    const s = await this.open(did, space)
    const value = jsonToLex({ ...record, $type: collection } as never)
    const res = await s.putRecord(value as never, rkey)
    return json(res.body)
  }

  async getRecord(did: string, space: SpaceArg, collection: string, rkey: string, repo?: string) {
    const s = await this.open(did, space)
    const res = await s.getRecord(collection as never, rkey, repo ? { repo: repo as never } : {})
    return json(res.body)
  }

  async listRecords(
    did: string,
    space: SpaceArg,
    { collection, repo, limit, cursor }: { collection?: string; repo?: string; limit?: number; cursor?: string },
  ) {
    const s = await this.open(did, space)
    const res = await s.listRecords({
      ...(repo ? { repo } : {}),
      ...(collection ? { collection } : {}),
      ...(limit ? { limit } : {}),
      ...(cursor ? { cursor } : {}),
    } as never)
    return json(res.body)
  }

  async deleteRecord(did: string, space: SpaceArg, collection: string, rkey: string) {
    const s = await this.open(did, space)
    const res = await s.deleteRecord(collection as never, rkey)
    return json(res.body ?? {})
  }

  async writers(did: string, space: SpaceArg, { cursor, limit }: { cursor?: string; limit?: number } = {}) {
    const s = await this.open(did, space)
    const res = await s.listWriters({ ...(cursor ? { cursor } : {}), ...(limit ? { limit } : {}) } as never)
    return json(res.body)
  }

  /** Every record of every writer, verified, up to `limit`. */
  async all(did: string, space: SpaceArg, { limit = 200 }: { limit?: number } = {}) {
    const s = await this.open(did, space)
    const records: unknown[] = []
    let more = false
    for await (const r of s.allRecords()) {
      if (records.length >= limit) {
        more = true
        break
      }
      records.push({
        repo: r.repo,
        collection: r.collection,
        rkey: (r as { rkey?: string }).rkey,
        valid: r.valid,
        record: json(r.record),
        ...(r.valid ? {} : { error: String((r as { error?: unknown }).error) }),
      })
    }
    return { records, more }
  }

  async members(did: string, space: SpaceArg, op: 'put' | 'remove' | 'list', members: { did: string; read?: boolean; write?: boolean }[] = []) {
    const client = await this.client(did)
    const { uri } = this.#uri(did, space)
    const manager = await SpaceManager.open(client.agent, uri as never, { policies: [MemberspacePolicyManager] })
    if (op === 'put') await manager.putMembers(members.map((m) => ({ did: m.did, read: m.read ?? true, write: m.write ?? false })) as never)
    if (op === 'remove') await manager.removeMembers(members.map((m) => m.did) as never)
    const listed: unknown[] = []
    for await (const m of manager.members()) listed.push(json(m))
    return { members: listed }
  }

  async authorize(did: string, space: SpaceArg) {
    const s = await this.open(did, space)
    return json(await s.authorize())
  }

  /**
   * Brings the helper's copy of `repo` in `space` up to date and answers what
   * changed. The copy (records and head) lives in the helper's state, so a
   * pull after a restart continues from it.
   */
  async pull(did: string, space: SpaceArg, repo: string) {
    const s = await this.open(did, space)
    const key = createHash('sha256').update(`${did} ${s.uri} ${repo}`).digest('hex')
    const copy: SyncCopy = (await this.sync.get(key)) ?? { records: {} }
    const head = copy.head
      ? { rev: copy.head.rev, state: new Uint8Array(Buffer.from(copy.head.state, 'base64')) }
      : undefined
    const lookup = (collection: string, rkey: string) => {
      const known = copy.records[`${collection}/${rkey}`]
      return known ? (jsonToLex({ $link: known.cid } as never) as never) : null
    }
    const pulled: SpaceReader.RepoPull = await s.pullRepo({ repo: repo as never, head, lookup } as never)
    const changes: unknown[] = []
    if (pulled.type === 'changes') {
      for (const c of pulled.changes) {
        const k = `${c.collection}/${c.rkey}`
        if (c.cid) copy.records[k] = { cid: c.cid.toString(), record: json(c.record) }
        else delete copy.records[k]
        changes.push({ collection: c.collection, rkey: c.rkey, cid: c.cid?.toString() ?? null, record: c.record ? json(c.record) : null })
      }
    } else if (pulled.type === 'snapshot') {
      copy.records = {}
      for (const r of pulled.records) {
        copy.records[`${r.collection}/${r.rkey}`] = { cid: r.cid.toString(), record: json(r.record) }
        changes.push({ collection: r.collection, rkey: r.rkey, cid: r.cid.toString(), record: json(r.record) })
      }
    } else {
      copy.records = {}
    }
    copy.head = 'head' in pulled && pulled.head
      ? { rev: pulled.head.rev, state: Buffer.from(pulled.head.state).toString('base64') }
      : undefined
    await this.sync.set(key, copy)
    return { type: pulled.type, rev: copy.head?.rev ?? null, changes, held: Object.keys(copy.records).length }
  }

  forget(did: string) {
    for (const k of [...this.#open.keys()]) if (k.startsWith(`${did} `)) this.#open.delete(k)
  }
}
