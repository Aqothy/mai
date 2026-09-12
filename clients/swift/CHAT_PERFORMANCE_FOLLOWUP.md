# Chat performance follow-up — 7–8 September 2026

**Update, September 10:** the validated native container is now in the main working tree. See [the current report](CHAT_NATIVE_PERFORMANCE.md) for final results, limitations and reproduction. Statements below about an isolated-only prototype describe earlier checkpoints.

This follows `CHAT_PERFORMANCE_REPORT.md`, using HEAD `88d7d7e` plus the
user's staged cleanup as the starting point. The staged index was preserved.

## Scope and measurement

Builds use Xcode MCP, Debug (`-Onone`), on a Mac14,9 running macOS 26.5.2,
with the macOS 27 SDK and a 120 Hz display. Scroll tests mount the production
timeline with 300 synthetic turns (5,850 rendered rows), the same rich
Markdown fixtures and 1,280 × 900 window as the previous report.

The numbers measure **display-link callback pacing, not presented frames**.
They are useful for main-thread stalls but cannot establish that the app
actually presents 120 frames/s. This is an interactive workstation, so small
differences must be treated cautiously. Profiler runs are separate from
comparative measurements. The first exploratory baseline involved sampling
and a window inspection; it is excluded from comparisons.

`scripts/benchmark-chat.py` launches an already-built app through
LaunchServices, captures stdout/stderr, waits for completion, exports JSON,
and terminates only that build. It checks report counts, warm-up timeout, and
recorded window occlusion. It does not build, alter project settings, or send
prompts to an agent. A code-image hash identifies each tested binary.

```sh
python3 clients/swift/scripts/benchmark-chat.py /path/to/mai.app /tmp/chat-results --runs 3
python3 clients/swift/scripts/benchmark-chat.py /path/to/mai.app /tmp/chat-stream --plan stream --runs 1
python3 clients/swift/scripts/benchmark-chat.py /path/to/mai.app /tmp/chat-stream-scroll --plan streamScroll --runs 1
```

Keep the app visible during measurement. Warm-up fills the content caches;
it does **not** pre-realize every native List row. Row realization and height
estimation costs remain in the measured path. Streaming uses the existing
mock lab; it does not establish live-provider latency.

## Cleanup versus committed HEAD

An isolated worktree built untouched HEAD, then the exact staged Swift patch.
App bundles were saved separately; neither includes the cursor experiment.

| State/run | 1,200 pt/s callbacks/s | 3,000 pt/s callbacks/s | 8,000 pt/s callbacks/s | Fast-sweep p99 / max (ms) |
|---|---:|---:|---:|---:|
| HEAD A | 109.8 | 104.2 | 79.8 | 42.6 / 755 |
| Cleanup A | 111.6 | 96.0 | 64.2 | 101.1 / 788 |
| HEAD B | 113.8 | 103.8 | 63.0 | 83.5 / 1,092 |
| Cleanup B | 113.5 | 105.4 | 74.0 | 71.0 / 758 |

There is **no demonstrated cleanup regression** in these runs. The fast
sweep varies substantially on unchanged HEAD too. One cleanup run being
slower is insufficient to attribute the difference to source cleanup. This
does not prove equivalence for every workload.

Inspection found no extra repeated parsing, lost cache, or added historical
timeline work in the staged scrolling path. Removing the layout-store
protocol preserves its main-actor isolation; the rich-block selectable-prose
flag was equivalent to `!isStreaming`; the removed scroll-state property had
no readers. The fixture's removed render-throttle field was unused.

All eight `aq/beta-01-*` through `aq/beta-08-*` branches lack this branch's
`ChatMacTextLayout`, `ChatMacRichBlocks`, and `ChatTimelineProjection` files.
The top beta branch uses UIKit text configuration. No speculative cleanup
rollback was made to the beta stack. This is source inspection, not a beta
performance benchmark.

## Retained changes

### Use NSTextView's native cursor tracking

The custom `ChatSelectableNSTextView.resetCursorRects()` called the native
implementation and then added another I-beam rectangle. Native NSTextView
already owns cursor tracking for selectable text. Delete the subclass and
construct NSTextView directly, for both prose and native code blocks.

An intermediate experiment replaced cursor rectangles with a persistent
tracking area. A focused test found **two** cursor-update tracking areas:
one native and one custom. That experiment was discarded. The final version
has one native area after repeated resize/tracking updates, remains
selectable, and adds no cache, observer, timer, or invalidation policy.

