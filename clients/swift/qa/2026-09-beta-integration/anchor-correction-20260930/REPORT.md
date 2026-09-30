# Apply AppKit row remeasurement once — September 30, 2026

The List reading-position failure from the earlier disclosure run is fixed. The app was adding a row-height delta to a clip origin that AppKit had already adjusted for that same delta. The new correction uses the last preserved origin plus the anchor's movement, so AppKit's own adjustment is not counted twice. User scrolling still clears that anchor and establishes a new one when the gesture ends.

## Reproduction and regression

The earlier List trace includes a 277-point row correction applied twice (213 → 490 → 767). A focused test using a real `NSScrollView`, the production position preserver and document notifications reproduces the fault without accessibility or SwiftUI. Growing the first row should move the origin from 250 to 350; before the fix it reaches 450. Subsequent shrink/growth also fails. `anchorBefore.json` records 2 passing tests and this failing test; `anchorAfter.json` records all 3 passing.

The tests cover both AppKit moving the clip before the observer runs and leaving the clip for the observer to correct. A third case changes row geometry during a user scroll, confirms the user's new position is retained, and verifies subsequent layout uses the new reading anchor.

After removing the temporary app hooks, Xcode MCP build-for-testing succeeds and all **47 selected native transcript, timeline and scroll-position tests pass**, with zero skips or runtime warnings. The actual result bundle identifies My Mac, macOS 27.0 build 26A428 (`regression-runtime.json`). A first cleanup build referenced the just-deleted temporary source; Xcode's synchronized file inventory caught up and the next build succeeded. Both logs are retained.

## Actual List controls during streaming

The normal Debug app hosts the production ChatView and ThreadStore notification path. Six completed fixture turns precede a growing reply. An external CUA client clicks the actual activity, thought, command-group and command labels; accessibility output confirms each expected expansion/collapse and command output. Small temporary hooks only record that a real action happened; they never set disclosure state. Each subsequent action waits for the app-side measurement/capture stage to finish.

All eight actions pass in `list-after/result.json`:

| Control | Open | Close |
| --- | --- | --- |
| Completed activity | Reading anchor −14 → −14 pt | −14 → −14 pt |
| Thought | −14 → −14 pt | −14 → −14 pt |
| Command group | −14 → −14 pt | −14 → −14 pt |
| Individual command output | −14 → −14 pt | −14 → −14 pt |

Following remains disabled and streaming advances during every action. The final reply matches **7,868 characters** exactly, the turn completes, previous item/message identities stay unchanged and no IDs duplicate. The anchor is the first substantive visible row; target controls are below it, so its row index remains stable. Raw clip offsets and total height change as List replaces estimated row heights. The invariant is the visible row's offset, not a fixed raw document offset.

The captures show the same preceding answer and target labels in place. Thought and nested output extend below the viewport; this sequence alone does not establish all expanded content is reachable after offscreen reuse. It also does not cover disclosure above the anchor, active thought updates, physical VoiceOver navigation, iOS or display-rate performance.

## Provenance and rejected driver attempts

- Base `446b2b2` plus `product-fix.patch`, the recorded temporary hooks and the existing external Xcode project change. `list-after-launch.json` contains source hashes. The actual run is PID 94278, Xcode launch `76bd13c300`, macOS 27.0 build 26A428.
- `ChatDisclosureQA.swift.txt` and `temporary-hooks.patch` preserve the exact successful driver. Capture helper and initial accessibility acknowledgement helper are in the preceding `disclosure-20260930` report folder. Regular action stages advance from actual button events, without external acknowledgements.
- `list-interrupted` passed three stages before the input wait expired. It is not a passed run.
- `list-driver-race` sent the next click before its capture/stage began, so the event was missed by the driver. That run was stopped and the readiness gate added.
- `list-expired-capture` contains an expired/relaunched attempt whose capture helper was no longer running. Its one measured anchor passes, but the missing capture makes the run fail. Only the fresh `list-after` folder is the completed pass.

All temporary source, action hooks and launch markers were removed before the final build and 47-test run. The earlier native eight-action result remains in `disclosure-20260930/REPORT.md`; the new unit suite includes native reflow and growing-row coverage. Full positional, offscreen and iOS disclosure QA remains open.
