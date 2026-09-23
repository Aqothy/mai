import fs from 'node:fs';
import path from 'node:path';
import net from 'node:net';
import {spawn,execFileSync} from 'node:child_process';
import {once} from 'node:events';
import {randomUUID,createHash} from 'node:crypto';
import {setTimeout as delay} from 'node:timers/promises';
const output=path.resolve(process.argv[2]);
const phase=process.argv[3]??'approvals';
if(!['approvals','approval-session','client'].includes(phase))throw new Error('Phase must be approvals, approval-session, or client');
const control=path.resolve(process.argv[4]??output);
if(!process.argv[2] || fs.existsSync(output)) throw new Error('Pass a new output directory');
fs.mkdirSync(output,{recursive:true});
const cache=path.join('/Users/aqothy/Library/Caches/maiD-QA/2026-09-22',path.basename(output));
const workspace=path.join(cache,'workspace');const data=path.join(cache,'data');
fs.mkdirSync(workspace,{recursive:true});fs.mkdirSync(data,{recursive:true});
if(fs.readdirSync(data).length || fs.readdirSync(workspace).length) throw new Error('Use a fresh disposable workspace/data pair');
const daemon=process.env.QA_DAEMON??'/Users/aqothy/Library/Caches/maiD-QA/2026-09-21/maiD-reasoning';
const codex='/Applications/ChatGPT.app/Contents/Resources/codex';
const listener=net.createServer();listener.listen(0,'127.0.0.1');await once(listener,'listening');
const port=listener.address().port;await new Promise(r=>listener.close(r));
const daemonLog=fs.openSync(path.join(output,'daemon.log'),'wx');
const child=spawn(daemon,[],{env:{...process.env,MAID_ADDR:`127.0.0.1:${port}`,MAID_DATA_DIR:data},stdio:['ignore',daemonLog,daemonLog]});
const exited=once(child,'exit');let ws;let next=0;const pending=new Map();const events=[];const checks=[];
const metadata={source:execFileSync('git',['rev-parse','HEAD'],{encoding:'utf8'}).trim(),daemon,daemonSHA256:createHash('sha256').update(fs.readFileSync(daemon)).digest('hex'),codex,codexVersion:execFileSync(codex,['--version'],{encoding:'utf8'}).trim(),workspace,data,endpoint:`ws://127.0.0.1:${port}/rpc`,provider:'Codex only',policy:'on-request + read-only + user reviewer (child-process configuration only)'};
const sourceDiff=execFileSync('git',['diff','--','internal','cmd'],{encoding:'utf8'});
metadata.backendSourceDiffSHA256=createHash('sha256').update(sourceDiff).digest('hex');
fs.writeFileSync(path.join(output,'backend-source.diff'),sourceDiff);
function save(name,value){fs.writeFileSync(path.join(output,name),JSON.stringify(value,null,2)+'\n');}
function check(ok,message){if(!ok)throw new Error(message);}
function call(method,params){return new Promise((resolve,reject)=>{const id=++next;const timer=setTimeout(()=>{pending.delete(id);reject(new Error(`${method} timed out`));},45000);pending.set(id,{resolve,reject,timer});ws.send(JSON.stringify({jsonrpc:'2.0',id,method,params}));});}
function dispatch(type,threadId,extra={}){return call('orchestration.dispatchCommand',{type,commandId:randomUUID(),threadId,...extra});}
async function snapshot(threadId){return (await call('orchestration.subscribeThread',{threadId})).snapshot.thread;}
function approvals(thread){return thread.timeline.filter(x=>x.kind==='approval'&&x.approval.status==='pending').map(x=>x.approval);}
async function waitThread(threadId,label,predicate,seconds=90){const deadline=Date.now()+seconds*1000;let t;do{t=await snapshot(threadId);if(predicate(t))return t;await delay(100);}while(Date.now()<deadline);save(label+'-timeout.json',t);throw new Error(label+' timed out');}
async function start(label,prompt){const id=`workflow-${label}-${randomUUID()}`;await dispatch('thread.start',id,{providerInstanceId:'codex-app-server',cwd:workspace,title:`QA ${label}`,modelSelection:{model:'gpt-5.6-luna'},configSelections:[{optionId:'reasoning_effort',value:'low'}],message:{text:prompt}});return id;}
try{
 const readyDeadline=Date.now()+15000;
 while(true){try{await new Promise((resolve,reject)=>{const s=net.connect(port,'127.0.0.1');s.once('connect',()=>{s.destroy();resolve();});s.once('error',reject);});break;}catch(e){if(Date.now()>readyDeadline||child.exitCode!==null)throw e;await delay(50);}}
 ws=new WebSocket(metadata.endpoint);await once(ws,'open');
 ws.addEventListener('message',({data})=>{const m=JSON.parse(String(data));if(m.method)events.push(m);const p=pending.get(m.id);if(p){pending.delete(m.id);clearTimeout(p.timer);m.error?p.reject(new Error(JSON.stringify(m.error))):p.resolve(m.result);}});
 const provider=await call('provider.start',{instanceId:'codex-app-server',name:'Codex workflow QA',driver:'codex-app-server',config:{command:[codex,'-c','approval_policy="on-request"','-c','sandbox_mode="read-only"','-c','approvals_reviewer="user"','app-server']}});
 check(provider.auth?.status==='authenticated','Codex authentication unavailable');
 metadata.authenticated=true;save('metadata.json',metadata);
 if(phase==='client'){
  save('ready.json',{...metadata,daemonPID:child.pid,providerPID:provider.pid,stopFile:path.join(output,'stop')});
  console.log('Isolated Codex client endpoint ready: '+metadata.endpoint);
  const deadline=Date.now()+20*60*1000;
  let crashed=false;
  while(!fs.existsSync(path.join(output,'stop'))){
   if(Date.now()>deadline)throw new Error('Client QA hold expired');
   const requestFile=path.join(control,'crash-provider-request.json');
   if(!crashed&&fs.existsSync(requestFile)){
    const request=JSON.parse(fs.readFileSync(requestFile));
    const t=await snapshot(request.threadId);
    check(t.cwd===workspace&&t.latestTurn?.state==='running','Crash request does not target an active isolated QA turn');
    check(Number(execFileSync('ps',['-p',String(provider.pid),'-o','ppid='],{encoding:'utf8'}).trim())===child.pid,'Provider is not the owned daemon child');
    process.kill(provider.pid,'SIGKILL');crashed=true;
    save('provider-crash.json',{threadId:t.id,turnId:t.latestTurn.turnId,providerPID:provider.pid,daemonPID:child.pid,at:new Date().toISOString()});
   }
   await delay(250);
  }
 }
 for(const decision of phase==='approvals'?['decline','accept']:phase==='approval-session'?['acceptForSession']:[]){
  const allowed=decision!=='decline';
  const name=decision==='acceptForSession'?'session-accepted.txt':allowed?'accepted.txt':'declined.txt';const marker=allowed?'QA_ACCEPTED':'QA_DECLINED';
  const program=`from pathlib import Path; Path("${name}").write_text("${marker}")`;
  const prompt=`This is a scoped permission QA test in the disposable current directory. Request command-execution approval for the write before running it (the child sandbox is read-only). Use the terminal tool to run exactly: python3 -c '${program}'. Do not use apply_patch or any other tool, read any files, or retry if denied. If approval is denied, finish with exactly DENIED; otherwise finish with exactly WRITTEN.`;
  const id=await start('approval-'+decision,prompt);
  let t=await waitThread(id,'approval-'+decision,t=>approvals(t).length>0||t.latestTurn?.state==='completed'||t.latestTurn?.state==='error');
  save('approval-'+decision+'-pending.json',t);
  check(approvals(t).length===1,'Expected a real pending command approval');
  const a=approvals(t)[0];
  check(a.args.cwd===workspace,'Unexpected approval working directory');
  check(a.args.commandActions?.length===1&&a.args.commandActions[0].command===`python3 -c '${program}'`,'Unexpected approval command');
  check(!fs.existsSync(path.join(workspace,name)),'Command ran before approval');
  const receipt=await dispatch('thread.approval.respond',id,{requestId:a.requestId,decision,optionId:decision});
  t=await waitThread(id,'approval-'+decision+'-complete',t=>t.latestTurn?.state==='completed');
  check(approvals(t).length===0,'Approval remained pending after completion');
  const exists=fs.existsSync(path.join(workspace,name));check(exists===allowed,'Approval decision did not control file execution');
  if(exists)check(fs.readFileSync(path.join(workspace,name),'utf8')===marker,'Written marker differs');
  save('approval-'+decision+'-completed.json',t);checks.push({check:'approval-'+decision,threadId:id,receipt,fileExists:exists,passed:true});
  console.log('Passed actual Codex approval '+decision);
 }
 save('result.json',{checks});
}catch(error){save('failure.json',{error:String(error),checks});throw error;}
finally{
 save('metadata.json',metadata);save('notifications.json',events);
 if(ws)ws.close();for(const p of pending.values())clearTimeout(p.timer);
 child.kill('SIGTERM');await Promise.race([exited,delay(10000,undefined,{ref:false}).then(()=>{if(child.exitCode===null&&child.signalCode===null)child.kill('SIGKILL');})]);
 fs.closeSync(daemonLog);save('cleanup.json',{daemonExited:child.exitCode!==null||child.signalCode!==null,exitCode:child.exitCode,signalCode:child.signalCode});
}
