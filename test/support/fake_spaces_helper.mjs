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
// The scope the session was last logged in with.
let currentScope = 'atproto transition:generic'
const written = []

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
    currentScope = p.scope ?? currentScope
    return { did, scope: currentScope, expiresAt: null }
  },
  'oauth.status': () => ({ did, held: true }),
  'space.get': (p) => {
    if (spaces.has(p.space)) return { space: p.space, policy: {} }
    throw { class: 'refused', code: 'SpaceNotFound', message: 'no such space' }
  },
  'space.delegationToken': (p) => {
    if (!spaces.has(p.space)) throw { class: 'refused', code: 'SpaceNotFound', message: 'no such space' }
    return { space: p.space, token: `dtok-${Date.now()}` }
  },
  // A personal space that does not exist until space.create makes it.
  'space.create': (p) => {
    spaces.add(`at:space/${did}/${p.type}/${p.skey ?? 'self'}`)
    return { space: `at:space/${did}/${p.type}/${p.skey ?? 'self'}`, members: [] }
  },
  'space.records.create': (p) => {
    const space = typeof p.space === 'string' ? p.space : `at:space/${did}/${p.space.type}/${p.space.skey ?? 'self'}`
    if (space.includes('town.delve.space.personal') && !spaces.has(space)) {
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
    if (!space.startsWith(`at:space/${did}/`)) {
      throw { class: 'refused', code: 'ScopeMissingError', status: 403, message: `Missing required scope "space:${space}"` }
    }
    return { records: written.map(({ rkey, record }) => ({ collection: p.collection, rkey, cid: 'bafyfake', value: record })) }
  },
  'space.all': (p) => {
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
    return { space: uri, created, readers: inboxReaders, added: created ? inboxReaders : [] }
  },
  'init': (p) => {
    inboxReaders = p.inboxReaders ?? []
    return { protocol: 1, version: 'fake' }
  },
}

const rl = createInterface({ input: process.stdin })
rl.on('line', (line) => {
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
    out = { jsonrpc: '2.0', id: msg.id, result: fn(msg.params ?? {}) }
  } catch (e) {
    out = { jsonrpc: '2.0', id: msg.id, error: { code: -32000, message: e.message, data: { class: e.class, code: e.code, status: e.status } } }
  }
  process.stdout.write(JSON.stringify(out) + '\n')
})
rl.on('close', () => process.exit(0))
