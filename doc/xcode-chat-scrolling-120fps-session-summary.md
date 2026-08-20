# Xcode Claude session report: “Optimize macOS and iOS chat scrolling for 120fps performance”

> **Status update — August 18, 2026:** This is now a historical experiment report. The native macOS path later regressed initial bottom positioning and cross-prose selection, so it and the benchmark lab were parked in recoverable Git stashes. The active worktree is iPhone/iPad-only. Current disposition, stash hashes, retained mobile optimizations, and post-rollback verification are documented in [chat-performance-ios-only-handoff.md](chat-performance-ios-only-handoff.md). Any statement below that describes the AppKit implementation as production-ready is superseded by this update.

## Executive summary

The session was found in Xcode’s local Coding Assistant store and matched the requested title exactly. It ran for about 2 hours and 10 minutes on August 18, 2026, using Xcode 27.0 Beta 5 and a Claude Code agent.

The work focused on the Swift client’s UIKit/iOS chat implementation. The original scrolling measurements were physically run on the user’s Apple-silicon Mac and its 120 Hz display, but they did **not** exercise the native AppKit/macOS implementation. For performance measurement, the agent built a Release iOS app, retagged and ad-hoc signed it as Catalyst so it could launch on the Mac, selected the requested real Codex ACP thread from the running daemon, and programmatically swept its UIKit scroll view while a `CADisplayLink` recorded frame timestamps. It did not benchmark a physical iPhone either.

The most important result was not a large change in average FPS; the real thread was already often near 120 FPS. The important change was the removal of rare, very visible 164–238 ms stalls. Those stalls were correlated with 61 synchronous text-layout misses after the transcript had supposedly been warmed. The final run recorded zero post-warm layout misses and reduced the worst frames to 22–25 ms.

The session identified and addressed four main problems:

1. Bottom-following repeatedly used `ScrollViewProxy.scrollTo`, an O(n) identity lookup over a long `ForEach`, and could remain engaged when the viewport moved toward older content.
2. Restored assistant messages with no turn ID were incorrectly treated like the active streaming message because several checks evaluated `nil != nil` as false.
3. Markdown/text preparation could report completion while another cancelled or concurrent task still held incomplete cache claims, and preparation did not rerun when pagination widened the loaded history window.
4. The UIKit text-view reuse pool used linear scans, was unbounded, and retained a 306 MB process footprint during a sampled sweep.

The session also built a UIKit prefetch/pre-attachment system, measured it, found that it made the important 3000 pt/s case worse, and removed it. The remaining limit is SwiftUI `List`/`UICollectionView` cell realization and self-sizing: the synthetic 10,000-row stress test still ran around 100 FPS during an 8000 pt/s fling.

## Follow-up: native macOS verification

After the original report was challenged, the current project was built and run again on August 18, 2026 using Xcode’s actual `My Mac` destination. This follow-up establishes a distinction the original report did not make clearly enough:

- The original session did run unit tests on a Mac destination.
- The original session’s **scrolling performance measurements were not native macOS measurements**. They came from a retagged `Release-iphoneos` executable that the process sampler identified as `Platform: Catalyst`.
- The current target genuinely supports native macOS: its evaluated `SUPPORTED_PLATFORMS` is `iphoneos iphonesimulator macosx`, and Xcode lists `My Mac` as an eligible `com.apple.platform.macosx` destination.
- The follow-up benchmark below is the first scrolling run verified here against the native AppKit path.

### Proof that the follow-up run was native

Xcode built against `MacOSX27.0.sdk` and launched:

```text
~/Library/Developer/Xcode/DerivedData/.../Build/Products/Debug/mai.app/Contents/MacOS/mai
```

`vmmap` reported `Platform: macOS`. The process loaded AppKit, and no `UIKitMacHelper` evidence appeared. The native source path also used `DesktopAppContainer`, `NSApplication`/`NSWindow`, the macOS chat-table introspector, and the macOS TextKit layout implementation behind `#if os(macOS)`.

### What was measured

An initial attempt mistakenly searched the mai sidebar for the Xcode/Claude session title, `Optimize macOS and iOS chat scrolling for 120fps performance`. That is not the title of the thread rendered by the app, so the runner correctly logged:

```text
real-thread benchmark: no thread matching "Optimize macOS and iOS chat scrolling for 120fps performance"
CHAT_BENCHMARK_COMPLETE
```

The fallback run used the built-in deterministic 10,000-row markdown stress transcript. The user then pointed out that the intended thread was visible in the native app’s sidebar. The query was corrected to `make some random edits`, which selected the same real thread used by the original session:

```text
8D821451-81BF-4BBC-A70E-9B5366B68E0B
Make some random edits, tool calls etc, I want you to display all the capabilities you’re capable of, use all of your tools. Do it to like a markdown demo file or something, don’t build this project
```

The successful native real-thread run used the production renderer, restored and warmed the whole 438-row rendered transcript, fixed the window at 1280×900 points, and swept upward and downward at 1,200, 3,000, and 8,000 points per second. The display link reported a 120 Hz Mac display.

The active shared scheme’s Run action was Debug; no separate Release-running scheme was available. These numbers prove and characterize the native path on the exact real transcript, but they should not be compared directly with the original session’s optimized Release/Catalyst numbers as a platform-only A/B test.

| Native macOS Debug, exact real thread | Average FPS | p50 | p95 | p99 | Worst frame | Hitches | Hitch time |
|---|---:|---:|---:|---:|---:|---:|---:|
| 1,200 pt/s | 107.45 | 8.33 ms | 17.72 ms | 23.40 ms | 84.13 ms | 180 | 102.95 ms/s |
| 3,000 pt/s | 110.04 | 8.33 ms | 17.12 ms | 22.64 ms | 36.97 ms | 106 | 81.91 ms/s |
| 8,000 pt/s | 104.29 | 8.33 ms | 18.71 ms | 21.35 ms | 31.54 ms | 100 | 132.35 ms/s |

For reference, the native 10,000-row synthetic fallback produced:

| Native macOS Debug pass | Average FPS | p50 | p95 | p99 | Worst frame | Hitches | Hitch time |
|---|---:|---:|---:|---:|---:|---:|---:|
| 10k rows, 1,200 pt/s | 115.83 | 8.33 ms | 8.33 ms | 19.86 ms | 45.96 ms | 58 | 33.91 ms/s |
| 10k rows, 3,000 pt/s | 103.43 | 8.33 ms | 18.54 ms | 23.51 ms | 112.21 ms | 294 | 131.27 ms/s |
| 10k rows, 8,000 pt/s | 94.22 | 8.33 ms | 21.66 ms | 30.41 ms | 230.90 ms | 266 | 209.82 ms/s |

The exact real-thread native path did not maintain 120 FPS in this Debug build. Its p95 intervals were approximately 17–19 ms, which means more than two 120 Hz frame budgets at the slowest 5% of sampled intervals. The 3,000 pt/s average being slightly higher than the 1,200 pt/s average should not be read as faster scrolling being cheaper: the sweep durations and realized row patterns differ, and this is one run without confidence intervals.

The real-thread launch also emitted a SwiftUI fault stating that the `OnScrollGeometryChange` modifier tried to update multiple times per frame. The synthetic launch separately emitted an AppKit warning about calling `layoutSubtreeIfNeeded` while a view was already being laid out. Neither aborted the benchmark, but both are plausible leads for native-path hitch investigation.

## Native macOS optimization pass after the baseline

The native baseline above was subsequently profiled and optimized in the production AppKit path. The final implementation was measured again on the exact same sidebar thread, native `My Mac` destination, 120 Hz display, 1280×900 window, and three fixed-velocity sweeps. The benchmark runner now also activates the app and makes its window key before measuring, so AppKit does not background- or occlusion-throttle the run.

This is still the shared scheme's Debug configuration. It is an honest native macOS result, not Catalyst, iOS-on-Mac, or a retagged iOS executable. It is also one before/after sample rather than a statistical study.

