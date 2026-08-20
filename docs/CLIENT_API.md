# maiD Client API

> **Status: UNSTABLE (pre-1.0).** Method names, payload shapes, and semantics may
> change without notice until v1.0. Thread/sidebar metadata and provider session
> routes persist, while conversation history remains provider-owned and is loaded
> on reopen when supported. Live events are sequenced but not retained, and a
> daemon restart resets the global `sequence` counter. Every replacement connection obtains fresh
> authoritative snapshots; clients never merge a prior connection's watermark into
> the new connection. The daemon binds to loopback by default and has
> **no client authentication**; it is single-user and intended for local or otherwise
> trusted transport.

Every JSON example in this document was captured verbatim from a live daemon
(driven end-to-end through a stub ACP agent) and only trimmed where marked with
`…`. To regenerate the full transcript:

```
MAID_CAPTURE_EXAMPLES=/tmp/client-api-transcript.md \
  go test -run TestCaptureClientAPIExamples ./internal/daemon
```

---

## 1. Transport

- **Endpoint:** `ws://127.0.0.1:8765/rpc` by default (HTTP GET upgrade); set
  `MAID_ADDR` to override the listen address. JSON-RPC 2.0, one JSON message per
  WebSocket **text** frame. Non-loopback binding is trusted-network only: the
  daemon has no client authentication or TLS.
- **Client → server:** JSON-RPC requests (`id` + `method` + `params`).
  `orchestration.dispatchCommand` must be a call (with `id`), not a notification.
- **Server → client:** responses to your calls, plus **notifications** that carry
  the live streams. Notifications reuse the subscription method name:
  - `orchestration.subscribeThread` — params is a _thread stream item_ (§5)
  - `orchestration.subscribeThreadList` — params is a _thread-list stream item_ (§6)
- One connection can hold many thread subscriptions plus the thread-list
  subscription. Subscriptions live for the connection; there is no
  `unsubscribeThreadList`.
- **Frame sizes:** raise your WebSocket library's _read_ limit (many default to
  32KiB — coder/websocket does): a snapshot of a long thread can be megabytes. The daemon accepts inbound frames up to 32MiB (a
  `thread.turn.start` with image/audio attachments is the big case).

## 2. Identity and idempotency

Three client-relevant identifiers:

| Id                  | Minted by             | Rule                                                                                                                                                                                                                               |
| ------------------- | --------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `threadId`          | **client**            | Generate a UUID and send it in `thread.start` for a new chat (or `thread.create` for an intentionally empty real thread). It is the only conversation id you ever use. |
| `commandId`         | **client**            | Generate a UUID per dispatched command. During one daemon run, retrying the same command with the same `commandId` returns the original result and applies nothing twice. Receipts do not survive daemon restart. |
| `message.messageId` | **client** (optional) | UUID for the user message in `thread.turn.start`; the server mints one if absent.                                                                                                                                                  |

Clients that retry a timed-out command SHOULD supply their own `commandId` (the
daemon mints one when absent) so the retry dedupes against the recorded
receipt during that daemon run; a retry without one is a new command and
duplicates the effect.

Everything else (`turnId`, `eventId`, assistant `messageId`, approval
`requestId`) is server- or provider-minted and arrives on events; treat all of
them as opaque strings. Provider-native session ids are server-internal — clients
never see or send them (the only exception is the import-oriented
`provider.listSessions` / `importSession` / `deleteSession` / `closeSession`
surface, §4).

Captured idempotent retry — the second `thread.create` with the same
`commandId` returns the original receipt (`sequence: 1`) instead of failing on
the existing thread:

```json
--> {"id": 4, "method": "orchestration.dispatchCommand",
     "params": {"type": "thread.create",
                "commandId": "5f0c9a3e-8f1d-4f6a-b2e7-9c8d7a6b5e40",
                "threadId": "1b2f8a54-6c1e-4d2a-9f3b-7c5d0e8a4f21",
                "title": "Fix the flaky login test",
                "providerInstanceId": "claude-code",
                "cwd": "/tmp/maid-demo"}}
<-- {"id": 4, "result": {"sequence": 1}}

--> {"id": 5, "method": "orchestration.dispatchCommand", "params": { ...same... }}
<-- {"id": 5, "result": {"sequence": 1}}
```

## 3. Orchestration RPC

### 3.1 `orchestration.dispatchCommand`

Params: a command envelope. Result: `{"sequence": <uint64>}` — the global
sequence of the event the command appended (your own subscription will also
receive that event; dedupe by `sequence`).

