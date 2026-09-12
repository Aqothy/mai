# Chat performance review and optimization report

Date: 2026-09-02. Branch: `aq/macos-chat-performance-hardening`.
Scope: review of commits after `39154a5` (`74f8f1b`, `234bd48`, `287f177`),
fixes to the last commit, and new macOS scrolling work with measurements.

All numbers below are from **Debug builds** (`-Onone`) because the Xcode MCP
can only build the Run configuration and `xcodebuild` is off limits. Absolute
frame times are therefore pessimistic. The system frameworks (AppKit, SwiftUI,
TextKit) are optimized regardless, and they dominate the profiles, so the
*shape* of the profiles and the relative before/after deltas are
representative. Re-run the same benchmark on a Release/Profile build before
quoting absolute FPS.

## 1. Review of the branch commits

### `287f177` "more chat optimizations" (written by the smaller model)

**Incremental section projection (`ChatTimelineProjection`)**: keep, but the
plumbing was wrong.

- Real win. A full `ChatTimelineLayout.sections` walk costs ~5 ms per event
  at 2,500 entries and ~20 ms at 10,000 entries (Debug). Every structural
  streaming event (tool item start/finish, thought settle) re-walked the whole
  transcript on the main thread. Tail-only reprojection costs ~0.2 ms.
- Bug: the watermark lived in `ThreadSession` and was consumed by
  `store.consumeSelectedThreadTimelineChanges()` *inside `body`*. That mutated
  store state during view evaluation, and `warmInitialPage` also consumed it
  against a captured (possibly stale) `Thread` value while events kept
  arriving, which could leave the mounted timeline showing stale sections
  until the next mutation happened to touch the same index.
- Fix: the projection now owns its watermark (`invalidate(from:)`,
  `invalidateAll()`, `project(_:)`). `ThreadSession.apply` and snapshot
  replacement invalidate it; the view only calls `project`. The pre-mount warm
  pass uses a pure full walk and never touches the shared projection. The
  store getters and the consume method are gone.

**Cold-open warm gate (`warmedThreadID`)**: keep, with a fast path.

- The gate fixes a real problem (every settled message on a cold open parsed
  Markdown synchronously inside the first body), but it showed a "Loading
  Chat…" spinner on *every* thread switch, including threads whose caches
  were still warm.
- Fix: `ChatView.isInitialPagePrimed` checks the segment and render-plan
  caches with lookups only; a primed thread mounts immediately.

**Sampled thought streaming (`ChatSampledStreamingThoughtText`)**: removed.

- It polled the buffer on a 100 ms timer and parsed in `body` on the main
  thread. The rate limit it added is redundant: the daemon already coalesces
  reasoning chunks on a 50 ms ticker (`textFlushInterval` in
  `internal/orchestration/ingestion.go`), so the client sees at most 20
  thought updates per second. The sampler only halved that and added up to
  100 ms of display lag.
- Replacement (`ChatLiveThoughtText`): the same pattern the assistant message
  text uses. The leaf observes the buffer's revision, parses off the main
  actor in `.task(id: revision)` (a newer revision cancels an in-flight
  parse), and swaps the finished `AttributedString` into state. No timer, no
  interval constant, and one streaming pattern instead of two.

**`ChatTimelinePerformanceTests`** (was untracked): rewritten.

- The "cold open primed" and "reasoning sampled" benchmarks were tautologies
  (they measured cache hits and 1/12th of the work by construction). Removed.
- Kept the full-vs-incremental projection pairs, added a tail-only case, and
  extended the correctness test to cover coalesced invalidations.

**`ThreadEventReducer` change index**: correct. Every timeline mutation branch
reports its index; non-timeline branches report nil.

### `74f8f1b` "Preserve native viewport across chat folds": keep.

`captureBeforeContentExpansion` reuses the prepend anchor with a zero offset.
The anchor (first substantive visible row) is always at or above the toggled
header because the header must be visible to be clicked, so its index stays
stable through the fold. The `prepareForToggle` closure on the fold model is
a small hack but contained. No change.

