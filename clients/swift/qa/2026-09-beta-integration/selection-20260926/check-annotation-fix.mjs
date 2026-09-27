import fs from 'node:fs';
import path from 'node:path';
import net from 'node:net';
import {spawn, execFileSync} from 'node:child_process';
import {once} from 'node:events';
import {randomUUID, createHash} from 'node:crypto';
import {setTimeout as delay} from 'node:timers/promises';

const output = path.resolve(process.argv[2]);
const daemon = process.env.QA_DAEMON;
const codex = process.env.QA_CODEX ?? '/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex';
if (!daemon || fs.existsSync(output)) throw new Error('Requires QA_DAEMON and a new output directory');
fs.accessSync(codex, fs.constants.X_OK);
fs.mkdirSync(path.join(output, 'workspace'), {recursive: true});
fs.mkdirSync(path.join(output, 'data'));
const resumeFixture = process.env.QA_RESUME_FIXTURE;
const prior = resumeFixture ? JSON.parse(fs.readFileSync(path.join(resumeFixture, 'metadata.json'))) : null;
const threadId = prior?.threadId ?? `annotation-qa-${randomUUID()}`;
if (resumeFixture) {
  execFileSync('python3', ['-c', 'import sqlite3,sys; a=sqlite3.connect("file:"+sys.argv[1]+"?mode=ro",uri=True); b=sqlite3.connect(sys.argv[2]); a.backup(b); a.close(); b.close()', path.join(resumeFixture, 'data/maid.db'), path.join(output, 'data/maid.db')]);
}
const pending = new Map(), notifications = [], checks = [];
let child, exited, ws, log, sequence = 0, launch = 0;
const hash = file => createHash('sha256').update(fs.readFileSync(file)).digest('hex');
function save(name, value) { fs.writeFileSync(path.join(output, name), JSON.stringify(value, null, 2) + '\n'); }
function check(ok, message) { if (!ok) throw new Error(message); checks.push(message); }
function call(method, params) {
  return new Promise((resolve, reject) => {
    const id = ++sequence;
    const timer = setTimeout(() => { pending.delete(id); reject(new Error(`${method} timed out`)); }, 45000);
    pending.set(id, {resolve, reject, timer}); ws.send(JSON.stringify({jsonrpc: '2.0', id, method, params}));
  });
}
function dispatch(type, id, extra = {}) { return call('orchestration.dispatchCommand', {type, commandId: randomUUID(), threadId: id, ...extra}); }
async function snapshot(id = threadId) { return (await call('orchestration.subscribeThread', {threadId: id})).snapshot.thread; }
async function waitFor(id, predicate, label) {
  const deadline = Date.now() + 90000;
  let current;
  do {
    current = await snapshot(id);
    if (current.latestTurn?.state === 'error') { save(`${label}-error.json`, current); throw new Error(`${label}: turn failed`); }
    if (predicate(current)) return current;
    await delay(100);
  } while (Date.now() < deadline);
  save(`${label}-timeout.json`, current); throw new Error(`${label} timed out`);
}
function messages(thread) { return thread.timeline.filter(row => row.message).map(row => row.message); }
function comparable(thread) { return messages(thread).map(({id, role, text, annotations}) => ({id, role, text, annotations: annotations ?? []})); }
async function startDaemon() {
  launch++;
  const listener = net.createServer(); listener.listen(0, '127.0.0.1'); await once(listener, 'listening');
  const port = listener.address().port; await new Promise(resolve => listener.close(resolve));
  log = fs.openSync(path.join(output, `daemon-${launch}.log`), 'wx');
  child = spawn(daemon, [], {env: {...process.env, MAID_ADDR: `127.0.0.1:${port}`, MAID_DATA_DIR: path.join(output, 'data')}, stdio: ['ignore', log, log]});
  exited = once(child, 'exit');
  const deadline = Date.now() + 15000;
  while (true) {
    try {
      await new Promise((resolve, reject) => { const socket = net.connect(port, '127.0.0.1'); socket.once('connect', () => {socket.destroy(); resolve();}); socket.once('error', reject); }); break;
    } catch (error) { if (Date.now() > deadline || child.exitCode !== null) throw error; await delay(50); }
  }
  ws = new WebSocket(`ws://127.0.0.1:${port}/rpc`);
  ws.addEventListener('message', ({data}) => {
    const value = JSON.parse(String(data));
    if (value.method) notifications.push(value);
    const request = pending.get(value.id);
    if (request) { pending.delete(value.id); clearTimeout(request.timer); value.error ? request.reject(new Error(JSON.stringify(value.error))) : request.resolve(value.result); }
  });
  await once(ws, 'open');
  await call('provider.start', {instanceId: 'codex-app-server', name: 'Codex annotation QA', driver: 'codex-app-server', config: {command: [codex, '-c', 'approval_policy="never"', '-c', 'sandbox_mode="read-only"', 'app-server']}});
}
async function stopDaemon() {
  ws?.close(); ws = undefined;
  if (!child) return;
  child.kill('SIGTERM');
  await Promise.race([exited, delay(10000, undefined, {ref: false}).then(() => { if (child.exitCode === null && child.signalCode === null) child.kill('SIGKILL'); })]);
  save(`cleanup-${launch}.json`, {exitCode: child.exitCode, signalCode: child.signalCode}); fs.closeSync(log); child = undefined;
}
async function prepare(id) {
  await dispatch('thread.session.prepare', id);
  return waitFor(id, thread => thread.session?.status === 'ready' && messages(thread).length > 0, 'prepare');
}
const plain = 'Reply exactly ALPHA. Do not use tools.';
const annotation = (reference, note = plain) => ({id: randomUUID(), messageId: reference, role: 'assistant', quote: 'ALPHA', note});
async function send(text, annotations) {
  const message = {messageId: randomUUID(), text, annotations};
  await dispatch('thread.turn.start', threadId, {message});
  return waitFor(threadId, thread => thread.latestTurn?.state === 'completed' && messages(thread).some(row => row.id === message.messageId), 'send');
}
try {
  save('metadata.json', {baseCommit: execFileSync('git', ['rev-parse', 'HEAD'], {encoding: 'utf8'}).trim(), daemon, daemonSHA256: hash(daemon), codex, codexSHA256: hash(codex), codexVersion: execFileSync(codex, ['--version'], {encoding: 'utf8'}).trim(), threadId});
  fs.writeFileSync(path.join(output, 'backend-source.diff'), execFileSync('git', ['diff', '--', 'internal'], {encoding: 'utf8'}));
  await startDaemon();
  if (resumeFixture) {
    const expected = comparable(JSON.parse(fs.readFileSync(path.join(resumeFixture, 'live.json'))));
    const fork = JSON.parse(fs.readFileSync(path.join(resumeFixture, 'fork.json')));
    for (const [label, id] of [['source', threadId], ['fork', fork.threadId]]) {
      const restored = await prepare(id); save(`${label}-resumed.json`, restored);
      check(JSON.stringify(comparable(restored)) === JSON.stringify(expected), `${label} preserves exact presentation with selected runtime`);
    }
  } else {
  await dispatch('thread.start', threadId, {providerInstanceId: 'codex-app-server', cwd: path.join(output, 'workspace'), title: 'Annotation persistence QA', modelSelection: {model: 'gpt-5.6-luna'}, configSelections: [{optionId: 'reasoning_effort', value: 'low'}], message: {messageId: randomUUID(), text: plain}});
  let live = await waitFor(threadId, thread => thread.latestTurn?.state === 'completed', 'initial');
  const firstAssistant = messages(live).find(row => row.role === 'assistant');
  check(firstAssistant?.text === 'ALPHA', 'initial exact reply');
  live = await send('', [annotation(firstAssistant.id)]);
  const secondAssistant = messages(live).filter(row => row.role === 'assistant').at(-1);
  check(secondAssistant?.text === 'ALPHA', 'annotation-only prompt accepted');
  live = await send(plain, [annotation(firstAssistant.id, 'Same quoted context')]);
  live = await send(plain, [annotation(secondAssistant.id, 'Same quoted context')]);
  save('before-steering.json', live);
  const slow = {messageId: randomUUID(), text: 'Run exactly python3 -c "import time; time.sleep(6)" once using the terminal, then reply exactly ALPHA. Do not read or modify any files and do not use other tools.'};
  await dispatch('thread.turn.start', threadId, {message: slow});
  live = await waitFor(threadId, thread => thread.latestTurn?.state === 'running' && thread.timeline.some(row => row.item?.status === 'in_progress' && row.item?.turnId === thread.latestTurn.turnId), 'active-tool');
  const activeTurn = live.latestTurn.turnId;
  const steering = [firstAssistant, secondAssistant].map(reference => ({messageId: randomUUID(), text: 'After the current command finishes, reply exactly ALPHA. Do not use any more tools.', annotations: [annotation(reference.id, 'Same quoted context')]}));
  for (const message of steering) await dispatch('thread.turn.start', threadId, {message});
  live = await waitFor(threadId, thread => thread.latestTurn?.state === 'completed' && steering.every(message => messages(thread).some(row => row.id === message.messageId)), 'steering-complete');
  check(steering.every(message => messages(live).find(row => row.id === message.messageId)?.turnId === activeTurn), 'both annotated steering messages belong to the same active turn');
  save('live.json', live);
  const expected = comparable(live);
  const fork = await call('provider.forkThread', {sourceThreadId: threadId}); save('fork.json', fork);
  const forked = await prepare(fork.threadId); save('fork-replayed.json', forked);
  check(JSON.stringify(comparable(forked)) === JSON.stringify(expected), 'native fork preserves exact messages, original IDs and annotation cards');
  await stopDaemon(); await startDaemon();
  for (const [label, id] of [['source', threadId], ['fork', fork.threadId]]) {
    const restored = await prepare(id); save(`${label}-after-restart.json`, restored);
    check(JSON.stringify(comparable(restored)) === JSON.stringify(expected), `${label} preserves exact presentation after daemon restart`);
    const ids = new Set(messages(restored).map(message => message.id));
    check(ids.size === messages(restored).length && messages(restored).every(message => (message.annotations ?? []).every(annotation => ids.has(annotation.messageId))), `${label} has unique message IDs and valid quote references`);
  }
  }
  save('result.json', {passed: true, checks}); console.log(JSON.stringify({passed: true, checks}, null, 2));
} catch (error) { save('failure.json', {error: String(error), checks}); throw error; }
finally { for (const request of pending.values()) clearTimeout(request.timer); await stopDaemon(); save('notifications.json', notifications); }
