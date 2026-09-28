# Reasoning and tool streaming QA — September 23

Base commit `dbba066`, plus `source.patch.gz`. `manifest.json` identifies source and built code images. The fixture is entirely Debug-only and uses the production reducer and streaming buffers with an isolated synthetic thread. No provider request, account, daemon or user conversation is involved.

## Results

- **macOS 27 and an iOS snippet host pass the complete activity state scenario.** The iOS snippet’s historical runtime was not recorded and is not proof of this full scenario on iOS 18.6; see [runtime correction](../RUNTIME_EVIDENCE.md). It streams a 6,000-character thought in 40-character chunks at 50 ms, 12 tool-output updates, a second 1,600-character thought, and the existing 20,000-character assistant reply. Both completed thought payloads and final tool/reply text match exactly. The turn completes, the five new entries are unique, and the existing history identities remain in order. These are reducer/state results, not motion or rendering results. `reducer-snippet.swift` is the exact check; `mac-state.json` and `ios-state.json` are its Xcode MCP outputs.
- **The assistant and reasoning observation regressions pass on each platform: 2 Mac / 2 iOS tests.** Actual result bundles confirm zero failures, skips or runtime warnings. Twenty text deltas update the live text without invalidating the observed selected thread, sidebar list or selected title. Thought completion publishes the authoritative final text and removes the live buffer. This checks observation boundaries; it cannot determine every view redraw, compositor update, or why the system screen-sharing icon flickers.
- Both app/test-target builds pass through Xcode MCP. The warning query reports no compiler issues. Raw logs retain the App Intents metadata extraction warning because these targets do not depend on AppIntents. iOS remains at the user's chosen 18.6 deployment target; the actual test-runner checks use the iOS 18.6 destination. The full-state snippet has no recorded runtime identity and retains the limitation above.
- No new streaming animation, placeholder/blanking behavior, native renderer change, or mobile renderer migration is introduced.

## Capture remains unverified

**No valid activity recording was obtained.** Do not use these attempts to pass the thinking-label displacement, split-frame, disclosure-transition, or presented-frame requirements. The previously captured assistant-only completion regression remains separate evidence in `../rendering-20260922/REPORT.md`.

The initial main-app attempts failed viewport selection/setup: one selected a restored window of the wrong size, one never stabilized its requested viewport, and an experimental launch that ignored saved state created no main window before timeout. The experiment was removed. Exact window-number selection now replaces selection of the largest window; older builds are accepted only when there is exactly one owned window matching the expected dimensions. Window restoration was a setup hypothesis, not a proven product defect.

Four explicitly owned ChatView snippet-window attempts also failed the on-screen capture gate. They reported `isVisible`/active-space state but lacked the visible occlusion state and were absent from the on-screen window list. Unhiding, activation and QA-only window-level/space changes did not establish a valid recording. The last attempt also used a layer-zero capture filter with a floating window; the exact-window query now accepts that level, but it was not rerun and does not retroactively validate the attempt. The experimental snippet and recorder are retained for diagnosis; they are not a demonstrated capture method.

A direct executable launch reached the correct 1280×900 viewport and started recording, then the benchmark rejected `visible=false` before measurement. Its partial movie is excluded and remains outside Git. The temporary direct-launch option was removed. All owned recorder/app attempts stopped; the existing Xcode-launched app was left alone. No foreground-window screenshots or unrelated window text are included in this report.

`attempts/` retains the failures and scoped app/capture logs, including timeouts. The snippet outputs retain syntax-highlighter missing-style warnings. No runtime crash was observed in the passing state checks or result bundles.

## Reproduction

After an Xcode MCP Debug build, the main-app recording harness accepts `--activity`:

```sh
python3 clients/swift/scripts/record-chat-stream.py /path/to/mai.app /empty/output --activity --container custom
python3 clients/swift/scripts/record-chat-stream.py /path/to/mai.app /another/empty/output --activity --container list
```

Use a build with no running instances and an unobscured window. The harness verifies the exact owned window and final source/completion plus every activity phase. The fixture emits phase timestamps for later transition inspection. A successful harness result would still require examining actual captured frames and reporting capture gaps; requested 120 Hz is not proof of 120 presented frames.

For the completed state checks, run `reducer-snippet.swift` with Xcode MCP in `mai/Features/Chat/ComposerAttachments.swift`, once on My Mac and once on iOS, printing the actual runtime rather than inferring it from the selected destination. Use the test runner with recorded device metadata to verify iOS 18.6. The Swift test identifiers and actual result summaries are saved alongside this report. Xcode's active destination was restored to My Mac afterward.
