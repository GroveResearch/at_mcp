// A record as its repository proves it: com.atproto.sync.getRecord's CAR
// (the record, its path in the repository's tree, and the signed commit),
// verified against the repository's signing key from its DID document. A
// record whose JSON says the right thing but whose proof doesn't hold is
// refused, never taken for the record.

import { verifyRecords } from '@atproto/repo'
import { lexToJson, type LexValue } from '@atproto/lex'
import { indeterminate, refused } from './errors.ts'

export type VerifyArgs = {
  pds: string
  did: string
  collection: string
  rkey: string
  signingKey: string
}

export async function verifiedRecord(
  { pds, did, collection, rkey, signingKey }: VerifyArgs,
  allowHttp = false,
  fetchImpl: typeof globalThis.fetch = globalThis.fetch,
): Promise<{ found: boolean; record?: unknown; cid?: string }> {
  const base = new URL(pds)
  if (base.protocol !== 'https:' && !(allowHttp && base.protocol === 'http:')) {
    throw refused('InsecureService', `${pds} isn't https`)
  }
  const url = new URL('/xrpc/com.atproto.sync.getRecord', base)
  url.searchParams.set('did', did)
  url.searchParams.set('collection', collection)
  url.searchParams.set('rkey', rkey)

  let res: Response
  try {
    res = await fetchImpl(url, { redirect: 'error' })
  } catch (err) {
    throw indeterminate('transport', `${url.host} didn't answer: ${String(err)}`)
  }
  if (res.status === 400 || res.status === 404) {
    const body = (await res.json().catch(() => ({}))) as { error?: string }
    if (body.error === 'RecordNotFound' || res.status === 404) return { found: false }
    throw refused(body.error ?? 'InvalidRequest', `getRecord refused (${res.status})`)
  }
  if (!res.ok) throw indeterminate('upstream', `getRecord answered ${res.status}`)

  const car = new Uint8Array(await res.arrayBuffer())
  let claims
  try {
    claims = await verifyRecords(car, did, signingKey)
  } catch (err) {
    throw refused('ProofInvalid', `the repository's proof for ${collection}/${rkey} doesn't hold: ${String(err)}`)
  }
  const claim = claims.find((c) => c.collection === collection && c.rkey === rkey)
  // A proof of the record's absence verifies with no record in it.
  if (!claim || claim.record === null || claim.record === undefined) return { found: false }
  return { found: true, record: lexToJson(claim.record as LexValue) }
}
