// at_mcp-spaces: at_mcp's helper for OAuth sessions and Spaces.
//
// It speaks JSON-RPC 2.0 on stdio, one JSON object per line, to the one
// at_mcp process that started it, and stops when its input ends. The first
// call is `init`, with the configuration; every other call names an account
// by DID. Log lines go out as `log` notifications on stdout, so nothing else
// shares the channel.
import { createInterface } from 'node:readline'
import { HelperError } from './errors.ts'
import { generateKey, keyProof, loadKey, publicKey } from './keys.ts'
import type { Log } from './log.ts'
import { OAuthSessions } from './oauth.ts'
import { Spaces } from './spaces.ts'
import { asGroup } from './group.ts'

export const PROTOCOL = 1
export const HELPER_VERSION = '0.1.0'

type Init = {
  stateDir: string
  userAgent: string
  plcDirectoryUrl?: string
  handleResolver?: string
  allowHttp?: boolean
  inboxReaders?: string[]
  tosHash?: string
}

type Handler = (params: Record<string, any>) => Promise<unknown>

export class Helper {
  oauth?: OAuthSessions
  spaces?: Spaces
  fetch?: typeof globalThis.fetch
  constructor(
    readonly log: Log,
    readonly baseFetch: typeof globalThis.fetch = globalThis.fetch,
  ) {}

  init(config: Init) {
    const ua = config.userAgent
    // Every request the helper makes names at_mcp, so a service's logs show
    // at_mcp use exactly.
    const fetch: typeof globalThis.fetch = (input, init) => {
      const req = new Request(input as RequestInfo, init)
      if (!req.headers.has('user-agent') || !req.headers.get('user-agent')!.startsWith('at_mcp/')) {
        req.headers.set('user-agent', ua)
      }
      return this.baseFetch(req, init?.redirect ? { redirect: init.redirect } : undefined)
    }
    this.fetch = fetch
    this.oauth = new OAuthSessions({
      stateDir: config.stateDir,
      fetch,
      log: this.log,
      plcDirectoryUrl: config.plcDirectoryUrl,
      handleResolver: config.handleResolver,
      allowHttp: config.allowHttp,
      tosHash: config.tosHash,
    })
    this.spaces = new Spaces(
      {
        stateDir: config.stateDir,
        fetch,
        plcDirectoryUrl: config.plcDirectoryUrl,
        inboxReaders: config.inboxReaders ?? [],
      },
      this.oauth,
    )
    // A space client is bound to the session it was opened with, DPoP key
    // and all, so a new login drops the account's open spaces.
    this.oauth.onNewSession = (did) => this.spaces?.forget(did)
    return { protocol: PROTOCOL, version: HELPER_VERSION }
  }

  get #o() {
    if (!this.oauth) throw new HelperError('refused', 'not_initialized', 'call init first')
    return this.oauth
  }
  get #s() {
    if (!this.spaces) throw new HelperError('refused', 'not_initialized', 'call init first')
    return this.spaces
  }

  methods: Record<string, Handler> = {
    init: async (p) => this.init(p as Init),
    'key.generate': async (p) => strip(await generateKey(p.keyFile)),
    // Calls as a group (its host's group token): a founder's first space,
    // an invite, an admission.
    'group.act': async (p) => {
      if (!this.fetch) throw new Error('not initialized')
      return asGroup(this.fetch, p as never)
    },
    'key.public': async (p) => strip(await publicKey(p.keyFile)),
    'key.prove': async (p) => ({
      proof: await keyProof(await loadKey(p.keyFile), { iss: p.iss, sub: p.sub, aud: p.aud, lxm: p.lxm }),
    }),
    'oauth.login': async (p) => this.#o.login({ account: p.account, keyFile: p.keyFile, scope: p.scope }),
    // Another app's grant (the town AppView's read on the inbox), approved
    // with the account's key.
    'oauth.approveFor': async (p) => this.#o.approveFor(p as never),
    // An outside app's sign-in as the account: what it asks, then approving it.
    'oauth.previewApp': async (p) => this.#o.previewApp(p as never),
    'oauth.approveApp': async (p) => this.#o.approveApp(p as never),
    'oauth.credentials': async (p) =>
      this.#o.credentials(p.did, { refresh: !!p.refresh, relogin: p.relogin }),
    'oauth.status': async (p) => this.#o.status(p.did),
    'oauth.logout': async (p) => {
      this.#s.forget(p.did)
      return this.#o.logout(p.did)
    },
    'space.create': async (p) => this.#s.create(p.did, p as never),
    'space.list': async (p) => this.#s.list(p.did, p),
    'space.get': async (p) => this.#s.getSpace(p.did, p.space),
    'space.authorize': async (p) => this.#s.authorize(p.did, p.space),
    'space.records.create': async (p) => this.#s.createRecord(p.did, p.space, p.collection, p.record, p.rkey),
    'space.records.put': async (p) => this.#s.putRecord(p.did, p.space, p.collection, p.rkey, p.record),
    'space.records.get': async (p) => this.#s.getRecord(p.did, p.space, p.collection, p.rkey, p.repo),
    'space.records.list': async (p) => this.#s.listRecords(p.did, p.space, p),
    'space.records.delete': async (p) => this.#s.deleteRecord(p.did, p.space, p.collection, p.rkey),
    'space.writers': async (p) => this.#s.writers(p.did, p.space, p),
    'space.all': async (p) => this.#s.all(p.did, p.space, p),
    'space.members.put': async (p) => this.#s.members(p.did, p.space, 'put', p.members),
    'space.members.remove': async (p) => this.#s.members(p.did, p.space, 'remove', p.members),
    'space.members.list': async (p) => this.#s.members(p.did, p.space, 'list'),
    'space.pull': async (p) => this.#s.pull(p.did, p.space, p.repo),
    'inbox.ensure': async (p) => this.#s.ensureInbox(p.did),
    'space.delegationToken': async (p) => this.#s.delegationToken(p.did, p.space),
  }

  async handle(line: string): Promise<string | null> {
    let msg: { id?: unknown; method?: string; params?: Record<string, unknown> }
    try {
      msg = JSON.parse(line)
    } catch {
      return JSON.stringify({ jsonrpc: '2.0', id: null, error: { code: -32700, message: 'parse error' } })
    }
    const { id = null, method = '', params = {} } = msg
    const handler = this.methods[method]
    if (!handler) {
      return JSON.stringify({ jsonrpc: '2.0', id, error: { code: -32601, message: `unknown method ${method}` } })
    }
    try {
      const result = await handler(params)
      return JSON.stringify({ jsonrpc: '2.0', id, result: result ?? null })
    } catch (err) {
      return JSON.stringify({ jsonrpc: '2.0', id, error: classify(err) })
    }
  }
}

