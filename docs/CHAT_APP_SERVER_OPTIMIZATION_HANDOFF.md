# Handoff prompt: optimize maiD chat performance

## Round 3 results (2026-07-30) — read before repeating work

> **Superseded for image message attachments:** maiD now preserves inline data
> for `kind: "image"` in client snapshots and events so clients can render ACP
> image content like Zed. The measurement below remains historical evidence for
> non-rendered attachment kinds; do not restore blanket image-data omission.

Implemented and measured:

1. Non-rendered message attachment bytes no longer echo back through client snapshots or
   live events. The canonical Go projection still retains attachment `data`
   for provider dispatch and failed-turn Retry, while the client projection
   keeps only `kind`, `name`, `mimeType`, and `uri` — the only fields currently
   rendered by both clients. For one 8 MiB non-rendered attachment on M2 Pro, client-event
   projection plus JSON encoding fell from a median 8.23 ms and roughly
   8.6 MB allocated to 1.01 µs and 1,072 bytes allocated; the wire payload fell
   from approximately 8,388,887 bytes to 269 bytes. Snapshot projection plus
   encoding similarly fell from a median 8.17 ms to 1.36 µs and 338 wire bytes.
   This removes an engine-worker stall, an outbound-queue-sized payload, and a
   process-lifetime duplicate of the base64 string in each warm client model.
2. Xcode snippet measurement of the Swift live-notification decoder, which
   runs on the main actor for ordered small events: the old 8,388,900-byte
   attachment fixture decoded in 6.02 ms median / 6.16 ms p95 / 9.42 ms max;
   the metadata-only 282-byte fixture decoded in 0.012 ms median / 0.017 ms
   p95 / 0.022 ms max. This is the client-side benefit of the server projection;
   no duplicate Swift sanitizer or custom decoder was added.
3. The remaining compact snapshot server phases are not a useful optimization
   target. A 44-file-change synthetic thread measured 8.5–10.2 µs for
   projection alone and 81.9–84.9 µs for projection plus JSON marshal
   (28,127 wire bytes). The earlier ~40.9 ms physical-device RPC interval is
   therefore not evidence of Go projection/marshal CPU time.

Measured and REJECTED:

- Swift reasoning reduction for 300 × 400-byte deltas (117 KB final text)
  measured 3.53 ms median / 5.19 ms p95 / 5.75 ms max for the entire
  300-event replay. A mutable custom payload would add correctness and Codable
  complexity for microseconds per live event.
- Formatting the growing reasoning JSON for the same 300 updates cost 39.8 ms
  total; per-update p95 was 0.244 ms and max 0.433 ms. Keep the current simple
  renderer unless a Release SwiftUI trace attributes a real layout hitch to a
  large visible reasoning row.
- Go assistant-message accumulation for the same 117 KB turn measured
  1.64–1.70 ms total. It allocates about 19.1 MB cumulatively because Go
  strings are immutable, but that work is spread across 300 flushes over the
  turn; replacing the domain string with a mutable accumulator is not justified
  without a GC or per-event trace showing a hitch.
- WebSocket compression is lower priority after compact tool projection and
  attachment-byte omission. The remaining normal snapshots/events are small
  on a loopback-first daemon, so compression adds interoperability and CPU
  risk without a measured user-visible win.

Verification:

- `go test ./...`
- `go test -race ./internal/orchestration`
- `go vet ./...`
- Xcode physical-device build-for-testing on iOS 26.5.2
- all 62 Swift tests passed; Xcode Issue Navigator reported no warnings
- `git diff --check`

Remaining unknowns that still require evidence:

- Release/Profile Animation Hitches traces for native iPhone navigation and
  realistic visible streaming; DEBUG snippets do not measure SwiftUI text
  layout or AttributeGraph frame cost.
- ACP pending-approval `args` can theoretically contain a large raw tool call.
  Do not truncate approval context (a safety surface) without a real payload
  trace and a lazy full-detail design.
- Multi-client jsonrpc2 notification wrapping still repeats raw-payload scans
  per subscriber, but it remains irrelevant to the ordinary single-client
  local daemon.
