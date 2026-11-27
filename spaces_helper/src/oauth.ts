// OAuth sessions per account, approved by the account's own login key.
//
// at_mcp is a loopback public client (`http://localhost?...`), so it needs no
// hosted metadata. An authorization is approved the way Welcome Mat's
// agent-authorization extension describes: fetch the authorize URL without
// credentials and read the JSON preview; check in code that it is exactly
// the request this helper made; then fetch it again signed with the login key.
// That signed fetch is the login and the consent, and the PDS answers with
// the redirect carrying the code, which goes to the client's `callback()`.
//
// The helper is the only holder of each session's refresh token. at_mcp asks
// for `credentials` (the access token and the session's DPoP key) and signs
// its own requests with them; it asks again when the token nears expiry or a
// request is refused as an invalid token.
import {
  NodeOAuthClient,
  type NodeSavedSession,
  type NodeSavedState,
  type OAuthSession,
} from '@atproto/oauth-client-node'
import { buildAtprotoLoopbackClientId } from '@atproto/oauth-types'
import { JoseKey } from '@atproto/jwk-jose'
import { createHash, randomBytes } from 'node:crypto'
import { authRefused, HelperError, indeterminate, refused } from './errors.ts'
import { dpopProof, loadKey, type LoginKey, wmToken } from './keys.ts'
import { FileStore, MemoryStore } from './store.ts'
import type { Log } from './log.ts'
import { withFileLock } from './lock.ts'
import { join } from 'node:path'

export const REDIRECT_URI = 'http://127.0.0.1/callback'

export type OAuthConfig = {
  stateDir: string
  fetch: typeof globalThis.fetch
  log: Log
  plcDirectoryUrl?: string
  handleResolver?: string
  allowHttp?: boolean
  tosHash?: string
}

export type Credentials = {
  did: string
  accessToken: string
  dpopJwk: Record<string, unknown>
  serviceUrl: string
  issuer: string
  scope: string
  expiresAt: string | null
}

export type Relogin = { account: string; keyFile: string; scope: string }

const scopeSet = (s: string) => new Set(s.split(/\s+/).filter(Boolean))
const sameScopes = (a: string, b: string) => {
  const x = scopeSet(a)
  const y = scopeSet(b)
  return x.size === y.size && [...x].every((s) => y.has(s))
}

export class OAuthSessions {
  readonly sessions: FileStore<NodeSavedSession>
  /** Called with the account's DID whenever it gets a new session (a login). */
  onNewSession: (did: string) => void = () => {}
  #clients = new Map<string, NodeOAuthClient>()

  constructor(readonly config: OAuthConfig) {
    this.sessions = new FileStore(`${config.stateDir}/oauth-sessions.json`)
  }

  // One client per scope, since a loopback client's id carries its scope.
  client(scope: string): NodeOAuthClient {
    const known = this.#clients.get(scope)
    if (known) return known
    const clientId = buildAtprotoLoopbackClientId({
      scope,
      redirect_uris: [REDIRECT_URI],
    })
    const client = new NodeOAuthClient({
      clientMetadata: {
        client_id: clientId,
        redirect_uris: [REDIRECT_URI],
        scope,
        response_types: ['code'],
        grant_types: ['authorization_code', 'refresh_token'],
        token_endpoint_auth_method: 'none',
        application_type: 'native',
        dpop_bound_access_tokens: true,
      },
      stateStore: new MemoryStore<NodeSavedState>(),
      sessionStore: this.sessions,
      fetch: this.config.fetch,
      allowHttp: this.config.allowHttp,
      plcDirectoryUrl: this.config.plcDirectoryUrl,
      handleResolver: this.config.handleResolver,
      runtimeImplementation: {
        // A refresh token is good for one refresh, and several at_mcp
        // processes may share this state folder: the client's refresh lock
        // is a lock file there.
        requestLock: (name: string, fn: () => unknown) =>
          withFileLock(join(this.config.stateDir, 'locks'), `oauth:${name}`, async () => fn()),
        // Every session's DPoP key is P-256 (ES256): at_mcp signs its own
        // requests with it (proto_rune's DPoP signs ES256 only), and atproto
        // OAuth requires servers to take ES256. Left to itself the client
        // takes the first algorithm the server lists, which may be ES256K.
        createKey: (algs: string[]) => {
          if (!algs.includes('ES256')) {
            throw new Error(`the authorization server does not take ES256 DPoP proofs (${algs.join(', ')})`)
          }
          return JoseKey.generate(['ES256'])
        },
        getRandomValues: randomBytes,
        digest: (bytes: Uint8Array, algorithm: { name: string }) =>
          createHash(algorithm.name).update(bytes).digest(),
      },
    } as ConstructorParameters<typeof NodeOAuthClient>[0])
    this.#clients.set(scope, client)
    return client
  }

