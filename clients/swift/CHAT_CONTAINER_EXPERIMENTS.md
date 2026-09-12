# Native chat container experiments — 8 September 2026

**Update, September 10:** the validated native container is now in the main working tree. See [the current report](CHAT_NATIVE_PERFORMANCE.md) for final results, limitations and reproduction. Statements below about an isolated-only prototype describe earlier checkpoints.

**Result: substantial improvement in ordinary fast scrolling, but no demonstrated sustained 120 presented FPS, and full-history scrubbing still misses the target.** The prototype remains in `/tmp/maid-perf-head`. No replacement container has been installed in the main checkout.

This extends [the earlier follow-up](CHAT_PERFORMANCE_FOLLOWUP.md). That investigation did not establish a regression caused by the staged cleanup; comparable stalls occurred on untouched HEAD. The inspected beta branches lack this macOS rendering path.

## What was tested

All containers use the existing rich Markdown row views and the same 300-turn synthetic transcript: 5,850 rows, 760-point content width, approximately 967,350 points of measured content. The app window is approximately 1,280 × 900 on a 120 Hz display. Results below measure **CADisplayLink callback pacing**, not displayed-frame throughput.

The optimized experiments use the app target's `-O`, whole-module compilation, and disabled coverage, authorized for the isolated checkout. They still use Debug configuration and DEBUG fixtures; dependencies were not rebuilt as a full Release distribution. Builds and tests use Xcode MCP. Comparisons exclude simultaneous profiling and UI inspection.

Three approaches were evaluated:

1. Existing SwiftUI `List`.
2. `NSTableView` with explicit delegate heights, automatic heights disabled, and reusable SwiftUI hosting cells.
3. Native `NSScrollView` with a flipped document view, prefix-sum row positions, binary-search viewport lookup, and a bounded pool of SwiftUI hosting views. It retains one viewport of neighboring rows on either side. Visible rows are mounted immediately; neighboring rows can be prepared incrementally in a yielding main-actor task.

The custom container retains selectable native text, code-block horizontal scrolling and copy controls. It does not replace rich content with screenshots or blank placeholders. Scheduling also forces offscreen view layout: merely creating an unlaid-out host postpones the same cost until exposure.

## Ordinary scrolling

Each pass starts at logical row 4,800 and sweeps in both directions. Exact offsets differ for List/table because their geometry differs. List and custom rows therefore do not traverse pixel-identical sequences. The most direct scheduling comparison is the same v2 custom binary with preparation enabled versus disabled.

| Variant | 3,000 pt/s callbacks/s | 8,000 pt/s callbacks/s | 8,000 pt/s p99 / max interval |
|---|---:|---:|---:|
| Optimized List, A | 109.17 | 69.91 | 39.14 / 971.06 ms |
| Custom, synchronous neighboring layout, A | 112.50 | 100.94 | 18.65 / 30.57 ms |
| Custom, scheduled neighboring layout, A | 119.42 | 119.87 | 8.33 / 17.84 ms |
| Custom, scheduled neighboring layout, B | 117.00 | 118.81 | 8.37 / 17.95 ms |

This supports a meaningful scheduling benefit, not a micro-optimization. It does not show that every frame is delivered on time: both near-120 runs still contain late callbacks. The workstation was interactive and runs span different times; small differences should not be interpreted as causal.

There is also a substantial preparation cost: measuring all 5,850 SwiftUI rows takes roughly 4.7–5.7 seconds, after the transcript's existing text preparation. That cost is outside the sweep. This is a diagnostic ceiling experiment, not an acceptable new cold-open path. Production currently loads a smaller initial page; a viable implementation would prepare bounded pages, cache geometry with explicit invalidation, and preserve anchors when pages arrive. That approach has not yet been measured here.

## Full-history scrollbar scrubbing

The v3 driver traverses the entire scrollable history in two seconds, repeatedly reversing direction: about 483,000 pt/s. Unlike the 8,000 pt/s sweep, most successive viewports share no rows.

| Measurement segment | Callbacks/s | p99 interval | Maximum interval |
|---|---:|---:|---:|
| 20 seconds | 44.10 | 38.33 ms | 50.00 ms |
| 24 seconds | 43.33 | 38.74 ms | 54.60 ms |
| 16 seconds | 42.56 | 38.23 ms | 53.58 ms |

