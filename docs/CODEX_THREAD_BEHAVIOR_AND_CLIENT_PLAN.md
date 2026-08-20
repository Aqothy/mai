# Codex thread behavior and maiD client plan

## Status and decision

This document records protocol and runtime behavior verified against Codex
Desktop `26.715.70719` with its bundled app-server `0.145.0-alpha.27`. The
renderer-scope and scroll-state implementation was rechecked in Desktop
`26.721.41059`. The desktop UI source was not available unminified, so findings
below distinguish shipped minified-renderer behavior, runtime traces, and
design recommendations.

The chosen maiD direction is Codex-like:

- reuse a cached per-thread model while it is trustworthy;
- keep a small number of inactive threads live-subscribed;
- never evict a running or interaction-blocked thread merely because it is
  hidden;
- after a subscription is lost, request an authoritative snapshot rather than
  replaying missed token/tool events;
- retain the complete ordered timeline but send bounded tool summaries, with
  full tool data loaded only when expanded.

Implementation status:

| Capability                                            | Status                                             |
| ----------------------------------------------------- | -------------------------------------------------- |
| Independently keyed Swift thread sessions             | Implemented                                        |
| Visible + five inactive idle subscriptions            | Implemented                                        |
| Hidden cached running/waiting subscription protection | Implemented                                        |
| 30-minute inactive-subscription TTL                   | Implemented                                        |
| Snapshot-only reopen and reconnect                    | Implemented in Swift and daemon protocol           |
| Conversation models retained for the app session      | Implemented; no count-based LRU                    |
| Complete compact history; no pages/cursors            | Implemented                                        |
| On-demand full tool detail by stable item ID          | Implemented                                        |
| Per-thread text composer draft persistence            | Implemented for new and existing Swift threads     |
| Client-local seen/unread markers                      | Implemented and persisted in Swift                 |
| Per-thread scroll-position restoration                | Removed; every remounted List opens at the bottom   |
| Restart-history presentation gate                     | Implemented with an explicit snapshot readiness flag |

The daemon protocol has one transport recovery path: subscribe with `threadId`
and receive an authoritative snapshot. Client resume cursors, restart tokens,
missed-event responses, event-range indexing, and their tests have been
removed. Provider history loading is a different server-side responsibility:
it rebuilds authoritative history after restart and remains active. Its
existing `thread.history-replay-completed` name refers to provider-owned
history materialization, not transport-event replay.

## 1. The three independent caches

Codex does not have a single four-thread cache. It has at least three relevant
layers with different lifetimes.

### 1.1 Conversation model cache

The renderer keeps conversations in a map keyed independently by canonical
thread ID. Navigating away does not normally remove the cached model. The map
can therefore contain more than four previously opened conversations.

This layer provides immediate content for warm navigation and can also provide
stale-while-revalidate content while an unsubscribed thread is being resumed.
No general count, time, or memory-pressure eviction for the conversation map
was found in the inspected build. Explicit archive, delete, and discard paths
do remove entries.

Codex does **not** appear to cache “the last 20 snapshots.” The inspected
20-entry limit applies to retained renderer/UI scopes. It is not a limit on
authoritative snapshots or on the conversation-model map.

### 1.2 Live subscription cache

Codex separately tracks which cached conversations still own a live app-server
stream. A thread becomes **inactive immediately** when its view is no longer
active; it does not wait one hour to become inactive.

An inactive subscription is removed when either:

1. there are more than four inactive owner subscriptions, in which case the
   oldest eligible inactive subscriptions are removed immediately; or
2. it has remained inactive for one hour.

The visible thread does not count toward the four inactive subscriptions.
Running threads and threads waiting for approval or user input are retained and
are not ordinary eviction candidates. Thus the client may simultaneously have
one visible thread, four idle inactive subscriptions, and additional hidden
running/blocked subscriptions.

Unsubscribing changes the conversation's resume state to `needs_resume`; it does
not normally delete the cached conversation model.

### 1.3 Per-thread UI state

Codex retains per-thread renderer/UI scopes separately, with a count limit of
20 in the inspected build. The minified renderer creates `ThreadScope` with
`retain: { max: 20 }`. This is the source of the number 20.