### `234bd48` benchmark relabeling: keep. Honest naming of what the display
link measures.

## 2. New: production-path synthetic benchmark

The mock lab (`MockChatView`) drives the row renderers but not the production
`ChatTimeline` (sections, folds, pagination, native preserver). A real thread
needs the daemon. Added a daemon-free path that mounts the production
`ChatView` on a generated transcript:

```
mai -ChatPerformanceLab -ChatAutoBenchmark scroll -ChatBenchmarkSyntheticTurns 300
```

- `ChatSyntheticBenchmarkThread` (DEBUG) builds N finished turns: user prompt,
  thought, three tool steps (folded like production), and a rich final answer
  rotating through tables, fenced code, long Markdown, an essay, and short
  prose. `MaiApp` seeds a `ThreadStore` from it and skips the RPC connection.
- Results print as `CHAT_BENCHMARK_RESULT {...}` lines on stdout (the sandbox
  blocks the `/tmp` log file; stdout is now line-buffered). Traces print as
  `CHAT_BENCHMARK_TRACE`.
- Launching the binary directly from a terminal sometimes leaves the app idle
  before it finishes launching (LaunchServices never delivers the launch
  event). `open -a <bundle>` on the running instance wakes it. Harness script
  used for this report: `/tmp/bench-inline.zsh` (not part of the repo).

## 3. Profile of a 3,000 pt/s sweep (before)

Main thread, 25 s sample during the sweep, 300-turn transcript, Debug:

- 48% busy. Of the busy time, roughly:
  - SwiftUI List row hosting (`NSHostingView.layout`, AttributeGraph, Auto
    Layout constraint updates, `NSTableView` automatic row heights): ~55%
  - `ChatMacHorizontalScrollView` (an `NSHostingView` nested per code block
    and table, plus `fittingSize` queries and its own Auto Layout pass): ~17%
  - Core Animation commit/draw: ~12%
- App-level code (timeline body, sections, rows, prepared prose text views)
  was under 1%. Prose is fully prepared: zero layout-cache misses during
  sweeps.

Conclusion: the tables and code blocks the user notices are expensive because
each one was a second SwiftUI hosting view inside an already hosted row.

## 4. New: native macOS code blocks and tables

`ChatMacRichBlocks.swift` replaces `ChatMacHorizontalScrollView` (deleted).

- Code blocks: one selectable non-wrapping `NSTextView` inside a horizontal
  `NSScrollView` (same wheel pass-through as before). The attributed text,
  syntax colors, and size are prepared off the main actor by
  `ChatTextLayoutStore.prepareCodeBlocks` during the existing page preparation,
  keyed by block id and appearance. Highlighting is baked into the prepared
  layout, so scrolled-in code appears highlighted immediately (previously it
  flashed plain, then re-laid out). A row realized before preparation shows
  plain text synchronously and receives colors when the highlighter finishes;
  metrics are identical so the row never resizes. Code is now selectable.
- Tables: `ChatTableLayout` measures cells off the main actor (columns 96–280
  pt to content, 24 pt spacing, 12 pt vertical padding, hairline dividers,
  bold header, per-column alignment) and `ChatMacTableHostView` draws them
  in one `NSView`. Same look as the SwiftUI grid, no hosting view, no Auto
  Layout.
- Both report their height from the prepared layout, so `NSTableView`'s
  automatic row height pass gets an immediate answer.
- iOS keeps the SwiftUI implementations unchanged.
- Also: `ChatCodeHighlighter.warmUp()` runs at launch at utility priority so
  the first code block does not pay JavaScript context creation.

## 5. Results (300-turn synthetic transcript, Debug, two runs each)

Metric legend: avg = display-link callbacks per second; p95/p99/max =
callback interval in ms (budget 8.33 ms at 120 Hz); excess = late-callback
time per second of run.

