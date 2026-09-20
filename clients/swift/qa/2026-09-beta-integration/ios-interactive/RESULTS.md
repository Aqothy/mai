# iOS interactive QA — synthetic transcript

Tested the installed app supplied by the parent task at commit **412959a** on the **iPhone 17 Pro, iOS 27 simulator**. Session: `Beta Release Simulator QA`; app: `com.anthonyqiu.mai`; process 52354 remained running throughout the observed interactions. The app used `-ChatPerformanceLab -ChatBenchmarkSyntheticTurns 300 -ChatBenchmarkPaginatedHistory YES -ChatBenchmarkUseList NO` in the normal app shell. This was an offline synthetic store; no prompt was sent and no real provider or daemon was contacted by these UI steps.

**Result: incomplete; one reproducible landscape layout defect.** These captures do not establish production readiness or performance timing. Source HEAD was already `571c565` when the session was revalidated later; no later binary or fix was verified here.

## Observed behavior

| Check | Result and evidence |
| --- | --- |
| Initial chat opening and bottom alignment | Passed for this fixture. Opened the only synthetic thread; final user turn 300 and its assistant response were visible, with the response ending above the composer. The hierarchy reports the outer transcript scrollbar at 100%. No blank settled transcript. [01 screenshot](01-initial-bottom.png), [hierarchy](01-initial-bottom-hierarchy.txt). |
| Agent activity, thought, grouped tools, individual tool | Passed by tapping the visible labels. Expanded “Worked for 2m”, then “Thought for 3s”, “Ran 3 commands”, and the first command. The expected turn-300 thought, command, build output, and duration appeared. Collapsed the individual tool, tool group, thought, and activity again. [02 expanded](02-expanded-thought-tool.png), [02 hierarchy](02-expanded-thought-tool-hierarchy.txt), [10 collapsed](10-activity-collapsed.png), [10 hierarchy](10-activity-collapsed-hierarchy.txt). |
| Jump to bottom after expansion | Passed. The jump control returned the final response entirely above the composer and the outer scrollbar to 100%, while keeping activity expanded. [09 screenshot](09-jump-bottom-expanded.png), [hierarchy](09-jump-bottom-expanded-hierarchy.txt). |
| Prose selection and Comment action | Passed. Long-pressed the final assistant response, selected `applyThreadEvent`, opened the edit menu's next page, then Comment. The sheet showed the exact selected quote. [03 menu](03-prose-comment-menu.png), [04 editor](04-comment-keyboard.png). |
| Comment editing, cancellation, adding, removal | Passed for draft editing. Typed `iOS QA draft — cancel this` and cancelled; no chip was created. Reopened Comment with an empty note, entered `iOS QA annotation — Unicode café`, and added it. A pending annotation chip appeared and Send became enabled with an empty prompt. Removed the chip via its x; it disappeared and Send became disabled. [11 cancelled](11-comment-cancelled.png), [05 added](05-pending-annotation.png), [06 removed](06-annotation-removed.png), with corresponding hierarchy files. Editing an already-added chip is not implemented by this strip; tapping its text did nothing. This is not a verified post-add editing flow. |
| Portrait keyboard and multiline composer | Passed for the exercised text. Entered three lines (`Offline QA draft`, `Second line café`, `Third line`); all were readable, the composer remained above the keyboard, and the Send control remained visible. [07 screenshot](07-portrait-composer-keyboard.png), [hierarchy](07-portrait-composer-keyboard-hierarchy.txt). |
| Landscape keyboard rotation | **Failed.** See defect below. Returning to portrait restored the readable three-line composer; the draft survived rotation. [12 recovery](12-portrait-recovered.png), [hierarchy](12-portrait-recovered-hierarchy.txt). |
| Scroll up and reopen | Partially passed. Selected all draft text and deleted it without sending. A downward swipe in the transcript revealed older SQL/code content while the keyboard remained open. Back navigation dismissed the keyboard; reopening the thread returned to the final turn. [13 scrolled up](13-scroll-up-keyboard.png), [hierarchy](13-scroll-up-keyboard-hierarchy.txt), [14 reopened hierarchy](14-reopened-bottom-hierarchy.txt). The 14 screenshot was captured during navigation animation and is not used as a settled-layout pass. |

