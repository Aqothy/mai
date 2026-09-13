# Beta integration release QA

Branch: `aq/beta-01-08-integration-20260912`. Started 2026-09-12.

This release combines cleanup, native macOS chat performance, beta 01–08, and snapshots of the pending beta worktree edits. The source worktrees are preserved. An unchecked requirement is not a pass. Record exact tested commit, binary hash, platform, provider/runtime version, commands, fixtures and failures. Historical benchmark reports are context, not evidence for this integration.

## Source integrity and build gates

- [x] Verify all eight fetched beta branch tips and all seven pending-worktree snapshots are ancestors of this branch.
- [x] Verify cleanup commit contains no new native transcript, benchmark suite or cursor optimization.
- [x] Review overlapping merges for native rendering, reference links, streaming reveal, rich attachments, annotations, completion and provider lifecycle.
- [x] Build app and test targets through Xcode MCP for macOS and iOS simulator; record warnings.
- [ ] Run macOS and iOS test plans, including reducer/replay, paging, cache cancellation, row sizing/reuse, attachments, annotations, completions, registry and terminal tests. Explain skips and unavailable coverage.
- [x] Run full Go tests, go vet, formatting and race tests for the changed provider/orchestration/daemon/terminal paths.
- [x] Confirm ACP filesystem and terminal client capabilities remain disabled.
- [x] Validate API/wire consistency without hand editing generated files; verify schema tests and committed client models.

## Native transcript and performance

Execute every item in [CHAT_QA_CHECKLIST.md](CHAT_QA_CHECKLIST.md), keeping direct UI observations separate from automated benchmarks.

- [ ] Run native and List scroll, streaming and streaming while scrolling, with three fresh visible launches per configuration and identical content/window/settings. Record average callback frequency, p99 and maximum intervals.
- [ ] Run extreme scrubbing separately and report its stalls.
- [ ] Compare paginated/full-history opening; exercise pagination and resize anchors.
- [ ] Exercise five ordinary and five full rich chats with switching/resizing, retained/peak memory, cancellation and release of presentation resources.
- [ ] Verify the beta reveal effect in prose/quotes/code survives the native renderer and respects Reduce Motion; completed source matches exactly.
- [ ] Verify parser-resolved reference-link rows retain correct links, annotations, attachments and native preparation.
- [ ] Verify selection menus bind comments to the actual message after reuse, scrolling, switching threads and reference-link splitting.

## Providers, persistence and connectivity

- [ ] ACP: create, list/page/import/resume, rename, stop/interrupt, close/delete, unsupported capability handling, additional directories and config options.
- [ ] Codex app-server: login state, model/config selection, new prompt, steering/queue, approvals, fork, retry, history paging and reconnect/replay.
- [ ] Codex reasoning with multiple summary/content parts agrees while streaming, after completion, and after reload; completed snapshots are authoritative.
- [ ] Claude native: authentication, model/permission mode, text/image input, thoughts/tool details, permission approval/denial, interrupt, retry and resume/import using its own binding.
- [ ] Lifecycle: late responses cannot switch providers/threads; malformed/closed RPC and transport loss clear activity or recover explicitly; no duplicate history or lost accepted prompt.
- [ ] Test current bundled and custom/pinned runtimes independently; capture versions and supported older/current Codex history combinations, including narrow unsupported-operation fallback.
- [ ] Registry install/update/delete, pinned/custom executable handling and safe restart preserve active work.
- [ ] Persist/restart/reconnect existing ordinary chats and verify no data loss; use disposable data for destructive operations and migration/downgrade testing.

## Attachments, annotations and composition

- [ ] Image-only, text+image and supported media render in user/assistant/tool rows; unsupported, invalid, oversized and missing payloads show a useful fallback.
- [ ] Open attachment preview and URLs, copy data/text, inspect file changes with attachments and remote tool detail loading; preserve scroll position.
- [ ] Camera/photo/file picker availability and permission descriptions match the built platform; denied permissions recover.
- [ ] Select quote, open Comment, edit/cancel/remove, send annotation-only and mixed prompts; failed send preserves draft; successful send removes only submitted annotations.
- [ ] Queued annotated prompts retain quote/note; steering and fork do not bind them to the wrong message.
- [ ] Completion: @file, /command and $skill triggers, filtering, cursor insertion, Unicode, keyboard up/down/enter/escape, mouse selection, stale-result cancellation and provider capability gating.
- [ ] Enter/Shift+Enter, composer focus, attachment removal, draft persistence, config changes and switching provider/workspace behave correctly.

## Terminal and surrounding app

