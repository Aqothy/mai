# Terminal Threads v1 Specification

Status: implemented through Increment 9.5; release validation remains
Last updated: 2026-08-06

## 1. Summary

maiD will add terminal threads as top-level peers of agent threads. A terminal
thread represents one interactive shell running in a pseudo-terminal (PTY) on
the macOS daemon. The Swift app renders that shell locally with Ghostty on
macOS, iPhone, and iPad.

The v1 design intentionally favors a small, maintainable implementation:

- one terminal thread owns one shell;
- the macOS daemon owns the shell and PTY;
- `libghostty-spm` renders the terminal locally with Ghostty and Metal;
- a passive, headless `libghostty-vt` instance on the daemon derives terminal
  title and coding-agent activity from the live terminal state;
- the existing JSON-RPC/WebSocket transport carries terminal bytes, input, and
  resize messages;
- every attached client may interact with the shared terminal;
- a bounded, passive Ghostty model exists only in daemon memory and is
  transferred on attach with Ghostty's native snapshot format;
- SQLite persists terminal metadata, never terminal output;
- a client disconnect does not terminate the shell;
- a daemon restart terminates every shell;
- no tmux, zellij, server-side pixel rendering, terminal multiplexer, durable
  checkpoint, tab, split, or multi-client role/arbitration layer is introduced.

This document is the implementation contract for v1. Later features should not
complicate these boundaries without concrete usage showing that the added
complexity is worthwhile.

## 2. Terminology: what “synchronization” means

The word synchronization is overloaded. This feature distinguishes three
different mechanisms.

### 2.1 Terminal I/O synchronization

The daemon sends PTY output to a client, and the client sends input and resize
events to the daemon. This is synchronization in the broad product sense.

maiD v1 implements this.

### 2.2 Rendered terminal-model synchronization

An authoritative terminal emulator publishes its current grid, cursor,
terminal modes, alternate-screen state, scrollback, hyperlinks, and parser
continuation to clients. Clients restore that canonical state into a compatible
renderer.

maiD v1 implements this at attach with Ghostty's native `GHOSTSNP` model
format. The daemon never renders pixels and does not define a custom cell-diff
protocol. It keeps a bounded headless Ghostty attach model, while each Apple
client restores that model into its local Ghostty renderer and then consumes
live PTY output.

### 2.3 Raw output replay

The first implementation sent previously emitted output to a fresh renderer,
which independently reparsed history before consuming live output. That design
was removed: it could repeat historical device queries, could not reproduce a
model after truncation, and produced cursor/mode errors and visible attach
flashes. PTY input is still not part of the snapshot; only PTY output updates
the shared terminal model.

Client input is not broadcast to other clients. Input is written to the shared
PTY, and any resulting PTY output is sent to every attached client. This
distinction matters because a process may disable echo; a password or other
non-echoed keypress produces no output for another renderer to observe.

## 3. Settled product decisions

| Concern | v1 decision |
| --- | --- |
| Apple renderer | Exact-pinned `libghostty-spm` fork |
| Ghostty package version | `Aqothy/libghostty-spm` `1.4.1`, Ghostty core `7a9c369cf5da72d41946f683c48b0466a210cb7e` |
| Rendering implementation | Package-owned Ghostty Metal renderer |
| Daemon platform | macOS only |
| PTY implementation | A small `internal/terminal` service using `github.com/creack/pty` |
| Shell | User's default shell, falling back to `/bin/zsh` |
| Terminal identity | Top-level terminal thread, independent of agent threads |
| Terminal count | One shell per terminal thread |
| Agent relationship | “Open Terminal Here” copies cwd; no durable parent relationship |
| Client ownership | No controller role; every attached client may write and resize |
| Disconnect | Detach that client's listener; keep PTY running |
| Daemon restart | Kill all PTYs; persisted metadata becomes stopped |
| Persistence | Metadata only |
| Output history | Bounded scrollback inside the daemon's in-memory Ghostty attach model |
| Cold attach | Transactional native GHOSTSNP restore plus sequenced live output |
| Resize | Required on initial attach and whenever grid rows/columns change |
| Networking | Existing local transport first; Tailscale/Cloudflare security is separate work |
| Ghostty on backend | Separate passive headless models for attach state and agent detection; never pixel rendering |
| Go Ghostty binding | Exact-pinned `go.mitchellh.com/libghostty` behind `AgentDetector` |
| Multiplexer | None |
| Tabs/splits | Deferred |
| Scrollback | Bounded daemon Ghostty scrollback transferred into client-owned Ghostty scrollback |
| Scrollback search | Deferred |
| Agent detection owner | macOS daemon |
| Agent detection engine | Passive headless `libghostty-vt`, with no renderer and no PTY-response callback |
| Agent detection persistence | None; only current-daemon-run semantic state |
| Initial detected agents | Codex and Claude Code; add others through small profiles after fixtures exist |

## 4. Goals

v1 must:

1. Run a real interactive login shell on the Mac.
2. Render ANSI/VT output through Ghostty on macOS, iPhone, and iPad.
3. Support interactive TUIs such as `vim`, `less`, and process monitors across
   detach and reattach through native model restoration.
4. Support software and hardware keyboard input, IME composition, terminal
   modifiers, selection, copy/paste, mouse reporting, and links through the
   package's native integration.
5. Keep a shell running when its view disappears or an attached client
   disconnects.
6. Reattach to a live shell with its bounded Ghostty model restored exactly.
7. Present terminal threads alongside agent threads with clear status and
   destructive actions.
8. Avoid routing terminals through provider or ACP abstractions.
9. Keep high-frequency terminal bytes out of SwiftUI observation and the
   agent-thread projection.
10. Close every PTY and child process when the daemon shuts down.
11. Detect whether Codex or Claude Code owns the foreground terminal job and
    show `Working`, `Needs input`, `Done`, or `Idle` in the thread list even
    when no client is displaying that terminal.
12. Keep terminal title/content detection off the UI hot path and publish only
    semantic changes to SwiftUI.

## 5. Non-goals

v1 does not provide:

- survival across daemon restarts or Mac reboots;
- tmux/zellij integration;
- multiple tabs or splits inside one terminal thread;
- multi-client roles, input arbitration, or resize arbitration;
- server-side pixel rendering or a custom cell-diff synchronization protocol;
- persisted transcripts or terminal output logs;
- command auditing;
- terminal output search;
- shell-command execution APIs for agents;
- ACP filesystem or terminal capabilities;
- Linux or Windows daemon support;
- public-internet authentication, pairing, TLS provisioning, or relay hosting;
- automatic import of Ghostty configuration;
- a generic “driver” abstraction for terminal backends;
- reliable notification of arbitrary shell-command completion before shell
  integration exists;
- a remotely updatable agent-rule language or plugin system;
- persistence of detected agent state, screen evidence, or terminal titles.

## 6. High-level architecture