These are the only command `type`s — anything else is rejected as an
unsupported command. Server/provider events (items, session status, streamed
messages, …) are not commands at all; they reach you only as events (§7):

| `type`                        | Fields (besides `commandId`, `threadId`)                                                    | Effect                                                                                                                                                                                                                                                                                                                                                                         |
| ----------------------------- | ------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `thread.create`               | `title?`, `providerInstanceId`, `modelSelection {model?, options?}`?, `cwd?` | Creates an ordinary empty thread. New-chat clients normally use `thread.start` instead. `cwd` must be an absolute existing directory; empty defaults to the daemon's cwd. Idempotent per `threadId`. |
| `thread.start`                | `providerInstanceId`, `cwd`, `message`, `configSelections?`, `title?` | Creates the real thread, records its first user message and config selections, and requests the first turn in one command. It is idempotent during the daemon run. This is the client-local draft Send path; no prior `thread.create` or session preparation is required. |
| `thread.meta.update`          | `title?`, `providerInstanceId?`, `modelSelection?`, `cwd?` | Updates thread metadata. Empty `cwd` means unchanged. Provider/model changes are rejected while a turn is active; cwd changes are rejected while a provider session is bound. |
| `thread.turn.start`           | `message {messageId?, text, attachments?}`, `title?` | Starts a subsequent turn (or **steers** the running one — see below). The thread must already exist, and a restored/imported thread must complete `thread.session.prepare` first so its history precedes the new message. `text` may be empty only if `attachments` is non-empty. Attachment: `{kind: "text"\|"image"\|"audio"\|"resource"\|"resource_link", name?, mimeType?, data?, uri?}`; image/audio/resource are gated by `capabilities.promptContent` (`resource` uses `embeddedContext`). |
| `thread.turn.retry`           | — | Retries the latest failed turn with its existing user message. It creates a new turn request without appending a duplicate message. |
| `thread.turn.interrupt`       | —                                                                                           | Interrupts the running turn; it settles as `interrupted`.                                                                                                                                                                                                                                                                                                                      |
| `thread.approval.respond`     | `requestId`, `decision: "accept"\|"acceptForSession"\|"decline"\|"cancel"`, `optionId?`     | Answers a pending approval (`requestId` from the `thread.approval-opened` event).                                                                                                                                                                                                                                                                                              |
| `thread.session.prepare`      | —                                                                                           | Materializes a restored/imported real thread's provider session and rebuilds provider-owned history. Safe to retry. It is not part of new-chat draft composition.                                                                                                  |
| `thread.session.stop`         | —                                                                                           | Stops/unbinds the provider session; the thread survives and the next turn starts a fresh session.                                                                                                                                                                                                                                                                              |
| `thread.config-option.set`    | `optionId`, `value`                                                                         | Sets any provider-owned session option, including model, reasoning level, access, or behavior modes. Use ids/values from `session.configOptions`; maiD does not impose universal mode values. Emits a fresh `thread.config-options-updated`.                                                                                                                                                                                                                      |

**Steering:** dispatching `thread.turn.start` while a turn is running does not
error — the message is injected into the running turn (the daemon performs a
cancel-and-resend handoff with the agent; the maiD turn stays `running`
throughout). If the running turn settles before the provider receives the steer,
the daemon re-delivers the accepted message on a fresh, server-initiated turn;
accepted messages are never silently dropped. Live-event clients must fold that
server-authored `thread.turn-start-requested` by moving its existing `messageId`
onto the event's new `turnId`, as well as replacing `latestTurn`. Otherwise their
local state will diverge from the next server snapshot.

### 3.2 `orchestration.subscribeThread`

Params `{"threadId": ...}`. The daemon registers the live stream first and
then returns an authoritative snapshot:

```json
<-- {"id": 6, "result": {
      "kind": "snapshot",
      "snapshot": {
        "snapshotSequence": 1,
        "thread": {
          "id": "1b2f8a54-6c1e-4d2a-9f3b-7c5d0e8a4f21",
          "title": "Fix the flaky login test",
          "providerInstanceId": "claude-code",
          "cwd": "/tmp/maid-demo",
          "timeline": [],
          "createdAt": "2026-07-01T23:39:09.007196-04:00",
          "updatedAt": "2026-07-01T23:39:09.007196-04:00"
        }}}}
```

Unknown `threadId` returns an error and removes the just-created subscription.
Subsequent events arrive as notifications:

```json
<-- {"method": "orchestration.subscribeThread",
     "params": {"kind": "event", "event": { ...Event, see §7... }}}
```

