// Disposable PDS + ordinary client-launched AtMcp release; no public network effects.
// AT_MCP_MCP_COMMAND points to a built bin/at_mcp-stdio. MCP_CLIENT_PATH points to
// @modelcontextprotocol/client 2.x; MCP_SDK_PATH optionally adds the 1.x client.
import assert from 'node:assert/strict';
import http from 'node:http';
import {mkdtemp, rm, writeFile} from 'node:fs/promises';
import {spawn} from 'node:child_process';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {pathToFileURL} from 'node:url';

const command = process.env.AT_MCP_MCP_COMMAND;
const sdk = process.env.MCP_CLIENT_PATH;
assert.ok(command && sdk, 'Set AT_MCP_MCP_COMMAND and MCP_CLIENT_PATH.');
const {Client} = await import(pathToFileURL(join(sdk, 'dist/index.mjs')));
const {StdioClientTransport} = await import(pathToFileURL(join(sdk, 'dist/stdio.mjs')));
const root = await mkdtemp(join(tmpdir(), 'at_mcp-stdio-sdk-'));
const mutations = [];
const clients = new Set();
const pds = http.createServer(async (req, res) => {
  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  const raw = Buffer.concat(chunks).toString();
  const body = raw ? JSON.parse(raw) : {};
  const url = new URL(req.url, 'http://localhost');
  let result;
  if (url.pathname.endsWith('/com.atproto.server.createSession')) {
    const name = body.identifier.split('.')[0];
    result = {did: `did:plc:${name}`, handle: body.identifier,
      accessJwt: `fixture-${name}`, refreshJwt: `refresh-${name}`};
  } else if (url.pathname.endsWith('/app.bsky.actor.getProfile')) {
    result = {did: url.searchParams.get('actor'), handle: 'fixture.test', displayName: 'café 日本語 🪁'};
  } else if (url.pathname.endsWith('/app.bsky.feed.getTimeline')) {
    // Realistic AppView shapes, so the real summarizers — not a mock — are what
    // the declared output schemas have to accept.
    result = {cursor: '2026-09-08T00:00:00Z::1', feed: [{post: {
      uri: 'at://did:plc:other/app.bsky.feed.post/1', cid: 'bafypost',
      author: {did: 'did:plc:other', handle: 'other.test', displayName: 'café 日本語 🪁'},
      record: {$type: 'app.bsky.feed.post', text: 'timeline café 🪁', createdAt: '2026-09-08T00:00:00Z'},
      viewer: {like: 'at://did:plc:alice/app.bsky.feed.like/1', repost: undefined},
      replyCount: 1, likeCount: 2, indexedAt: '2026-09-08T00:00:00Z'}}]};
  } else if (url.pathname.endsWith('/app.bsky.feed.getPostThread')) {
    const post = (n, did) => ({
      uri: `at://${did}/app.bsky.feed.post/${n}`, cid: `bafy${n}`,
      author: {did, handle: `${did.split(':').pop()}.test`},
      record: {$type: 'app.bsky.feed.post', text: `node ${n} 🪁`, createdAt: '2026-09-08T00:00:00Z'},
      viewer: {}, indexedAt: '2026-09-08T00:00:00Z'});
    result = {thread: {
      $type: 'app.bsky.feed.defs#threadViewPost', post: post(2, 'did:plc:other'),
      parent: {$type: 'app.bsky.feed.defs#threadViewPost', post: post(1, 'did:plc:root')},
      replies: [{$type: 'app.bsky.feed.defs#threadViewPost', post: post(3, 'did:plc:alice')}]}};
  } else if (url.pathname.endsWith('/com.atproto.repo.createRecord')) {
    const name = req.headers.authorization?.replace('Bearer fixture-', '');
    assert.equal(body.repo, `did:plc:${name}`);
    mutations.push({name, text: body.record.text});
    result = {uri: `at://${body.repo}/${body.collection}/${mutations.length}`, cid: 'bafyfixture'};
  } else {
    res.writeHead(404, {'content-type': 'application/json'});
    res.end(JSON.stringify({error: 'UnsupportedFixtureCall', message: url.pathname}));
    return;
  }
  res.writeHead(200, {'content-type': 'application/json'});
  res.end(JSON.stringify(result));
});
await new Promise(resolve => pds.listen(0, '127.0.0.1', resolve));
const service = `http://127.0.0.1:${pds.address().port}`;

