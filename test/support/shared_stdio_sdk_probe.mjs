// Official SDK clients against an existing disposable HTTP owner. No real PDS.
import assert from 'node:assert/strict';
import http from 'node:http';
import {join} from 'node:path';
import {pathToFileURL} from 'node:url';
const load = (root, file) => import(pathToFileURL(join(root, file)));
const {Client} = await load(process.env.MCP_CLIENT_PATH, 'dist/index.mjs');
const {StdioClientTransport} = await load(process.env.MCP_CLIENT_PATH, 'dist/stdio.mjs');
const legacy = process.env.MCP_SDK_PATH;
const {Client: LegacyClient} = await load(legacy, 'dist/esm/client/index.js');
const {StdioClientTransport: LegacyStdio} = await load(legacy, 'dist/esm/client/stdio.js');
const {StreamableHTTPClientTransport} = await load(legacy, 'dist/esm/client/streamableHttp.js');
const url = process.env.TEST_SHARED_URL, did = process.env.TEST_SHARED_DID;
// The credential that names the identity. It travels in the child's environment,
// never in argv, which is what the generated descriptor does too.
const grant = process.env.AT_MCP_GRANT;
const clients = new Set();
const control = async action => {
  const response = await fetch(`${process.env.TEST_CONTROL}/${action}`);
  assert.equal(response.status, 200); return response.json();
};
async function stdio(target = url, expected = did, old = false) {
  const C = old ? LegacyClient : Client, T = old ? LegacyStdio : StdioClientTransport;
  const client = new C({name: 'at_mcp-shared-stdio-proof', version: '1'}, old ? {} : {
    versionNegotiation: {mode: {pin: '2026-07-28'}}
  });
  const transport = new T({command: process.env.TEST_MCP_COMMAND,
    args: process.env.TEST_SHARED_RELEASE === '1'
      ? ['--url', target, '--did', expected]
      : [...JSON.parse(process.env.TEST_MCP_ARGS), '-e',
        `AtMcp.MCP.SharedStdio.run(${JSON.stringify(target)}, ${JSON.stringify(expected)}, System.get_env("AT_MCP_GRANT"))`],
    env: {PATH: process.env.PATH, LANG: 'C', LC_ALL: 'C', AT_MCP_GRANT: grant}, stderr: 'pipe'});
  let diagnostics = ''; 
  clients.add(client);
  try { const connecting = client.connect(transport, {timeout: 15000});
    transport.stderr?.on('data', chunk => diagnostics += chunk); await connecting; }
  catch (error) { await client.close(); clients.delete(client); throw new Error(`${error.message}\n${diagnostics}`); }
  if (!old) assert.equal(client.getNegotiatedProtocolVersion(), '2026-07-28');
  return client;
}
async function direct() {
  const c = new LegacyClient({name: 'at_mcp-shared-http-proof', version: '1'});
  clients.add(c);
  await c.connect(new StreamableHTTPClientTransport(new URL(url), {
    requestInit: {headers: {authorization: `Bearer ${grant}`}}
  }));
  return c;
}
const call = (c, name, args = {}) => c.callTool({name, arguments: args}, undefined, {timeout: 45000});
const status = async c => JSON.parse((await call(c, 'identity_status')).content.map(x => x.text || '').join(''));
const post = (c, text) => call(c, 'post', {text});
const close = async c => { await c.close(); clients.delete(c); };
const proxy = http.createServer(async (req, res) => {
  const chunks = []; for await (const chunk of req) chunks.push(chunk);
  const body = Buffer.concat(chunks);
  const target = new URL(url); target.pathname = new URL(req.url, target).pathname;
  const headers = {...req.headers, host: target.host};
  if (headers.origin) headers.origin = target.origin;
  const upstream = http.request(target, {method: req.method, headers}, incoming => {
    const drop = body.toString().includes('lost-response-fixture');
    if (drop) { incoming.resume(); incoming.on('end', () => res.destroy()); }
    else { res.writeHead(incoming.statusCode, incoming.headers); incoming.pipe(res); }
  });
  upstream.on('error', () => res.destroy()); upstream.end(body);
});
try {
  const second = await stdio(url, did, true), first = await stdio(), web = await direct();
  assert.equal((await control('state')).logins, 1);
  assert.ok((await first.listTools()).tools.some(t => t.name === 'post'));
  for (const [i, c] of [first, second, web].entries()) assert.ok(!(await post(c, `client-${i}`)).isError);
  for (const c of [first, second, web]) assert.equal((await status(c)).write_quota.used, 3);
  await close(first);
  assert.equal((await control('state')).owner_alive, true);
  assert.ok(!(await post(second, 'after-front-close')).isError);
  const beforeWrong = (await control('state')).writes.length;
  await assert.rejects(stdio(url, 'did:plc:wrong-account'));
  assert.equal((await control('state')).writes.length, beforeWrong);
  await control('disconnect');
  for (const c of [second, web]) {
    try { assert.equal((await post(c, 'disconnected')).isError, true); }
    catch (error) { if (error.code === 'ERR_ASSERTION') throw error; }
  }
  assert.equal((await control('state')).writes.length, 4);
  await close(second); await close(web);
  await control('reconnect');
  const resumed = await stdio();
  assert.equal((await status(resumed)).write_quota.used, 4);
  assert.ok(!(await post(resumed, 'after-reconnect')).isError);
  await new Promise(resolve => proxy.listen(0, '127.0.0.1', resolve));
  const lossy = await stdio(`http://127.0.0.1:${proxy.address().port}/mcp`);
  const lost = await post(lossy, 'lost-response-fixture');
  assert.equal(lost.isError, true);
  assert.equal(lost.structuredContent.outcome, 'unknown');
  assert.match(lost.content.map(x => x.text || '').join(''), /may have completed/);
  const state = await control('state');
  assert.equal(state.writes.filter(w => w.text === 'lost-response-fixture').length, 1);
  assert.equal(state.writes.length, 6);
  assert.equal((await status(resumed)).write_quota.used, 6);
  assert.equal(state.logins, 2, 'one login per owner generation, not per front');
  console.log(JSON.stringify({modern: '2026-07-28', legacy: true, shared_owner: true,
    shared_quota: true, disconnect_blocks_all: true, no_duplicate_after_response_loss: true, public_writes: 0}));
} finally {
  await Promise.all([...clients].map(c => c.close()));
  proxy.closeAllConnections(); await new Promise(resolve => proxy.close(resolve));
}
