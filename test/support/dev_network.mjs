// A local AT Protocol network for the end-to-end suite (test/e2e): upstream's
// reference PLC, PDS, AppView, bsync and ozone from `@atproto/dev-env`'s
// TestNetwork, every service on localhost. `AtMcp.Test.DevNetwork` runs this
// with Node and talks to it over stdin and stdout, one line at a time:
//
//   stdout, once ready:  {"ready": {...}}   where the services are, the two
//                                           accounts and the feed generator
//   stdin "sync":        wait until the AppView has indexed every write the
//                        PDS has sequenced, then answer {"synced": true}
//   stdin "close", or stdin closing: stop every service, answer
//                        {"closed": true} and exit
//
// AT_MCP_E2E_DEV_ENV is the built `packages/dev-env` directory of an atproto
// checkout; DB_POSTGRES_URL and REDIS_HOST are what TestNetwork needs.
// scripts/e2e.sh provides all three. Logs go to stderr.
import net from 'node:net'
import path from 'node:path'
import readline from 'node:readline'
import { pathToFileURL } from 'node:url'

const devEnv = process.env.AT_MCP_E2E_DEV_ENV
if (!devEnv) {
  console.error('AT_MCP_E2E_DEV_ENV must name a built atproto packages/dev-env')
  process.exit(2)
}

const { TestNetwork } = await import(
  pathToFileURL(path.join(devEnv, 'dist', 'index.js')).href
)

const say = (message) => process.stdout.write(JSON.stringify(message) + '\n')

// Each run indexes into fresh Postgres schemas, so nothing a previous run left
// is read back. Schema names take letters and underscores only.
const run = Array.from({ length: 8 }, () =>
  String.fromCharCode(97 + Math.floor(Math.random() * 26)),
).join('')

// The AppView names image URLs from its public URL, and the PDS names those it
// writes into a view from its CDN pattern; dev-env sets both to hosts that are
// not this machine. Point both at the AppView's own image route, so an image
// read stays on localhost.
const freePort = () =>
  new Promise((resolve, reject) => {
    const server = net.createServer()
    server.on('error', reject)
    server.listen(0, '127.0.0.1', () => {
      const { port } = server.address()
      server.close(() => resolve(port))
    })
  })
const appviewPort = await freePort()

const network = await TestNetwork.create({
  dbPostgresSchema: `atmcp_${run}`,
  bsky: { port: appviewPort, publicUrl: `http://localhost:${appviewPort}` },
  pds: {
    bskyAppViewCdnUrlPattern: `http://localhost:${appviewPort}/img/%s/plain/%s/%s@jpeg`,
  },
})

const seed = network.getSeedClient()
const password = 'e2e-password'

const account = async (name) => {
  const created = await seed.createAccount(name, {
    handle: `${name}.test`,
    email: `${name}@example.com`,
    password,
  })
  return { did: created.did, handle: created.handle, password }
}

const self = await account('alice')
const other = await account('bob')

// A feed the other account publishes, served by a feed generator on localhost
// that answers with whatever the other account has posted.
const feeds = {}
const generator = await network.createFeedGen(feeds)
const feed = await seed.createFeedGen(other.did, generator.did, 'e2e-feed')
feeds[feed.uriStr] = async () => {
  const posts = await network.bsky.db.db
    .selectFrom('post')
    .where('creator', '=', other.did)
    .select('uri')
    .orderBy('sortAt', 'desc')
    .limit(10)
    .execute()
  return {
    encoding: 'application/json',
    body: { feed: posts.map((p) => ({ post: p.uri })) },
  }
}

await network.processAll()

say({
  ready: {
    pds: network.pds.url,
    appview: network.bsky.url,
    appview_did: network.bsky.serverDid,
    plc: network.plc.url,
    accounts: { self, other },
    feed: feed.uriStr,
  },
})

let closing = null
const close = () => {
  closing ??= network
    .close()
    .catch((err) => console.error('closing the network:', err))
    .then(() => {
      say({ closed: true })
      process.exit(0)
    })
  return closing
}

const lines = readline.createInterface({ input: process.stdin })
lines.on('line', async (line) => {
  try {
    switch (line.trim()) {
      case 'sync':
        await network.processAll()
        say({ synced: true })
        break
      case 'close':
        await close()
        break
      default:
        say({ error: `unknown command ${line}` })
    }
  } catch (err) {
    say({ error: String(err?.stack ?? err) })
  }
})
lines.on('close', close)
process.on('SIGTERM', close)
process.on('SIGINT', close)
