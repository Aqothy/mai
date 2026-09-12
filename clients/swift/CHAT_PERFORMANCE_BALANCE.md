# Chat performance, behavior and memory — updated 11 September 2026

**Current decision after the broader List pass:** retain the native container on macOS for its substantial heavy-scroll improvement, with the geometry corrections below. iOS continues to use List. A debug launch with `-ChatBenchmarkUseList YES` selects the original macOS List for comparison. List was temporarily restored as the default during this investigation; the final source restores native macOS after the targeted behavior checks.

This is a measured engineering tradeoff, not a claim of world-best performance. No tested simple List change matched the native heavy-scroll result. The native implementation still has more maintenance surface than List and does not achieve sustained 120 presented FPS in every workload.

## List versus native

The earlier optimized List measured 71.15 display-link callbacks/s at 8,000 pt/s, versus 118.31 for native. Adding vertical `fixedSize` to the List row was tested as a small layout experiment: **70.90 callbacks/s, p99 27.11 ms, maximum 981.15 ms**. It did not close the gap and was removed. This does not prove that every possible List optimization is exhausted.

After the native geometry fixes, another 20,000-character production-reducer stream measured **114.82 callbacks/s**, p99 **20.26 ms**, maximum **46.21 ms**, with exact source equality and completed-turn checks passing. That remains in the range of the earlier native repeats, versus approximately 97–98 for the matched List streaming repeats. These runs span different builds and times; small differences are not causal evidence.

All rates are **CADisplayLink callback pacing**, not verified presented FPS. Full-history scrubbing remains around 55–56 callbacks/s in the earlier valid native runs. The fixture contains repeated rich Markdown shapes, and List's estimated geometry differs from native measured geometry. See [the original report](CHAT_NATIVE_PERFORMANCE.md) for methodology and limitations.

## Broader List investigation requested by the user

A fresh eight-second `sample` profile of the 8,000 pt/s List sweep again found substantial time inside AppKit's visible-row preparation and automatic-height path. There were 5,631 main-thread samples; `NSTableView.prepareContentInRect:` appeared in 1,598 and `_doAutomaticRowHeightForRowView:row:` in 941 inclusive samples. These overlap and must not be added together. Profiling changes timing, so that run is diagnostic only. The already-prepared Markdown pipeline was not an identifiable major sampled cost. The explicit streaming text leaf already isolates incoming deltas; adding broad equality checks would not target the sampled row-sizing work.

The following are separate isolated builds and single unprofiled launches using the same 300-turn fixture and sweep driver:

| List implementation | 1,200 pt/s callbacks/s | 3,000 pt/s callbacks/s | 8,000 pt/s callbacks/s | Fast sweep p99 / max interval |
|---|---:|---:|---:|---:|
| Fresh original List | 113.40 | 106.33 | 68.78 | 53.55 / 949.85 ms |
| Single native rich-row view | 112.90 | 83.21 | 74.19 | 32.67 / 124.21 ms |
| Native rich-row view + reuse | 113.60 | 94.64 | 88.86 | 23.06 / 39.94 ms |
| Cached exact SwiftUI row heights | 111.55 | 103.28 | 62.19 | 82.66 / 1235.30 ms |
| Scheduled AppKit overdraw | 112.30 | 105.78 | 66.55 | 34.27 / 1083.90 ms |
| One List row per message | 110.86 | 102.82 | 74.69 | 178.43 / 411.86 ms |
| Message grouping + native view reuse | 31.43 | 48.87 | 27.18 | 263.44 / 395.84 ms |

The experiments target different costs:

- **Single native content view:** keep List's row lifecycle, replace settled prose/code/table view trees with one `NSViewRepresentable` reusing the existing native content renderer. Unsupported and live rows retain SwiftUI. This prototype used a font-metric code-header height and was not promoted or certified for complete visual parity.
- **View reuse:** additionally recycle native content views within the session's text-layout store. The pool is limited by the number of active representables and drains when none remain. Fast scrolling improved, but medium scrolling regressed and still stalled for 756 ms. It did not establish near-native consistency or earn a second production reuse mechanism.
- **Exact row heights:** measure settled rows through the existing SwiftUI renderer once, caching by row content, width, color scheme and Dynamic Type size, then apply a fixed frame. Interactive rows remain dynamically sized. This still did not eliminate List's estimate-correction stalls.
- **Scheduled overdraw:** use AppKit's public `prepareContent(in:)` after yielding, covering the viewport and one viewport on either side. No delegate replacement or private API. It did not improve the fast sweep.
- **Message grouping:** retain all content while reducing List rows by grouping adjacent blocks of the same message. The benchmark maps original row 4,800 to its containing group, rather than treating the smaller physical row count as the same index. Group realization produced 374–412 ms stalls.
- **Grouping with reuse:** combine the previous grouping and reusable native content. It was substantially worse and was rejected.

