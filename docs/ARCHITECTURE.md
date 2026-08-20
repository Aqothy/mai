# Architecture

maiD is a local daemon that fronts AI coding agents (via ACP) for multiple
concurrent clients. Clients talk JSON-RPC over WebSocket; the daemon owns all
thread state and syncs every client through an event stream.

## Package map

```
cmd/maiD            entrypoint: NewServer().RunWebSocket(addr)
internal/daemon     transport: WebSocket JSON-RPC, client registry, event fanout
internal/orchestration
                    the domain core: commands, sequenced live events,
                    projection (authoritative read model), provider command reactor,
                    provider runtime ingestion
internal/providerservice
                    provider instance lifecycle + thread→instance routing;
                    defines the adapter seam it consumes (ProviderInstance,
                    Authenticator, SessionManager)
internal/adapters/acp
                    the ACP adapter (spawns/talks to agent processes)
internal/provider   provider-neutral types shared by all of the above
internal/store      durable metadata (SQLite): thread sidebar rows, session
                    routes, instance specs, terminal thread rows — metadata
                    only, never events (docs/PERSISTENCE_PLAN.md)
internal/terminal   terminal threads: PTY sessions, native Ghostty attach models,
                    and the daemon-owned coding-agent detector
                    (docs/TERMINAL_THREADS_SPEC.md)
internal/terminal/agentrules
                    compiled-in agent classification rules (embedded manifests)
internal/terminal/vtscreen
                    passive headless libghostty-vt terminals: the detection
                    screen and each run's attach model
                    (docs/TERMINAL_AGENT_DETECTION.md)
```

Dependencies flow one way: `daemon → orchestration, providerservice, acp,
store`, `providerservice, acp → provider`, and `providerservice → store →
provider` (store defines the persistence contracts; the daemon composes the
one SQLite store into both consumers). providerservice knows nothing about
orchestration — the daemon connects them by feeding `providerservice.Events()`
into `orchestration.ProviderRuntimeIngestion.Run` (the seam is inverted so the
provider side stays orchestration-agnostic). The acp package never imports
providerservice: it implements the seam implicitly and returns its concrete
`*Instance`.

The daemon is the composition root: `daemon.openProviderInstance` (server.go)
is the `providerservice.InstanceFactory` that maps a `provider.DriverKind` to
its adapter implementation. New drivers get a case there. Provider start uses
an `InstanceSpec` whose opaque `config` belongs to the selected driver;
providerservice stores/routes the spec without decoding it and passes the
runtime-event sink to the factory separately.

## The two flows

Everything the daemon does is one of these two flows. Both funnel through the
engine's single worker queue (`Engine.Dispatch` for client commands,
`Engine.AppendEvent` for provider/server events), so the projection is the
single source of truth and live events stay totally ordered.

### 1. Command flow (client intent, downward)

```
client ── ws ─▶ daemon/rpc.go        rpcHandler.Handle (method switch)
                    │  orchestration.dispatchCommand
                    ▼
orchestration/engine.go   Engine.Dispatch → engine queue → worker goroutine
                    │  dispatch (command-type switch) → decider validates
                    ▼
                    Event stamped with a sequence + applied to Projection
                    │  listeners notified (still on the worker goroutine)
        ┌───────────┴─────────────┐
        ▼                         ▼
daemon/rpc.go                orchestration/provider_event_reactor.go
publishOrchestrationEvent    handle (event-type switch) → per-thread chain
fan out to subscribed        │  e.g. handleSessionPrepare: StartSession;
clients (ws notify)          │       handleTurnStart: StartSession + SendTurn
                             ▼
                             providerservice/service.go
                             withThreadInstance → route thread → instance
                             │  (generation fencing, auto re-StartSession)
                             ▼
                             adapters/acp   the agent process
```

### 2. Event flow (provider events, upward)

