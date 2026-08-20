# FFF-backed Composer File Picker Specification and Incremental Plan

Status: proposed for implementation  
Last updated: 2026-08-05

## 1. Decision

maiD will implement composer file references with FFF in the Go daemon through
FFF's supported C ABI and a small private cgo wrapper.

The initial release is macOS-only and uses a pinned, prebuilt
`libfff_c.dylib`. The daemon keeps one path-only FFF index alive per active
workspace. The Swift composer calls a typed JSON-RPC method while the user has
an active `@` trigger and inserts the selected relative path into the prompt.

This is the selected tradeoff because it gives maiD FFF's warm in-process
search, watcher, ignore handling, and ranking without adding a Rust sidecar,
MCP translation layer, Node runtime, or independent search implementation.
Cgo and native-library packaging are accepted costs for the macOS daemon.

The first version must not use:

- `fff-mcp` as the composer protocol;
- `purego` or a hand-written `dlopen`/`dlsym` layer;
- `rg` or `fzf` as a second search backend;
- a port or fork of FFF's Rust search core;
- content indexing merely to support file-name completion.

## 2. Product outcome

When the insertion cursor is in an active `@query` in the chat composer, the
client shows fuzzy-matched files from that thread or draft's workspace. Search
is performed by the daemon and remains warm across queries. Selecting a result
replaces the trigger range with a relative-path Markdown reference and a
trailing space.

Example:

```text
Before: Please update @promptcomp|
After:  Please update [PromptComposer.swift](clients/swift/mai/Features/Chat/PromptComposer.swift) |
```

The vertical bar represents the insertion cursor and is not part of the text.

### Required behavior

- `@` completion works in both existing threads and local drafts.
- Search observes `.gitignore` and FFF-supported `.ignore` files.
- The initial workspace scan never blocks daemon startup.
- Repeated queries reuse a resident index; they do not create an FFF instance
  or walk the workspace for every keystroke.
- File creation, deletion, and rename become visible through FFF's watcher.
- Results contain relative paths only. Absolute paths do not enter draft text.
- Keyboard, pointer, touch, VoiceOver, and Dynamic Type paths are usable.
- Search failure does not discard or mutate the user's draft.
- The feature remains separate from ACP filesystem and terminal capabilities.

### Non-goals for v1

- Repository-wide content grep.
- Directory references.
- File previews or file-content transfer to the Swift client.
- Remote/non-macOS daemon support.
- Searching outside the selected thread or draft workspace.
- Persisting a second maiD-owned file index.
- Exposing FFF as an ACP tool or provider capability.

## 3. Architecture

```text
PromptComposer
    -> ComposerFileSearchModel
    -> WorkspaceRPCClient
    -> workspace.searchFiles
    -> internal/workspacesearch.Service
    -> one warm fff.Finder per canonical workspace root
    -> libfff_c.dylib
```

FFF is owned entirely by the daemon. Swift owns trigger detection, request
debouncing, stale-response suppression, suggestion presentation, and text
replacement. Neither side implements a second fuzzy scorer.

### 3.1 Proposed daemon layout

```text
internal/workspacesearch/
    service.go
    service_test.go
    types.go
    fff/
        finder.go
        finder_darwin_cgo.go
        finder_unsupported.go
        finder_integration_test.go

third_party/fff/
    MANIFEST.json
    LICENSE
    include/fff.h
    lib/darwin-arm64/libfff_c.dylib
```

`MANIFEST.json` records the exact FFF tag or commit, source URL, target triple,
header SHA-256, dylib SHA-256, and upstream license version. Ordinary builds
must not download dependencies from the network.

The wrapper is internal until its API and upgrade behavior have proven useful
outside maiD. It must not begin as a general-purpose public Go binding.

### 3.2 Go boundary

The Go-facing native boundary should stay narrow:

```go
type Finder interface {
	WaitReady(ctx context.Context) error
	SearchFiles(query string, limit int) ([]FileMatch, error)
	ScanProgress() ScanProgress
	Close() error
}
```

The implementation may add a health method if the selected FFF version
provides useful diagnostics. Glob, directory, grep, query-history, and other
FFF APIs remain unwrapped until a maiD feature requires them.