| Exact real thread, native macOS Debug | 1,200 pt/s | 3,000 pt/s | 8,000 pt/s |
|---|---:|---:|---:|
| Baseline average FPS | 107.45 | 110.04 | 104.29 |
| Optimized average FPS | **116.90** | **115.34** | **106.06** |
| Baseline p95 | 17.72 ms | 17.12 ms | 18.71 ms |
| Optimized p95 | **8.33 ms** | **8.33 ms** | **17.66 ms** |
| Baseline p99 | 23.40 ms | 22.64 ms | 21.35 ms |
| Optimized p99 | **17.85 ms** | **18.32 ms** | **20.54 ms** |
| Baseline worst frame | 84.13 ms | 36.97 ms | 31.54 ms |
| Optimized worst frame | **33.71 ms** | **31.35 ms** | 32.16 ms |
| Baseline hitch count | 180 | 106 | 100 |
| Optimized hitch count | **54** | **84** | **92** |
| Baseline hitch time | 102.95 ms/s | 81.91 ms/s | 132.35 ms/s |
| Optimized hitch time | **26.17 ms/s** | **40.78 ms/s** | **117.71 ms/s** |

The first optimized machine-readable results were:

| Sweep | Frames / duration | Average FPS | p50 | p95 | p99 | Worst frame | Hitches | Hitch time |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 1,200 pt/s | 2,339 / 20.00 s | **116.90** | 8.33 ms | **8.33 ms** | 17.85 ms | 33.71 ms | 54 | 26.17 ms/s |
| 3,000 pt/s | 2,177 / 18.87 s | **115.34** | 8.33 ms | **8.33 ms** | 18.32 ms | 31.35 ms | 84 | 40.78 ms/s |
| 8,000 pt/s | 754 / 7.10 s | **106.06** | 8.33 ms | 17.66 ms | 20.54 ms | 32.16 ms | 92 | 117.71 ms/s |

At 1,200 pt/s, average delivery improved by 9.45 FPS, p95 returned to a single 120 Hz frame, hitch count fell from 180 to 54, and late-frame time fell about 74.6%. At 3,000 pt/s, average improved by 5.29 FPS, p95 returned to a single frame, and hitch time roughly halved. The 8,000 pt/s fling improved only modestly: average rose 1.77 FPS and p95/p99 improved slightly, while the worst frame was effectively unchanged. The native Debug implementation is therefore much smoother during ordinary and brisk scrolling, but it is not locked to 120 FPS during an extreme fling.

### Native root causes found

The native `sample` call tree was dominated by repeated AppKit/SwiftUI layout and row self-sizing. The existing TextKit-backed `ChatSelectableText` path appeared in the sample but was not the leading cost. That changed the optimization strategy: the retained work reduces avoidable timeline invalidation and scroll coordination instead of replacing the text engine again.

The main native-specific issues were:

1. `onScrollGeometryChange` carried raw `contentOffset` through a SwiftUI geometry value and ran observable/state work at display cadence. SwiftUI logged that the modifier tried to update multiple times per frame.
2. Initial alignment, streaming/content-growth following, explicit jump-to-bottom, and prepend preservation were split across SwiftUI proxy calls and AppKit behavior. This caused redundant identity/layout work and made follow intent difficult to reason about.
3. A real animated jump-to-bottom could stop around 96% of the scroll range, leaving the button visible rather than actually reaching the newest item.
4. Scroll-away intent was inferred too late. Layout growth and user movement could be confused, allowing bottom-follow logic to fight a user moving toward older content.
5. The macOS `List` used a zero minimum row height. AppKit diagnosed attempts to set a negative-zero row height for the tiny pagination marker.
6. Pagination compensation performed more layout-sensitive work than necessary near `NSTableView` frame callbacks.
7. Horizontal tables/code blocks and the vertical timeline share the wheel-event path. The existing macOS forwarding view needed an explicit predominant-axis policy and behavioral verification.

### Retained native fixes

`ChatView.swift` now transforms macOS geometry into a small semantic value: top visibility, bottom visibility, and rounded container/inset/content heights. Raw offset is deliberately absent. SwiftUI actions now run for meaningful edge or size transitions instead of every display frame. The iOS geometry path remains separate because its existing UIKit follower still needs its original data. In the final native runs, the earlier “update multiple times per frame” fault did not reappear.

`ChatMacScrollPositionPreserver.swift` is now the single lightweight native scroll coordinator for:

- Constant-time initial bottom alignment through the enclosing `NSScrollView`.
- Constant-time explicit and animated bottom pinning, with SwiftUI proxy fallback only during the short attachment window.
- Immediate disengagement of follow intent when the clip view moves toward older content.
- Native `willStartLiveScroll`/`didEndLiveScroll` activity signals instead of SwiftUI scroll-phase handling in the nested scroll hierarchy.
- Preserving a concrete visible `NSTableView` row across history prepends, then compensating only for measured layout-induced anchor movement.

The bounds observer does only a cheap `minY` comparison during ordinary scrolling; it does not create a task or force layout for every frame. Prepend correction is coalesced onto a later main-actor turn, and the explicit `layoutSubtreeIfNeeded` calls were removed from capture/restoration. Content growth pins to the end only while follow intent remains active; a user moving upward cancels that intent at the source.

The macOS jump-to-bottom path now writes the native clip position directly and records end visibility after a successful pin. This fixed the observed 96% stop. The mock performance lab uses the same coordinator so its Mac results exercise the production policy rather than an unrelated proxy-only implementation.

The macOS list minimum row height is now one point rather than zero, while iOS retains zero. This removed the negative-zero AppKit row-height diagnostic without materially changing transcript layout.

`ChatMacHorizontalScrollView` keeps its custom responder behavior scoped to macOS: vertical wheel motion over a code block or table is forwarded to the outer timeline, while deliberate horizontal motion stays inside the rich block. iOS keeps its native nested-scroll behavior and does not receive this patch. An explicit `usesPredominantAxisScrolling = true` assignment was tested and then removed because AppKit already defaults it to true; retaining it would document no project-specific policy and produce no behavioral or performance change.

The existing iOS constant-time `UICollectionView` bottom follower from the original session remains in place. Nonanimated iOS pins use it directly; animated iOS requests continue through SwiftUI. No speculative cross-platform rewrite was added because profiling showed the new bottleneck was the native AppKit/SwiftUI layout path.

### Apple API research applied to the native pass

The current pass reviewed the Xcode 27 Apple documentation rather than assuming a newer rendering API would automatically solve the problem:

- Apple's SwiftUI performance guidance recommends reducing update frequency and transforming geometry into only the values that actually affect view state. That directly motivated removing raw content offset from the macOS geometry payload.
- SwiftUI documents that only the first `onScrollPhaseChange` in a nested scroll hierarchy is invoked and reports a runtime issue for later ones. Native `NSScrollView` live-scroll notifications are therefore the more reliable source for the outer Mac timeline with nested tables and code scrollers.
- `NSScrollView.usesPredominantAxisScrolling` defaults to true. The audit removed a redundant explicit assignment and left the meaningful direction routing in the responder override.
- `NSResponder.scrollWheel(with:)` forwards unhandled wheel events to the next responder by default. The existing Mac rich-block host follows that responder-chain model for vertical motion rather than installing a global event monitor.
- TextKit's `NSTextLayoutManager.ensureLayout(for:)` and display-link APIs were reviewed. Profiling did not justify another text-layout rewrite or a custom display loop: repeated SwiftUI/AppKit row layout and state invalidation were the larger native costs.

This kept the changes narrow: use AppKit where it provides direct, constant-time scroll coordination, preserve SwiftUI's virtualization and the existing TextKit renderer, and measure any broader caching idea before retaining it.

### Manual native-app verification

The final Debug `.app` was launched normally, with the real sidebar rather than `MockChatView`, and the exact `Make some random edits, tool calls etc...` row was selected. Accessibility inspection showed the newest items at the bottom (items 420–425 of 425 in that presentation).

The following behaviors were then exercised in the actual Mac UI:

- Scrolling upward made the jump-to-bottom button appear.
- A single jump moved from approximately items 380–384 back to items 420–425, and the button disappeared immediately.
- Scrolling far into older history and returning to the end preserved the newest transcript; accessibility row totals changed transiently because SwiftUI `List` virtualizes its accessibility children, not because messages were lost.
- A vertical scroll gesture targeted over a table's horizontal scroller moved the outer timeline.
- The table's explicit horizontal “Scroll Right” action moved the inner horizontal scrollbar from 0 to 1 while the outer timeline position stayed effectively unchanged.

This verifies direction routing, bottom-follow disengagement, explicit bottom recovery, and pagination anchoring in the native app. Frame pacing itself remained programmatically driven for repeatability, so it measures rendering throughput rather than trackpad input latency.

### Native experiments attempted and reverted

