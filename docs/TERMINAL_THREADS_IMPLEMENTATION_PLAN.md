# Terminal Threads v1 Incremental Implementation Plan

Status: Increments 0–9.5 are implemented. Attach now transfers an exact
`GHOSTSNP` model between daemon and client builds pinned to Ghostty
`7a9c369cf`: no raw replay, synthetic VT redraw, or replay input barrier
remains. The Swift package fork exposes transactional surface restore and the
client does not reveal the surface or apply newer output until installation
completes. Increment 10 release hardening remains. Agent detection covers all
embedded manifest agents. See docs/TERMINAL_AGENT_DETECTION.md for the
Increment 8 decision record, Increment 9 benchmark, and Increment 9.5 design.
Last updated: 2026-08-06
Companion specification: [TERMINAL_THREADS_SPEC.md](./TERMINAL_THREADS_SPEC.md)

## 1. Delivery rule

Implement one increment at a time. Every increment must leave the existing
agent-thread product working, keep the repository buildable, and have its own
acceptance check. Do not begin the next increment to hide unfinished behavior
in the current one.

Terminal threads remain separate from ACP, providers, and agent orchestration
throughout the plan. Networking authentication, tmux/zellij, tabs, splits,
durable sessions, and persisted terminal output are not prerequisites for any
increment.

The user-visible navigation entry should remain absent until Increment 5. The
earlier increments use unit tests, focused harnesses, or a development-only
entry point so partially implemented terminals do not appear complete.

## 2. Performance strategy

The completed feature parses a visible coding-agent terminal in three places:

1. the daemon's bounded Ghostty attach model preserves canonical state;
2. the daemon's zero-scrollback Ghostty detector derives shared agent status;
3. the attached Swift Ghostty surface renders pixels and handles interaction.

Each additional attached client owns one renderer. When every client detaches,
only the two passive daemon parsers remain. They perform no Metal rendering,
font shaping, SwiftUI work, or network serialization of cells. Keeping attach
and detection separate avoids scanning retained scrollback for classification
and keeps attach sequencing independent from debounced detector work.

Agent detection was introduced in two measured increments:

- Increment 8 added foreground-process plus OSC title/progress detection
  without a second terminal grid.
- Increment 9 added headless screen parsing for status cases that require the
  terminal's rendered bottom contents.

Increment 9 has a benchmark gate. If measured cost is unacceptable, stop and
choose an explicit product tradeoff—reduced detached-status accuracy or
agent-specific lifecycle integrations. Do not replace Ghostty with a homegrown
ANSI stripper or a server-to-client cell protocol.

Apply optimizations in this order, only when measurement justifies the next
one:

1. format/classify only dirty screens and suppress unchanged semantic output;
2. keep detector scrollback at zero and throttle formatting, while continuing
   to feed VT bytes in order;
3. reduce foreground-process probes for clean idle terminals;
4. if per-terminal detector memory is still material, instantiate the detector
   screen only for a recognized/suspected coding-agent foreground job and
   accept that it needs subsequent output before screen evidence is complete;
5. prefer a complete agent lifecycle integration when one becomes available.

Step 4 adds lifecycle and cold-initialization complexity, so it is not the
default v1 design. Do not couple classification to the bounded attach model or
optimize away a parser based only on intuition.

## 3. Increment overview

| Increment | Result | User-visible? |
| --- | --- | --- |
| 0. Dependency spikes | Renderer, PTY, and daemon Ghostty build risks resolved | No |
| 1. Swift renderer shell | Ghostty view works with host-managed fake I/O | Development only |
| 2. Daemon PTY core | One tested local shell session without RPC | No |
| 3. First end-to-end terminal | One live remote shell supports output, input, resize, and terminate | Development only |
| 4. Reattach lifecycle | Initial replay, sequencing, detach, reconnect, exit, and relaunch work | Development only |
| 5. Terminal threads product | Persisted metadata and terminal rows join the Threads list | Yes |
| 6. Multi-client control | Latest explicit attachment wins safely | Yes |
| 7. Apple-platform UX | Keyboard, IME, mouse, selection, links, and responsive layouts are polished | Yes |
| 8. Lightweight agent signals | Process and OSC title/progress produce shared status | Yes |
| 9. Screen-accurate agent status | Detached Codex/Claude status uses Ghostty-parsed bottom contents | Yes; feature complete |
| 9.5. Model-based attach | Attach transactionally installs the daemon VT's native GHOSTSNP model; raw replay and the client barrier retire | Yes |
| 10. Completion hardening | Performance, failure handling, accessibility, and docs meet release quality | Yes |

