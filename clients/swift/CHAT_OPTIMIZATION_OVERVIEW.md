# Chat optimization work: overview and report index

Updated September 12, 2026. This is the entry point for this investigation, not a claim that every performance target or QA scenario is complete.

## Current implementation

macOS uses a custom AppKit NSScrollView and virtualized document. Completed rich content uses existing native text/code/table bodies; live, interactive and unsupported rows retain SwiftUI. iOS remains SwiftUI List. A Debug launch argument selects the original macOS List for comparison.

The work is in the main working tree as unstaged/new files. The user's staged cleanup and main Xcode project settings were preserved. Optimized compilation was applied only to the isolated performance build. No adapter/backend compatibility fix has been implemented in this chat.

## How the retained optimizations work

1. **Remove unnecessary native text tracking work.** Earlier profiling identified cursor/selection tracking overhead. Native text configuration avoids repeated unnecessary tracking setup while preserving selection. The follow-up report contains comparisons and configuration tests.
2. **Keep streaming updates local.** The active streaming text leaf and existing reducer/render pipeline update incoming content without remeasuring unchanged completed history. This investigation reused that separation rather than adding broad equality checks or another state mirror.
3. **Realize a bounded viewport.** Stable row IDs and measured geometry locate the visible range by binary search. AppKit hosts only the viewport, nearby prepared rows and a reuse pool, rather than retaining a view for every row.
4. **Prepare nearby rows outside the immediate scroll step.** Visible rows mount first; a yielding, cancellable task prepares one viewport of neighbors on either side. AppKit work stays on the main actor. This improves ordinary scrolling but cannot hide arbitrarily large jumps across history.
5. **Reuse existing native rich-content bodies.** Completed prose/code/tables avoid repeated SwiftUI hosting. Reused views reset content-specific selection, copy feedback and horizontal position. Shared styles avoid a separate visual specification.
6. **Reuse already-computed exact heights.** Prose/table layouts already know their geometry. Reading those heights removes duplicate SwiftUI measurement without adding a cache. Code headers and interactive content keep the original measurement path. Sixty exact-height comparisons cover three widths and first/last block combinations.
7. **Correct live geometry and anchoring.** Content refresh no longer invalidates an unchanged live height reporter. Height changes move all resident neighbors immediately; mounting remains coalesced. A top-aligned hosting wrapper prevents growing content from recentering upward before its allocation catches up. Regression tests reproduced the previous stale-height, overlap and 120-point upward-shift failures.

Existing pagination, layout caching and syntax warmup are part of the system; not every mechanism listed here was newly introduced in this investigation. No measured process-startup speedup is claimed.

## What was rejected

A renewed List investigation tested vertical fixed sizing, native rich-row hosting, host reuse, explicit cached heights, scheduled AppKit overdraw, message grouping, and grouping with reuse. None established near-native heavy-scroll consistency with acceptable complexity. Those experimental changes were removed; their patches/results remain archived.

Keeping only the latest width in the text-layout cache reduced cache-entry counts but barely changed normal five-chat memory and made revisited widths require more work. It was removed. No eager warming of five full transcripts was added.

## Results and limits

The final ordinary 8,000-point/second sweep measured 119.69 display-link callbacks/s, with 8.33 ms p99 and 17.73 ms maximum intervals. Two final streams measured 114.74–115.35 callbacks/s with exact source and completion checks passing. Full-history preparation median improved from 8.34 to 6.68 seconds; normal paginated opening remains approximately 0.8 seconds, with no demonstrated normal-opening improvement from the height change.

Five fully loaded chats after four widths each ended at 343.2 MiB whole-process RSS. This is a checkpoint, not a universal memory ceiling or measured peak. Each full-history prepare/four-resize/settle sequence took about 28 seconds. Earlier extreme full-history scrubbing remained around 55–56 callbacks/s. Universal 120 presented FPS has not been achieved or independently measured.

The main build succeeded and 55 selected tests passed on September 11. Pagination/resize probes passed with zero anchor error. Visual checks found the restored original List centered and the corrected streaming indicator below content, but do not establish complete visual parity. The user's earlier List misalignment was not reproduced in the restored source. Claude's reported loading failure remains unverified.

## Reports

- [Latest detailed results and tradeoffs](CHAT_PERFORMANCE_BALANCE.md): final geometry fixes, additional List experiments, preparation gain, memory and limitations. Start here for numbers.
- [Native architecture and first optimized comparisons](CHAT_NATIVE_PERFORMANCE.md): virtualization, native body reuse, scheduling and scrolling/streaming/scrubbing evidence.
- [Initial follow-up and cleanup/beta investigation](CHAT_PERFORMANCE_FOLLOWUP.md): no demonstrated staged-cleanup regression, beta source inspection, initial profiling and experiments. These older builds/settings are not interchangeable with final optimized measurements.
- [Container experiments](CHAT_CONTAINER_EXPERIMENTS.md): historical alternatives and outcomes.
- [Original Fable report](CHAT_PERFORMANCE_REPORT.md): work preceding this follow-up.
- [Manual launch and benchmark instructions](CHAT_BENCHMARK_GUIDE.md).
- [QA checklist](CHAT_QA_CHECKLIST.md): remaining manual and integration coverage, not a claim of completed testing.
- [Raw final artifacts](benchmarks/2026-09-10/balance/): JSON/logs, rejected experiments, failing/passing regression evidence, final 55-test summary and source hashes. The directory includes the September 11 follow-up results.

## Adapter compatibility recommendation — proposed, not implemented

Keep maiD's ACP transport generic. Implement Codex app-server history compatibility in codex-acp, ideally upstream. Prefer documented capabilities where available; otherwise narrowly fall back on an unsupported history operation, not arbitrary auth/network/data errors. Support legacy full-history and paginated turn/item retrieval with complete ordering and pagination. Test old ordinary threads, older paginated backends and current backends. Never silently return empty or partial history as success.

For registry-managed agents, default to updates to a supported adapter/runtime combination, record the resolved versions, and activate updates at an idle process restart. Keep the previous executable installation for launch regressions, but do not promise runtime rollback can reverse a migrated history format. Respect explicitly configured custom commands and pinned versions; surface limitations when capabilities or stored data cannot be supported. Arbitrary combinations of all historical CLI/adapter versions cannot be guaranteed.

Current maiD registry code invokes npm with a version range bounded by the registry version recorded at install/update, not an exact reproducible pin. A maintainable improvement is to resolve and retain an exact installed adapter and dependency set per installation/update, rather than resolving changing dependencies at every launch. Updating the adapter alone may not update the bundled runtime; report both and the actual executable path. The installed codex-acp normally uses bundled Codex, with CODEX_PATH as an override.

The observed error is a Codex history API compatibility gap; it is independent of SwiftUI/AppKit and local transcript pagination. Better error context should identify provider, adapter/runtime version and failing operation. This is especially useful for investigating the still-unconfirmed Claude report.