Codex does not keep 20 complete conversation views mounted. When the local
conversation component unmounts, its layout-effect cleanup writes keyed
restore state into the retained thread scope. A later mount receives that
state as its initial scroll offset and virtualized-list restore state. The
stored scroll state contains:

- distance from the bottom;
- the latest turn reference;
- virtualized-turn-list state.

Composer drafts are persisted per thread across application restarts. No
restart-persistent scroll keys were found.

The inspected renderer persists non-empty drafts in a map under
`composer-prompt-drafts-v1`, keyed by the canonical conversation/context key.
Clearing a draft deletes its entry. Draft retention is independent of live
subscriptions, the conversation cache, and the 20-entry renderer-scope cache;
no count-based draft pruning was found.

Codex's sidebar unread state is also client-owned. The inspected build persists
thread IDs per host under `unread-thread-ids-by-host-v1`, derives summary fields
such as `hasUnreadTurn` and `unreadMessageCount`, marks hidden conversations
unread on relevant turn completion, and broadcasts `threadReadStateChanged`
between windows. No server-side read receipt was found. This verifies the
sidebar unread/blue-dot behavior, not a distinct in-conversation divider.

## 2. Why an older-than-four thread can still open quickly

The four-thread limit is not a four-conversation model limit. An older thread
can have lost its live subscription while its conversation model and UI scope
remain cached.

Reopening such a thread can therefore:

1. paint cached content immediately;
2. issue `thread/read` and `thread/resume` in the background;
3. replace or reconcile the cached model with authoritative current state;
4. restore separately cached scroll/UI state.

That is expected to feel slightly slower than returning to the immediately
previous, still-subscribed thread, but significantly faster than the first open
after application launch. The app-server's disk caches and the operating
system's warm filesystem cache can further improve the repeated-open path.

## 3. Verified navigation timelines

### 3.1 Warm A to B to A

With A and B both cached and subscribed:

```text
A active
  A resumeState=resumed, streamRole=owner

A -> B
  A becomes inactive but remains resumed/owner
  B becomes active and is already resumed/owner
  no A or B history request is required

B -> A
  B becomes inactive but remains resumed/owner
  A becomes active and is already current
  no thread/read or thread/resume for A
```

### 3.2 Cold or unsubscribed B

```text
A -> B
  A remains cached and may remain subscribed
  B's cached model may paint immediately if one exists
  B thread/read(includeTurns: false)
  B thread/resume(excludeTurns: true, initialTurnsPage: newest 5)
  B becomes stream owner
  older history pages load progressively
```

This is authoritative state plus paged history, not a replay of every missed
notification.

### 3.3 Running A to B to A

```text
A is running
A -> B
  A remains subscribed despite being hidden
  A continues receiving message, reasoning, tool, plan, and status updates
  those updates are reduced into A's inactive cached model

B -> A
  A is already current
  no snapshot or missed-event replay is needed
```

Streaming hundreds of deltas while the subscription is healthy is normal: the
UI needs those deltas to present live progress. The inefficient case is
replaying hundreds of old deltas after a connection gap. Codex avoids that
catch-up replay by requesting current authoritative state after the stream is
lost.

If A completes while hidden, its completed model is already current. It then
becomes an ordinary inactive subscription and may later be evicted by the
four-thread or one-hour rule. Reopening it after that eviction uses the
snapshot/resume path.

## 4. History pagination

For a thread that needs resume, the inspected Codex build requests:

```text
thread/read
  includeTurns: false

thread/resume
  excludeTurns: true
  initialTurnsPage:
    limit: 5
    itemsView: full
    sortDirection: desc
```

The newest page is reversed into chronological display order. Remaining pages
are requested with `thread/turns/list`, normally in five-turn pages.

The current build generally drains all remaining pages in the background after
the newest page renders. This is progressive loading rather than permanently
bounded lazy history: it improves first paint and spreads decoding work out,
but the complete conversation is normally present eventually. A separate path
can request one older page when the user scrolls upward, and a feature flag can
suppress the automatic background drain.

Chosen maiD behavior differs deliberately: return the complete ordered timeline
in one snapshot, but project every tool kind to a bounded summary. Full tool
output, inline attachment data, and file diff/before/after text are requested
by stable thread/item ID only when the user expands that item. maiD does not
add turn pages, page cursors, or page-merge state.