Instance creation must use FFF's versioned `FffCreateOptions` API. Prefer a
small C helper initialized with C99 designated fields rather than duplicating
the complete C struct layout in Go.

Initial options:

| Option | Value | Reason |
| --- | --- | --- |
| `base_path` | Canonical workspace root | One index is scoped to one workspace |
| `watch` | `true` | Keep the resident path index current |
| `enable_content_indexing` | `false` | Composer completion searches paths only |
| `ai_mode` | `false` | This is an interactive human picker |
| `enable_fs_root_scanning` | `false` | Never expand beyond the workspace |
| `enable_home_dir_scanning` | `false` | Never expand beyond the workspace |
| mmap cache | `false` (decided in Increment 0) | Path-only completion gains nothing from content caches; revisit only with a measured cold-start benefit and an app-owned cache location |

The wrapper owns the raw FFF handle. It must:

- copy native strings and values into Go-owned memory before freeing results;
- free each payload with its dedicated FFF free function;
- free every outer `FffResult` with `fff_free_result`;
- serialize `Close` against active native calls;
- make `Close` idempotent;
- reject calls after close;
- keep `unsafe.Pointer` and C types private to the package;
- recover ordinary FFF error results as Go errors, without logging query text;
- use an explicit close path; a finalizer may only be a leak safety net.

Direct cgo calls are synchronous. A context cancellation cannot interrupt a
native call already in progress. Path queries are expected to be short, so the
client cancels or supersedes requests and ignores stale responses. The server
must clamp work per request rather than promising hard native cancellation.

### 3.3 Workspace index registry

`internal/workspacesearch.Service` owns a concurrency-safe registry keyed by a
canonical workspace root.

Required lifecycle:

1. Canonicalize and validate the workspace directory.
2. Lazily create one index for the first request to that root.
3. Coalesce concurrent first requests so they cannot create duplicate indexes.
4. Run/wait for the initial scan outside the global registry lock.
5. Serve all later queries from the same warm instance.
6. Update `lastUsed` after a request.
7. Close indexes idle for 15 minutes.
8. Keep no more than eight indexes; evict the least-recently-used idle index
   before exceeding the bound.
9. Close every index during daemon shutdown.

The limits are initial safety defaults and should be changed only from measured
memory behavior. Do not add a general cache framework or external dependency
for this registry.

Index initialization is asynchronous. A search may wait up to 100 ms for an
initial scan. If the index is still warming, the RPC returns `indexing: true`
and no error; the client may retry while the same trigger remains active. A
real initialization or search failure is returned as a typed RPC error.

### 3.4 Workspace resolution and trust boundary

Existing threads and local drafts need different lookup inputs:

- Existing thread: the client sends `threadId`; the daemon resolves the
  canonical cwd from orchestration state.
- Local draft: the client sends its selected absolute `cwd`; the daemon applies
  the same absolute-directory validation used when creating a thread.

Exactly one of `threadId` or `cwd` is required. A request containing both or
neither is invalid. FFF root/home scanning stays disabled even after the root
is accepted.

This RPC belongs to the trusted maiD client/daemon API. It must not be forwarded
to ACP providers, registered as an ACP capability, or made callable by a model
through provider tool negotiation.

## 4. Wire contract

Add the canonical method and DTOs to `api/wire`, then regenerate clients with
`make generate`. Generated Swift or schema files must not be edited directly.

Method:

```text
workspace.searchFiles
```

Proposed Go wire shapes:

```go
type WorkspaceSearchFilesParams struct {
	ThreadID orchestration.ThreadID `json:"threadId,omitempty"`
	Cwd      string                 `json:"cwd,omitempty"`
	Query    string                 `json:"query"`
	Limit    int                    `json:"limit,omitempty"`
}

type WorkspaceFileEntry struct {
	RelativePath string `json:"relativePath"`
	DisplayName  string `json:"displayName"`
}

type WorkspaceSearchFilesResult struct {
	Entries  []WorkspaceFileEntry `json:"entries"`
	Indexing bool                 `json:"indexing,omitempty"`
}
```

Validation rules:

- `query` is at most 256 UTF-8 bytes;
- omitted `limit` defaults to 50;
- `limit` is clamped to `1...100`;
- every returned path is relative, normalized, and remains beneath the root;
- duplicate relative paths are removed before returning;
- native scores and absolute paths are server-private;
- an empty query is allowed so FFF can return its default/frecency ordering.

