# Thought, tool and reply recordings — September 27

Four complete recordings now exercise the previously uncaptured activity sequence through the actual native and List windows. All four preserve the exact thought/tool/reply source, complete the turn, and keep the bottom working-row star at one position in every matched recorded frame. No split update was identified in the inspected candidate frames. This is bounded capture evidence, not a guarantee about missing display frames, every disclosure interaction, or sustained 120 fps.

## Build and scenario

Base commit `a3ae542`, plus the two benchmark-only changes in `final-source.patch.gz`. The final macOS code image is `b346570400909e9f1c9afa9df9630f6bdd0513b6fe64357a8181679b9bac8ac1`. Xcode MCP builds pass on My Mac and the iOS 18.6 destination; build logs are retained. The active destination was restored to My Mac. No deployment target, generated model, project setting, production renderer, animation, or provider configuration changes in this pass.

The daemon-free Debug fixture uses 20 synthetic history turns, a 6,000-character thought, 12 tool updates, a 1,600-character second thought and a 20,000-character answer. It exercises the production reducer, live buffers, automatically expanded current thought, completion/collapse, tool status, answer growth and final settled rendering. No live provider or user conversation participates. The tool row is synthetic; it does not execute its displayed command.

Window: 1280×900 points, sidebar 280 points, 760-point transcript and composer. macOS 27 (26A428), Mac14,9, built-in display advertising 120 Hz. Each renderer runs in a fresh app process, with the same fixture. Recording uses the existing cropped AVFoundation harness without audio. The recording is stopped before the owned app. FFmpeg's intentional SIGINT stop returns 255; each completed movie is subsequently decoded/probed successfully.

## Observations

| Fixture / renderer | Recorded frames | Consecutive matched working-row frames | Star template top | Capture rate | Largest capture gap |
| --- | ---: | ---: | ---: | ---: | ---: |
| Repeated / native | 2,926 | 2,730 | y=750 only | 79.74/s | 167.50 ms |
| Repeated / List | 3,017 | 2,778 | y=750 only | 78.15/s | 156.33 ms |
| Numbered / native | 2,935 | 2,682 | y=750 only | 78.41/s | 134.00 ms |
| Numbered / List | 3,094 | 2,857 | y=750 only | 79.18/s | 122.83 ms |

`analyze-activity.py` decodes every recorded frame in timestamp order and searches for the visually verified fixed star at x=398–413 across y=50–789. The reference includes its surrounding background; the match threshold is mean absolute error below 3/255. The symbol itself occupies approximately y=753–761. Every capture has zero unmatched frames between the first and last match and no second matched vertical position. The indicator disappears after completion. This tracks the working-row symbol; it does not independently measure every letter of its phrase or the activity group's scrolling `Working` header. The latter belongs above the activity items and moves with the transcript.

The sampled full frames show the composer and content centered in the detail pane, with no content behind the sidebar in this configuration. Current thoughts wrap and grow above the bottom working row. The numbered fixture distinguishes sections that otherwise look identical, making an old/new tile displacement easier to see. Sections, Unicode, incomplete inline delimiters, code and prose remain legible in the inspected views. The short literal incomplete Markdown tail is expected until its delimiter arrives.

The left/right motion heuristic flagged 15 native and 28 List frames with repeated paragraphs. All 43 candidate frames were visually reviewed in the retained overview sheets; they show coherent text rather than the vertical split in the user's screenshot. Repeated text and sparse right-hand text can make inferred motion ambiguous. The numbered fixture reduced the candidates to four native frames (1163, 1196, 2393, 2454) and two List frames (2500, 2567). Every one of those six candidates and its immediate predecessor/successor was inspected. Their full three-frame strips are retained. They show coherent movement from thought collapse, answer growth and list wrapping, with no visible old/new-content seam.

The heuristic remains a candidate generator. It cannot certify every pixel, and it does not eliminate the missed display frames. Automatic thought completion/collapse is covered here; clicking disclosures while scrolling, resizing and switching chats remains separate QA. These captures add thought/tool evidence to the September 22 assistant-only check and its independently reproduced/fixed List completion jump. They do not reproduce a new production rendering defect.

## Recording setup repair and exclusions

Before the successful captures, one launch produced no benchmark output and timed out. A scoped process sample showed an idle AppKit event loop, not a rendering hang. Bringing the owned app into view produced a fullscreen window; fixed-size setup then failed. A normal-window attempt subsequently reported the requested 1280×900 AppKit frame while the exact WindowServer window still reported 1512×948. The recorder correctly rejected the mismatch.

The benchmark now requires the exact window to be on screen, visible in the active Space, outside fullscreen, with WindowServer dimensions agreeing with AppKit for 750 ms before it emits the ready marker. The query runs only during setup, outside measured scrolling. Apple's public [window-information API](https://developer.apple.com/documentation/coregraphics/cgwindowlistcopywindowinfo(_:_:)) supplies those dimensions. The existing recorder still independently verifies the exact window. The successful repeated captures use the intermediate code image `0d7179a2c59e06122af1f37ab07cd2058f0eb3884392784c4b67cd47d504a4cf`, identified by `viewport-source.patch.gz`; the numbered captures add only distinct section text.

The first numbered List recording lost visible occlusion state during streaming and was rejected. Its partial movie is excluded from results and is not committed. A fresh run with the identical final build completed successfully. The failed setup/visibility logs and metadata are retained under `failed-attempts/`, including empty outputs and the launch sample. No failed run contributes a performance or visual pass.

Computer use was limited to activating the prepared QA windows and taking the diagnostic window out of fullscreen. Streaming, capture, source checks, extraction and numerical analysis were scripted. App activation was needed when the scripted launch did not present its window; no product UI test depends on a simulated click here.

## Evidence and limits

`manifest.json` links source hashes, original paths, binary/movie hashes and losslessly preserved evidence. Each successful capture folder contains source-validation logs, metadata, all frame timestamps, every frame's analysis, the star positions, a full reference frame and candidate review images. Movies remain outside Git at the recorded local cache paths. No foreground capture from a rejected/obscured movie is copied into this report.

Run `record-chat-stream.py ... --activity --container custom` and again with `--container list`. After completion, extract the frame at five seconds with FFmpeg and visually confirm its star position before running `analyze-activity.py`; use `export-candidates.py` for adjacent-frame strips. NumPy and Pillow are required for analysis. Preserve variable-rate timestamps with `-fps_mode passthrough`.

The requested capture rate was 120 Hz, but the actual rate was about 79 Hz, with the gaps reported above. App callback results from these instrumented runs remain in the logs for provenance and are excluded from uninstrumented FPS comparisons. The observations neither prove a 60 Hz List cap nor justify blanking content or replacing the iOS renderer. Physical-device performance, unseen frames and system screen-sharing-icon flicker remain unverified by this recording method. The broader release checklist remains open.