### 3.3 `orchestration.unsubscribeThread`

Params `{"threadId": ...}`, result `null`. Stops that thread's live stream
when the client cache policy evicts it, without touching the connection, its
other thread subscriptions, or the cached/server thread state.

### 3.4 `orchestration.subscribeThreadList`

No params. Returns the sidebar snapshot and subscribes to sidebar updates:

```json
<-- {"id": 3, "result": {"kind": "snapshot",
      "snapshot": {"snapshotSequence": 0, "threads": [], "updatedAt": "…"}}}
```

Live updates are whole-item upserts keyed by `thread.id` (replace, don't merge):

```json
<-- {"method": "orchestration.subscribeThreadList",
     "params": {"kind": "thread-upserted", "sequence": 1,
                "thread": { ...ThreadListEntry, see §6... }}}
```

New-chat drafts are client-local and therefore never appear in this stream.

High-frequency events (coalesced assistant/reasoning chunks, tool-call item
updates, plan updates) deliberately do **not** repaint the thread list; expect
thread-list updates on lifecycle changes (create, turn start/settle, session
status, approvals opening, title changes).

### 3.5 `orchestration.getItemDetail`

Params `{"threadId": ..., "itemId": ...}`. Returns the complete current `Item`
from the daemon's materialized thread projection. It does not scan or replay
events. Unknown thread/item IDs return an error.

Thread snapshots and live item events carry compact tool summaries; call this
method only when the user expands a tool. Cache the result by
`threadId + itemId + sequence`, and request it again after the item's
`sequence` changes.

## 4. Provider RPC

Provider management is instance-scoped, not thread-scoped. `instanceId` is a
client-chosen stable name for a configured agent runtime (e.g. `"claude-code"`).

### 4.1 `provider.start`

Params `{"instanceId", "name"?, "driver": "acp", "config": {"command": ["npx", "@zed-industries/claude-code-acp"]}, "restart"?: bool}`.
`config` is an opaque driver-owned envelope; for ACP, `config.command` is the
executable followed by its arguments. The adapter spawns that process over
stdio, runs `initialize`, and returns the instance descriptor. Starting the same
`instanceId` again with semantically equal configuration returns the existing
live instance; `restart: true` replaces the process — running turns owned by the
replaced process settle as errors, and the next prompt on each thread resumes
the provider session via the stored resume cursor (context is retained when the
agent supports load/resume).

```json
<-- {"id": 1, "result": {
      "instanceId": "claude-code",
      "name": "Claude Code", "driver": "acp",
      "pid": 48318, "status": "initialized",
      "startedAt": "…", "initializedAt": "…",
      "auth": {"status": "unknown",
               "methods": [{"id": "agent-login", "name": "Agent login"}]},
      "capabilities": {"loadReplay": true, "resume": true,
                       "auth": true, "logout": true,
                       "modelSwitch": "in-session",
                       "configOptions": true,
                       "promptContent": {}, "mcp": {}}}}
```

Gate UI on `capabilities`: `promptContent.image/audio` before offering
attachments, `loadReplay` when deciding whether stored history can be rebuilt,
`resume` when deciding whether agent context can continue without replay, and
`configOptions` before loading pre-send settings, and `auth`/`logout` for the
auth menu. **Auth status is `"unknown"` whenever the
agent advertises methods** (ACP
has no auth probe — agents advertise their login method even when already
logged in). Render `auth.methods` as available actions and open the auth flow
when an operation fails with an auth-required error — never off this status.

### 4.2 `provider.list`

`provider.list` takes no params and returns every provider process known to this
daemon run. `provider.start` normally accepts a full instance spec, but
`{"instanceId"}` alone starts that instance from its persisted internal spec.
This process start is unrelated to ACP session resume.

### 4.2.1 ACP registry

`acp.registry.list` takes no params and returns the registry's supported
`npx` agents. The daemon caches the registry index under `MAID_DATA_DIR` and
falls back to that cache when offline. Binary and `uvx` distributions are not
included in this MVP.

`acp.registry.start` takes `{"registryId", "restart"?: bool}`. It launches
the registry's exact-version npm package through `npm exec`, using maiD-owned
persistent prefix and cache directories. The resulting stable instance ID is
`registry-<registryId>`. Registry environment variables are passed to the ACP
process. No global npm installation is performed.

`acp.registry.addCustom` takes `{"name", "command", "args"?, "env"?}`. As in
Zed, the required agent name is its user-chosen stable definition ID. Custom and
registry definitions share one namespace; exact ID collisions are rejected by
both the client and daemon, while duplicate display names are allowed.
maiD separately namespaces the hidden runtime instance ID as `custom-<name>`.
The daemon records the launch
definition in `agents/installed.json`, alongside registry installations. Custom
and registry agents start lazily through `acp.registry.start`.

Agent launch definitions are canonical only in the private JSON manifest.
SQLite keeps a config-free instance reference where thread-route foreign keys
require one; commands, arguments, and environment values are not duplicated in
the database.

### 4.2.2 Provider options for client-local drafts

New-chat drafts stay entirely on the client. Providers that advertise
`capabilities.configOptions` expose their pre-send option catalog through:

- `provider.options.get {"providerInstanceId", "cwd"}` →
  `{"optionsSessionId", "configOptions"}`;
- `provider.options.set {"optionsSessionId", "optionId", "value"}` → the refreshed
  option result;
- `provider.options.updated` notifications for spontaneous catalog changes;
- `provider.options.invalidated {"optionsSessionId"}` when the helper session dies.

For ACP, the daemon keeps at most one disposable options session per provider
instance per WebSocket connection. Reusing the same provider and cwd is warm;
changing cwd replaces that provider's helper session. The opaque `optionsSessionId`
lets clients ignore late updates from replaced sessions. These helpers are not
threads and are never promoted. Native providers may implement the same API
without opening any session.

Sending a local draft is one `thread.start` command through
`orchestration.dispatchCommand`.

### 4.3 `provider.authenticate` / `provider.logout`

- `provider.authenticate` params `{"instanceId", "methodId"}` — `methodId` must
  be one of `auth.methods[].id`; unknown methods are rejected without calling
  the agent. Result: the refreshed connection (`auth.status: "authenticated"`).
- `provider.logout` params `{"instanceId"}` — capability-gated. Result: the
  refreshed connection (`auth.status: "unauthenticated"`).

### 4.4 `provider.listSessions` / `provider.importSession` / session maintenance

Explicit import and maintenance tooling over the agent's own session store —
**not** an auto-synced sidebar (that is `orchestration.subscribeThreadList`).
Listing and maintenance are capability-gated by what the agent advertises;
unsupported operations fail fast:

```json
--> {"id": 16, "method": "provider.listSessions", "params": {"instanceId": "claude-code"}}
<-- {"id": 16, "result": [{"sessionId": "sess_new", "title": "Test session",
                           "cwd": "/tmp/maid-demo"}]}

--> {"id": 17, "method": "provider.importSession",
     "params": {"instanceId": "claude-code", "session":
       {"sessionId": "sess_new", "title": "Test session", "cwd": "/tmp/maid-demo"}}}
<-- {"id": 17, "result": {"threadId": "thread_…", "imported": true}}

--> {"id": 18, "method": "provider.deleteSession",
     "params": {"instanceId": "claude-code", "sessionId": "sess_new"}}
<-- {"id": 18, "error": {"code": -32001,
       "message": "ACP agent does not advertise session/delete support"}}
```

`listSessions` accepts an optional `cwd` filter and aggregates all provider
pages. Call `importSession` only for a summary explicitly selected by the user.
It mints a maiD-owned thread ID, stores the provider session route, and returns
that ID; repeating the same `(instanceId, sessionId)` returns the existing ID
with `imported: false`. Subscribe to that thread and dispatch
`thread.session.prepare` to load provider-owned history. Import requires metadata
persistence. `deleteSession`/`closeSession` return `null` on success and reject
a session currently bound to an orchestration thread; stop/unbind that thread
first.

## 5. The sync contract

The server is authoritative; clients are thin replicas that can always resync.

1. **Subscribe first, then apply the snapshot.** The subscription is registered
   before the snapshot is built, so you cannot miss events — but you may receive
   events that are _already inside_ the snapshot.
2. **Dedupe rule:** ignore any notification whose `event.sequence` (thread
   stream) or `sequence` (thread-list stream) is `<= snapshotSequence`.
3. `sequence` is **global and strictly increasing across all threads**, so a
   single thread's stream has gaps — that is normal. Order and dedupe by
   `sequence`; never expect contiguity.
4. **Reconnect recipe** (after any disconnect):
   - reopen the WebSocket and subscribe to the thread list normally;
   - keep cached content visible and call `subscribeThread` with its thread ID;
   - buffer live detail notifications until the response arrives;
   - atomically replace the cached projection with the snapshot, then reduce
     buffered events newer than its `snapshotSequence`.
5. **Overflow-close:** each connection has a bounded outbound queue (1024
   notifications). A client that reads too slowly gets its connection closed by
   the server. Recovery is the reconnect recipe; nothing is lost because the
   a replacement connection obtains a fresh authoritative snapshot.
6. Multiple clients are symmetric: commands from any client fan out to all
   subscribers (including the sender — apply your own edits from the event
   stream, not optimistically, or dedupe by `commandId`).

### Applying streamed text (the two append rules)

**Assistant messages stream as coalesced chunks**: the daemon buffers the
provider's per-token chunks and flushes `thread.message-sent` events sharing
one `messageId` — the first chunk immediately, later ones at most every few
tens of milliseconds, and the remainder when the message settles (the provider
item completes, a tool call or reasoning interleaves, or the turn ends). Each
event's `text` is a **delta — append it** to the message with that id (create
the message on first sight):

