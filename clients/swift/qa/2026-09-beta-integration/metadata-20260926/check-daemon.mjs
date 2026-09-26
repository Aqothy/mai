import fs from 'node:fs';
import path from 'node:path';
import net from 'node:net';
import assert from 'node:assert/strict';
import {spawn, execFileSync} from 'node:child_process';
import {once} from 'node:events';
import {setTimeout as delay} from 'node:timers/promises';
import {createHash} from 'node:crypto';

const output = path.dirname(new URL(import.meta.url).pathname);
const prior = JSON.parse(fs.readFileSync(path.join(output, 'results.json')));
assert.equal(prior.passed, true);
const data = path.join(prior.work, 'daemon-data');
fs.mkdirSync(data); // refuse to reuse a previous daemon run
execFileSync('python3', ['-c', 'import sqlite3,sys; from contextlib import closing;\nwith closing(sqlite3.connect("file:"+sys.argv[1]+"?mode=ro",uri=True)) as s, closing(sqlite3.connect(sys.argv[2])) as d: s.backup(d)', path.join(prior.work, 'recovered.db'), path.join(data, 'maid.db')]);
const daemon = '/Users/aqothy/Library/Caches/maiD-QA/2026-09-24/reasoning-reload/maiD';
const server = net.createServer();
server.listen(0, '127.0.0.1');
await once(server, 'listening');
const port = server.address().port;
await new Promise(resolve => server.close(resolve));
const log = fs.openSync(path.join(output, 'daemon.log'), 'w');
const child = spawn(daemon, [], {env: {...process.env, MAID_DATA_DIR: data, MAID_ADDR: `127.0.0.1:${port}`}, stdio: ['ignore', log, log]});
const exited = once(child, 'exit');
const result = {daemon, daemonSHA256: createHash('sha256').update(fs.readFileSync(daemon)).digest('hex'), data, daemonPID: child.pid, source: prior.versions.current};
let ws, next = 0;
const pending = new Map();
function call(method, params = {}) {
    return new Promise((resolve, reject) => {
        const id = ++next;
        const timer = setTimeout(() => {pending.delete(id); reject(new Error(method + ' timed out'));}, 10000);
        pending.set(id, {resolve, reject, timer});
        ws.send(JSON.stringify({jsonrpc:'2.0', id, method, params}));
    });
}
try {
    const deadline = Date.now() + 15000;
    while (true) {
        try {
            await new Promise((resolve, reject) => {
                const socket = net.connect(port, '127.0.0.1');
                socket.once('connect', () => {socket.destroy(); resolve();});
                socket.once('error', reject);
            });
            break;
        } catch (error) {
            if (Date.now() > deadline || child.exitCode !== null) throw error;
            await delay(50);
        }
    }
    ws = new WebSocket(`ws://127.0.0.1:${port}/rpc`);
    await once(ws, 'open');
    ws.addEventListener('message', ({data}) => {
        const message = JSON.parse(String(data));
        const request = pending.get(message.id);
        if (!request) return;
        pending.delete(message.id);
        clearTimeout(request.timer);
        message.error ? request.reject(new Error(JSON.stringify(message.error))) : request.resolve(message.result);
    });
    const {snapshot} = await call('orchestration.subscribeThread', {threadId:'qa-thread-café-👩🏽‍💻'});
    const thread = snapshot.thread;
    assert.equal(thread.title, 'Original café 👩🏽‍💻');
    assert.equal(thread.providerInstanceId, 'qa-provider');
    assert.equal(thread.modelSelection.model, 'qa-model');
    assert.deepEqual(thread.additionalDirectories, ['/disposable/extra α','/disposable/extra β']);
    assert.equal((thread.timeline ?? []).length, 0); // provider history is intentionally not fabricated
    const terminalList = await call('terminal.subscribeList');
    assert.equal(terminalList.terminals.length, 1);
    const terminal = terminalList.terminals[0];
    assert.equal(terminal.terminalId, 'qa-terminal');
    assert.equal(terminal.title, 'Terminal 保持');
    assert.equal(terminal.status, 'stopped');
    const providers = await call('provider.list');
    assert.equal(providers.some(provider => provider.pid > 0), false);
    result.thread = thread;
    result.terminal = terminal;
    result.checks = ['exact sidebar metadata and extra directories restored', 'terminal metadata restored without relaunch', 'provider processes remain stopped', 'history remains provider-owned'];
    result.passed = true;
} catch (error) {
    result.failure = String(error);
    throw error;
} finally {
    ws?.close();
    for (const request of pending.values()) clearTimeout(request.timer);
    child.kill('SIGTERM');
    await Promise.race([exited, delay(10000, undefined, {ref:false}).then(() => {
        if (child.exitCode === null && child.signalCode === null) child.kill('SIGKILL');
    })]);
    fs.closeSync(log);
    result.daemonExited = child.exitCode !== null || child.signalCode !== null;
    fs.writeFileSync(path.join(output, 'daemon-result.json'), JSON.stringify(result,null,2)+'\n');
}