- **Caching `NSHostingView.fittingSize` and rich-block content identities:** this looked attractive in local call trees, but repeat runs drove the 8,000 pt/s result down to roughly 83–85 FPS. The cache and extra `Hashable` plumbing were fully removed.
- **More aggressive dispatch/run-loop coalescing:** replacing the small yielded main-actor correction with a broader queue coalescer regressed the fling. The final coordinator schedules work only when an actual prepend anchor or initial alignment exists.
- **Prewarming every syntax highlighter:** this increased startup/measurement work and made the benchmark worse. It was removed. HighlighterSwift's many “MISSING STYLE” lines are Debug-only dependency logging, not evidence that eager warming helps.
- **Disabling the new coordinator to isolate AppKit's reentrancy warning:** the one startup warning still appeared even with initial pinning and then the entire introspection bridge disabled. It is therefore not caused by the new coordinator.
- **Explicit predominant-axis assignment:** removed during the production audit because it restated AppKit's default and did not contribute to the verified nested-scroll behavior.
- **Native AppKit animation for jump-to-bottom:** Xcode 27's `NSAnimationContext.animate(.smooth)` path was compiled successfully, but the user explicitly approved an immediate jump. The animation code was removed before the final build, leaving the simpler constant-time pin with no animation state or completion race.

### Final build and test status

- Xcode `buildForTesting` succeeded for both `My Mac` and the iPhone 17 simulator after the final shared-code edit.
- Four scroll-state regression tests were added for leaving the bottom during a user gesture, resuming follow intent at the bottom, suppressing a jump-button flash during transient content growth, and stopping follow during in-place content expansion.
- The final macOS focused set passed: 50 passed, 0 failed, 0 skipped, 0 not run across `ChatTimelineLayoutTests`, `ChatMarkdownRichBlockTests`, and `ChatStreamingMarkdownRendererTests`.
- The iOS chat matrix passed: 110 passed, 0 failed, 0 skipped, 0 not run. This includes markdown correctness, streaming, selectable TextKit views, reuse, pagination/follow state, and 25 markdown performance tests.
- The complete Mac plan reported 270 tests: 256 passed, the same three `ThreadStoreTests` timed out, and 11 iOS-only terminal-controller tests had no Mac result. This is substantially broader than the earlier run in this report; none of the chat tests failed.
- Manual native verification covered the interaction cases described above.
- The three reproducible `ThreadStoreTests` timeouts are unrelated to the files in this pass and also time out when run alone. They are not being represented as fixed or as evidence of a chat regression.

One startup-only `NSTableView` reentrant-operation warning remains. Isolation showed it occurs without the new bridge and appears to come from the existing SwiftUI `List`/rich-row mount. The coordinator no longer forces layout from table notifications, the warning did not abort measurement, and no per-frame geometry fault or negative-zero row warning appeared in the final run. It remains a separate cleanup target rather than a claimed fix.

The current native pass directly changed:

- `clients/swift/mai/Features/Chat/ChatView.swift`
- `clients/swift/mai/Features/Chat/ChatMacScrollPositionPreserver.swift`
- `clients/swift/mai/Features/Chat/ChatMacHorizontalScrollView.swift`
- `clients/swift/mai/Features/Chat/MockChatView.swift`
- `clients/swift/mai/Features/Chat/ChatRealThreadBenchmarkRunner.swift`
- `clients/swift/maiTests/ChatTimelineLayoutTests.swift`
- `clients/swift/maiTests/ChatMarkdownTests.swift`

The repository already contained extensive staged and unstaged work from the Claude session and other work. These files identify the current pass's scope; they are not a claim that every existing change in those files originated here.

## Final production-readiness audit

The implementation received a final audit after the first optimized result. The audit had three goals: preserve behavior, remove benchmark-only duplication, and reject any optimization whose measured value did not justify its maintenance cost.

### Final-code repeat measurements

Two more native Debug runs were recorded after the final simplification, using the same exact daemon thread, 1280×900 key window, 120 Hz display, and production renderer. The first ran immediately after the complete test plan; the second ran after a short settling interval. Both are included to show machine variance instead of selecting only the best sample.

| Final code | Average FPS | p95 | Worst frame | Hitch time |
|---|---:|---:|---:|---:|
| 1,200 pt/s, run A | 114.70 | 8.33 ms | 39.98 ms | 42.92 ms/s |
| 1,200 pt/s, settled run B | **116.30** | **8.33 ms** | **33.50 ms** | **30.28 ms/s** |
| 3,000 pt/s, run A | 114.17 | 8.33 ms | 33.15 ms | 48.73 ms/s |
| 3,000 pt/s, settled run B | **115.65** | **8.33 ms** | **33.02 ms** | **36.71 ms/s** |
| 8,000 pt/s, run A | 107.61 | 16.67 ms | **28.78 ms** | 104.68 ms/s |
| 8,000 pt/s, settled run B | **108.03** | **16.67 ms** | 29.07 ms | **100.63 ms/s** |

The simplified code remains clearly above the native baseline of 107.45/110.04/104.29 FPS. The settled run improved average delivery by 8.85, 5.61, and 3.74 FPS respectively. More importantly, p95 remained one 120 Hz frame at ordinary and brisk speeds and two frames during the artificial 8,000 pt/s fling. The earlier 116.90/115.34/106.06 optimized sample and these two final-code samples form a consistent range; small differences are machine/run variance rather than evidence that the removed redundant code was useful.

### Behavioral contract and evidence

| Required behavior | Final behavior | Evidence |
|---|---|---|
| Open a chat at the newest message | Native initial alignment pins directly to the actual AppKit bottom after attachment/layout. | Exact real thread opened at its newest rows in the normal Mac sidebar UI. |
| Follow streaming at the bottom | Content growth performs a constant-time native pin only while `shouldFollowBottom` remains true. | Existing streaming tests plus final state-machine regression tests passed. |
| Let the user read older content | Live-scroll start or observed upward clip movement disables follow intent at the source. Layout growth no longer pulls the user back down. | Manual upward scroll showed the jump button; dedicated scroll-away test passed. |
| Resume following at the end | Ending a gesture with the end zone visible restores follow intent. | New `endingAUserScrollAtTheBottomResumesFollowing` test passed. |
| Explicit jump-to-bottom | One direct native bounds write reaches the true bottom and marks it visible. The jump is intentionally immediate, as approved by the user. | Manual click returned to the newest rows and removed the button immediately; the earlier 96% stop no longer occurred. |
| Avoid jump-button flicker during streaming/layout | A transient end-zone loss while already following does not mark the timeline as away from the bottom. | New transient-content-growth test passed. |
| Expand/fold content without being yanked | Expansion explicitly disables follow intent until the end is genuinely visible again. | New expansion state test and existing folding tests passed. |
| Load older history without a viewport jump | The coordinator captures a concrete visible table row, inserts a prepared page without animation/automatic offset repair, and compensates only for measured anchor-height changes. | Manual deep-history traversal returned to the exact newest content; pagination and preparation tests passed. |
| Preserve markdown and selection | Rendering, cache, TextKit selection, rich blocks, links, and sanitizer behavior are unchanged by the scroll coordinator. | 110/110 iOS chat tests and the final 50/50 Mac focused tests passed. |
| Preserve streaming markdown correctness | Incremental repair/planning and settled-transition cache preparation are unchanged. | All `ChatStreamingMarkdownRendererTests` passed on both tested destinations. |
| Route nested table/code scrolling correctly | Mac vertical-dominant wheel input is forwarded to the outer timeline; horizontal input remains in the rich block. iOS keeps its platform-native path. | Manual outer-vertical and inner-horizontal accessibility interactions succeeded. |
| Keep pagination and normal operation production-like | Normal UI stays paginated; only explicit benchmark mode mounts the full transcript for deterministic measurement. | Normal sidebar launch and explicit benchmark launch were both exercised. |
| Use the actual Mac implementation | The optimized process is native macOS/AppKit and built against the macOS SDK. | Xcode `My Mac`, `vmmap Platform: macOS`, AppKit loaded, no UIKitMacHelper. |
| Share worthwhile behavior with iOS | Production `ChatScrollState` and the request modifier are shared; iOS retains its constant-time `UICollectionView` nonanimated pin and SwiftUI animated fallback. | iPhone 17 simulator build-for-testing and 110 chat tests passed. |

### Maintainability changes made during the audit