```json
{"sequence": 10, "type": "thread.message-sent",
 "payload": {"messageId": "assistant:turn_342f…", "role": "assistant",
             "text": "hi — a few dozen tokens per flush", "turnId": "turn_342f…", …}}
```

There is no per-message completion marker; show a busy indicator off
`latestTurn.state == "running"`, not off message traffic. User messages arrive
the same way (from your own `thread.turn.start`, from other clients, or
replayed session history) with `role: "user"` and the full text in one event.

**Items** (`thread.item-upserted`) are keyed by `item.id`. Non-empty scalar
fields (`kind`, `title`, `status`, `turnId`) patch your cached item. Tool kinds
carry `toolCallSummary` plus `detailAvailable`; a present summary replaces the
cached summary and an absent one keeps it. Complete `toolCall` values are
returned only by `orchestration.getItemDetail`. The non-tool `payload` has
exactly two rules:

- `item.textDelta` set (coalesced reasoning chunk): append it to the cached
  payload's `"text"`. Settle events carry the full `{"text", "attachments"}`
  payload as a checkpoint, so a client that missed chunks self-heals.
- otherwise: a non-empty `item.payload` **replaces** the cached payload
  entirely (the server always sends the complete payload), and an absent one
  keeps it. Never merge payload JSON key-wise.