## 5. Connection and restart behavior

Codex marks conversations as needing resume after its app-server connection is
replaced. The active conversation then follows the ordinary authoritative
read/resume path. No missed-event cursor was observed in this desktop flow.

For maiD:

- subscriptions belong to one WebSocket and are lost with it;
- keep cached models on disconnect so the UI does not blank;
- reconnect and obtain a fresh thread-list snapshot;
- resubscribe the selected thread and cached running/blocked threads first;
- resubscribe other warm inactive threads up to the subscription budget;
- buffer live notifications received between subscription registration and
  snapshot application, then apply only notifications newer than the snapshot
  watermark.

The daemon constructs authoritative state from its live projection. After a
daemon restart, persisted metadata restores thread stubs and
`thread.session.prepare` loads provider-owned display history when supported.
No historical transport events are retained; the live projection is the
authoritative snapshot source.

`ThreadDetailSnapshot.historyRestorePending` explicitly reports whether a
restored metadata stub is still being materialized. The field is optional on
the wire: omitted/false means ready, and true means the client must not infer
readiness from timeline contents. This matters when a second client subscribes
after some provider history has already arrived: that snapshot can be nonempty
but still incomplete.

The iOS restart flow is:

1. Subscribe and receive the daemon's immediate authoritative projection.
2. Install the snapshot and its `historyRestorePending` state.
3. If pending and no preparation is already active, dispatch
   `thread.session.prepare`; provider startup is part of that command.
4. Continue reducing ordered provider-history events into the retained model
   while showing `Restoring Chat…`.
5. Clear pending only on `thread.history-replay-completed`, then mount the
   List once with the complete content. A terminal error/stopped session hides
   the loader and exposes the existing recovery UI without falsely declaring
   the history complete.

The subscribe RPC is intentionally not held open until provider restoration
finishes. Keeping snapshot delivery immediate avoids coupling navigation to
provider startup latency or provider failure while the explicit readiness
field still prevents empty or partially restored history from flashing as a
finished chat.

### 5.1 Where the subscription policy lives in maiD

The daemon does not know which thread is visible, inactive, cached, or
protected. Each WebSocket owns a set of thread IDs in
`internal/daemon/rpc.go` (`rpcClient.threadSubscriptions`). Calling
`orchestration.subscribeThread` inserts one ID; calling
`orchestration.unsubscribeThread` removes only that ID; disconnecting drops
the entire connection-owned set. Event fan-out checks every ID independently.

The Swift client owns the cache policy in
`clients/swift/mai/Features/Threads/ThreadStore.swift`:

- navigation marks the prior session inactive but does not immediately
  unsubscribe it;
- the visible session, up to five idle inactive sessions, and any already
  cached running/waiting sessions remain subscribed;
- the sixth eligible inactive session is unsubscribed immediately;
- an eligible inactive session is also unsubscribed after 30 minutes;
- an unsubscribed model remains available for stale-while-refresh rendering
  for the rest of the app session;
- reconnect creates a new server subscription set and obtains snapshots for
  selected/protected/warm sessions.

No additional backend subscription rewrite is required for this policy. The
daemon already supports multiple independent subscriptions and has regression
coverage for multi-thread fan-out, targeted unsubscribe, reconnect snapshots,
and snapshot/live boundary ordering.

Running state and subscription state are orthogonal. The daemon continues a
provider turn and updates its authoritative projection even when no client is
subscribed. A subscription only controls whether that WebSocket receives the
live event stream. The Swift policy keeps every already-cached running or
interaction-blocked thread subscribed while connected, but this is a client
decision rather than a backend invariant. Consequently, a disconnected client
can have running server threads with no subscribers and recover them later from
authoritative snapshots.

There is no backend count cap on `threadSubscriptions`. If one connection has
15 hidden running threads, one visible thread, and five idle inactive threads,
its subscription set can contain 21 IDs. All 21 receive matching live events
and retain their conversation models. As hidden turns finish, they become
ordinary inactive candidates; the five-idle/30-minute policy unsubscribes the
oldest excess sessions without deleting their cached conversations.

## 6. Chosen maiD cache policy

Match the useful Codex conversation and subscription behavior while using the
mock/t3code-style single active chat view:

