# Swift new-chat draft flow handoff

> **Retracted draft architecture.** The prepared server-draft design in this
> document has been replaced by `docs/CLIENT_LOCAL_DRAFT_PLAN.md`. Draft text
> and selections now stay local; disposable ACP options sessions provide live
> configuration only, and `thread.start` creates the real thread on Send. The
> materialized-draft details below remain only as historical context.

## Purpose

Continue the Swift new-chat work with the smallest design that is correct under
normal use, WebSocket reconnects, and daemon restarts while preserving generic
ACP dynamic session configuration.

Do not add polling, sleeps, duplicate retry loops, transport event replay, or
speculative protocol machinery. Prefer one authoritative path and explicit UI
states.

Read before changing code:

- `docs/CODEX_THREAD_BEHAVIOR_AND_CLIENT_PLAN.md`
- `clients/swift/AGENTS.md`
- staged and working-tree diffs; the working tree contains review fixes that are
  not staged yet

## User requirements

- Keep the prompt editable while the agent is preparing.
- Disable provider, ACP-agent, CWD, config, and Send controls while preparing,
  starting, or sending.
- Provider and CWD may change while the thread is still a draft.
- Provider and CWD become immutable after the first turn starts; changing them
  then requires New Chat.
- A non-empty CWD is required before creating or preparing a backend draft.
- Choose CWD in this order:
  1. last successfully used CWD;
  2. most recently used CWD from existing threads;
  3. ask the user.
- Configured CWD presets are explicitly out of scope for now.
- Preserve generic ACP modes/models/config options returned dynamically by the
  prepared session.
- Reconnect behavior must use authoritative snapshots, not cached state as
  proof that a server object still exists.
- Optimize for simplicity, correctness, and maintainability before micro-
  optimizations.

## Retracted constraint: why the draft was previously assumed to require the server

T3 Code keeps a new-thread draft entirely local and atomically creates the
server thread with the first turn. That is simpler, but maiD cannot copy it
without losing generic ACP dynamic config before first Send.

ACP agents commonly return modes and config options from `session/new` and
subsequent session updates. ACP has no standard pre-session "describe config"
request. Therefore maiD needs a real prepared ACP session before showing the
full generic configuration UI.

This conclusion was too strong. A disposable unbound ACP session can provide
the dynamic catalog without becoming the draft or the real thread session.
Selections are reconciled against the authoritative real `session/new` result
on Send, while ACP defaults provide the safe fallback for values that are no
longer valid.

## Reference implementations inspected

### T3 Code: local-only pre-thread drafts

Repository: `~/Code/Personal/t3code`

Key locations:

- `apps/server/src/ws.ts:684-890`

Useful idea: separate editable client draft state from server thread state and
materialize atomically on first Send.

Not directly usable: it does not need the same generic ACP session-returned
configuration before first Send.

### Zed: strict ACP loading state

Repository: `~/Code/Personal/zed`

Key locations:

- `crates/agent_ui/src/conversation_view.rs:735`
- `crates/agent_ui/src/conversation_view.rs:1096-1235`
- `crates/agent_ui/src/conversation_view.rs:3340`
- `crates/agent_servers/src/acp.rs:1465-1484`
- `crates/agent_ui/src/agent_panel.rs:2941-3035`

Useful ideas:

- require a project/CWD before `session/new`;
- represent creation as a loading state;
- store the load task with the view so dropping the view cancels it;
- do not permit interaction with a half-created session;
- treat primary session CWD as creation-time identity.

### Agmente: local placeholder followed by ACP materialization

Repository: `~/Code/Personal/Agmente`

Key locations:

- `Agmente/ServerViewModel.swift:344-349`
- `Agmente/ServerViewModel.swift:513-586`
- `Agmente/ServerViewModel.swift:846-929`
- `Agmente/ServerViewModel.swift:1139-1352`
- `Agmente/ACPSessionViewModel.swift:157-344`
- `Agmente/SessionDetailView.swift:735-805`
- `ACPClient/Sources/ACPClient/ACP/ACPClientManager.swift:217-245`

Useful ideas:

- create a local placeholder identity first;
- never send a prompt with an unresolved placeholder ID;
- migrate state only after `session/new` returns the real ID;
- render dynamic typed config from the real ACP session;
- invalidate connection-scoped materialization state on reconnect.

maiD already controls the thread ID sent to `thread.create`, so it does not need
Agmente's placeholder-to-different-server-ID migration. Reusing the same client-
generated thread ID is simpler.

## Current implementation state

The staged change introduces the draft prompt UI and server-backed draft flow.
The working tree contains additional review fixes. Inspect the actual diff; do
not assume all working-tree changes are staged.

Current behavior after the working-tree fixes:

1. `ThreadDraftStore` persists the local prompt under a stable client-generated
   draft thread ID.
2. The client loads the authoritative thread-list snapshot and provider
   catalogs before publishing `.connected`.
3. The draft chooses remembered CWD, then the most recent unique thread CWD.
4. With no CWD, the prompt remains editable, preparation does not begin, and
   Send is disabled.
5. Once provider and CWD exist, SwiftUI starts structured draft preparation.
6. Provider, ACP-agent, CWD, config, and Send controls are disabled while
   preparing/starting/sending; the prompt editor remains available.
7. The backend draft is created with the same client-generated ID, subscribed,
   and prepared so dynamic ACP config can be displayed.
8. First Send starts the turn and promotes `draft` to false.
9. A provider-only draft change clears/releases the prior session through the
   existing server provider-switch path and prepares the new provider.
10. A CWD draft change stops the current session, updates metadata, and prepares
    again. This is slower but required by the current ACP/session contract.
11. Thread-state waits are event-driven and cancellation-aware; there is no
    polling.
12. The previous unstructured `draftPreparationTail` queue has been removed.

Build status at handoff: the Xcode project built successfully after these
changes. The active Xcode test plan exposed zero tests, even though
`clients/swift/maiTests/maiTests.swift` exists; investigate test-plan/scheme
configuration without manually editing generated project files.

## Authoritative draft restoration: current solution

The server thread-list snapshot includes both ordinary threads and drafts, but
the sidebar must not display drafts.

`ThreadStore` currently partitions the snapshot into:

- `threads`: sidebar-visible non-draft entries;
- `draftEntriesByID`: authoritative draft entries keyed by ID.

This is intentional and efficient:

- draft existence lookup is O(1);
- the sidebar does not repeatedly filter all entries;
- no entry is duplicated between the two collections;
- both collections are updated only in the centralized thread-list snapshot and
  update reducers.

On draft restoration:

- ID in `draftEntriesByID`: the server still has the draft; subscribe and reuse;
- ID in `threads`: it was promoted; open the real thread;
- ID in neither: the cached detail model is stale; discard it and allow the
  draft to be recreated from local prompt/provider/CWD state.

Do not regress to checking `sessionsByID` as proof that a draft exists. That is
a process-lifetime client cache and can outlive the daemon object after a daemon
restart.

## Reconnect model

The protocol currently cannot distinguish a temporary WebSocket reconnect from
a daemon process restart; there is no daemon instance/epoch ID.

The current safe policy is to treat every new connection generation as needing
authoritative revalidation:

- fresh thread-list snapshot;
- fresh provider catalog before interactive draft UI;
- replacement authoritative snapshots for restored subscriptions;
- rerun draft reconciliation after connection transitions back to connected;
- preserve local prompt and preferences.

This addresses the known draft restart bug. A daemon instance ID is optional
future optimization, not required for this draft fix. Do not add it unless a
broader cache invalidation requirement is demonstrated.

## Remaining work not yet implemented

### 1. Replace implicit booleans with one small preparation state

`DraftPromptModel` still coordinates `isPreparing`, `canRetryPreparation`, an
active UUID, task keys, and selected backend state. This works but is harder to
reason about than one explicit state.

Consider a minimal state such as:

```swift
enum DraftPreparationState: Equatable {
    case selecting
    case preparing
    case ready
    case failed(String)
}
```

Keep the enum small. Do not reproduce backend session statuses in the view
model. The store remains authoritative for whether a draft is ready.

Desired transitions:

```text
no provider/CWD -> selecting
valid setup -> preparing
prepared matching draft -> ready
preparation error -> failed
Retry -> preparing
first turn -> normal non-draft ChatView
```

Only introduce this if it removes existing flags and task-key complexity; do
not layer it on top as another source of truth.

### 2. Make failed setup changes unambiguous

The picker currently represents the requested provider/CWD before the server
operation succeeds. `draftIsReady` correctly blocks Send when displayed setup
does not match the authoritative prepared draft, but failure UX should be
explicit.

Choose one simple policy and test it:

- preferred: on failure, keep the requested setup visible, show the error, keep
  Send disabled, and let Retry apply that setup; or
- revert the picker to the last successfully prepared setup.

Do not show a requested provider/CWD while allowing Send through the previous
session.

### 3. Use an explicit connection generation for restore-once semantics

`DraftPromptModel` currently resets `didAttemptDraftRestore` when connection
state is not connected. This relies on observing the expected state transition.

A clearer optional improvement is a monotonically increasing
`connectionGeneration` in `ThreadStore`, incremented after each successful
initial bootstrap. Store the last restored generation in `DraftPromptModel`.
Then each connection is reconciled exactly once without inferring generation
from booleans.

Only implement this if it simplifies code and tests. Do not add a daemon epoch
at the same time.