The mock performance lab previously carried its own copied scroll-state machine and copied bottom-request modifier. That duplication was removed. `MockChatView` now uses the production `ChatScrollState` and `ChatBottomScrollRequestModifier`, so its benchmark cannot silently diverge in follow intent, jump requests, or end visibility. This removed roughly 100 lines of duplicated behavior and required no new abstraction layer.

The bottom-request modifier was simplified to one closure, `pinToBottom(animated) -> Bool`. On macOS the approved immediate native pin handles both request kinds. On iOS, an animated request returns `false` and follows the existing SwiftUI animation path, while a nonanimated request uses the direct collection-view offset. This is simpler than maintaining a separate “pins animated requests directly” flag.

Stale anchor-rebase state is now cleared whenever the coordinator attaches to a new table or begins a new prepend capture. This is a small correctness guard for navigation/reuse, not a frame-rate micro-optimization.

Four focused state tests were added rather than building a large AppKit test harness. Pure follow-intent rules are deterministic unit-test material; row realization and nested wheel delivery remain better covered by the real native UI and benchmark. This keeps the test design proportional to the risk.

### Value-versus-complexity ledger

| Retained work | Complexity | Why it earns its place |
|---|---|---|
| Semantic macOS scroll geometry without raw offsets | Low | Removes display-cadence SwiftUI state invalidation; p95 and hitch improvements are large. |
| Direct native bottom pin | Low | Replaces an O(n) SwiftUI identity lookup, fixes the incomplete jump, and centralizes bottom semantics. |
| Native live-scroll/upward-movement follow cancellation | Low–moderate | Prevents streaming/layout from fighting the user, including keyboard/accessibility/programmatic movement. |
| Native prepend anchor preservation | Moderate | Solves a visible correctness problem caused by estimated variable row heights; avoids forced/reentrant layout. |
| Rounded size/edge transition filtering | Low | Preserves every decision-relevant transition while removing subpixel noise. |
| One-point macOS minimum list row | Trivial | Removes an AppKit-invalid zero/negative-zero row-height path. |
| Restored-message nil-turn classification fix | Low | Eliminates incorrect streaming treatment and the 164–238 ms cold-layout stalls. |
| Completion-safe markdown/text cache preparation | Moderate | Makes “warm” mean complete despite cancellation/concurrent claims; directly protects scrolling and pagination. |
| Bounded indexed native text-view reuse | Moderate | Removes linear lookup and unbounded retained views; structurally bounds cost without changing rendered output. |
| Production state reused by the mock lab | Negative net complexity | Deletes duplicate behavior and makes performance tests more trustworthy. |
| Foreground/key-window benchmark setup | Low, benchmark-only | Prevents background throttling from contaminating measurements; no production UI effect. |

Every retained optimization either fixes a demonstrated behavioral bug, removes measured main-thread work, or reduces code. None exists solely to save an unmeasured microsecond.

The following were deliberately removed because they failed that standard:

- UIKit prefetch/pre-attachment: high complexity and a measured 3,000 pt/s regression.
- `NSHostingView.fittingSize`/content-identity cache: moderate complexity and an 8,000 pt/s regression to roughly 83–85 FPS.
- Whole-transcript syntax-highlighter prewarming: extra work and worse results.
- Broader dispatch/run-loop coalescing: more machinery and worse fling performance.
- Explicit predominant-axis assignment: AppKit already supplies the same default.
- Native jump animation: unnecessary after the user approved an immediate jump; removing it avoids animation lifecycle and interruption edge cases.

### Production-readiness verdict

For the chat-scrolling changes themselves, the final code is a strong production candidate: both platform branches build, all 160 targeted chat test executions passed (50 final Mac focused plus 110 iOS), the exact native Mac thread was manually exercised, and repeat frame-pacing runs remained materially above baseline. The retained implementation is smaller after the audit and keeps platform-specific code behind narrow boundaries.

It would be inaccurate to claim that no regression is mathematically possible or that the entire application has a completely green release gate. Three unrelated `ThreadStoreTests` still time out, 11 iOS-only terminal tests do not run on the Mac destination, and one startup-only `NSTableView` reentrant-operation warning remains outside the new coordinator. The warning was reproduced with the coordinator disabled, but Apple says this class of warning may become an assertion in a future AppKit release. Those are existing project-level follow-ups, not hidden chat-pass successes.

### Is this the fastest possible implementation?

It is the best measured implementation found within the current SwiftUI `List`/TextKit architecture and the requested maintainability constraint. It is not the theoretical maximum. The remaining 8,000 pt/s ceiling is dominated by SwiftUI/AppKit row realization, hosting, and variable-height self-sizing. Raising that ceiling substantially would most likely require a custom native `NSTableView`/`NSCollectionView` timeline with explicit row-height caching and a much larger rewrite of selection, accessibility, folding, streaming, pagination, and anchoring.

That rewrite is not currently justified: normal and brisk scrolling already deliver one-frame p95 at 120 Hz, while multiple smaller caching/prefetch experiments measured worse. The next responsible performance step is not more speculative production code. It is a native Release configuration and repeated controlled profiling runs; the shared scheme currently runs native Mac benchmarks in Debug. A custom virtualizer should be considered only if Release measurements and real user traces show the extreme-fling ceiling is a product problem worth the added architecture and regression surface.

## Session identity and source records

| Field | Value |
|---|---|
| Xcode conversation title | `Optimize macOS and iOS chat scrolling for 120fps performance` |
| Xcode conversation ID | `6269639C-BF11-4048-AD79-CF7CDCD13FFC` |
| Claude session ID | `de188cde-162a-400a-950d-c2656f456130` |
| Assistant provider/model identifier | `claude-code` |
| Start | 2026-08-18 17:58:22 UTC / 13:58:22 Toronto time |
| End | 2026-08-18 20:08:46 UTC / 16:08:46 Toronto time |
| Xcode/toolchain observed by `sample` | Xcode 27.0 Beta 5, build `27A5237l` |
| Host OS observed by `sample` | macOS 26.5.2 (`25F84`) |
| Reported host | M2 Pro MacBook Pro, 120 Hz display |
| Project working directory used by Claude | `/Users/aqothy/Code/Personal/maiD/clients/swift` |

Primary local records:

- Xcode conversation: `~/Library/Developer/Xcode/UserData/CodingAssistant/mai-ajvexhhktjwtgvgbkhqoplogzozb/6269639C-BF11-4048-AD79-CF7CDCD13FFC/conversation.plist`
- Xcode metadata: the adjacent `metadata.plist`
- Raw Claude transcript: `~/Library/Developer/Xcode/CodingAssistant/ClaudeAgentConfig/projects/-Users-aqothy-Code-Personal-maiD-clients-swift/de188cde-162a-400a-950d-c2656f456130.jsonl`
- Claude subagent and persisted profiling outputs: the adjacent `de188cde-162a-400a-950d-c2656f456130/` directory
- Final benchmark log retained at the time of this report: `/tmp/mai-chat-benchmark.log`
- Visual verification screenshot retained at the time of this report: `/tmp/mai-real-chat.png` (1972×1386 pixels)

The `/tmp` files are temporary and may disappear after a reboot or cleanup. The Xcode and Claude records are the durable source of truth.

## Original request and success criteria

The user asked for the chat to be as smooth as the display supports—120 FPS on the current Mac—through markdown-heavy chats, with real verification rather than an assumed improvement. They explicitly allowed SwiftUI, AppKit, UIKit, or a custom virtualizer, but asked the agent to prioritize large, maintainable wins and avoid overengineering. Markdown rendering, streaming, bottom-following, and pagination had to keep working. The user also asked for iOS improvements where the same changes had a significant effect.

The requested real-world test target was the Codex ACP thread titled approximately:

> Make some random edits, tool calls etc, I want you to display all the capabilities you’re capable of, use all of your tools. Do it to like a markdown demo file or something, don’t build this project

The user sent a follow-up while the agent was working to emphasize that it must test on macOS and must use that exact markdown-heavy Codex ACP thread.

The selected real thread had ID `8D821451-81BF-4BBC-A70E-9B5366B68E0B`. Its rendered content included a large “Extended Markdown Lab” with tables, code/tool-oriented content, headings, quotes, and many markdown formats. The retained screenshot shows the exact thread title and the transcript at its bottom anchor.

## Important inherited work

The session did not start from an unoptimized chat. The working tree was already heavily modified, and the latest relevant commit shown at session start was:

```text
3600d56 Fix thread replay and chat rendering stalls
```