## 4. Increment 0 — dependency and packaging spikes

### Objective

Resolve the three risks that could invalidate the architecture before adding
production domain or UI code.

### Work

1. Add exact-pinned `libghostty-spm` through Xcode's package workflow. Do not
   hand-edit `project.pbxproj`.
2. Render `TerminalSurfaceView` with `InMemoryTerminalSession` on macOS, iPhone,
   and iPad using canned ANSI and alternate-screen output.
3. Verify its callbacks provide byte-exact input and rows/columns for resize.
4. Run a standalone `creack/pty` spike that launches `/bin/zsh`, writes input,
   receives output, resizes, and terminates the process group.
5. Pin `go.mitchellh.com/libghostty` and a compatible Ghostty source commit in
   a build spike.
6. Produce statically linked arm64 and x86_64 macOS daemon test binaries. The
   resulting program must not require an installed Ghostty dylib, Zig, CMake,
   or `pkg-config` at runtime.
7. Measure headless VT feeding and plain-text formatting with recorded Codex
   and Claude output, including an output burst.

### Exit checks

- Metal terminal content renders on all required Apple form factors.
- Software and hardware input reach the fake backend once, not twice.
- PTY resize changes `stty size` and full-screen applications respond.
- Both daemon architectures start and parse fixtures successfully.
- The benchmark establishes a written CPU/memory baseline for one and 25
  headless terminals.

### Stop condition

If either Ghostty package cannot be packaged reliably, stop and reassess the
dependency. Do not begin a custom terminal renderer or VT parser.

## 5. Increment 1 — isolated Swift Ghostty adapter

### Objective

Create the final client-side rendering boundary without involving networking
or the thread list.

### Work

Add the initial files under `clients/swift/mai/Features/Terminal/`:

```text
TerminalSessionController.swift
TerminalSurfaceHost.swift
TerminalThreadView.swift
TerminalStatusView.swift
```

`TerminalSessionController` owns stable `TerminalViewState` and
`InMemoryTerminalSession` instances. A fake backend feeds canned output and
captures input/resize.

Raw `Data` goes directly to `InMemoryTerminalSession.receive(_:)`. It must not
be stored in an `@Observable` property, passed through SwiftUI `body`, or copied
into a preview model.

Keep `TerminalSurfaceHost`, status chrome, and toolbar content as separate
`View` types with narrow inputs so lifecycle/status changes do not reconstruct
the terminal surface.

### Exit checks

- Repeated output does not invalidate terminal toolbar/status views.
- The controller retains one stable surface/session for its view lifetime.
- Input, resize deduplication, process-exit delivery, and teardown have focused
  Swift tests.
- macOS, compact iPhone, and regular iPad previews/harnesses render.

### Explicitly deferred

RPC, PTY ownership, persistence, replay, navigation, and agent status.

## 6. Increment 2 — daemon PTY core

### Objective

Build one correct local terminal session behind a small Go service, without
networking or persistence.

### Work

Create `internal/terminal` with PTY spawn, write, resize, output reading,
natural exit, terminate, and service shutdown. Use one serialized session
boundary and process-group cleanup.

Start the user's login shell in a validated cwd with the specified terminal
environment. Keep the API concrete; do not introduce a terminal driver or
generic process-launcher abstraction.

### Exit checks

- A Go test can launch a shell, execute a command, receive ordered output, and
  resize it.
- Natural exit and explicit termination close resources exactly once.
- Daemon/service shutdown kills all child process groups.
- Invalid cwd and invalid dimensions produce typed errors.
- `go test ./internal/terminal` passes without involving orchestration.

### Explicitly deferred

RPC, replay, run IDs, subscriptions, SQLite, multiple clients, and detection.