The expanded thought text and settled prose were readable. Code deliberately extended horizontally within its own scroll region; the transcript did not widen. Collapsed command labels were ellipsized on the narrow phone; expanding the first command exposed its complete text. The jump button overlays transcript content during scrolling, and the translucent composer can show content moving behind it; these observations are separate from the landscape defect.

## Defect: multiline composer crowds the landscape navigation and keyboard

Reproduction on 412959a:

1. Open the synthetic thread in portrait and focus Prompt.
2. Type the three-line draft above.
3. Rotate with `orientation landscapeLeft` (the application reports Landscape Right).
4. Capture again after rotation settles.

The settled [08 screenshot](08-landscape-keyboard-overlap.png) and [hierarchy](08-landscape-keyboard-overlap-hierarchy.txt) show:

- Navigation bar: y=24 through 78; composer editor region starts at y=53, overlapping that navigation region by 25 points.
- Jump-to-bottom control: y=-1 through 37, partly outside the viewport and immediately above the title.
- Send/Add controls: y=147.3 through 183.3; the keyboard input view starts at y=178, covering their bottom 5.3 points.
- Effectively no unobscured transcript area remains above the composer. A second capture without interaction reproduced the same geometry, so this was not only a rotation frame.

A smaller hit-target issue was also observed: the collapsed activity row's reported Button hitPoint `(201, 581.2)` did not activate it. Tapping its visible “Worked for 2m” label hitPoint `(69.7, 579)` did. Nested thought and tool labels responded. This report does not claim VoiceOver activation was tested.

## Missing verification

- **Pagination was not reached.** The app was launched with paginated history, but no older-page loading boundary was crossed; prepend anchoring, duplicate rows, and page-transition stability remain unverified.
- Scroll-away followed by jump-bottom was verified after expanding activity, but not after pagination or a long uninterrupted history scrub.
- Landscape without the software keyboard, long reference-document selection, rich attachments, streaming transitions, and real provider flows were outside these completed steps.
- This simulator session supplies no physical-device 60/120 Hz, accessibility-service, or timing evidence.

On resumption, the existing session returned `Session not found. It may have already been closed, or the identifier is wrong`; see [session-revalidation.json](session-revalidation.json). No session was created, restarted, or ended by this subtask. Consequently the remaining steps and any landscape fix need a new parent-owned run.

## Retest A — compact-height editor only

The parent subsequently supplied a new running session, `Beta Landscape Fix QA`, process 13140, built from the working tree with `DraftPromptEditor` restricted to one visible text line in compact vertical size class. This retest did **not** include the later jump-button fitting change or large comment-sheet detent. The synthetic fixture and device were unchanged. No app code or build configuration was modified by this subtask.

- **Draft retention passed.** Entered `Offline QA draft`, `Second line café`, and `Third line 日本語` as three lines. In landscape the focused line remained visible in a one-line editor; returning to portrait restored all three lines exactly. [16 screenshot](16-compact-portrait-restores-draft.png), [hierarchy](16-compact-portrait-restores-draft-hierarchy.txt).
- **Send keyboard clearance improved without annotations.** In settled landscape, Send was y=125.3..161.3 and the keyboard started at y=178. However, the jump button at y=21..59 directly overlaid the navigation title, and the composer region still began at y=75 against a navigation bottom of 78. This is a failed complete-layout check. [15 screenshot](15-compact-landscape-jump-overlap.png), [hierarchy](15-compact-landscape-jump-overlap-hierarchy.txt).
- **Comment sheet note visibility failed after rotation and an existing multiline draft.** Returned to portrait, selected `block` from upper assistant prose, opened Comment, and typed `Landscape annotation café`. The sheet initially appeared large, but settled at its medium position after typing while the keyboard remained open. The Comment TextView was at y=551.1 with height 7.7; the keyboard input view began at y=546. The note was completely hidden. An empty recapture gave the same result. Add still created a pending chip. [17 screenshot](17-comment-hidden-by-keyboard.png), [hierarchy](17-comment-hidden-by-keyboard-hierarchy.txt).
- **Landscape with a pending annotation still failed.** Focused the existing three-line prompt and rotated again. The `block` chip occupied y=60.7..89, overlapping the navigation bar at y=24..78. Jump-to-bottom was y=-1.3..36.7. Send was y=147.3..183.3, with the bottom 5.3 points behind the keyboard starting at y=178. A second settled capture confirmed this. [18 screenshot](18-compact-landscape-annotation-overflow.png), [hierarchy](18-compact-landscape-annotation-overflow-hierarchy.txt).

