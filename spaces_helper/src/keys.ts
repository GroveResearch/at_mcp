// The agent's login key: a P-256 private JWK in a 0600 file of its own.
//
// Only this module reads it, and only to sign. Nothing it returns carries the
// private part: callers get the did:key and the JWK thumbprint (`jkt`), which
// is how the PDS knows the key.
import { P256Keypair } from '@atproto/crypto'
import {
  type JWK,
  type KeyLike,
  SignJWT,
  calculateJwkThumbprint,
  exportJWK,
  generateKeyPair,
  importJWK,
} from 'jose'
import { createHash, randomUUID } from 'node:crypto'
import { PrivateFileError, readPrivateJson, writePrivateJson } from './files.ts'

export type PublicKeyInfo = { didKey: string; jkt: string; jwk: JWK }

export type LoginKey = PublicKeyInfo & { privateKey: KeyLike | Uint8Array }

function publicPart(jwk: JWK): JWK {
  const { kty, crv, x, y } = jwk
  return { kty, crv, x, y }
}

async function info(jwk: JWK): Promise<PublicKeyInfo> {
  const pub = publicPart(jwk)
  const d = Buffer.from(jwk.d!, 'base64url')
  const keypair = await P256Keypair.import(d)
  return {
    didKey: keypair.did(),
    jkt: await calculateJwkThumbprint(pub, 'sha256'),
    jwk: pub,
  }
}

export async function loadKey(keyFile: string): Promise<LoginKey> {
  const jwk = await readPrivateJson<JWK>(keyFile)
  if (jwk.kty !== 'EC' || jwk.crv !== 'P-256' || !jwk.d || !jwk.x || !jwk.y) {
    throw new PrivateFileError(
      'file_corrupt',
      `${keyFile} is not a P-256 private JWK`,
    )
  }
  const privateKey = await importJWK(jwk, 'ES256')
  return { ...(await info(jwk)), privateKey }
}

/** Makes a new key at `keyFile`. Refuses to replace anything already there. */
export async function generateKey(keyFile: string): Promise<PublicKeyInfo> {
  const { privateKey } = await generateKeyPair('ES256', { extractable: true })
  const jwk = await exportJWK(privateKey)
  const stored: JWK = { kty: jwk.kty, crv: jwk.crv, x: jwk.x, y: jwk.y, d: jwk.d }
  await writePrivateJson(keyFile, stored, { exclusive: true })
  return info(stored)
}

export async function publicKey(keyFile: string): Promise<PublicKeyInfo> {
  const { didKey, jkt, jwk } = await loadKey(keyFile)
  return { didKey, jkt, jwk }
}

const b64urlSha256 = (s: string) =>
  createHash('sha256').update(s).digest('base64url')

/**
 * Welcome Mat's self-signed access token (spec 1.1, "access token"): `typ`
 * `wm+jwt`, bound to the key by `cnf.jkt`, for the service at `aud` (its
 * origin). `tosHash` binds it to the terms text when the service asks.
 */
export async function wmToken(
  key: LoginKey,
  aud: string,
  { tosHash, now = Date.now() }: { tosHash?: string; now?: number } = {},
): Promise<string> {
  const payload: Record<string, unknown> = {
    jti: randomUUID(),
    aud,
    cnf: { jkt: key.jkt },
    iat: Math.floor(now / 1000),
  }
  if (tosHash) payload.tos_hash = tosHash
  return new SignJWT(payload)
    .setProtectedHeader({ typ: 'wm+jwt', alg: 'ES256' })
    .sign(key.privateKey)
}

/**
 * An RFC 9449 proof for `htm` `htu` (the target without query or fragment),
 * with `ath` for `accessToken` and the server's `nonce` when it gave one.
 */
export async function dpopProof(
  key: LoginKey,
  htm: string,
  url: string | URL,
  {
    accessToken,
    nonce,
    now = Date.now(),
  }: { accessToken?: string; nonce?: string; now?: number } = {},
): Promise<string> {
  const target = new URL(url)
  const htu = `${target.origin}${target.pathname}`
  const payload: Record<string, unknown> = {
    jti: randomUUID(),
    htm,
    htu,
    iat: Math.floor(now / 1000),
  }
  if (accessToken) payload.ath = b64urlSha256(accessToken)
  if (nonce) payload.nonce = nonce
  return new SignJWT(payload)
    .setProtectedHeader({ typ: 'dpop+jwt', alg: 'ES256', jwk: key.jwk })
    .sign(key.privateKey)
}

export const tosHashOf = (text: string) => b64urlSha256(text)

/**
 * Proof that the caller holds the login key it enrolls (`loginKeyProof`, the
 * town PDS's `town.delve.agent.createAgent` and `enrollKey`): a compact JWS
 * by the key, `typ` `agent-key-proof+jwt`, for one call by one caller about
 * one agent. The PDS checks it against the `loginKey` did:key in the same
 * body, so the header carries no key.
 */
export async function keyProof(
  key: LoginKey,
  { iss, sub, aud, lxm, now = Date.now() }: { iss: string; sub: string; aud: string; lxm: string; now?: number },
): Promise<string> {
  return new SignJWT({ iss, sub, aud, lxm, jti: randomUUID(), iat: Math.floor(now / 1000) })
    .setProtectedHeader({ typ: 'agent-key-proof+jwt', alg: 'ES256' })
    .sign(key.privateKey)
}