```text
SwiftUI terminal thread view
        |
        v
TerminalSurfaceHost
  - TerminalViewState (package integration object)
  - InMemoryTerminalSession
  - Ghostty Metal surface
        |
        | input bytes / rows + columns
        | output snapshot / live output bytes
        v
TerminalStore + TerminalRPCClient
        |
        v
existing JSON-RPC over WebSocket
        |
        v
daemon/rpc.go
        |
        v
internal/terminal.Service
  - persisted metadata lookup
  - live session map
  - shared client attachments
  - bounded passive Ghostty attach model
  - passive headless Ghostty VT detector
  - foreground-job and agent-activity classifier
        |
        v
macOS PTY + login shell
```

The native snapshot format crosses the wire, but renderer ownership does not.
The daemon knows about byte streams, PTY dimensions, process lifecycle,
metadata, a bounded Ghostty attach model, and a separate private text grid for
detection. It knows nothing about client surfaces, fonts, SwiftUI, or Metal,
and it never defines or sends a custom terminal-cell protocol.

## 7. Repository boundaries

### 7.1 New Go package

Create `internal/terminal` with narrowly scoped files such as:

```text
internal/terminal/
  service.go          live-session and metadata operations
  session.go          one PTY run and its lifecycle
  pty_darwin.go       macOS PTY creation, resize, and process termination
  vtscreen/           passive Ghostty detection and native attach models
  detector.go         agent detection and debounced scans
  detector_rules.go   small, compiled-in Codex/Claude classifiers
  process_darwin.go   foreground process-group and executable identification
  types.go            internal IDs, statuses, and event types
  *_test.go
```

`internal/terminal` must not import `internal/orchestration`,
`internal/providerservice`, `internal/provider`, or `internal/adapters/acp`.
Terminals are not providers and terminal input is not an orchestration command.

The daemon is the composition root. `Server` owns one terminal service and
connects it to RPC fanout and the SQLite metadata store.

### 7.2 Store boundary

Add a terminal-specific persistence interface in `internal/store`:

```go
type TerminalStore interface {
    UpsertTerminal(TerminalMeta) error
    DeleteTerminal(terminalID string) error
    ListTerminals() ([]TerminalMeta, error)
}
```

The existing SQLite implementation implements this interface. Do not add
terminal-only fields to the agent `threads` table and do not add fake provider
instance IDs for terminals.

### 7.3 Wire boundary

All client-visible terminal types and methods belong in `api/wire`. Add them to
the generated method and notification registries and run `make generate`.
Generated Swift files must not be edited manually.

### 7.4 Swift feature boundary

Add a separate feature directory:

```text
clients/swift/mai/Features/Terminal/
  TerminalStore.swift
  TerminalRPCClient.swift
  TerminalSessionController.swift
  TerminalSurfaceHost.swift
  TerminalThreadView.swift
  TerminalThreadRow.swift
  TerminalStatusView.swift
  TerminalSettings.swift
```

Platform-specific navigation composition remains under `Platform/iOS` and
`Platform/Desktop`.

Do not place terminal transport or renderer state inside `ThreadStore`.

## 8. Swift package decision

Use `https://github.com/Aqothy/libghostty-spm` at exact version `1.4.1` and
link the `GhosttyTerminal` product. The workspace's SwiftPM mirror redirects
the original package identity to this fork without a hand-edited Xcode project.
Both this package and the daemon pin Ghostty core commit
`7a9c369cf5da72d41946f683c48b0466a210cb7e`.

The upstream package already supplies the Ghostty core, Metal renderer,
CoreText shaping, host-managed I/O, UIKit/AppKit views, SwiftUI integration,
and native input/selection/clipboard behavior. The narrow fork adds one
missing capability: transactional restoration of a host-provided native
GHOSTSNP model into `InMemoryTerminalSession`.

maiD owns a small adapter around the package. Application and transport code
do not call the Ghostty C API directly; the package's
`InMemoryTerminalSession.restore(snapshot:)` wrapper contains that boundary.
The app awaits restoration before revealing the surface or applying live
output.

The package exposes `TerminalViewState` as an `ObservableObject`. That remains
inside the integration wrapper; maiD's own shared models use `@Observable`.

Keep the fork as a small reviewed patch stack over upstream. Upgrade the daemon
binding, Ghostty core, package binary, snapshot compatibility identifier, and
Swift package tag together. Do not track either upstream main independently.

### 8.1 Daemon Ghostty dependency

Use the exact-pinned `go.mitchellh.com/libghostty` Go binding for a passive
`libghostty-vt` terminal on the macOS daemon. Pin both the Go module commit and
the compatible upstream Ghostty C library commit; do not follow either main
branch implicitly.

The Go binding is used because it already provides terminal creation, VT byte
feeding, resize, OSC title/progress callbacks, and plain-text formatting. maiD
must wrap it behind an internal `Detector` interface so binding churn does not
spread through the terminal service.

The binding uses cgo and a repository-built static `libghostty-vt`. The pinned
build recipe and compatibility check live in the repository; release artifacts
must not require end users to install Zig, Ghostty, or `pkg-config`.

Both daemon Ghostty models are deliberately passive:

- do not register `WithWritePty` or forward terminal response bytes;
- do not let either model answer PTY queries;
- do not render from either model;
- keep the detector at zero scrollback and never expose its evidence;
- keep bounded scrollback only in the attach model;
- serialize attach-model access with sequence assignment and resize;
- serialize detector access inside the detector.

The client Ghostty surface remains responsible for interactive rendering and
its normal host-managed input path. The attach model provides canonical state
only when a client joins; the separate detector model keeps shared agent state
available after navigation, disconnection, or iOS suspension.

## 9. Server domain model

### 9.1 Persisted terminal metadata

```go
type TerminalMeta struct {
    ID        string
    Title     string
    Cwd       string
    CreatedAt time.Time
    UpdatedAt time.Time
}
```

Only these values are durable.

Do not persist:

- PID;
- process status;
- attachment/client ID;
- rows or columns;
- output or input;
- attach sequence;
- run ID;
- exit code;
- shell process handles.

### 9.2 Live session

Conceptually, one live session contains:

```go
type Session struct {
    MetaID              string
    RunID               string
    PTY                 *os.File
    Command             *exec.Cmd
    Status              Status
    Columns             uint16
    Rows                uint16
    Sequence            uint64
    AttachVT            SnapshotScreen
    Detector            *AgentDetector
    AgentActivity       AgentActivity
    ObservedTitle       string
    ControllerClientID  string
    ExitCode            *int
    StartedAt           time.Time
}
```

The exact locking strategy is implementation-owned, but every field above is
process-local. A daemon restart reconstructs only `TerminalMeta` rows and
reports them as stopped.

### 9.3 Status vocabulary

Use these client-visible statuses:

- `starting`: shell spawn is in progress;
- `running`: PTY accepts input;
- `exited`: process ended naturally; its final attach model remains available
  in this daemon run;
- `stopped`: metadata exists but no live run exists, normally after daemon
  restart or an explicit termination;
- `error`: spawn or PTY operation failed.

Unknown future values must decode without crashing the client and render as a
neutral unavailable state.

### 9.4 Coding-agent activity vocabulary

Agent activity is separate from the shell lifecycle status above. A terminal
may be `running` while its agent is `idle`, `blocked`, or absent.

