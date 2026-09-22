import fs from 'node:fs';
import {randomUUID, createHash} from 'node:crypto';
import {setTimeout as delay} from 'node:timers/promises';
const out = new URL('./', import.meta.url);
const socket = new WebSocket('ws://127.0.0.1:8765/rpc');
let id = 0;
const pending = new Map();
socket.addEventListener('message', ({data}) => {
  const message = JSON.parse(String(data));
  const request = pending.get(message.id);
  if (!request) return;
  pending.delete(message.id);
  clearTimeout(request.timer);
  message.error ? request.reject(new Error(JSON.stringify(message.error))) : request.resolve(message.result);
});
function call(method, params) {
  return new Promise((resolve, reject) => {
    const key = ++id;
    const timer = setTimeout(() => {pending.delete(key); reject(new Error(`${method} timed out`));}, 30000);
    pending.set(key, {resolve, reject, timer});
    socket.send(JSON.stringify({jsonrpc:'2.0', id:key, method, params}));
  });
}
const threadId = `reasoning-qa-${randomUUID()}`;
const commandId = randomUUID();
await new Promise((resolve, reject) => {
  socket.addEventListener('open', resolve, {once:true});
  socket.addEventListener('error', reject, {once:true});
});
try {
  const command = {
    type:'thread.start', commandId, threadId, providerInstanceId:'codex-app-server',
    cwd:'/Users/aqothy/Library/Caches/maiD-QA/2026-09-20/live-release/workspace',
    title:'Release QA — reasoning', modelSelection:{model:'gpt-5.6-luna'},
    configSelections:[{optionId:'reasoning_effort', value:'low'}],
    message:{text:'Reply with exactly OK. Do not use tools or modify files.'},
  };
  await call('orchestration.dispatchCommand', command);
  const deadline = Date.now() + 90000;
  let thread;
  do {
    thread = (await call('orchestration.subscribeThread', {threadId})).snapshot.thread;
    if (thread.latestTurn?.state === 'completed') break;
    await delay(250);
  } while (Date.now() < deadline);
  const messages = thread.timeline.filter(x => x.kind === 'message').map(x => ({role:x.message.role, text:x.message.text}));
  const options = thread.session?.configOptions ?? [];
  const effort = options.find(x => x.id === 'reasoning_effort')?.currentValue;
  if (thread.latestTurn?.state !== 'completed' || effort !== 'low' || messages.length !== 2 || messages[1].text.trim() !== 'OK') {
    fs.writeFileSync(new URL('daemon-failure.json', out), JSON.stringify(thread, null, 2));
    throw new Error(`Unexpected turn/config: ${JSON.stringify({effort, messages})}`);
  }
  const result = {source:'5ea7385', threadId, command, effectiveEffort:effort, messages, sessionStatus:thread.session.status, latestTurn:thread.latestTurn,
    daemonSHA256:createHash('sha256').update(fs.readFileSync('/Users/aqothy/Library/Caches/maiD-QA/2026-09-21/maiD-reasoning')).digest('hex')};
  fs.writeFileSync(new URL('daemon-result.json', out), JSON.stringify(result, null, 2) + '\n', {flag:'wx'});
  console.log('Real daemon selected low reasoning and completed its Codex turn.');
} finally {
  socket.close();
  for (const request of pending.values()) clearTimeout(request.timer);
}
