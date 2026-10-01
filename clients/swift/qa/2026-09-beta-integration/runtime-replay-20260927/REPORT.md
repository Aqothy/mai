# Timestamp and provider replay QA — September 27–29, 2026

The actual iOS 18.6 runner exposed a date-decoding defect hidden by the historical preview-host checks. The captured daemon snapshots contain fractional RFC 3339 timestamps, for example `2026-09-24T00:26:41.437657-04:00`. Foundation's built-in JSON `.iso8601` strategy rejects these on iOS 18.6. This affected RPC responses, chat notifications and terminal-list notifications.

The shared `WireJSON` decoder now accepts timestamps with or without fractions and reports malformed fields as decoding errors. RPC responses, terminal notifications and `ThreadStore` notifications use it. Session import uses the same parser, preserving its existing optional-date behavior. Encoding is unchanged. Both date format styles are necessary on older runtimes; see [Apple's fractional-second parsing documentation](https://developer.apple.com/documentation/foundation/date/iso8601formatstyle/includingfractionalseconds).

**The generated convenience decoder remains unfixed pending regeneration approval.** The prepared generator change and `generated-date-decoder-proposed.patch` replace only `newJSONDecoder()`'s body with the shared factory. The proposal was generated in a separate temporary directory and compared against all three generated files; only that helper differs. The source model was not edited. The two older-runtime replay failures below remain release blockers, not waived tests.

## Evidence

All runtime claims below come from the test runner's actual `.xcresult` device/configuration metadata, preserved as `*-runtime.json`. Every successful run has zero failures/skips/expected failures. This is simulator and macOS evidence, not a physical-device performance claim.

| Check | Runtime | Result | Evidence |
|---|---|---|---|
| Original full activity, reasoning and annotation replays | iOS 18.6 / 22G86 | Activity passes; reasoning and annotation fail while decoding dates | `ios18-results.json` |
| Fraction/whole-second parsing, UTC and offsets, malformed values, existing encoder | iOS 18.6 / 22G86 | 4 pass | `ios18-date-parser-results.json` |
| Actual `RPCClient` WebSocket response and two terminal-list notifications | iOS 18.6 / 22G86 | 1 passes; fraction and whole-second updates both delivered | `ios18-transport-results.json` |
| Three full replays, four parser checks and actual WebSocket transport | macOS 27.0 | 8 pass | `mac-results.json` |
| Chat/sidebar notification regression before shared factory | iOS 18.6 / 22G86 | Fails: both updates rejected | `ios18-notifications-before.json` |
| Notification check after factory change, initial exact `Date` equality assertion | iOS 18.6 / 22G86 | Updates apply; equality fails on sub-microsecond epoch-conversion rounding | `ios18-notifications-exact-date-assertion.json` |
| All 28 `ThreadStoreTests` plus four decoder tests | iOS 18.6 / 22G86 and macOS 27.0 | 32 pass on each | `ios18-store-regressions.json`, `mac-store-regressions.json` |

The date assertions compare Unix seconds within one microsecond. They cover whole seconds and 1/3/6/9-digit fractions with UTC, negative and positive offsets; accepting nine fractional digits does not claim nanosecond precision from `Date`. The chat regression checks actual accepted snapshot/sidebar updates and exact titles, alongside the timestamp accuracy. Reconnect, hidden-chat observation, streaming, cache eviction, drafts, completions and annotation regressions remain green.

The complete activity replay checks two exact completed thoughts, twelve tool updates, the exact 20,000-character reply, completed turn state, five unique new entries and preserved earlier history IDs. The reasoning fixture checks every live thought checkpoint, authoritative completions, duplicate-sequence rejection and exact live/reloaded timeline identity. Annotation expectations are now extracted independently from raw JSON, so uniformly dropping optional notes/references in the model decoder cannot pass. Neither replay changes or rounds the captured timestamps.

`source-checkpoint.json` identifies the base commit, final source hashes and successful Xcode MCP build logs. The final regression source follows the eight-case Mac run only by adding the chat-notification regression and changing `ThreadStore` to the shared factory. The generated file hash is unchanged. Console/summary text is compressed beside each result. One build immediately after removing the temporary transport harness saw Xcode's stale file inventory; refreshing the test list and rebuilding succeeded. No project-file edits or skipped tests were used to recover.

## Reproduction and remaining work

`WireJSONTests` and `ThreadStoreTests/fractionalDateNotificationsUpdateChatAndSidebar()` are self-contained. The three `ChatProviderReplayTests` use compressed captures preserved in `ChatProviderReplayFixtures`; they deliberately retain the generated decoder and currently reproduce its two iOS 18.6 failures.

For transport checks, run `date-wire-server.go` from the repository root with `reasoning-reload-20260924/pipeline.json` as its argument. It binds only to loopback and prints a free endpoint. Copy `WireTransportRuntimeQA.swift` into the test target, replace `QA_ENDPOINT` with that endpoint, and build/discover/run through Xcode MCP. The temporary target copy was removed after both-platform checks; the local server was stopped. This harness sends captured/synthetic data and does not use a provider account or production daemon.

After approval, regenerate through the prepared generator, verify the output matches the proposed one-helper diff, and repeat all three replays plus the decoder/notification regressions on iOS 18.6 and Mac. Verify actual runtime metadata again. Keep the release gate open until those runs pass. The wider release checklist, physical 60/120 Hz checks and current distribution archives remain separate requirements.