Grouping changes estimated geometry and begins at the containing message boundary; the pixel sequences are not identical. These are screening experiments, not statistically precise rankings. Their source patches and signed-image hashes are archived. All six broader List prototypes were removed from the experiment checkout after measurement, and none was copied into the main app. The earlier `fixedSize` attempt was also rejected. The best fast-sweep List candidate remained around 89 callbacks/s with an inconsistent medium sweep, while earlier repeated native sweeps were around 118–120. This supports retaining native for this macOS transcript; it does not establish a universal limit for SwiftUI List or prove that every conceivable redesign is exhausted.

## Retained native preparation improvement

The retained change skips duplicate SwiftUI measurement for settled prose and tables whose exact text/table layouts already exist. It uses the same source, width, spacing metrics and invalidation keys. Code headers and interactive rows keep their original SwiftUI measurement; there is no new cache or eager warming of extra chats.

The tests now pass **60 exact-height comparisons** against the existing SwiftUI row at three widths and all first/last-block combinations, covering short prose, wrapped formatted prose, resolved quoted prose, resolved tables and source-parsed rich tables. A separate test confirms code headers retain SwiftUI measurement.

After the laptop was closed, two resumed opening runs were rejected for a hidden window. The user confirmed the closed lid. A subsequent diagnostic build failed signing with `errSecInternalComponent`; signing subsequently recovered without changing keychain permissions or signing settings. The change has now been copied into the main checkout after targeted tests and behavior checks; the main checkout then built successfully and passed all 55 selected tests. After the laptop reopened, three visible launches per signed image measured full-history readiness at **8,598 / 8,327 / 8,340 ms before**, and **6,679 / 6,678 / 6,828 ms after**. The median fell about **20%**, or **1.66 seconds**. Every run aligned the same 5,851 items with unchanged 967,374-point total geometry. These are sequential same-evening launches of the previously signed baseline and candidate, with the same earlier driver; preparation/alignment is measured, not first-presented-frame latency or network restoration. Its patch is archived so the remaining work is concrete and reviewable. The speculative window-selection diagnostic was removed after the closed lid explained occlusion. Two visible candidate scroll launches measured **118.69 / 117.81 callbacks/s at 8,000 pt/s**, p99 **8.37 / 17.22 ms**, maximum **31.26 / 22.33 ms**. At 3,000 pt/s they measured **118.79 / 119.42 callbacks/s**. This retains the earlier native performance range; it is not a new scrolling-throughput claim from a preparation-only change.

The final implementation passed the real pagination/resize probe: 109 → 301 items, actual 700-point window width, unchanged 829.5-point offset within the anchor row, and **zero pagination and resize anchor error**.

## Native correctness corrections

1. A live height change moved visible rows but could leave already-prepared neighboring rows at their previous positions. A growing reply could therefore overlap a mounted working indicator. The new regression test reproduced a **50-point stale position**. Geometry changes now reposition every resident row before publishing the changed document extent.
2. Refreshing an unchanged active row replaced the identity used by its height reporter. A queued height report could then be discarded, with no further geometry event to correct the row. The new test reproduced a row remaining **16 points high instead of 150**. Content refresh and height invalidation are now distinguished, preserving the reporter for an unchanged live row while still invalidating changed source, width and theme.

Both tests failed before their corresponding fixes and pass afterward. An additional AppKit/SwiftUI integration test expands and collapses a live row through **500, 60 and 300 points**, checking its host frame, following-row position and complete scrollable extent. The earlier main-checkout run passed 52 selected tests. After the follow-up corrections below, the main checkout builds successfully and **55 selected tests pass**, with no failures or skipped tests. The main project build settings are unchanged.

Visual inspection during an actual synthetic production-event stream showed the working timer and indicator below incoming content. Actual thought disclosure displayed its complete text. Nested tool controls expanded, and the following answer stayed accessible. The initial offline fixture incorrectly advertised fetchable tool details, producing a connection error when expanded; its `detailAvailable` flag is corrected in the final source. This inspection is not a complete test of fetched remote tool payloads or every possible rich-content combination.

Scrolling an expanded individual thought five pages away and back resets that disclosure in **both** List and native; this was reproduced in each. The outer turn expansion remains. No extra disclosure-persistence machinery was added to imitate a behavior List itself did not preserve.

### Follow-up to the reported benchmark-window bugs

The user subsequently reported that the earlier native visual checks missed streaming overlap and jumping. Those checks were insufficient. Two additional regression tests now reproduce the underlying layout failures:

- A growing SwiftUI row could exceed its allocated AppKit host height and recenter upward. Holding the host top edge fixed while reducing allocated height from 300 to 60 points reproduced a **120-point upward movement**. An outer frame with a zero minimum height and top alignment preserves the content origin while continuing to report its full ideal height.
- Even with all resident neighbors repositioned, deferring that work to a task allowed the following row to retain its old position before painting. Height reports now update resident frames and document extent immediately. Only mounting newly exposed views stays deferred and coalesced. This removes the pending-height dictionary rather than adding another layout mechanism.

Both tests failed before these corrections and pass afterward. Fifteen targeted tests pass, including the 60 prepared-height comparisons and code-header fallback. Visual checks of the new native benchmark stream at 15 and 22 seconds showed the timer and whimsical text below the growing content. These sampled frames supplement the deterministic geometry tests; they cannot prove every presented frame is correct.

The current original List benchmark window was centered on opening and after scrolling through code blocks, with the transcript entirely to the right of the sidebar. The earlier reported misalignment has not been reproduced in this restored List source, so its exact experimental-build cause remains unconfirmed. No additional List alignment workaround was introduced.

The final post-fix scroll sweep measured **119.60 / 119.54 / 119.69 callbacks/s** at 1,200 / 3,000 / 8,000 pt/s, with **8.33 ms p99** in each sweep and maximum intervals **26.22 / 20.99 / 17.73 ms**. One launch confirms the fixes retained good ordinary sweep performance; its small improvement over earlier repeats is not attributed causally to the fixes. The pagination/resize probe also passed again with zero anchor error.

Two independent, unprofiled 20,000-character streams after the new fixes measured **114.74 / 115.35 callbacks/s**, p99 **19.75 / 20.00 ms**, maximum **49.82 / 52.71 ms**. Both source-equality and completion checks passed. Before these fixes, the prepared-height candidate measured **114.12 / 114.73**, maximum **53.80 / 49.09 ms**. This supports no material streaming regression; it is not evidence of a throughput gain from the correctness changes.

## Normal opening versus the full-history diagnostic

Three launches each of the same signed app, with normal five-turn pagination, prepared and aligned **109 timeline items**:

| Container | Readiness times |
|---|---|
| List | 787, 751, 760 ms |
| Native | 799, 784, 773 ms |

These measure local fixture selection-to-prepared-alignment. They exclude daemon/network restore and do not measure process startup or the first presented frame. The difference is small; there is no demonstrated multi-second normal-opening penalty here.

With the retained height reuse, three normal paginated openings measured **780 / 789 / 601 ms**, versus **782 / 772 / 768 ms** in the baseline. This does not establish a normal-opening improvement. The full-history median improvement from 8.34 to 6.68 seconds applies to loading all 300 turns before scrolling. Normal opening does not do that. Once thousands of rows really are loaded, native width changes can still require substantial remeasurement. That remains a real tradeoff and is not hidden behind the normal-opening numbers. Replacing exact offscreen heights with estimates would need additional correction and anchoring machinery; it has not earned that complexity with a verified implementation here.

## Five-chat memory measurements

The added `sessions` workload creates five separate synthetic ThreadStore sessions with unique message IDs and selects each through the real chat view. It retains prior sessions under the existing session policy; it does not multiply one process measurement by five. Only one chat is visible at a time. Each chat contains 300 turns, with normal pagination preparing only the recent page.

| Completed chats | List RSS | Native RSS |
|---:|---:|---:|
| 1 | 226.3 MiB | 190.1 MiB |
| 2 | 234.2 MiB | 204.5 MiB |
| 3 | 239.5 MiB | 210.9 MiB |
| 4 | 244.8 MiB | 216.4 MiB |
| 5 | 243.6 MiB | 222.5 MiB |

These paginated runs used the latest-width cache candidate before its rejection; with no width changes both cache designs retain the same measurements. These are first sampled process-RSS values after each readiness checkpoint, one launch per container. They include the entire app and runtime, are not isolated cache allocations or true peak memory, and are not a memory ceiling for arbitrary real chats. Synthetic content repeats fixture shapes; real content diversity, attachments and additional windows can change memory use. The normal five-chat result does not justify eagerly warming all five complete transcripts.

The current session policy retains up to five inactive subscriptions for 30 minutes and clears session presentation stores on eviction. The syntax-highlighting cache has an existing 8 MiB estimated-content budget. Native mounted views remain limited to the viewport, nearby preparation and their reuse pool. Text layouts and the global Markdown-plan cache are not a universal process-memory budget; no claim of bounded total memory is made.

A subsequent matched pair using the final retained cache and corrected window driver loaded **all 300 turns in each of five chats**, without resizing:

