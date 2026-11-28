import { test } from 'node:test'
import assert from 'node:assert/strict'
import { Secp256k1Keypair } from '@atproto/crypto'
import { MemoryBlockstore, Repo, WriteOpAction, getRecords } from '@atproto/repo'
import { verifiedRecord } from '../src/records.ts'

const did = 'did:plc:principal'
const collection = 'link.ident.endorsement'
const agent = 'did:plc:agent'

// A principal's repository holding its endorsement of the agent, and
// getRecord's CAR for a path in it, as the PDS serves it.
async function repository() {
  const key = await Secp256k1Keypair.create()
  const storage = new MemoryBlockstore()
  const repo = await Repo.create(storage, did, key, [
    {
      action: WriteOpAction.Create,
      collection,
      rkey: agent,
      record: { $type: collection, agent, createdAt: '2026-11-28T00:00:00.000Z' },
    },
  ])
  const car = async (rkey: string) => {
    const chunks: Uint8Array[] = []
    for await (const c of getRecords(storage, repo.cid, [{ collection, rkey }])) chunks.push(c)
    return Buffer.concat(chunks)
  }
  return { key, car }
}

const serving = (bytes: Uint8Array) =>
  (async () => new Response(bytes, { status: 200 })) as unknown as typeof fetch

const args = (signingKey: string, rkey = agent) => ({
  pds: 'https://pds.example',
  did,
  collection,
  rkey,
  signingKey,
})

test('a record its repository proves is taken, with what it says', async () => {
  const { key, car } = await repository()
  const got = await verifiedRecord(args(key.did()), false, serving(await car(agent)))
  assert.equal(got.found, true)
  assert.equal((got.record as { agent: string }).agent, agent)
})

test("a proof signed by another key than the DID document's is refused", async () => {
  const { car } = await repository()
  const other = await Secp256k1Keypair.create()
  await assert.rejects(verifiedRecord(args(other.did()), false, serving(await car(agent))), (e: { code: string }) => {
    assert.equal(e.code, 'ProofInvalid')
    return true
  })
})

test('a proof that the record is absent says so', async () => {
  const { key, car } = await repository()
  const got = await verifiedRecord(args(key.did(), 'did:plc:someone-else'), false, serving(await car('did:plc:someone-else')))
  assert.equal(got.found, false)
})

test('plain http is refused unless allowed', async () => {
  await assert.rejects(verifiedRecord({ ...args('did:key:x'), pds: 'http://pds.example' }), (e: { code: string }) => e.code === 'InsecureService')
})