## 6. Thread model (what a UI renders)

The thread snapshot (§3.2) and thread-list entry share these building blocks:

- **`timeline[]`** is the canonical conversation order. Each entry is a tagged
  union with exactly one matching payload:
  - `{kind: "message", message: {id, role: user|assistant, text, attachments?, turnId?, createdAt, updatedAt}}`
  - `{kind: "item", item: {id, kind, title?, status, detailAvailable?, toolCallSummary?, payload?, sequence?, turnId?, createdAt, updatedAt}}`
  - `{kind: "approval", approval: {requestId, turnId?, args?, options[], status: pending|resolved, decision?, optionId?, createdAt, updatedAt}}`
- Item kinds are `reasoning`, `command_execution`, `file_change`,
  `mcp_tool_call`, `tool_call`, `warning`, and `error`; statuses are
  `in_progress`, `completed`, `failed`, `interrupted`, and `declined`.
- Tool items carry a bounded provider-neutral `toolCallSummary`. It includes
  action/name/namespace/provider kind, bounded command/query/output/error
  previews, bounded location/change/attachment metadata, total counts, exit
  code, duration, and a truncation marker. File-change summaries omit
  diff/oldText/newText; attachment summaries omit inline data. The full
  provider-neutral `toolCall` is available through §3.5.
- Image message attachments in snapshots and live events preserve inline
  `data` with their presentation fields (`kind`, `name`, `mimeType`, and
  `uri`) so clients can render provider-replayed and newly received images.
  Other attachment kinds carry presentation metadata only unless their UI gains
  an explicit rendering or detail-fetch contract.
- Approval options are provider-supplied `{id, name, kind}` values such as
  `allow_once`, `allow_always`, `reject_once`, and `reject_always`.

Render `timeline` in array order. New entities append; message chunks and
item/approval lifecycle events update the matching entry by ID without moving
it. Consecutive reasoning or assistant chunks update their active entry. A
newly started tool or a switch between reasoning and assistant text settles
the active content streams server-side, so content that resumes afterward
appends a new segment in the correct position.
Plans and contextual session state update outside the timeline. Timestamps are
metadata, never ordering keys.
- **`plan`** `{entries: [{content, priority?: high|medium|low, status?: pending|in_progress|completed}], updatedAt}` —
  fully replaced on every `thread.plan-updated`.
