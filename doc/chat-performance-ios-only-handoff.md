# Chat performance: iOS/iPadOS-only handoff

Date: August 18, 2026

## Current decision

The native macOS chat path and the chat benchmark lab are parked. The active product path is iPhone and iPad only.

This supersedes any production-readiness conclusion for the AppKit implementation in `xcode-chat-scrolling-120fps-session-summary.md`. The native Mac benchmark work produced useful data, but the real app later regressed in two essential behaviors:

- A selected chat did not reliably open at its newest content.
- Text selection could not continue across prose as expected.

Those are product regressions, regardless of favorable frame-pacing numbers. The native Mac path must therefore be treated as experimental until it is restored on a separate branch, corrected, and reverified.

## Recoverable Git stashes

Use the commit hashes rather than `stash@{n}` because stash indices change whenever another stash is added or removed.

| Parked work | Commit hash | Scope |
|---|---|---|
| Native macOS chat/desktop worktree snapshot | `16eb0a259bc537b0f5028ba6fd5d6deedb5c84b2` | Full tracked dirty-worktree snapshot taken before rollback. It includes mixed shared/iOS files as well as the Mac port, so do not apply it directly over future work. |
| Mock-chat and frame-pacing lab | `605d6abb7288e5f973bb89f9b32ccdd9a83ed388` | The third parent (`^3`) contains only the three parked untracked lab files: frame-pacing monitor, mock chat, and deterministic Markdown fixtures. |
| Chat performance XCTest benchmarks | `a0d2b4fe8c15b3b9dfb89c970e7900a42dc0a7b2` | The third parent (`^3`) contains only the parked iOS XCTest performance benchmark file. |
| Real-thread benchmark runner | `f81c147a77af9897c21e71088c8b78bd98badc32` | The third parent (`^3`) contains only the production-thread selection/warm-up/sweep runner. It was reconstructed byte-for-byte from the retained pre-deletion tool output, including the final native-window activation change. |

Safe inspection and recovery:

```bash
git stash list
git stash show --stat 16eb0a259bc537b0f5028ba6fd5d6deedb5c84b2
git ls-tree -r --name-only 605d6abb7288e5f973bb89f9b32ccdd9a83ed388^3
git ls-tree -r --name-only a0d2b4fe8c15b3b9dfb89c970e7900a42dc0a7b2^3
git ls-tree -r --name-only f81c147a77af9897c21e71088c8b78bd98badc32^3
```

Restore the native Mac snapshot into an isolated branch rather than the current iOS worktree:

```bash
git stash branch aq/restore-macos-chat 16eb0a259bc537b0f5028ba6fd5d6deedb5c84b2
```

The macOS snapshot contains the whole tracked dirty state at capture time, not a clean Mac-only patch. Inspect it on its temporary branch and transplant only the desired commits or hunks.

The three benchmark stashes were created while unrelated changes were already staged, so a normal `git stash apply` or `git stash branch` would also try to replay that old index snapshot. Recover only their dedicated untracked-file parents instead:

```bash
git restore --source=605d6abb7288e5f973bb89f9b32ccdd9a83ed388^3 -- \
  clients/swift/mai/Features/Chat/ChatFramePacingBenchmark.swift \
  clients/swift/mai/Features/Chat/MockChatMarkdownFixtures.swift \
  clients/swift/mai/Features/Chat/MockChatView.swift

git restore --source=a0d2b4fe8c15b3b9dfb89c970e7900a42dc0a7b2^3 -- \
  clients/swift/maiTests/ChatMarkdownPerformanceTests.swift

git restore --source=f81c147a77af9897c21e71088c8b78bd98badc32^3 -- \
  clients/swift/mai/Features/Chat/ChatRealThreadBenchmarkRunner.swift
```

This restores only the parked benchmark sources and leaves the current iOS implementation untouched. Reconnecting the mock-chat route or launch arguments should be done only on a benchmark branch.

## What was removed from the active product