No server notification is required for v1. While `indexing` is true, the client
uses bounded polling tied to the lifetime of the active trigger.

## 5. Swift client design

Add focused types under `clients/swift/mai/Features/Chat/` and keep network code
under `clients/swift/mai/Network/`:

```text
Features/Chat/
    ComposerFileSearchModel.swift
    ComposerFileSuggestionList.swift
    ComposerFileTrigger.swift
    ComposerFileReference.swift

Network/
    WorkspaceRPCClient.swift
```

`ComposerFileSearchModel` is `@MainActor @Observable`. It owns suggestion
state, selected-row state, indexing state, and the current search task. Raw
draft text remains owned by the existing prompt model/draft store.

### 5.1 Trigger rules

`ComposerFileTrigger` is a pure value parser with focused tests. An active
trigger:

- begins with `@` at the start of text or after whitespace/open punctuation;
- ends at the insertion cursor;
- does not activate inside an email-like token such as `name@example.com`;
- accepts path separators, dots, underscores, and hyphens;
- closes when the cursor leaves its range, the relevant text is deleted, the
  user dismisses it, or the prompt is submitted.

Use SwiftUI's selection-aware text APIs so completion works at the insertion
cursor, not just at the end of the draft. If the target SDK cannot supply the
required selection and replacement behavior for the current multiline
`TextField`, stop at Increment 4 and specify the smallest AppKit/UIKit-backed
editor adapter. Do not silently ship end-of-text-only parsing.

### 5.2 Query behavior

- Start or replace a debounce task whenever the active trigger query changes.
- Debounce by 80 ms.
- Cancel the previous Swift task before issuing a new request.
- Assign a monotonically increasing local request generation.
- Apply a response only if its generation, workspace, and trigger range still
  match current state.
- While `indexing` is true, retry after 250 ms, stopping immediately when the
  trigger disappears or the view is removed.
- Clear suggestions on connection loss without changing prompt text.

### 5.3 Presentation and insertion

Suggestions appear above the composer without changing the composer's width.
Each row shows the filename prominently and its parent path secondarily.

Interaction requirements:

- macOS: Up/Down change selection, Return/Tab accepts, Escape dismisses;
- iOS/iPadOS: touch selects, keyboard navigation works when a hardware
  keyboard is present;
- VoiceOver identifies each result as a file and reads its relative path;
- the list has a bounded height and scrolls without resizing the chat timeline;
- loading, no-results, and failure states are visually distinct but compact.

Selection replaces exactly the active trigger range. It must not replace a
second `@` token or text after the cursor. `ComposerFileReference` owns Markdown
escaping for the display name and destination and returns:

```text
[display name](relative/path) 
```

Paths containing spaces, brackets, parentheses, backslashes, and non-ASCII
characters require unit fixtures. The prompt remains plain Markdown text; the
client does not attach file contents.

## 6. Performance and reliability budgets

Measure on a release build using at least a small repository and a generated
100,000-path workspace.

| Measurement | Initial budget |
| --- | --- |
| Warm native path query, p95 | under 20 ms |
| Warm RPC query, daemon receive to response, p95 | under 35 ms |
| Composer query change to updated list, excluding 80 ms debounce, p95 | under 75 ms on local network |
| Returned results | at most 100; normal UI request 50 |
| Duplicate indexes for one canonical root | zero |
| Native memory after 10,000 repeated searches | no sustained growth after warm-up |
| File watcher convergence for create/delete/rename | under 2 seconds in integration tests |
| Daemon startup delay caused by indexing | zero synchronous indexing |

Budgets are regression gates, not claims about every repository or filesystem.
If a budget fails, record the measured corpus and profile before changing the
architecture.

The dylib is a required release artifact. Because it is linked directly, a
missing or incompatible dylib can prevent the daemon from launching. Treat
that as a packaging integrity failure and catch it in staged-release smoke
tests rather than adding a runtime fallback search engine.

## 7. Incremental implementation plan

Every increment must leave the existing daemon and clients buildable and have
its own focused verification. The user-visible entry remains absent until
Increment 5.

### Increment 0 — native dependency and packaging proof

#### Objective