## 7. Increment 3 — first end-to-end live terminal

### Objective

Connect one Swift Ghostty surface to one daemon PTY through the existing
JSON-RPC/WebSocket transport.

### Work

1. Add the minimum terminal wire vocabulary and generated clients.
2. Add create, output subscription, write, resize, and terminate operations.
3. Add `RPCClient.notify` for write/resize notifications.
4. Add a separate `TerminalRPCClient` and `@MainActor @Observable`
   `TerminalStore` with a second WebSocket connection.
5. Route output notifications directly to the active
   `TerminalSessionController` outside observable state.
6. Expose the terminal through a development-only entry point.

### Exit checks

- A real shell prompt appears on macOS, iPhone, and iPad.
- Typing, paste, and resize round-trip through the daemon.
- A 10 MiB output command does not create an observed output string or freeze
  SwiftUI.
- Terminate closes the PTY and the client surface receives process exit.
- Existing agent-thread streaming behavior and tests remain unchanged.

### Explicitly deferred

Reconnect, replay, persistence, thread-list UI, multi-client attachment, and
detection.

## 8. Increment 4 — reattach and lifecycle correctness

### Objective

Make a live shell survive navigation, WebSocket loss, and iOS suspension while
remaining intentionally non-durable across daemon restart.

### Work

Add run IDs, monotonic output sequences, the 2 MiB replay buffer, the client
replay input barrier, attach snapshot ordering, local notification buffering
during attach, detach, reconnect, natural exit, stopped state, and relaunch.

Replay is the raw output stream; the daemon does not filter it. The client
renders replay behind an input barrier (a trailing DSR-5 sentinel with a
bounded timeout) so the renderer's reactions to historical bytes — device-query
answers, mode-enable reports, focus events — never reach the live PTY.

Keep output history only in daemon memory. Do not add a screen snapshot,
terminal transcript table, event-sourcing system, or tmux; synthesizing attach
state from a terminal model is Increment 9.5, after the daemon VT exists.
Replay rendered at a different grid than it was recorded at can mis-wrap until
the next real resize; that cosmetic limit is accepted here and removed by
Increment 9.5, not patched with repaint signals.

### Exit checks

- The snapshot/live race cannot lose or duplicate output.
- Navigating away detaches without killing the shell.
- Reconnect receives replay followed by live bytes in sequence order.
- Replayed device queries and mode changes produce no PTY input; the barrier
  releases on the sentinel answer and on timeout.
- Stale events from a previous run cannot affect a relaunched shell.
- Daemon restart loses the shell/output by design.
- Go and Swift reducer tests cover truncation and race boundaries.

### Explicitly deferred

Persistent metadata, visible terminal rows, multi-client attachment, and agent
detection.

## 9. Increment 5 — terminal threads as a product

### Objective

Turn the working terminal into a first-class top-level thread with persisted
identity and understandable lifecycle actions.

### Work

1. Add the `terminal_threads` SQLite table and terminal-specific store
   interface.
2. Add terminal-list snapshot/upsert/remove RPC items.
3. Add `TerminalSummary` and stable terminal selection/navigation identity.
4. Merge agent and terminal rows only in the presentation layer.
5. Add New Terminal and Open Terminal Here.
6. Add rename, relaunch, terminate, and delete actions with distinct copy.
7. Show persisted title, cwd summary, and lifecycle state.

Each terminal row receives only the equatable title/subtitle/status values it
renders. Terminal output never becomes an input to the list.

### Exit checks

- Terminal metadata survives daemon and app restart; process/output do not.
- Agent and terminal rows sort deterministically without terminal output
  changing `updatedAt`.
- Deleting either an agent thread or terminal never affects the other.
- Compact iPhone, regular iPad, and macOS navigation all open the correct item.
- The feature is useful at this point even though rich agent badges are absent.

### Explicitly deferred

Multi-client attachment, full package-input polish, and agent status.

## 10. Increment 6 — shared multi-client attachment

### Objective

Allow a terminal to stay open on multiple devices without adding ownership or
takeover state.

### Work

Track attached clients per terminal, fan output out to every listener, allow
any attached client to write or resize, and retain run-ID fencing. The most
recent resize wins.