These are three segments of one valid custom-scroller launch, not three independent repetitions. The v3 raw JSON still carries the ordinary sweep labels; `metadata.json` records `scrubPeriodSeconds: 2.0`. Those labels must not be read as velocities for this run. The current source revision fixes the labels.

The first custom launch and the attempted List scrub comparison were rejected because the window was occluded. They provide no valid before/after comparison. The valid custom result is sufficient to show that this prototype does **not** meet the full-history 120 Hz target.

An additional experiment suppressed neighbor preparation when the new visible row range did not overlap the previous one. Xcode signing was initially blocked, then recovered at 21:31. The experiment built and its tests passed, but subsequent comparisons did not establish a useful gain:

| Segment | Previous version, evening repeat | Jump suppression |
|---|---:|---:|
| 20 seconds | 39.10 callbacks/s | 39.69 callbacks/s |
| 24 seconds | 40.48 callbacks/s | 40.39 callbacks/s |
| 16 seconds | 42.48 callbacks/s | 40.32 callbacks/s |

These runs were sequential on the same workstation, with jump suppression tested first. Each column is one launch with three segments. Differences are small and inconsistent; the added condition was **removed**. The retained source uses the prior scheduling behavior, corrected scrub labels, and a separate `ChatNativeTableExperiment.swift` file. The signed v4 binary and its patch retain the rejected experiment for reproducibility.

## Correctness findings

The native table prototype fails its 5,850-row geometry test: scrolling between distant variable-height rows produced position errors of approximately 1,101–1,166 points despite explicit heights and disabled automatic sizing. A smaller 100-row test had passed. Plain table style, a wrapper cell and explicit height invalidation did not resolve the observed behavior. This rejects the current implementation, not every possible NSTableView design.

The custom prototype passed row-boundary lookup and bounded-host/reuse tests. A visual inspection found readable rich content and native controls. Recycling originally reversed accessibility child order; v3 inserts hosts in document order, and a subsequent accessibility inspection showed sections in ascending order. The automated ordering assertion now passes.

After signing recovered, all three custom-scroller tests passed, including jump suppression. After removing the unhelpful optimization and moving the prototype into its own file, Xcode built successfully again and the two retained custom tests passed. The earlier table geometry failure remains a known limitation of the separate table experiment; it was not fixed or counted as passing. See [initial results](benchmarks/2026-09-08/container-tests.txt), [v4 results](benchmarks/2026-09-08/custom-tests-v4.txt), and [current custom results](benchmarks/2026-09-08/custom-tests-current.txt).

At the September 8 checkpoint, this was not a production replacement: live-content invalidation, streaming heights and the full timeline contract were incomplete. The September 9 work below addresses several of these gaps; production readiness is still unproven.

## Presentation trace

An Animation Hitches trace was captured separately from comparative runs. Matching the app's update swap IDs to frame-lifetime events produces many approximately 8.33 ms-spaced lifetime completions. This is evidence against a blanket 60 Hz limit for this native path, but not a measurement of sustained presented FPS. Update events are sparse in some parts of the trace, and multiple pipeline events must not be counted as distinct displayed frames. Frame-lifetime duration also is not the inter-presentation interval.

The large trace remains under `/tmp/maid-chat-perf/profile-animation/animation.trace`; its environment-bearing table of contents is deliberately not copied into the repository. No presented-120 claim is made.

## Artifacts and next decision

[Raw result JSON and benchmark-only log lines](benchmarks/2026-09-08/summary.json), per-run code-image hashes, and [the launch harness](benchmarks/2026-09-08/benchmark-containers.py) are retained under `benchmarks/2026-09-08/`. Logs retain benchmark lines only. [The v3 experiment patch](benchmarks/2026-09-08/container-experiment-v3.patch) reconstructs the tested source relative to the main source hashes in `source-base.json`. [The v4 patch](benchmarks/2026-09-08/container-experiment-v4.patch) includes the rejected jump suppression. [The current patch](benchmarks/2026-09-08/container-experiment-current.patch) restores the prior scheduling behavior, fixes scrub labels, adds the ordering assertion, and moves the prototype into its own file. Neither patch includes Xcode project settings or the user's staged cleanup.

