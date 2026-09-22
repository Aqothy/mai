import fs from 'node:fs';
import {createHash} from 'node:crypto';
import {setTimeout as delay} from 'node:timers/promises';
const out = new URL('./', import.meta.url);
const clients = [];
function assert(value, message) {if (!value) throw new Error(message);}
function save(name, data) {fs.writeFileSync(new URL(name, out), JSON.stringify(data, null, 2) + '\n', {flag:'wx'});}
async function client() {
  const socket = new WebSocket('ws://127.0.0.1:8765/rpc');
  const pending = new Map(), events = [];
  let id = 0;
  socket.addEventListener('message', ({data}) => {
    const message = JSON.parse(String(data));
    if (!message.id) {events.push(message); return;}
    const request = pending.get(message.id);
    if (!request) return;
    pending.delete(message.id); clearTimeout(request.timer);
    message.error ? request.reject(new Error(JSON.stringify(message.error))) : request.resolve(message.result);
  });
  await new Promise((resolve, reject) => {
    socket.addEventListener('open', resolve, {once:true});
    socket.addEventListener('error', reject, {once:true});
  });
  const result = {
    socket, events,
    call(method, params) {return new Promise((resolve, reject) => {
      const key = ++id;
      const timer = setTimeout(() => {pending.delete(key); reject(new Error(`${method} timed out`));}, 30000);
      pending.set(key, {resolve, reject, timer});
      socket.send(JSON.stringify({jsonrpc:'2.0', id:key, method, params}));
    });},
    notify(method, params) {socket.send(JSON.stringify({jsonrpc:'2.0', method, params}));},
    items(runId) {return events.filter(x => x.method === 'terminal.subscribe' && x.params.runId === runId).map(x => x.params);},
    output(runId) {return Buffer.concat(this.items(runId).filter(x => x.kind === 'output').map(x => Buffer.from(x.data, 'base64')));},
    close() {socket.close(); for (const request of pending.values()) clearTimeout(request.timer);},
  };
  clients.push(result); return result;
}
async function until(test, name, timeout = 30000) {
  const deadline = Date.now() + timeout;
  while (!test()) {if (Date.now() > deadline) throw new Error(`${name} timed out`); await delay(50);}
}
function input(c, terminalId, runId, command) {c.notify('terminal.write', {terminalId, runId, data:Buffer.from(command + '\n').toString('base64')});}
const a = await client();
let terminalId, runId;
const result = {source:'5ea7385', checks:[], startedAt:new Date().toISOString()};
try {
  const created = await a.call('terminal.create', {title:'Release QA — terminal', cwd:'/Users/aqothy/Library/Caches/maiD-QA/2026-09-20/live-release/workspace', columns:80, rows:24});
  ({runId} = created); terminalId = created.terminal.terminalId;
  assert(terminalId && runId && created.terminal.status === 'running', 'creation did not return a running terminal');
  result.terminalId = terminalId; result.originalRunId = runId;
  result.snapshotFormat = created.snapshotFormat;
  input(a, terminalId, runId, "exec /bin/sh");
  input(a, terminalId, runId, "stty -echo -onlcr; PS1=''; printf '\\r\\nREADY-%s\\r\\n' terminal");
  await until(() => a.output(runId).includes('READY-terminal'), 'quiet shell');
  result.checks.push('create and live input');
  const started = performance.now();
  input(a, terminalId, runId, '/usr/bin/python3 /Users/aqothy/Library/Caches/maiD-QA/2026-09-20/live-release/workspace/terminal-output.py');
  await until(() => a.output(runId).includes('QA-BURST-END\r\n'), '5 MiB burst');
  const all = a.output(runId);
  const begin = Buffer.from('QA-BURST-BEGIN\r\n'), end = Buffer.from('\r\nQA-BURST-END\r\n');
  const burst = all.subarray(all.indexOf(begin) + begin.length, all.indexOf(end));
  const expected = Buffer.from(Array.from({length:65536}, (_, i) => `${String(i).padStart(6, '0')}|${'x'.repeat(72)}\n`).join(''));
  assert(expected.length === 5 * 1024 * 1024 && burst.equals(expected), '5 MiB ordered payload differs');
  const chunks = a.items(runId).filter(x => x.kind === 'output');
  assert(chunks.every((x, i) => i === 0 || x.sequence > chunks[i-1].sequence), 'output sequences not strictly increasing');
  const maximumChunk = Math.max(...chunks.map(x => Buffer.from(x.data, 'base64').length));
  assert(maximumChunk <= 65536, 'notification exceeds batching limit');
  result.burst = {bytes:burst.length, sha256:createHash('sha256').update(burst).digest('hex'), chunks:chunks.length, maximumChunk, elapsedMs:performance.now()-started};
  result.checks.push('exact ordered 5 MiB payload and monotonic bounded notifications');
  input(a, terminalId, runId, "printf '\\r\\nAFTER-%s\\r\\n' burst");
  await until(() => a.output(runId).includes('AFTER-burst'), 'post-burst input');
  a.close();
  const b = await client();
  const attached = await b.call('terminal.attach', {terminalId, columns:96, rows:31});
  assert(attached.runId === runId && attached.columns === 96 && attached.rows === 31, 'reconnect changed run or ignored grid');
  assert(Buffer.from(attached.snapshot, 'base64').includes('AFTER-burst'), 'snapshot lost prior visible output');
  input(b, terminalId, runId, "set -- $(stty size); printf '\\r\\nSIZE-%s-%s\\r\\n' \"$1\" \"$2\"");
  await until(() => b.output(runId).includes('SIZE-31-96'), 'PTY resize');
  assert(b.items(runId).filter(x => x.kind === 'output').every(x => x.sequence > attached.sequence), 'live output overlapped snapshot sequence');
  result.reconnect = {runId:attached.runId, snapshotSequence:attached.sequence, snapshotBytes:Buffer.from(attached.snapshot, 'base64').length, columns:attached.columns, rows:attached.rows};
  result.checks.push('disconnect/reconnect retains process and atomic history; actual PTY grid matches resize');
  b.notify('terminal.detach', {terminalId, runId});
  await b.call('terminal.subscribeList', {});
  const c = await client();
  await c.call('terminal.attach', {terminalId, columns:96, rows:31});
  input(b, terminalId, runId, "printf 'DETACHED-%s\\n' forbidden");
  input(c, terminalId, runId, "printf '\\r\\nATTACHED-%s\\r\\n' allowed");
  await until(() => c.output(runId).includes('ATTACHED-allowed'), 'attached input');
  await delay(100);
  assert(!c.output(runId).includes('DETACHED-forbidden'), 'detached client input executed');
  const oldRun = runId;
  const relaunched = await c.call('terminal.relaunch', {terminalId, columns:80, rows:24});
  runId = relaunched.runId;
  assert(runId && runId !== oldRun && relaunched.terminal.status === 'running', 'relaunch did not create fresh run');
  input(c, terminalId, runId, "exec /bin/sh");
  input(c, terminalId, runId, "stty -echo; PS1=''; printf '\\nNEW-%s\\n' ready");
  await until(() => c.output(runId).includes('NEW-ready'), 'relaunched shell');
  input(c, terminalId, oldRun, "printf 'STALE-%s\\n' forbidden");
  input(c, terminalId, runId, "printf '\\nCURRENT-%s\\n' allowed");
  await until(() => c.output(runId).includes('CURRENT-allowed'), 'current run input');
  await delay(100);
  assert(!c.output(runId).includes('STALE-forbidden'), 'stale run input executed');
  result.newRunId = runId;
  result.checks.push('detached input rejected; relaunch replaces run and rejects stale input');
  input(c, terminalId, runId, 'exit 7');
  await until(() => c.items(runId).some(x => x.kind === 'status' && x.status === 'exited'), 'exit notification');
  const exit = c.items(runId).find(x => x.kind === 'status' && x.status === 'exited');
  assert(exit.exitCode === 7, `exit code lost: ${JSON.stringify(exit)}`);
  const final = await c.call('terminal.relaunch', {terminalId, columns:80, rows:24});
  assert(final.runId !== runId, 'relaunch after exit reused run');
  await c.call('terminal.terminate', {terminalId});
  await c.call('terminal.delete', {terminalId});
  const list = await c.call('terminal.subscribeList', {});
  assert(!(list.terminals ?? []).some(x => x.terminalId === terminalId), 'deleted terminal remains in list');
  result.checks.push('exit code, relaunch after exit, terminate and delete');
  result.completedAt = new Date().toISOString();
  save('result.json', result);
  console.log(JSON.stringify(result, null, 2));
} catch (error) {
  save('failure.json', {...result, error:String(error)});
  throw error;
} finally {
  for (const c of clients) c.close();
}
