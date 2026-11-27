import { test } from 'node:test'
import assert from 'node:assert/strict'
import { createServer } from 'node:http'
import { decodeJwt } from 'jose'
import { asGroup } from '../src/group.ts'

// A stand-in group host: its resource name, a group token for a service
// token, a nonce it asks for once, and the calls made as the group.
async function host() {
  const seen: { method: string; auth: string; proof: Record<string, unknown>; body: unknown }[] = []
  let asked = false
  const server = createServer(async (req, res) => {
    let raw = ''
    for await (const chunk of req) raw += chunk
    const url = new URL(req.url!, 'http://x')
    if (url.pathname === '/.well-known/oauth-protected-resource') {
      res.writeHead(200, { 'content-type': 'application/json' })
      return res.end(JSON.stringify({ resource: 'https://groups.example' }))
    }
    const method = url.pathname.replace('/xrpc/', '')
    const proof = decodeJwt(String(req.headers.dpop))
    if (!asked) {
      asked = true
      res.writeHead(401, { 'www-authenticate': 'DPoP error="use_dpop_nonce"', 'dpop-nonce': 'n1' })
      return res.end(JSON.stringify({ error: 'use_dpop_nonce' }))
    }
    seen.push({ method, auth: String(req.headers.authorization), proof, body: JSON.parse(raw) })
    if (method === 'com.atproto.space.putRecord') {
      res.writeHead(400, { 'content-type': 'application/json' })
      return res.end(JSON.stringify({ error: 'InvalidRecord', message: 'no' }))
    }
    res.writeHead(200, { 'content-type': 'application/json' })
    if (method === 'org.atgrp.internal.getGroupAuth') return res.end(JSON.stringify({ accessJwt: 'group-token' }))
    res.end(JSON.stringify({ uri: 'at:space/g/x/y', cid: 'c' }))
  })
  await new Promise<void>((r) => server.listen(0, '127.0.0.1', r))
  const port = (server.address() as { port: number }).port
  return { url: `http://127.0.0.1:${port}`, seen, close: () => { server.closeAllConnections(); server.close() } }
}

test('acting as a group: a group token for a service token, then calls with it, each with a fresh proof', async () => {
  const h = await host()
  try {
    const out = await asGroup(fetch, {
      hostUrl: h.url,
      serviceToken: 'svc',
      group: 'did:plc:g',
      space: 'at:space/did:plc:p/org.atgrp.inbox/self',
      calls: [{ method: 'com.atproto.space.createRecord', body: { repo: 'did:plc:g' } }],
    })
    assert.deepEqual(out.results, [{ uri: 'at:space/g/x/y', cid: 'c' }])
    const [auth, call] = h.seen
    assert.equal(auth.method, 'org.atgrp.internal.getGroupAuth')
    assert.equal(auth.auth, 'Bearer svc')
    assert.deepEqual(auth.body, { group: 'did:plc:g', space: 'at:space/did:plc:p/org.atgrp.inbox/self' })
    // The proof names the host as it names itself, with the nonce it asked for.
    assert.equal(auth.proof.htu, 'https://groups.example/xrpc/org.atgrp.internal.getGroupAuth')
    assert.equal(auth.proof.nonce, 'n1')
    assert.equal(call.auth, 'DPoP group-token')
    assert.ok(call.proof.ath)
    assert.notEqual(call.proof.jti, auth.proof.jti)
  } finally {
    h.close()
  }
})

test("a group host's refusal is the helper's refusal, naming the host's error", async () => {
  const h = await host()
  try {
    await assert.rejects(
      asGroup(fetch, {
        hostUrl: h.url,
        serviceToken: 'svc',
        group: 'did:plc:g',
        space: 'at:space/did:plc:g/org.atgrp.members/self',
        calls: [{ method: 'com.atproto.space.putRecord', body: {} }],
      }),
      (err: { failureClass: string; code: string }) => err.failureClass === 'refused' && err.code === 'InvalidRecord',
    )
  } finally {
    h.close()
  }
})
