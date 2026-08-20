# Client-local draft architecture

Status: implemented. This supersedes the draft-flow portions of
`SWIFT_DRAFT_FLOW_HANDOFF.md`.

## Decision

A new-chat draft is local client data. It is not a thread and it does not
own a real provider session.

ACP still needs a live session to return exact dynamic configuration
options. The daemon therefore owns disposable **options sessions** whose
only job is to populate the settings UI. They are never promoted into a
thread session and never required for Send.

This keeps one correctness path for every provider:

1. Edit a local draft.
2. Optionally preview provider options.
3. Send one `thread.start` orchestration command.
4. Let the normal provider reactor create the real session and run the
   turn.

Native Codex and Claude providers use the same draft and Send path. Their
options implementations may be stateless; they are not forced to create
draft sessions.

## State ownership

### Client

`ThreadDraftStore` owns the prompt under a client-generated thread ID.
`DraftPreferencesStore` owns the remembered provider, cwd, and config
values.

Changing provider, ACP agent, or cwd is always an immediate local update.
It also starts a cancellable options reload, but does not block the prompt,
pickers, or Send.

### Daemon connection

Each WebSocket connection has:

```go
optionsSessions map[provider.InstanceID]*clientOptionsSession
```

There is at most one options session for each provider instance on that
connection. An entry records its cwd, provider handle, current options,
and an opaque connection-local `optionsSessionID`.

- Same provider and cwd: reuse the warm session.
- Same provider and new cwd: remove the old entry, open a replacement, and
  close the old handle best-effort in the background.
- Different provider: keep both entries, so switching back is warm.
- Disconnect: forget and best-effort close every entry.

There is deliberately no LRU, TTL, lease, promotion, reconnect identity,
or durable options state.

The daemon serializes options-session lifecycle operations for each WebSocket
client. A draft has only one active settings interaction at a time, so a
single lifecycle lock is enough; callbacks use a smaller state lock and never
wait on provider I/O. This does not block the Swift main thread or
non-settings controls.

### Orchestration

No draft state exists in the domain or event log. `thread.start` is a
normal `Command` sent through the existing
`orchestration.dispatchCommand` RPC; there is no bespoke start RPC or
server-side draft saga.

The command records, under one engine lock:

- the real thread;
- the first user message;
- the chosen config values; and
- the first turn-start request.

The existing provider reactor then opens the real session and sends the
turn. A provider failure produces a visible errored thread. Retrying emits
`thread.turn.retry`, which starts a new turn using the failed turn's
existing user message; it does not append a duplicate message.

`thread.session.prepare` and `thread.session.stop` remain for real
restored/imported threads. They are not used by the new-chat draft flow.

## Provider options API

The API is provider-generic:

```text
provider.options.get
  { providerInstanceID, cwd }
  -> { optionsSessionID, configOptions }

provider.options.set
  { optionsSessionID, optionID, value }
  -> { optionsSessionID, configOptions }

provider.options.updated
  notification { optionsSessionID, configOptions }

provider.options.invalidated
  notification { optionsSessionID }
```

Every response or notification is accepted by the client only when its
`optionsSessionID` is still current. This prevents a late update from a replaced
session from changing the current form. Selection fetches also verify that
the provider and cwd are still selected after each await.

The provider interface is:

```text
OpenOptionsSession(cwd, callbacks) -> { handle, configOptions }
SetOptionsSessionValue(handle, optionID, value) -> configOptions
CloseOptionsSession(handle)
```

ACP implements it with an unbound `session/new`. Native providers may
return a catalog without opening a session.

Providers advertise `capabilities.configOptions` so clients only request
options when supported. The ACP client also advertises support for boolean
configuration options. ACP filesystem and terminal capabilities remain
unsupported by this project.

## Swift behavior

The draft model contains local form fields plus:

- current options, `optionsSessionID`, and loading/error phase;
- one cancellable options-load task driven by the current selection;
- a small serialized queue for user config changes.

The config-change queue is needed because dependent ACP options are
stateful. For example, a model update must reach the ACP session before a
reasoning-level update. It is a FIFO list, not a general scheduler.