To reproduce a signed v3 binary's scrubbing workload:

```sh
python3 clients/swift/benchmarks/2026-09-08/benchmark-containers.py /path/to/mai.app /tmp/new-results --container custom --prewarm --scrub-period 2 --runs 1
```

Omit `--scrub-period 2` for ordinary sweeps. The harness requires an empty output directory and an already-built app. It does not build or change signing settings.

The measured native path is promising for ordinary scrolling. Jump suppression did not improve the result enough to retain. The next substantial investigations are reducing native/SwiftUI view-realization work on disjoint jumps and replacing full-history measurement with bounded preparation. Both need measured gains and production behavior tests; neither is a proven solution here. Near-120 callbacks on a fully prepared static fixture do not justify installing this incomplete container in the shipping chat.


## September 9: incremental geometry and direct native rows

The isolated source remains in `/tmp/maid-perf-head`. The [current patch](benchmarks/2026-09-09/native-experiment.patch) is relative to the main checkout files recorded in [source-base.json](benchmarks/2026-09-09/source-base.json), excluding staged cleanup and Xcode project settings. Nothing here installs the experimental container in the shipping chat.

Completed rich rows can mount their existing AppKit text/code/table bodies directly. Other rows retain their SwiftUI presentation. Measurements now reuse stable row IDs, content keys and width; live row height reports update geometry without remeasuring completed history. The existing native scroll-position controller is shared, with stable row identities for prepending. Plan, history, working and end markers are included. Theme changes refresh retained rows while keeping height measurements.

| Workload | List | Native prototype | Qualification |
|---|---:|---:|---|
| 20,000-character synthetic production-event stream | 90.63 callbacks/s | 113.11 callbacks/s | Same signed app; one launch each |
| Streaming p99 callback interval | 29.15 ms | 20.86 ms | Same pair |
| Streaming maximum callback interval | 263.93 ms | 43.02 ms | Same pair |
| Prepared static 8,000 pt/s sweep | — | 119.37 callbacks/s | Earlier incremental build, before complete timeline markers |
| Full-history two-second scrub | — | 52.87–54.22 callbacks/s | Direct-native build before shared controller integration |

Streaming uses the actual ThreadStore reducer and ChatTimeline, injecting local synthetic events without sending a prompt. Both matched runs finished with exact source-text equality and a completed turn. Native measurement logs show an initial pass, three new rows at streaming start, and the newly settled rows at completion; no full-history measurement pass occurred per streamed chunk. These streaming binaries did not yet reject every occluded callback; the updated harness implementation now does. Interpret this first comparison as provisional until repeated with that stricter validation.

All rates remain display-link callbacks, not verified presented FPS. App-target optimized Debug compilation is used; dependencies are not a full Release build. Direct-native styles still duplicate some presentation details and need consolidation and interaction/appearance validation before shipping.

Opening 300 synthetic turns with the existing five-turn initial page prepared and aligned **109 rows in 788.77 ms**. Forcing all history loaded took **8,093.63 ms**, including **5,338.34 ms** measuring 5,851 rows. This is one launch per configuration, not a startup benchmark or first-presented-frame measurement. It demonstrates why full-history premeasurement cannot be the normal open path; pagination is existing application behavior, not a newly invented optimization. The attempted List opening comparison was occluded and excluded.

Six geometry/cache tests passed, including content-key invalidation, theme refresh without remeasurement, streaming-tail geometry, removed anchors, and native-controller preservation through height correction and prepend. The rejected NSTableView large-history geometry test remains unresolved. Full pagination, resize, folds, accessibility, selection and appearance still require end-to-end validation.

[Raw results and metadata](benchmarks/2026-09-09/summary.json), filtered benchmark logs and [the updated runner](benchmarks/2026-09-09/benchmark-containers.py) are retained. The measured gains justify continued validation; they do not establish 120 FPS during full-history scrubbing.


### Streaming while reading history, and real resize validation