- **`latestTurn`** `{turnId, state: running|completed|interrupted|error, requestedAt, startedAt?, completedAt?, stopReason?, error?, interruptRequested?}`.
- **`session`** — once a real thread has a bound provider session:
  `{threadId, providerInstanceId, providerName?, provider?, cwd?,
status, activeTurnId?, stopRequested?, configOptions?, slashCommands?, tokenUsage?,
lastError?, updatedAt}`.
  - `status`: `starting`, `running` (turn active), `ready` (idle),
    `interrupted`, `stopped`, `error` (see `lastError`).
  - `configOptions[]` `{id, type: select|boolean, category?: mode|model|model_config|thought_level|other, label?, description?, choices?: [{value, label?}], currentValue?}` —
    `type` is the rendering discriminator: `select` options carry `choices` and a
    string `currentValue` (render a selector), `boolean` options carry a JSON
    boolean `currentValue` (render a toggle). Set via `thread.config-option.set`
    with a `value` of the matching JSON type — a string for selects, `true`/`false`
    for booleans; mismatched types are rejected at dispatch. Agents that only
    have legacy ACP "modes" get one synthesized `select` with `id: "acp.session-mode"`.
  - `slashCommands[]` `{name, description?, hasInput?}` — typed into the prompt
    as plain text (send `"/compact …"` in `message.text`).
  - `tokenUsage` `{usedTokens, maxTokens?, cost?, currency?}`.
- **ThreadListEntry** (sidebar item) = the above minus messages/items/approvals
  bodies, plus the derived `hasPendingApprovals` flag. `updatedAt` is the
  sidebar recency timestamp: the latest user-message time, falling back to
  `createdAt` before the first user message.

## 7. Event reference

Common event envelope (thread stream notifications):

```json
{"sequence": 20, "eventId": "evt_…", "type": "thread.approval-opened",
 "occurredAt": "…", "commandId": "…", "actor": "client|server|provider",
 "metadata": {…}, "payload": {…}}
```

`payload.threadId` names the thread. `commandId` is present only on events a
client command produced (dedupe your own optimistic edits with it); events
from provider/server events omit it. `metadata` carries only `requestId` (set
on approval-response events). Ignore unknown event types and unknown payload
fields — new ones will appear pre-1.0.

