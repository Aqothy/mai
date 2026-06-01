const actions = {
  init: 'agent-init',
  auth: 'agent-authenticate',
  logout: 'agent-logout',
  new: 'session-new',
  list: 'session-list',
  load: 'session-load',
  resume: 'session-resume',
  close: 'session-close',
};

const els = {
  socketPath: document.getElementById('socketPath'),
  current: document.getElementById('current'),
  agentName: document.getElementById('agentName'),
  agentCommand: document.getElementById('agentCommand'),
  authMethod: document.getElementById('authMethod'),
  cwd: document.getElementById('cwd'),
  sessionID: document.getElementById('sessionID'),
  mcpServers: document.getElementById('mcpServers'),
  sessions: document.getElementById('sessions'),
  status: document.getElementById('status'),
  output: document.getElementById('output'),
};

bindButtons();
loadContext();
restoreState();
updateCurrent();

function bindButtons() {
  document.getElementById('agentInit').addEventListener('click', agentInit);
  document.getElementById('auth').addEventListener('click', auth);
  document.getElementById('logout').addEventListener('click', logout);
  document.getElementById('sessionNew').addEventListener('click', sessionNew);
  document.getElementById('sessionList').addEventListener('click', sessionList);
  document.getElementById('sessionLoad').addEventListener('click', sessionLoad);
  document.getElementById('sessionResume').addEventListener('click', sessionResume);
  document.getElementById('sessionClose').addEventListener('click', sessionClose);
}

async function loadContext() {
  try {
    const res = await fetch('/api/context');
    const context = await res.json();
    els.socketPath.textContent = `Local web UI · socket ${context.socketPath}`;
    if (!els.cwd.value) {
      els.cwd.value = context.cwd || '';
    }
    remember();
  } catch (err) {
    setStatus(`Failed to load context: ${err}`, true);
  }
}

function restoreState() {
  els.agentName.value = localStorage.agentName || 'codex';
  els.agentCommand.value = localStorage.agentCommand || '';
  els.authMethod.value = localStorage.authMethod || '';
  els.cwd.value = localStorage.cwd || '';
  els.sessionID.value = localStorage.sessionID || '';
  els.mcpServers.value = localStorage.mcpServers || '';
}

function remember() {
  localStorage.agentName = value(els.agentName);
  localStorage.agentCommand = value(els.agentCommand);
  localStorage.authMethod = value(els.authMethod);
  localStorage.cwd = value(els.cwd);
  localStorage.sessionID = value(els.sessionID);
  localStorage.mcpServers = els.mcpServers.value.trim();
  updateCurrent();
}

function updateCurrent() {
  const agent = value(els.agentName) || 'no agent';
  const session = value(els.sessionID);
  els.current.textContent = session ? `${agent} · ${session}` : `${agent} · no current session`;
}

async function agentInit() {
  const command = splitCommand(value(els.agentCommand));
  if (!command.length) {
    show({ ok: false, message: 'Agent command is required' });
    return;
  }
  await call(actions.init, { name: value(els.agentName), kind: 'acp', command });
}

async function auth() {
  await call(actions.auth, { name: value(els.agentName), methodId: value(els.authMethod) });
}

async function logout() {
  await call(actions.logout, { name: value(els.agentName) });
}

async function sessionNew() {
  const params = withSessionOptions({ name: value(els.agentName), cwd: value(els.cwd) });
  const resp = await call(actions.new, params);
  if (resp.ok && resp.data?.id) {
    els.sessionID.value = resp.data.id;
    remember();
  }
}

async function sessionList() {
  const params = { name: value(els.agentName) };
  if (value(els.cwd)) {
    params.cwd = value(els.cwd);
  }
  const resp = await call(actions.list, params);
  if (resp.ok) {
    renderSessions(resp.data?.threads || []);
  }
}

async function sessionLoad() {
  await call(actions.load, withSessionOptions({
    name: value(els.agentName),
    sessionId: value(els.sessionID),
    cwd: value(els.cwd),
  }));
}

async function sessionResume() {
  await call(actions.resume, withSessionOptions({
    name: value(els.agentName),
    sessionId: value(els.sessionID),
    cwd: value(els.cwd),
  }));
}

async function sessionClose() {
  await call(actions.close, { name: value(els.agentName), sessionId: value(els.sessionID) });
}

function withSessionOptions(params) {
  const raw = els.mcpServers.value.trim();
  if (!raw) {
    return params;
  }
  params.options = { mcpServers: JSON.parse(raw) };
  return params;
}

async function call(action, params) {
  remember();
  setBusy(true);
  setStatus(`Sending ${action}...`, false);

  try {
    const res = await fetch('/api', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ action, params }),
    });
    const body = await res.json();
    show(body);
    return body;
  } catch (err) {
    const body = { ok: false, message: String(err) };
    show(body);
    return body;
  } finally {
    setBusy(false);
  }
}

function renderSessions(threads) {
  if (!threads.length) {
    els.sessions.innerHTML = '<small>No sessions returned.</small>';
    return;
  }

  const rows = threads.map((thread) => `
    <tr data-session-id="${escapeAttr(thread.id)}">
      <td>${escapeHTML(thread.id)}</td>
      <td>${escapeHTML(thread.title || '')}</td>
      <td>${escapeHTML(thread.cwd || '')}</td>
      <td>${escapeHTML(thread.updatedAt || '')}</td>
    </tr>
  `).join('');

  els.sessions.innerHTML = `
    <table>
      <thead><tr><th>ID</th><th>Title</th><th>CWD</th><th>Updated</th></tr></thead>
      <tbody>${rows}</tbody>
    </table>
  `;

  els.sessions.querySelectorAll('tr[data-session-id]').forEach((row) => {
    row.addEventListener('click', () => {
      els.sessionID.value = row.dataset.sessionId;
      remember();
    });
  });
}

function show(resp) {
  setStatus(resp.message || (resp.ok ? 'ok' : 'error'), !resp.ok);
  els.output.textContent = JSON.stringify(resp, null, 2);
}

function setStatus(message, isErr) {
  els.status.textContent = message;
  els.status.className = `status ${isErr ? 'err' : 'ok'}`;
}

function setBusy(busy) {
  document.querySelectorAll('button').forEach((button) => {
    button.disabled = busy;
  });
}

function value(input) {
  return input.value.trim();
}

function splitCommand(command) {
  return command.match(/(?:[^\s"]+|"[^"]*")+/g)?.map((part) => part.replace(/^"|"$/g, '')) || [];
}

function escapeHTML(value) {
  return String(value).replace(/[&<>"']/g, (char) => ({
    '&': '&amp;',
    '<': '&lt;',
    '>': '&gt;',
    '"': '&quot;',
    "'": '&#39;',
  }[char]));
}

function escapeAttr(value) {
  return escapeHTML(value).replace(/`/g, '&#96;');
}
