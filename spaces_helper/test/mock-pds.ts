// A stand-in for the town PDS's authorization server with the signed
// authorize path (Welcome Mat's agent-authorization extension), and a PLC directory and
// handle resolver for one account. Enough of atproto OAuth for a stock
// oauth-client to complete a login: metadata, PAR, authorize (preview and
// signed consent), token and refresh. It checks what the real path will
// check: the wm+jwt's signature and `cnf.jkt`, the proof's `htu`, `ath` and
// nonce, single use of the proof's `jti` and of the `request_uri`, and that
// `login_hint` names the account whose key signed.
import { createServer, type IncomingMessage, type Server } from 'node:http'
import { createHash, randomBytes } from 'node:crypto'
import { calculateJwkThumbprint, decodeProtectedHeader, importJWK, jwtVerify, type JWK } from 'jose'

export type MockPds = {
  url: string
  did: string
  handle: string
  enroll(jkt: string): void
  revokeKey(): void
  previews: number
  consents: number
  tokensIssued: number
  refreshes: number
  noExtension?: boolean
  previewOverride?: (preview: Record<string, unknown>) => Record<string, unknown>
  accessTokenTtl: number
  userAgents: string[]
  lastAccessToken?: string
  close(): Promise<void>
}

const read = (req: IncomingMessage) =>
  new Promise<string>((resolve) => {
    let s = ''
    req.on('data', (c) => (s += c))
    req.on('end', () => resolve(s))
  })