  /** Logs `account` in with the key at `keyFile`, for `scope`. */
  async login({ account, keyFile, scope }: Relogin) {
    const key = await loadKey(keyFile)
    const client = this.client(scope)
    let url: URL
    try {
      url = await client.authorize(account, { scope })
    } catch (err) {
      const cause = (err as { cause?: Error }).cause
      throw refused('authorize_failed', `could not start an authorization for ${account}: ${(err as Error).message}${cause ? ` (${cause.message})` : ''}`)
    }
    const code = await this.approve(url, key, {
      clientId: client.clientMetadata.client_id,
      redirectUri: REDIRECT_URI,
      scope,
      account,
    })
      .then((location) => location.searchParams)
      .catch(async (err) => {
        await client.abortRequest(url).catch(() => {})
        throw err
      })
    const { session } = await client.callback(code, { redirect_uri: REDIRECT_URI })
    // A new session has a new DPoP key: anything holding the old one goes.
    this.onNewSession(session.did)
    const info = await session.getTokenInfo(false)
    this.config.log('info', 'oauth login approved by the account key', {
      did: session.did,
      scope: info.scope,
    })
    return { did: session.did, scope: info.scope, expiresAt: info.expiresAt?.toISOString() ?? null }
  }

  /**
   * The preview, the check and the signed fetch. Answers the callback's
   * parameters. Nothing is signed unless the preview names exactly this
   * client, this redirect, these scopes and this account.
   */
  async approve(
    url: URL,
    key: LoginKey,
    expected: {
      clientId: string
      scope: string
      account: string
      /** The exact redirect, for this helper's own client. */
      redirectUri?: string
      /** For another client's request: the origin its redirect must be on. */
      redirectOrigin?: string
    },
  ): Promise<URL> {
    const fetch = this.config.fetch
    const preview = await fetch(url, {
      headers: { accept: 'application/json' },
      redirect: 'manual',
    })
    const type = preview.headers.get('content-type') ?? ''
    if (!preview.ok || !type.includes('application/json')) {
      throw refused(
        'signed_authorize_unsupported',
        `the authorization server at ${url.origin} gave no JSON preview (HTTP ${preview.status}); it does not offer agent authorization by key`,
      )
    }
    const body = (await preview.json()) as { consent_request?: Record<string, unknown> }
    const req = body.consent_request ?? {}
    const mismatches: string[] = []
    if (req.client_id !== expected.clientId) mismatches.push('client_id')
    if (expected.redirectUri != null && req.redirect_uri !== expected.redirectUri) mismatches.push('redirect_uri')
    if (expected.redirectOrigin != null) {
      let origin: string | undefined
      try {
        origin = new URL(String(req.redirect_uri)).origin
      } catch {}
      if (origin !== expected.redirectOrigin) mismatches.push('redirect_uri')
    }
    if (typeof req.scope !== 'string' || !sameScopes(req.scope, expected.scope)) mismatches.push('scope')
    if (req.login_hint != null && req.login_hint !== expected.account) mismatches.push('login_hint')
    if (mismatches.length) {
      throw refused(
        'preview_mismatch',
        `the authorization preview differs from the request this helper made (${mismatches.join(', ')}); nothing was signed`,
        { mismatches },
      )
    }

    let nonce = preview.headers.get('dpop-nonce') ?? undefined
    for (let attempt = 0; attempt < 2; attempt++) {
      const token = await wmToken(key, url.origin, { tosHash: this.config.tosHash })
      const proof = await dpopProof(key, 'GET', url, { accessToken: token, nonce })
      const res = await fetch(url, {
        headers: { authorization: `DPoP ${token}`, dpop: proof, accept: 'application/json' },
        redirect: 'manual',
      })
      if (res.status >= 300 && res.status < 400) {
        const location = res.headers.get('location')
        if (!location) throw indeterminate('no_redirect', 'the consent answer had no Location')
        const params = new URL(location).searchParams
        if (params.get('error')) {
          throw refused('consent_denied', `the authorization server answered ${params.get('error')}: ${params.get('error_description') ?? ''}`.trim())
        }
        return new URL(location)
      }
      const err = (await res.json().catch(() => ({}))) as { error?: string; error_description?: string }
      if (res.status === 401 && err.error === 'use_dpop_nonce' && attempt === 0) {
        nonce = res.headers.get('dpop-nonce') ?? nonce
        continue
      }
      if (res.status === 401 && err.error === 'tos_changed') {
        throw refused('tos_changed', 'the service changed its terms; the key must consent to them again before it can authorize anything')
      }
      if (res.status === 401 || res.status === 403) {
        throw authRefused(
          'key_refused',
          `the PDS refused this account's login key (${err.error ?? res.status}). A principal may have revoked the agent or replaced its key; a new key must be enrolled before the account can log in again`,
          { error: err.error, description: err.error_description },
        )
      }
      throw indeterminate('consent_failed', `the consent fetch answered HTTP ${res.status} ${err.error ?? ''}`.trim())
    }
    throw indeterminate('consent_failed', 'the consent fetch kept asking for a new DPoP nonce')
  }