| Layer                         | Policy                                                 |
| ----------------------------- | ------------------------------------------------------ |
| Visible thread                | Always cached and subscribed                           |
| Hidden running/blocked thread | If already cached/opened, always cached and subscribed |
| Idle inactive subscriptions   | Five, oldest eligible first                            |
| Inactive subscription TTL     | 30 minutes                                             |
| Full in-memory thread models  | Retain without a count bound for the app session       |
| Per-thread UI/scroll state    | None                                                    |
| Composer draft                | Persist per thread                                     |
| Seen/unread marker            | Persist a local unread-ID set per server/account scope |
| Active scroll state           | One active List; remounted threads open at the bottom  |
| Expansion/selection state     | Not implemented                                        |
| Reopen while still subscribed | Reuse current model; no request                        |
| Reopen after unsubscribe      | Paint cached model, then authoritative snapshot        |
| Reconnect                     | Authoritative snapshot; no event replay                |
| History bootstrap             | Complete compact authoritative timeline                |
| Remaining history             | None; no client pagination state                       |

Conversation models have no count-based eviction, matching the inspected Codex
behavior and keeping navigation predictable. They are process-lifetime cache,
not durable storage; app termination clears them. The client should release
decoded images, audio, and other recreatable media under memory pressure rather
than coupling textual conversation retention to an arbitrary thread count.

There is no Swift 30-entry cache now. For example, after opening 100 idle
threads during one app process, `sessionsByID` may still contain 100 decoded
conversation models. Ordinarily only the visible thread plus the five newest
eligible inactive threads remain subscribed, with any hidden protected
running/waiting threads added outside that idle budget. Unsubscribing a session
changes only its `subscriptionState`; it does not clear its `thread` model.

The Swift chat uses one active `List`, matching `MockChatView` and t3code's
thread-keyed feed. Switching threads destroys the old List and creates the new
one at the bottom. `ChatScrollState` exists only for that active view's
bottom-follow and scroll-button behavior. Text drafts remain in their separate
persistent per-thread map. iOS task selection updates `selectedThreadID`
directly in the button action; it is not deferred behind an extra main-actor
task or executor yield.

## 7. Client model

Replace the single `selectedThread` projection with independently keyed
sessions:

```text
ThreadStore
  selectedThreadID
  sessionsByID: [ThreadID: ThreadSession]

ThreadSession
  complete process-lifetime thread model
  lastSequence
  subscriptionState
  inactiveSince
  bufferedItems
  shouldRestoreAfterReconnect
  historyRestorePending
```

History pagination is intentionally not part of this architecture. `ChatView`
owns one active `ChatScrollState`; `ThreadSession` contains no scroll or view
state.

`ThreadListEntry.updatedAt` is authoritative sidebar metadata and records the
most recent live user prompt. Conversation sessions do not synchronize a
second live copy of this value; sidebar sorting and timestamps read directly
from the thread-list subscription.

Subscription state vocabulary:

```text
subscriptionState:
  subscribedVisible
  subscribedInactive(since)
  subscribedProtectedRunning
  unsubscribed
```

Notifications must be routed by `threadID` into `sessionsByID[threadID]`, not
discarded merely because the thread is not selected.

## 8. Selection algorithm

When selecting B from A:

1. Mark A inactive immediately.
2. If A is running or blocked, protect its subscription.
3. Otherwise add A to the inactive-subscription LRU and enforce the five-entry
   and 30-minute limits.
4. Set `selectedThreadID = B` without deleting A's conversation model.
5. If B is subscribed/current, render it with no RPC.
6. If B is cached but unsubscribed, render cached content immediately and
   subscribe for an authoritative snapshot. A distinct synchronizing badge is
   not currently implemented.
7. If B is not cached, show the normal loading state and subscribe for an
   authoritative snapshot.
8. Buffer notifications until B's authoritative snapshot is installed.
9. Apply buffered events newer than the snapshot watermark.
10. If `historyRestorePending` is true, keep reducing provider-history events
    behind `Restoring Chat…` until the explicit completion event.
11. Render the complete compact timeline; request full tool detail only after
    explicit expansion.

The eviction pass must run after navigation, turn settlement, approval/input
resolution, and periodically while the app is active so that a protected
running thread becomes normally evictable after it finishes.