Interactions were paused at this point for the parent to install the additional fixes. Pagination remains unverified. This retest is evidence of residual defects, not a final pass of the newer pending source changes.

## Final layout changes — runtime verification pending

The parent reported a later installation containing a compact horizontal composer (`AnyLayout`), the one-line compact editor, a jump-button `ViewThatFits` fallback, and a large Comment sheet. **These changes have not been verified by this subtask.**

On the final resumption, calling `DeviceInteractionSynthesize` failed because the tool was no longer callable, and the enabled tool inventory contained no device-interaction tool. The parent separately confirmed that the Xcode runtime was disconnected and no Xcode, Simulator, or app process was running. This is an environment interruption, not evidence of a passing or failing final layout.

No session was restarted or app built by this subtask. Final checks still required: landscape Prompt/Send/Back and pending annotation clearance; jump control placement or appropriate hiding; large Comment sheet note visibility with a long quote and software keyboard; portrait draft restoration; and an actual pagination boundary with anchor and duplicate-row observation. The earlier captures remain valid only for their explicitly identified pre-fix versions.

## Retest B — final horizontal composer and large Comment sheet

The parent supplied the current build in a new session, `Beta Final Layout QA`, on iPhone 17 Pro / **iOS 27 only**, device `8D313546-861F-484C-B6BF-E2AA8B2DEF2A`, process 41701. It included the compact horizontal composer, one-line compact editor, jump-button fitting fallback, and large Comment sheet. This does not verify iOS 18.6 support.

- **Landscape draft layout passed visually.** The prior three-line draft was restored by the app. Typed `— final ✅` into the second line, leaving the three lines `Offline QA draft`, `Second line café— final ✅`, and `Third line 日本語`. Rotated with the software keyboard visible. The horizontal Prompt occupied y=123..165, Send y=122..158, keyboard began y=178, and navigation occupied y=24..78. Prompt, Send, title, and Back had no visual overlap. A settled recapture matched. [19 screenshot](19-final-landscape-draft.png), [hierarchy](19-final-landscape-draft-hierarchy.txt). The jump control was not visibly drawn over the title; AX still exposed a jump Button at x=62, y=103, so accessibility activation of the hidden fallback is not proven here.
- **Portrait draft restoration passed.** Rotation back restored all three lines including café, 日本語, and ✅. [20 screenshot](20-final-portrait-draft-restored.png), [hierarchy](20-final-portrait-draft-restored-hierarchy.txt).
- **Comment note visibility after typing passed.** Selected `block` in upper prose and opened Comment. Typed `Final comment café 日本語 ✅` and `Second note line remains visible.` as two lines. The sheet remained large after typing and a settled recapture. Its editor occupied y=224.7..530, above the keyboard beginning at 546; both lines and Add/Cancel were readable. This resolves the reproduced short-quote scenario from capture17. [21 screenshot](21-final-comment-note-visible.png), [hierarchy](21-final-comment-note-visible-hierarchy.txt). Long-quote overflow was not exercised.
- **Pending annotation in landscape passed without keyboard.** Added the note, focused the existing draft, and rotated to landscape. The keyboard was absent in the resulting capture. The `block` chip, prompt, and Send shared the horizontal composer; navigation and content were readable. [22 screenshot](22-final-landscape-annotation-no-keyboard.png), [hierarchy](22-final-landscape-annotation-no-keyboard-hierarchy.txt). **This is not a pass for annotation-plus-keyboard clearance.**

Before the final keyboard-clearance capture, the Xcode device-interaction tool became unavailable again (`DeviceInteractionSynthesize is not a function`; no DeviceInteraction tools in the enabled inventory). No further interaction, session restart, build, or send was attempted. The parent was given the handoff immediately. Remaining device checks: pending annotation with the landscape keyboard, long-quote comment editing, actual pagination/anchor/duplicate observation, and iOS 18.6. No benchmark timing claim is made by any screenshot in this report.