```go
type AgentKind string

const (
    AgentNone    AgentKind = ""
    AgentCodex   AgentKind = "codex"
    AgentClaude  AgentKind = "claude"
    AgentUnknown AgentKind = "unknown"
)

type AgentActivityState string

const (
    AgentActivityNone    AgentActivityState = "none"
    AgentActivityIdle    AgentActivityState = "idle"
    AgentActivityWorking AgentActivityState = "working"
    AgentActivityBlocked AgentActivityState = "blocked"
    AgentActivityDone    AgentActivityState = "done"
    AgentActivityUnknown AgentActivityState = "unknown"
)
```

Wire/UI wording maps `blocked` to “Needs input”. This is clearer to users and
covers approvals, questions, and permission prompts without claiming the
reason is known.

`done` is presentation state, not a literal terminal escape sequence. Derive
it when an agent that was working returns to idle/the shell while the terminal
is detached. Keep it until the next explicit attach, which acknowledges it.
When the same transition happens while the terminal is visibly attached, show
`idle` instead.

Do not infer `failed` from arbitrary terminal text. The child agent generally
runs beneath a shell, so the terminal service does not reliably own its exit
code. A recognized agent with insufficient evidence is `unknown`, never a
confident error.

## 10. SQLite persistence

Add a separate table to the existing SQLite schema:

```sql
CREATE TABLE IF NOT EXISTS terminal_threads (
    terminal_id TEXT PRIMARY KEY,
    title       TEXT NOT NULL DEFAULT '',
    cwd         TEXT NOT NULL,
    created_at  TEXT NOT NULL,
    updated_at  TEXT NOT NULL
) STRICT;
```

Ordering uses `updated_at DESC, terminal_id`, matching the deterministic
thread-list pattern.

`updated_at` changes only when the user performs an identity-level action:

- create;
- relaunch;
- rename;
- explicitly open a stopped terminal.

Do not update it for every PTY output chunk, keypress, resize, attach, or
background reconnect. A noisy shell must not continuously jump to the top of
the sidebar.

Termination keeps the row. Deletion removes it.

## 11. PTY lifecycle

### 11.1 Dependency

Use `github.com/creack/pty` rather than implementing Darwin PTY ioctls by hand.
It provides macOS PTY creation, initial sizing, and resize operations while
remaining much smaller than a terminal emulator or multiplexer dependency.
Pin the selected Go module version when implementation begins.

### 11.2 Shell resolution

Resolve the shell in this order:

1. a valid absolute executable path in `SHELL`;
2. `/bin/zsh`.

v1 does not expose arbitrary executable/argument selection in the UI. It
starts one interactive login shell. This keeps terminal creation predictable
and prevents the metadata schema from becoming a generic process launcher.

### 11.3 Working directory

- Resolve an empty cwd to the current user's home directory.
- Clean and absolutize the path.
- Require it to exist and be a directory before spawning.
- Return an actionable invalid-cwd error rather than silently falling back.
- “Open Terminal Here” sends the agent thread's current cwd as a copied value.

The terminal remains independent after creation. Later changes to the agent
thread do not change the terminal cwd.

### 11.4 Environment

Inherit the daemon's user environment, remove daemon-only authentication
secrets when such secrets are introduced, and override:

```text
TERM=xterm-256color
COLORTERM=truecolor
TERM_PROGRAM=maiD
```

Use `xterm-256color` for v1 compatibility. Do not require Ghostty terminfo to
be installed on the Mac.

### 11.5 Initial size and resize

Create the PTY with the client's measured rows and columns. If measurement is
not yet available, use `80x24` temporarily and apply the first measured size
immediately afterward.

Validate dimensions before conversion:

- columns: 2 through 500;
- rows: 1 through 300.

The client sends resize only when rows or columns change. Pixel dimensions do
not cross the wire in v1.

Resize is required for:

- phone rotation;
- iPad Split View and Stage Manager;
- macOS window resizing;
- keyboard appearance/disappearance;
- safe-area or toolbar changes;
- terminal font-size changes.

### 11.6 Termination

Explicit termination and daemon shutdown must close the PTY and terminate the
entire shell process group, not only the shell leader. Use graceful termination
with a short bounded grace interval, followed by forceful termination if
children remain.

Natural process exit changes status to `exited` and retains the final attach
model until explicit termination, relaunch, deletion, or daemon shutdown.

Relaunch kills any remaining old process group, releases the old attach model,
allocates a new run ID, resets sequence to zero, and starts a fresh shell in
the persisted cwd.

### 11.7 Coding-agent detection

#### Ownership

The daemon is the sole authority for agent identity and semantic activity.
This is required because a terminal may keep running after its Swift view is
destroyed, its client disconnects, or iOS suspends the app. The Swift Ghostty
surface may still use title callbacks for local presentation, but it must not
classify or report agent state.

Frontend-only classification is explicitly rejected for the shared thread
list: it would freeze as soon as the user navigated away and different clients
could disagree about the same terminal.

#### Data path

For every non-empty coalesced PTY output batch, the session performs these
operations in order:

1. under the session lock, assign the output sequence and feed the original,
   unchanged bytes to the bounded attach model;
2. feed the same bytes to the separately serialized passive detector and mark
   detection content dirty;
3. fan out the original bytes to attached Swift clients.

Snapshot encoding holds the session lock, so its model and sequence describe
the same point in the stream. Resize updates the PTY, attach model, and detector
to the same rows and columns. Pixel values use stable dummy cell dimensions
because neither daemon model renders.

#### Why the completed design has separate parsers

While a coding-agent terminal is visibly attached, the attach model, detector,
and each Swift renderer parse the PTY byte stream once. This duplication is
intentional and bounded:

- the attach model owns bounded canonical state for future joins;
- the zero-scrollback detector produces shared semantic state while clients are
  absent without scanning retained history;
- each Swift parse owns Metal rendering, shaping, selection, input modes, and
  local interaction;
- when all clients detach, only the two passive daemon parsers remain.

The apparent single-parse alternatives are worse for this product:

- client-only parsing loses status after navigation, disconnect, or iOS
  suspension;
- server-only pixel rendering or a custom cell-diff protocol would discard the
  package's native renderer and input integration;
- switching status authority between frontend and backend requires a terminal
  state handoff and introduces disagreement/races during attach;
- raw-tail regexes do not represent a terminal screen;
- agent lifecycle hooks are faster when complete, but Codex and Claude do not
  currently expose complete enough lifecycle coverage for all approval,
  interrupt, and idle transitions.

The two daemon models have distinct policies and lifetimes, so they stay
separate rather than coupling attach correctness to classification. The
detailed rollout and performance gates are recorded in
[TERMINAL_THREADS_IMPLEMENTATION_PLAN.md](./TERMINAL_THREADS_IMPLEMENTATION_PLAN.md).

#### Agent identity

Terminal text alone is not enough to prove that an agent is currently
running; old transcript text can remain after the process exits. Identity is
therefore process-first:

1. read the PTY's current foreground process group;
2. compare it with the login shell's process group;
3. when the foreground group changes, inspect that group's command basenames;
4. map known executables/wrappers to `codex` or `claude`;
5. clear the detected agent immediately when the login shell regains the
   foreground.

Use a small macOS-only helper. Prefer the existing `x/sys/unix` ioctl support
for the foreground process-group query. For v1, invoking `/bin/ps` only when
the foreground process group changes is acceptable and simpler than adding a
general process-inspection dependency. Do not invoke `ps` per PTY chunk or per
screen scan. While an agent is known, perform a one-second foreground-group
recheck so a silent exit is eventually observed; idle shells require no
periodic process scan.

Title or screen evidence may identify an agent only when process inspection
returns a non-shell foreground job but cannot name it. It must never resurrect
an agent after the login shell is foreground again.

#### Terminal evidence

Use three already-parsed Ghostty signals:

- OSC 0/2 terminal title;
- OSC 9;4 progress state;
- the current active screen formatted as plain text with trailing whitespace
  trimmed.

The detector has zero scrollback, so its formatted text is the current bottom
screen rather than a raw byte tail or a user-scrolled viewport. This matters
for TUIs: carriage returns, cursor movement, clear-screen sequences, and the
alternate screen make regexes over the last raw bytes incorrect.

Retain the raw title only inside the detector, capped at 256 Unicode scalars.
For client presentation, remove control characters, normalize whitespace,
strip known leading spinner glyphs, and cap the result at 128 scalars. A
spinner changing frames must not cause repeated RPC or SwiftUI updates.

#### Classification rules

Start with small, compiled-in Codex and Claude profiles. Each profile is a
pure function over:

```text
foreground executable identity
normalized OSC title
OSC progress state
current screen text
previous activity
whether the terminal is attached
```

Rules may inspect bounded regions such as the last three or five non-empty
lines, text after the current prompt marker, or the normalized title. Evaluate
specific blockers before broad working/idle rules. `blocked` requires explicit
visible approval, permission, or question controls; ambiguous content returns
`unknown` rather than falsely claiming that user action is required.

Do not build a generic manifest engine, remote rule updater, regular-expression
DSL, or plugin system for v1. Capture representative screen/title fixtures and
write direct, table-driven Go tests. Add another small profile only after a
real fixture exists. If more than roughly three profiles produce duplicated
logic, extract the common rule representation then.

#### Scheduling and stabilization

Feeding bytes into `libghostty-vt` is synchronous and stays in the session's
serialized runtime. Plain-text formatting and rule evaluation are debounced:

- schedule a scan 200 ms after output becomes dirty;
- during continuous output, force at most one scan every 500 ms so a trailing
  debounce cannot starve forever;
- scan immediately on a meaningful title/progress change or foreground-group
  change;
- do not scan clean idle terminals;
- publish only when normalized title, agent kind, or semantic activity changes.

Publish `working` and `blocked` immediately. Require two matching scans or
300 ms of stable evidence before a `working` to `idle` transition, preventing
spinner redraws and transient prompt frames from flickering the sidebar.

The detector stores its last semantic result, not a growing text history.
Formatted screen text is a short-lived local value and is discarded after
each scan.

#### Client-visible result

Each running `TerminalSummary` carries transient fields:

```text
observedTitle?
agentKind?
agentActivity
agentActivityUpdatedAt?
```

These fields are process-local, are not written to SQLite, and reset to no
activity on relaunch/termination. The daemon publishes a terminal-list upsert
only when one of these semantic fields changes. It never sends screen evidence
or detector text to the client.

## 12. Native attach model

### 12.1 Model policy

Each live run keeps a passive Ghostty VT model in daemon memory:

- maximum retained scrollback: 2 MiB per terminal;
- feed output only, never input, in sequence order;
- resize it with the PTY under the same session lock;
- preserve both screens, cursor, modes, margins, tabstops, styles, and parser
  continuation through Ghostty's native snapshot representation;
- release it on relaunch, terminate, delete, or daemon shutdown;
- never write its contents to SQLite or routine logs.

The 2 MiB limit is a starting value, not a public compatibility promise. Change
it only after measurement.

### 12.2 Snapshot safety and compatibility

Live output reaches the client unchanged. Attach does not replay historical VT
bytes and therefore cannot regenerate historical device-query answers or
mode reports into the current PTY. It transfers the already-parsed terminal
model with Ghostty's authenticated `GHOSTSNP` format.

GHOSTSNP v1 is not stable across arbitrary upstream revisions. Daemon and
client must embed the same exact Ghostty core and advertise a compatibility
identifier containing that revision. The client rejects any other identifier
before calling Ghostty.

Surface restore is transactional: decode and configuration occur before the
renderer lock; the complete decoded grid must equal the current surface grid;
only then may the old model be replaced. Failure preserves the old model. The
operation returns only after parser continuation and renderer state are ready,
which is also the client's visibility and live-output barrier.

### 12.3 Attach snapshot

An attach snapshot contains:

- terminal summary;
- run ID;
- snapshot sequence;
- native snapshot format identifier and GHOSTSNP bytes;
- current rows and columns;
- exit information when available.

After native installation completes, the client consumes only live events
whose run ID matches and whose sequence is greater than the snapshot sequence.

### 12.4 Snapshot/live race

The implementation must not lose output produced while attach is returning a
snapshot.

Use the existing thread-subscription pattern:

1. Register the RPC client as the terminal attachment.
2. Capture the authoritative snapshot under the terminal service's ordering
   boundary.
3. Output generated after that point is assigned a higher sequence and sent as
   a live notification.
4. The Swift session buffers notifications while the attach request is in
   flight.
5. Install the snapshot, discard buffered events at or below its sequence, and
   apply the remainder in order.

Do not build a durable event log. The sequence exists only to order one daemon
run and close the attach race.

### 12.5 Accepted limitations

The 2 MiB scrollback bound may omit old history, but active model state remains
exact; modes and alternate-screen contents do not depend on replaying retained
history. Ghostty restores its own model but not the user's viewport scroll
offset, PTY process state, or a session across daemon restart.

Snapshot wire compatibility is revision-pinned until upstream publishes a
stable contract. Upgrade daemon and Swift binary together; never track a
moving Ghostty branch independently on either side.

## 13. Shared attachment and multi-client behavior

Each terminal may have multiple active attachments. This deliberately follows
the simple shared-PTY model: every attached client can view and interact with
the same shell.

### 13.1 Attach behavior

When client B attaches while client A is already attached:

1. B receives an authoritative snapshot and subscribes to live output.
2. A remains attached and continues to receive output.
3. Both A and B may send input and resize the shared PTY.
4. The most recently processed resize determines the PTY grid.

There is no lease, controller identity, takeover action, viewer role, or
resize arbitration. Devices with different grids may cause a TUI to repaint;
that is an accepted tradeoff for the simpler model.

### 13.2 Disconnect behavior

When an attached WebSocket disconnects:

- remove only that connection's attachment;
- leave the shell and attach model running;
- do not start a grace timer;
- do not terminate automatically.

A later attach receives the current snapshot and joins the other listeners.

### 13.3 Authorization checks