On provider or cwd change, old controls disappear immediately and the
settings area shows a contextual loading state. This avoids letting the
user edit settings that belong to the old cwd. The rest of the form stays
usable.

Remembered values are applied in this order:

1. install the provider's raw option response;
2. apply a remembered model if it is still valid;
3. install the provider's resulting dependent options;
4. apply other remembered values if they remain valid.

Changing a setting updates local preferences immediately. The options
session update is only a live preview; if it fails, Send still carries the
local value and the real session reconciles it best-effort.

If Send happens before options load, selections may not yet carry category
hints. ACP infers missing categories from the authoritative real
`session/new` response, applies model selections first, then applies
dependent selections. This is what makes “Send does not wait for options”
correct rather than merely optimistic.

## Send and failure behavior

Send first snapshots the complete local form and marks the form as
sending. Later UI edits cannot change that attempt.

The snapshot becomes one `Command`. The draft's stable client-generated
thread ID is the reconciliation key: after an ambiguous RPC outcome, the
client opens that real thread if it appears in the authoritative thread
list. If it does not appear, a later Send builds a fresh command from the
current local draft using the same thread ID.

| Event | Behavior |
| --- | --- |
| Disconnect/restart while editing | Local draft is untouched. Settings reload after reconnect. |
| Options agent/session dies | Current settings show a retryable error. Send remains available. |
| Rapid provider/cwd changes | Superseded fetches are ignored by selection and `optionsSessionID` guards. |
| Options fetch fails | Only the settings area shows Retry. |
| Provider switch | Local change; a warm per-provider options session is reused when available. |
| Cwd change | Local change; that provider's replacement options session opens asynchronously. |
| Start command is rejected | Draft remains, with an error and Retry. |
| Connection dies during Start | After reconnect, the client-known thread ID resolves the outcome: open the real thread if present; otherwise keep the draft and allow Send again. |
| Start is accepted | Open the real thread and remove the local draft. |
| Provider fails after acceptance | Show the normal errored thread; Retry reuses its existing user message. |
| Config value is stale at Send | Apply best-effort, emit a runtime warning, and use the provider default. |

The deliberately unsupported narrow case is a daemon crash after the
start command is durably accepted but before the provider receives the
first message, when the provider cannot restore that message. Covering
that window would require durable command/message recovery or retaining a
second client backup lifecycle. The implementation does neither until
real usage justifies that complexity.

## UI blocking policy

- Prompt editing: blocked only during the brief Start RPC to prevent two
  first sends.
- Provider, agent, and cwd controls: remain responsive while options load;
  disabled during Start for the same snapshot/duplicate-send reason.
- Config controls: enabled only for the current live `optionsSessionID`.
- Send: requires connection, provider, cwd, and non-empty prompt. It does
  not require options to finish loading.

Async does not mean every control should stay enabled. The small Start
lock prevents duplicate commands and makes the submitted snapshot obvious.
Options loading does not lock the form because it is optional preview
data.

## Removed complexity

- server draft objects and draft flags;
- draft prepare/restore/stop state machines;
- prepared-draft promotion;
- server-side draft restore/reconciliation state machines;
- custom `thread.start` RPC DTOs and handler;
- `PendingFirstSend` durable-backup lifecycle;
- options-session LRU/TTL/lease/revision machinery;
- synchronous close-before-open on cwd changes; and
- duplicate config-update notifications.

## Validation targets

- No server object is created while editing a new-chat draft.
- Switching providers is immediate; switching back can reuse a warm
  options session.
- Cwd changes never block the form and never expose editable stale
  settings.
- Dynamic dependent ACP options update in provider order.
- Send works before options load.
- First-turn provider failure yields one visible user message and a
  working Retry.
- Multiple WebSocket clients have independent options sessions.
- Replacing or reopening unbound ACP options sessions works.
- A late options notification cannot update a replacement session.
- Daemon, orchestration, ACP adapter, and Swift validation pass.

## Deferred optimizations

Do not add these without measured need:

- promoting an options session into a real thread session;
- caching option catalogs across connections;
- more than one cwd-tagged options session per provider;
- cross-device draft sync;
- durable first-command recovery; or
- agent-process recycling for implementations that cannot close abandoned
  sessions.
