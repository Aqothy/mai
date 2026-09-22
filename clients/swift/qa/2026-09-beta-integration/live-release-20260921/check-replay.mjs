// Historical failed QA harness: thread.session.stop resets the route. It is
// not a reconnect operation. Use check-recovery.mjs for the corrected flow.
import fs from 'node:fs';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { setTimeout as delay } from 'node:timers/promises';
const dir=path.dirname(new URL(import.meta.url).pathname);
const threadID=fs.readFileSync(path.join(dir,'thread-id.txt'),'utf8').trim();
const original=JSON.parse(fs.readFileSync(path.join(dir,'completed-snapshot.json'),'utf8')).result.snapshot.thread;
const ws=new WebSocket('ws://127.0.0.1:8765/rpc');
let nextID=0;const pending=new Map();
const events=[];
ws.addEventListener('message',e=>{
 const m=JSON.parse(String(e.data));
 if(m.id){const p=pending.get(m.id);if(p){pending.delete(m.id);clearTimeout(p.timer);m.error?p.reject(new Error(JSON.stringify(m.error))):p.resolve(m.result);}}
 else events.push(m);
});
function call(method,params){return new Promise((resolve,reject)=>{const id=++nextID;const timer=setTimeout(()=>{pending.delete(id);reject(new Error(`${method} timed out`));},30000);pending.set(id,{resolve,reject,timer});ws.send(JSON.stringify({jsonrpc:'2.0',id,method,params}));});}
function save(name,data){fs.writeFileSync(path.join(dir,name),JSON.stringify(data,null,2)+'\n',{flag:'wx'});}
function messages(t){return t.timeline.filter(x=>x.kind==='message').map(x=>({role:x.message.role,text:x.message.text}));}
function check(value,message){if(!value)throw new Error(message);}
await new Promise((resolve,reject)=>{ws.addEventListener('open',resolve,{once:true});ws.addEventListener('error',reject,{once:true});});
try{
 const initial=await call('orchestration.subscribeThread',{threadId:threadID});
 check(JSON.stringify(messages(initial.snapshot.thread))===JSON.stringify(messages(original)),'fresh subscriber content differs');
 save('fresh-subscriber.json',initial);
 const listed=await call('provider.listSessions',{instanceId:'codex-app-server',cwd:original.cwd});
 save('session-list.json',listed);
 check(listed.length>0,'working-directory history is empty');
 await call('orchestration.dispatchCommand',{type:'thread.meta.update',commandId:randomUUID(),threadId:threadID,title:'Release QA — Unicode'});
 await call('orchestration.dispatchCommand',{type:'thread.session.stop',commandId:randomUUID(),threadId:threadID});
 await call('orchestration.dispatchCommand',{type:'thread.session.prepare',commandId:randomUUID(),threadId:threadID});
 let resumed;
 const deadline=Date.now()+30000;
 do{
  resumed=(await call('orchestration.subscribeThread',{threadId:threadID})).snapshot.thread;
  if(resumed.session?.status==='ready'&&messages(resumed).length===2)break;
  await delay(250);
 }while(Date.now()<deadline);
 check(resumed.session?.status==='ready','resumed session is not ready');
 check(JSON.stringify(messages(resumed))===JSON.stringify(messages(original)),'replayed messages differ or are duplicated');
 check(resumed.title==='Release QA — Unicode','rename was lost');
 save('resumed-thread.json',resumed);
 const fork=await call('provider.forkThread',{sourceThreadId:threadID});
 check(fork.threadId&&fork.threadId!==threadID,'fork identity is not independent');
 save('fork.json',fork);
 const forkSnapshot=await call('orchestration.subscribeThread',{threadId:fork.threadId});
 save('fork-initial-snapshot.json',forkSnapshot);
 save('replay-events.json',events);
 save('replay-result.json',{freshSubscriber:true,listedSessions:listed.length,stopAndResumeExactMessages:true,renamedTitlePreserved:true,independentFork:fork.threadId,originalThread:threadID});
 console.log('Fresh subscriber, live history listing, rename, stop/resume exact content, and independent fork passed.');
}finally{ws.close();for(const p of pending.values())clearTimeout(p.timer);}
