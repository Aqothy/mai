# Disclosure during streaming — September 30, 2026

Native: the completed activity, thought, command group and nested command output all open/close while a reply streams, without moving the reading origin. List: the comparison remains **unverified**, because external accessibility inspection changes its geometry and moves the intended control offscreen before disclosure input. The full top/middle/bottom and iOS disclosure requirements remain open.

## Native result

The normal Debug app runs the production `ChatView` and ThreadStore notification path with six completed fixture turns. Completed answers are compact, each thought contains 2,060 characters of detail, and each turn has three completed command steps. A new reply begins with a 2,402-character preamble and continues with numbered words every 120 ms independently of the input driver. The script returns to the last completed turn and pauses automatic following via normal native live-scroll notifications.

An external accessibility client (CUA) activates the actual controls. After each action, the updated accessibility state was inspected. The app-side script measures layout, captures the actual window and advances only when the external action is acknowledged. It does not call the disclosure model or change its expanded state directly.

| Action | Observed UI result | Origin before → after |
| --- | --- | --- |
| Open completed activity | Hide activity + Show thought + Ran 3 commands | 297 → 297 pt |
| Open thought | Hide thought + long reasoning text | 297 → 297 pt |
| Close thought | Show thought; long detail removed | 297 → 297 pt |
| Open command group | Three individual command controls | 297 → 297 pt |
| Open first command | Build complete! (1.5s), command and timing | 297 → 297 pt |
| Close first command | Output text removed | 297 → 297 pt |
| Close command group | Individual command controls removed | 297 → 297 pt |
| Close completed activity | Show activity; thought/group removed | 297 → 297 pt |

All eight stages keep `following=false`, `nearBottom=false`, and advance the reply source. Final source matches all 9,268 characters exactly, the turn completes, previous message/item identities remain unchanged, and no IDs duplicate. `native/result.json` contains the authoritative pass, stage data and nine capture checkpoints. The thought and nested-output captures show the opened content; the viewport remains at the same preceding answer. The long thought/output extends below the visible viewport when expanded: this run does not establish the separate full-reachability, offscreen-reuse or disclosure-persistence checks.

## List issue to investigate

No List disclosure sequence is counted as passed. The initial intended row reports offscreen to the accessibility click operation. A position-only diagnostic without external inspection keeps the actual List origin at 297 points before/after the synthetic scroll (`list-position-probe`). During a subsequent interval containing the first external accessibility inspection, the origin changes **297 → 0 → 193** before any disclosure action (`list-accessibility-activation`).

Initializing accessibility before the position baseline does not resolve it. The next run starts its measurement at 213 points, then changes through **490, 767, 323, 545, 657, 72, 340 and 0** during further inspection/attempted input. Document height changes accompany these offsets while following remains false. The controls cannot be clicked because the target reports offscreen. `list-after-ax-setup/ready.png` shows the last three answers; `after-inspection.png` shows the first answers. Thus the effect reaches the visible viewport, not just a sampled flag. Raw samples and compact `origin-changes.json` files retain the transitions.

The recorded document class is `SwiftUI.SwiftUIOutlineListView`. The first position-only probe retains the same scroll view/window identity. The origin sampling added afterward reacquires the live transcript for each sample. Causality between SwiftUI/AppKit accessibility layout, the app's anchor corrections and the external client's tree queries is **not yet isolated**. Do not call this a proven ordinary pointer-scrolling regression or dismiss it as harmless test noise. A smaller reproduction must distinguish the external inspection behavior from app anchoring before this QA gate can pass.

## Source, execution and rejected setup attempts

- Base: `8d0d2a8`, plus temporary QA hooks and the existing external Xcode project change. `metadata.json` records source hashes and launch references. This is not a pristine committed binary.
- Native pass: macOS 27.0 build 26A428; normal Xcode MCP launch, PID 97388, reference `76d5368780`. `ChatDisclosureQA-first.swift.txt` exactly matches its recorded source hash. It also serves the first List attempt.
- `ChatDisclosureQA-traced.swift.txt` preserves the later List probe and accessibility-initialization setup; `temporary-hooks.patch` supplies the launch/state-reference hooks against the base. The injected scroll-state reference observes the production state, with an explicit setup-only bottom request in the final attempted List run.
- In-process accessibility enumeration failed to expose SwiftUI buttons. An external CUA query did expose them, so input moved to that client. These discovery attempts are retained under `native-setup-*` and are not product failures.
- The first longer native interaction run hit the capture helper's original 120-second deadline after four completed state measurements. It did not pass. The successful run uses a 900-second capture deadline and a slower-growing stream. The UI-input wait remains bounded per stage.
- Both unresolved traced List runs were stopped explicitly; `aborted.json` identifies why. Earlier timeout results remain separate. A successful capture helper exit is not a test pass: require the scenario's `result.json`.

All owned app/capture processes were stopped. The request marker, temporary source and product hooks were removed. `ContentView.swift` and `ChatView.swift` again match HEAD. Xcode MCP build-for-testing succeeds after removal (`BuildProject-Log-20260930-123821.txt.gz`). No product change was made for disclosure QA.

Next: isolate the List accessibility/layout movement, finish equivalent List interaction, then extend disclosure checks across viewport positions, offscreen rows and actively streaming thoughts/tools. Physical VoiceOver/keyboard navigation, iOS and device performance remain independent release gates.
