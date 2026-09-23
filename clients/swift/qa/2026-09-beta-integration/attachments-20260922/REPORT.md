# Attachment QA — September 22–23

Source: `93d14ff52c3f389103c5518177b104df9dddd427` plus `source.patch`. macOS 27, Xcode 27. `metadata.json` records the patch and built code hashes. This pass uses disposable fixtures and real Codex; no Claude turns or valuable user chats were used.

## Fixed fallback layout

The actual attachment component rendered an invalid image's message as **“Image…”**, even in a 640-point window. Its content-sized stack and aspect ratio compressed the label. The background now owns the available card width, with padded text allowed to wrap vertically. The existing filename and accessibility label/value are preserved. No streaming effect or preview feature was added.

`before/03-invalid-same-view.png` shows the failure; `after/03-invalid-same-view.png` shows the readable result. Light/dark, a 240-point component window and a 375-point two-image grid are captured. The component pixel assertions checked image identity, not label readability; the original assertion run passed while visual inspection found the truncated label.

Xcode previews verify the complete label at accessibility text sizes AX3 in light appearance and AX5 in dark/increased contrast, at a deliberately narrow 160-point card width. The word wraps with hyphenation, without clipping. Xcode selected **iPhone 18 Pro / iOS 27.0** for these previews even though the active build destination was iOS 18.6. These are not iOS 18.6 preview or physical-device results. The macOS Dynamic Type override did not increase the font, so its captures do not establish Mac large-text scaling.

## Completed checks

| Path | Evidence and result |
| --- | --- |
| Same mounted attachment view | Red → blue → invalid → oversized encoded payload → red, using the colliding PNG fixtures from `../image-reuse/`. No old-color pixels survive replacement or failure. This exercises the actual asynchronous view task and confirms the earlier image-identity fix. |
| Missing/remote/unsupported inline content | Missing image and unsupported audio retain filename labels; a remote image URI retains a link label. The product does not fetch remote image URIs into inline thumbnails. |
| Composer file pipeline | Nine inputs admit eight and report one limit error; removing one during processing leaves seven ready attachments, with no resurrection. Original PNG bytes and MIME type are preserved. Empty/invalid files fail and leave no pending card. An unsupported provider rejects the attachment. |
| Actual byte boundaries | A decodable PNG padded to exactly 10 MiB uploads unchanged and decodes in the transcript. At 10 MiB + 1, the composer gives the size-limit error and the transcript rejects decoded bytes. A decodable PNG named `.txt` fails the file-type gate. All three first pass thumbnail decoding; these checks do not accidentally exercise only the invalid-image path. |
| Live image-only prompt | The real composer loader, Swift RPC, daemon and Codex accept an empty-text red-image message. The stored user text stays empty and its attachment bytes stay exact. Codex replies, “What would you like me to do with this image?” |
| Live text + image prompt | The real Swift store sends the prompt with the blue image; exact text/bytes survive, and Codex replies exactly `blue`. |
| Actual native and List windows | The completed live chat is opened separately in each renderer. Both window screenshots contain 275,520 red and 705,600 blue fixture pixels, excluding the bubble background. Visual inspection confirms image/filename/reply placement with no overlap in these settled frames. |

The first component oversized-file fixture was invalid zero-filled data. It proved rejection, not the intended size boundary. `attachment-limits.swift` and `limits/results.json` supply the corrected decodable-fixture evidence. Padding a tiny PNG checks file-size policy; it does not simulate a high-resolution photograph or memory pressure.

The live daemon executable hash is `5fc07b1f15907588e7418094c961f6156697f34cf09cdcb6864c94120eaf4390`; Codex is `0.155.0-alpha.9.2`, model `gpt-5.6-luna`, low reasoning. The temporary provider uses read-only/on-request settings. Exact runtime, endpoint, isolated workspace and cleanup are recorded in `live/live-attachments-b-*.json`. The owned daemon exited normally after the checks. No auth files or database are committed.

## Tooling failures and capture limits

- The first temporary daemon reached its 20-minute hold limit before a snippet ran; it exited cleanly. That setup failure is retained under `tooling/`.
- The first live snippet was cancelled shortly after its dispatch reached the daemon, then Xcode timed out after 200 seconds. It is not a completed image-only test. Running the work in an explicitly owned task allowed the subsequent two real turns to finish.
- `NSView.cacheDisplay` was unsuitable as full-chat evidence: the List image was absent, materials were missing, and native text could appear over an image. The second snippet therefore records a capture failure despite successful provider assertions. No product fix was made based on those artifacts.
- The final check captures each owned **actual window** by its reported window number with `screencapture -x -o -l`, after a three-second settling interval. These images supersede the full-chat bitmap captures. This is settled rendering evidence, not every streaming/display frame. `live/window-image-validation.json` contains pixel assertions; `live/*-geometry.json.gz` records view geometry.
- A first analysis invocation used the system Python without Pillow and stopped before producing results. The bundled image-analysis runtime produced the saved validation.

## Builds and reproduction

Both Xcode MCP builds succeed: My Mac and the **mai QA iOS 18.6** simulator destination. GetBuildLog reports no compiler issues. The raw logs retain Xcode's benign “Metadata extraction skipped, no AppIntents.framework dependency found” warning. Logs and preview metadata are in `builds/`; the active destination was restored to My Mac. No project, deployment target or generated files changed in this pass.

Run the component/limit snippets with Xcode RunCodeSnippet in `ComposerAttachments.swift` on My Mac, substituting a fresh app-container `QA_OUTPUT` directory. Copy the two committed PNG fixtures there. The component harness additionally needs invalid/empty PNG files, a text file and an oversized invalid PNG; the separate boundary harness needs copies of the red PNG padded with zero bytes to exactly 10 MiB and 10 MiB + 1, plus the original PNG saved as `disguised.txt`. Preserve file names used by the snippets.

For live reproduction, use `../workflows-20260922/check-provider.mjs` in client mode with the corrected daemon. Copy its `ready.json` and PNG fixtures into the container directory. The exact successful-provider/failed-offscreen-capture attempt is retained in `tooling/live-attempt-snippet.swift`; it uses the setup/helpers from `../workflows-20260922/client-workflows.swift`. Then run `render-live-attachments.swift` with that directory and the completed `SOURCE_THREAD_ID`. When each renderer writes its `*-ready.json`, capture only that window and create the corresponding `*-captured` marker. Do not substitute offscreen cache bitmaps for actual window screenshots.

Still open: assistant/tool attachment integrations, remote tool detail loading and URL actions, picker/permission recovery, VoiceOver interaction, mobile attachment runtime/device checks, and streaming image-height transitions. The current inline image card has no tap-to-open preview or copy-image action; those nonexistent actions are not required as release regressions. Existing supported URL/copy/detail actions remain on the release checklist. This pass does not clear the app for production.
