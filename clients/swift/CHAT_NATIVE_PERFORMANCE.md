# Native chat performance — 10 September 2026

The native transcript is now installed in the **main working tree**, as unstaged changes. It is the default macOS chat container; iOS retains its existing List. The user's staged cleanup and Xcode project settings are unchanged. The implementation substantially improves ordinary scrolling and streaming, but **does not achieve sustained 120 FPS during extreme full-history scrubbing**.

## Measurements

These are **CADisplayLink callbacks per second**, not verified presented FPS. The display supports 120 Hz. Scroll measurements use a prepared 300-turn rich Markdown fixture, 5,851 native timeline items including the end marker, 760-point row width, and roughly 967,374 points of native content. Preparation is excluded from scrolling measurements.

| Workload | List callbacks/s | Native callbacks/s | List → native p99 interval | List → native maximum interval |
|---|---:|---:|---:|---:|
| 1,200 pt/s | 113.01 | 119.90 | 20.58 → 8.33 ms | 29.30 → 17.07 ms |
| 3,000 pt/s | 108.37 | 119.58 | 20.63 → 8.33 ms | 27.60 → 17.62 ms |
| 8,000 pt/s | 71.15 | 118.31 | 27.81 → 16.69 ms | 940.25 → 22.00 ms |

These September 10 sweeps are one launch per container, corroborating the earlier repeated native sweeps around 118–120 callbacks/s. The native sweep preceded removal of unused coordinator state, formatting, an iOS diagnostic guard, and stricter preparation-timeout reporting; List used the subsequent signed snapshot. Neither difference changes row rendering. Each run records its code-image hash. List's estimated row positions and content extent differ from native measured geometry, so identical logical starting rows and velocities do not produce pixel-identical workloads. This is evidence of a large practical gain, not a precisely controlled percentage improvement.

| Additional workload | Result | Evidence / qualification |
|---|---|---|
| Streaming 20,000 characters through the production reducer | Final native: **116.16 callbacks/s**, p99 16.67 ms, max 40.67 ms | Exact source text and completed turn verified |
| Matched streaming repeats, September 9 | List **96.81 / 98.48**, native **114.80 / 115.36** callbacks/s | Two launches per mode using the same signed app; final native result above is a later build |
| Scrolling at 3,000 pt/s while streaming | List **103.31**, native **119.70** callbacks/s | Earlier matched build; one launch each, text/completion verified |
| Extreme full-history scrub, two seconds per traversal | Native **55.12 / 56.07** callbacks/s | Same-build native-body reuse experiment; **well below 120** |
| Load older history, then resize the actual window to 700 points | **0-point anchor error** for both operations | Final build; 109 → 301 items, same row and 829.5-point within-row offset |

Scrubbing traverses nearly a million points every two seconds, exposing mostly unrelated rows each frame. It is much harsher than the 8,000 pt/s sweep. Native body reuse improved matched scrub runs from 49.41 / 50.68 to 55.12 / 56.07 callbacks/s, but did not remove the remaining text/layout/realization cost. No claim of a full-history 120 Hz solution is warranted.

Opening the ordinary five-turn initial page previously prepared and aligned 109 items in **789 ms**. Forcing the entire 300-turn fixture loaded took **8.09 seconds**, including 5.34 seconds of row measurement. These are single diagnostic measurements of selection-to-prepared-alignment, **not process startup or first presented frame**. Existing pagination keeps that full-history cost out of normal opening. No new app-startup speedup is claimed.

## Retained implementation and why it is worthwhile

- **Bounded native realization:** `ChatNativeTranscript` uses NSScrollView, stable row geometry, binary-search viewport lookup, and a bounded pool of row views. It avoids repeated List hosting/layout work while scrolling through completed rich content.
- **Scheduled nearby preparation:** visible rows mount immediately; one viewport of neighbors is prepared incrementally in a yielding main-actor task. Earlier matched experiments showed a substantial gain over synchronous neighboring layout. Tasks cancel when the viewport or content changes.
- **Reuse existing rendering:** completed prose, code and tables use their existing AppKit bodies directly. Interactive and unsupported rows retain SwiftUI. Three lazily created body views per pooled native host avoid repeated construction. Reuse clears selection, copy feedback and horizontal position when content changes.
- **Explicit geometry invalidation:** stable identity, content key and width determine reusable completed-row heights. Theme changes refresh presentation. Live rows report height changes; completed history is not remeasured for each streamed chunk. Width changes still require loaded-history remeasurement.
- **Shared behavior and styles:** both containers use the same native scroll-position controller. Stable identities preserve reading position across prepends and reflow. Rich-block styling constants are shared with the existing SwiftUI views. Native text selection, horizontal scrolling, copy controls and accessibility remain available.

