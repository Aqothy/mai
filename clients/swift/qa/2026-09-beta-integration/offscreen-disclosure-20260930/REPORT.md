# Offscreen disclosure follow-up — September 30, 2026

The native scenario completed its automated geometry/source checks. The List comparison is **incomplete**, and full disclosure-state/pixel equivalence is not established. The user requested wrap-up to limit time/usage; no further run was started.

## Native result

Normal Xcode MCP Debug app on macOS 27.0 build 26A428, base product commit `641a886`, PID 94811, launch `76d54f1c80`, plus the archived temporary hooks and pre-existing external project change. `metadata.json` records source hashes; `ChatDisclosureQA.swift.txt` is the scenario source.

The fixture contains 20 completed turns, with ordinary initial pagination, and a new streaming reply. CUA activates the real final completed activity and thought controls. Each opening preserves the reading anchor at −14 points while following remains paused. The reply completes with its exact 3,732-character source, original item/message IDs preserved and no duplicates.

After completion the script moves to older history four times, returns to the original reading anchor, resizes to 700/1280/800/1100 points and reaches the end. Loaded native rows grow **20 → 50 → 64** and stop growing once history is loaded. The returned anchor has the same stable message/segment ID and **−14-point offset at return and all four widths**. It reaches the bottom with origin 3,862 and height 4,560 against a 698-point viewport; following is restored there.

Every recorded checkpoint has finite nonnegative row geometry, nonoverlapping sequential rows, a final row within the document extent and a nonempty visible row range. `layout-checks.json` preserves measurements; `result.json` is the successful source/geometry result. The stable-offset resize values were inspected from the saved measurements; the fixture does not independently assert every captured pixel or the full user experience.

The document extent changes 4,808 → 4,560 on return after offscreen reuse. Thought disclosure state may have changed as views were recycled; the captures are retained for comparison, but that specific behavior was **not adjudicated** before wrap-up. Do not claim that expanded thought persistence matches List or that every part of expanded content was visually reviewed. The earlier checklist deliberately requires comparing persistence before treating a reset as a regression.

## Incomplete List comparison

PID 94921, launch `76c6d2e100`, same scenario source. Accessibility was initialized and the final activity was opened successfully. The latest recorded stage is `last-thought-open`; there is no final result. At wrap-up the process was no longer running and the capture session handle had expired. `list-incomplete/aborted.json` records this; this is neither a completed pass nor an established product failure. The earlier eight-action List pass remains independently valid in the anchor-correction report.

## Cleanup and next action

Temporary `ChatDisclosureQA.swift`, startup/action hooks, injected state and request marker were removed. Cleaned source builds successfully through Xcode MCP (`BuildProject-Log-20260930-224337.txt.gz`). No additional tests were run after the user's stop request; the preceding 47-test anchor/native/timeline run is preserved under `anchor-correction-20260930`.

If this requirement remains in scope for the next bounded milestone, use the saved fixture/captures to compare offscreen thought-state behavior and actual reachability, then fill the missing List result. Reuse the setup; do not repeat unrelated benchmarks or infer a pixel/interaction pass from geometry alone. The full top/middle/bottom, active thought/tool, iOS and physical input matrix remains in the handoff.
