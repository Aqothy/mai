# Persistence Implementation (provider-owned history)

Status: Phase 1 built (2026-07-13) — `internal/store` (SQLite via
`modernc.org/sqlite`, WAL) plus both write paths: providerservice
write-through for routes/instance specs, and the daemon's asynchronous
`threadMetaWriter` for sidebar rows. Implementation deviations from the sketch
below: routes live in their own `thread_routes` table instead of being merged
into `threads` (the two write paths never contend on a row, and a thread
created before any session bind needs no NULL instance id); `threads`
carries `provider_instance_id`/`model_selection` (the thread-level selection)
so a rehydrated stub can be reopened even if no route was ever bound; and no
migration machinery or unused columns — the schema has never shipped, so it
is a plain idempotent CREATE, and columns arrive with the features that read
them. Data dir: `$MAID_DATA_DIR`, default user-config-dir/maiD.

Phase 2 built (2026-07-13) — boot rehydration. `Engine.RestoreThreads`
(`orchestration/restore.go`) seeds projection stubs under the engine lock
before the daemon serves connections; no events are appended (the new process
starts a fresh sequence and clients obtain snapshots), timestamps are preserved from the store, and stubs have
an empty timeline and no session binding. providerservice restores routes and
instance specs itself inside `New` when a route store is configured (rather
than the daemon passing them in): instances stay cold and respawn lazily on
first `StartSession` for a routed thread (`ensureInstanceStarted`), and all
restored routes share one event generation that is never assigned to a live
instance, so the existing stale-generation recovery in `withThreadInstance`
re-runs `StartSession` with the stored start input + resume cursor before the
first operation.

Phase 0 built (2026-07-14) — provider capabilities now report independent
`LoadReplay` and `Resume` flags, with ACP mapping `loadSession` and session
`resume` respectively.

Phase 3 built (2026-07-15) — restored threads request one-shot history replay
during session preparation. ACP prefers `session/load` for that intent and
returns its complete ordered update batch with the prepared session. The
reactor applies that batch synchronously, completes replay, and only then marks
the session ready. Ordinary process recovery remains resume-first and discards
any load replay; unavailable display history produces a visible warning.

Phase 4 built (2026-07-16) — `provider.importSession` accepts an explicitly
selected `SessionSummary`, mints a maiD thread id, and atomically stores the
sidebar row plus provider route. Imports dedupe by `(instance_id,
provider_session_id)`, immediately publish a real replay-pending stub, and
reuse Phase 3 preparation/replay; retries return the existing maiD thread id.
There is no background synchronization.

This is the complete intended persistence design. maiD owns durable metadata;
providers own conversation history. Process-local events are sequenced and
fanned out live but are not retained for client recovery.

## Decisions (settled with the owner)

1. **Metadata in maiD; conversation history in providers.** Providers own their
   session/conversation data; maiD stores just what it needs to list
   threads in the UI and re-establish the provider session (id + resume
   cursor). Providers without durable storage are not rejected — they work
   fully live (the projection holds everything for the daemon's
   lifetime) and degrade on restart to title-only threads. The capability
   decides the reopen experience; nothing is gated out.
2. **Zed-style import, no auto-sync.** The store holds threads created
   through maiD plus explicitly imported ones. maiD never mirrors provider
   session lists into its own store in the background.
3. **Snapshot restart semantics.** Reopening rebuilds the *UI timeline*, not a
   byte-identical event stream. Sequences restart per daemon boot; clients obtain
   authoritative snapshots and use their watermarks only for later live events
   on that connection.
4. **No retained transport replay log.** `EventSequencer` assigns total order
   and listeners fan events out immediately. The **projection** is authoritative
   while the daemon runs, the **store** survives restarts (metadata), and the
   **provider** owns conversation history.

Rationale for metadata-only:

- Every planned provider persists its own data:
  - **ACP agent servers** with `loadSession`/`session/resume` (replay history
    as `session/update`s on load).
  - **Codex app server**: persists threads itself (JSONL rollouts + SQLite
    state DB); exposes `thread/list` (cursor pagination, filters),
    `thread/resume`, and `thread/read` (fetch stored history without
    resuming), plus archive/delete/fork.
  - **Claude SDK**: sessions in `~/.claude/projects/.../<session-id>.jsonl`,
    resumable by session id; display rebuild = adapter reads the transcript
    file (no protocol replay needed).
- Mirroring provider-owned content in maiD would duplicate storage and require
  durable sequences, projection checkpoints, per-thread versions, and snapshot
  windowing without improving the intended provider-backed reopen path.
- Metadata-only storage enables **importing** sessions created outside maiD
  via `session/list` / `thread/list`.

Prior art consulted:

- **Zed** (`crates/agent_ui/src/thread_metadata_store.rs`): one SQLite row
  per thread for *every* agent (`sidebar_threads`: Zed-minted `thread_id`
  UUID PK, agent's own `session_id`, `agent_id`, title, timestamps, paths,
  archived). Full content persisted only for Zed's native agent. Reopen =
  `session/load` with stored id, fallback `session/resume` (context, no
  replay), else error — Zed accepts that some agents can't be reopened.
  Import = page the agent's `session/list`, mint fresh `thread_id` per
  discovered session, dedupe on `session_id`.
- **Agmente** (Swift/Core Data): metadata always; full messages only as a
  fallback cache for ACP agents lacking `session/load`. For load-capable
  agents and Codex the backend is the source of truth (Codex code never
  reads messages from local storage; it rehydrates via
  `thread/read`/`thread/resume`, and prunes local rows to match the
  server's `session/list`).
- **T3** (TypeScript/Effect, SQLite event log + SQL projections) mirrors full
  message text and every tool call/activity, duplicating what Codex rollouts /
  `thread/read` already hold. Every adapter implements a `readThread`
  provider-replay capability, but it has **zero call sites**. Costs visible in
  the code include ~1,700 lines of in-memory delta reassembly before storage,
  unbounded per-thread message tables, two projection folds, 32 migrations,
  and turn-revert logic that rewrites projection tables. Its provider-event
  "dedupe" appends a fresh UUID to the command id, so receipts never dedup
  provider redelivery. This tradeoff is useful prior art, but it is not maiD's
  persistence model.

## Why metadata-only fits maiD's architecture

maiD reduces sequenced live events into an authoritative in-memory projection,
and ACP `session/load` replays history as `session/update` notifications. So
restart recovery needs no transport event log: rehydrate thread *stubs* from metadata, and when a
thread is reopened, the provider's replay flows through the existing
ingestion pipeline (`orchestration/ingestion.go`) and rebuilds the timeline
as fresh events. The ingestion pipeline is the replay renderer.

The ACP adapter conditionally drops replayed updates during load: ordinary
process recovery suppresses them because the projection is already populated;
a Phase 3 display reopen emits them through ingestion. `awaitSessionBarrier`
keeps both paths ordered before session preparation completes.

## Phase 0 — split the capability model

`provider.Capabilities.Resume` (contract.go) deliberately conflates load and
resume. Split:

```go
type Capabilities struct {
    // LoadReplay: adapter can rebuild display history for a stored session
    // (ACP session/load, Codex thread/read+resume, Claude SDK transcript).
    LoadReplay bool
    // Resume: adapter can restore agent context without replaying history
    // (ACP session/resume). Continue-only.
    Resume bool
    // ...existing fields
}
```

`ListSessions`/`DeleteSession`/`CloseSession` stay on the optional
`providerservice.SessionManager` interface — unchanged.

The capability is phrased as "can you rebuild history for session X", not
"do you support ACP session/load": the mechanism (protocol replay,
`thread/read`, transcript file) is an adapter detail.

The split is needed because the two flags answer
independent questions that real agents answer independently (ACP ships
load-only, resume-only, and neither):

- `LoadReplay` → "can the history UI be rebuilt on reopen?" (sets
  `ReplayHistory`; without it the UI shows "history unavailable").
- `Resume` → "can the agent continue in context without replay?" (drives
  in-process stale-generation recovery; means continue can work even when
  display can't).

Adapter mappings: ACP `LoadReplay` ← `AgentCapabilities.loadSession`,
`Resume` ← session `resume` capability (the existing
`supportsLoadSession()`/`supportsResumeSession()` checks, surfaced
generically). Codex: both true (`thread/read` / `thread/resume`). Claude
SDK: both true (transcript file / resume-by-session-id).

## Phase 1 — the metadata store (new package `internal/store`)

SQLite via `modernc.org/sqlite` (cgo-free; keeps `CGO_ENABLED=0`
cross-compilation and needs no C toolchain — the metadata workload is tiny
and single-writer, so mattn/cgo performance is irrelevant here;
`ncruces/go-sqlite3` is the acceptable alternative). Open with WAL mode and
a `busy_timeout`. Schema — essentially `providerservice.threadRoute` +
sidebar fields, merged:

```sql
CREATE TABLE threads (
    thread_id           TEXT PRIMARY KEY,          -- maiD's stable id
    title               TEXT,
    cwd                 TEXT,
    instance_id         TEXT NOT NULL REFERENCES instances(instance_id),
    provider_session_id TEXT,                      -- NULL until first provider bind
    resume_cursor       TEXT,                      -- opaque JSON, provider-owned
    start_input         TEXT,                      -- JSON: model/config selections to re-apply
    created_at          TEXT NOT NULL,
    updated_at          TEXT NOT NULL
) STRICT;

CREATE TABLE instances (
    instance_id TEXT PRIMARY KEY,
    driver_kind TEXT NOT NULL,
    config      TEXT                               -- opaque InstanceSpec.Config
) STRICT;
```

T3 independently converged on the same route-record shape — its
`provider_session_runtime` table (`thread_id` PK, provider name, instance
id, adapter key, `resume_cursor_json`, `last_seen_at`) is essentially the
`threads` route columns above, kept separate from its derived session
projection. Adopt that shape; skip everything else it stores.

Invariants (mirroring Zed):

- `thread_id` is **ours**, `provider_session_id` is **theirs**. Never
  conflate them — that separation is what allows importing external
  sessions and surviving provider session-id churn.
- A `provider_session_id` is only meaningful together with its
  `instance_id`: session ids are minted per-agent, not globally unique, and
  resuming requires spawning that instance (with its stored config) first.
  Hence the `instances` table (config is per-instance, shared by all its
  threads — never duplicated per thread) and the `(instance_id,
  provider_session_id)` dedupe key for import. `driver_kind` lives only on
  `instances`; threads derive it via the FK (single source of truth).
- Do NOT persist `Generation` — process-lifetime fencing only; reset on boot.
- Do NOT source the sidebar from `session/list` — that is per-provider and
  only for import (FUTURE_WORK rule, unchanged).

Two narrow interfaces, both implemented by the one SQLite store; in-memory
implementations remain the default (per the seam contract in
`docs/ARCHITECTURE.md`):

```go
// consumed by providerservice — persistent backing for threadRoutes
type RouteStore interface {
    SaveRoute(threadID string, r RouteRecord) error // ProviderSessionID, ResumeCursor, StartInput
    DeleteRoute(threadID string) error
    LoadRoutes() (map[string]RouteRecord, error)
}

// consumed by daemon/orchestration — the durable sidebar
type ThreadStore interface {
    UpsertThread(m ThreadMeta) error // title, cwd, provider selection, timestamps
    DeleteThread(threadID string) error
    ListThreads() ([]ThreadMeta, error)
}
```

Write paths:

- `providerservice.bindThreadSession` / resume-cursor updates →
  `SaveRoute`.
- A daemon `OnEvent` listener → asynchronous `UpsertThread` when
  `ThreadMetadataMayChange` identifies a user message, explicit thread metadata
  change, or model-changing config update. Listeners run on the engine worker
  and must stay cheap: mark the thread dirty and wake the writer goroutine;
  never block the worker on SQLite.
- **Client-local drafts (current):** composing a new chat creates no
  orchestration object and writes nothing to SQLite. Disposable
  connection-owned provider options sessions supply live ACP configuration
  without entering persistence. `thread.start` records the real thread,
  selection, first message, and first turn request together; that event wakes
  the metadata writer. See `docs/CLIENT_LOCAL_DRAFT_PLAN.md`.
- **`UpdatedAt` is user-message recency (implemented 2026-07-14):** it starts
  at `CreatedAt` and advances monotonically when a newer user message is
  recorded. Turn starts/settlements, session machinery, config options,
  approvals, token usage, and renames do not change sidebar order. Explicit
  metadata and model-selection changes are still persisted without changing
  `UpdatedAt`.

## Phase 2 — boot rehydration

In `daemon.newServer`: read `ListThreads()` + `LoadRoutes()` + instance
specs; seed the projection with thread stubs (id, title, timestamps; session
status stopped/idle; **empty timeline**) via a dedicated restore path on the
engine before serving connections. Instances stay cold — re-spawn lazily on
first use of a routed thread (`withThreadInstance` already re-runs
`StartSession`; the route now comes from the store instead of the map).

Restart semantics: sequences reset to 0 per boot. Clients replace cached
projections with authoritative subscribe snapshots; there is no client event
cursor or missed-event catch-up response. Durable sequences are not part of
the persistence design.

## Phase 3 — the reopen/replay path (the real work)

Add `ReplayHistory bool` to `provider.StartSessionInput`. Orchestration sets
it when preparing a rehydrated thread whose one-shot replay intent is pending.
`StartSession` returns a `StartSessionResult`: the prepared session, the
complete ordered replay batch when available, and an explicit unavailable
signal otherwise. Ingestion serializes that thread from before the provider
load through replay, buffer flush, the internal replay-completed orchestration
event, and the ready binding. No provider runtime completion event or second
asynchronous path is involved.

ACP adapter `StartSession` becomes intent-aware:

- `ReplayHistory && supportsLoadSession()` → `session/load`, capture its
  replayed updates, and return them only after the load response and ordered
  stream barrier both succeed. Bind the thread→session route before awaiting
  the load so notifications resolve correctly. A failed load returns no replay
  batch, leaving the one-shot intent pending for retry.
- `!ReplayHistory` (in-process stale-generation recovery; projection already
  populated) → today's behavior exactly: prefer `session/resume`, else
  `session/load` while capturing and discarding its replay.
- Neither load nor resume → fresh session, no agent memory. Surface this in
  the UI ("history unavailable for this agent") rather than pretending.

This is the per-adapter template: a Codex adapter implements
`ReplayHistory` via `thread/resume` + `thread/read` (translating turns into
runtime events); a Claude SDK adapter reads the transcript file.
Orchestration never knows the difference — the "interface that works for all
providers" is `StartSessionInput.ReplayHistory` + `StartSessionResult.Replay`
on the existing `ProviderInstance` seam, with the split capabilities deciding
whether display restore and provider-context resume are available.

Replay fidelity contract — same UI, not same log:

- **Preserved:** conversation content and timeline order. Replay feeds the
  same ingestion switch as live traffic, so the projection/UI is built by
  one code path either way.
- **Different by design:** sequences (fresh process), event ids, chunk
  boundaries (a message that streamed as 30 coalesced chunks live may
  replay as one), timestamps unless the provider stores originals (Codex
  and Claude transcripts do; ACP replay updates generally don't).
- **Not coming back:** resolved permission requests (ephemeral, already
  answered), token-usage counters, and anything the agent chose not to
  persist — fidelity is capped by the provider's own storage (Codex/Claude
  transcripts are near-complete; a minimal ACP agent's replay may be
  messages-only). Same ceiling Zed accepts.
- **Resume is two independent halves:** display (replay → ingestion) and
  continue (resume cursor → provider restores its own context). Neither
  depends on a retained transport event log.

## Phase 4 — import external sessions (explicit, Zed-style)

RPC surface exists (`provider.listSessions` → `SessionManager.ListSessions`).
Add an import command (Zed's pattern): for each `provider.SessionSummary`
the user picks, mint a fresh `thread_id`, store a metadata row with the
provider's session id, and dedupe on `(instance_id, provider_session_id)`.
Opening an imported thread is Phase
3's replay path — zero extra machinery.

Explicitly NOT auto-sync: maiD never mirrors provider session lists into
the store in the background. Provider lists are polluted (Codex
`thread/list` / `~/.claude/projects` contain every session from every tool
and project), auto-sync turns maiD into a reconciliation mirror of N
provider stores, and the metadata rows carry maiD-owned fields that have no
provider counterpart. Optional later
middle ground: a "browse provider sessions" view that lists live from
`session/list`/`thread/list` without persisting, importing a session only
when the user opens it.

## Patterns worth stealing from T3 (cheap and metadata-oriented)

- **Statically registered, ordered migrations** with a tracking table for
  the store's schema versioning.
- **Archive/delete as first-class lifecycle** (`archived_at`/`deleted_at`
  columns, soft delete) rather than hard row deletes — the `archived` column
  above; add `deleted_at` when the thread-delete command is built.
- **Idle session reaper**: a sweep that stops provider processes after N
  minutes idle but never touches stored metadata — the "provider process is
  disposable, my record is durable" separation this whole design rests on.
  Optional, later.
- **Title-via-events**: provider-supplied thread titles flow into maiD's own
  title field (already how maiD projects agent titles), so titles survive
  provider loss. Keep that in the metadata write path.

## Risks accepted consciously

- **Provider persistence is trusted.** `LoadReplay` means the agent
  *implements* load, not that its data survives an agent update or a
  `~/.gemini` wipe. A thin thread whose backend lost the session degrades to
  metadata-only (title in sidebar, empty history, fresh context on
  continue). Zed and Agmente-for-Codex accept this; make the degraded state
  explicit in the UI instead of guarding with duplicate storage.
- **ACP `loadSession` is optional, and some real agents lack it.** T3's
  Cursor and Grok ACP integrations are examples. Decision: accept the
  degradation: threads on such agents lose display history across daemon
  restarts, and continuation works only while a resume cursor remains valid.
- **Reopen-for-display needs the provider up.** T3 renders reopened threads
  instantly from its own tables and only starts the provider on the next
  turn; a thin design must spawn the agent and replay to show history.
  Mitigation: prefer non-resuming reads where the protocol offers them
  (Codex `thread/read`; Claude SDK transcript file — neither needs a live
  session), and accept the spawn cost for ACP `session/load` (the user is
  usually about to continue the thread anyway).
- **Resume cursors can go stale** across agent version bumps. Treat
  load/resume failure as "start fresh + keep metadata", never as thread
  deletion.
- **Replay volume**: a long session replayed through ingestion bursts events
  to subscribed clients. Chunk coalescing helps; if still noisy, rebuild the
  projection first and send one snapshot before notifying subscribers
  (later optimization).

## Build order

1. Phase 1 + 2 — durable sidebar (immediately visible value).
2. Phase 0 + 3 — reopen with history.
3. Phase 4 — import.

The phases above are built; further persistence work is limited to metadata
needed by concrete product features.
