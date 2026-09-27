# Completion and composer QA — September 27, 2026

Two completion defects were reproduced and fixed on top of `9b21281`.

1. Refreshing a skill catalog could retain the same skill path/ID while changing its name. A delayed selection of the old menu row inserted the obsolete name. The model now requires the complete selected match to remain in the current results. The regression fails before the fix with `$old ` instead of rejecting the stale choice, then passes while allowing `$new `.
2. Accepting a command with no trailing space reopened its completion menu immediately. The actual hosted text field reported `/review` with cursor 1 before reporting cursor 7; the first update cleared the old suppression. Accepted completion text now stays suppressed across cursor updates until the text changes. Explicit file-completion presentation resets suppression. Escape retains its previous text-and-cursor dismissal semantics. The same keyboard sequence fails before and passes after the fix.

## Validation

- Xcode MCP builds succeed for My Mac and the iOS 18.6 simulator. Final focused runs each pass **14/14**, with no failures, skips or tests not run. These include six new regressions plus eight existing completion, draft and annotation checks. `mac-final.json` and `ios18-final.json` contain exact test identities and result paths; compressed summaries/console logs are retained locally.
- Deliberately out-of-order file-search responses retain the newest results. Replies/errors after scope changes, dismissal or task cancellation cannot replace current results. Indexing/failure retry recovers. Search requests preserve the correct working directory/thread, limit and complete Unicode character boundaries under the 256-byte query limit.
- Static commands/skills check filtering, enabled capability gating, selection wrapping, command spacing, dismissal, cursor requests and stale catalog choices. Existing Unicode suffix/selection-index checks pass.
- Existing draft checks verify persistence, sending a snapshot before provider startup, failure retention and preserving new text/annotations entered during a successful pending send.
- `keyboard-controls.swift` runs through Xcode MCP in the production `PromptComposer.swift` context. It hosts the real `PromptComposer` and `PromptCompletionView`, assigns the native editor first responder, and sends `NSEvent` key-down events through its window. Actual Down/Up/Return/Tab/Escape routing, native multiline Unicode replacement and draft-to-chat focus release pass. Completion insertion never calls Send. `after-controls.json` contains the final PASS marker.

The final model-source hash and evidence hashes are in `manifest.json`. Build logs are compressed alongside this report. `mac-before.json` is the failing catalog regression; `before-reopened-menu.json` and `before-cursor-trace.json` show the independently discovered menu-reopen failure. Temporary cursor logging used to identify the latter was removed before final validation.

## Limits and incomplete harness attempts

These are focused checks, not production clearance. The keyboard window was not the OS key window; its native first responder was assigned explicitly. They verify SwiftUI's handled completion keys and the real editor's insertion path, but do not establish default app focus acquisition, ordinary Return/Shift+Return behavior, physical typing, mouse selection or VoiceOver behavior.

Attempts to assert a newline from ordinary Shift+Return produced no edit in the inactive window, even after explicitly requesting window activation. Direct field-editor routing bypassed the SwiftUI completion handler. Those attempts remain in `attempt-plain-return.json`, `attempt-key-window.json` and `attempt-direct-responder*.json`, with their source in `keyboard-return-attempt.swift`; they are excluded from passes and do not justify changing Send semantics. Initial snippet attempts also failed because a local type could not use an extension macro, focus was absent, or focusing selected the whole token. Their results are preserved. A snippet can return partial console output without reporting a thrown assertion as a tool error, so only the explicit final PASS marker counts.

iOS software-keyboard/rotation/long-comment layout, provider/workspace changes through rendered controls, physical devices and the remaining release checklist stay open. No provider request, deployment, generated-model change or deployment-target change was made for this checkpoint.
