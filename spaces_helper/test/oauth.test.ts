import { test, before, after } from 'node:test'
import assert from 'node:assert/strict'
import { mkdtemp, stat, writeFile, chmod } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { Helper } from '../src/main.ts'
import { startMockPds, type MockPds } from './mock-pds.ts'

const SCOPE = 'atproto transition:generic'

let pds: MockPds
let dir: string
let helper: Helper
const logs: string[] = []

async function call(method: string, params: Record<string, unknown>) {
  const out = JSON.parse((await helper.handle(JSON.stringify({ jsonrpc: '2.0', id: 1, method, params })))!)
  return out
}

before(async () => {
  pds = await startMockPds()
  dir = await mkdtemp(join(tmpdir(), 'spaces-helper-'))
  helper = new Helper((level, message) => logs.push(`${level} ${message}`))
  const init = await call('init', {
    stateDir: dir,
    userAgent: 'at_mcp/9.9.9',
    plcDirectoryUrl: pds.url,
    handleResolver: pds.url,
    allowHttp: true,
  })
  assert.equal(init.result.protocol, 1)
})

after(() => pds.close())

test('a new key file is 0600 and answers only its public parts', async () => {
  const keyFile = join(dir, 'gen.json')
  const out = await call('key.generate', { keyFile })
  assert.match(out.result.didKey, /^did:key:zDn/)
  assert.deepEqual(Object.keys(out.result).sort(), ['didKey', 'jkt'])
  assert.equal((await stat(keyFile)).mode & 0o777, 0o600)
  const again = await call('key.generate', { keyFile })
  assert.equal(again.error.data.class, 'indeterminate')
  assert.deepEqual((await call('key.public', { keyFile })).result, out.result)
})

test('a key file others may read is refused before anything is signed', async () => {
  const keyFile = join(dir, 'loose.json')
  await call('key.generate', { keyFile })
  await chmod(keyFile, 0o644)
  const out = await call('oauth.login', { account: pds.handle, keyFile, scope: SCOPE })
  assert.equal(out.error.data.class, 'refused')
  assert.equal(out.error.data.code, 'file_insecure')
  assert.equal(pds.consents, 0)
})

test('the account key approves a login: preview, check, signed consent, code, tokens', async () => {
  const keyFile = join(dir, 'agent.json')
  const { result: key } = await call('key.generate', { keyFile })
  pds.enroll(key.jkt)
  const out = await call('oauth.login', { account: pds.handle, keyFile, scope: SCOPE })
  assert.ifError(out.error)
  assert.equal(out.result.did, pds.did)
  assert.equal(pds.previews, 1)
  assert.equal(pds.consents, 1)

  const creds = await call('oauth.credentials', { did: pds.did })
  assert.equal(creds.result.accessToken, pds.lastAccessToken)
  assert.equal(creds.result.serviceUrl, pds.url)
  assert.equal(creds.result.dpopJwk.kty, 'EC')
  assert.ok(creds.result.dpopJwk.d, 'the session DPoP key, which at_mcp signs requests with')
  // P-256, though the server lists ES256K first: proto_rune signs ES256 only.
  assert.equal(creds.result.dpopJwk.crv, 'P-256')
  // The login key is not the session's DPoP key.
  assert.notEqual(creds.result.dpopJwk.x, key.jkt)
  assert.equal((await stat(join(dir, 'oauth-sessions.json'))).mode & 0o777, 0o600)
  assert.ok(pds.userAgents.every((ua) => ua === 'at_mcp/9.9.9'), pds.userAgents.join(','))
})

test('credentials asked with refresh get a new token; the old one is not answered again', async () => {
  const before = (await call('oauth.credentials', { did: pds.did })).result.accessToken
  const fresh = await call('oauth.credentials', { did: pds.did, refresh: true })
  assert.notEqual(fresh.result.accessToken, before)
  assert.equal(fresh.result.accessToken, pds.lastAccessToken)
})

test('a preview that is not the request this helper made is never signed', async () => {
  const keyFile = join(dir, 'agent.json')
  const consents = pds.consents
  for (const change of [
    (p: Record<string, unknown>) => ({ ...p, scope: `${p.scope} account:email` }),
    (p: Record<string, unknown>) => ({ ...p, client_id: 'https://evil.example/client.json' }),
    (p: Record<string, unknown>) => ({ ...p, redirect_uri: 'https://evil.example/cb' }),
    (p: Record<string, unknown>) => ({ ...p, login_hint: 'someone.else' }),
  ]) {
    pds.previewOverride = change
    const out = await call('oauth.login', { account: pds.handle, keyFile, scope: SCOPE })
    assert.equal(out.error.data.code, 'preview_mismatch')
    assert.equal(out.error.data.class, 'refused')
  }
  pds.previewOverride = undefined
  assert.equal(pds.consents, consents)
})

test('a session that can no longer refresh logs in again with the key, quietly', async () => {
  const keyFile = join(dir, 'agent.json')
  // The server forgets every refresh token: the next refresh fails.
  const { result: key } = await call('key.public', { keyFile })
  pds.revokeKey()
  pds.enroll(key.jkt)
  const consents = pds.consents
  const out = await call('oauth.credentials', {
    did: pds.did,
    refresh: true,
    relogin: { account: pds.handle, keyFile, scope: SCOPE },
  })
  assert.ifError(out.error)
  assert.equal(out.result.accessToken, pds.lastAccessToken)
  assert.equal(pds.consents, consents + 1)
  assert.ok(logs.some((l) => l.startsWith('info oauth session could not be refreshed')))
})

test('a key the PDS refuses is auth_refused, and says a principal may have replaced it', async () => {
  const keyFile = join(dir, 'agent.json')
  pds.revokeKey()
  const out = await call('oauth.credentials', {
    did: pds.did,
    refresh: true,
    relogin: { account: pds.handle, keyFile, scope: SCOPE },
  })
  assert.equal(out.error.data.class, 'auth_refused')
  assert.equal(out.error.data.code, 'key_refused')
  assert.match(out.error.message, /principal may have revoked the agent or replaced its key/)
})

test('without a key to log in again, a lost session is auth_refused', async () => {
  const out = await call('oauth.credentials', { did: pds.did, refresh: true })
  assert.equal(out.error.data.class, 'auth_refused')
})

test('an authorization server with no JSON preview is refused as not offering agent authorization', async () => {
  const keyFile = join(dir, 'agent.json')
  const { result: key } = await call('key.public', { keyFile })
  pds.enroll(key.jkt)
  pds.noExtension = true
  const consents = pds.consents
  const out = await call('oauth.login', { account: pds.handle, keyFile, scope: SCOPE })
  pds.noExtension = false
  assert.equal(out.error.data.code, 'signed_authorize_unsupported')
  assert.equal(pds.consents, consents)
})