## 9. Server/API changes for compact tool detail

`ThreadDetailSnapshot` retains the complete `Thread.Timeline`, preserving one
simple authoritative replacement path. Its client projection replaces complete
tool data with bounded `ToolCallSummary` values for command execution, file
changes, MCP calls, and generic tool calls. The canonical server projection
keeps the full `Item`.

```text
orchestration.getItemDetail
  params: threadID, itemID
  result: complete current Item
```

Snapshots and live notifications use the same compact representation. The
client caches a fetched detail by the item's latest event `sequence`, so a
changed item invalidates the prior detail without relying on timestamp uniqueness.

## 10. Implementation plan

### Phase 1: multi-thread cache and live subscriptions — implemented

1. Add a `ThreadSession` type and `sessionsByID` to the Swift client.
2. Move projection, snapshot watermark, and buffering from global
   `ThreadStore` fields into each session. Keep the selected thread's load
   error in the store because it drives one visible recovery action.
3. Route live events by their payload thread ID.
4. Stop clearing the previous thread on selection.
5. Keep five inactive subscriptions and exempt running/blocked sessions.
6. Add the 30-minute inactive timer and deterministic LRU eviction.
7. Add unit tests for A to B to A, fifth-inactive eviction, TTL eviction,
   running-thread protection, and completion followed by eviction.

### Phase 2: snapshot-only recovery — implemented

1. On unsubscribe/reopen, call `orchestration.subscribeThread` with only the
   thread ID.
2. On WebSocket reconnect, resubscribe selected/protected sessions first.
3. Retain stale UI content until its authoritative replacement arrives.
4. Preserve the existing subscribe-before-snapshot and buffered-live-event
   race protection.
5. Test reconnect with the same daemon, daemon restart, events arriving during
   snapshot creation, and a running hidden thread.
6. Keep the protocol snapshot-only; do not add a second missed-event replay
   recovery path unless measurement demonstrates a concrete need.
7. Automatically reconnect connection failures. For an isolated thread
   snapshot failure, show an inline Retry button that requests one fresh
   authoritative snapshot instead of maintaining another retry loop.
8. Carry the optional `historyRestorePending` state in the detail snapshot.
   Do not infer restoration readiness from an empty timeline, missing session,
   latest turn, or sequence value. Keep an empty or partially restored
   timeline behind the restoration loader until the existing provider-history
   completion event arrives.

### Phase 3: compact tool detail — implemented

1. Keep complete tool items in the daemon projection.
2. Project all tool kinds into bounded summaries for snapshots and live events.
3. Add `orchestration.getItemDetail(threadId, itemId)`.
4. Render compact tool rows and load complete details only on expansion.
   Render the result as structured, bounded fields rather than encoding one
   potentially multi-megabyte tool object into a chat `Text`.
5. Cache complete detail by stable item revision and expose inline
   loading/Retry. Large text fields use bounded inline previews; the complete
   canonical item remains in the process cache.
6. Keep the full timeline in each snapshot; do not add pagination or cursors.

### Phase 4: drafts and read state — implemented

1. Implemented for the current single-endpoint client: `ThreadDraftStore` uses
   one Codable dictionary in app preferences, keyed by thread ID.
   Store only non-empty drafts; delete the key when the composer becomes empty.
   Do not tie draft eviction to subscriptions or conversation-cache retention.
   Add an explicit local server/account namespace if the client gains multiple
   endpoints or accounts.
2. Implemented for the current single-endpoint client: `ThreadReadStateStore`
   persists unread thread IDs in app preferences. A hidden thread becomes
   unread when its final queued turn completes or it requires attention, and
   selecting it clears the marker.
3. Implemented: surface unread state with a sidebar marker and bold title, plus
   explicit Mark as Read/Unread actions. It remains client-side; server receipts
   are only needed later for cross-device sync.
4. If multi-window support is added, publish local read-state changes so every
   window updates immediately.
5. Removed after on-device failures: do not retain per-thread List offsets,
   List instances, row views, or layout measurements. Remount at the bottom.
6. Release decoded attachment/media caches under memory pressure without
   deleting textual conversation models.
7. Verify drafts and unread state across A to B to A, process restart, turn
   completion while hidden, and explicit mark unread/read.

## 11. Expected trade-offs