Resolve the native ABI, architecture, loading, and distribution risks before
adding product code.

#### Work

1. Select and pin one exact FFF release tag or commit. Do not follow `main` or
   a floating nightly label.
2. Add its matching `fff.h`, arm64 macOS C-library artifact, license, and
   manifest under `third_party/fff`.
3. Verify the dylib is arm64 and that the header/library expose the required
   versioned create, scan, path-search, result-accessor, result-free, and
   destroy functions.
4. Normalize the dylib install name to `@rpath/libfff_c.dylib` if necessary.
5. Build a disposable cgo smoke program that creates an index for a fixture,
   waits for scanning, searches it, frees all results, and destroys the index.
6. Stage the smoke executable and dylib into an otherwise empty directory and
   prove runtime loading with an `@loader_path`-based rpath.
7. Run the staged executable after ad-hoc signing both artifacts.
8. Decide mmap-cache behavior from measured cold-start results and record the
   chosen cache location/setting in this document.
9. Add deterministic `make fff-verify` and staged packaging checks. Normal
   builds must not invoke Cargo, Zig, npm, or the network.

#### Exit checks

- The smoke search returns the expected relative fixture path.
- AddressSanitizer or repeated-loop testing exposes no result-lifetime leak.
- `otool -L` shows a relocatable FFF dependency, not a developer-machine path.
- The staged signed program starts without `DYLD_LIBRARY_PATH`.
- Header and dylib checksums match `MANIFEST.json`.
- The source/version update procedure is written beside the manifest.

#### Stop condition

If the pinned artifact cannot load relocatably or its ownership API cannot be
used safely, stop and resolve packaging/version selection. Do not begin the RPC
or composer UI.

### Increment 1 — narrow, memory-safe Go wrapper

#### Objective

Expose the minimum FFF path-search lifecycle behind an idiomatic internal Go
API without daemon integration.

#### Work

1. Add `internal/workspacesearch/fff` with `darwin && cgo` implementation files.
2. Add a compile-safe unsupported implementation for `!darwin || !cgo` that
   reports a clear feature-unavailable error.
3. Implement create, readiness/progress, path search, and close only.
4. Add a small C creation helper using `FffCreateOptions`.
5. Translate every native result into Go-owned values and centralize ownership
   cleanup.
6. Protect active calls against concurrent close.
7. Add fixture integration tests for ranking, ignore rules, empty results,
   Unicode paths, repeated search, and close behavior.

#### Exit checks

- `go test ./internal/workspacesearch/fff` passes on macOS arm64 with cgo.
- `CGO_ENABLED=0 go test ./internal/workspacesearch/fff` compiles and exercises
  the unsupported path.
- Concurrent search/close tests do not crash or call a destroyed handle.
- A repeated-search test shows stable native memory after warm-up.
- No C type or pointer is exposed outside the FFF package.

### Increment 2 — workspace search service

#### Objective

Add the daemon-owned warm-index registry and make its lifecycle testable without
networking.

#### Work

1. Add pure Go workspace-search types and a private index interface.
2. Implement canonical-root validation, lazy initialization, duplicate-create
   coalescing, asynchronous readiness, request limits, and typed errors.
3. Add idle eviction, the eight-index bound, and service shutdown.
4. Inject the service into daemon construction and close it during daemon
   shutdown, without exposing a handler yet.
5. Test registry behavior with a fake index; keep FFF integration tests focused
   and separately identifiable.
6. Add an integration test proving watcher convergence for created, renamed,
   and deleted files.

#### Exit checks

- One hundred concurrent first searches for one root create one FFF instance.
- Searching two roots never mixes relative paths.
- Registry locks are not held during native scan or search calls.
- Idle/max-count eviction closes exactly the intended instances.
- Shutdown closes all indexes and rejects later requests.
- Existing daemon and orchestration tests still pass.

### Increment 3 — typed workspace-search RPC

#### Objective

Expose file search through the canonical generated client contract.

#### Work

1. Add `workspace.searchFiles`, its DTOs, and method definition to `api/wire`.
2. Run `make generate`; do not edit generated schema or Swift files directly.
3. Add the daemon handler with strict parameter, root, query, and limit
   validation.
4. Resolve an existing thread's cwd from orchestration state. Accept a cwd only
   for a local draft request.
