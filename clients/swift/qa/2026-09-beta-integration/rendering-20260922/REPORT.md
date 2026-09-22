# Scripted streaming capture — September 22

Initial-capture scope: native macOS and SwiftUI List, animation-free production message/reducer/rendering paths in the daemon-free Debug synthetic fixture. Base source `2be528a` plus the benchmark-only window/checkpoint changes recorded in `../benchmarks/20260922-final/source.patch`; code image SHA-256 `bba11d79339a8289fc44ad5eddd10ff31cbc62a4460391b5cf830c6e71cc1e2c`. macOS 27, Mac14,9, one built-in display advertising 120 Hz, 1280×900-point window. No live provider or user chat was used.

## Observed results

- Both actual app runs completed and preserved the exact 20,000-character streamed source. The fixture crosses incomplete code fences, headings, nested lists, quotes, links, prose and tables before settling. Raw app logs and capture timestamps are included.
- Native and List sampled views have a 760-point transcript and composer from approximately x=400 to x=1160, centered at x=780 in the detail pane (x=280–1280). Neither sampled view is behind the sidebar. This verifies this window/sidebar configuration, not every split/fullscreen configuration.
- In the native capture, the constant `Working` word matches in **all 1,668 consecutive frames from 2.054666 to 24.254 seconds**, at y=714 with zero observed vertical displacement. Its worst template mean absolute error is 0.951/255; the acceptance threshold is 6. The word disappears on completion, rather than moving to another matched position. `native-working-label.csv` includes every frame, including unmatched pre-stream and post-completion frames. An initial summary restricted to after 4 seconds counts 1,519 of those frames.
- The upper transcript's left/right vertical-motion comparison nominated frames 1357 and 1418 when both bands changed, with individual matching errors below 0.008 and different inferred offsets. Inspection of each frame and its immediate neighbours shows coherent whole-content movement. Sparse text on the right confused the motion heuristic; no vertical old/new-content seam is visible in these sequences. The two three-frame strips are saved at full resolution.
- The overview and intermediate native/List frames show plain text, a steady working phrase and correct relative placement beneath the content. No fade/reveal renderer was reintroduced.

## Completion regression found and fixed

The complete List frame scan caught a separate defect at completion: `Working` moved from y=714 to y=749 for 19 captured frames (25.415333–25.649833 seconds), before it disappeared. The actual before/adjacent frames are in `list-working-candidate.png`. This was not a template ambiguity: matching error was zero in several displaced frames.

The cause was mixed presentation state. The timeline intentionally preserves streaming rows while asynchronous settled-layout preparation finishes, but the bottom working phrase used the already-completed server state and disappeared immediately. List adjusted its bottom position with the old running header still visible. `ChatView` now uses the same effective streaming-presentation ID for the message rows and bottom indicator on both macOS paths and iOS; they leave that presentation together. It reuses the existing preparation boundary and adds no fade, transition or extra timer.

`completion-fix-source.patch` and `completion-fix-build.json` identify the exact change and binary. Both macOS and iOS 18.6 Xcode MCP builds succeed with zero reported warnings. The fixed production paths were recorded again using the same 20,000-character fixture and viewport:

| Captured-label regression | Matched frames | Observed label y | Result |
| --- | ---: | --- | --- |
| List before fix | 1,826 | 714, 749 | Fails |
| List after fix | 1,724 | 714 | Passes |
| Native after fix | 1,709 | 714 | Passes |

`label-regression.json` records actual command exit codes: the before capture fails the stationary-label check, while both fixed captures pass. The optional `--require-stationary-working-label` requires matches in more than half the recording and only the reference y=714; it checks this fixed-bottom fixture, not arbitrary scrolling/viewport states. Exact source and completion checks also pass on both new launches. Full frame timestamps, per-frame label measurements and binary/movie hashes are retained. This does not turn the separate seam heuristic or missing display frames into passes.

## Measurement limits

This is **capture evidence, not proof of every presented 120 Hz frame**. Native capture contains 1,878 frames over 25.170 seconds, averaging 74.57 captured frames/s, with a 156.334 ms largest capture gap. Requesting 120 Hz from AVFoundation did not guarantee 120 captured frames/s. `native-summary.json` and `list-summary.json` record each capture's actual timing. Recording/encoding adds workload, so app callback reports from these launches are excluded from uninstrumented performance comparisons.

Template tracking checks the working label, not every pixel or every thought/tool disclosure. Motion matching ranks frames for review; it is not a correctness oracle and can miss seams. The native initial capture did not reproduce the reported split-frame or label-bounce defect within its observed coverage; the List completion defect found by the expanded scan is recorded and fixed above. Full high-refresh presented-frame validation and reasoning/tool-specific disclosure transitions remain open. Capture logs cannot determine why another app's screen-sharing indicator flickers.

## Reproduction and artifacts

The capture harness is `clients/swift/scripts/record-chat-stream.py`. Run it with the already-built Debug app and an empty output directory, selecting `--container custom` or `--container list`. It launches the fixture, waits for a verified visible 1280×900 window, records only that crop without audio, stops capture before closing its app, and saves timestamps and source validation. It does not build.

`analyze-capture.py` is specific to this fixture/viewport. First extract its reference image from the recording at 15 seconds with FFmpeg; the reference's label bounds were visually verified. Decode with `-fps_mode passthrough` to preserve the actual variable-rate frame sequence. The candidate criterion used here is a left/right inferred-shift difference greater than 2 pixels, both zero-shift errors greater than 0.008 and both minimum errors below 0.008. Inspect candidates and their neighbours; do not convert heuristic success into a universal pass.

Original movies stay outside Git in the local QA cache; paths, hashes and sizes are in each summary. App logs, capture metadata, all capture frame timestamps, label positions, sampled full frames and candidate strips are committed. FFmpeg capture logs and full timestamp JSON are losslessly gzip-compressed; capture logs retain their original carriage-return progress output. The initial native window probe failed because JavaScript for Automation returned the screen count as a string; the corrected probe converts it to a number. No recording was taken in that attempt. The first analysis attempt omitted timestamp passthrough and was stopped; its results were discarded. The completed analysis uses the actual 1,878-frame sequence.

## Uninstrumented streaming after the fix

Three fresh visible launches per renderer, same 20-turn paginated fixture and 20,000-character stream, with no capture/profiler/build running. All six logs pass exact-source/completion and viewport checks; saved JSON reports match raw logs. `timing-audit.json` records the audit and binary hashes.

| Renderer | Mean callback Hz | p99 interval range | Worst interval |
| --- | ---: | ---: | ---: |
| Native | 110.68 | 23.86–24.63 ms | 55.21 ms |
| List | 96.28 | 29.70–31.00 ms | 201.40 ms |

These are display-link callbacks, not presented FPS. Occasional stalls remain; this is not a constant-120-fps claim. Existing September 21 Release archives predate this completion fix and need refreshing before they can serve as final release evidence. iOS 18.6 compilation passes; an iOS runtime completion/keyboard/rotation pass remains required.
