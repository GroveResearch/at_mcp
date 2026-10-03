// Invoked by http_client_test.exs against disposable loopback accounts only.
// The official SDK owns framing, initialization, sessions and tool calls.
import assert from 'node:assert/strict';
import { pathToFileURL } from 'node:url';
import { resolve } from 'node:path';

const sdk = process.env.MCP_SDK_PATH;
const { Client } = await import(pathToFileURL(resolve(sdk, 'dist/esm/client/index.js')));
const { StreamableHTTPClientTransport } = await import(
  pathToFileURL(resolve(sdk, 'dist/esm/client/streamableHttp.js'))
);
// One endpoint for every identity, so the URL is the same for both and only the
// grant differs. aliceDid is the binding an ordinary descriptor also carries.
const [url, aliceGrant, aliceDid, bobGrant] = process.argv.slice(2);
const clients = [];

async function connect(grant, did) {
  const client = new Client({ name: 'at_mcp-independent-probe', version: '1' });
  clients.push(client);
  const headers = { authorization: `Bearer ${grant}` };
  if (did) headers['x-kite-account-did'] = did;
  await client.connect(new StreamableHTTPClientTransport(new URL(url), {
    requestInit: { headers }
  }));
  return client;
}

try {
  const alice_client = await connect(aliceGrant, aliceDid);
  assert.equal(alice_client.getServerVersion().name, 'at_mcp');
  const tools = await alice_client.listTools();
  assert.ok(tools.tools.some(tool => tool.name === 'post'));
  const read = await alice_client.callTool({ name: 'get_profile', arguments: {} });
  assert.ok(!read.isError);
  assert.ok(read.content.some(item => item.type === 'text' && item.text.includes('Mock')));

  // Bob's grant cannot be talked into serving alice, and a stale DID binding
  // against it reaches nothing rather than the wrong identity.
  await assert.rejects(connect(bobGrant, aliceDid));
  const bob_client = await connect(bobGrant, null);
  const bob_profile = await bob_client.callTool({ name: 'get_profile', arguments: {} });
  assert.ok(!JSON.stringify(bob_profile).includes(aliceDid));

  // And no credential at all reaches nothing, on the same URL.
  await assert.rejects(connect('', null));

  const written = await alice_client.callTool({ name: 'post', arguments: { text: 'mock only' } });
  assert.ok(!written.isError);
  assert.ok(written.content.some(item => item.type === 'text' && item.text.includes('at://')));

  // Reconnecting is not a way around the account's own write quota.
  const reconnected = await connect(aliceGrant, aliceDid);
  const limited = await reconnected.callTool({ name: 'post', arguments: { text: 'over quota' } });
  assert.equal(limited.isError, true);
  assert.ok(limited.content.some(item => item.type === 'text' && item.text.includes('quota exhausted')));
  console.log(JSON.stringify({ passed: true, tools: tools.tools.length,
    read: true, identity_isolation: true, write: true,
    one_endpoint: true, credential_required: true,
    reconnect_does_not_reset_quota: true }));
} finally {
  await Promise.all(clients.map(client => client.close()));
}