Every input and resize operation includes terminal ID and run ID. The daemon
applies it only when:

- the terminal and live run exist;
- run ID matches;
- the sending RPC client is attached to the terminal;
- the session is running.

Stale input and resize notifications are ignored. They must never affect a
newer relaunched shell.

## 14. JSON-RPC contract

Names below are normative; exact generated Go/Swift field optionality can be
refined during implementation without changing behavior.

### 14.1 List stream

`terminal.subscribeList {}` returns a `TerminalListStreamItem` snapshot and
registers the connection for subsequent notifications of the same method.

List stream kinds:

- `snapshot` with all terminal summaries;
- `terminal-upserted` with one summary;
- `terminal-removed` with one terminal ID.

The server publishes list updates for create, rename, relaunch, exit,
termination, deletion, error status changes, and changed normalized
title/agent activity. It does not publish on raw output, input, resize, or an
attach that does not acknowledge `done`.

### 14.2 Lifecycle requests

```text
terminal.create
  input:  title?, cwd, columns, rows
  result: terminal attach snapshot

terminal.attach
  input:  terminalId, columns, rows
  result: terminal attach snapshot

terminal.relaunch
  input:  terminalId, columns, rows
  result: terminal attach snapshot for a new run

terminal.rename
  input:  terminalId, title
  result: terminal summary

terminal.terminate
  input:  terminalId
  result: null

terminal.delete
  input:  terminalId
  result: null
```

Creating a terminal persists metadata, starts the shell, and attaches the
calling client atomically from the product's perspective. If the spawn fails,
the row remains with error/stopped status so the user can correct the cwd or
delete it.

Attaching to an existing `running` or `exited` live run returns its retained
snapshot. A `stopped` terminal requires relaunch. The UI may automatically
relaunch a stopped row after explicit user selection.

`terminate` kills the live run and retains metadata. `delete` terminates if
necessary and removes metadata.

### 14.3 High-frequency client notifications

Use JSON-RPC notifications rather than request/response calls for:

```text
terminal.write
  terminalId, runId, data

terminal.resize
  terminalId, runId, columns, rows

terminal.detach
  terminalId, runId
```

`data` is a Go `[]byte`/Swift `Data` field and therefore base64-encoded by the
JSON coders. Do not assume terminal bytes are valid UTF-8.

The handwritten Swift `RPCClient` needs a small `notify` method using its
existing serializer and WebSocket. Do not create a new transport protocol.

### 14.4 Terminal stream

Server notifications use `terminal.subscribe` with these kinds:

- `output`: terminal ID, run ID, sequence, base64 data;
- `status`: terminal ID, run ID, sequence, status, optional exit code/message.

PTY reads are coalesced for up to 8 ms or 64 KiB, whichever comes first,
before notification fanout. This prevents one JSON message per character,
keeps interactive latency low, and avoids excessive JSON/base64 work during
large output bursts.

No individual output notification may exceed 64 KiB of decoded terminal data.

### 14.5 Error vocabulary

Define stable terminal error codes or typed data for:

- terminal not found;
- invalid cwd;
- invalid dimensions;
- spawn failed;
- terminal not running;
- stale run;
- client not attached;
- write failed;
- resize failed.

Messages must be useful to a person and must not include terminal input or
output contents.

## 15. Daemon concurrency and backpressure

The terminal service is separate from the orchestration engine worker. PTY
output must never enter the agent projection or block agent event ingestion.

Required properties:

- each session serializes its PTY write, resize, lifecycle, sequence, attach
  model, detector, and attachment mutations;
- different terminal sessions can run concurrently;
- PTY read loops may block on the PTY but not on Swift clients;
- output fanout uses the existing bounded per-client outbound queue;
- a slow client is disconnected rather than allowing unbounded memory growth;
- session shutdown is idempotent;
- late output from a previous run ID is discarded;
- daemon shutdown waits for terminal process cleanup before returning;
- detector formatting is event-driven/debounced rather than an always-on poll;
- detector state never enters the high-frequency output fanout path.

The service may use a mutex per session plus a service-level map mutex. Do not
introduce an actor framework, event-sourcing layer, or generic reactor.

## 16. Swift client architecture

### 16.1 Connection choice

Agent threads and terminals share one `RPCClient`/WebSocket connection.
`RPCConnectionCoordinator` is the sole owner of connection establishment, the
15-second attempt timeout, reconnect backoff, and disconnect handling.
`ThreadStore` and `TerminalStore` register their synchronization and restoration
work with it while retaining separate domain state and RPC protocols.

This keeps one authoritative connection state for the unified workspace UI,
avoids duplicate retry machinery, and lets JSON-RPC multiplex thread and
terminal requests by request ID. Terminal output remains bounded and ordered;
raw bytes still bypass SwiftUI observation.

### 16.2 TerminalStore

`TerminalStore` is `@MainActor @Observable` and owns only UI-relevant terminal
state:

- terminal summaries;
- selected/attached terminal identity;
- observable lifecycle/control status;
- terminal-list and attachment subscription state.

It derives connection status from `RPCConnectionCoordinator`; it does not own
transport connection or reconnect tasks.

It does not expose a growing output `Data` or `String` property.

Use `@ObservationIgnored` for:

- active stream sinks/controllers;
- notification decoder;
- buffered output items during attach;
- transport tasks and session maps that should not invalidate views.

When raw bytes arrive, route them directly to the active
`TerminalSessionController`. Update observable properties only for status,
title, error, or control changes.

`TerminalSummary`, `AgentKind`, and `AgentActivityState` must be `Equatable` so
identical detector reports do not invalidate terminal rows. Keep one small
observable summary per row or pass the row only the title, subtitle, and status
values it renders; never make every row observe a screen buffer or detector
object.

### 16.3 TerminalSessionController

The terminal detail view owns one stable controller with `@State`. It owns:

- `TerminalViewState`;
- `InMemoryTerminalSession`;
- current terminal ID and run ID;
- last applied output sequence;
- attach buffering state;
- current control state;
- forwarding of input and resize to `TerminalStore`;
- an awaited transactional snapshot restore for attach and direct calls to
  `InMemoryTerminalSession.receive(_:)` for live output;
- process-exit delivery to the Ghostty surface.

Raw output never passes through SwiftUI `body` and never becomes a value-type
input to the terminal surface view.

### 16.4 Ghostty host

`TerminalSurfaceHost` is a small SwiftUI view that embeds the package's
`TerminalSurfaceView` and passes only stable integration objects. It is a
separate invalidation boundary from overlays and toolbar/status chrome.

Conceptually:

```swift
let session = InMemoryTerminalSession(
    write: { data in
        // Forward to terminal.write while this client remains attached.
    },
    resize: { viewport in
        // Forward only when rows or columns changed.
    }
)

terminalViewState.configuration = TerminalSurfaceOptions(
    backend: .inMemory(session)
)
```

Daemon output is delivered with `session.receive(data)`.

Do not add an `MTKView`, custom Metal shaders, cell renderer, display link, or
manual font shaper. The package owns all of those terminal-rendering concerns.

### 16.5 App root