| Completed chats | List RSS | Native RSS |
|---:|---:|---:|
| 1 | 519.9 MiB | 268.7 MiB |
| 2 | 550.6 MiB | 292.2 MiB |
| 3 | 577.6 MiB | 316.7 MiB |
| 4 | 617.1 MiB | 337.9 MiB |
| 5 | 637.0 MiB | 360.0 MiB |

All ten checkpoints were aligned and visible. This single pair uses the same signed `balanced-final` app; native preceded List. Readiness plus the driver's settling interval was 8.6–9.9 seconds per native chat and 7.1–9.3 seconds per List chat. These deliberately unpaginated opening costs remain substantial in both containers. The memory figures use the same first-checkpoint RSS method and limitations as above.

The final implementation also completed five fully loaded chats with **four actual window widths per chat** (1,000, 800, 700 and 1,280 points), all checkpoints visible and aligned:

| Completed chats | Native RSS after resize sequence | Prepare + four resizes + settle |
|---:|---:|---:|
| 1 | 307.8 MiB | 28.87 s |
| 2 | 339.2 MiB | 27.81 s |
| 3 | 374.8 MiB | 28.40 s |
| 4 | 346.0 MiB | 28.11 s |
| 5 | 343.2 MiB | 27.69 s |

Each selected chat retained 14,700 width-specific layout entries. RSS fluctuates with allocator/runtime reclamation; the lower final value is **not** a demonstrated memory optimization relative to earlier runs. These are checkpoint RSS values, not measured peaks. Full-history reflow remains expensive: the approximately 28-second sequence includes initial preparation, four width changes and settling, rather than one resize or normal opening. An earlier before-run was interrupted to investigate the user's visual report and is explicitly excluded; this final run is a correctness/memory characterization, not a before/after resize-speed comparison.

## Rejected memory optimization

The text-layout store currently retains width-specific measurements. A candidate kept only the latest width per row. It was tested with five chats resized through four content-window widths, using the same driver for the original and candidate caches:

| Workload after five chats | Original cache | Latest-width-only candidate |
|---|---:|---:|
| Normal pagination: retained layouts per selected chat | 285 | 102 |
| Normal pagination: process RSS | 244.4 MiB | 243.2 MiB |
| All 300 turns loaded: layouts per selected chat | 14,715 | 5,550 |
| All 300 turns loaded: process RSS | 681.3 MiB | 652.0 MiB |
| Full-history fifth chat, prepare + four resizes + settle | 14.56 s | 15.83 s |

The full-history RSS difference was about 29 MiB, while revisiting an old width now required rebuilding discarded measurements. The candidate run was slower; a single sequential comparison is not sufficient to quantify that cost precisely. The ordinary five-chat RSS difference was negligible. **The candidate and its test were removed**: reducing a cache-entry counter alone does not earn extra production code. The rejected patch and measurements are archived.

A subsequent long native full-history resize run became hidden and was rejected. It also exposed a diagnostic bug: losing the key window could skip requested resizes. The final driver captures the app window independently of key status and fails at a hidden checkpoint. Rejected results are not included in comparisons.

## Reproduction

Use an already-built, signed optimized Debug app from Xcode MCP. The isolated app target uses `-O`, whole-module compilation and disabled coverage; dependencies remain Debug. Main project settings and the user's staged cleanup remain unchanged.

```sh
python3 clients/swift/scripts/benchmark-containers.py /path/to/mai.app /tmp/five-list --plan sessions --container list --paginated --runs 1
python3 clients/swift/scripts/benchmark-containers.py /path/to/mai.app /tmp/five-native --plan sessions --container custom --paginated --runs 1
python3 clients/swift/scripts/benchmark-containers.py /path/to/mai.app /tmp/resize-memory --plan sessionsResize --container custom --paginated --runs 1
python3 clients/swift/scripts/benchmark-containers.py /path/to/mai.app /tmp/open-native --plan open --container custom --paginated --runs 3
```

Omitting `--paginated` intentionally loads the complete fixture. Keep the window visible and avoid other CPU/GPU work. The memory plans sample RSS every 0.5 seconds and include fixed settling time in `preparedAndSettledMilliseconds`; that field is not first-frame latency. Output directories must be fresh. Builds are never performed by the runner.

[Raw measurements and rejected experiments](benchmarks/2026-09-10/balance/) accompany this report. The production changes retained from this pass are the native correctness fixes and reuse of already-computed prose/table heights. Rejected List and cache experiments remain archived only. Substantial remaining costs in disjoint text realization and large-history reflow are acknowledged; they are not evidence that a more complicated rewrite would be a better overall app.
