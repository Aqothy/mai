# iOS plain-chat retest — 2026-09-20

**Result: blocked by device-session lifecycle failure; no requested scenario verified.** The parent supplied a build based on app source `217e488`, with later test-only edits, for iPhone 17 Pro / iOS 27 simulator `8D313546-861F-484C-B6BF-E2AA8B2DEF2A`. This subtask did not build, change app source or the Xcode project, restart or end a session, send a prompt, or use a physical phone.

The required device-interaction skill was read first. Only Xcode device-interaction capture/activation calls were used for UI access.

## Setup evidence

1. The first capture with parent-supplied key `Plain Chat Final Simulator QA` returned `Session not found. It may have already been closed, or the identifier is wrong`.
2. The parent created a non-workspace retry session, `Plain Chat Interaction Retry`. Capture succeeded but showed SpringBoard and reported `applicationState: NotRun`. Activating the installed `com.anthonyqiu.mai` once opened process **70290**, with **No Threads** and **Connecting…**. The synthetic launch arguments were absent. No further app interaction was attempted in that ordinary shell. See [screenshot](00-launch-without-fixture.png) and [hierarchy](00-launch-without-fixture-hierarchy.txt).
3. The parent closed the retry session, created a fresh workspace-backed session `Plain Chat Fixture QA`, and reported successful installation with `-ChatPerformanceLab -ChatBenchmarkSyntheticTurns 300 -ChatBenchmarkPaginatedHistory YES -ChatBenchmarkUseList NO`. The immediate first capture again returned the same `Session not found` error. The retry loop was stopped and the parent informed.

The failure is an environment/tool interruption, not evidence of an app crash or a pass/fail result for the source changes. The retry session's `NotRun` status does not establish the parent-owned installation's process state.

## Still required

- Pending annotation plus multiline Unicode draft in landscape **with the software keyboard visibly present**: Prompt, Send, Back, title, annotation chip, and jump-control clearance; draft restoration in portrait.
- Long selected quote in Comment with the software keyboard: note remains visible/editable and Add/Cancel remain accessible.
- An actual older-history pagination boundary from the initial chunk of the 300-turn fixture, with before/after anchor and duplicate-row observation.

Earlier evidence in [the parent results](../RESULTS.md) remains limited to its explicitly identified builds and scenarios. This run adds no iOS 18.6, physical-device 60/120 Hz, timing, streaming, accessibility-service, or real-provider validation.

## Direct scripted launch after user workflow correction

The user requested scripts and direct computer control in preference to Xcode interaction sessions, then requested non-UI QA whenever it provides equivalent evidence. `simctl launch --terminate-running-process` with the same synthetic arguments successfully started process 70772; a simulator screenshot verified the expected synthetic thread in the ordinary app shell. The transient launch screenshot is no longer present in the local evidence directory. This confirms fixture launch, not entry into the chat or the remaining keyboard/selection cases. Device Hub direct accessibility timed out repeatedly, including after its QA-owned viewer process was reopened. No physical phone was used. Subsequent non-UI checks should use scripted launch and Xcode MCP tests/builds; do not treat viewer failure as app failure or mark unobserved interactions passed.