| Sweep | Build | avg fps | p95 ms | p99 ms | max ms | excess ms/s |
|---|---|---|---|---|---|---|
| cruise 1,200 pt/s | before | 110.1 / 112.9 | 16.7 / 10.2 | 23.3 / 23.6 | 44 / 41 | 79 / 57 |
| cruise 1,200 pt/s | after | 112.1 / 112.4 | 16.7 / 16.7 | 19.9 / 20.3 | 25 / 33 | 65 / 62 |
| scroll 3,000 pt/s | before | 97.9 / 104.7 | 18.1 / 16.7 | 25.0 / 22.7 | 587 / 660 | 180 / 125 |
| scroll 3,000 pt/s | after | 103.7 / 103.9 | 16.7 / 16.7 | 20.2 / 22.0 | 150 / 153 | 135 / 134 |
| fling 8,000 pt/s | before | 70.7 / 79.3 | 23.6 / 20.2 | 35.8 / 31.2 | 771 / 1173 | 409 / 336 |
| fling 8,000 pt/s | after | 78.0 / 78.6 | 16.7 / 16.7 | 27.7 / 27.9 | 654 / 680 | 350 / 344 |

Profile after: main thread 62% idle during the 3,000 pt/s sweep (was 52%);
rich-block hosting 1.8% of samples (was 8.2%); `NSHostingView.layout` 7%
(was 13%); Auto Layout engine 6% (was 12%).

Streaming (mock lab, rapid-burst essay + component catalog, 24 s):
119.1 avg, p99 8.33 ms, 14 late callbacks, 7.3 ms/s excess. Streaming was
already incremental (leaf observation of the live buffer, stable-prefix
parser, equatable stable blocks) and stays smooth.

Scrolling while streaming (new lab plan `streamScroll`: 10k-row transcript,
rapid-burst reply streaming at the bottom while a 3,000 pt/s sweep scrolls
through history; four clean runs): 107–110 avg, p95/p99 16.7 ms, max
103–236 ms, 88–107 ms/s excess. That matches the non-streaming sweep, so
growth of the live row costs the rows above it nothing measurable. Two other
runs recorded 10–39 s display-link gaps at identical offsets; they coincided
with the app window being covered while the machine was in use (display
links pause for occluded windows) and never reproduced with the window
visible. The stall trace now records the window's occlusion state so such
gaps are not mistaken for main-thread stalls.

Unit projection benchmarks (Debug, per structural event):

| Case | full re-walk | incremental |
|---|---|---|
| 2,500 entries, mixed events | 4.6 ms | 0.9 ms |
| 10,000 entries, mixed events | 18 ms | 3.6 ms |
| 10,000 entries, tail-only events | 18 ms | 0.2 ms |

("Mixed" includes a mid-transcript approval resolution every third event,
which legitimately reprojects half the transcript.)

## 6. What still stalls, and why

The remaining 150 ms (3,000 pt/s) and ~650 ms (8,000 pt/s) stalls are inside
AppKit's `NSTableRowData _keepTopRowStableAtLeastOnce:andDoWorkUntilDone:` and
`_doAutomaticRowHeightForRowView:` (18% and 11% of the fling sample). SwiftUI
`List` on macOS estimates heights for unrealized rows; when a fast scroll
enters a region whose real heights differ a lot from the estimates, the table
realizes and re-measures rows in a loop and corrects the offset. They occur at
the same transcript offsets in both builds (about 35–55k points above the
bottom), independent of our code. App-level work during sweeps is under 2%.

Levers that remain, in order of expected impact:

1. **Fewer rows per screen.** A settled rich message is split into one List
   row per prose/rich segment (a code-heavy answer is ~15 rows). Each row
   pays SwiftUI hosting + Auto Layout + automatic row height. Now that code
   and tables are cheap native views with known sizes, one row per message
   (a vertical stack of native views) would cut per-row overhead several
   times over. Keep segmentation only for very large messages.