### Exit checks

- Clients A and B can attach, receive the same output, and both write.
- The most recently processed resize determines the PTY grid.
- Disconnecting one client leaves the PTY and other listeners alive.
- Unattached and stale-run input/resize has no effect.
- Real multi-client WebSocket tests cover the behavior.

## 11. Increment 7 — Apple-platform terminal UX

### Objective

Validate and polish the interactions users expect from a real terminal while
relying on `libghostty-spm` wherever it already provides the behavior.

### Work

Validate software accessory keys, hardware modifiers, CJK/IME, selection,
copy/paste, mouse reporting, OSC 8 links, bell callbacks, scrollback, phone
rotation, keyboard resizing, iPad Split View/Stage Manager, and macOS window
resizing. Add a font-size setting, keep one fixed theme, and add only the minimal host UI the package
requires.

### Exit checks

- The platform acceptance matrix in the specification passes.
- Terminal-surface state remains isolated from toolbar and list invalidation.
- Accessibility labels exist for terminal actions and status overlays.
- No custom Metal renderer, display link, font shaper, or keyboard stack was
  added.

## 12. Increment 8 — lightweight shared agent signals

### Objective

Deliver useful background agent awareness without adding a second terminal
grid yet.

### Work

1. Track the foreground PTY process group and inspect it only when it changes.
2. Identify Codex and Claude command basenames, including recorded wrapper
   cases that can be supported reliably.
3. Extend the existing streaming replay escape scanner, or add one small
   bounded streaming OSC tracker, for OSC 0/2 title and OSC 9;4 progress.
4. Normalize observed titles and suppress spinner-frame churn.
5. Derive semantic `working`, `blocked` when explicitly signaled, `idle`,
   `done`, and `unknown` states.
6. Publish only changed `TerminalSummary` semantic fields.

Do not scan raw output with regular expressions and call it a terminal screen.
Do not add `go-libghostty` to the production daemon in this increment.

### Exit checks

- Agent identity clears when the login shell regains the foreground.
- Title/progress continues updating while no client is attached.
- One spinner does not create repeated list upserts or row invalidations.
- Recorded Codex and Claude title/progress fixtures document exactly which
  states are and are not recognized.
- The UI uses calm `Working`, actionable `Needs input`, persistent `Done`, and
  neutral unknown presentation.

### Decision record

At the end of this increment, compare recognized states with the required
fixture matrix. Record the missing cases that actually require current-screen
content. Increment 9 exists only for those concrete gaps, although it remains
required for the current v1 goal of Herdr-like bottom-screen detection.

## 13. Increment 9 — screen-accurate detached agent status

### Objective

Classify Codex and Claude states that cannot be determined reliably from
process, title, or progress signals while preserving accuracy after all clients
detach.

### Work

1. Add the exact-pinned Go binding and repository-owned static
   `libghostty-vt` build proven in Increment 0.
2. Create one passive, zero-scrollback Ghostty VT state for each live terminal.
3. Feed original PTY output in the session's existing serialized order.
4. Resize it with the PTY but never register its PTY-response callback.
5. Format only the current active screen after dirty output settles.
6. Add direct, fixture-backed Codex and Claude classifiers for bounded regions
   such as the bottom non-empty lines and active prompt controls.
7. Stabilize transient working-to-idle transitions.
8. Keep screen/title evidence out of RPC, SQLite, logs, and SwiftUI.

Do not add a generic manifest language, remote rule updates, hooks installer,
cell-grid protocol, renderer-state snapshot, or frontend status report.

### Exit checks

- Required Codex and Claude working, approval/question, idle, and done fixtures
  classify while the terminal has no attached client.
- Cursor movement, carriage returns, clear-screen, resize, and alternate-screen
  fixtures use the actual current screen rather than stale raw text.
- Continuous output formats at most twice per second; clean idle terminals do
  no formatting work.
- 25 detector sessions remain within the Increment 0 budget, or the budget is
  consciously revised with measured evidence.
- At the Increment 9 checkpoint, an attached client uses exactly two parsers,
  never one parser per SwiftUI row or subscriber. Increment 9.5 deliberately
  adds the separate bounded attach model measured by its own gate.