The app root creates one RPC client and coordinator, then passes both to the
domain stores:

```swift
let rpc = RPCClient()
let connection = RPCConnectionCoordinator(rpc: rpc)
let threadStore = ThreadStore(rpc: rpc, connection: connection)
let terminalStore = TerminalStore(rpc: rpc, connection: connection)
```

It starts the coordinator through either store. A transport failure restores
both subscription domains through one retry path; it never terminates a daemon-owned
shell.

### 16.6 Unified sidebar model

Unify only presentation and navigation:

```swift
enum WorkspaceItemID: Hashable {
    case agentThread(String)
    case terminal(String)
}

enum WorkspaceListItem: Identifiable {
    case agentThread(ThreadListEntry)
    case terminal(TerminalSummary)
}
```

Merge and sort the two lists by `updatedAt DESC` in the sidebar presentation
layer. Do not convert terminal summaries into fake `ThreadListEntry` values.

Each row receives only the values it renders. Terminal output and whole store
objects must not be passed into every row.

## 17. Navigation and sidebar UX

### 17.1 Naming

Because the list contains chats and terminals, change the user-facing list
title from “Chats” to “Threads”. Search copy becomes “Search Threads”.

### 17.2 Row presentation

A terminal row displays:

- terminal icon;
- persisted title;
- normalized observed title when useful, otherwise cwd's last path component;
- relative `updatedAt`;
- the highest-value status: `Needs input`, `Done`, `Working`, `Agent ready`,
  `Running`, `Exited`, `Stopped`, or `Error`.

Lifecycle state wins when the terminal is not running. For a running terminal,
activity priority is `blocked`, `done`, `working`, `idle`, `unknown`, then no
agent. Keep the treatment compact: one status label or badge, not a dashboard
inside every row. `Needs input` and `Done` may use attention colors; continuous
`Working` should remain visually calm.

Do not show PID, rows/columns, shell path, attachment ID, snapshot size, or
implementation terminology.

### 17.3 Creation

The primary create button becomes a menu:

- New Chat;
- New Terminal.

Global New Terminal starts in the user's home directory unless a cwd is
explicitly selected. An agent-thread context menu provides “Open Terminal
Here”, using that thread's cwd and a title derived from the final path
component.

Do not add a remote filesystem browser for v1. A user can `cd` after opening.
Recent-cwd selection may be added later if real usage shows it is needed.

### 17.4 Independence from agent threads

“Open Terminal Here” is a creation shortcut, not a relationship:

- copy cwd at creation;
- do not persist `sourceThreadID`;
- deleting the agent thread does nothing to the terminal;
- deleting the terminal does nothing to the agent thread;
- neither can send commands to the other.

### 17.5 Detail layout

The terminal view is primarily the Ghostty surface. Keep chrome minimal:

- navigation title: persisted terminal title;
- optional normalized observed title and cwd subtitle where the platform
  naturally supports them;
- toolbar/menu: Rename, Relaunch, Terminate, Delete, text size;
- unobtrusive connection or control overlay only when action is required.

Use separate SwiftUI view structs for the surface, status overlay, and toolbar
content so status changes do not rebuild the terminal host.

### 17.6 Close semantics

- navigating back or selecting another thread detaches the view;
- it does not terminate the shell;
- Terminate is explicit and destructive;
- Delete terminates if necessary and removes metadata;
- a naturally exited shell remains viewable with a Relaunch action;
- a stopped metadata row relaunches when the user explicitly opens it.

### 17.7 Shared attachment UX

Opening the terminal on another device does not change the current screen or
show ownership UI. Both views remain connected to the same shell. Normal
disconnect handling still keeps the last rendered screen visible and disables
input until reconnection.

## 18. Platform input and terminal behavior

Use package behavior before writing maiD-specific substitutes.

### 18.1 Included through libghostty-spm

- Metal rendering;
- CoreText font shaping;
- ordinary scrollback and scrolling;
- software keyboard accessory keys;
- hardware keyboard input;
- CJK/IME composition;
- mouse/touch reporting;
- tap-to-focus and software-keyboard lifecycle;
- surface fitting when the keyboard changes the available size;
- selection;
- copy/paste;
- OSC 8 link recognition;
- bell callbacks;
- terminal title callbacks;
- desktop notification callbacks;
- shell command-finished callbacks;
- prompt/scrollback navigation when shell markers are available.

### 18.2 maiD host responsibilities

- decide whether a URL is safe and open it through the platform;
- present paste confirmation when required;
- forward only measured rows/columns;
- map terminal bell/notification callbacks to app UX;
- treat client-side title/progress callbacks as presentation signals only;
  never use them as the shared agent-status authority;
- store the terminal font-size preference; keep the v1 theme fixed;
- request notification permission only when the user enables notifications.

### 18.3 v1 feature cut

Ship the package-provided keyboard, IME, selection, clipboard, mouse, link,
and scrollback behavior with the core terminal.

Defer:

- tabs and splits;
- scrollback search UI;
- custom keyboard accessory redesign unless the package default fails usability
  testing;
- reliable job-completion notifications until shell integration/OSC 133 is
  deliberately installed;
- custom Ghostty shaders;
- server-side Kitty graphics handling.

Kitty graphics that work through Ghostty's retained core and renderer require
no new wire protocol—the image bytes are terminal output. Add a compatibility
test, but do not build a separate image channel.

## 19. Lifecycle flows

### 19.1 Create

1. User selects New Terminal or Open Terminal Here.
2. Client measures the Ghostty surface, falling back to `80x24`.
3. Client calls `terminal.create`.
4. Daemon validates cwd, persists metadata, starts the PTY and passive
   detector, and subscribes the calling RPC client.
5. Client installs the returned empty/initial snapshot.
6. Live output feeds directly into Ghostty.

### 19.2 Navigate away

1. Detail view sends best-effort `terminal.detach` and unregisters its local
   stream sink.
2. Daemon removes that client's attachment if the run still matches.
3. PTY continues running, updating its bounded attach model and shared agent
   activity through the daemon detector.

### 19.3 Reattach after suspension/disconnect

1. `TerminalStore` reconnects and refreshes the terminal-list snapshot.
2. Visible terminal detail calls `terminal.attach` with current dimensions;
   this acknowledges a pending `done` state.
3. Store buffers terminal notifications until the response arrives.
4. Controller validates and transactionally restores the native Ghostty model.
5. Controller applies buffered events above the snapshot sequence.
6. Current dimensions resize the PTY.

### 19.4 Natural exit

1. PTY read loop drains remaining output.
2. Detector performs its final state transition and shuts down.
3. Session emits an exited status with exit code.
4. Client Ghostty receives process exit after preceding output.
5. Sidebar displays Exited.
6. Detail keeps final screen and offers Relaunch.

### 19.5 Relaunch

1. User explicitly chooses Relaunch.
2. Daemon cleans up old handles and process group.
3. Attach model and sequence reset.
4. Detector state, observed title, and agent activity reset.
5. New run ID is allocated.
6. Fresh shell starts in persisted cwd.
7. Calling client installs the new snapshot; other attached clients receive a
   new-run signal and reattach for their own snapshots.

