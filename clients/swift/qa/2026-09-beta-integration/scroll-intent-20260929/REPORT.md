# Streaming scroll intent — September 29, 2026

Result: native and List pass the full-chat scroll-away/resume scenario after fixing a conflicting geometry observer. This is a macOS functional check, not a 120 Hz presentation or physical-input performance certification.

## Defect and fix

Before the fix, the reader's actual vertical origin stayed fixed during streaming, but the native chat's `isNearBottom` flag repeatedly changed to true and back to false. The jump button therefore received false visibility changes.

The callback trace identifies two sources competing for the same state. During the measured reading-away phase, the native transcript emitted 69 correct `nearBottom=false` reports; a SwiftUI observer above both renderer branches emitted 57 `nearBottom=true` reports from a smaller nested scroll area (760 points wide, with content height equal to viewport height), while the actual transcript viewport was 1100 × 698 points. See `native-before-trace/geometry-trace.json`, samples, and `trace-diagnosis.json`. The observation invalidation count is one-shot: 1 means a change occurred, not that only one change occurred.

Move `onScrollGeometryChange` onto the macOS List branch itself. The AppKit transcript already reports its actual document geometry. It must not also inherit SwiftUI geometry from a nested code/table scroller. No debounce, threshold change, or animation masking is involved. Apple's [geometry-observer documentation](https://developer.apple.com/documentation/swiftui/view/onscrollgeometrychange(for:of:action:)) explains that the modifier selects the first scroll view it finds in the hierarchy.

## Method and source

- Base HEAD: `5d5fc5b`. Post-fix app = that base plus `product-fix.patch`, temporary instrumentation, and the pre-existing external Xcode project change. Do not describe this as a pristine committed binary.
- Normal Debug app built and launched with Xcode MCP, not a Preview host. Actual app reports macOS 27.0 build 26A428. Post-fix PIDs: native 62926, List 62979. Launch records, per-run source hashes and compressed build logs are included.
- Full production `ChatView` with six completed rich turns; fixture transport delivers production ThreadStore notifications. Stream 32 characters every 40 ms, independently of the assertions, until all 12,047 source characters arrive.
- One 1100 × 800 point content window per renderer. Follow for 2 seconds; use the production live-scroll start/end notifications and native clip offset to move 1500 points away; observe for 4 seconds; return to the actual document end and observe resumed following for 3 seconds. This exercises the scroll controller without claiming physical trackpad event coverage.
- Sample offsets and follow/visibility state about every 16 ms; one-shot Observation tracking additionally detects state mutation between samples. Each stable phase must have zero invalidations, enough source growth, and the expected final state. While reading, origin drift must be at most 1 point. While following, the end must stay within the existing near-bottom distance.
- Require exact final Unicode source, completed turn, unchanged prior identities and no duplicate IDs. Capture actual windows at five checkpoints, with `screencapture`; inspect reading-away and completed views for correct button/content presentation.

## Results

| Renderer / phase | Samples | Characters added | Maximum bottom gap | Reading-origin drift | State invalidations |
| --- | ---: | ---: | ---: | ---: | ---: |
| Native initial follow | 111 | 1536 | 0 pt | — | 0 |
| Native reading away | 217 | 3040 | 4279 pt | 0 pt | 0 |
| Native resumed follow | 161 | 2272 | 0 pt | — | 0 |
| List initial follow | 100 | 1504 | 0 pt | — | 0 |
| List reading away | 197 | 3008 | 4279 pt | 0 pt | 0 |
| List resumed follow | 144 | 2304 | 0 pt | — | 0 |

Both final replies match all 12,047 source characters; both complete and preserve identities. Captures show centered content, jump button visible while reading away, and the completed source marker with no jump button at the bottom. Horizontal clip origin is zero at all checkpoints after the initial native loading capture.

The native initial capture has no mounted transcript yet (`clipX/clipY=-1`). It is retained as a loading checkpoint, **not** evidence that cold opening or blank-viewport duration passes. No state-mutating test hooks are used: the injected scroll-state reference only observes the same state used by the production view; scrolling goes through native geometry and controller notifications.

44 existing timeline-layout/native-transcript regression checks pass on the final source with all temporary app hooks removed. Test-result metadata identifies My Mac, macOS 27.0 build 26A428; 0 failed, 0 skipped, 0 runtime warnings. This is not a full-suite result. The first cleanup build retained Xcode's stale file inventory and failed looking for the removed temporary harness; the next build succeeds without source changes. Both logs are preserved.

## Reproduction and remaining scope

`ChatScrollIntentQA.swift.txt` preserves the harness; `instrumented-product.patch` reproduces the product fix plus temporary hooks against the base. `temporary-hooks.patch` is the original pre-trace hook patch. Copy the harness into the filesystem-synced Chat source folder for an isolated QA run, install the hooks, write `mai-scroll-intent-qa-request.json` in the app container's temporary directory with `output` and `renderer` (`native` or `list`), run `capture-window.py <output>` and launch through Xcode MCP. The capture script exiting successfully only means captures completed; require `result.json` to contain `passed: true`. Remove the marker, harness and hook changes afterward. Current product source contains only the geometry ownership fix.

Raw before-failure records, the traced reproduction, and both passing after runs remain separate. Further gates still include thought/tool disclosure while streaming, physical scrolling/jump-button input, iOS scroll intent, cold opening/sidebar/fullscreen, broader frame presentation, and release validation. The pending generated timestamp decoder and its two iOS 18.6 replay failures are unaffected.
