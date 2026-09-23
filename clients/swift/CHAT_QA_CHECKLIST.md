# Chat QA checklist

The integrated release also requires [RELEASE_QA.md](RELEASE_QA.md), which covers beta providers, attachments, annotations, completions, terminals and distribution.

Unmarked items are QA to perform, not already-verified claims. See CHAT_PERFORMANCE_BALANCE.md for completed automated evidence and CHAT_BENCHMARK_GUIDE.md for launches. Record app binary/commit, renderer, OS, window size, refresh rate, content fixture and adapter/runtime versions with failures. Use the same content/window for List/native comparisons. Keep visual inspection separate from timed benchmarks.

## Essential macOS behavior

- [ ] Open empty, short and long chats; content is centered in the detail pane, never behind the sidebar, with no prolonged blank viewport.
- [ ] Toggle sidebar, resize split divider/window, enter/exit fullscreen; content reflows without clipping, horizontal drift or losing the reading anchor.
- [ ] Scroll slowly, fling rapidly, drag the scrollbar far away and reverse direction; no missing/duplicated rows, overlapping blocks or stale reused content.
- [ ] Reach older-history boundaries repeatedly; newly inserted turns preserve the visible row and offset, with no stuck loading state or duplicate turns.
- [ ] Open at the bottom; short content and composer spacing are correct. Jump-to-bottom works after scrolling away.
- [ ] Expand/collapse thoughts, grouped activity and nested tools at top/middle/bottom; all content is reachable and following rows move correctly.
- [ ] Expand offscreen content and resize; no stale height or clipped scroll extent. Compare disclosure persistence with List before treating differences as regressions.

## Streaming and scroll intent

- [ ] Stream prose with wrapping, partial Markdown delimiters, code fences, tables and long lines; no temporary overlap or upward recentering.
- [ ] Working timer/whimsical text stays below content throughout growth and transitions between block types.
- [x] Verify assistant and reasoning deltas update only the live text observation, and thought completion publishes authoritative text and clears the buffer. Two regressions pass on macOS 27 and iOS 18.6; the full two-thought/tool/reply state scenario also preserves exact source and earlier history. This does not pass visual frame coherence. See `qa/2026-09-beta-integration/activity-20260923/REPORT.md`.
- [ ] Inspect captured streaming frames for mixed old/new content, tile seams and single-frame displacement; callback pacing alone cannot pass this check.
- [x] Reproduce and fix the captured List completion displacement. The September 22 image regression fails on the old recording (35-point movement over 19 frames) and passes on fixed List/native captures. Exact source/completion pass; missed display frames and thought/tool-specific transitions remain outside this regression's scope. See `qa/2026-09-beta-integration/rendering-20260922/REPORT.md`.
- [x] Remove streamed-text fades and working-indicator pulse/phrase transitions as requested on September 19. Plain text is the current baseline; there is no reveal timeline or custom text renderer.
- [ ] While following the bottom, new text remains visible without repeated jumping or jump-button flicker.
- [ ] Scroll away during streaming; incoming text does not pull the reader back. Return to bottom and verify following resumes.
- [ ] Expand thoughts/tools while streaming; preserve the reader's position and intentional follow state.
- [ ] Resize or switch chats during streaming; return to complete, correct content with no updates leaking into another chat.
- [ ] Complete, stop, fail and retry a turn; final rendering matches exact source and the working indicator clears correctly.
- [x] Exercise real daemon reconnect/replay; no duplicate chunks, stale indicator or silently missing history. The September 21 actual Release/Codex run verifies exact messages, cleared working state and preserved native session identity after provider and daemon restart. See `qa/2026-09-beta-integration/live-release-20260921/REPORT.md`.

## Rich content and accessibility