2. **Exact heights for unrealized rows.** Not possible with SwiftUI `List`.
   A custom `NSTableView`-backed timeline could feed prepared heights and
   remove the estimate-correction loop entirely. This is the real fix for
   scrubbing but is a large rewrite.
3. Release-build measurement to confirm the Debug-only overhead in
   `ChatTimelineRenderRowView`/`ChatMessageRow` is negligible.

## 7. Streaming: how it works today (no change needed)

- Text deltas append to a `ThreadStreamingText` reference observed only by
  the live message leaf; they do not invalidate the timeline.
- `ChatIncrementalMarkdownRenderPlanner` keeps settled blocks and reparses
  only the unstable tail; stable blocks are `Equatable` so SwiftUI skips them.
- Structural events (tool items, thoughts) invalidate only the changed suffix
  of the section projection (section 1).
- Thoughts use the same leaf pattern; the daemon's 50 ms flush cadence bounds
  their update rate.

## 7b. Cursor rects while scrolling (not changed)

About 20% of main-thread samples during a sweep with the mouse over the
transcript are `routeCursorRect` → `_NSFindWindowUnderMouse` → SkyLight
IPC, driven by `ChatSelectableNSTextView.resetCursorRects` adding an I-beam
cursor rect per visible text view; AppKit re-routes every rect on each
scroll. If the I-beam over prose is worth keeping, a single tracking area on
the timeline that sets the cursor by hit-testing would cost one query per
mouse move instead of one per text view per frame.

## 8. Startup and quality-of-life notes

- Highlighter warm-up moved off the launch path (section 4).
- Cold open of a thread whose caches are warm no longer flashes a spinner.
- Code blocks are selectable on macOS.
- Not changed: `receiveNotification` decodes each event on the main actor.
  Text deltas are ~200 bytes, so this is tens of microseconds; not a hot spot.

## 9. Files touched

- `Features/Chat/ChatTimelineProjection.swift` (rewritten API)
- `Features/Threads/ThreadSession.swift`, `ThreadStore.swift` (invalidation)
- `Features/Chat/ChatView.swift` (primed fast path, warm pass, live thought
  leaf, rich block preparation, highlight theme in preparation key)
- `Features/Chat/MockChatView.swift` (`streamScroll` lab plan)
- `Features/Chat/ChatMacRichBlocks.swift` (new), `ChatMacTextLayout.swift`
  (code/table caches, shared inline attributed-string builder,
  `contentWidth`), `ChatTextLayout.swift` (request types, protocol defaults)
- `Features/Chat/ChatMarkdownCodeBlockView.swift`, `ChatMarkdownTableView.swift`,
  `ChatMarkdownRichContentView.swift` (macOS uses native views)
- `Features/Chat/ChatMacHorizontalScrollView.swift` (deleted)
- `Features/Chat/ChatCodeHighlighter.swift` (`warmUp`)
- `Features/Chat/ChatSyntheticBenchmarkThread.swift` (new, DEBUG),
  `ChatFramePacingBenchmark.swift` (synthetic launch arg, stdout traces,
  stall trace), `ContentView.swift` (synthetic store, highlighter warm-up)
- `maiTests/ChatTimelinePerformanceTests.swift` (rewritten)

## 10. How to reproduce

```
# production timeline, synthetic 300-turn transcript, three sweeps
mai -ChatPerformanceLab -ChatAutoBenchmark scroll -ChatBenchmarkSyntheticTurns 300

# mock lab scroll / streaming / scroll-while-streaming passes
mai -ChatPerformanceLab -ChatAutoBenchmark scroll
mai -ChatPerformanceLab -ChatAutoBenchmark stream
mai -ChatPerformanceLab -ChatAutoBenchmark streamScroll

# projection micro-benchmarks
maiTests/ChatTimelinePerformanceTests
```

Read `CHAT_BENCHMARK_RESULT` JSON lines from stdout. If the app sits idle with
no output after a few seconds when launched from a terminal, run
`open -a <path to mai.app>` once to deliver the launch event.
