// A stand-in for the Spaces helper (priv/spaces_helper/at_mcp-spaces.mjs)
// speaking the same JSON-RPC lines, for AtMcp's own tests. It holds one
// session whose access token is `tok-<n>`, n counting the refreshes, with a
// real P-256 DPoP key so proto_rune can sign its proofs. The first token
// expires `FAKE_FIRST_TTL` seconds after it is issued (default 10, inside
// AtMcp's margin), every later one in an hour. Each call is appended to the
// file `FAKE_LOG`, one JSON line, so a test can see what AtMcp asked.
import { createInterface } from 'node:readline'
import { generateKeyPairSync } from 'node:crypto'
import { appendFileSync, writeFileSync, mkdirSync, existsSync, readFileSync, unlinkSync } from 'node:fs'

const { privateKey } = generateKeyPairSync('ec', { namedCurve: 'P-256' })
const dpopJwk = privateKey.export({ format: 'jwk' })
let n = 1
let issuedTtl = Number(process.env.FAKE_FIRST_TTL ?? 10)
const did = process.env.FAKE_DID ?? 'did:plc:oauthagent'
const spaces = new Set()
let inboxReaders = []
// The inbox's members, as the helper would list them.
const inboxMembers = new Set()
// The scope the session was last logged in with.
let currentScope = 'atproto transition:generic'

// As the PDS grants it: the agent routes' permission set expanded into one
// rpc permission naming every method.
const agentMethods = ['acceptTransfer', 'createAgent', 'deleteAgent', 'enrollKey', 'listAgents', 'offerTransfer', 'revokeSessions', 'rotatePassword']
const expandSets = (scope) =>
  scope.replace(/include:town\.delve\.authManageAgents\?aud=(\S+)/g, (_, aud) =>
    `rpc?${agentMethods.map((m) => `lxm=town.delve.agent.${m}`).join('&')}&aud=${aud}`)
const written = []
const keyed = new Map()

const creds = () => ({
  did,
  accessToken: `tok-${n}`,
  dpopJwk,
  serviceUrl: process.env.FAKE_SERVICE ?? 'https://pds.invalid',
  issuer: 'https://pds.invalid',
  scope: currentScope,
  expiresAt: new Date(Date.now() + issuedTtl * 1000).toISOString(),
})