  /**
   * Approves another client's pending request for this account (an
   * app's read grant, such as the town AppView's on the account's inbox)
   * with the account's login key: the same preview, check and signed
   * fetch as its own sign-in. Nothing is signed unless the preview names
   * exactly `clientId`, exactly `scope`, this account, and a redirect on
   * `clientId`'s own origin. Then the redirect is fetched, so the app's
   * callback gets its code.
   */
  async approveFor({
    keyFile,
    account,
    authorizationUrl,
    clientId,
    scope,
  }: { keyFile: string; account: string; authorizationUrl: string; clientId: string; scope: string }) {
    const url = new URL(authorizationUrl)
    if (url.searchParams.get('client_id') !== clientId) {
      throw refused('preview_mismatch', 'the request is not from the app at_mcp approves; nothing was signed', {
        mismatches: ['client_id'],
      })
    }
    const key = await loadKey(keyFile)
    const location = await this.approve(url, key, {
      clientId,
      scope,
      account,
      redirectOrigin: new URL(clientId).origin,
    })
    const delivered = await this.config.fetch(location, { redirect: 'manual' })
    return { approved: true, delivered: delivered.status < 400, status: delivered.status }
  }

  /**
   * What an outside app's authorization request asks, as the authorization
   * server shows it (the JSON preview of agent authorization): its
   * client_id, the name and links its metadata gives, the scopes, the
   * redirect and the login hint. Signs nothing.
   */
  async previewApp({ authorizationUrl }: { authorizationUrl: string }) {
    const url = new URL(authorizationUrl)
    const res = await this.config.fetch(url, { headers: { accept: 'application/json' }, redirect: 'manual' })
    const type = res.headers.get('content-type') ?? ''
    if (!res.ok || !type.includes('application/json')) {
      throw refused(
        'signed_authorize_unsupported',
        `the authorization server at ${url.origin} gave no JSON preview (HTTP ${res.status}); it does not offer agent authorization by key`,
      )
    }
    const body = (await res.json()) as { consent_request?: Record<string, unknown> }
    const req = body.consent_request ?? {}
    const meta = (req.client_metadata ?? {}) as Record<string, unknown>
    return {
      clientId: req.client_id ?? null,
      clientName: meta.client_name ?? null,
      clientUri: meta.client_uri ?? null,
      scope: req.scope ?? null,
      redirectUri: req.redirect_uri ?? null,
      loginHint: req.login_hint ?? null,
    }
  }