export async function startMockPds(): Promise<MockPds> {
  const did = 'did:plc:agenttestaaaaaaaaaaaaaaa'
  const handle = 'agent.test'
  let enrolled: string | null = null
  const requests = new Map<string, { params: URLSearchParams; used: boolean }>()
  const codes = new Map<string, { scope: string; clientId: string; redirect: string; challenge: string }>()
  const refreshTokens = new Map<string, string>()
  const usedJti = new Set<string>()
  let nonce = randomBytes(8).toString('hex')

  const state = {} as MockPds
  let origin = ''

  const server: Server = createServer(async (req, res) => {
    const url = new URL(req.url!, origin)
    state.userAgents.push(String(req.headers['user-agent'] ?? ''))
    if (process.env.MOCK_DEBUG) console.error('MOCK', req.method, req.url)
    const send = (status: number, body: unknown, headers: Record<string, string> = {}) => {
      res.writeHead(status, { 'content-type': 'application/json', 'dpop-nonce': nonce, ...headers })
      res.end(JSON.stringify(body))
    }
    try {
      if (decodeURIComponent(url.pathname) === `/${did}`) return send(200, didDoc())
      if (url.pathname === '/xrpc/com.atproto.identity.resolveHandle') {
        return url.searchParams.get('handle') === handle ? send(200, { did }) : send(400, { error: 'InvalidRequest' })
      }
      if (url.pathname === '/.well-known/oauth-protected-resource') {
        return send(200, { resource: origin, authorization_servers: [origin], scopes_supported: [], bearer_methods_supported: ['header'] })
      }
      if (url.pathname === '/.well-known/oauth-authorization-server') return send(200, asMetadata())
      if (url.pathname === '/oauth/par' && req.method === 'POST') {
        const params = new URLSearchParams(await read(req))
        const requestUri = `urn:ietf:params:oauth:request_uri:req-${randomBytes(8).toString('hex')}`
        requests.set(requestUri, { params, used: false })
        return send(201, { request_uri: requestUri, expires_in: 300 })
      }
      if (url.pathname === '/oauth/authorize' && req.method === 'GET') return authorize(req, url, send, res)
      if (url.pathname === '/oauth/token' && req.method === 'POST') {
        const params = new URLSearchParams(await read(req))
        if (params.get('grant_type') === 'authorization_code') {
          const code = codes.get(params.get('code') ?? '')
          if (!code) return send(400, { error: 'invalid_grant' })
          codes.delete(params.get('code')!)
          const challenge = createHash('sha256').update(params.get('code_verifier') ?? '').digest('base64url')
          if (challenge !== code.challenge) return send(400, { error: 'invalid_grant', error_description: 'pkce' })
          return send(200, tokens(code.scope))
        }
        if (params.get('grant_type') === 'refresh_token') {
          const scope = refreshTokens.get(params.get('refresh_token') ?? '')
          if (!scope || !enrolled) return send(400, { error: 'invalid_grant' })
          refreshTokens.delete(params.get('refresh_token')!)
          state.refreshes++
          return send(200, tokens(scope))
        }
        return send(400, { error: 'unsupported_grant_type' })
      }
      if (url.pathname === '/oauth/revoke') return send(200, {})
      send(404, { error: 'NotFound' })
    } catch (err) {
      // A fixed body: the error itself goes to this test's own log only.
      if (process.env.MOCK_DEBUG) console.error('MOCK error', err)
      send(500, { error: 'InternalServerError', message: 'the mock failed' })
    }
  })

  function tokens(scope: string) {
    const access = `at-${randomBytes(12).toString('hex')}`
    const refresh = `rt-${randomBytes(12).toString('hex')}`
    refreshTokens.set(refresh, scope)
    state.tokensIssued++
    state.lastAccessToken = access
    return { access_token: access, token_type: 'DPoP', refresh_token: refresh, expires_in: state.accessTokenTtl, scope, sub: did }
  }

  async function authorize(
    req: IncomingMessage,
    url: URL,
    send: (s: number, b: unknown, h?: Record<string, string>) => void,
    res: import('node:http').ServerResponse,
  ) {
    const requestUri = url.searchParams.get('request_uri') ?? ''
    const pending = requests.get(requestUri)
    if (!pending || pending.used) return send(400, { error: 'invalid_request', error_description: 'unknown or used request_uri' })
    const p = pending.params
    const auth = String(req.headers.authorization ?? '')
    if (!auth) {
      const accept = String(req.headers.accept ?? '')
      if (state.noExtension || !accept.includes('application/json')) {
        res.writeHead(200, { 'content-type': 'text/html' })
        return res.end('<html>login page</html>')
      }
      state.previews++
      let preview: Record<string, unknown> = {
        client_id: p.get('client_id'),
        client_metadata: { client_name: 'at_mcp' },
        scope: p.get('scope'),
        redirect_uri: p.get('redirect_uri'),
        login_hint: p.get('login_hint'),
      }
      if (state.previewOverride) preview = state.previewOverride(preview)
      return send(200, { consent_request: preview, how_to_consent: 'sign it' })
    }
    if (!auth.startsWith('DPoP ')) return send(401, { error: 'invalid_token' })
    const wm = auth.slice(5)
    const proof = String(req.headers.dpop ?? '')
    const header = decodeProtectedHeader(proof)
    const jwk = header.jwk as JWK
    const key = await importJWK(jwk, 'ES256')
    const { payload: pp } = await jwtVerify(proof, key, { typ: 'dpop+jwt' })
    if (pp.htu !== `${origin}/oauth/authorize` || pp.htm !== 'GET') return send(401, { error: 'invalid_dpop_proof' })
    if (pp.nonce !== nonce) return send(401, { error: 'use_dpop_nonce' })
    if (usedJti.has(String(pp.jti))) return send(401, { error: 'invalid_dpop_proof', error_description: 'replayed' })
    usedJti.add(String(pp.jti))
    if (pp.ath !== createHash('sha256').update(wm).digest('base64url')) return send(401, { error: 'invalid_dpop_proof' })
    const { payload: wp } = await jwtVerify(wm, key, { typ: 'wm+jwt', audience: origin })
    const jkt = await calculateJwkThumbprint(jwk, 'sha256')
    if ((wp.cnf as { jkt?: string })?.jkt !== jkt) return send(401, { error: 'invalid_token' })
    if (jkt !== enrolled) return send(401, { error: 'invalid_token', error_description: 'key not enrolled' })
    const hint = p.get('login_hint')
    if (hint && hint !== handle && hint !== did) return send(403, { error: 'access_denied' })
    pending.used = true
    state.consents++
    const redirect = new URL(p.get('redirect_uri')!)
    if (url.searchParams.get('deny') === '1') {
      redirect.searchParams.set('error', 'access_denied')
    } else {
      const code = `cod-${randomBytes(8).toString('hex')}`
      codes.set(code, {
        scope: p.get('scope')!,
        clientId: p.get('client_id')!,
        redirect: p.get('redirect_uri')!,
        challenge: p.get('code_challenge')!,
      })
      redirect.searchParams.set('code', code)
    }
    if (p.get('state')) redirect.searchParams.set('state', p.get('state')!)
    redirect.searchParams.set('iss', origin)
    nonce = randomBytes(8).toString('hex')
    res.writeHead(303, { location: redirect.toString(), 'dpop-nonce': nonce })
    res.end()
  }

  function didDoc() {
    return {
      '@context': ['https://www.w3.org/ns/did/v1'],
      id: did,
      alsoKnownAs: [`at://${handle}`],
      verificationMethod: [],
      service: [{ id: '#atproto_pds', type: 'AtprotoPersonalDataServer', serviceEndpoint: origin }],
    }
  }

  function asMetadata() {
    return {
      issuer: origin,
      authorization_endpoint: `${origin}/oauth/authorize`,
      token_endpoint: `${origin}/oauth/token`,
      pushed_authorization_request_endpoint: `${origin}/oauth/par`,
      revocation_endpoint: `${origin}/oauth/revoke`,
      require_pushed_authorization_requests: true,
      response_types_supported: ['code'],
      grant_types_supported: ['authorization_code', 'refresh_token'],
      code_challenge_methods_supported: ['S256'],
      token_endpoint_auth_methods_supported: ['none', 'private_key_jwt'],
      token_endpoint_auth_signing_alg_values_supported: ['ES256'],
      // ES256K first, as the reference PDS lists it.
      dpop_signing_alg_values_supported: ['ES256K', 'ES256'],
      scopes_supported: ['atproto'],
      authorization_response_iss_parameter_supported: true,
      client_id_metadata_document_supported: true,
      protected_resources: [origin],
      require_request_uri_registration: true,
      request_parameter_supported: false,
      request_uri_parameter_supported: true,
      response_modes_supported: ['query', 'fragment', 'form_post'],
      subject_types_supported: ['public'],
      prompt_values_supported: ['none', 'login', 'consent', 'select_account', 'create'],
    }
  }

  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve))
  const port = (server.address() as { port: number }).port
  origin = `http://127.0.0.1:${port}`
  Object.assign(state, {
    url: origin,
    did,
    handle,
    enroll: (jkt: string) => (enrolled = jkt),
    revokeKey: () => {
      enrolled = null
      refreshTokens.clear()
    },
    previews: 0,
    consents: 0,
    tokensIssued: 0,
    refreshes: 0,
    accessTokenTtl: 3600,
    userAgents: [],
    close: () => new Promise<void>((r) => server.close(() => r())),
  })
  return state
}