The existing implementation already included substantial performance work:

- Settled prose used native selectable TextKit-backed views.
- Markdown segmentation separated prose from rich code/table blocks.
- Markdown plans and text layouts were cached.
- Expensive layout preparation was intended to run off the main actor.
- A mock performance lab and frame-pacing benchmark already existed.
- Long transcripts were represented with a SwiftUI `List`, whose UIKit backing collection view virtualized rows.
- Streaming used a stable streaming presentation rather than constantly replacing the settled renderer.

This session’s changes were an incremental optimization and correctness pass over that architecture. Because the repository was already dirty and contained other agents’ work, the list of all dirty files at the end of the session is not a clean diff of this one session. The files explicitly edited or created by this session are listed later.

## How scrolling was actually tested

### Platform and launch method

The performance run was on Mac hardware, but it exercised the iOS/UIKit implementation rather than the native AppKit implementation or a physical iOS device. This distinction is independent of whether Xcode also offered a native Mac destination: the measured executable itself was Catalyst.

The session:

1. Built the app in Release configuration for `generic/platform=iOS` with signing disabled.
2. Used `vtool` to replace the executable’s build-version platform with `maccatalyst 18.6 27.0`.
3. Ad-hoc signed the app with `codesign -f -s -`.
4. Launched the app using `open -n ... --args ...`.

The `sample` report identified the running process as ARM64 and `Platform: Catalyst`, from the `Release-iphoneos/mai.app` product. In Swift conditional compilation, Catalyst follows the `os(iOS)` branch, so this did exercise the UIKit chat path and the new `UICollectionView`/`UITextView` logic. It was nevertheless a Mac-hosted workaround, not a frame-pacing run on a physical iPhone or iPad.

The app connected to the daemon at the build-configured URL `ws://10.0.0.211:8765/rpc`. The session verified that `10.0.0.211` was the Mac’s current LAN address and that port 8765 was reachable.

### Deterministic window and transcript setup

The benchmark pinned the app window to 1280×900 points for repeatable layout widths. The real-thread runner then:

1. Waited up to 60 seconds for the thread list.
2. Selected the first title containing `make some random edits`, case-insensitively.
3. Waited up to 120 seconds for the selected thread, restored history, and markdown segment cache to become available.
4. Mounted the whole transcript instead of the normal initial pagination window, so pagination and scroll anchoring would not mutate the list during measurement.
5. Waited three seconds for the initial bottom anchor to settle.
6. Waited up to 180 seconds for the timeline preparation task to report `transcript warm`.
7. Ran the three fixed-velocity sweeps.

Before the full-mount logic, the real timeline initially prepared only 30 rendered rows. After preparation invalidation and restored-message fixes, the real thread expanded to 438 rendered rows before measurement. The final log recorded `prepare rows=438 requests=18` and zero synchronous layout misses after warm-up.

### Scroll driver

The scroll driver was programmatic, not a physical trackpad, mouse wheel, finger, or synthesized touch sequence.

`ChatBenchmarkModel.runScrollBenchmark` located the largest vertical `UIScrollView` in the app window, excluding `UITextView` instances and smaller horizontal code scrollers. A `CADisplayLink` callback then updated the scroll offset every frame using:

```text
new offset = old offset ± pointsPerSecond × elapsed display-link time
```

Each pass swept upward toward older history and then back downward. A phase ended when it reached the scroll range boundary or its configured maximum duration. The three velocities and maximum duration per direction were:

| Label | Velocity | Maximum per direction |
|---|---:|---:|
| Cruise | 1,200 pt/s | 10 s |
| Scroll | 3,000 pt/s | 12 s |
| Fling | 8,000 pt/s | 8 s |

This method is useful because it is deterministic and repeatedly realizes the same production rows at controlled velocities. It does not measure input latency, gesture recognizer behavior, trackpad momentum, or the full human interaction pipeline. The session’s statement that it was smooth at every speed a trackpad could produce was an inference from the 8,000 pt/s sweep, not a separate trackpad recording.

### Frame measurement

`ChatFramePacingMonitor` requested a fixed frame-rate range equal to the display’s reported maximum, which was 120 Hz. It recorded each display-link timestamp on the main run loop and calculated:

- Total frame count and duration.
- Average delivered callbacks per second.
- p50, p95, p99, and maximum frame intervals.
- Hitch count, where an interval exceeded 1.5 times the expected frame duration.
- Hitch time in milliseconds per second, computed from the time over the expected 8.33 ms frame budget.

At 120 Hz, one frame is approximately 8.33 ms, two frames are 16.67 ms, and three frames are 25 ms.

### Mock stress data

The synthetic lab loaded 10,000 deterministic variable-height markdown rows. The fixture varied paragraph counts, added lists every 11th row, added fenced Swift blocks every 29th row, and used a user role every seventh row so narrower bubble widths were exercised. The streaming benchmark used a roughly 4,000-word essay plus a markdown component catalog in a rapid-burst stream.

The mock is substantially harsher than the requested real chat and is useful for exposing the remaining virtualization ceiling. It is not a literal reproduction of the real thread.

## Real-thread benchmark results

### Initial real-thread run

This run happened after the first structural optimization pass, but before the restored-message/preparation bugs were corrected. It is the “before” result used in the session’s final comparison.

| Sweep | Frames / duration | Avg FPS | p50 | p95 | p99 | Worst frame | Hitches | Hitch time |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 1,200 pt/s | 1,255 / 10.85 s | 115.62 | 8.33 ms | 8.33 ms | 8.33 ms | 237.88 ms | 7 | 36.53 ms/s |
| 3,000 pt/s | 1,869 / 15.82 s | 118.04 | 8.33 ms | 8.33 ms | 8.33 ms | 171.85 ms | 7 | 16.23 ms/s |
| 8,000 pt/s | 1,008 / 8.81 s | 114.32 | 8.33 ms | 8.33 ms | 12.37 ms | 164.45 ms | 11 | 46.69 ms/s |

The unusual combination of excellent p95 values and terrible maximum frames is the key diagnostic clue: this was not sustained low FPS. Most frames were on time, but a small number of newly realized large markdown rows synchronously typeset on the main thread and froze the scroll for 0.16–0.24 seconds.

The log contained 74 layout-miss lines in total and 61 after the transcript claimed to be warm. The large misses were concentrated in restored assistant items such as `item-43` and `item-46`.

### Final real-thread run

| Sweep | Frames / duration | Avg FPS | p50 | p95 | p99 | Worst frame | Hitches | Hitch time |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 1,200 pt/s | 2,382 / 20.00 s | **119.05** | 8.33 ms | 8.33 ms | 8.33 ms | **25.00 ms** | 17 | 8.01 ms/s |
| 3,000 pt/s | 1,974 / 16.65 s | **118.50** | 8.33 ms | 8.33 ms | 16.67 ms | **21.55 ms** | 24 | 12.31 ms/s |
| 8,000 pt/s | 972 / 8.23 s | **117.93** | 8.33 ms | 8.33 ms | 16.67 ms | **22.19 ms** | 16 | 16.87 ms/s |

Final post-warm synchronous layout misses: **0**.

### Practical interpretation

- The average improved by 3.43 FPS at cruise, 0.46 FPS at 3,000 pt/s, and 3.61 FPS at 8,000 pt/s.
- The meaningful improvement was worst-frame latency: approximately 238→25 ms, 172→22 ms, and 164→22 ms.
- p50 and p95 stayed at one 120 Hz frame for all three speeds.
- Hitch count is not directly comparable because run durations and content traversal timing differed; hitch severity is the more important signal here.
- The result is near the display maximum, but “locked at 120 FPS” is too strong. The final average was 117.93–119.05 FPS, p99 sometimes reached two frames, and the harness’s own comments describe under 5 ms/s hitch time as the smooth target. The final passes were 8.01–16.87 ms/s. The long freezes were removed, but the run was not literally hitch-free.

## Mock benchmark progression

The table below preserves the important experimental steps. Values are average FPS; the 3,000 pt/s hitch-time column shows how much late-frame time accumulated per second.