5. Map scanning state to `indexing: true` and real failures to stable JSON-RPC
   errors.
6. Add RPC tests for thread lookup, draft cwd, invalid combinations, missing
   roots, limit clamping, path normalization, scan warming, and FFF failure.
7. Add generated-contract examples/tests for the new method.

#### Exit checks

- A JSON-RPC integration test finds a known fixture from both thread and draft
  forms.
- The handler cannot return an absolute or root-escaping path.
- Invalid requests never create an FFF instance.
- Generated files are reproducible with a clean second `make generate`.
- Existing WebSocket subscriptions and provider RPCs remain unaffected.

### Increment 4 — cursor-aware Swift trigger and search model

#### Objective

Build and test all composer behavior except the production suggestion surface.

#### Work

1. Add the pure `ComposerFileTrigger` parser and replacement-range model.
2. Make the multiline prompt editor expose cursor/selection changes using the
   target SwiftUI SDK's selection-aware API.
3. Add `WorkspaceRPCClient` using generated DTOs and method constants.
4. Add `@MainActor @Observable ComposerFileSearchModel` with debounce,
   cancellation, request generations, indexing retry, and lifecycle cleanup.
5. Integrate the model behind a development-only fixture/harness.
6. Add tests for triggers at the beginning, middle, and end of text; multiple
   triggers; email suppression; cursor movement; deletion; stale responses;
   workspace switching; disconnect; and retry cancellation.

#### Exit checks

- Moving the cursor between two `@` expressions searches/replaces only the
  active one.
- An out-of-order response cannot replace current suggestions.
- Removing the trigger cancels polling and clears state.
- No draft text or suggestion list is lost on RPC failure.
- The implementation uses no third-party Swift dependency.

#### Stop condition

If the multiline SwiftUI editor cannot provide correct cursor-aware selection
and replacement, stop and specify/test the smallest platform editor adapter.
Do not weaken the feature to end-of-text-only completion without a product
decision.

### Increment 5 — production composer suggestion UI

#### Objective

Ship the complete user-visible `@file` flow.

#### Work

1. Add `ComposerFileSuggestionList` above `PromptComposer` and connect it to the
   search model.
2. Add filename/parent-path presentation, indexing, empty, and compact error
   states.
3. Implement macOS and hardware-keyboard selection commands plus touch/pointer
   selection.
4. Implement Markdown-safe exact-range replacement and trailing-space cursor
   placement.
5. Dismiss suggestions on Escape, submit, focus loss, workspace change, and
   trigger invalidation.
6. Add accessibility labels, focus behavior, Dynamic Type checks, and compact/
   regular-width previews.
7. Add model/view tests for acceptance and dismissal. Use UI tests only for
   behavior that cannot be covered below the UI layer.

#### Exit checks

- A user can type `@`, search, choose a file, and submit the resulting prompt
  on macOS, iPhone, and iPad.
- Up/Down/Return/Tab/Escape work on macOS without submitting accidentally.
- Selecting one of multiple trigger ranges edits only that range.
- Long paths do not widen the composer or chat layout.
- VoiceOver reads the filename and relative path.
- File paths with Markdown-significant characters remain unambiguous.

### Increment 6 — watcher, ranking, and lifecycle hardening

#### Objective

Make the warm index reliable over long-running real workspace sessions.

#### Work

1. Exercise FFF watcher behavior during agent-created, moved, and deleted files.
2. Add an explicit reindex recovery path for watcher health failures, without
   running rescans on every query.
3. Verify Git ignore changes converge; trigger a bounded reindex if the pinned
   FFF version requires it.
4. Evaluate the pinned C API's supported access/query tracking. If it records a
   selected file without misrepresenting mere search results, add a one-way
   `workspace.recordFileSelection` notification; otherwise defer selection
   feedback and retain FFF's default ranking.
5. Verify idle eviction, reopen, daemon restart, and multi-client concurrent
   searches against real FFF indexes.
6. Add structured metrics for scan duration, warm query duration, result count,
   index count, and failures. Do not log raw query text or absolute paths.

#### Exit checks

- File changes converge within the watcher budget without a daemon restart.
- A forced reindex does not race search or close.
- No sensitive query/path values appear in normal logs.
- Reopening an evicted workspace produces a fresh healthy index.
- Ranking feedback is either implemented against a verified API or explicitly
  documented as deferred.

