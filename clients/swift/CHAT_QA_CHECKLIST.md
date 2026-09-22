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
- [ ] Inspect captured streaming frames for mixed old/new content, tile seams and single-frame displacement; callback pacing alone cannot pass this check.
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

## Performance and memory

- [ ] Repeat scroll and streaming plans at least three launches, with no profiler/other workload; compare average, p99 and worst stalls, not averages alone.
- [ ] Run extreme scrubbing separately; record remaining dropped pacing honestly rather than extrapolating ordinary sweep results.
- [ ] Compare normal paginated opening with forced full history; distinguish preparation from process startup/network/first presentation.
- [ ] Open five distinct normal chats, then five full rich chats; switch back and forth, resize and record retained/peak memory using appropriate tools.
- [ ] Evict/close sessions and verify presentation resources can be released; do not require RSS to immediately fall because allocators retain memory.
- [ ] Verify cancellation when changing chats during preparation; stale work must not repopulate the wrong transcript.

## iOS regression pass

- [ ] Confirm iOS still uses List. Repeat opening, pagination, scrolling, thought/tool expansion, streaming follow/scroll-away, keyboard and rotation checks.
- [ ] Exercise supported 60/120 Hz devices, text sizes and memory pressure. Mac callback measurements do not establish iOS performance.

## Provider/version compatibility — separate from renderer

- [ ] Record the actual adapter, backend executable and versions; test bundled runtime and explicit custom executable independently.
- [ ] Load/import/resume ordinary and paginated Codex threads on supported older/current combinations, including multi-page history and completed/live tool content.
- [ ] Unsupported history operations yield a narrow compatible fallback where available; auth/network/corruption errors are not hidden by retry loops.
- Excluded by the user: live Claude testing, because no Claude Pro account is available. Use Codex for this run; historical Claude authentication errors are not renderer failures.
- [ ] Adapter updates preserve active work, apply on safe restart and respect pinned/custom installations. Verify history compatibility before testing downgrade against valuable data.