### 19.6 Daemon shutdown/restart

1. Server stops accepting terminal operations.
2. Terminal service terminates all live process groups and closes PTYs.
3. SQLite metadata remains.
4. New daemon reports each persisted terminal as Stopped.
5. Opening one starts a new run; no old output is available.

## 20. Logging, privacy, and security

Never log:

- terminal input;
- terminal output;
- native terminal snapshots;
- detector screen/title evidence;
- clipboard contents;
- full environment variables.

Debug logs may include correlation metadata such as terminal ID, run ID,
status, agent kind, semantic activity, sequence, byte count, rows/columns, and
duration. They must not include the matched screen text or raw terminal title.

For the initial implementation, keep the daemon's existing loopback default.
Physical-device development may use a trusted local/Tailscale address under an
explicit development configuration.

Do not publish an unauthenticated `terminal.*` API through a public Cloudflare
Tunnel. Network authentication and device authorization are separate work, but
the terminal API must be able to sit behind the same future RPC authentication
middleware without redesign.

## 21. Failure behavior

| Failure | Required UX/behavior |
| --- | --- |
| Invalid cwd | Keep/create stopped metadata row only when useful; show “Folder is unavailable” and allow delete or retry |
| Shell spawn failure | Show Error with a retry/relaunch action |
| PTY read EOF | Drain output, mark Exited |
| PTY write failure | Mark Error/Exited as appropriate; do not retry input |
| Resize failure | Keep terminal usable when possible; surface persistent failures once, not per resize |
| WebSocket disconnect | Keep last screen visible, disable input, reconnect automatically |
| Snapshot incompatible or invalid | Preserve the existing surface, fail the attach, detach that client, and show one actionable compatibility error |
| Grid changes during snapshot request | Discard the stale-grid snapshot and request one fresh snapshot at the measured grid |
| Detector unavailable | Keep the terminal fully usable; show no agent badge or a neutral Unknown state, and record one bounded diagnostic |
| Daemon restart | Show Stopped and relaunch on explicit open |
| Client outbound overflow | Disconnect slow client; PTY remains alive |

Routine resize, stale run, and unattached-client input races must not produce
repeating alerts.

## 22. Tests

### 22.1 Go unit tests

- attach model scrollback respects the 2 MiB cap;
- native snapshot reproduces text, cursor, modes, alternate screen, resize,
  erased prompt bytes, and split VT parser continuation;
- corrupt native snapshots are rejected;
- session output sequence is monotonic;
- old run output is ignored after relaunch;
- invalid dimensions are rejected;
- unchanged resize is not re-applied;
- cwd validation accepts directories and rejects files/missing paths;
- disconnect detaches without terminating;
- terminate kills the process group;
- daemon close terminates every live session;
- metadata survives restart while output does not;
- no output/input is written to SQLite;
- detector feeds fragmented VT/OSC sequences correctly;
- detector screen follows cursor movement, clear-screen, and alternate-screen
  behavior rather than raw byte order;
- detector title normalization removes control characters and spinner churn;
- foreground shell clears a previously detected agent;
- Codex/Claude fixtures classify explicit working, blocked, idle, and ambiguous
  states correctly;
- ambiguous blocker text does not produce `blocked`;
- `working` to `idle` stabilization prevents transient flicker;
- detached `working` to idle/shell becomes `done`, and attach acknowledges it;
- clean idle terminals do not format or probe continuously.

### 22.2 RPC integration tests

Use real WebSocket clients, following the existing daemon multi-client tests:

- subscribeList snapshot then upserts;
- attach snapshot cannot lose concurrent output;
- notifications buffered before attach response are ordered by sequence;
- clients A and B receive the same live output and can both write;
- the latest processed resize from either attached client wins;
- unattached clients cannot write or resize;
- disconnecting B keeps the PTY and A's listener running;
- client C reattaches, restores the native snapshot, then receives live output;
- relaunch rejects stale input carrying the old run ID;
- delete terminates and removes list metadata;
- slow-client queue overflow disconnects only that client;
- semantic agent changes publish one summary upsert without publishing screen
  text;
- ordinary output that does not change semantics publishes no list upsert;
- agent activity continues to update with no attached client.

### 22.3 Swift unit tests

- terminal-list snapshot/upsert/remove reducer;
- native snapshot installation plus buffered output ordering;
- stale run and duplicate sequence rejection;
- a new-run signal reattaches an existing listener after another client
  relaunches;
- reconnect requests reattach only for the visible terminal;
- workspace-item merge/sort identity;
- search uses `localizedStandardContains`;
- terminal row status mapping;
- terminal activity priority and `Needs input`/`Done` copy;
- identical equatable activity summaries do not replace row state;
- raw output does not mutate an observable output property;
- resize forwarding deduplicates identical rows/columns;
- incompatible snapshot formats are rejected before calling Ghostty;
- snapshot installation is an awaited visibility and sequence barrier;
- resize is forwarded without a second app-level trailing debounce;
- a daemon-generated fixture restores through the real fork API into an
  on-simulator Ghostty surface.

### 22.4 Integration/manual acceptance matrix

Test on macOS, iPhone simulator/device, and iPad simulator/device:

- shell prompt and ANSI colors;
- long output and scrollback;
- `vim`, `less`, and one mouse-aware TUI;
- emoji, combining marks, wide glyphs, and CJK IME;
- software accessory Esc/Ctrl/Alt/Tab/arrows;
- hardware keyboard shortcuts and modifiers;
- selection, copy, and paste;
- OSC 8 link activation;
- phone rotation;
- keyboard show/hide resize;
- iPad Split View resize;
- macOS window resize;
- background, foreground, disconnect, and reattach;
- simultaneous attachment on Mac and iPhone;
- natural shell exit and relaunch;
- daemon restart showing stopped metadata;
- Codex and Claude working/approval/idle transitions while the terminal is
  visible;
- the same transitions after navigating back to the thread list;
- `Done` clears when the terminal is explicitly reopened;
- observed-title spinner frames do not flash or reorder the row;
- Kitty graphics compatibility as best effort.

### 22.5 Performance checks

- continuous output must not cause SwiftUI sidebar/detail invalidation per
  chunk;
- terminal input should remain responsive over the intended Tailscale path;
- a 10 MiB output burst must leave attach-model scrollback memory capped;
- terminal output must not delay agent orchestration events;
- detector text formatting occurs no more than twice per second during a
  continuous output stream and does not run for clean idle shells;
- 25 simultaneously running detector terminals remain within an agreed memory
  and CPU budget measured during Increment 0;
- arm64 and x86_64 daemon release artifacts statically contain
  `libghostty-vt` and start without external libraries;
- no unbounded tasks, arrays, output strings, or notification queues remain
  after detach/delete.

## 23. Acceptance criteria

The v1 feature is complete when:

1. A terminal thread can be created from the global menu and from an agent
   thread's cwd.
2. The shell is rendered by Ghostty/Metal on all three Apple form factors.
3. Input, resize, selection, clipboard, IME, and hardware/software keyboard
   behavior pass the acceptance matrix.
