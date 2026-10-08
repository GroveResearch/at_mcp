// Modeled provider and signature-checking AppView, not a live-provider proof.
import assert from 'node:assert/strict';
import http from 'node:http';
import {generateKeyPairSync, sign, verify} from 'node:crypto';
import {mkdtemp, rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {pathToFileURL} from 'node:url';
const {Client} = await import(pathToFileURL(join(process.env.MCP_CLIENT_PATH, 'dist/index.mjs')));
const {StdioClientTransport} = await import(pathToFileURL(join(process.env.MCP_CLIENT_PATH, 'dist/stdio.mjs')));
const root = await mkdtemp(join(tmpdir(),'direct-auth-'));
const {privateKey, publicKey} = generateKeyPairSync('ec',{namedCurve:'secp256k1'});
const did='did:plc:external', aud='did:web:api.delve.town#bsky_appview';
let mode='ok', issuance=0, appCalls=0, writes=0, logins=0, proxyCalls=0, refreshes=0, expiredOnce=false;
const faults=[];
function send(res,status,body) {res.writeHead(status,{'content-type':'application/json'});res.end(JSON.stringify(body));}
function jwt(payload) {
  const msg=[{alg:'ES256K',typ:'JWT'},payload].map(x=>Buffer.from(JSON.stringify(x)).toString('base64url')).join('.');
  return msg+'.'+sign('sha256',Buffer.from(msg),{key:privateKey,dsaEncoding:'ieee-p1363'}).toString('base64url');
}
const app=http.createServer((req,res)=>{try {
  appCalls++;
  assert.equal(req.headers['atproto-proxy'],undefined);
  assert.ok(!JSON.stringify(req.headers).includes('home.access.jwt'));
  assert.ok(!JSON.stringify(req.headers).includes('home-refresh'));
  const [h,p,s]=req.headers.authorization.slice(7).split('.');
  assert.ok(verify('sha256',Buffer.from(h+'.'+p),{key:publicKey,dsaEncoding:'ieee-p1363'},Buffer.from(s,'base64url')));
  const payload=JSON.parse(Buffer.from(p,'base64url'));
  const method=new URL(req.url,'http://fixture').pathname.split('/').pop();
  if(payload.aud!==aud || payload.lxm!==method || payload.exp<=Date.now()/1000) return send(res,401,{error:'InvalidToken'});
  assert.equal(payload.iss,did);
  if(mode==='app-malformed-error') return send(res,503,{error:{object:true},message:['not text']});
  if(mode==='app-novel-error') return send(res,503,{error:'UnseenRemoteFailure_4729',message:'Read refused'});
  if(mode==='app-auth-503') return send(res,503,{error:'InvalidToken'});
  if(mode==='app-redirect') {res.writeHead(307,{location:pdsOrigin+'/leak'});return res.end();}
  if(method.endsWith('getMembership')) return send(res,200,{enabled:true,membership:{did,status:'active',suspended:false,joined:true,revision:1}});
  if(method.endsWith('getPosts')) {assert.equal(new URL(req.url,'http://fixture').searchParams.getAll('uris').length,2);return send(res,200,{posts:[]});}
  return send(res,200,{feed:[]});
} catch(e){faults.push(e.message);send(res,500,{error:'FixtureFailure'});}});
await new Promise(r=>app.listen(0,'127.0.0.1',r));
const pds=http.createServer(async(req,res)=>{try {
 const u=new URL(req.url,'http://fixture');
 if(u.pathname.endsWith('createSession')) {logins++;return send(res,200,{did,handle:'external.test',accessJwt:'home.access.jwt',refreshJwt:'home-refresh'});}
 if(u.pathname.endsWith('refreshSession')) {assert.equal(req.headers.authorization,'Bearer home-refresh');refreshes++;return send(res,200,{did,handle:'external.test',accessJwt:'home.access.jwt',refreshJwt:'home-refresh'});}
 assert.equal(req.headers.authorization,'Bearer home.access.jwt');
 if(u.pathname.endsWith('getServiceAuth')) {
  issuance++; if(mode==='home-expired' && !expiredOnce) {expiredOnce=true;return send(res,401,{error:'ExpiredToken'});}
  assert.equal(u.searchParams.get('aud'),aud); assert.ok(u.searchParams.get('lxm').startsWith('town.delve.'));
  const exp=Number(u.searchParams.get('exp'));assert.ok(exp>Date.now()/1000 && exp<=Date.now()/1000+61);
  if(mode==='home-malformed-error') return send(res,403,{error:['not text'],message:{object:true}});
  if(mode==='home-novel-error') return send(res,503,{error:'UnseenIssuerFailure_391',message:'Do not expose home.access.jwt'});
  if(mode==='denied') return send(res,403,{error:'Forbidden',message:'Issuance denied'});
  if(mode==='home-token') return send(res,200,{token:'home.access.jwt'});
  if(mode==='malformed') return send(res,200,{token:'unsafe\nheader'});
  if(mode==='missing') return send(res,200,{});
  if(mode==='unsupported') return send(res,501,{error:'NotImplemented'});
  if(mode==='issue-redirect') {res.writeHead(307,{location:`http://127.0.0.1:${app.address().port}/leak`});return res.end();}
  return send(res,200,{token:jwt({iss:did,aud:mode==='wrong-aud'?'did:web:other.test':aud,lxm:mode==='wrong-method'?'town.delve.actor.getProfile':u.searchParams.get('lxm'),exp:mode==='expired'?1:exp})});
 }
 if(u.pathname.includes('/town.delve.')) {proxyCalls++;return send(res,501,{error:'NotImplemented'});}
 if(u.pathname.endsWith('createRecord')) {
  let text='';for await(const part of req) text+=part;
  const body=JSON.parse(text);assert.equal(body.repo,did);assert.equal(body.collection,'town.delve.feed.post');writes++;
  req.socket.destroy();return;
 }
 throw new Error('Unexpected home request '+u.pathname);
} catch(e){faults.push(e.message);send(res,500,{error:'FixtureFailure'});}});
await new Promise(r=>pds.listen(0,'127.0.0.1',r));
const pdsOrigin=`http://127.0.0.1:${pds.address().port}`;
const client=new Client({name:'direct-route-proof',version:'1'});
const transport=new StdioClientTransport({command:process.env.TEST_EXTERNAL_COMMAND,args:JSON.parse(process.env.TEST_EXTERNAL_ARGS),stderr:'pipe',env:{PATH:process.env.PATH,TEST_APPVIEW_ORIGIN:`http://127.0.0.1:${app.address().port}`,AT_MCP_HANDLE:'external.test',AT_MCP_APP_PASSWORD:'fixture',AT_MCP_SERVICE:pdsOrigin,AT_MCP_STATE_DIR:join(root,'state')}});
let diagnostics='';transport.stderr?.on('data',s=>diagnostics+=s);
async function call(name,args={},error=false){const r=await client.callTool({name,arguments:args});assert.equal(Boolean(r.isError),error,JSON.stringify(r));assert.ok(!JSON.stringify(r).includes('home.access.jwt'));return r;}
try {
 await client.connect(transport);
 await call('get_membership'); await call('get_timeline');
 assert.equal(proxyCalls,0);assert.equal(issuance,2);assert.equal(appCalls,2);
 for(const failure of ['home-malformed-error','home-novel-error','denied','missing','home-token','malformed','unsupported','issue-redirect']) {
  mode=failure;const before=appCalls;const count=issuance;const result=await call('get_timeline',{},true);
  if(failure==='home-malformed-error') {assert.equal(result.structuredContent.http_status,403);assert.match(result.structuredContent.upstream_message,/Home PDS service-token issuance failed/);}
  assert.equal(appCalls,before);assert.equal(issuance,count+1);
 }
 for(const failure of ['wrong-aud','wrong-method','expired','app-redirect','app-auth-503','app-malformed-error','app-novel-error']) {
  mode=failure;const count=appCalls;const issued=issuance;const result=await call('get_timeline',{},true);
  if(failure==='app-malformed-error') {assert.equal(result.structuredContent.http_status,503);assert.match(result.structuredContent.upstream_message,/Direct AppView read failed/);}
  assert.equal(appCalls,count+1);assert.equal(issuance,issued+1);assert.equal(logins,1);
 }
 assert.equal(refreshes,0);mode='home-expired';const issuedBeforeRecovery=issuance;await call('get_timeline');assert.equal(refreshes,1);assert.equal(issuance,issuedBeforeRecovery+2);assert.equal(logins,1);
 mode='ok';await call('get_posts',{uris:[`at://${did}/town.delve.feed.post/1`,`at://${did}/town.delve.feed.post/2`]});const result=await call('post',{text:'uncertain'},true);assert.equal(result.structuredContent.outcome,'unknown');assert.equal(writes,1);
 await call('mute',{actor:did},true);assert.equal(proxyCalls,1);
 assert.deepEqual(faults,[]);console.log('direct_service_auth_passed');
} catch(e){console.error(diagnostics);throw e;} finally {await client.close();pds.closeAllConnections();app.closeAllConnections();await Promise.all([new Promise(r=>pds.close(r)),new Promise(r=>app.close(r))]);await rm(root,{recursive:true,force:true});}