- [ ] Terminal create/attach, live byte ordering, 5 MiB output, resize, reconnect/snapshot, input gating, relaunch/exit/terminate/delete and switching to/from chat.
- [ ] Terminal agent-state detection, OSC overlength/split sequences and run identity guards.
- [ ] Project folder search/selection, sidebar filters, thread search/import/fork navigation and split-window/fullscreen behavior.
- [ ] Light/dark, Dynamic Type, keyboard-only navigation, VoiceOver labels/actions, copy feedback and no stale accessibility content after row reuse.
- [ ] iOS List opening/pagination/reveal/scroll intent, rotation, keyboard safe areas, attachments and annotations; verify physical 60/120 Hz devices and memory pressure separately from simulator.

## Distribution gate

- [ ] Validate a Release archive for intended production platforms, signing/entitlements, required usage descriptions and minimum OS; test the actual distribution build.
- [ ] Ensure debug benchmarks/synthetic data do not activate in Release and private QA data/secrets are absent from changes.
- [ ] Confirm no unresolved failures or unexplained skipped requirements. Report remaining blockers explicitly before calling this ready for production.

## Execution evidence

In progress; this branch is **not yet cleared for production**. Durable results are in [qa/2026-09-beta-integration](qa/2026-09-beta-integration).

- Cleanup-only commit: `6c37934`. Performance snapshot: `1ea0d32`. Eight fetched beta tips and seven snapshots of their pending edits are ancestors of the integration branch (`ancestry.json`). Original worktrees and the safety stash are preserved.
- Xcode MCP builds for macOS 26.5.2 and iOS 27 simulator succeed. The September 13 builds have no reported compiler warnings. Actual `.xcresult` counts: **120 macOS tests passed**, **116 iOS tests passed**, plus **4 new iOS regression tests passed**. Five additional attachment/prompt regression tests passed independently on **each platform** after the image fix (`412959a`). No failures, skips or runtime warnings in these bundles. The MCP summary incorrectly included cached tests from the other platform; the JSON evidence is extracted directly from each result bundle. These tests cover specific logic; unchecked end-to-end requirements above remain open.
- Full Go test suite, `go vet ./...`, changed Go formatting, configured race tests for adapters/orchestration/providerservice/daemon/terminal, and `make fff-verify` passed. The first race attempt lacked the Ghostty pkg-config path; the configured run passed. Tests explicitly reject unsupported ACP filesystem/terminal requests and omit those client capabilities.
- Real WebSocket daemon API transcript capture passed with its fake ACP runtime. This checks protocol behavior and expected error handling, not live external-provider behavior.
- Codex CLI 0.153.4 from the installed app passed a real prompt, listing, stop/resume with 5 replay events, and independent fork. Custom CLI 0.147.0 passed the same flow with its advertised `gpt-5.6-sol` model; the user-configured `gpt-6-astra` default fails with an explicit upgrade-required response. This compatibility failure is recorded, not suppressed.
- Claude CLI 2.1.258: authentication status was present, but three live turns (including September 13) failed during OAuth refresh with the CLI's concurrent-refresh error. Reauthentication is pending; Claude live QA is not passed.
- Integration repairs preserve beta annotation actions in native text, original message identity after reuse, attachments on resolved rows, streaming code reveal, and platform-safe navigation titles. Reference documents keep their complete selection path on iOS and retain annotation metadata on both platforms. New regression tests cover these boundaries, Unicode completion insertion, annotation removal during sends and bounded reveal batches.

- Schema, method registry and vocabulary regenerated into a temporary directory match all committed JSON byte for byte. An isolated copy of the Swift generator also produced identical `MaidModels.swift`, `MaidRPC.swift` and `MaidVocabulary.swift`.
- Native scroll: three valid launches on code image `4edd466d…aa86` from `f0354e8`, using ordinary Debug settings. Mean callback rates across runs: 119.30 Hz at 1,200 points/s, 119.33 at 3,000, 118.58 at 8,000. Maximum observed interval: 45.62 ms. Display link pacing is not presented FPS. Two List launches completed; the third was rejected for `visible=false` when the Mac locked. The remaining matrix is pending unlock. The exact measured app is preserved at `/tmp/maid-integration-20260912/f0354e8/mai.app` while subsequent unrelated image fixes are tested.
- `412959a` fixes a stale-image collision in the old prefix/suffix/length task identity. Two distinct valid PNG fixtures reproduce the collision (`image-reuse/`); image decoding and annotation-only send/queue failure tests pass. Interactive verification of an in-place image replacement remains pending.

Next: finish visible standalone benchmarks, interactive macOS/iOS/device checks and distribution validation. Historical performance reports are not used as proof for this build.
