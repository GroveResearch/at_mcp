// Read-only contract check against a running AtMcp account.
//
//   npm install --prefix "$dir" @modelcontextprotocol/client@2.0.0
//   MCP_CLIENT_PATH="$dir/node_modules/@modelcontextprotocol/client" \
//     AT_MCP_GRANT=<grant> node scripts/live_contract_check.mjs <at_mcp-connect path> <url> <did>
//
// Connects the way a client does, through a generated stdio connection, and
// checks what only a live service can show: that every tool advertises its
// output schema, that structured content matches the text for real
// application responses (its JSON, or for posts a text naming each one), and that refusals arrive as codes rather than as
// internal terms. It calls no write tool and creates no record.
import {isDeepStrictEqual} from 'node:util';
import {join} from 'node:path';
import {pathToFileURL} from 'node:url';

const sdk = process.env.MCP_CLIENT_PATH;
const [command, url, did] = process.argv.slice(2);
// The grant names the identity; the endpoint is shared. It travels in the
// environment rather than argv, which is what the generated descriptor does.
const grant = process.env.AT_MCP_GRANT;
if (!sdk || !command || !url || !did || !grant) {
  console.error('Set MCP_CLIENT_PATH and AT_MCP_GRANT, and pass <at_mcp-connect path> <url> <did>.');
  process.exit(2);
}

const {Client} = await import(pathToFileURL(join(sdk, 'dist/index.mjs')));
const {StdioClientTransport} = await import(pathToFileURL(join(sdk, 'dist/stdio.mjs')));

const failures = [];
const check = (ok, description) => { if (!ok) failures.push(description); };

const client = new Client({name: 'at_mcp-live-contract', version: '1'});
await client.connect(
  new StdioClientTransport({command, args: ['--url', url, '--did', did],
    env: {...process.env, AT_MCP_GRANT: grant}, stderr: 'pipe'}),
  {timeout: 20_000}
);

// Reads made of posts give a model readable text rather than the JSON; that
// text must still name every post the structured content holds.
const readings = new Set(['get_notifications', 'get_timeline', 'get_author_feed', 'get_posts',
  'search_posts', 'get_quotes', 'get_actor_likes', 'get_feed', 'get_list_feed', 'get_thread',
  'get_thread_chain']);
const postUris = value => Array.isArray(value) ? value.flatMap(postUris)
  : !value || typeof value !== 'object' ? []
  : (typeof value.uri === 'string' && typeof value.text === 'string' ? [value.uri] : [])
      .concat(Object.values(value).flatMap(postUris));

const call = async (name, args = {}) => {
  const result = await client.callTool({name, arguments: args});
  const text = result.content.find(c => c.type === 'text')?.text;
  const reading = readings.has(name) && !result.isError;
  const parsed = text && !result.isError && !reading ? JSON.parse(text) : undefined;
  if (parsed !== undefined) {
    check(isDeepStrictEqual(parsed, result.structuredContent),
      `${name}: structured content differs from the JSON text`);
  }
  if (reading) {
    const omitted = postUris(result.structuredContent).filter(uri => !text?.includes(uri));
    check(omitted.length === 0, `${name}: the text omits ${omitted.join(', ')}`);
  }
  return {isError: Boolean(result.isError), text, body: result.structuredContent ?? parsed};
};

const {tools} = await client.listTools();
const missing = tools.filter(t => !t.outputSchema?.properties).map(t => t.name);
check(missing.length === 0, `tools without an output schema: ${missing.join(', ')}`);
check(tools.find(t => t.name === 'get_posts')?.inputSchema.properties.uris.maxItems === 25,
  'get_posts does not advertise its 25-item limit');

const status = await call('identity_status');
check(status.body?.did === did, `identity_status reports ${status.body?.did}, expected ${did}`);
const resets = status.body?.write_quota?.resets_at;
check(resets === null || /^\d{4}-\d{2}-\d{2}T/.test(resets),
  `write quota reset is not an ISO8601 time: ${JSON.stringify(resets)}`);

for (const [name, args] of [['get_timeline', {limit: 3}], ['get_notifications', {limit: 3}]]) {
  const page = await call(name, args);
  check(!page.isError, `${name} failed: ${page.text}`);
  check(Number.isInteger(page.body?.count) && Array.isArray(page.body?.items),
    `${name} did not return a page`);
}

const missingProfile = await call('get_profile', {actor: 'this-handle-does-not-exist.invalid'});
check(missingProfile.isError, 'a missing profile did not report an error');
check(typeof missingProfile.body?.code === 'string', 'a service refusal carried no code');
check(!/%[A-Z]|ProtoRune|Elixir\./.test(missingProfile.text ?? ''),
  `a service refusal named internals: ${missingProfile.text}`);

const oversized = await call('get_posts',
  {uris: Array.from({length: 26}, (_, i) => `at://${did}/app.bsky.feed.post/${i}`)});
// The declared maxItems schema refuses the call before the backend batch guard.
check(oversized.body?.code === 'invalid_arguments', 'an oversized batch was not refused locally');

await client.close();

if (failures.length > 0) {
  console.error(JSON.stringify({ok: false, failures}, null, 2));
  process.exit(1);
}
console.log(JSON.stringify({ok: true, did, tools: tools.length, checks: 'schemas, parity, refusals'}));
