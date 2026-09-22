import fs from 'node:fs';
import path from 'node:path';
import {randomUUID} from 'node:crypto';
import {setTimeout as delay} from 'node:timers/promises';
const dir=path.dirname(new URL(import.meta.url).pathname);
const original=JSON.parse(fs.readFileSync(path.join(dir,'completed-snapshot.json'),'utf8')).result.snapshot.thread;
const listed=JSON.parse(fs.readFileSync(path.join(dir,'session-list.json'),'utf8'));
const source=listed.find(x=>x.sessionId==='01a0c583-402a-7653-9b6b-cfe34da193e3');
if(!source)throw new Error('Original QA session missing from captured history');
const ws=new WebSocket('ws://127.0.0.1:8765/rpc');let id=0;const pending=new Map();
const transcript=[];
ws.addEventListener('message',e=>{const m=JSON.parse(String(e.data));transcript.push(m);if(m.id){const p=pending.get(m.id);if(p){pending.delete(m.id);clearTimeout(p.timer);m.error?p.reject(new Error(JSON.stringify(m.error))):p.resolve(m.result);}}});
function call(method,params){transcript.push({request:method,params});return new Promise((resolve,reject)=>{const key=++id;const timer=setTimeout(()=>{pending.delete(key);reject(new Error(`${method} timed out`));},30000);pending.set(key,{resolve,reject,timer});ws.send(JSON.stringify({jsonrpc:'2.0',id:key,method,params}));});}
function save(name,data){fs.writeFileSync(path.join(dir,name),JSON.stringify(data,null,2)+'\n',{flag:'wx'});}
function check(condition,message){if(!condition)throw new Error(message);}
function messages(t){return t.timeline.filter(x=>x.kind==='message').map(x=>({role:x.message.role,text:x.message.text}));}
async function prepare(threadId){
 await call('orchestration.dispatchCommand',{type:'thread.session.prepare',commandId:randomUUID(),threadId});
 const deadline=Date.now()+30000;let t;
 do{t=(await call('orchestration.subscribeThread',{threadId})).snapshot.thread;if(t.session?.status==='ready'&&messages(t).length===2)break;await delay(250);}while(Date.now()<deadline);
 check(t.session?.status==='ready','session is not ready');
 check(JSON.stringify(messages(t))===JSON.stringify(messages(original)),'recovered message content differs or is duplicated');return t;
}
await new Promise((resolve,reject)=>{ws.addEventListener('open',resolve,{once:true});ws.addEventListener('error',reject,{once:true});});
try{
 const imported=await call('provider.importSession',{instanceId:'codex-app-server',session:source});save('import-original.json',imported);
 const duplicate=await call('provider.importSession',{instanceId:'codex-app-server',session:source});check(duplicate.threadId===imported.threadId&&!duplicate.imported,'import is not idempotent');save('import-duplicate.json',duplicate);
 const replayed=await prepare(imported.threadId);save('imported-replayed.json',replayed);
 await call('orchestration.dispatchCommand',{type:'thread.meta.update',commandId:randomUUID(),threadId:imported.threadId,title:'Release QA — restored'});
 const fork=await call('provider.forkThread',{sourceThreadId:imported.threadId});check(fork.threadId!==imported.threadId,'fork must have independent local identity');save('real-fork.json',fork);
 save('fork-replayed.json',await prepare(fork.threadId));
 await call('orchestration.dispatchCommand',{type:'thread.meta.update',commandId:randomUUID(),threadId:fork.threadId,title:'Release QA — fork'});
 const restarted=await call('provider.start',{instanceId:'codex-app-server',name:'Codex QA',driver:'codex-app-server',config:{command:['/Applications/ChatGPT.app/Contents/Resources/codex','app-server']},restart:true});save('provider-restarted.json',restarted);
 const recovered=await prepare(imported.threadId);save('provider-restart-recovered.json',recovered);
 check(recovered.title==='Release QA — restored','renamed title lost');
 const providers=await call('provider.list',{});check(providers.find(x=>x.instanceId==='claude-code').status==='configured','Claude was unexpectedly initialized');save('providers-after-recovery.json',providers);
 save('recovery-result.json',{sourceSession:source.sessionId,importedThread:imported.threadId,forkedThread:fork.threadId,idempotentImport:true,exactReplay:true,forkExactHistory:true,providerRestartPreservesMessages:true,claudeConfiguredOnly:true});
 console.log('Original history import, idempotent import, exact replay, independent fork history, and provider restart recovery passed.');
}catch(error){save('recovery-failure.json',{error:String(error)});throw error;}
finally{save('recovery-protocol.json',transcript);ws.close();for(const p of pending.values())clearTimeout(p.timer);}