| Stage | Cruise 1,200 | Scroll 3,000 | Fling 8,000 | Streaming | 3,000 hitch time | Notes |
|---|---:|---:|---:|---:|---:|---|
| Baseline | 117.7 | 94.6 | 87.0 | 116.8 | 211.74 ms/s | 144 layout-miss log lines; 173 ms worst 3,000 frame |
| Phase A | 116.9 | **110.7** | 98.8 | 117.3 | **76.85 ms/s** | Direct bottom pin, follow disengagement, bounded indexed pool, width fix |
| Prefetch/pre-attach | 118.3 | 103.9 | 98.7 | 116.9 | 133.93 ms/s | Regression; 8,000 worst frame also rose to 68 ms |
| Budgeted prefetch | 118.1 | 103.3 | 99.7 | 117.4 | 138.81 ms/s | 2 ms drain budget did not recover 3,000 performance |
| Final recorded run, prefetch removed | 118.8 | 104.2 | 99.8 | 117.4 | 131.93 ms/s | 19/25/33 ms worst scroll frames; zero real-thread misses |

There was run-to-run variation, and the agent noted that other work was occurring on the same machine. A separate post-removal run measured 106.6 FPS at 3,000 pt/s. This explains why the closing answer summarized the mock result as approximately 108 FPS rather than using only the final 104.2 FPS sample.

The final streaming pass measured 117.4 FPS, p95 8.33 ms, p99 16.67 ms, an 87.78 ms worst frame, 53 hitches, and 21.62 ms/s hitch time.

## Profiling process and findings

### Failed Instruments attempt

The first profiling attempt used `xctrace` with the Time Profiler template during the 3,000 pt/s pass. The trace ran for 45.93 seconds, but it was unusable:

- The aggregated `time-profile` table contained zero rows.
- The raw `time-sample` table contained only six rows from an initial stackshot.
- Lifecycle/tick data proved that the recording itself stayed active.
- Most of the apparent 15 MB trace size was the Instruments template; the actual recorded corespace was about 1 MB.

The subagent suggested a kperf/ktrace ownership conflict, missing Developer Tools profiling permission, or an Instruments 27 Beta deferred-mode issue. It also found evidence that an ambiguous process selection could attach to an Xcode Preview/Debug process instead of the intended Release app. No conclusions were drawn from that trace.

### Successful `sample` profiling

The session switched to the macOS `sample` tool and triggered capture from benchmark log markers. One attempt selected a stale process and showed a 99% idle main thread. The agent then killed old benchmark instances, selected the newest exact `Release-iphoneos/mai.app` PID, and obtained real scrolling samples.

The sampled Release process had a 306.1 MB physical footprint and 308.4 MB peak footprint. That value motivated bounding the reuse pool, but the session did not publish a final post-fix memory measurement, so a specific memory reduction should not be claimed.

The sampled call tree attributed a large portion of work to SwiftUI’s UIKit-backed list and native text attachment. One post-change breakdown reported these overlapping call-tree buckets:

| Sampled bucket | Approx. share of main-thread samples |
|---|---:|
| `UICollectionView.layoutSubviews` family | 30.4% |
| Cell creation/dequeue | 22.9% |
| `ChatSelectableTextHostView.layoutSubviews` | 13.2% |
| `_UIHostingView.layoutSubviews` / render actions | 9.0% |
| SwiftUI host self-sizing | 8.7% |
| Drawing/backing-store work | 7.7% |
| `UITextView.setAttributedText` / typesetting | 7.4% |

These buckets came from parent/child call-tree markers and should not be added as if they were disjoint CPU categories.

The session’s closing analysis also attributed roughly 23% of the earlier main-thread work to the repeated bottom-follow/identity-resolution path. After the direct-offset change, the profile was dominated by cell realization, self-sizing, hosting, and remaining display-side TextKit work.

## Issues and fixes

### 1. Bottom-following did O(n) work and fought scrolling away from the end

#### Symptom

During streaming and content-height corrections, the timeline repeatedly called `ScrollViewProxy.scrollTo(bottomID, anchor: .bottom)`. Resolving that row identifier walked the long SwiftUI `ForEach` identity list. On a large transcript this was O(n) work on the main thread.

The UIKit path also did not reliably disengage bottom-following when the viewport moved upward through keyboard, accessibility, benchmark-driven, or other non-gesture scrolling. It could keep snapping toward the end while the user intended to inspect older content.

#### Fix

`ChatListBottomFollower.swift` was added with two UIKit components:

- `ChatListCollectionViewIntrospector` finds the `UICollectionView` backing the enclosing SwiftUI `List`. It verifies that the marker’s center lies inside the collection view so it does not accidentally select the sidebar or a nested code scroller.
- `ChatListBottomFollower` retains a weak scroll-view reference and computes the bottom offset directly from content size, adjusted insets, and bounds. It calls `setContentOffset(..., animated: false)` only when the difference exceeds 0.5 points.

`ChatView.swift` now detects offset movement toward older content and calls `noteScrollAwayFromEnd()`, excluding same-frame changes caused by content growth or viewport shrink. When following is appropriate, it uses the direct offset write and falls back to `ScrollViewProxy` only before the collection view is resolved.

Equivalent behavior was added to `MockChatView.swift` so the stress harness measured the same path as production.

#### Effect

This removed repeated identity-walk work, made streaming bottom-follow constant-time, and stopped content growth from yanking the viewport back down after an upward move.

### 2. Restored messages with nil turn IDs were misclassified as streaming

#### Symptom

Several code paths used a condition equivalent to:

```swift
message.turnID != streamingTurnID
```

For restored messages and an idle thread, both values could be `nil`. The expression was false, so settled assistant messages were excluded from the settled rendering/preparation path as if they were still streaming. The largest messages in the target chat were therefore not represented and warmed correctly before scrolling.

The real-thread diagnostics showed 61 post-warm layout misses concentrated in the large restored items, producing 164–238 ms synchronous main-thread stalls.

A related issue allowed a replayed/stale streaming buffer retained by `ThreadStore` to override the settled message even when the message presentation had already become settled.

#### Fix

Four guards in `ChatView.swift` were changed to make a nil streaming turn explicitly mean “nothing is streaming”:

```swift
streamingTurnID == nil || message.turnID != streamingTurnID
```

The corrected checks cover:

- Expansion of settled whole-document markdown into render rows.
- Whole-document markdown render-cache requests.
- Markdown render requests for standard message rows.
- Native text-layout request generation.

`ChatMessageRow` now uses a `ThreadStreamingText` buffer only when `presentation.isStreaming` is true. Otherwise the settled timeline text and settled renderer win.

#### Effect

The target transcript mounted 438 rendered rows rather than remaining on a small standard-row representation, its intended settled render plans were ready before the sweep, and post-warm synchronous layout misses fell from 61 to zero. The worst real-thread frame dropped from 238 ms to 25 ms.

### 3. Cache-preparation races could signal warm with holes

#### Symptom

Both `ChatMarkdownRenderCache.prime` and `ChatTextLayoutStore.prepare` used in-flight claim sets to prevent duplicate work. A new preparation call could find all of its missing requests already claimed by another task and return immediately, even if that other task had been cancelled and had not finished every request. The benchmark then received `transcript warm` while cache entries were missing.

The timeline preparation task’s identity also omitted the oldest loaded section. When pagination widened the mounted history without changing the total timeline count, width, streaming turn, or fold set, preparation did not necessarily rerun over the newly loaded window.

#### Fix

- Both preparation methods now loop until every requested value is cached or their own task is cancelled.
- If another task owns the remaining claims, the loop waits 25 ms and checks again.
- Cancelled workers release claims for requests they did not build.
- Successfully completed partial work remains cached.
- `ChatTimelinePreparationKey` now includes `oldestLoadedSectionID`, so widening history invalidates and reruns preparation.

The real-thread benchmark also mounts all sections before warming, avoiding pagination and re-anchoring during the measured sweep.

#### Effect

The warm signal became a meaningful guarantee for the requested window. Fixing the race alone did not remove the target stalls—the restored-message classification bug still produced 61 misses—but it eliminated a genuine readiness race and made later results reproducible.

### 4. Text-view reuse was unbounded and used linear scans

#### Symptom

`ChatTextLayoutStore` kept idle `UITextView` instances in an array and searched it linearly for an exact `(layout ID, width, layout identity)` match. Fast traversal could grow the array without a cap, retain attributed text for many rows, and increase both search cost and memory. The sampled process footprint after a sweep was 306.1 MB.

#### Fix

The pool was restructured into:

- A dictionary keyed by layout ID and width for O(1) exact lookup.
- An ordered key list for deterministic oldest-entry eviction.
- A cap of 160 content-bearing idle text views.
- A separate cap of 8 blank spare text views.
- Evicted/replaced views have `attributedText` cleared before entering the spare pool.
- Deactivation clears dictionaries, order state, and spares so UIKit views do not outlive the navigation destination.

