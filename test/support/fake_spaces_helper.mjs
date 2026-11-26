// A stand-in for the Spaces helper (priv/spaces_helper/at_mcp-spaces.mjs)
// speaking the same JSON-RPC lines, for AtMcp's own tests. It holds one
// session whose access token is `tok-<n>`, n counting the refreshes, with a
// real P-256 DPoP key so proto_rune can sign its proofs. The first token
// expires `FAKE_FIRST_TTL` seconds after it is issued (default 10, inside
// AtMcp's margin), every later one in an hour. Each call is appended to the
// file `FAKE_LOG`, one JSON line, so a test can see what AtMcp asked.
import { createInterface } from 'node:readline'
import { generateKeyPairSync } from 'node:crypto'
import { appendFileSync } from 'node:fs'

const { privateKey } = generateKeyPairSync('ec', { namedCurve: 'P-256' })
const dpopJwk = privateKey.export({ format: 'jwk' })
let n = 1
let issuedTtl = Number(process.env.FAKE_FIRST_TTL ?? 10)
const did = process.env.FAKE_DID ?? 'did:plc:oauthagent'
const spaces = new Set()

const creds = () => ({
  did,
  accessToken: `tok-${n}`,
  dpopJwk,
  serviceUrl: process.env.FAKE_SERVICE ?? 'https://pds.invalid',
  issuer: 'https://pds.invalid',
  scope: 'atproto transition:generic',
  expiresAt: new Date(Date.now() + issuedTtl * 1000).toISOString(),
})

const methods = {
  init: () => ({ protocol: 1, version: 'fake' }),
  'oauth.credentials': (p) => {
    if (p.refresh) {
      n++
      issuedTtl = 3600
    }
    return creds()
  },
  'oauth.login': () => ({ did, scope: 'atproto', expiresAt: null }),
  'oauth.status': () => ({ did, held: true }),
  'space.get': () => {
    throw { class: 'refused', code: 'SpaceNotFound', message: 'no such space' }
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
    return { uri: `${space}/${did}/${p.collection}/3kfake`, cid: 'bafyfake' }
  },
  'inbox.ensure': () => ({ space: `at:space/${did}/org.atgrp.inbox/self`, created: true, readers: [] }),
}

const rl = createInterface({ input: process.stdin })
rl.on('line', (line) => {
  const msg = JSON.parse(line)
  if (process.env.FAKE_LOG) appendFileSync(process.env.FAKE_LOG, JSON.stringify({ method: msg.method, params: msg.params }) + '\n')
  let out
  try {
    const fn = methods[msg.method]
    if (!fn) throw { class: 'refused', code: 'unknown_method', message: msg.method }
    out = { jsonrpc: '2.0', id: msg.id, result: fn(msg.params ?? {}) }
  } catch (e) {
    out = { jsonrpc: '2.0', id: msg.id, error: { code: -32000, message: e.message, data: { class: e.class, code: e.code } } }
  }
  process.stdout.write(JSON.stringify(out) + '\n')
})
rl.on('close', () => process.exit(0))