A subsequent matched build, with full callback visibility checks, measured scrolling at 3,000 pt/s while the synthetic production reply streamed: **119.70 callbacks/s native versus 103.31 List**, p99 **8.33 versus 21.84 ms**, and maximum interval **22.18 versus 46.41 ms**. Both source-equality/completion checks passed. Each result is one launch; this is provisional until repeated. Raw runs are `complete-items-stream-scroll-a` and `complete-items-list-stream-scroll-a` in the September 9 artifacts.

The actual ChatView pagination probe loaded **109 → 301 rows** and preserved the same row and offset with **0 points error**. Initial resize attempts did not narrow either List or the custom window while external window management was active; those attempts are invalid as reflow validation. With unmanaged window control, narrowing the window from 1,280 to 700 points changed prepared row width **760 → 380** and transcript height **50,639 → 56,323**. This exposed **5.5 points of real anchor drift**. The shared controller now treats clip-view size changes as layout movement rather than reader scrolling, retaining the prior top origin before applying row reflow deltas. Repeating the same probe produced **0 points pagination error and 0 points resize error**. The exact anchor offset stayed **829.5 points** within the same prose row. Both failed and passing probe logs are retained.

The optional `--float-window` runner flag targets only the launched process's AeroSpace window, if that window manager is enabled. It does not enable AeroSpace or change configuration. The successful resize run did not use that flag. Earlier sweep window sizes were requested by the harness but could be overridden by external window management; prepared content width was 760 points. Exact displayed-window sizes should not be inferred from the requested 1,280×900 setting.

Eight targeted tests now pass, including bounded realization/order and the resize-origin regression. The test's floating-point tolerance is 0.000001 points after a synthetic bounds transformation; the previous exact comparison differed by less than 0.000000001 points, not a visible offset. The end-to-end lifecycle probe independently measured zero error.


### Strict streaming repeats after the resize fix

Two launches per container, using the same signed build and every-callback visibility rejection, confirmed the streaming benefit. Native: **114.80 and 115.36 callbacks/s**, p99 **18.50 and 17.55 ms**, maximum **40.86 and 45.81 ms**. List: **96.81 and 98.48 callbacks/s**, p99 **26.68 and 27.78 ms**, maximum **280.58 and 293.26 ms**. All four passed exact final-source and turn-completion checks. Native runs preceded List runs; these are sequential repetitions, not randomized or presentation-level measurements. See `strict-native-stream-a` and `strict-list-stream-a`.


### Native body reuse and simplification

Two valid 20-second full-history scrub launches per mode, with the same signed app, measured **50.68 / 49.41 callbacks/s** without native-body reuse and **56.07 / 55.12** with it. Each pass traverses the full ~967k-point transcript every two seconds. A subsequent pair using normal chat preparation measured **49.74 → 56.04**. Post-measurement resident memory was **290,480 → 279,488 KiB** in that pair; this single RSS sample is not peak memory or proof of a memory reduction. The modest 10–13% pacing gain, bounded reuse, and removal of repeated body construction justify retaining three lazily created body views per pooled host. A regression test confirms correct replacement text, cleared selection and reset code horizontal position when switching row kinds.

TextKit 2's native display path measured approximately 33–34 callbacks/s in its valid full-history run. Two immediate TextKit 1 comparisons were occluded and rejected. Later valid TextKit 1 runs above remain around 49–56; these are not an interleaved same-session TextKit-engine comparison. The TextKit 2 switch was removed because the experiment did not demonstrate a benefit. Its source patch and valid raw run are archived; no general claim about TextKit 2 performance is made.

The working container is now `ChatNativeTranscript.swift`. The failed NSTableView branch and its diagnostic test were removed from active code; their original failure remains archived. The native container now receives readiness from ChatView's normal preparation task instead of polling benchmark globals. Its DEBUG opt-in gate can therefore serve ordinary threads, and normal initial-bottom visibility/alignment is restored. The same real-window lifecycle probe still passes with zero pagination and resize-anchor error. Nine targeted native tests pass after simplification.

The archive runner supports historical experiment flags for reproducing signed snapshots. The latest source always reuses native bodies and no longer implements the table or TextKit 2 alternatives; use the appropriate archived source/binary when comparing historical modes. Full production readiness remains unproven, particularly shared presentation styling and end-to-end visual/accessibility behavior. No 120-presented-FPS claim is made.
