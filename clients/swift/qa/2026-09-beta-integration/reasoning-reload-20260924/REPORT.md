# Reasoning stream/reload consistency — September 24

Base: `076161b`. The production change is seven lines in the Codex history converter; no Swift, generated-model or project changes are needed. `manifest.json` records the source patch, environment and corrected daemon hash.

## Defect and correction

Two adjacent reasoning items stayed separate in the live timeline but concatenated during history replay. The history converter emitted their text without the `item/completed` boundary used by live streaming. That removed a row, joined text without a separator and changed the IDs of subsequent thought rows. The new adapter-to-orchestration regression reproduces this failure in `before-fix.log`.

Replay now emits the same authoritative completion after each reasoning item. The existing event-order assertion includes that boundary. The regression now preserves five ordered entries with stable identities: two adjacent thoughts, a tool, another thought and an assistant reply.

The scripted scenario checks two summary parts, two content parts, Unicode and split Markdown; an item recovered entirely from its completed snapshot; and a completed snapshot that replaces different live text. The production 50 ms ingestion loop delivers intermediate thought updates. The test waits for exact text/status at each checkpoint and compares both the completed live projection and history replay with an explicit expected timeline.

## Validation

- Full backend suite: **506 top-level tests pass**, 14 packages, zero failures. Five opt-in tests are skipped: Claude live smoke (excluded by the user), Codex live smoke/history, local npm lifecycle and API example capture. The history check is separately enabled below; prior reports retain the other scoped evidence.
- Adapter and orchestration packages with race detection: **175 top-level tests pass**, zero failures. Two Codex live tests are opt-in skips in this run. Static analysis for both packages passes.
- Xcode MCP snippets on **macOS 27** and **iOS 18.6** decode the actual server events in `pipeline.json` through the shipped models and `ThreadSession` reducer. Both pass 11 events, three live thought checkpoints, three authoritative completions, the five-entry timeline, stable identities after reload, duplicate-sequence rejection and cleared activity. The first snippet failed compilation because a local helper lacked `@MainActor`; the corrected snippet passes on both platforms. That harness failure is retained.
- Actual bundled Codex history resume passes using the existing disposable two-turn image chat: two sessions across two one-item pages and exact user text, images and assistant replies. No model turn, Claude request, personal-history import or account-wide listing was performed. This checks ordinary real-runtime history compatibility; it does not claim the image fixture exercised multiple reasoning parts.

`pipeline.json` is synthetic protocol data produced by the actual adapter/ingestion/projection code, not a model's private reasoning. The client fixture asserts the same wire data on both platforms. This is data and lifecycle evidence; it does **not** certify rendered thought/tool frames, scrolling behavior or 120 Hz presentation. Those requirements remain open.

## Reproduction

Run `go test ./internal/adapters/codexapp -run 'TestReasoningLiveAndReloadTimelineAgree|TestReplayEventsPreservesTurnAndItemOrder' -count=1 -v`. Optionally set `MAID_REASONING_QA_OUTPUT` to an output JSON path to export the wire fixture. Substitute its base64 encoding for the quoted `QA_FIXTURE_BASE64` placeholder in `client-pipeline.swift`, then run that snippet through Xcode MCP in `mai/Features/Threads/ThreadSession.swift` on each destination. The recorded fixture contains three coalesced delta events; timer scheduling can split these differently in a new export.

The live history command uses `CODEX_LIVE_TEST=1`, `CODEX_HISTORY_QA_FIXTURE` pointing to `../history-20260923/fixture.json`, `CODEX_LIVE_BINARY=/Applications/ChatGPT.app/Contents/Resources/codex`, `CODEX_LIVE_MODEL=gpt-5.6-luna` and `go test ./internal/adapters/codexapp -run '^TestLiveHistoryPagination$' -count=1 -v`.

The release gate remains open. Final archives must be refreshed after the outstanding fixes/QA and paired with the current daemon.