| `type`                                  | Emitted when                                                           | Payload keys to apply                                                                                                                                                                                                                                                                                            |
| --------------------------------------- | ---------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `thread.created`                        | `thread.create` or the create portion of `thread.start`                | `title`, `providerInstanceId`, `modelSelection`, `cwd`                                                                                                                                                                                                                         |
| `thread.imported`                       | explicit `provider.importSession`                                      | create a real thread with `title`, `providerInstanceId`, `cwd`, `createdAt`, and `updatedAt`; its timeline starts empty and is rebuilt by `thread.session.prepare` |
| `thread.meta-updated`                   | `thread.meta.update`, or the **agent set a title**                     | non-empty scalar fields patch the thread (`title`, `cwd`, …). **Selection is a replacement aggregate**: when `providerInstanceId` is present it is the complete new selection — set it AND replace `modelSelection` with the event's value (absent = cleared, e.g. after a provider-only switch); a `modelSelection` without `providerInstanceId` replaces just the model choice. `sessionCleared: true` means clear the current `session` because a provider switch made it stale |
| `thread.message-sent`                   | user message recorded / coalesced assistant chunk                      | `messageId`, `role`, `text` (append!), `attachments?`, `turnId`; a new message appends to `timeline`; later chunks update it by `messageId` without moving it                                                                                                                                                                              |
| `thread.turn-start-requested`           | turn accepted                                                          | `turnId`, `messageId` — set `latestTurn = {state: "running"}` and apply `title` when present; also apply the selection aggregate (same rule as `meta-updated`) and `sessionCleared` when present. If a later server-authored start repeats an existing `messageId`, move that message to the new `turnId`; this is the completion-race steering fallback and is also used by failed-turn Retry.                                                        |
| `thread.turn-interrupt-requested`       | interrupt accepted                                                     | intent only; set `latestTurn.interruptRequested = true`; the settle arrives via `session-status-set` or `turn-interrupt-confirmed`                                                                                                                                                                              |
| `thread.turn-interrupt-confirmed`       | an interrupt prevented provider dispatch                               | `turnId` — settle the matching turn as interrupted without changing provider session state                                                                                                                                                                                                                       |
| `thread.turn-interrupt-failed`          | provider rejected the interrupt                                        | `turnId` — clear `latestTurn.interruptRequested`; an error item carries the reason                                                                                                                                                                                                                                |
| `thread.session-prepare-requested`      | pre-turn session preparation accepted (`thread.session.prepare`)       | intent only; set `session.status = "starting"`, clear `session.lastError`/`activeTurnId`, and set `session.updatedAt`. When no `session` exists, scaffold it from thread state (`{threadId, providerInstanceId, cwd?}`) so replay matches server snapshots. The prepared binding arrives via `session-status-set` (status `ready`), a failure via status `error` + `lastError` |
| `thread.session-stop-requested`         | stop accepted                                                          | intent only; set `session.stopRequested = true` and wait for `session-status-set`                                                                                                                                                                                                                                |
| `thread.session-stop-failed`            | provider rejected the stop                                             | clear `session.stopRequested`; an error item carries the reason                                                                                                                                                                                                                                                   |
| `thread.config-option-set-requested`    | config option change accepted                                          | intent only (`optionId`, `value`); wait for `config-options-updated`                                                                                                                                                                                                                                             |
| `thread.approval-response-requested`    | approval answer accepted                                               | intent only; wait for `approval-resolved`                                                                                                                                                                                                                                                                        |
| `thread.session-status-set`             | session bound / turn started / turn settled / provider error           | `session` (binding, §6) — **replace entirely**: the payload is the complete new binding (the server derives it from full thread state), so fields absent from it are cleared, not kept. Also settles `latestTurn`: `running`→turn running, `ready`→turn completed, `interrupted`/`stopped`→turn interrupted, `error`→turn errored (+ `session.lastError`); a settle event may carry a top-level `stopReason` (`end_turn`, `max_tokens`, `refusal`, ...) — copy it to `latestTurn.stopReason` |
| `thread.history-replay-completed`       | restored history has fully passed through ingestion                    | ordering marker only; no client projection fields change |
| `thread.item-upserted`                  | tool call / reasoning / warning / error item progress                  | `item` — upsert by `item.id`: non-empty scalar fields patch; a new item appends to `timeline`; later upserts update it by ID without moving it; `item.textDelta` appends to the payload's `text`, otherwise a non-empty `payload` replaces it (§5)                                                                                    |
| `thread.plan-updated`                   | agent plan update                                                      | `plan` — replace entirely                                                                                                                                                                                                                                                                                        |
| `thread.approval-opened`                | agent asked permission                                                 | `approval {requestId, requestType, detail?, args?, options[], turnId}` — append a pending approval; if the `requestId` already exists (an agent retried a declined tool call with the same tool-call id), reset that entry to pending without moving it |
| `thread.approval-resolved`              | approval answered by the user or cancelled                             | `approval {requestId, decision, optionId?, cancelled?}` — resolve it                                                                                                                                                                                                                                             |
| `thread.config-options-updated`         | session options published/changed                                      | `configOptions` (full replace; `[]` clears); `modelSelection` when a model option reports the current model                                                                                                                                                                                                      |
| `thread.slash-commands-updated`         | agent published its commands                                           | `slashCommands` (full replace; `[]` clears)                                                                                                                                                                                                                                                                      |
| `thread.token-usage-updated`            | usage/cost update                                                      | `tokenUsage`                                                                                                                                                                                                                                                                                                     |

Captured approval round-trip (trimmed):

```json
<-- {"method": "orchestration.subscribeThread", "params": {"kind": "event", "event": {
      "sequence": 20, "type": "thread.approval-opened", "actor": "provider",
      "payload": {"threadId": "9d4c2e71-…", "approval": {
        "requestId": "permission:9d4c2e71-…:acp-session-af9f40ba-…:tool_1",
        "requestType": "dynamic_tool_call", "detail": "Edit file",
        "args": {"title": "Edit file", "toolCallId": "tool_1"},
        "options": [
          {"optionId": "allow",  "name": "Allow",  "kind": "allow_once"},
          {"optionId": "reject", "name": "Reject", "kind": "reject_once"}],
        "turnId": "turn_847c0a74-…"}}}}}

--> {"id": 13, "method": "orchestration.dispatchCommand",
     "params": {"type": "thread.approval.respond",
                "commandId": "6e9a3c50-…", "threadId": "9d4c2e71-…",
                "requestId": "permission:9d4c2e71-…:acp-session-af9f40ba-…:tool_1",
                "decision": "accept"}}
<-- {"id": 13, "result": {"sequence": 21}}

<-- {… "sequence": 22, "type": "thread.approval-resolved",
     "payload": {"approval": {"requestId": "permission:9d4c2e71-…",
                              "decision": "accept", "optionId": "allow", …}}}
```

