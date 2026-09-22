# Composer paste regression

Fix: `267d18b`.

The real Release workflow on `b9a259a` failed before submitting its first Codex prompt: pasting a multiline prompt containing café and 👩🏽‍💻 caused `String index is out of bounds`. The Debug build reproduced the same failure. The stopped stack shows the new selection reaching `PromptComposer.cursorOffset` while its text argument is still empty, during the draft store's observation `willSet`.

The composer now resolves a collapsed selection by matching an actual character boundary in the current text. It never traverses the string using an index from another revision. A temporarily mismatched or non-boundary selection returns nil, which suspends completion until the next matching input update. Ordinary start, middle and end cursors preserve character-based offsets; selections of text still disable completion. The change adds no timers, deferral or animation.

Three new regression cases cover the paste/deletion ordering, every boundary of a Unicode fixture, non-boundary stale indices and selected text. All six related integration tests pass on macOS 27 and iOS 18.6, with no failures, skips or runtime warnings in the actual result bundles. Xcode MCP builds succeed on both platforms. The pre-existing full suites remain scoped to `b9a259a`; they were not repeated for this isolated composer correction.

The exact paste then succeeded in the Debug app under the debugger. The accessibility value preserved every line, accent and emoji. Selecting/deleting the draft and pasting `short 👩🏽‍💻` also succeeded, and the same process remained running. One combined select-all/paste attempt left the old text selected and is not counted as a successful replacement check.

Both new Release archives now pass their local artifact checks. The same multiline prompt succeeds in the unmodified macOS Release app, receives the exact Codex response and clears the composer/working indicator. The real code-copy, replay, import/fork and restart checks also pass. See `../live-release-20260921/REPORT.md` and `../distribution/20260921/REPORT.md`. No live Codex prompt had been submitted by the original crashing workflow. Physical-device validation and presented-frame consistency remain separate open requirements.