4. Navigating away and reconnecting preserves the live shell.
5. A newly attached client transactionally restores bounded native model state
   and receives sequenced live output without an attach gap or visible buffer
   flash.
6. Multiple attached clients receive output and can write or resize; the
   latest resize wins.
7. Daemon restart loses processes and output but retains terminal metadata.
8. Terminate and Delete have distinct, understandable behavior.
9. Agent-thread orchestration/provider code contains no terminal-specific
   cases.
10. Terminal output does not enter `@Observable` state, SQLite, or routine
    logs.
11. Codex and Claude activity remains accurate in the list after the terminal
    view detaches, including `Needs input` and `Done` transitions.
12. Detector evidence never crosses RPC, enters SQLite, or appears in routine
    logs, and detector updates do not invalidate SwiftUI per output chunk.
13. Server and Swift unit tests cover lifecycle, snapshot/live ordering,
    shared attachment, persistence, stale-run fencing, and agent-state
    classification.
14. No tabs, splits, multiplexer, durable checkpoint, cell-grid sync protocol,
    or networking-auth system was added incidentally.

## 24. Implementation sequence

The dependency-ordered, test-gated plan is maintained separately in
[TERMINAL_THREADS_IMPLEMENTATION_PLAN.md](./TERMINAL_THREADS_IMPLEMENTATION_PLAN.md).
Its increments are:

0. resolve Swift Ghostty, PTY, and daemon Ghostty packaging risks;
1. build the isolated Swift renderer adapter with fake host I/O;
2. build and test the daemon PTY core without RPC;
3. connect one live end-to-end terminal;
4. add initial replay, sequencing, detach, reconnect, exit, and relaunch;
5. add metadata persistence and terminal rows to the Threads list;
6. add shared multi-client attachment;
7. finish Apple-platform input and interaction UX;
8. add lightweight foreground-process and OSC agent signals without a second
   terminal grid;
9. add headless Ghostty screen detection for the status gaps that require live
   bottom-screen contents;
10. perform release hardening without adding new feature scope.

Increment 9 is the functional feature-complete checkpoint. Networking
authentication remains separate work.

## 25. Prior-art findings

### t3code

t3code uses server-owned PTYs and client-owned renderers. Clients receive a
snapshot/history and live output, then feed it into their terminal renderer.
That is terminal I/O synchronization and output replay, not native terminal
model transfer.

The researched terminal manager permits multiple attach listeners. Its write
and resize operations do not carry a controller identity, so multiple attached
clients can write and resize the same PTY; the last resize effectively wins.
maiD adopts that simple behavior while retaining run-ID checks and requiring a
connection to attach before it can write or resize.

t3code persists capped terminal history and uses a capped client buffer. maiD
keeps the useful sequence-and-live attach race pattern, but replaces raw
history replay with an in-memory native Ghostty model.

Relevant research locations:

- `~/Code/Personal/t3code/apps/server/src/terminal/Manager.ts`
- `~/Code/Personal/t3code/packages/client-runtime/src/state/terminalSession.ts`
- `~/Code/Personal/t3code/apps/mobile/modules/t3-terminal/ios/T3TerminalView.swift`
- <https://github.com/pingdotgg/t3code/blob/main/apps/server/src/terminal/Manager.ts>

### Zed

Zed persists terminal metadata and restores terminal UI entries by spawning
new shells. It does not require a durable PTY to make terminal threads useful.
That supports maiD's metadata-only restart policy.

Relevant research location:

- `~/Code/Personal/zed/crates/agent_ui/src/agent_panel.rs`

### libghostty-spm

The package supplies the native Apple embedding layer that upstream release
XCFrameworks alone do not provide as conveniently for this use case.

- <https://github.com/Lakr233/libghostty-spm>

### Herdr

Herdr's current agent detection is server-owned. It first identifies the
foreground process, then evaluates a live bottom-buffer snapshot maintained by
its headless Ghostty VT engine. Its rules can also use OSC terminal-title and
progress evidence. Detection follows the terminal's live bottom rather than a
user-scrolled viewport, continues with no focused UI, skips unchanged idle
screens, and stabilizes transient state changes.

maiD adopts the small architectural core—process-first identity plus
Ghostty-parsed title/progress/current screen on the daemon—but not Herdr's
multiplexer, remote manifest updates, general rule DSL, integration installer,
session restore, or large supported-agent matrix. v1 keeps direct, tested
Codex and Claude profiles.

Relevant research locations:

- <https://github.com/herdrdev/herdr/blob/master/docs/next/website/src/content/docs/agents.mdx>
- <https://github.com/herdrdev/herdr/blob/master/src/pane.rs>
- <https://github.com/herdrdev/herdr/blob/master/src/pane/terminal.rs>
- <https://github.com/herdrdev/herdr/blob/master/src/detect/manifests/codex.toml>
- <https://github.com/herdrdev/herdr/blob/master/src/detect/manifests/claude.toml>

### Go libghostty binding

`go.mitchellh.com/libghostty` is a thin cgo wrapper over
`libghostty-vt`. It provides the exact primitives needed here: `VTWrite`,
resize, title/progress effects, terminal state access, and a plain-text
formatter. Its Go API currently promises no stability and it does not bundle
the native library for downstream applications, so exact pinning and a
repository-owned static build recipe are mandatory.

- <https://github.com/mitchellh/go-libghostty>
- <https://pkg.go.dev/go.mitchellh.com/libghostty>

### Go PTY

`creack/pty` provides the small Unix/macOS PTY seam needed by the daemon.

- <https://github.com/creack/pty>

## 26. Revisit triggers

Do not expand the architecture merely because a future option exists. Revisit
specific decisions only after observing one of these triggers:

- users report devices repeatedly fighting over grid size or input: consider
  explicit controller/viewer roles;
- the revision-pinned native snapshot becomes too costly to maintain: pursue an
  upstream stable restore API or evaluate explicit tmux integration;
- users require survival across daemon restarts: evaluate opt-in tmux/zellij,
  not a custom multiplexer;
- several feature stores need independent WebSocket connections: extract a
  shared RPC connection/router;
- users need many terminals per workspace: consider tabs/splits only after
  measuring sidebar clutter;
- users need transcript search/auditing: design explicit opt-in persistence
  with privacy controls;
- more than roughly three agent profiles duplicate the same classifier
  mechanics: extract a small embedded rule representation, but do not add
  remote updates until release lag becomes a measured problem;
- an agent provides complete, reliable lifecycle hooks: allow one server-side
  hook authority for that agent instead of running two competing classifiers;
- detached detector accuracy is not worth its measured cgo/build cost: remove
  agent badges as a product tradeoff rather than moving authority to an iOS
  renderer;
- the Go binding changes incompatibly or stops shipping usable commits:
  maintain a reviewed fork/build pin behind `AgentDetector`, without exposing
  binding APIs elsewhere;
- `libghostty-spm` becomes unsuitable: fork its package interface and build
  pipeline rather than leaking Ghostty C APIs through maiD.

Until one of those triggers occurs, the v1 boundaries remain the preferred
architecture.