This adds a real maintenance obligation: custom row geometry and view lifetime management. The large measured scrolling gain justifies it; the implementation does not establish an optimal architecture for every workload. The discarded NSTableView implementation, TextKit 2 experiment, ineffective jump-prewarm suppression and ineffective stateless host-reuse experiment are absent from active code. Their results remain in the historical report.

## Correctness and validation

The main checkout builds successfully through Xcode MCP. **49 selected tests pass**, covering viewport boundaries, bounded host reuse/order, completed-row invalidation, streaming-tail geometry, native scroll intent, initial alignment cancellation, pagination, anchors, native selection/accessibility and existing timeline behavior. The isolated source also builds for the iPhone 17 simulator; its platform guard correction is included in the main checkout.

The final programmatic lifecycle probe passed real history loading and actual window resize with zero measured anchor drift. Visual/accessibility inspection checked readable rich content, activity disclosure, jump-to-bottom, horizontal code scrolling, table content, and correct header/copy/body order. This is targeted validation, not exhaustive device or accessibility certification.

Two correctness fixes accompanied the container work: preserving the previous clip origin during resize before applying row reflow, and completing the initial-alignment callback when user scrolling cancels the initial pin. The latter has a regression test that failed before the fix and passed afterward.

Benchmarks reject hidden windows, missing display links, timeouts, incomplete preparation and mismatched streamed text. The September 10 monitor also observes window occlusion changes independently of frame callbacks and has a watchdog, preventing a stopped display link from silently hanging. Rejected runs are excluded. The first attempted final sweep hung before this fix and produced no usable result.

## Remaining substantial opportunities

The clear remaining targets are **text/view realization during disjoint jumps** and **remeasuring large loaded histories after width changes**. More prewarming cannot cheaply cover arbitrary jumps through an entire transcript. Keeping all rows alive would trade this problem for memory and startup cost. Estimated heights with progressive correction could reduce full-history preparation, but introduce scrollbar and anchoring complexity; that is not a proven improvement here. A different text/rendering architecture would require another correctness and performance study.

Ordinary fast scrolling is now close to the display's callback ceiling. Extreme scrubbing and streaming still miss it, and callback rates cannot establish presented-frame throughput. There remains room for substantial improvement in those workloads; this report does not claim that only micro-optimizations remain.

The earlier investigation did **not** establish that the staged cleanup caused the stalls. The inspected beta branches did not contain this macOS rendering path. No speculative cleanup rollback or beta-branch change was made.

## Reproduction and artifacts

Use an already-built, signed optimized Debug app from Xcode. The measured app target used `-O`, whole-module compilation and disabled coverage in the authorized isolated checkout. Dependencies remained Debug; this is **not a full Release distribution benchmark**. Main project settings were not changed, so its ordinary unoptimized Debug run should not be expected to match these numbers.

Keep the app visible on a 120 Hz display, quit other instances, and avoid builds, profiling or UI interaction while measuring. Every command needs a fresh output directory. The runner builds nothing and exits only its own launched app process.

```sh
python3 clients/swift/scripts/benchmark-containers.py /path/to/mai.app /tmp/native-scroll --container custom --plan scroll --runs 3
python3 clients/swift/scripts/benchmark-containers.py /path/to/mai.app /tmp/list-scroll --container list --plan scroll --runs 3
python3 clients/swift/scripts/benchmark-containers.py /path/to/mai.app /tmp/native-stream --plan stream --runs 3
python3 clients/swift/scripts/benchmark-containers.py /path/to/mai.app /tmp/native-scrub --plan scrub --scrub-period 2 --runs 3
python3 clients/swift/scripts/benchmark-containers.py /path/to/mai.app /tmp/native-lifecycle --plan lifecycle --paginated --runs 1
```

The final signed benchmark app is locally available at `/tmp/maid-chat-perf/containers-final-maintainable/mai.app`. The maintained runner defaults to the native container and removes obsolete experiment switches. Older archived runners remain available for older signed snapshots.

[Final measurements](benchmarks/2026-09-10/summary.json), [main-checkout tests](benchmarks/2026-09-10/main-tests.txt), [source hashes](benchmarks/2026-09-10/promoted-source.json), and [the source patch](benchmarks/2026-09-10/native-transcript.patch) are archived alongside filtered logs and per-run metadata. The patch is relative to the user's preserved index, excluding their cleanup and all project settings. [Historical experiments](CHAT_CONTAINER_EXPERIMENTS.md) contain the matched streaming, reuse, failed approaches and presentation-trace limitations.