### Increment 7 — performance and release hardening

#### Objective

Prove the feature meets its budgets and that the production package cannot omit
or mismatch FFF.

#### Work

1. Add repeatable Go benchmarks for warm path queries and registry concurrency.
2. Run the 100,000-path corpus and record cold scan, warm p50/p95/p99, and
   native memory measurements.
3. Stage the real daemon and dylib into the final distribution layout.
4. Verify relocatable load paths, minimum macOS version, arm64 architecture,
   entitlements, and code signatures.
5. Launch the staged daemon outside the repository and execute a real RPC
   search from the Swift app.
6. Add CI checks for manifest checksums, `otool -L`, architecture, signing-stage
   layout, Go tests, generation drift, and Swift tests/build.
7. Document the exact FFF upgrade procedure and rollback process.

#### Exit checks

- Every performance budget is met or has a written measured exception.
- The packaged daemon launches with no Homebrew, Rust, Zig, FFF, or developer
  checkout installed.
- Removing or replacing the dylib makes the packaging smoke test fail.
- The signed Swift application can perform `@file` completion against a staged
  daemon.
- Rolling back FFF means reverting one manifest/header/dylib/wrapper-compatible
  change, not rebuilding search behavior.

## 8. Test matrix

### Go unit tests

- Native-result ownership and error conversion.
- Close idempotence and search/close synchronization.
- Root canonicalization and invalid directory rejection.
- Duplicate initialization coalescing.
- Scan warming and bounded wait behavior.
- Limit/query validation.
- Idle and maximum-count eviction.
- Shutdown.
- RPC parameter and response validation.

### Go + FFF integration tests

- `.gitignore` and `.ignore` behavior.
- Fuzzy matches and stable relative paths.
- Empty query.
- Unicode and Markdown-significant filenames.
- Create, rename, delete, and ignore-file changes.
- Repeated search and native-memory stability.
- Staged dylib loading outside the checkout.

### Swift unit tests

- Trigger parsing at arbitrary selections.
- Email and non-trigger `@` cases.
- Debounce and cancellation using a controllable clock/client.
- Out-of-order response suppression.
- Indexing retries and disconnect cleanup.
- Exact range replacement.
- Markdown reference escaping.
- Keyboard selection state.

### End-to-end acceptance

- Existing-thread completion.
- Local-draft completion before thread creation.
- Empty-query suggestions.
- Large workspace initial scan followed by warm searches.
- Agent-created file appears without restarting.
- Daemon reconnect and workspace index recreation.
- macOS keyboard and iOS/iPadOS touch paths.

## 9. Operational and upgrade rules

- FFF updates are explicit dependency changes, never automatic downloads.
- Update header and dylib together from the same tag/commit.
- Verify checksums, exported symbols, architecture, load commands, fixture
  behavior, memory ownership, watcher convergence, and benchmarks before merge.
- Keep the previous pinned artifact available until the staged daemon and Swift
  acceptance test pass.
- Do not expose an option for users to select arbitrary FFF dylibs.
- Do not load FFF from Homebrew or a global install in production.
- Do not treat a native crash as a recoverable query error; investigate and pin
  or roll back the dependency.

## 10. Definition of done

The feature is complete when:

1. `@` completion works for drafts and existing threads on supported Apple
   clients.
2. The daemon serves warm FFF searches from one bounded index per workspace.
3. Watcher updates, index eviction, shutdown, and failure behavior are tested.
4. The generated wire contract is canonical and reproducible.
5. The staged signed macOS distribution includes and loads the pinned dylib
   without machine-local dependencies.
6. Performance and memory budgets have recorded release-build measurements.
7. ACP/provider capabilities remain unchanged.
8. The FFF upgrade and rollback process is documented and verified.

## 11. References

- [FFF repository](https://github.com/dmtrKovalenko/fff)
- [FFF C header](https://github.com/dmtrKovalenko/fff/blob/main/crates/fff-c/include/fff.h)
- [Client contract generation](./CLIENT_GENERATION.md)
- [maiD architecture](./ARCHITECTURE.md)
- [Swift project instructions](../clients/swift/AGENTS.md)