- [ ] Check headings, nested lists, quotes, rules, Unicode/emoji, links, inline formatting, narrow/wide tables and labelled/unlabelled code against List.
- [ ] Select/copy prose and code, copy tables, scroll code/tables horizontally; verify actual clipboard text and no unexpected chat scrolling.
- [ ] Scroll reused views into unrelated rows; selection, copied feedback, syntax colors and horizontal offset do not leak.
- [ ] Check light/dark appearance, increased text size, keyboard scrolling/focus, VoiceOver labels and copy-button accessibility.
- [ ] Check attachments, approvals, error rows and fetched remote tool details with real threads; offline fixtures cannot validate these integrations.
- [x] Verify real Codex image-only and text+image user messages in actual native/List windows. September 23: exact payloads survive; Codex identifies the blue fixture; both renderers show images and replies correctly in settled window captures. Same-view replacement and invalid-image fallback also pass. Assistant/tool rows, URL actions, remote details and streaming image-height transitions remain open; see `qa/2026-09-beta-integration/attachments-20260922/REPORT.md`.

## Performance and memory

- [x] Repeat scroll and streaming plans at least three launches, with no profiler/other workload; compare average, p99 and worst stalls, not averages alone. The `217e488-plain-streaming` report records both renderers and remaining stalls; this is completed measurement, not a claim of hitch-free rendering.
- [x] Run extreme scrubbing separately; record remaining dropped pacing honestly rather than extrapolating ordinary sweep results. September 22 full-history stress: native 39.88 callback Hz over three valid runs; List 17.80 over two. Worst intervals 79.04/947.03 ms. Neither is a 120 fps stress pass; rejected launches are preserved in `benchmarks/20260922-final/REPORT.md`.
- [x] Compare normal paginated opening with forced full history; distinguish preparation from process startup/network/first presentation. September 22: three fresh native launches each, 109 versus 5,851 rows, 0.732–0.745 versus 7.714–7.980 seconds to the prepared/aligned checkpoint; no network or first-presentation claim.
- [x] Open five distinct normal chats, then five full rich chats; switch back and forth, resize and record retained/peak memory using appropriate tools. September 22: each scenario passed 11 visits and 44 resizes. Physical footprint final/peak: 123.9M/169.2M normal, 486.8M/494.5M full rich. This does not cover continuous resizing across arbitrarily many distinct widths or OS memory pressure.
- [x] Evict/close sessions and verify presentation resources can be released; do not require RSS to immediately fall because allocators retain memory. The September 20 resource tests verify eviction releases the original cache/layout objects while preserving thread data and reopening uses fresh caches; whole-app memory-pressure behavior remains a separate device check.
- [x] Verify cancellation when changing chats during preparation; stale work must not repopulate the wrong transcript. The September 20 native preparation regression replaces the active preparation and verifies cancelled work cannot install stale rows.

## iOS regression pass

- [ ] Confirm iOS still uses List. Repeat opening, pagination, scrolling, thought/tool expansion, streaming follow/scroll-away, keyboard and rotation checks.
- [ ] Exercise supported 60/120 Hz devices, text sizes and memory pressure. Mac callback measurements do not establish iOS performance.

## Provider/version compatibility — separate from renderer

- [x] Record the actual adapter, backend executable and versions; test bundled runtime and explicit custom executable independently. Live workflow reports identify the daemon; September 23 history checks exercise Codex 0.155.0-alpha.9.2 and 0.147.0 independently and retain versions/native executable hashes. The older runtime emits cache/plugin compatibility warnings despite passing listing/replay; see `qa/2026-09-beta-integration/history-20260923/REPORT.md`.
- [ ] Load/import/resume ordinary and paginated Codex threads on supported older/current combinations, including multi-page history and completed/live tool content.
- [ ] Unsupported history operations yield a narrow compatible fallback where available; auth/network/corruption errors are not hidden by retry loops.
- Excluded by the user: live Claude testing, because no Claude Pro account is available. Use Codex for this run; historical Claude authentication errors are not renderer failures.
- [ ] Adapter updates preserve active work, apply on safe restart and respect pinned/custom installations. Verify history compatibility before testing downgrade against valuable data.
