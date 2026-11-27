import { test } from 'node:test'
import assert from 'node:assert/strict'
import { mkdtemp, writeFile, readdir, readFile, utimes } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fork } from 'node:child_process'
import { lockFileName, withFileLock } from '../src/lock.ts'
import { townPost } from '../src/types.ts'
import { generateKey, keyProof, loadKey } from '../src/keys.ts'
import { decodeJwt, decodeProtectedHeader, importJWK, jwtVerify } from 'jose'

test('two holders of one lock never overlap, across processes too', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'lock-'))
  const log = join(dir, 'log')
  // A second process takes the same lock while this one holds it.
  const child = `
    const { withFileLock } = await import(${JSON.stringify(new URL('../src/lock.ts', import.meta.url).href)})
    const { appendFile } = await import('node:fs/promises')
    await withFileLock(${JSON.stringify(dir)}, 'refresh', async () => {
      await appendFile(${JSON.stringify(log)}, 'child-in\\n')
      await new Promise((r) => setTimeout(r, 100))
      await appendFile(${JSON.stringify(log)}, 'child-out\\n')
    })`
  const script = join(dir, 'child.mjs')
  await writeFile(script, child)
  const { appendFile, readFile } = await import('node:fs/promises')
  const mine = withFileLock(dir, 'refresh', async () => {
    await appendFile(log, 'parent-in\n')
    const p = fork(script, { execArgv: ['--experimental-transform-types', '--no-warnings'] })
    await new Promise((r) => setTimeout(r, 300))
    await appendFile(log, 'parent-out\n')
    return p
  })
  const p = await mine
  await new Promise((r) => p.on('exit', r))
  assert.deepEqual((await readFile(log, 'utf8')).trim().split('\n'), ['parent-in', 'parent-out', 'child-in', 'child-out'])
  assert.deepEqual((await readdir(dir)).filter((f) => f.endsWith('.lock')), [])
})

test('a lock left by a process that died is taken over', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'lock-'))
  const name = 'oauth:x'
  const file = join(dir, lockFileName(name))
  await writeFile(file, JSON.stringify({ pid: 2 ** 22 + 12345, at: Date.now() }))
  assert.equal(await withFileLock(dir, name, async () => 'taken'), 'taken')
})

test('a lock file left empty, by a holder killed as it took it, is taken over', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'lock-'))
  const name = 'store:oauth-sessions.json'
  const file = join(dir, lockFileName(name))
  await writeFile(file, '')
  // Fresh, it may still be being written: waited for, not taken.
  const early = await Promise.race([
    withFileLock(dir, name, async () => 'taken'),
    new Promise((r) => setTimeout(() => r('waiting'), 500)),
  ])
  assert.equal(early, 'waiting')
  // Once it has stayed unreadable, it is taken over.
  const old = new Date(Date.now() - 10_000)
  await utimes(file, old, old)
  assert.equal(await withFileLock(dir, name, async () => 'taken'), 'taken')
})

test("a lock is never seen half written, and a dead holder's draft is cleared", async () => {
  const dir = await mkdtemp(join(tmpdir(), 'lock-'))
  const name = 'oauth:y'
  const dead = 2 ** 22 + 54321
  await writeFile(join(dir, `${lockFileName(name)}.${dead}.0badc0de.draft`), '')
  const seen = await withFileLock(dir, name, async () => JSON.parse(await readFile(join(dir, lockFileName(name)), 'utf8')))
  assert.equal(seen.pid, process.pid)
  assert.deepEqual(await readdir(dir), [])
})

test('a key proof is the login key signing one call by one caller about one agent', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'proof-'))
  const keyFile = join(dir, 'k.json')
  const pub = await generateKey(keyFile)
  const key = await loadKey(keyFile)
  const proof = await keyProof(key, { iss: 'did:plc:principal', sub: 'agent.test', aud: 'did:web:pds.test', lxm: 'town.delve.agent.createAgent' })
  const header = decodeProtectedHeader(proof)
  assert.deepEqual(header, { typ: 'agent-key-proof+jwt', alg: 'ES256' })
  const payload = decodeJwt(proof)
  assert.equal(payload.iss, 'did:plc:principal')
  assert.equal(payload.sub, 'agent.test')
  assert.equal(payload.aud, 'did:web:pds.test')
  assert.equal(payload.lxm, 'town.delve.agent.createAgent')
  assert.ok(payload.jti && payload.iat)
  await jwtVerify(proof, await importJWK(key.jwk, 'ES256'))
  assert.match(pub.didKey, /^did:key:zDn/)
})

test("a space post's text is held to town.delve.feed.post's limits, not app.bsky's", () => {
  const post = (text: string) => ({ $type: 'town.delve.feed.post', text, createdAt: '2026-11-27T00:00:00.000Z' })
  assert.equal(townPost.safeParse(post('a'.repeat(301))).success, true)
  assert.equal(townPost.safeParse(post('a'.repeat(100000))).success, true)
  assert.equal(townPost.safeParse(post('a'.repeat(100001))).success, false)
})
