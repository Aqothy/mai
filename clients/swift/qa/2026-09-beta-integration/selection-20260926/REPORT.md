# Native selection, reference and copy QA — September 26, 2026

Seven distinct macOS checks and two iOS 18.6 checks pass through Xcode MCP. This pass adds regression tests and makes no production changes. The base is `73866d1`; the accompanying test sources contain the exact fixtures. Both app/test builds succeed with no reported build errors.

## Verified behavior

- Forty parser-resolved reference messages go through the actual native transcript virtual document, scroll view, prepared rows and reusable host pool. Jumps to rows 20, 35, 5, 28 and 0 reuse hosts without leaking selection. The mounted host count stays below the full message count.
- Rendered `Guide` links have the correct per-message URL. Comment actions capture exact Unicode quotes, original assistant message IDs and the correct annotation model. A menu retained before recycling cannot comment on its old row. Switching to another chat model with the same message ID/content rejects the old menu and accepts a newly created one.
- Actual text-view copy and code/table button actions write exact Unicode/plain-source/tab-separated clipboard contents. The test snapshots the prior clipboard in memory and restores it only while it still owns the clipboard change count. No clipboard backup is written to evidence.
- Wide code and tables scroll horizontally. Reusing the code body resets horizontal position and selection. Both light and dark prepared syntax attributes match the text view after standard font fixing. Copy feedback resets and cannot leak into a later prose row; old table accessibility content and the copy button are cleared.
- Reference rows retain attachments only on the final split row, which correctly avoids the text-only native host. Annotations retain the complete message/document path. iOS 18.6 preserves its complete standard message, reference source and attachment metadata. These assertions do not certify attachment pixels or link-opening gestures.

## Failures and their resolution

The original `native-actions.swift` snippet timed out after 180 seconds. A sample showed its main thread in the normal app event loop, not a blocked clipboard action; the cause of the snippet timeout is unproven. That attempt is excluded from passing evidence. The same action scenario runs as an app-hosted regression test.

The first clipboard test failed because it compared the unmodified prepared font against TextKit's CJK fallback font at the Chinese characters `保持`. The diagnostic log shows the same syntax color and paragraph style, with PingFang substituted for the Latin monospace font. Apple's documented [font fixing](https://developer.apple.com/documentation/foundation/nsmutableattributedstring/fixfontattribute%28in%3A%29) performs this substitution. Applying that operation to the expected string makes the full attributed-string comparison pass; no attributes are omitted from comparison. The highlighter's `hljs-operator` missing-style warning is retained; the exact copy and rendered/prepared comparison pass despite it.

## Evidence and limits

`manifest.json` records original paths and hashes. `mac-selection-*` contains five passing selection/reference/reuse tests. `mac-initial-console.txt` contains the passing attachment test and the initial clipboard failure. `mac-font-diagnostic-console.txt` identifies the fallback font. `mac-clipboard-*` contains the final passing copy test; `ios-*` contains both passing shared reference tests.

Actions use real AppKit controls, text storage and the system clipboard, driven programmatically. This is not a pointer/trackpad gesture test, an app-wide VoiceOver pass, a screenshot comparison, an iOS physical-device measurement, or evidence of every presented frame. Outer-transcript position during horizontal gestures and annotation persistence through native provider reload/fork remain separate release checks.
