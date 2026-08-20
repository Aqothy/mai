# Draft Threads

> **Retracted architecture.** Backend draft threads have been removed.
> New-chat drafts are client-local, and disposable provider options sessions
> supply live ACP configuration without becoming threads. The implemented
> design is documented in `docs/CLIENT_LOCAL_DRAFT_PLAN.md`; the material
> below remains only as historical context.

## Status and terminology

The backend draft-thread lifecycle described below is no longer implemented.

Two different things are called “draft” and must remain independent:

- A **backend draft thread** is an unsent engine thread used to prepare a
  provider session and obtain live configuration. It is promoted by the first
  turn and is not written to the thread metadata store before promotion.
- A **composer prompt draft** is unsent text owned by a client. Codex persists
  non-empty composer text independently for every thread/context. Swift
  `ThreadDraftStore` now does the same; it is independent of backend draft
  status, subscriptions, process-lifetime conversation retention, and
  the active chat view lifecycle.

This document primarily specifies backend draft threads. The complete Swift
composer-draft and unread-state plan lives in
`docs/CODEX_THREAD_BEHAVIOR_AND_CLIENT_PLAN.md`.

UX goal: creating a "new thread" gives the user a composer with a working
provider picker and **live** config options, but nothing is persisted and
nothing appears in any client's sidebar until the first message is sent.
Pressing "new thread" again or switching providers reuses the client's single
draft — it never accumulates threads.

## Decision

**A draft is a normal engine thread that the persistence layer skips. This is
uniform across all providers.**

- Drafts must exist on the backend because ACP config options are dynamic: a
  live session is required to list them and to react to `session/update`
  (setting one option can change others). That machinery is thread-scoped
  (`thread.session.prepare` → `EventThreadConfigOptionsUpdated` → thread
  subscription), so the draft has to be a thread to use it.
- Native providers (Codex/Claude direct APIs) do **not** need a live server
  process for config metadata — but we still run them through the same draft
  flow. Their "prepare" is simply cheap: fetch config metadata from the native
  endpoint, return it as `ConfigOptions`, create no remote conversation
  (native APIs create the conversation on first message anyway). The provider
  interface absorbs the cost difference; clients see one flow.

Rejected alternatives, for the record:

- _Pure client-side drafts + cached config-option snapshots (t3code):_
  loses live/interdependent ACP options while composing. Not acceptable here.
- _Per-provider split (client-only drafts for native, backend drafts for
  ACP):_ the architecture allows it, but it forks the draft lifecycle into two
  client code paths — two promotion flows,
  two config-UI data sources, per-provider branching in UI code. Provider
  differences belong behind `ProviderInstance`, not replicated across N
  clients.
- _Thread-less draft RPCs (`provider.prepareDraft`/`setDraftConfig`, the
  previous attempt):_ required duplicating the thread-scoped config streaming
  pipe outside the engine. That is why it didn't work.

## Where draft state lives

A draft thread occupies exactly the same in-memory structures as a real
thread. Its thread metadata and prompt are not written to SQLite; the
ephemeral provider route may be persisted and is pruned after restart:

| State                                            | Location                                                            | Persisted?                      |
| ------------------------------------------------ | ------------------------------------------------------------------- | ------------------------------- |
| The `Thread` (timeline, session, config options) | `Projection.threads` map, `internal/orchestration/projection.go:12` | Gated — skipped for drafts (§2) |
| Live event sequence                              | `EventSequencer`, `internal/orchestration/store.go`                 | No history is retained          |
| Thread → instance/session route                  | `Service.threadRoutes`, `internal/providerservice/service.go:80`    | Yes, but self-cleaning (see §4) |
| Thread → live ACP session                        | `sessionsByThread`, `internal/adapters/acp/session.go`              | Never                           |

Because an unpersisted draft exists only in the in-memory projection, all its
engine state evaporates on daemon restart. Cleanup only has to handle the
running-daemon case.

Draft **prompt text** never touches the backend, so typing costs zero RPCs. The
Swift client persists non-empty prompt text per thread rather than
coupling it to the one backend draft slot.

## Lifecycle

```
new thread (client)                    first send                 daemon restart
      │                                     │                           │
thread.create (draft=true, in-mem only)     │                           │
subscribe                                   │                           │
thread.session.prepare ──► provider session, config options stream in   │
thread.config-option.set … (live)           │                           │
      │                                thread.turn.start                │
      │                                draft=false ► metaWriter persists│
      │                                thread-upserted ► sidebar        │
      │                                                            projection entry,
      │                                                            session and route
      │                                                            are released
```

Promotion is emergent: the first `thread.turn.start` flips the flag, the
existing persistence and fan-out do the rest. There is no promote step, and
after the first send a draft is indistinguishable from any other thread.

Multi-client independence is by ID ownership: each device generates and
locally remembers its own draft thread ID. Two devices composing at once are
two independent threads with independent sessions; concurrent sends serialize
through the engine's single worker with nothing to coordinate. Clients only
ever _display_ the draft they own (all `draft` entries are filtered from the
sidebar), so one device's draft never affects another.

## Backend changes

### 1. `Draft` flag on the projection thread

- `Draft bool` on `Thread` and `ThreadListEntry`
  (`internal/orchestration/projection.go`), included in snapshot /
  `thread-upserted` payloads so clients can filter.
- `applyThreadCreated` sets `Draft: true`.
- `applyThreadTurnStartRequested` sets `Draft = false` (first user message is
  the promotion trigger).
- `RestoreThreads` (`internal/orchestration/restore.go`) marks restored stubs
  `Draft: false`. Required: restored threads also have no in-memory turns, so
  `LatestTurn == nil` alone cannot distinguish draft from restored. Anything
  read back from SQLite is non-draft by construction, because only non-drafts
  are ever written.