const strip = ({ didKey, jkt }: { didKey: string; jkt: string }) => ({ didKey, jkt })

/**
 * Each failure in at_mcp's classes. An XRPC error from a server is a
 * refusal (it answered, and said no), with its name as the code; 401s and
 * the session errors of oauth-client are `auth_refused`; anything else
 * (network, timeouts, our own faults) is `indeterminate`.
 */
export function classify(err: unknown) {
  if (err instanceof HelperError) {
    return { code: -32000, message: err.message, data: { class: err.failureClass, code: err.code, ...(err.details ?? {}) } }
  }
  const e = err as { name?: string; message?: string; error?: string; status?: number; code?: string }
  const name = e?.name ?? ''
  if (['TokenRefreshError', 'TokenRevokedError', 'TokenInvalidError', 'AuthMethodUnsatisfiableError'].includes(name)) {
    return { code: -32000, message: e.message ?? name, data: { class: 'auth_refused', code: name } }
  }
  if (name === 'PrivateFileError') {
    return { code: -32000, message: e.message ?? name, data: { class: 'refused', code: e.code } }
  }
  if (name === 'TypeError' && /space|collection/i.test(e.message ?? '')) {
    return { code: -32000, message: e.message ?? name, data: { class: 'refused', code: 'TypeError' } }
  }
  const status = typeof e?.status === 'number' ? e.status : undefined
  const xrpcError = typeof e?.error === 'string' ? e.error : undefined
  if (status !== undefined && xrpcError) {
    const cls = status === 401 ? 'auth_refused' : status >= 500 ? 'indeterminate' : 'refused'
    return { code: -32000, message: e.message ?? xrpcError, data: { class: cls, code: xrpcError, status } }
  }
  if (name === 'SpaceRepoVerificationError' || name === 'RepoGapError' || name === 'UnsupportedSpacePolicyError') {
    return { code: -32000, message: e.message ?? name, data: { class: 'refused', code: name } }
  }
  return { code: -32000, message: e?.message ?? String(err), data: { class: 'indeterminate', code: name || 'error' } }
}

export function run() {
  const write = (s: string) => process.stdout.write(s + '\n')
  const log: Log = (level, message, meta) =>
    write(JSON.stringify({ jsonrpc: '2.0', method: 'log', params: { level, message, ...(meta ?? {}) } }))
  const helper = new Helper(log)
  const rl = createInterface({ input: process.stdin, crlfDelay: Infinity })
  let pending = 0
  let closed = false
  rl.on('line', (line) => {
    if (!line.trim()) return
    pending++
    helper
      .handle(line)
      .then((out) => out && write(out))
      .finally(() => {
        pending--
        if (closed && pending === 0) process.exit(0)
      })
  })
  rl.on('close', () => {
    closed = true
    if (pending === 0) process.exit(0)
  })
}
