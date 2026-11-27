// Acting as a group: a group token from the group's host
// (`org.atgrp.internal.getGroupAuth`), bound to a DPoP key made for it alone,
// then calls as the group with it. The host is the group's PDS and
// authorization server; the caller proves who it is with a service token
// from its own PDS, and the token's scopes are what its roles in the group
// allow in `space`. This is how a founder makes the group's first spaces,
// invites people, and admits members. It follows group-host's own client
// (`atgrp`'s GroupSession): the proof names the host as it names itself
// (`/.well-known/oauth-protected-resource`'s `resource`), and a call the
// host answers with `use_dpop_nonce` is sent once more with its nonce.
import { exportJWK, generateKeyPair } from 'jose'
import { refused, indeterminate } from './errors.ts'
import { dpopProof, type LoginKey } from './keys.ts'

export type GroupCall = { method: string; body: Record<string, unknown> }

export async function asGroup(
  fetch: typeof globalThis.fetch,
  {
    hostUrl,
    serviceToken,
    group,
    space,
    calls,
  }: { hostUrl: string; serviceToken: string; group: string; space: string; calls: GroupCall[] },
) {
  const base = hostUrl.replace(/\/+$/, '')
  const meta = await read(await fetch(`${base}/.well-known/oauth-protected-resource`), 'the host\'s metadata')
  const resource = String((meta as { resource?: string }).resource ?? base).replace(/\/+$/, '')
  const pair = await generateKeyPair('ES256', { extractable: true })
  const key = { jwk: await exportJWK(pair.publicKey), privateKey: pair.privateKey } as unknown as LoginKey
  let nonce: string | undefined

  const post = async (method: string, authorization: string, token: string | undefined, body: unknown) => {
    for (let attempt = 0; ; attempt++) {
      const proof = await dpopProof(key, 'POST', `${resource}/xrpc/${method}`, { accessToken: token, nonce })
      const res = await fetch(`${base}/xrpc/${method}`, {
        method: 'POST',
        headers: { authorization, dpop: proof, 'content-type': 'application/json' },
        body: JSON.stringify(body),
      })
      const given = res.headers.get('dpop-nonce')
      if (given) nonce = given
      const stale = (res.headers.get('www-authenticate') ?? '').includes('use_dpop_nonce')
      if (stale && attempt === 0) continue
      return read(res, method)
    }
  }

  const auth = (await post('org.atgrp.internal.getGroupAuth', `Bearer ${serviceToken}`, undefined, {
    group,
    space,
  })) as { accessJwt?: string }
  if (!auth.accessJwt) throw refused('GroupAuthRefused', 'the group host gave no group token')
  const token = auth.accessJwt
  const results: unknown[] = []
  for (const call of calls) results.push(await post(call.method, `DPoP ${token}`, token, call.body))
  return { results }
}

async function read(res: Response, what: string): Promise<unknown> {
  const text = await res.text()
  let body: unknown = {}
  try {
    body = text ? JSON.parse(text) : {}
  } catch {
    body = { message: text.slice(0, 300) }
  }
  if (res.ok) return body
  const { error, message } = body as { error?: string; message?: string }
  const said = `${what} answered ${res.status}${error ? ` ${error}` : ''}${message ? `: ${message}` : ''}`
  if (res.status >= 500) throw indeterminate(error ?? `Status${res.status}`, said, { status: res.status })
  throw refused(error ?? `Status${res.status}`, said, { status: res.status })
}
