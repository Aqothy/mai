import fs from 'node:fs';
import path from 'node:path';
import net from 'node:net';
import {spawn, execFileSync} from 'node:child_process';
import {once} from 'node:events';
import {randomUUID, createHash} from 'node:crypto';
import {gunzipSync} from 'node:zlib';
import {setTimeout as delay} from 'node:timers/promises';

// Only the disposable September 22 annotated QA chat is reopened. Prepare
// a consistent SQLite backup in output/data before invoking this probe.
const output = path.resolve(process.argv[2]);
const daemon = process.env.QA_DAEMON;
if (!daemon || !fs.existsSync(path.join(output, 'data/maid.db')) || ['metadata.json', 'daemon.log', 'failure.json'].some(name => fs.existsSync(path.join(output, name)))) {
  throw new Error('Requires QA_DAEMON and a fresh output containing the disposable database backup');
}
const threadId = 'swift-queue-0EE6AC87-9B84-4AB2-8A3D-804F44017A9F';
const fixture = JSON.parse(gunzipSync(fs.readFileSync(new URL('../workflows-20260922/evidence/client-workflows-a/steering-completed.json.gz', import.meta.url))));
const codex = process.env.QA_CODEX ?? '/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex';
fs.accessSync(codex, fs.constants.X_OK);
const listener = net.createServer();
listener.listen(0, '127.0.0.1'); await once(listener, 'listening');
const port = listener.address().port; await new Promise(resolve => listener.close(resolve));
const log = fs.openSync(path.join(output, 'daemon.log'), 'wx');
const child = spawn(daemon, [], {env: {...process.env, MAID_ADDR: `127.0.0.1:${port}`, MAID_DATA_DIR: path.join(output, 'data')}, stdio: ['ignore', log, log]});
const exited = once(child, 'exit');
let ws, next = 0;
const pending = new Map();
function save(name, value) { fs.writeFileSync(path.join(output, name), JSON.stringify(value, null, 2) + '\n'); }
function call(method, params) {
  return new Promise((resolve, reject) => {
    const id = ++next;
    const timer = setTimeout(() => { pending.delete(id); reject(new Error(`${method} timed out`)); }, 45000);
    pending.set(id, {resolve, reject, timer});
    ws.send(JSON.stringify({jsonrpc: '2.0', id, method, params}));
  });
}
async function prepare(id) {
  await call('orchestration.dispatchCommand', {type: 'thread.session.prepare', commandId: randomUUID(), threadId: id});
  const deadline = Date.now() + 45000;
  let snapshot;
  do {
    snapshot = (await call('orchestration.subscribeThread', {threadId: id})).snapshot.thread;
    if (snapshot.session?.status === 'ready' && snapshot.timeline.some(row => row.message?.text.includes('STEERED'))) return snapshot;
    await delay(100);
  } while (Date.now() < deadline);
  save('timeout.json', snapshot); throw new Error('Annotated fixture did not finish replay');
}
function inspect(thread) {
  const matches = thread.timeline.filter(row => row.message?.text.includes('Change your final reply for this running turn'));
  return matches.map(row => ({id: row.message.id, text: row.message.text, annotations: row.message.annotations ?? []}));
}
try {
  save('metadata.json', {commit: execFileSync('git', ['rev-parse', 'HEAD'], {encoding: 'utf8'}).trim(), daemon,
    daemonSHA256: createHash('sha256').update(fs.readFileSync(daemon)).digest('hex'),
    codex, codexSHA256: createHash('sha256').update(fs.readFileSync(codex)).digest('hex'),
    codexVersion: execFileSync(codex, ['--version'], {encoding: 'utf8'}).trim(), threadId,
    note: 'Existing disposable annotated thread, no new model turn; source database untouched; fork uses native provider API.'});
  const deadline = Date.now() + 15000;
  while (true) {
    try {
      await new Promise((resolve, reject) => {
        const socket = net.connect(port, '127.0.0.1');
        socket.once('connect', () => {socket.destroy(); resolve();}); socket.once('error', reject);
      }); break;
    } catch (error) { if (Date.now() > deadline || child.exitCode !== null) throw error; await delay(50); }
  }
  ws = new WebSocket(`ws://127.0.0.1:${port}/rpc`);
  ws.addEventListener('message', ({data}) => {
    const value = JSON.parse(String(data)); const request = pending.get(value.id);
    if (request) { pending.delete(value.id); clearTimeout(request.timer); value.error ? request.reject(new Error(JSON.stringify(value.error))) : request.resolve(value.result); }
  });
  await once(ws, 'open');
  await call('provider.start', {instanceId: 'codex-app-server', name: 'Codex annotation QA', driver: 'codex-app-server',
    config: {command: [codex, '-c', 'approval_policy="on-request"', '-c', 'sandbox_mode="read-only"', 'app-server']}});
  const replayed = await prepare(threadId); save('replayed.json', replayed);
  const fork = await call('provider.forkThread', {sourceThreadId: threadId}); save('fork.json', fork);
  const forked = await prepare(fork.threadId); save('fork-replayed.json', forked);
  const original = fixture.thread ?? fixture.snapshot?.thread ?? fixture;
  const result = {original: inspect(original), replayed: inspect(replayed), forked: inspect(forked)};
  save('result.json', result); console.log(JSON.stringify(result, null, 2));
} catch (error) { save('failure.json', {error: String(error)}); throw error; }
finally {
  ws?.close(); for (const request of pending.values()) clearTimeout(request.timer);
  child.kill('SIGTERM');
  await Promise.race([exited, delay(10000, undefined, {ref: false}).then(() => { if (child.exitCode === null && child.signalCode === null) child.kill('SIGKILL'); })]);
  fs.closeSync(log); save('cleanup.json', {exitCode: child.exitCode, signalCode: child.signalCode});
}
