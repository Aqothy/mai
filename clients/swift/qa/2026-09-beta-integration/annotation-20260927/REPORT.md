# Long-quote annotation QA and runtime audit — September 27, 2026

No annotation layout defect was established and no product layout changed. Keyboard clearance on the supported older runtime remains incomplete.

## Measured results

- Mac hosted editor: a 7,090-character quote in a 500-point-wide window leaves a 255-point visible note viewport. This checks layout geometry, not keyboard or pointer interaction.
- iOS preview host: explicitly focusing the real note editor produces a 328-point software-keyboard area and a 211.33-point visible editor above it. Native multiline Unicode insertion updates the note exactly while retaining the quote. A runtime probe identifies **iOS 27.0**, simulator `4F9854A9-3749-4BD5-BF18-8FA8C31DC7E1`, despite Xcode's active run destination being iOS 18.6. These are not older-runtime or physical-device results. This harness hosts the editor directly, rather than proving the complete app's sheet transition.
- Actual iOS 18.6 test runner: the preserved `ChatAnnotationLayoutTests.swift` presents the production editor as a real sheet. The test's console and `.xcresult` summary both confirm iOS 18.6 / iPhone 16 / `9BE259FD-5083-4C60-9D6A-0AAC4CDB2F48`. Native Unicode editing and quote preservation succeed, but the software keyboard does not appear: its guide only occupies the 34-point bottom safe area. The explicit keyboard-presence assertion **fails**, so this is not a keyboard-clearance pass. The note is 342.33 points tall in that state.

`ios18-sheet-result.json`, compressed logs and `ios18-runtime-summary.json` retain that failure. The harness was moved out of the default unit-test target into this QA folder after collecting evidence because it requires a visible software keyboard. This preserves the failed requirement; it does not convert it to a pass or a skipped release gate. To rerun, temporarily copy the harness into `maiTests`, build with Xcode MCP and run `ChatAnnotationLayoutTests/longQuoteLeavesAnEditableNoteAboveTheKeyboard()` on the intended device. Record the actual runtime and require the keyboard assertion to pass.

## Tooling limits

Initial iOS snippet attempts inspected a lazily created window keyboard guide and reported zero bounds. Creating the **root view's** guide before focusing produced the correct geometry; those incomplete attempts are preserved. Two harness build failures (a quoted interpolation and a Swift Testing macro expansion around `first(where:)`) were repaired before execution. These are harness failures, not product regressions.

No `UIButton` was exposed for the iOS 27 SwiftUI toolbar, so Add/Cancel actions were not verified by the view-tree walk. A normal Simulator.app is absent in this Xcode installation; its viewer is DeviceHub. One direct DeviceHub accessibility attempt timed out, matching earlier viewer problems, and was not looped. No simulator keyboard preferences were changed. Software-keyboard visibility on iOS 18.6, Add/Cancel reachability/actions, landscape with pending annotations and pagination still need verification.

The runtime mismatch also means an active Xcode destination cannot establish the runtime of historical `RunCodeSnippet` checks. See [runtime evidence correction](../RUNTIME_EVIDENCE.md). Unit-test `.xcresult` device metadata remains authoritative; the keyboard checkpoint's 14/14 result is independently confirmed on iOS 18.6 in its added runtime-summary artifact.