When a row is realized, it first takes the exact view already containing the correct layout, then a blank spare, then the oldest content-bearing view for recycling.

#### Effect

Exact reuse no longer scans the whole pool, and retained views are bounded. The transcript did not record a final memory measurement, so the structural bound is verified in code but its final MB impact was not quantified.

### 5. Mock warm-up used the wrong width for user bubbles

#### Symptom

The mock benchmark warmed every message at the full row width. User bubbles add horizontal padding and therefore render prose at a narrower width. The prepared key did not match the eventual display width, causing avoidable synchronous layouts in the benchmark.

#### Fix

`MockChatView.swift` now uses `ChatTimelineMetrics.proseTextWidth(role:in:)`, matching production and accounting for user-bubble width.

#### Effect

The mock became a more faithful measurement of the production cache path and stopped counting a benchmark-only width mismatch as a product regression.

### 6. There was no harness for the requested real thread

#### Symptom

The pre-existing auto-run path opened only `MockChatView`. It could not prove performance on the user’s exact daemon-backed transcript, and normal pagination could change the list during a sweep.

#### Fix

The session added `ChatRealThreadBenchmarkRunner.swift`, `-ChatBenchmarkThread`, warm signals in the real timeline, full-transcript mounting for benchmark mode, and routing changes in the iOS and desktop containers.

The new invocation is:

```text
-ChatAutoBenchmark scroll -ChatBenchmarkThread "make some random edits" -ChatPerformanceLab
```

`-ChatPerformanceLab` must come last because it is a value-less flag and `UserDefaults` argument parsing can otherwise consume the next argument.

The runner logs the exact selected thread ID/title, waits for history and caches, performs the same three sweeps as the mock, and emits machine-readable `CHAT_BENCHMARK_RESULT` JSON lines.

#### Effect

The final result is based on the requested real Codex ACP chat rather than only on a generated fixture.

## Attempted and rejected approaches

### UIKit collection-view prefetch and text-view pre-attachment

The agent implemented a complete experiment rather than merely discussing it:

- A `ChatListRowPrefetcher` replaced/interposed the collection view’s `UICollectionViewDataSourcePrefetching` target while forwarding callbacks to the existing target.
- Production and mock timelines registered collection-item-to-layout-request mappings on each body evaluation.
- `ChatTextLayoutStore.preattachTextView` took an already prepared layout, filled a spare/new `UITextView` with the attributed text, and returned it to the exact-content pool so row realization would only need a frame assignment.
- A second version queued prefetch bursts and drained them with a 2 ms per-run-loop budget, while supporting cancellation.

The experiment was removed because it regressed the important 3,000 pt/s case from about 110.7 FPS to 103–106 FPS and increased hitch time from roughly 77 to 116–139 ms/s. The session concluded that a continuous 120 Hz sweep left no true idle main-thread window: pre-attachment merely moved or duplicated display-side TextKit typesetting and sometimes did work for cells never realized.

This was a useful negative result. The final code retains only the collection-view introspection needed for constant-time bottom pinning.

### `UIUpdateLink`

The agent searched Xcode 27 documentation for `UIUpdateLink` and its low-latency/immediate-presentation preferences. It did not adopt it. The documentation indicated that low-latency event dispatch primarily benefits Pencil events and warns that extra work in the low-latency phase can itself cause dropped frames. The actual bottleneck was cell realization and synchronous text work, not the lack of a newer display callback API. `CADisplayLink` remained the measurement driver.

### Full custom `UICollectionView` rewrite

The session considered a full UIKit collection-view rewrite as the way to remove the remaining SwiftUI `List` realization/self-sizing overhead. It did not implement one because the requested real chat already reached near-maximum refresh after the correctness fixes, while the rewrite would be a large, high-risk architecture change affecting selection, streaming, pagination, folding, bottom anchoring, and accessibility.

### Diagnostic instrumentation of the two worst messages

After the preparation-race fix failed to remove the stalls, the agent stopped theorizing and instrumented `item-43` and `item-46`. It logged whether the rows entered preparation and how many requests were generated. This exposed the nil-turn-ID classification path. The item-specific instrumentation was removed after the fix; only the general `prepare rows=... requests=...` trace remains in benchmark mode.

### Screenshot capture fallback

The first screenshot script attempted Python `Quartz` and failed because that module was unavailable. A Swift/CoreGraphics script then found the visible `mai` window, invoked `/usr/sbin/screencapture`, and successfully wrote `/tmp/mai-real-chat.png`. The image verifies correct thread selection, bottom anchoring, and rendered markdown appearance, but it is a still image and does not prove scroll fluidity.

## Build, test, and behavior verification

### Builds

The agent repeatedly rebuilt the Release generic-iOS product after major edits and relaunched the ad-hoc Mac-hosted app. The final build completed successfully. Xcode code-issue refreshes on the edited files were also reported clean.

### macOS-destination test run

The Xcode test run reported:

- 192 passed tests.
- Three failed `ThreadStoreTests`:
  - `retryResubscribesSelectedThreadAfterSnapshotFailure`
  - `subscribeRecoveryAppliesBufferedDetailAndListUpdates`
  - `restoredThreadPreparationIsLimitedAndRetryable`
- All three failures were timeout failures documented as pre-existing and likely related to concurrent RPC/daemon work.
- 72 tests showed `No result` on the default Mac destination:
  - 36 `ChatMarkdownTests`
  - 25 `ChatMarkdownPerformanceTests`
  - 11 `TerminalSessionControllerTests`

The agent investigated instead of counting `No result` as success and found that those files were wrapped in `#if os(iOS)`.

This was functional/unit-test coverage on the Mac destination. It was not a native-macOS scrolling frame-pacing run and does not make the Catalyst benchmark numbers representative of the AppKit renderer.

### iOS simulator tests

The run destination was switched to an iPhone 17 simulator. The 36 markdown tests and 25 markdown performance tests—61 chat tests total—succeeded. These covered the reuse pool, selection, markdown behavior, and related chat paths. The destination was then switched back to My Mac.

The simulator run was functional test verification only. No simulator frame-pacing benchmark was recorded, and a simulator would not substitute for a physical 120 Hz iPhone performance result anyway.

### Streaming, bottom-follow, pagination, and folding

- Final mock streaming benchmark: 117.4 average FPS and 8.33 ms p95.
- `ChatTimelineLayoutTests` passed, including bottom-follow intent, pagination-by-complete-turn, and activity grouping/folding behavior.
- The real chat was visually inspected at the bottom anchor and captured in a still screenshot.
- The real-thread benchmark deliberately disabled incremental pagination by mounting the full transcript; pagination correctness was therefore covered by tests and the normal implementation, not exercised during the measured real-thread sweep.

### Test-host pollution discovered during verification

The benchmark launch argument `ChatAutoBenchmark=scroll` became persisted in `com.anthonyqiu.mai` defaults. Test hosts then launched the auto-benchmark plan and reported zero selected tests, initially making the markdown suite look broken. The agent identified the persisted preference, deleted it, and documented the cleanup:

```sh
defaults delete com.anthonyqiu.mai ChatAutoBenchmark
defaults delete com.anthonyqiu.mai ChatBenchmarkThread
```

Old benchmark processes also remained alive after `CHAT_BENCHMARK_COMPLETE`, so the notes recommend killing old `Release-iphoneos/mai.app` processes before choosing the newest PID for profiling.

## Files changed by this session

The transcript shows this session creating or directly editing the following product files:

- `clients/swift/mai/Features/Chat/ChatListBottomFollower.swift` — new UIKit list introspector and constant-time bottom follower.
- `clients/swift/mai/Features/Chat/ChatRealThreadBenchmarkRunner.swift` — new real-daemon-thread benchmark runner.
- `clients/swift/mai/Features/Chat/ChatFramePacingBenchmark.swift` — real-thread argument and benchmark coordination/logging support.
- `clients/swift/mai/Features/Chat/ChatView.swift` — follow disengagement, direct pin wiring, full benchmark mount/warm signal, preparation key, restored-message guards, stale streaming-buffer fix.
- `clients/swift/mai/Features/Chat/ChatTextLayout.swift` — indexed/bounded text-view reuse and completion-safe layout preparation.
- `clients/swift/mai/Features/Chat/ChatMarkdownRenderCache.swift` — completion-safe prime/claim loop.
- `clients/swift/mai/Features/Chat/MockChatView.swift` — matching bottom-follow behavior, correct user-bubble warm widths, and temporary prefetch experiment later removed.
- `clients/swift/mai/Platform/iOS/IOSAppContainer.swift` — route real-thread benchmark mode through the production container/thread selection.
- `clients/swift/mai/Platform/Desktop/DesktopAppContainer.swift` — corresponding desktop route.