### 2. Gate metadata persistence

`threadMetaWriter.flush` (`internal/daemon/persistence.go:158`) skips drafts:

```go
entry, ok := w.engine.ThreadListEntry(threadID)
if !ok || entry.Draft {
    continue
}
```

`markDirty` stays untouched. The turn-start event is `ThreadListVisible`, so
promotion re-marks the thread dirty and the next flush writes it — carrying
the final title and provider in its first row.

### 3. Provider switching on a draft — existing commands only

Same thread, same ID, **two** commands from the client — the old session's
teardown is already automatic:

1. `thread.meta.update` with the new `providerInstanceId`. The decider
   resolves the selection change and sets `SessionCleared` when the bound
   session belongs to a different instance (`selection.go:50`,
   `sessionBindingStaleFor`); the projection clears the binding, and the
   reactor reacts to `SessionCleared` with `handleSessionRelease` →
   `providerservice.ReleaseSession` (`service.go:663`), which drops the route
   (scheduling the SQLite `DeleteRoute`) and best-effort stops the old
   session on its instance.
2. `thread.session.prepare` — new provider session; its config options stream
   in through the same subscription.

**Rapid switching is already guarded.** The engine rejects a selection change
while the previous prepare is still in flight (`validateMetaUpdate`,
`selection.go:60-69`: no changes while `sessionPreparing` or a turn is
active) and rejects overlapping prepares (`engine.go:616`). The reactor runs
release/prepare handlers on a per-thread FIFO chain (`enqueueThread`), so
they can never interleave for one thread, and every prepare settles (bound or
error) within `providerRPCTimeout`, so the "preparing" state cannot stick.
Net effect: flipping providers as fast as you can click yields, at worst, a
rejected command while the previous switch settles — never two live sessions
and never a leak. Clients should disable the provider picker while session
status is `starting` (or retry the switch when the status settles).

Refs stay bounded at one thread + one session per client no matter how often
the user flips providers. If prepare fails (agent missing, auth needed), the
existing session-error state + "Retry agent setup" applies unchanged.

### 4. Cleanup — who releases what

| Ref                                   | Created by                        | Released by                                                                                                            |
| ------------------------------------- | --------------------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| `Projection.threads` entry            | `thread.create`                   | daemon restart                                                                                                         |
| Provider session (`sessionsByThread`) | `thread.session.prepare`          | provider switch; instance close / daemon restart                                                                       |
| Route (`threadRoutes` + SQLite row)   | `bindThreadSession` → `SaveRoute` | unbind already schedules `DeleteRoute` (`service.go:239-253`); startup pruner removes orphans (`persistence.go:78-80`) |
| SQLite `threads` row                  | never created for drafts          | n/a                                                                                                                    |

Leak analysis for the running daemon: each device holds at most **one** draft
because the client reuses its draft thread ID across reloads and reconnects
(if the thread still exists in the projection, re-subscribe and continue —
config options intact; if not, recreate). A device that vanishes forever
leaks one thread + one session until daemon restart. Accept this for now.
**Deliberately deferred:** an idle sweep (remove subscriber-less drafts
after a TTL) is easy to add later if lingering sessions ever matter; do not
tie draft lifetime to WebSocket disconnect — mobile reconnects constantly and
it would churn provider sessions on every backgrounding.

### 5. Provider interface contract

What any `ProviderInstance` must satisfy — this is where per-provider
differences live, and the only place:

- **`StartSession(threadID, input)`** — idempotent per thread: if a session
  is already bound (the draft's prepare created it), reuse it. This is the
  adoption point when the first turn arrives. The ACP adapter already does
  this (`internal/adapters/acp/session.go`).
- **Prepare must be cheap to abandon.** A session created by
  `session.prepare` may never see a turn. ACP: `session/new` is lightweight.
  Native providers: fetch config metadata from the native endpoint, allocate
  local state, create **no** remote conversation — defer anything
  side-effectful or billable to the first turn.
- **`ConfigOptions`** returned from `StartSession` (and streamed via runtime
  events when they change). ACP: from `session/new` + `session/update`.
  Native: from the metadata endpoint; if options never change after prepare,
  that is fine — "static" is just a stream that never updates. No options →
  client renders no controls. Same client code path either way.
- **`StopSession(threadID)`** — must be safe on a never-used session. ACP:
  unbind, and send `session/close` when the agent advertises support.
- **Concurrency:** sessions for different threads on one instance must be
  usable concurrently (multiple devices sending at once).

## Edge cases & migration

- **Legacy orphan rows** (metadata persisted under the old flow, no session
  ever created) still error on load and are indistinguishable in SQLite:
  prune them once, and independently make the load path degrade gracefully —
  a restored thread whose session cannot be resumed surfaces as
  re-preparable (session-error + retry), not a hard error. Needed anyway for
  ACP agents without `session/load`.
- **Draft events on the wire:** `thread-upserted` broadcasts include drafts
  and every client filters them. Acceptable; revisit only if it ever shows up
  as real overhead.
- **Turn on a draft that never ran prepare:** already works —
  `handleTurnStart` calls `StartSession` before `SendTurn`
  (`provider_event_reactor.go:183-246`).

## Implementation status

1. Implemented: `Draft` flag, restore marking, snapshot/notification payloads.
2. Implemented: persistence gate in `threadMetaWriter.flush`.
3. Implemented in Swift: new-thread UI plus the independent per-thread composer
   draft store described above.
4. Deferred hardening: graceful re-preparable handling for
   unresumable restored threads; prune legacy rows; idle sweep only if
   lingering draft sessions become a real problem.