### Performance and efficiency

- Warm subscribed navigation is immediate and requires no RPC.
- Older cached-but-unsubscribed threads paint immediately and revalidate in the
  background.
- Full RPC response envelopes, including authoritative thread snapshots, decode
  on concurrent execution before their transferred result is installed on the
  main actor. The routing envelope for each WebSocket frame also decodes away
  from the main actor while the receive loop preserves wire order. Small
  ordered live-notification reduction remains serialized on the main actor.
- A warm subscribed task selected directly changes synchronously. Compact
  iOS pushes a dedicated task destination in `NavigationStack`; iPad always
  uses `NavigationSplitView` and lets it collapse columns when constrained.
  New Chat is also its own destination and transitions in place to the created
  task after the first send. A cold task displays a titled loading state while
  snapshot transport and decode remain asynchronous.
- After daemon restart, any snapshot explicitly marked
  `historyRestorePending` displays `Restoring Chat…` while ordered provider
  history updates the retained model. This includes both an empty stub and a
  partially restored multi-client snapshot. The List mounts once at the
  restoration completion boundary, so its initial bottom anchor applies to
  complete content.
- Snapshot recovery avoids expensive replay of old streaming deltas.
- Compact tool projection removes collapsed rich output from initial transfer,
  decoding, layout, and retained conversation models.
- Explicitly expanded tool details incur their individual transfer once per
  item revision. A loader provides immediate feedback for the first request;
  repeated expansion of the same revision uses the cached detail without an
  RPC.
- Every conversation opened during the app session remains warm; recreatable
  decoded media is the first memory-pressure release valve.

### Simplicity and maintainability

- Snapshot-only recovery has one authoritative correctness path and removes
  restart-token/cursor/recovery-reducer invariants.
- Live reduction is still required while subscribed, but old events never need
  to be reconstructed after a gap.
- Subscription lifetime and conversation retention remain independent.
  Conversation models have no count policy, avoiding exemption rules and
  surprising reloads.
- Full-history snapshots avoid page cursors, page merging, upward-load
  coordination, and stale-page recovery.
- Explicit history readiness avoids fragile content heuristics and requires
  only one optional snapshot field plus the existing provider-history
  completion event. It does not introduce an epoch, resume cursor,
  `afterSequence`, or transport replay log.

## 12. Evidence locations

Installed Codex artifacts inspected during the investigation:

- `/Applications/ChatGPT.app/Contents/Resources/app.asar`
- `webview/assets/app-initial-BHB6SClA.js`, where the minified `ThreadScope`
  declaration contains `retain:{max:20}`;
- `webview/assets/local-conversation-thread-Bj5uKwgs.js`, where unmount cleanup
  stores `distanceFromBottomPx`, `latestTurn`, and `virtualizedTurnList`, and a
  later mount passes the cached offset and virtualized-list restore state;
- `webview/assets/thread-scroll-layout-BywaziyM.js`, which applies
  `initialOffset` to the newly mounted scroll container;
- renderer conversation-store and resume logic in the shipped
  `app-initial~...` JavaScript chunks;
- `local-conversation-thread-*.js` for per-thread scroll state;
- generated app-server v2 schemas for `ThreadReadParams`,
  `ThreadResumeParams`, and `ThreadTurnsListParams`;
- desktop runtime logs under
  `~/Library/Logs/com.openai.codex/2026/07/16` and `2026/07/21`.

Runtime tests verified warm navigation without detail RPCs, hidden running
updates, immediate oldest-idle unsubscribe after exceeding four inactive owner
streams, Codex's five-turn resume bootstrap/background loading, and snapshot
resume after app-server connection replacement. Those Codex pagination findings
are evidence about Codex, not a planned maiD feature.

Local t3code source provides a useful readiness precedent:
`packages/client-runtime/src/state/threads.ts` keeps a thread
`synchronizing` until an explicit synchronized completion marker, and
`packages/client-runtime/src/state/threads-sync.test.ts` covers updates arriving
before that marker. maiD adopts only the explicit-ready principle; it does not
adopt t3code's replay cursor machinery. Local Codex provider integration also
uses authoritative `thread/read(includeTurns: true)`/`thread/resume`
materialization rather than treating a nonempty body as proof of completion.