function params(name) {
  return {command, args: JSON.parse(process.env.AT_MCP_MCP_ARGS || '[]'), stderr: 'pipe', env: {
    PATH: process.env.PATH, LANG: 'C', LC_ALL: 'C',
    AT_MCP_ENV_FILE: join(root, 'inherited-service-file-must-not-be-read'),
    BLUESKY_HANDLE: `${name}.test`, BLUESKY_APP_PASSWORD: 'fixture-password',
    BLUESKY_SERVICE: service, AT_MCP_STATE_DIR: join(root, name)
  }};
}

async function connect(name, legacy = false, environment = {}) {
  let C = Client, T = StdioClientTransport;
  if (legacy) {
    const path = process.env.MCP_SDK_PATH;
    assert.ok(path, 'MCP_SDK_PATH required for legacy check');
    C = (await import(pathToFileURL(join(path, 'dist/esm/client/index.js')))).Client;
    T = (await import(pathToFileURL(join(path, 'dist/esm/client/stdio.js')))).StdioClientTransport;
  }
  const options = params(name);
  Object.assign(options.env, environment);
  const transport = new T(options);
  const client = new C({name: 'at_mcp-stdio-proof', version: '1'}, legacy ? {} : {
    versionNegotiation: {mode: {pin: '2026-07-28'}}
  });
  let diagnostics = '';
  transport.stderr?.on('data', chunk => diagnostics += chunk);
  clients.add(client);
  try {
    await client.connect(transport, {timeout: 15_000});
    if (!legacy) assert.equal(client.getNegotiatedProtocolVersion(), '2026-07-28');
    return {client, transport, diagnostics: () => diagnostics};
  } catch (error) {
    await client.close(); clients.delete(client);
    throw new Error(`${error.message}\n${diagnostics}`);
  }
}

async function call(connection, name, args = {}) {
  const result = await connection.client.callTool({name, arguments: args});
  assert.ok(!result.isError, JSON.stringify(result));
  const summary = JSON.parse(result.content.find(c => c.type === 'text').text);
  // A declared output schema is only worth having if the structured content
  // carries the same result the text does.
  assert.deepEqual(result.structuredContent, summary, `${name} structured content`);
  return summary;
}

async function rejectInvalidArguments(connection) {
  for (const [name, args] of [
    ['get_author_feed', {}],
    ['get_author_feed', {actor: 42}],
    ['get_timeline', {limit: 0}],
    ['get_posts', {uris: Array(26).fill('at://did:plc:fixture/app.bsky.feed.post/1')}],
    ['post', {text: 42}],
    ['post', {text: 'not sent', langs: [42]}],
  ]) {
    const result = await connection.client.callTool({name, arguments: args});
    assert.equal(result.isError, true, `${name} must refuse invalid arguments`);
    assert.equal(result.structuredContent.code, 'invalid_arguments');
    assert.match(result.content[0].text, /input schema/i);
  }
  await assert.rejects(connection.client.callTool({name: 'unknown_fixture_tool', arguments: {}}),
    error => error.code === -32602);
  // A valid call on the same connection must still work, with no writes used.
  assert.equal((await call(connection, 'identity_status')).write_quota.used, 0);
  assert.equal(mutations.length, 0);
}

async function close(connection) {
  const pid = connection.transport.pid;
  await connection.client.close();
  clients.delete(connection.client);
  assert.throws(() => process.kill(pid, 0), {code: 'ESRCH'});
}