It also updated Claude project-memory notes outside the repository with the benchmark recipe, platform workaround, known test failures, simulator requirement, and defaults cleanup.

The session did not commit the changes. The repository was dirty before it began, so source control history alone does not isolate this work.

## Reproduction recipe preserved by the session

### Mock lab

```text
-ChatAutoBenchmark all -ChatPerformanceLab
```

Plans are `scroll`, `stream`, and `all`.

### Exact real thread

```text
-ChatAutoBenchmark scroll -ChatBenchmarkThread "make some random edits" -ChatPerformanceLab
```

Requirements and caveats:

- The daemon must be reachable at the `MAI_RPC_URL` baked into the build.
- Put the value-less `-ChatPerformanceLab` argument last.
- Benchmark output is printed as `CHAT_BENCHMARK_RESULT {json}` and attempts to append to `/tmp/mai-chat-benchmark.log`. The final sandboxed native launch did not update that file, so the reliable native recipe is to launch the executable directly from a captured terminal session and retain stdout.
- `layout miss` lines after `transcript warm` indicate synchronous main-thread text layouts and should be zero.
- Kill old benchmark instances before profiling so the PID is unambiguous.
- Delete persisted benchmark defaults afterward.
- For CPU profiling on this setup, the session recommends `sample <pid> 20 1 -file /tmp/sample.txt` triggered by `benchmark start:` log lines. The Xcode 27 Beta 5 deferred Time Profiler trace was empty.

## Known limitations and open risks

1. **The original session had neither a native-AppKit nor physical-device frame-pacing run.** Its performance result was a Mac-hosted UIKit/Catalyst workaround. This report now includes both a native macOS Debug baseline and a native optimized rerun of the exact same real thread, but not a native Release run. Actual iPhone/iPad ProMotion performance remains unmeasured.
2. **No real gesture/input-latency measurement.** Scrolling was driven by direct offset writes. This isolates rendering/realization throughput but does not cover trackpad or touch event latency and momentum behavior.
3. **Near-120 is not literal 120 with zero hitches.** The original Catalyst pass averaged 117.93–119.05 FPS, but the final native Debug repeats were 114.17–116.30 FPS at the two ordinary/brisk speeds and 107.61–108.03 FPS during the extreme fling.
4. **Extreme flings remain below 120.** The final exact-thread native macOS Debug repeat reached 108.03 FPS at 8,000 pt/s, while the native 10,000-row Debug baseline reached 94.2 FPS at that nominal speed. The remaining cost appears dominated by list cell realization, self-sizing, hosting, and display-side text attachment.
5. **Final memory was not remeasured.** The pool is now bounded, but the report cannot state how many MB were recovered from the 306 MB sampled baseline.
6. **Interaction verification is not an input-latency study.** The native UI was actively scrolled and its jump/nested-scroll behavior inspected, but no scrolling video, Core Animation instrument capture, or user-perceived smoothness study was recorded.
7. **Benchmark mode changes pagination behavior.** It mounts the full transcript to keep measurement stable. That is appropriate for a scrolling benchmark but is not exactly the normal incremental-history operating mode.
8. **Shared-machine variance.** Several iterations differed by a few FPS while other processes were active. Two final-code repeats are recorded, but a larger controlled sample with confidence intervals was not performed.
9. **The real-thread baseline was already after some Phase A changes.** Its before/after comparison isolates the restored-message/preparation fixes well, but it is not a pristine pre-session product baseline.
10. **Images in the selected thread remained unsupported.** The original request explicitly accepted that limitation, and the session did not add image rendering.
11. **One startup AppKit reentrancy warning remains.** It reproduces without the new coordinator and appears outside this scroll fix, but Apple warns that this category may assert in a future release.
12. **The whole application test plan is not entirely green.** Three unrelated `ThreadStoreTests` still time out, although all targeted chat tests pass on both tested destinations.

## Condensed chronology

1. Located prior benchmark/platform notes and inspected the existing TextKit/SwiftUI chat stack.
2. Established a Release mock baseline on the Mac using the ad-hoc launch workaround.
3. Attempted Xcode Time Profiler; trace contained no usable periodic samples.
4. Switched to `sample`, corrected stale/wrong PID selection, and obtained main-thread call trees.
5. Implemented Phase A: direct bottom pinning, upward-movement follow disengagement, indexed/bounded text-view reuse, and role-aware mock warm widths.
6. Rebuilt and measured a large mock improvement at 3,000 and 8,000 pt/s.
7. Built UIKit prefetch/pre-attachment, then added a 2 ms budget after the first version caused bursts.
8. Measured that both prefetch versions regressed 3,000 pt/s and removed the entire experiment.
9. Added a production real-thread benchmark path and selected the exact Codex ACP markdown thread from the daemon.
10. Found 164–238 ms stalls and 61 post-warm layout misses in restored messages.
11. Fixed preparation claim races and made preparation rerun when the loaded history window changed; stalls persisted.
12. Instrumented the two worst messages, found nil-turn-ID streaming misclassification and stale buffer use, then corrected four guards and the display-side streaming decision.
13. Rebuilt and obtained the final 119.0/118.5/117.9 FPS real-thread results with zero post-warm misses.
14. Captured the rendered real chat at its bottom anchor.
15. Ran Mac tests, investigated 72 `No result` cases, discovered persisted benchmark defaults, and cleaned them.
16. Switched to an iPhone 17 simulator and passed all 61 iOS chat tests.
17. Restored the Mac destination, killed the benchmark app, cleaned defaults, and wrote project-memory notes.
18. Ran a true native macOS baseline on the exact sidebar thread and profiled the AppKit/SwiftUI path.
19. Replaced per-frame geometry state work with semantic transitions, added the native scroll coordinator, fixed direct bottom pinning and prepend anchoring, and removed forced layout calls.
20. Manually verified the real Mac UI: scroll-away, immediate jump-to-bottom, deep-history return, vertical wheel routing over tables, and inner horizontal scrolling.
21. Audited maintainability, removed the mock scroll-state/modifier copies and redundant predominant-axis assignment, and added four follow-intent regression tests.
22. Built both platform branches, passed 110 iOS chat tests and 50 final Mac focused tests, ran the complete 270-test Mac plan, and recorded two final-code native benchmark repeats.

## Bottom line

The session made a credible, evidence-driven improvement to the requested real chat. The real win was eliminating rare synchronous typesetting freezes, not merely raising a headline average-FPS number. It also left behind a reusable real-thread benchmark and correctly removed an optimization experiment that measured worse.

The strongest verified claim from the **original session’s Release/Catalyst run** is:

> On the M2 Pro Mac’s 120 Hz display, the exact Codex ACP markdown-heavy thread delivered 117.9–119.0 average display-link FPS with 8.33 ms p95 frame intervals, 21.6–25.0 ms worst frames, and zero synchronous post-warm native text-layout misses after the fixes.

That claim describes the UIKit/Catalyst path, not the native AppKit renderer.

The strongest verified claim from the **final optimized native AppKit code** is:

> Across two final-code repeats on the same 120 Hz Mac, the actual macOS app scrolling the exact sidebar thread delivered 114.70–116.30, 114.17–115.65, and 107.61–108.03 FPS at 1,200/3,000/8,000 pt/s. The native baseline was 107.45/110.04/104.29 FPS, and final p95 improved from roughly 17–19 ms to 8.33/8.33/16.67 ms.

The result is materially smoother and fixes real bottom-follow, jump-to-bottom, pagination-anchor, per-frame geometry, and nested-scroll-routing issues at their coordination points. It should still not be generalized into “the native Mac app is locked at 120 FPS,” “physical iOS devices are proven at 120 FPS,” or “the UI is completely hitch-free.” The extreme 8,000 pt/s native Debug fling remains around 108 FPS. A native Release configuration, more controlled trials, and a physical 120 Hz iPhone/iPad run with real touch/trackpad latency instrumentation would be needed for stronger claims.