  /**
   * Approves an outside app's request with the account's login key, only if
   * it is still exactly what was previewed (client, scope, redirect, and the
   * account), and answers the callback URL, which the agent hands back to
   * the app. The callback is not fetched here.
   */
  async approveApp({
    keyFile,
    account,
    authorizationUrl,
    clientId,
    scope,
    redirectUri,
  }: { keyFile: string; account: string; authorizationUrl: string; clientId: string; scope: string; redirectUri: string }) {
    const key = await loadKey(keyFile)
    const location = await this.approve(new URL(authorizationUrl), key, { clientId, scope, account, redirectUri })
    return { callbackUrl: location.toString() }
  }

  async #restore(did: string, refresh: boolean | 'auto'): Promise<OAuthSession> {
    const saved = await this.sessions.get(did)
    if (!saved) throw authRefused('no_session', `no OAuth session is held for ${did}`)
    return this.client(saved.tokenSet.scope).restore(did, refresh)
  }

  /**
   * The current access token and DPoP key, refreshed first when it is close
   * to expiry (or always, with `refresh`). When the session cannot be
   * refreshed and `relogin` is given, the key logs in again, quietly; only a
   * refusal of the key itself is `auth_refused`.
   */
  async credentials(did: string, { refresh = false, relogin }: { refresh?: boolean; relogin?: Relogin } = {}): Promise<Credentials> {
    try {
      const session = await this.#restore(did, refresh ? true : 'auto')
      await session.getTokenInfo(refresh ? true : 'auto')
    } catch (err) {
      if (err instanceof HelperError && err.code !== 'no_session') throw err
      if (!relogin) {
        throw authRefused('session_lost', `the OAuth session for ${did} can no longer be refreshed (${(err as Error).message}), and no login key was given to log in again`)
      }
      this.config.log('info', 'oauth session could not be refreshed; logging in again with the account key', {
        did,
        cause: (err as Error).message,
      })
      const again = await this.login(relogin)
      if (again.did !== did) {
        throw refused('wrong_account', `the login key logged in as ${again.did}, not ${did}`)
      }
    }
    const saved = await this.sessions.get(did)
    if (!saved) throw indeterminate('no_session', `the session for ${did} disappeared`)
    const { tokenSet, dpopJwk } = saved
    return {
      did,
      accessToken: tokenSet.access_token,
      dpopJwk: dpopJwk as unknown as Record<string, unknown>,
      serviceUrl: tokenSet.aud.replace(/\/+$/, ''),
      issuer: tokenSet.iss,
      scope: tokenSet.scope,
      expiresAt: tokenSet.expires_at ?? null,
    }
  }

  async status(did: string) {
    const saved = await this.sessions.get(did)
    if (!saved) return { did, held: false }
    return {
      did,
      held: true,
      scope: saved.tokenSet.scope,
      issuer: saved.tokenSet.iss,
      expiresAt: saved.tokenSet.expires_at ?? null,
    }
  }

  async logout(did: string) {
    const saved = await this.sessions.get(did)
    if (!saved) return { did, held: false }
    try {
      await this.client(saved.tokenSet.scope).revoke(did)
    } catch (err) {
      this.config.log('warning', 'revoking the session at its server failed; dropped locally', {
        did,
        cause: (err as Error).message,
      })
      await this.sessions.del(did)
    }
    return { did, held: false }
  }

  /** The session itself, for the Spaces calls. */
  session(did: string): Promise<OAuthSession> {
    return this.#restore(did, 'auto')
  }
}