try {
  const a = await connect('alice');
  const b = await connect('bob');
  await rejectInvalidArguments(a);
  if (process.env.MCP_SDK_PATH) {
    const legacy = await connect('legacy', true);
    await rejectInvalidArguments(legacy);
    await close(legacy);
  }
  const {tools} = await a.client.listTools();
  // No count is pinned here. The loop below fails by name on any tool missing a
  // schema, and the Elixir side compares the number reported back against the
  // tools the server declares, so a new tool needs no edit in either place.
  for (const tool of tools) {
    assert.equal(tool.outputSchema?.type, 'object', `${tool.name} declares no output schema`);
    assert.ok(tool.outputSchema.properties.code, `${tool.name} cannot report a failure code`);
  }
  assert.equal(tools.find(t => t.name === 'get_posts').inputSchema.properties.uris.maxItems, 25);
  assert.equal(tools.find(t => t.name === 'get_profiles').inputSchema.properties.actors.maxItems, 25);
  for (const [connection, name] of [[a, 'alice'], [b, 'bob']]) {
    assert.equal((await call(connection, 'identity_status')).did, `did:plc:${name}`);
    assert.equal((await call(connection, 'get_profile')).display_name, 'café 日本語 🪁');
    assert.equal((await call(connection, 'get_profile', {actor: 'café 日本語 🪁'})).did, 'café 日本語 🪁');
  }
  await assert.rejects(connect('alice'), /state|start this account|closed/i);
  const timeline = await call(a, 'get_timeline');
  assert.equal(timeline.count, 1);
  assert.equal(timeline.items[0].text, 'timeline café 🪁');
  assert.equal(timeline.items[0].author_did, 'did:plc:other');
  assert.equal(timeline.items[0].viewer.like, 'at://did:plc:alice/app.bsky.feed.like/1');
  assert.equal(timeline.cursor, '2026-09-08T00:00:00Z::1');
  const thread = await call(a, 'get_thread', {uri: 'at://did:plc:other/app.bsky.feed.post/2'});
  assert.equal(thread.text, 'node 2 🪁');
  assert.equal(thread.parent.uri, 'at://did:plc:root/app.bsky.feed.post/1');
  assert.equal(thread.replies.length, 1);
  assert.equal(thread.context.max_replies_per_node, 20);
  const post = await call(a, 'post', {text: 'café 日本語 🪁'});
  assert.ok(post.uri.startsWith('at://did:plc:alice/'));
  const before = (await call(a, 'identity_status')).write_quota;
  assert.equal(before.used, 1);
  assert.match(before.resets_at, /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z$/);
  assert.equal((await call(b, 'identity_status')).write_quota.used, 0);
  await close(a);
  const resumed = await connect('alice', Boolean(process.env.MCP_SDK_PATH));
  assert.equal((await call(resumed, 'identity_status')).write_quota.used, 1);
  assert.equal((await call(resumed, 'get_profile', {actor: 'café 日本語 🪁'})).did, 'café 日本語 🪁');
  await close(resumed);
  await close(b);

  // Exercise EOF directly, without an SDK's signal/kill fallback.
  const options = params('eve');
  const child = spawn(options.command, options.args, {env: options.env, stdio: ['pipe', 'pipe', 'pipe']});
  let stdout = '', stderr = '';
  child.stdout.on('data', chunk => stdout += chunk);
  child.stderr.on('data', chunk => stderr += chunk);
  const exited = new Promise((resolve, reject) => {
    const timer = setTimeout(() => { child.kill('SIGKILL'); reject(new Error(`EOF timeout: ${stderr}`)); }, 10_000);
    child.on('error', error => { clearTimeout(timer); reject(error); });
    child.on('close', (code, signal) => { clearTimeout(timer); resolve({code, signal}); });
  });
  child.stdin.end(JSON.stringify({jsonrpc: '2.0', id: 1, method: 'initialize', params: {
    protocolVersion: '2025-11-25', capabilities: {}, clientInfo: {name: 'eof', version: '1'}
  }}) + '\n');
  assert.deepEqual(await exited, {code: 0, signal: null}, stderr);
  const frames = stdout.trim().split('\n').map(line => JSON.parse(line));
  assert.equal(frames.length, 1);
  assert.equal(frames[0].id, 1);

  if (process.env.AT_MCP_STDIO_RELEASE === '1') {
    const file = join(root, 'carol.env');
    await writeFile(file, `BLUESKY_HANDLE=carol.test\nBLUESKY_APP_PASSWORD=fixture-password\nBLUESKY_SERVICE=${service}\n`, {mode: 0o600});
    const carol = await connect('carol', false, {BLUESKY_HANDLE: '', BLUESKY_APP_PASSWORD: '', AT_MCP_STDIO_ENV_FILE: file});
    assert.equal((await call(carol, 'identity_status')).did, 'did:plc:carol');
    await close(carol);
  }
  assert.deepEqual(mutations, [{name: 'alice', text: 'café 日本語 🪁'}]);
  console.log(JSON.stringify({modern: '2026-07-28', legacy: Boolean(process.env.MCP_SDK_PATH),
    concurrent_accounts: 2, unicode: true, exclusive_state: true,
    output_schemas: tools.filter((t) => t.outputSchema).length, structured_content: true, recoverable_invalid_arguments: true, iso_quota_reset: true,
    real_summaries: ['get_timeline', 'get_thread'],
    durable_quota: true, process_cleanup: true, graceful_eof: true,
    private_env_file: process.env.AT_MCP_STDIO_RELEASE === '1', mock_writes: 1, public_writes: 0}));
} finally {
  await Promise.allSettled([...clients].map(c => c.close()));
  await new Promise(resolve => pds.close(resolve));
  await rm(root, {recursive: true, force: true});
}