While a turn is waiting for permission the agent blocks on the answer — surface pending approvals prominently. Approvals whose turn gets
interrupted/steered resolve automatically with `cancelled: true`.

## 8. Errors and the failure model

**RPC errors** are standard JSON-RPC error objects:

```json
<-- {"id": 18, "error": {"code": -32001,
       "message": "thread \"00000000-0000-0000-0000-000000000000\" not found"}}
<-- {"id": 19, "error": {"code": -32001,
       "message": "unsupported orchestration command \"thread.item.upsert\""}}
```

- `-32602` — invalid params (bad shape).
- `-32601` — unknown method.
- `-32001` — daemon-level failure (validation, capability gating, provider call
  failure). The message is actionable prose; there is no structured error data.
- **Agent-originated errors pass through with their original code and data**
  (e.g. an ACP auth-required failure surfaces as
  `{"code": -32000, "message": "Authentication required", "data": {…}}`).
  Detecting "this needs login" currently requires matching on the code/message;
  there is no dedicated projection yet.

**Turn/provider failures during a turn are not RPC errors** — the dispatch
already succeeded. There is no `turn-error` event either. A failure surfaces
as:

1. `thread.item-upserted` with `item.kind: "error"` (human-readable title), and
2. `thread.session-status-set` with `session.status: "error"` +
   `session.lastError`, which also settles `latestTurn.state` to `"error"`.

Non-fatal provider/runtime warnings surface as `thread.item-upserted` with
`item.kind: "warning"`; they do not change `session.status`.

The thread remains usable: the next `thread.turn.start` starts a fresh turn
(and, if the agent dropped the session, transparently falls back to a new
provider session — resend the prompt when the error hints at it).

## 9. Terminal RPC

Terminal threads use a parallel, deliberately separate method family on the
same transport; they never appear in orchestration streams. Authoritative
shapes live in `api/wire/terminal.go` and the generated clients; behavior is
specified in `docs/TERMINAL_THREADS_SPEC.md`.

- Lifecycle calls: `terminal.create`, `terminal.attach`, `terminal.relaunch`
  (each returns a `TerminalAttachSnapshot`), plus `terminal.rename`,
  `terminal.terminate`, `terminal.delete`. The snapshot's base64 `replay` is
  a redraw synthesized from the daemon's terminal model at the caller's
  `columns`×`rows` — never recorded history — so clients feed it straight to
  their renderer and treat renderer reactions as live input. After applying
  it, consume only live items above `sequence` for the same `runId`.
- High-frequency client → server **notifications**: `terminal.write`,
  `terminal.resize`, `terminal.detach` — all fenced by `terminalId` + `runId`
  and accepted only from a connection attached to that terminal.
- Server → client notifications: `terminal.subscribe` (ordered `output` and
  `status` items per run) and `terminal.subscribeList` (snapshot /
  `terminal-upserted` / `terminal-removed`).
- `TerminalSummary` carries transient agent-detection fields for running
  terminals: `observedTitle` (normalized, spinner-free), `agentKind` (open
  label such as `"codex"` or `"claude"`; treat unknown values as display
  text), `agentActivity` (closed `TerminalAgentActivity` vocabulary: `none`,
  `idle`, `working`, `blocked` → render “Needs input”, `done` → persists
  until the next attach acknowledges it, `unknown` → render neutrally), and
  `agentActivityUpdatedAt`. List upserts are published only when these
  semantic fields or lifecycle state change — never per output chunk — and
  activity changes do not bump `updatedAt`, so rows do not reorder while an
  agent works.

## 10. Minimal client checklist

1. `provider.start` (or confirm via `provider.list`), gate UI on `capabilities`.
2. `orchestration.subscribeThreadList` → render sidebar entries and apply `thread-upserted` by id.
3. Keep new-chat prompt/provider/cwd/config state in a device-local draft. Use `provider.options.get/set` only to preview live options.
4. Send one `thread.start` command containing the client-generated thread ID, prompt, provider, cwd, and remembered config selections.
5. Subscribe to the created thread, clear the accepted local draft, then apply events per §5/§7 (append message text, merge
   items, replace plan/config/slash, track approvals).
6. Answer `thread.approval-opened` via `thread.approval.respond`.
7. On disconnect/overflow-close: keep cached detail projections visible, open a
   replacement connection, and subscribe again with only each selected/protected
   thread ID.
8. Buffer live notifications until each response arrives, atomically replace
   detail state with its snapshot, then apply only buffered events newer than
   `snapshotSequence`.