- Canonical server retention of attachment data is intentional for Retry.
  Disk-backed blobs or post-settlement eviction would need explicit retry and
  provider-lifecycle semantics, not an opportunistic memory clear.

## Round 2 results (2026-07-30) — read before repeating work

Implemented and measured (Go benchmarks on M2 Pro, `go test -bench` in
`internal/orchestration` and `internal/adapters/acp`; both files are kept as
regression guards):

1. Reasoning-stream projection made linear. `appendPayloadText` splices the
   escaped chunk into the text-only payload in place instead of a decode/
   encode cycle per flush, and ingestion's `turnState.reasoning`/
   `reasoningPending` are byte accumulators instead of string `+=`.
   A 300-flush / 117 KB reasoning turn on the engine worker went from
   89.2 ms and 59.1 MB allocated to 0.40 ms and 0.71 MB (~220×). Fast-path
   equivalence is pinned by `TestAppendPayloadTextMatchesDecodeEncodeSemantics`.
2. ACP tool-call accumulation is typed. `toolCallPatch` replaces the
   JSON-overlay (`overlayToolCallData` re-encoded the whole accumulated blob,
   including full file old/new text, on every sparse update — 4 marshal round
   trips). A 64 KB file edit across 5 updates went from 6.02 ms / 1.67 MB /
   316 allocs to 0.72 ms / 0.29 MB / 38 allocs (~8×). Chunk events also no
   longer marshal `Data: marshalRaw(u.Content)` per delta (it had no reader);
   plan/usage/info events keep their diagnostic `Data`.
3. Swift observation isolation. `ThreadStore.sessionsByID` is
   `@ObservationIgnored`; the selected-thread computed properties observe
   `selectedSessionGeneration`, bumped only when a mutation changes what they
   return. A hidden subscribed thread streaming at full rate no longer
   invalidates the visible `ChatView`.
   `hiddenThreadEventsDoNotInvalidateSelectedThreadObservers` proves both
   directions with `withObservationTracking`.
4. Swift streaming append is in place. The `threadMessageSent` reducer branch
   mutates through the storage subscript, so accumulated message text keeps a
   single reference (amortized O(chunk) instead of a full copy per chunk),
   and attachments are only touched when the event carries some.
5. `ThreadSession.apply` evaluates `isProtected` (two full timeline scans)
   only for event types that can change turn/session/approval state — not per
   streamed message/item chunk.
6. `ChatView` row identity is a `ChatRowIdentity` enum wrapping the existing
   ID string; the per-event List diff no longer builds one interpolated
   String per row.
7. Outbound JSON-RPC encoding runs off the main actor (`RPCClient.encode`,
   `@concurrent`, `sending` params), mirroring the decode path; a multi-MB
   base64-attachment `thread.turn.start` no longer escapes JSON on main.

Measured and REJECTED — do not redo without new evidence:

- `SubscribeThread` holding the engine mutex during snapshot projection:
  measured 10 µs for a 44-file-change thread (previews share backing arrays;
  nothing large is copied). Not a stall source.
- `ThreadListSnapshot` approval scans: 3 µs for 30 × 40-entry threads.
- Timeline `Message/Item/Approval` reverse scans and the Swift
  `lastIndex(where:)` equivalents: scan distances at realistic thread sizes
  are trivial; index maps add invariants for no measurable win.
- Draft-persist debounce, `humanized()` memoization, `projectedText`
  caching, composer line-count caching: all µs-scale at their trigger rates.
- Display-cadence scroll coalescing: forbidden by the scroll handoff without
  device traces; `scrollTo` per selected-thread event remains.

Remaining unknowns for a future round (need a physical device or multi-client
load): jsonrpc2 notification fan-out re-serializes the marshaled payload per
subscriber (2 byte copies + 2 escape scans in the fork's `NewNotification`/
`EncodeMessage`) — irrelevant single-user, relevant for many clients;
unbounded server retention of full tool payloads per thread (eviction/spill
was deliberately skipped for a single-user local daemon); on-device
re-verification of the DEBUG stream-apply diagnostics after the observation
split; WebSocket compression (handoff priority 5) still unevaluated.

---

Use this prompt for the next agent:

> Optimize the maiD iOS chat client and Go daemon for cold thread loading,
> warm thread switching, streaming, scrolling, and memory. Work only in the
> Work only in the Swift client and Go backend.
>
> Read `/Users/aqothy/Code/Personal/maiD/AGENTS.md` and
> `/Users/aqothy/Code/Personal/maiD/clients/swift/AGENTS.md` completely before
> editing. Also read:
>
> - `docs/CODEX_THREAD_BEHAVIOR_AND_CLIENT_PLAN.md`
> - `docs/chat-scroll-handoff.md`
> - `docs/ARCHITECTURE.md`
> - `docs/CLIENT_API.md`
>
> Preserve the chosen architecture:
>
> - one active SwiftUI `List`, keyed/remounted per selected thread;
> - process-lifetime in-memory conversation models;
> - subscriptions bounded separately as visible + five idle inactive with a
>   30-minute TTL + already-open running/blocked threads;
> - cached subscribed reopen performs no detail RPC;
> - reconnect or reopen after unsubscribe obtains a fresh authoritative
>   snapshot;
> - `ThreadDetailSnapshot.historyRestorePending` explicitly gates daemon-
>   restart history materialization; never infer readiness from timeline
>   contents;
> - no transport replay, event epoch, or `afterSequence` recovery;
> - snapshot boundary plus buffered live events where `sequence` is newer;
> - complete ordered timelines in snapshots, with no pagination or cursors;
> - bounded summaries for every tool kind in snapshots and live events;
> - full tool data only through `orchestration.getItemDetail`, cached by
>   thread/item revision;
> - per-thread persistent drafts and local seen/unread state remain separate
>   from List/view lifetime.
>
> Already implemented and measured — review these paths for regressions, but
> do not repeat the same refactors:
>
> 1. JSON-RPC routing and full-response decoding moved off the main actor while
>    preserving receive order.
> 2. `ThreadSession.apply` mutates in place, avoiding full timeline
>    copy-on-write on every streamed event.
> 3. Conversation models persist for the process; live subscriptions alone use
>    the visible + five idle/30-minute TTL + protected-running policy.
> 4. Reconnect/unsubscribed reopen uses one authoritative snapshot plus
>    buffered newer live events; transport replay, event epochs, cursors, and
>    `afterSequence` were removed.
> 5. Every tool kind uses a compact snapshot/live summary; full detail uses one
>    generic `orchestration.getItemDetail` RPC and a revision-keyed client
>    cache.
> 6. Expanded tool detail uses structured bounded sections instead of dumping
>    a complete JSON object into one `Text`.
> 7. Production uses one native virtualized `List`, stable row identities, one
>    initial bottom owner, and no per-thread raw scroll-offset cache.
> 8. The old sidebar `Task.yield()` and streaming bottom-request cascade were
>    removed; the measured yield did not coalesce work and caused
>    multiple-updates-per-frame diagnostics.
> 9. Compact-width iOS uses a native `NavigationStack`: the task-list root
>    pushes either a dedicated New Chat destination or a task destination.
>    iPad always uses `NavigationSplitView`, which owns its compact-column
>    collapse when space is constrained. The old drawer is retained only as
>    an unused future option.
> 10. After daemon restart, a snapshot marked `historyRestorePending` keeps
>     provider-restored events behind `Restoring Chat…`; the List mounts once
>     after `thread.history-replay-completed`. This also covers a nonempty but
>     partial snapshot observed by another client. A terminal error/stopped
>     status exposes recovery UI instead of an endless loader. Do not replace
>     the explicit flag with empty-timeline/session/latest-turn heuristics.
>
> Do not keep all chat views alive, reuse one List across unrelated thread
> identities, or restore raw per-thread List offsets without new device
> evidence. Do not modify `MockChatView.swift` to accommodate production
> transport behavior.
>
> Start from measured evidence, not guesses. Current physical-device baseline
> on iPhone 14 / iOS 26.5.2 / DEBUG:
>
> - cold 106-row thread: 3,344,491-byte snapshot, selection 1.43 ms, loader
>   visible 50.47 ms, RPC receive 807.05 ms, off-main full decode 26.05 ms,
>   List mount 17.68 ms, total 929.74 ms;
> - cold 7-row thread: 28,390 bytes, total 92.80 ms;
> - warm 106-row reopen, 10 samples: total median 35.88 ms, p95 48.67 ms,
>   max 54.66 ms;
> - warm 7-row reopen, 10 samples: total median 48.22 ms, p95 49.70 ms,
>   max 49.84 ms.
>
> The same 106-row task after compact projection measured:
>
> - 75,414-byte snapshot, selection 1.57 ms, loader 40.81 ms, RPC receive
>   40.89 ms, off-main decode 2.69 ms, List mount 19.32 ms, total 128.30 ms;
> - versus the physical baseline: 97.75% fewer bytes and 86.20% less
>   tap-to-first-layout time;
> - warm long reopen, 7 samples: total median 52.81 ms, p95 56.45 ms;
> - warm short reopen, 6 samples: total median 42.12 ms, p95 45.25 ms;
> - a 204,641-byte file-change detail: 46.32 ms receive and 2.50 ms decode;
> - re-expanding that revision: no second RPC.
>
> A historical 25-second physical Animation Hitches trace found no
> potential-hang records for drawer-only cycles, but every sampled task switch
> performed during the
> drawer transition produced one. Long-task cases were approximately 150–177
> ms and short-task cases 60–100 ms in this DEBUG/Instruments run, dominated by
> SwiftUI layout and AttributeGraph work. Treat this as evidence for where to
> profile a Release build, not permission to keep every chat List alive.
>
> Before the drawer was retired from the active iPhone path, it started an
> uncached subscription immediately, closed with a deterministic 220 ms
> ease-out, and published selection only after animation completion. Measured
> selection commit was 253–258 ms; a warm cached reopen then mounted in
> 15.17 ms with no RPC. A follow-up physical trace removed the earlier
> 150–177 ms combined stalls but still reported separate 98–117 ms
> List-remount delays under DEBUG/Instruments. Keep these measurements and the
> retained implementation as the reactivation reference; benchmark the active
> native push path separately.
>
> The original raw full-detail renderer was also defective: it JSON-encoded
> large before/after contents into one `Text`, creating a giant blank row and
> about 160 ms of main-thread work. `ChatView` now renders structured,
> bounded tool-detail sections (8,000 characters per large text preview and at
> most ten inline file changes) while retaining the complete canonical result
> in the revision cache.
>
> The pre-compaction aggregate breakdown of a separate 3,320,951-byte long
> snapshot:
>
> - timeline: 3,301,222 bytes;
> - all items: 3,278,957 bytes;
> - file-change items: 3,267,548 bytes;
> - file-change tool calls: 3,254,326 bytes;
> - messages: 22,158 bytes;
> - 44 file changes contain 1,509,803 bytes of `oldText` and 1,534,293 bytes
>   of `newText`;
> - repeated old/new/diff string values account for 1,302,189 duplicate bytes.
>
> Relevant paths:
>
> - `internal/provider/contract.go`: `FileChange`, `ToolCall`;
> - `internal/adapters/acp/convert.go`: `toolChangesFromACP`;
> - `internal/orchestration/client_projection.go`: compact tool summaries;
> - `internal/orchestration/api.go`: snapshots and item-detail params;
> - `internal/orchestration/engine.go`: `SubscribeThread`;
> - `internal/daemon/rpc.go`: subscription/event projection and item-detail RPC;
> - `clients/swift/mai/Network/RPCClient.swift`: ordered off-main decoding;
> - `clients/swift/mai/Features/Threads/ThreadStore.swift`: model retention,
>   subscriptions, snapshot/event installation, and revision-keyed detail cache;
> - `clients/swift/mai/Features/Chat/ChatView.swift`: active List, compact tool
>   rows, expansion loading, and Retry;
> - `clients/swift/mai/Features/Chat/ChatPerformanceDiagnostics.swift`.
>
> Prioritize work in this order, but verify each boundary before committing to
> a large refactor:
>
> 1. Complete the remaining compact-detail measurements: command, MCP, and
>    generic tool items plus a Release/Profile structured-expansion trace.
>    Cold snapshot, warm switching, one file-change detail, and cache-only
>    re-expansion are already measured above.
> 2. Instrument Go snapshot build, JSON marshal, write/flush, and response
>    byte phases. The old 807 ms and new 40.89 ms client intervals combine
>    server and network costs; do not pretend either identifies one phase.
> 3. Use SwiftUI Instruments to determine whether hidden subscribed sessions
>    invalidate the visible chat through `sessionsByID`. Only then consider
>    independently observable session reference models.
> 4. Use Animation Hitches to measure native navigation and streaming. If the
>    retained drawer is re-enabled, repeat its historical combined
>    drawer/List-remount trace. Only add display-cadence coalescing when traces
>    prove the need; never use arbitrary sleeps or `Task.yield()` as a
>    coalescer.
> 5. Consider WebSocket compression only after verifying interoperability with
>    `URLSessionWebSocketTask` and measuring both network savings and client/
>    server CPU.
>
> Do not add turn pagination, page cursors, missed-event replay, or event epochs.
> Compact complete-history snapshots plus on-demand item detail are the chosen
> complexity/performance trade-off.
>
> UX requirements:
>
> - every tap must be acknowledged synchronously;
> - desktop/direct selection publishes synchronously;
> - compact iOS pushes a native New Chat or task destination immediately;
> - iPad keeps the task list and detail in `NavigationSplitView`, allowing the
>   system to collapse columns when space is constrained;
> - cached content paints immediately after that navigation transition;
> - missing content shows `Loading Chat…`; a snapshot explicitly marked as
>   restoring shows `Restoring Chat…` until its ordered completion boundary;
> - an individual snapshot failure shows inline Retry; connection loss uses the
>   existing reconnect path;
> - no animated top-to-bottom correction when opening a thread;
> - opening starts at the bottom unless a separately justified semantic
>   navigation target is requested;
> - streaming follows only while the user is already following the bottom;
> - no `onChange`/scroll-geometry multiple-updates-per-frame diagnostics.
>
> Benchmark before and after on the same physical iPhone, OS, daemon, fixed
> short/long threads, and network. Use a Release Instruments run for shipping
> claims and the existing privacy-safe DEBUG diagnostics for regression
> timings. For warm navigation, discard one warm-up and collect at least 20
> A → B → A cycles. Report median, p95, maximum, snapshot/page bytes, row/turn
> counts, server phase timings, decode time, first-content time, hitch count,
> and peak memory. iPhone Mirroring may drive the UI, but only app timestamps
> and Instruments data count as benchmark evidence.
>
> Acceptance targets:
>
> - direct model-selection work under 8 ms, excluding native navigation
>   animation;
> - cached tap-to-first-layout p50 under 50 ms and p95 under 100 ms;
> - cold first content materially earlier and initial bytes materially smaller
>   than the 3.34 MB baseline;
> - no main-thread stall over one frame from snapshot decoding;
> - stream projection p95 under 2 ms;
> - no multiple-updates-per-frame diagnostics or visible navigation/chat
>   hitch;
> - complete snapshot/detail/live-boundary correctness tests, including a
>   nonempty partial restart snapshot that remains gated until completion;
> - no replay/epoch/dead compatibility code.
>
> Keep fixes simple, reviewable, and provider-neutral. Remove superseded code
> only after tests prove the new path. Do not edit the Xcode project or
> generated files manually; change the canonical Go wire contract and run its
> generator. Use Xcode MCP for builds, issue navigation, and Apple
> documentation when available; use normal file tools for reads/edits. If
> Xcode MCP is unavailable, state that and use `xcodebuild`.
>
> Run and report:
>
> - Swift unit tests and a device/simulator build;
> - focused compact-snapshot, snapshot/live-boundary, subscription, detail-fetch,
>   and reconnect tests;
> - `go test ./...`;
> - `go test -race` for touched concurrent Go packages;
> - formatting/lint and `git diff --check`.
>
> At handoff, separate implemented improvements, measured improvements,
> rejected ideas, and remaining unknowns. Do not claim an optimization without
> before/after evidence.
