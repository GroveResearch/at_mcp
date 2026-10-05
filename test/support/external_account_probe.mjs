// A home PDS forwards authenticated application calls to a separate AppView.
// Ordinary MCP transport exercises the agent's own identity, never public services.
import assert from 'node:assert/strict';
import http from 'node:http';
import {mkdtemp, rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {pathToFileURL} from 'node:url';
const sdk = process.env.MCP_CLIENT_PATH;
const {Client} = await import(pathToFileURL(join(sdk, 'dist/index.mjs')));
const {StdioClientTransport} = await import(pathToFileURL(join(sdk, 'dist/stdio.mjs')));
const root = await mkdtemp(join(tmpdir(), 'at-mcp-external-'));
const did = 'did:plc:external';
const authority = 'did:web:api.delve.town#bsky_appview';
const calls = [], writes = [], faults = [];
let membership = {did, status: 'active', suspended: false, revision: 1, joined: true};
let membershipFailure = false;
let timelineUnimplemented = false;
let timelineRequests = 0;
function send(res, status, body) { res.writeHead(status, {'content-type':'application/json'}); res.end(JSON.stringify(body)); }
async function body(req) { let data=''; for await (const chunk of req) data+=chunk; return data ? JSON.parse(data) : {}; }
function view(record, n) { return {uri:`at://${did}/town.delve.feed.post/${n}`, cid:`bafy${n}`, author:{did,handle:'external.test'}, record, viewer:{}}; }
const appview = http.createServer(async (req,res) => {
  const url = new URL(req.url,'http://localhost');
  calls.push(url.pathname);
  if (req.headers.authorization !== 'Bearer fixture-external') return send(res,401,{error:'AuthRequired'});
  if(url.pathname.endsWith('membership.getMembership')) {
    if(membershipFailure) return send(res,503,{error:'UpstreamFailure',message:'Membership unavailable'});
    return send(res,200,{enabled:true,...(membership===undefined?{}:{membership})});
  }
  if(url.pathname.endsWith('actor.getProfile')) return send(res,200,{did,handle:'external.test'});
  if(url.pathname.endsWith('feed.getTimeline')) return send(res,200,{feed:writes.map((r,i)=>({post:view(r,i+1)}))});
  if(url.pathname.endsWith('feed.getPosts')) {
    assert.equal(url.searchParams.getAll('uris').length,2);
    return send(res,200,{posts:writes.map((r,i)=>view(r,i+1))});
  }
  if(url.pathname.endsWith('graph.muteActor') || url.pathname.endsWith('notification.updateSeen')) {await body(req); return send(res,200,{});}
  return send(res,404,{error:'UnsupportedFixtureCall'});
});
await new Promise(resolve=>appview.listen(0,'127.0.0.1',resolve));
const appOrigin=`http://127.0.0.1:${appview.address().port}`;
const pds = http.createServer(async (req,res) => {
  try {
    const url = new URL(req.url,'http://localhost');
    if(url.pathname.endsWith('feed.getTimeline')) {
      timelineRequests++;
      if(timelineUnimplemented) return send(res,501,{error:'NotImplemented',message:'Timeline operation is not implemented'});
    }
    if(url.pathname.includes('/town.delve.')) {
      if(req.headers['atproto-proxy']!==authority) return send(res,400,{error:'WrongService',message:'Town calls require AppView proxy'});
      const data=await body(req);
      const proxied=await fetch(appOrigin+req.url,{method:req.method,headers:{authorization:req.headers.authorization,'content-type':'application/json'},...(req.method==='POST'?{body:JSON.stringify(data)}:{})});
      return send(res,proxied.status,await proxied.json());
    }
    assert.equal(req.headers['atproto-proxy'],undefined,'home PDS calls must not proxy');
    const data=await body(req);
    if(url.pathname.endsWith('com.atproto.server.createSession')) return send(res,200,{did,handle:'external.test',accessJwt:'fixture-external',refreshJwt:'fixture-refresh'});
    if(url.pathname.endsWith('com.atproto.repo.createRecord')) {
      assert.equal(data.repo,did); assert.equal(data.collection,'town.delve.feed.post');
      assert.equal(data.record.$type,'town.delve.feed.post'); writes.push(data.record);
      if(data.record.text==='uncertain') {req.socket.destroy(); return;}
      return send(res,200,{uri:`at://${did}/${data.collection}/${writes.length}`,cid:`bafy${writes.length}`});
    }
    return send(res,404,{error:'UnsupportedFixtureCall'});
  } catch(e) { faults.push(e.message); send(res,500,{error:'FixtureAssertion',message:e.message}); }
});
await new Promise(resolve=>pds.listen(0,'127.0.0.1',resolve));
const client=new Client({name:'external-identity-proof',version:'1'});
const transport=new StdioClientTransport({command:process.env.AT_MCP_EXTERNAL_COMMAND,args:JSON.parse(process.env.AT_MCP_EXTERNAL_ARGS||'[]'),stderr:'pipe',env:{PATH:process.env.PATH,LANG:'C',LC_ALL:'C',AT_MCP_NETWORK:'delve',BLUESKY_HANDLE:'external.test',BLUESKY_APP_PASSWORD:'fixture',BLUESKY_SERVICE:`http://127.0.0.1:${pds.address().port}`,AT_MCP_STATE_DIR:join(root,'state')}});
let diagnostics='';transport.stderr?.on('data',s=>diagnostics+=s);
async function call(name,args={},error=false) {
  const result=await client.callTool({name,arguments:args});
  assert.equal(Boolean(result.isError),error,JSON.stringify(result));
  if(!error) assert.deepEqual(JSON.parse(result.content.find(x=>x.type==='text').text),result.structuredContent);
  return result.structuredContent;
}
try {
  await client.connect(transport);
  const identity=await call('identity_status'); assert.equal(identity.did,did);
  assert.equal((await call('get_membership')).membership.joined,true);
  assert.equal((await call('get_profile')).did,did);
  assert.equal((await call('get_timeline')).count,0);
  timelineUnimplemented=true;
  const before=timelineRequests;
  const unsupported=await client.callTool({name:'get_timeline',arguments:{}});
  assert.equal(unsupported.isError,true);
  assert.deepEqual(unsupported.structuredContent,{code:'upstream_not_implemented',http_status:501,upstream_message:'Timeline operation is not implemented'});
  const guidance=unsupported.content.find(x=>x.type==='text').text;
  assert.match(guidance,/not implemented/);
  assert.doesNotMatch(guidance,/retrying later|proxy|incompatib/i);
  assert.equal(timelineRequests,before+1,'unsupported operation must not retry');
  timelineUnimplemented=false;
  const post=await call('post',{text:'external account in town'});
  assert.ok(post.uri.includes('/town.delve.feed.post/'));
  const read=await call('get_posts',{uris:[post.uri,post.uri]});
  assert.equal(read.items[0].text,'external account in town');
  await call('mute',{actor:'did:plc:other'});
  await call('update_seen');
  membership=undefined; assert.equal((await call('get_membership')).membership,null);
  membership={did,status:'withdrawn',suspended:false,revision:2,joined:false};
  assert.equal((await call('get_membership')).membership.joined,false);
  membership={did,status:'active',suspended:true,revision:3,joined:true};
  assert.equal((await call('get_membership')).membership.suspended,true);
  membership={did,status:'active'}; await call('get_membership',{},true);
  membershipFailure=true; await call('get_membership',{},true);
  const unknown=await call('post',{text:'uncertain'},true);
  assert.equal(unknown.code,'write_outcome_unknown');
  assert.equal(writes.filter(x=>x.text==='uncertain').length,1,'uncertain writes must never retry');
  assert.equal(writes.length,2); assert.deepEqual(faults,[]);
  console.log(JSON.stringify({external_identity:did,appview_calls:calls.length,home_writes:writes.length,membership_states:true,unknown_write_not_retried:true}));
} catch(error) {throw new Error(`${error.stack}\n${diagnostics}`);}
finally {await client.close(); await new Promise(r=>pds.close(r)); await new Promise(r=>appview.close(r)); await rm(root,{recursive:true,force:true});}