```
adapters/acp        agent process emits ACP updates
                    │  converted to provider.RuntimeEvent, sent to the
                    │  per-instance event sink (stamps instance identity)
                    ▼
providerservice/service.go   publish → ingress chan → runHub
                    │  drops events from replaced (stale) process generations
                    ▼
                    Events() channel  (single consumer: ingestion)
                    ▼
orchestration/ingestion.go   Run → Ingest (runtime-event-type switch)
                    │  coalesces assistant/reasoning text chunks per
                    │  textFlushInterval; attachments and semantic
                    │  boundaries flush pending content immediately;
                    │  turn lifecycle/errors as session changes
                    ▼
orchestration/engine.go   Engine.AppendEvent (same worker queue as flow 1)
                    │  event → projection → listeners; session updates are
                    │  derived into full bindings (session.go) under
                    │  the write lock, stale updates dropped
                    ▼
daemon/rpc.go       publishOrchestrationEvent → subscribed clients
```

## Where the call graph lives

The pipeline is wired with switches, not virtual dispatch. To trace a feature,
grep these in order — each switch is the complete list of what the layer
handles:

| Layer                     | File                                      | Switch                                      |
| ------------------------- | ----------------------------------------- | ------------------------------------------- |
| RPC methods               | `daemon/rpc.go`                           | `rpcHandler.Handle`                         |
| Command deciders          | `orchestration/engine.go`                 | `Engine.dispatch`                           |
| Append guards/derivations | `orchestration/engine.go`                 | `validateEventInput` / `Engine.appendInput` |
| Session-status derivation | `orchestration/session.go`           | `deriveSessionStatus` (update-kind switch)    |
| Projection appliers       | `orchestration/projection.go`             | `Projection.Apply`                          |
| Provider side effects     | `orchestration/provider_event_reactor.go` | `ProviderEventReactor.handle`               |
| Runtime-event translation | `orchestration/ingestion.go`              | `ProviderRuntimeIngestion.Ingest`           |
| Thread-list visibility    | `orchestration/projection.go`             | `ThreadListVisible`                         |

Vocabulary: the engine has two write doors, both producing **events**
(`events.go`) — process-local notifications stamped by `Engine.stamp` for
live ordering. Events are not retained for transport replay.
**Commands** (`command.go`,
via `Engine.Dispatch`) are CLIENT intents: validated by a decider (which may
refuse them), retryable idempotently by `commandId` (receipts). **Event
inputs** (`EventInput`, via `Engine.AppendEvent`) are provider/server
observations appended nearly verbatim: nothing to refuse, nothing retries
them, no receipt. Session lifecycle changes use the private engine operation
in `session.go`: producers submit what they
observed (bound / turn-started / turn-settled / stopped / error) and the
engine derives the complete `SessionBinding` from the live thread inside its
locked write region — making it the single staleness/dedupe authority for
session status. A stale update (settle/error for a non-current turn, any settle
after the session stopped) is dropped: no event, `Sequence 0`, no error. The
appended event still carries the full binding, so the wire format is
unchanged and the projection applies it as a plain replace.

Conversation chronology is projection-owned: `Thread.Timeline` is appended in
the engine's observed event order. Streamed messages and item/approval lifecycle
updates mutate their existing tagged entry without moving it. Plans and session
metadata remain replace-in-place state outside the timeline. Event `sequence`
is authoritative for live ordering/deduplication, but clients render snapshots in
timeline array order and never reconstruct chronology from timestamps.

## Concurrency model

A round trip crosses several goroutines by design; a stack trace never shows
the whole flow. The handoffs, in order:

1. **RPC handler goroutine** (per request) → `Engine.Dispatch` blocks on the
   engine queue.
2. **Engine worker** (one goroutine, `engine.go`): the ONLY writer to the
   sequence and projection — single-writer, so deciders and appliers need
   no locking among themselves. Listeners run here too, so they must stay
   cheap (`publishOrchestrationEvent`) or immediately hand off (reactor).
3. **Reactor per-thread chains** (`enqueueThread`): provider RPCs for one
   thread run strictly in order, never overlapping; different threads run
   concurrently. Chaining on the previous tail is the only serialization.
4. **Adapter read loop** → per-instance event sink → providerservice `ingress`
   (buffered): blocking send = natural backpressure into the agent process.
