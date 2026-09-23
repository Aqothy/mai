# Codex history compatibility — September 23

Production source: `f46c590ac19ce78614ebf3f28bd8cd3a195ee0a5`. This pass adds two Go test files and changes no production behavior. macOS 27 / Go 1.26.5; exact versions and executable hashes are in `results.json`.

| Runtime | Scoped pagination | Actual adapter listing | Resume/replay |
| --- | --- | --- | --- |
| Bundled Codex 0.155.0-alpha.9.2 | Two disposable sessions over two one-item pages, identical order to the adapter's scoped result | 737 unique sessions, crossing its 100-item page boundary | Two completed image turns, exact text/image bytes/replies |
| Custom Codex 0.147.0 | Same result | Same 737 unique sessions | Same history created by the newer runtime, using the supported `gpt-5.6-sol` selection |
| Bundled after custom resume | Same result | Same 737 unique sessions | Same history remains intact after switching back to `gpt-5.6-luna` |

`TestLiveHistoryPagination` drives the actual adapter and real native runtimes. It separately reads the controlled workspace one item per page and compares the complete ordered list. The account-wide list exercises the adapter's actual 100-item page size; only counts and uniqueness are logged, without personal session metadata. These checks establish native **session-list pagination**, not paginated turns inside an enormous conversation.

The only resumed history is the disposable two-turn image chat from `../attachments-20260922/`. `fixture.json` records its native ID, working directory and exact expected content. The test sends no new model turn, deletes no history and does not resume personal chats. The custom-runtime resume changes the fixture's effective model; the final bundled run changes it back. All instances are closed by test cleanup.

## Compatibility limitations retained

The custom 0.147.0 runtime reports a models-cache decoding error (`supports_parallel_tool_calls` missing), warnings about unsupported plugin-hook shape, and the expected model-change warning. Listing and replay still complete correctly. The final bundled run passes without those warnings. This is not a clean bill of health for every older-runtime plugin/configuration combination, nor evidence to downgrade valuable history. No user configuration was edited and no global cache was manually removed; normal runtime cache behavior was not instrumented.

The existing earlier custom-runtime smoke evidence covers a real `gpt-5.6-sol` response; this pass intentionally verifies history without generating more messages. It does not overturn the earlier explicit failure when that old runtime was asked to use the user's newer default model.

## Failure behavior and checks

`TestHistoryListingRejectsIncompleteResults` supplies a successful first page followed by each of five faults: repeated cursor, unsupported operation, expired authentication, malformed page and EOF. Every case retains a visible error, returns no partial success and issues no retry. Unsupported operations fail explicitly here; neither installed runtime needed an alternate listing API. This test covers `ListSessions`, not every history-reading or registry-update path.

The complete Codex adapter package passes with the race detector: **39 top-level tests pass**, zero failures. The two opt-in live tests are deliberately skipped in that offline package run; the new live-history test passes in all three explicit runtime runs above. `go vet ./internal/adapters/codexapp` succeeds. Raw logs are retained, including all custom-runtime warnings.

## Reproduction

Run `go test ./internal/adapters/codexapp -run '^TestLiveHistoryPagination$' -count=1 -v` with `CODEX_LIVE_TEST=1`, `CODEX_HISTORY_QA_FIXTURE` pointing to a disposable fixture, `CODEX_LIVE_BINARY` selecting the exact executable, and `CODEX_LIVE_MODEL` selecting its supported model. Opt into account-wide read-only listing separately with `CODEX_HISTORY_LIST_ALL=1`; that check requires more than 100 existing sessions and does not create sessions to reach the threshold. The controlled fixture's workspace must have at least two native sessions to exercise one-item pagination.

For offline fault coverage, run `go test -race ./internal/adapters/codexapp -count=1` without live environment variables. The test fixture is machine-local history: recreate it through the documented live attachment workflow if its native session no longer exists. The committed test does not fabricate passing history.

Remaining provider scope includes registry install/update/pin transitions, broader migration/downgrade recovery, huge per-thread history, multi-part reasoning through rendered completion/reload, and remaining ACP workflows. This report does not clear the overall release gate.