- The native desktop app container and desktop sidebar.
- The AppKit text-layout/selection host.
- The AppKit table-view scroll coordinator and list introspector.
- The AppKit horizontal scroll view used for code blocks and tables.
- macOS platform branches and AppKit imports added across chat, composer, registry, and shared view code.
- Native-Mac initial-bottom, bottom-follow, pagination-anchor, and semantic scroll-geometry paths.
- Mock Chat navigation and benchmark launch arguments.
- The mock transcript, real-thread benchmark runner, frame-pacing monitor, deterministic benchmark fixtures, and performance XCTest suite.
- Benchmark-only tracing and full-transcript mount/warm behavior from production `ChatView` and `ChatTextLayout`.

The active source tree contains no `os(macOS)`, AppKit, `ChatMac*`, `MockChat*`, or `ChatBenchmark*` references under `clients/swift/mai`.

## Mobile optimizations retained

The rollback intentionally keeps the mobile changes that address meaningful costs or correctness problems:

1. `ChatListBottomFollower` resolves the `UICollectionView` backing the SwiftUI `List` and performs constant-time, non-animated bottom pinning. Streaming content growth no longer has to resolve the bottom row through `ScrollViewProxy` on every update.
2. `ChatView` still uses `ScrollViewReader` for the cold initial jump to the bottom and as a fallback before the UIKit scroll view is resolved. This is the established iOS path; the failed AppKit initial-alignment coordinator is gone.
3. Upward content-offset movement disengages bottom following even when keyboard or accessibility scrolling does not produce a user-driven `ScrollPhase`. Content growth and viewport shrink are excluded so normal streaming or keyboard changes do not incorrectly cancel following.
4. Earlier-history pagination remains bounded by complete user turns. A prepend records the former first rendered row and restores it after content height grows, preventing the visible viewport from jumping.
5. The preparation task key includes the oldest loaded section. Loading another page therefore primes the widened history window instead of leaving newly inserted rows cold.
6. The settled-message continuity bridge keeps a just-finished message on its already-rendered streaming presentation until the settled Markdown and native text layouts have been prepared. The swap is immediate and non-animated.
7. Restored messages use their settled renderer unless the presentation is genuinely streaming, avoiding stale replayed streaming buffers.
8. `ChatTextLayoutStore` retains the UIKit/TextKit layout cache, waits for concurrent preparation claims to finish, uses keyed reuse instead of linear scans, and bounds content-bearing and blank reusable `UITextView` pools.
9. The Markdown render cache uses completion-safe preparation, and the streaming renderer retains recent immutable snapshots so view recreation does not temporarily collapse content.
10. Long settled prose remains one TextKit selection run when semantic boundaries allow it. Code and tables stay dedicated rich blocks, while user text remains literal and selectable.

## Behavior preserved on iPhone and iPad

- Initial chat opening at the newest content uses the original iOS proxy jump.
- Explicit jump-to-bottom restores follow intent; immediate jumps are accepted behavior.
- Scrolling away disables follow intent; returning to the end re-enables it.
- Streaming content and viewport changes follow only while the user remains at the end.
- Pagination loads complete earlier turns and preserves the visible anchor.
- Markdown parsing, sanitization, code blocks, tables, links, quotes, thematic breaks, and streaming repairs remain active.
- Settled assistant prose and literal user prose retain native range selection and link behavior.
- iPhone and iPad continue using the same UIKit/TextKit production path.

## Verification after parking Mac and benchmark code

Xcode 27.0 Beta 5, scheme `mai`:

| Verification | Result |
|---|---|
| iPhone 17 simulator build | Passed in 9.684 seconds |
| iPad Pro 13-inch (M5) simulator build | Passed in 3.563 seconds |
| Focused chat/Markdown/scroll-state suites | 86 passed, 0 failed |
| Complete iOS test plan | 238 passed, 3 failed, 0 skipped, 241 total |

The three full-plan failures are existing asynchronous `ThreadStoreTests` timeouts:

- `retryResubscribesSelectedThreadAfterSnapshotFailure()`
- `subscribeRecoveryAppliesBufferedDetailAndListUpdates()`
- `restoredThreadPreparationIsLimitedAndRetryable()`

All fail at the shared `Condition was not satisfied before timeout` helper. They are outside chat rendering, selection, scrolling, pagination, or bottom-follow code and match the previously observed unrelated failures.

The 86 focused passes include direct coverage for:

- Jump-to-bottom and bottom-follow state transitions.
- User scroll-away persistence and resuming follow at the end.
- Content-growth behavior while following or away from the end.
- Pagination by complete user turns.
- Long prose staying in one selectable segment.
- Selection across consecutive prose/thematic-break content.
- Native `UITextView` range selection, literal user text, link behavior, selection preservation, and view reuse.
- Markdown structure, sanitization, rich blocks, cache behavior, streaming repair, stable incremental blocks, and snapshot caching.

## Live iPhone simulator behavior pass

The production app was installed and exercised on an iPhone 17 simulator after the rollback. This was the normal Threads experience, not Mock Chat or a benchmark route.

| Interaction | Observed result |
|---|---|
| Open normal thread list | The normal Threads list appeared; no Mock Chat entry point was active. |
| Open `Make some random edits…` | The Markdown-heavy transcript opened at its newest content. Accessibility reported a 39-page outer vertical scroller at `100%`; `End of Extended Markdown Lab` and the composer were visible. |
| Scroll toward older content | The scroller moved to `97%` and the `Scroll to bottom` control appeared, confirming follow intent disengaged. |
| Reverse-scroll to the end | The scroller returned to `100%`, the bottom control disappeared, and the final content was visible again. |
| Use the bottom control | Independently verified from `97%`; tapping it immediately returned the transcript to `100%`. |
| Load earlier history | Repeated upward paging reached `0%`, exposed the original first prompt, and expanded the accessibility page count from 39 to 57. This confirms pagination inserted an earlier history window. |
| Inspect rich Markdown | Headings, tables, bullets, quotes, inline formatting, and prose rendered without visible clipping. |
| Select assistant prose | A long press produced native selection handles and the Copy/Look Up menu. |
| Stability | The app remained running with no crash or hang throughout the pass. |

The interaction artifacts are under:

```text
/var/folders/dh/6dql449d3dncd76y6yrp2f6w0000gn/T/ActionArtifacts/default/DeviceInteractionSynthesize/
```

The important artifact prefixes are `Verify iOS Chat Behavior-19_19_13_211` (thread list), `19_19_23_679` (initial bottom), `19_22_11_842` (pagination/top), `19_22_33_564` (prose selection), `19_23_28_813` (scrolled away), and `19_23_40_989` (returned to bottom).

Cross-block/cross-prose selection-handle dragging could not be safely automated because the handles did not expose usable hierarchy coordinates. It is covered directly by the passing selection and segmentation tests listed above. Live streaming follow was not exercised because that would require sending a real prompt; its state transitions and content-growth cases are also in the passing focused suite.

The simulator log contained repeated syntax-highlighter `MISSING STYLE` warnings and one reused text-layout attachment measured at 16.08 ms. Neither produced a visible failure. These are observations for future profiling, not functional regressions found by this pass.

## Remaining verification boundary

The build, focused automated behavior tests, and non-mutating simulator UI pass are green. A simulator cannot prove 120 Hz physical-device frame pacing, touch latency, thermal behavior, or live network-stream behavior. The benchmark instrumentation was deliberately parked at the user’s request, so the active production build makes no FPS measurement claim.

## Production status

For iPhone/iPad, the code compiles and the focused chat suite is green. The retained optimizations are localized to meaningful hot paths and correctness boundaries; the discarded prefetch experiment and the native Mac coordination layer are not active. The only known full-plan failures are the unrelated ThreadStore timeouts listed above.

Native macOS is not an active or supported product path in this worktree. Restore it only from an isolated stash branch and treat the earlier native performance claims as historical experiment results, not current production guarantees.