5. **providerservice hub** (`runHub`, one goroutine): generation-filters and
   forwards to the `Events()` channel.
6. **Ingestion loop** (one goroutine): translates and re-enters through
   `Engine.AppendEvent` or the private queued session-update operation. Both
   use the engine queue, so they never mutate the sequence/projection directly.
7. **Per-client outbound writer** (`rpcClient.writeOutbound`): slow clients
   overflow their bounded queue and get disconnected rather than stalling the
   engine worker.

Failure isolation: reactor handlers, ingestion, and event listeners recover
panics independently, and the engine worker converts panics that fire BEFORE
anything was appended (decider/validation code) into command errors — one bad
command/event cannot wedge the daemon. A panic AFTER live state began
mutating (sequence assignment / projection apply) instead shuts the daemon down:
the sequence and read model may now disagree, and with no complete state to rebuild
from, failing fast is the only honest recovery. The engine reports a typed
`InvariantViolationError` (after replying to the in-flight caller) and closes
itself; the server's handler (`handleInvariantViolation`) records it and runs
the normal `Server.Close` — killing group-isolated agent processes —
and `RunWebSocket` returns the error, so `cmd/maiD/main.go` remains the sole
owner of `log.Fatal`/process exit.

Provider configuration is discovered on the real thread session, not via a
separate catalog read: the client creates an empty thread, then immediately
prepares its provider session (`thread.session.prepare`); that session
supplies the current/default model and authoritative configuration and is
reused for the first prompt. Dynamic options are resolved on that prepared
session: each successful option change replaces the advertised option set.

Provider process restarts are handled by **generation fencing**: every
`StartInstance` allocates a generation; the hub drops runtime events from
replaced generations except terminal events needed to settle work that ended
before a replacement session rebound. Sessions and runtime events carry their
generation internally, so ingestion rejects those old terminal events after
the replacement binding exists. `withThreadInstance` re-runs `StartSession`
(with the stored resume cursor) when a thread's route points at a stale
generation.

## Persistence (metadata only)

The daemon deliberately retains no historical transport event log. The
`Engine.stamp` (sequence.go) only assigns process-local ordering metadata before live
fan-out. What survives a restart is METADATA in `internal/store` (SQLite,
`$MAID_DATA_DIR` or the user config dir): sidebar thread rows, thread→session
routes with resume cursors, and provider instance specs. Providers own
conversation history; reopening a restored thread rebuilds its timeline by
loading provider-stored history through the normal ingestion pipeline when the
provider supports it. Metadata persistence, boot rehydration, history loading,
and explicit session import are implemented (`docs/PERSISTENCE_PLAN.md`).

Both write paths are write-through against in-memory truth and both are
optional (a nil store means in-memory only, the pre-persistence behavior):

- providerservice mirrors `threadRoutes`/`instanceSpecs` mutations through
  `store.RouteStore` (bind/release/stop/start-input updates), snapshotting
  current in-memory state under a store mutex so racing writers converge.
  Route generations are never persisted — fencing resets each boot.
- the daemon's engine listener marks threads dirty for user messages, explicit
  metadata changes, and model-changing config updates. An asynchronous writer
  goroutine (`threadMetaWriter`) promptly reads projection state and upserts
  `store.ThreadStore` rows, so the engine worker never blocks on SQLite.

## Terminal threads

Terminal threads live entirely outside the two agent-thread flows:
`internal/terminal` owns PTY shells, per-run native Ghostty attach models, and
agent detection, and `internal/daemon/terminal.go` composes them with RPC fanout
and the SQLite metadata store. Terminals never touch orchestration,
providerservice, or ACP; PTY output never enters the engine queue. The
implementation contract is `docs/TERMINAL_THREADS_SPEC.md`; the daemon-side
agent detection (foreground process + OSC signals + headless Ghostty VT
screen) is documented in `docs/TERMINAL_AGENT_DETECTION.md`.

## Known simplifications

- One provider driver (ACP). `daemon.openProviderInstance` is deliberately a
  plain switch — add a registry only when drivers become plugins.