### 4. Handle an unexpectedly stopped/error draft session

A draft that becomes `stopped` or `error` without a provider/CWD selection
change currently becomes unsendable. The selection-based preparation key may
not trigger again.

Prefer an explicit visible Retry action over an automatic retry loop. Do not
add session-status polling. A retry should run the same single preparation path.

### 5. Add focused tests

At minimum cover:

#### CWD selection and gating

- remembered CWD wins;
- otherwise most recent thread CWD wins;
- no available CWD leaves the local prompt editable;
- no available CWD dispatches no `thread.create` or session prepare;
- Send remains disabled until a non-empty CWD is prepared.

#### UI/preparation serialization

- a second preparation call is ignored/blocked while one is active;
- controls are disabled during preparation and sending;
- prompt editing remains available;
- cancellation from navigation removes any registered thread-state waiter;
- a new preparation can proceed after cancellation.

#### Provider/CWD changes while draft

- provider-only change releases/clears the old binding and prepares the new
  provider;
- CWD change waits for successful stop, updates CWD, and prepares again;
- stop failure exits with an error instead of waiting forever;
- setup mismatch or failure never enables Send.

#### Reconnect/restart

- reconnect to the same daemon reuses the existing draft;
- missing draft after daemon restart discards stale cached detail and recreates
  from the local ID/prompt/setup;
- draft promoted while disconnected opens the promoted thread;
- local prompt survives each case;
- stale provider and ACP registry entries are replaced before the draft becomes
  interactive;
- a transient subscription failure is not incorrectly treated as authoritative
  absence when the thread-list snapshot still contains the draft.

#### Dynamic config

- session-returned config options render after preparation;
- remembered config is applied only to the matching provider;
- navigation during a config request does not save the value under a different
  provider;
- config cannot be changed while preparation is active.

### 6. Investigate why Swift tests are not in the active test plan

`clients/swift/maiTests/maiTests.swift` contains tests, but Xcode tools reported
zero configured tests. Follow `clients/swift/AGENTS.md`: do not manually edit the
Xcode project or autogenerated files. Report if scheme/test-plan changes require
user action.

## CWD change performance

Changing CWD for an already prepared draft remains inherently slower than a
local picker update because the ACP session was created with the original CWD.
ACP has no generic request to move a live session to another primary CWD.

Keep the current correct sequence under a loader:

```text
stop old draft session
update thread CWD
prepare the draft session again
```

Do not create replacement draft IDs, parallel provider sessions, or background
orphan cleanup merely to hide this latency. Those approaches add lifecycle and
resource-leak complexity.

A server optimization could combine session clearing and CWD metadata update,
but the provider still must release the old session before safely preparing the
new one. Implement only if measurement shows the extra command boundary matters.

## Approaches intentionally not recommended now

- Fully local T3-style draft: loses authoritative generic ACP dynamic config.
- Placeholder-to-new-ID migration copied from Agmente: unnecessary because maiD
  controls and reuses its thread ID.
- Polling session state or sleeping before retries.
- Automatic retry loops for isolated preparation/config/snapshot failures.
- Creating a replacement server draft on every provider/CWD change.
- Parallel old/new ACP sessions without provider session-generation support.
- Hard-coding a local `maiD` CWD preset in the Swift client.
- Adding daemon instance identity before a demonstrated need beyond existing
  authoritative reconnect handling.

## Suggested implementation order

1. Preserve and build the current working-tree behavior.
2. Make the test target runnable or report the project configuration blocker.
3. Add focused tests for current behavior before further refactoring.
4. Introduce a small preparation state only if it deletes existing flags and
   simplifies transitions.
5. Clarify failure/Retry UX and cover it with model tests.
6. Add explicit connection generation only if tests show restore-once logic is
   unclear or fragile.
7. Stop when the behavior is correct; avoid speculative server/API work.

## Acceptance criteria

- The client builds under Swift 6.2 strict concurrency.
- A prompt can be typed and persisted without provider/CWD or backend session.
- No backend draft is created until provider and non-empty CWD are selected.
- Exactly one preparation operation is active at a time.
- Provider/CWD/config/Send controls are unavailable during preparation; prompt
  editing remains available.
- Dynamic ACP config appears from the prepared session.
- Send is enabled only when prompt, provider, CWD, and authoritative prepared
  draft all match.
- Provider/CWD changes work only while draft and are locked after first Send.
- CWD stop failure returns a visible error and never hangs.
- Reconnect uses authoritative server state and preserves local prompt text.
- Missing server draft is recreated; existing or promoted draft is not
  duplicated.
- No polling, sleeping, redundant task queue, or duplicate retry owner is added.
- Focused tests cover normal flow, failure, cancellation, and reconnect.