### Feature-complete checkpoint

After this increment, the functional v1 feature is complete. Increment 9.5
retires the replay compromise, and Increment 10 is release hardening, not an
opportunity to add scope.

## 14. Increment 9.5 — model-based attach from the daemon VT

### Objective

Replace raw-byte replay with the daemon headless Ghostty VT's native terminal
model, removing the artifacts no input barrier can fix. This is
the terminal-multiplexer architecture: the server owns a terminal model, and
attach receives current state, never history.

### Rationale

Raw replay re-feeds history into a fresh renderer. The Increment 4 barrier
stops that renderer from injecting reactions into the PTY, but one limit is
structural: bytes recorded at one grid render mis-wrapped at another, and no
repaint signal can fix it because the shell repaints relative to the
mis-placed cursor. This is not hypothetical: on iOS the surface reports a
provisional grid from an early SwiftUI layout (observed 32x11 against a
settled 39x35), so every attach briefly resizes the PTY to the wrong grid and
the repaint race leaves the prompt one row down until the next real resize.
With a server-side model this class is removed at attach, because the daemon
first applies the requested grid and then snapshots current model state instead
of asking the client to append byte history. Increment 9 established the
headless Ghostty build path; Increment 9.5 adds a separate bounded attach model.

### Work

1. Extend the per-terminal headless VT to retain the bounded scrollback attach
   needs, measured against the Increment 0 budget before adoption.
2. Export the attach payload with `libghostty-vt`'s authenticated binary
   snapshot format (`GHOSTSNP`). Do not use `FormatterFormatVT`: it is a copy
   formatter, not a lossless model-transfer protocol.
3. Pin daemon and client to the same exact Ghostty core revision and carry an
   explicit compatibility identifier on the wire because GHOSTSNP v1 is not
   stable across arbitrary commits.
4. Expose one transactional host-managed surface restore in the Swift package:
   decode and configure off the renderer lock, validate the captured grid,
   swap only a complete model, restore parser continuation, then return.
5. Keep live output streaming byte-identical; only the attach payload changes.
6. Delete the raw replay buffer and client barrier. Buffer live items above the
   snapshot sequence until asynchronous native installation completes.

### Exit checks

- Attaching after a full-screen application exits shows a clean prompt with no
  stray input at any grid size (the mode-2048 in-band-resize regression
  fixture).
- Attaching at a different grid than the recording renders without mis-wrapped
  prompt padding.
- Attaching mid-`nvim` reproduces the current screen and mode state, and
  typing works immediately.
- The native attach payload for a busy screen stays within a measured
  size and encode-time budget.
- No byte recorded in history can produce PTY input on attach, verified by
  fixtures rather than a query blacklist.

### Stop condition

Do not ship a synthetic formatter redraw or silently fall back to raw replay.
If exact native snapshot compatibility cannot be maintained, fail attach with
an actionable version error until the daemon and client can be upgraded
together or a supported upstream model-transfer API exists.

## 15. Increment 10 — release hardening

### Objective

Make the completed feature safe and predictable under failure and sustained
use.

### Work

- Run the full platform/manual matrix and multi-client tests.
- Profile continuous output, 25 sessions, repeated attach/detach, and memory
  release after delete.
- Verify detector failure degrades to a usable terminal with neutral status.
- Audit logs and SQLite for terminal contents and input.
- Update architecture/client API documentation.

### Exit checks

- Every acceptance criterion in `TERMINAL_THREADS_SPEC.md` passes.
- No unbounded output buffer, task, queue, or detector text survives teardown.
- Existing agent-thread performance and behavior show no regression.
- No deferred feature was pulled into v1 incidentally.

## 16. Commit and review boundaries

Prefer one focused change series per increment. Within a larger increment,
safe commit boundaries are:

1. domain/types plus unit tests;
2. wire definitions and generated output;
3. daemon behavior and integration tests;
4. Swift model/controller behavior and tests;
5. platform presentation and manual validation.

Never mix generated-client edits with unrelated UI cleanup. Never hand-edit
generated wire files or the Xcode project. Preserve the user's existing dirty
worktree and coordinate before touching overlapping navigation files.