Apple documents [NSTrackingArea](https://developer.apple.com/documentation/appkit/nstrackingarea)
and describes cursor-rectangle APIs as legacy in its
[tracking-area guide](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/EventOverview/TrackingAreaObjects/TrackingAreaObjects.html).

### Preserve native code accessibility

The new native code renderer explicitly hid its NSTextView from
accessibility. Its surrounding SwiftUI group names the code block but does
not provide the code's contents. Remove that suppression so the native text
and selection are accessible again. Tables already supply their text via
the surrounding accessibility value.

## Retained-change measurements

To isolate cursor deletion, the later sequence alternated cleanup C, native A,
cleanup D, native B. Each row below reports the two-run range, not a confidence
interval. “Native” is cursor deletion alone; “final” adds accessibility repair.

| Sweep | Cleanup callbacks/s | Native callbacks/s | Cleanup max stall | Native max stall |
|---|---:|---:|---:|---:|
| 1,200 pt/s | 112.0–112.6 | 112.1–112.6 | 46–50 ms | 30 ms |
| 3,000 pt/s | 98.2–100.3 | 98.7–100.6 | 421–472 ms | 406–526 ms |
| 8,000 pt/s | 60.2–66.9 | 67.6–67.7 | 931–1,013 ms | 713–733 ms |

The fast-sweep average increased about 6% in this small comparison. Normal
scrolling averages were essentially unchanged. Earlier unchanged-HEAD runs
span a much wider range, so this is suggestive, not a statistically established
speedup. The justification for retaining cursor deletion is eliminating
redundant custom behavior and reducing maintenance, without extra machinery.

The final build's complete sweep was:

| Sweep | Callbacks/s | p99 interval | Maximum stall |
|---|---:|---:|---:|
| 1,200 pt/s | 111.9 | 20.5 ms | 27.9 ms |
| 3,000 pt/s | 100.2 | 20.8 ms | 466.0 ms |
| 8,000 pt/s | 74.8 | 28.8 ms | 823.6 ms |

Existing mock essay/catalog streaming was also checked, one run per state:

| Workload | Cleanup → final callbacks/s | Cleanup → final p99 | Cleanup → final max stall |
|---|---:|---:|---:|
| Streaming | 118.6 → 118.9 | 8.33 → 8.33 ms | 91.4 → 22.4 ms |
| Streaming while scrolling | 108.2 → 111.9 | 18.2 → 18.1 ms | 93.7 → 94.5 ms |

These single streaming runs do not establish a throughput improvement. They
check the retained changes under streaming load; they do not measure live
provider/network behavior or prove that very long active code fences are cheap.

Raw JSON, compressed console output, binary hashes, and environment details
are in [benchmarks/2026-09-07](benchmarks/2026-09-07). `cursor-*` files belong to
the rejected custom tracking-area experiment; use `native-*` and `final-*`
for retained changes. `paired-*`, `no-adjust-*`, and `fixed-prose-*` are rejected
experiments. The stale-build attempt is excluded from the exported results.

## Experiments rejected

These were tested independently on top of the initial cursor-tracking
experiment, then removed:

| Experiment | 3,000 pt/s max stall | 8,000 pt/s callbacks/s | 8,000 pt/s max stall | Decision |
|---|---:|---:|---:|---|
| Pair prose with the following rich block | 55 ms | 63.3 | 1,471 ms | Reject: moves the estimation problem and worsens the worst stall. |
| Disable automatic offset adjustment | 462 ms | 72.6 | 861 ms | Reject: does not eliminate AppKit's row-height correction work. |
| Explicit SwiftUI frame using prepared prose height | 475 ms | 64.5 | 831 ms | Reject: duplicates layout information without a demonstrated win. |

These are exploratory single runs, not statistical estimates. Pairing never
crossed message boundaries and preserved source segmentation, but its
changed height distribution made the fastest case worse. Grouping whole
messages would further risk eager realization of giant rich messages.

### Incrementally append active code into the display TextKit graph

A 500-chunk code-layout microbenchmark measured 1.199 s for rebuilding the
measurement graph per chunk versus 0.367 s for incrementally updating the
native display graph (10 XCTest iterations each). **This is not an accepted
speedup:** geometry parity tests failed. Newline/tab cases reported a document
width of 10,000,032 pt instead of 129–142 pt, and clearing text changed empty
height by one point. Text content and selection preservation passed, but that
is insufficient for a correct renderer.

The experiment and its temporary tests were removed. A future attempt needs
consistent measurement semantics and an end-to-end long-code streaming
comparison; a second mutable measurement graph or width-clamping workaround
is not justified by the incomplete microbenchmark. Diagnostic test summaries
are retained as `rejected-streaming-*.txt.gz`.

## Validation

After removing the streaming experiment, Xcode MCP built the macOS app and
test targets successfully on 8 September at 00:25. All 40 selected tests passed:
timeline layout, pagination/folding, scroll-follow intent, incremental
projection equivalence, native selection/cursor ownership, and code
accessibility. See `final-tests.txt.gz` in the artifact directory.

The retained production changes affect only macOS-conditional code. This pass
did not build or benchmark iOS. The programmatic harness was exercised on all
three plans and Python syntax was checked. `git diff --check` passed; the staged
Swift patch hash still matches the saved original. No project files were edited.

## Remaining bottleneck and engineering assessment

The fresh sample again contains long main-thread stacks in
`NSTableRowData._keepTopRowStableAtLeastOnce:andDoWorkUntilDone:` and automatic
row-height calculation, with SwiftUI hosting/layout underneath. Cached
Markdown is not the same as cached native List row geometry. Fewer parser
calls will not remove this loop.

The existing incremental projection and streaming leaf observation remain
worth keeping. Text deltas update the live text object; historical rows do
not observe its revisions. Structural changes invalidate a section suffix.
Native code/table rendering removes nested SwiftUI hosting, a substantial
architectural simplification relative to the previous wrapper.

Consistent 120 Hz scrubbing is **not established**. A larger native timeline
with authoritative row heights remains a possible route, but must cover
pagination anchors, folds, width/font changes, attachments, selection,
accessibility, and streaming before it can replace List. Hijacking SwiftUI's
private table delegate, pre-realizing the whole history during benchmark
warm-up, or accepting offset jumps would conceal costs or sacrifice behavior.

The lower-complexity change retained here deletes duplicate work; it should
not be described as solving the native row-estimation bottleneck.