const methods = {
  'oauth.credentials': (p) => {
    if (p.relogin?.scope && currentScope === 'atproto transition:generic') currentScope = p.relogin.scope
    if (p.refresh) {
      n++
      issuedTtl = 3600
    }
    return creds()
  },
  'oauth.login': (p) => {
    currentScope = expandSets(p.scope ?? currentScope)
    return { did, scope: currentScope, expiresAt: null }
  },
  'oauth.status': () => ({ did, held: true }),
  'oauth.approveFor': (p) => ({ approved: true, delivered: true, status: 200 }),
  // An outside app's request, as the authorization server previews it; the
  // login hint from the URL's own hint= parameter, for tests.
  'oauth.previewApp': (p) => ({
    clientId: 'https://app.example/client-metadata.json',
    clientName: 'Example app',
    clientUri: 'https://app.example',
    scope: 'atproto transition:generic space:town.delve.space.feed?authority=*&action=read',
    redirectUri: 'https://app.example/callback',
    loginHint: new URL(p.authorizationUrl).searchParams.get('hint'),
  }),
  // getRecord's proof, as FAKE_FIXTURE's `verify` says for each principal.
  'record.verify': (p) => {
    const v = (fixture().verify ?? {})[p.did]
    if (v === 'ProofInvalid') throw { class: 'refused', code: 'ProofInvalid', message: 'proof does not hold' }
    if (!v) throw { class: 'indeterminate', code: 'transport', message: 'no answer' }
    return v
  },
  // The helper's own check, with the protocol's scope parser.
  'scope.readOnlySpaces': async (p) => {
    const { readOnlySpaces } = await import(new URL('../../spaces_helper/src/scopes.ts', import.meta.url))
    return readOnlySpaces(p.scope ?? '', p.types ?? [], p.authority)
  },
  'oauth.approveApp': (p) => ({ callbackUrl: `${p.redirectUri}?code=fake-code&iss=x` }),
  'space.get': (p) => {
    if (spaces.has(p.space) || (fixture().existing ?? []).includes(p.space)) return { space: p.space, policy: {} }
    throw { class: 'refused', code: 'SpaceNotFound', message: 'no such space' }
  },
  'space.delegationToken': (p) => {
    // This account's own spaces exist once made; another authority's (a
    // group's) are taken to exist.
    if (p.space.startsWith(`at:space/${did}/`) && !spaces.has(p.space)) {
      throw { class: 'refused', code: 'SpaceNotFound', message: 'no such space' }
    }
    return { space: p.space, token: `dtok-${Date.now()}` }
  },
  // A personal space that does not exist until space.create makes it.
  'space.create': (p) => {
    spaces.add(`at:space/${did}/${p.type}/${p.skey ?? 'self'}`)
    return { space: `at:space/${did}/${p.type}/${p.skey ?? 'self'}`, members: [] }
  },
  'space.records.create': (p) => {
    const space = typeof p.space === 'string' ? p.space : `at:space/${did}/${p.space.type}/${p.space.skey ?? 'self'}`
    // A space of its own (its own state space) exists once made.
    if (space.startsWith(`at:space/${did}/town.delve.space.agent/`) && !spaces.has(space)) {
      throw { class: 'refused', code: 'SpaceNotFound', message: 'no such space' }
    }
    const rkey = `3kfake${written.length}`
    written.push({ rkey, record: p.record })
    return { uri: `${space}/${did}/${p.collection}/${rkey}`, cid: 'bafyfake' }
  },
  // As the PDS answers: records with their key and CID, and no URI. A space
  // that isn't the account's is refused for a missing scope.
  'space.records.list': (p) => {
    const space = typeof p.space === 'string' ? p.space : `at:space/${did}/${p.space.type}/${p.space.skey ?? 'self'}`
    // Its own spaces, and its state space under its principal.
    if (!space.startsWith(`at:space/${did}/`) && !space.endsWith(`/town.delve.space.agent/${did}`)) {
      throw { class: 'refused', code: 'ScopeMissingError', status: 403, message: `Missing required scope "space:${space}"` }
    }
    return { records: written.map(({ rkey, record }) => ({ collection: p.collection, rkey, cid: 'bafyfake', value: record })) }
  },
  // Records kept under a key (put, get, delete): a member's confirmation in
  // a group's members space, say. FAKE_REFUSE_PUT refuses every put.
  'space.records.put': (p) => {
    if (process.env.FAKE_REFUSE_PUT) throw { class: 'refused', code: 'Forbidden', status: 403, message: 'not a member' }
    keyed.set(`${p.space} ${p.collection} ${p.rkey}`, p.record)
    return { uri: `${p.space}/${did}/${p.collection}/${p.rkey}`, cid: 'bafykeyed' }
  },
  'space.records.get': (p) => {
    const record = keyed.get(`${p.space} ${p.collection} ${p.rkey}`)
    if (!record) throw { class: 'refused', code: 'RecordNotFound', status: 400, message: 'no such record' }
    return { uri: `${p.space}/${p.repo ?? did}/${p.collection}/${p.rkey}`, cid: 'bafykeyed', value: record }
  },
  'space.records.delete': (p) => {
    keyed.delete(`${p.space} ${p.collection} ${p.rkey}`)
    return {}
  },
  // Calls as a group: each answered as written. FAKE_GROUP_REFUSE names an
  // error the host gives instead.
  'group.act': (p) => {
    if (process.env.FAKE_GROUP_REFUSE) throw { class: 'refused', code: process.env.FAKE_GROUP_REFUSE, status: 400, message: 'refused' }
    return {
      results: p.calls.map((c) => ({
        uri: `${c.body.space ?? 'at:space/x'}/${c.body.repo ?? 'x'}/${c.body.collection ?? 'x'}/${c.body.rkey ?? '3kgroupfake'}`,
        cid: 'bafygroup',
      })),
    }
  },
  'space.records.clear': (p) => ({}),
  'space.all': (p) => {
    const given = (fixture().all ?? {})[p.space]
    if (given) return { records: given, more: false }
    if (!p.space.startsWith(`at:space/${did}/`)) {
      throw { class: 'refused', code: 'ScopeMissingError', status: 403, message: `Missing required scope "space:${p.space}"` }
    }
    return { records: [], more: false }
  },
  // Keys: a made-up did:key per file, and a proof that echoes what it binds.
  'key.generate': (p) => {
    writeFileSync(p.keyFile, '{}', { mode: 0o600 })
    return { didKey: `did:key:zDnaeFake${Buffer.from(p.keyFile).toString('hex').slice(-12)}`, jkt: 'jkt' }
  },
  'key.prove': (p) => ({ proof: 'proof:' + JSON.stringify({ iss: p.iss, sub: p.sub, aud: p.aud, lxm: p.lxm }) }),
  // As the helper: the readers are added once, when the inbox is made.
  'inbox.ensure': (p) => {
    const uri = `at:space/${did}/org.atgrp.inbox/self`
    const created = !spaces.has(uri)
    spaces.add(uri)
    if (created) for (const r of inboxReaders) inboxMembers.add(r)
    const listed = inboxReaders.filter((r) => inboxMembers.has(r))
    return { space: uri, created, readers: inboxReaders, added: created ? inboxReaders : [], listed }
  },
  // The account takes a member off its inbox (the reader, say).
  'space.members.remove': (p) => {
    for (const m of p.members ?? []) inboxMembers.delete(m.did ?? m)
    return {}
  },
  'init': (p) => {
    inboxReaders = p.inboxReaders ?? []
    return { protocol: 1, version: 'fake' }
  },
}

// The file FAKE_FIXTURE names, read at each call: what a test says a
// method answers.
function fixture() {
  const file = process.env.FAKE_FIXTURE
  return file && existsSync(file) ? JSON.parse(readFileSync(file, 'utf8')) : {}
}

const rl = createInterface({ input: process.stdin })
rl.on('line', async (line) => {
  const msg = JSON.parse(line)
  if (process.env.FAKE_LOG) appendFileSync(process.env.FAKE_LOG, JSON.stringify({ method: msg.method, params: msg.params }) + '\n')
  // The file FAKE_DIE names holds a method: its next call kills this helper
  // before it answers, as a crash would, and the file goes.
  if (process.env.FAKE_DIE && existsSync(process.env.FAKE_DIE) && readFileSync(process.env.FAKE_DIE, 'utf8') === msg.method) {
    unlinkSync(process.env.FAKE_DIE)
    process.exit(1)
  }
  let out
  try {
    const fn = methods[msg.method]
    if (!fn) throw { class: 'refused', code: 'unknown_method', message: msg.method }
    out = { jsonrpc: '2.0', id: msg.id, result: await fn(msg.params ?? {}) }
  } catch (e) {
    out = { jsonrpc: '2.0', id: msg.id, error: { code: -32000, message: e.message, data: { class: e.class, code: e.code, status: e.status } } }
  }
  process.stdout.write(JSON.stringify(out) + '\n')
})
rl.on('close', () => process.exit(0))
