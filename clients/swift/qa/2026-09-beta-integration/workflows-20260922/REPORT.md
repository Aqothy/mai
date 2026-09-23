# Codex workflow QA — September 22, 2026

Real Codex approval, queue, annotated steering and interruption checks passed. Crash/retry QA found and fixed a provider-lifecycle defect. These are scripted checks through the real daemon and Swift client store; they do not certify the corresponding menus, accessibility or every rendered frame.

## Crash/retry defect and repair

The original daemon left a Codex turn and its command `running` after its owned app-server process was killed. The Swift client still saw that state 15 seconds later and could not expose Retry. `evidence/client-retry-a/` preserves the process identity, pre-crash snapshot and failed observation.

The adapter now handles closure of the provider transport after its reader finishes. It fails already-started turns on an unexpected disconnect, cancels them on intentional shutdown, clears pending approvals and stops an unusable process. Calls awaiting a start acknowledgement retain their normal dispatch-error path. A late start acknowledgement cannot reactivate a closed connection or a previously completed turn. Process cleanup waits for terminal event delivery.

The same real-provider scenario passes with the fix (`evidence/client-retry-fixed/`):

- Swift observes an error and a settled command after the forced exit.
- Retry uses a fresh turn and rebinds the original user message; its ID and exact text survive, with exactly one user message in the local timeline.
- The real Codex response completes with `RETRIED_OK`; the failed-state action clears.

This checks explicit retry of a read-only timing command. Retrying arbitrary tools with external side effects is outside this scenario.

## Other completed workflows

| Scenario | Observed result | Evidence |
| --- | --- | --- |
| Decline command approval | The disposable file does not exist before or after declining; approval clears and turn completes. | `provider-approval-b` |
| Allow once | The file does not exist before approval and contains exactly `QA_ACCEPTED` afterward; approval clears. | `provider-approval-b` |
| Allow for session | The real runtime accepts the existing UI decision and performs exactly the approved disposable write. This does not test how long permission persists or later commands. | `provider-approval-session` |
| Two queued prompts | Both wait behind a real running command, then run in order as separate turns; message IDs and exact replies match. | `client-workflows-a` |
| Switch chats with queued work | Queue draining leaves the other chat selected and does not send it either prompt. | `client-workflows-a` |
| Annotated steering | A queued prompt steers its original running turn while another chat is selected; message ID, quote, note and referenced message ID survive. The final response is exactly `STEERED`. | `client-workflows-a` |
| Interrupt and continue | An incorrect turn ID is rejected; the correct command/turn stops, then another prompt completes with `AFTER_INTERRUPT`. | `client-workflows-a` |

The installed runtime advertised `accept`, a structured execution-policy amendment and `cancel` in `availableDecisions`. It nevertheless accepted both legacy `decline` and `acceptForSession` decisions in the actual runs. No rejection or execution mismatch was observed; no approval-option change is justified by this evidence alone. Policy-amendment support is not covered here.

## Automated validation

- The new process-exit regression failed on the original source for both unexpected and intentional exit.
- Five lifecycle regressions, including two exit subcases, pass across 30 repetitions: unexpected/intentional exit, pending-approval exit, malformed transport/process cleanup, completed-before-exit, and fast completion.
- Full `go test ./...` and `go vet ./...` pass.
- Race checks pass for Codex adapter, provider service, orchestration and daemon with the repository's Ghostty pkg-config configuration.
- The Swift workflow snippets compile and execute through Xcode MCP in `ThreadStore.swift`'s context on My Mac. They instantiate actual `RPCClient` and `ThreadStore`, and use the same send/queue/steer/interrupt/retry methods as the app. No simulated provider or mock client is used in these live workflows.

The Swift app's product code did not change for this fix. The most recent app builds and rendering evidence remain those of `951a4bf`; the daemon binary used after the fix is identified by SHA-256 and its exact backend source diff in each run's metadata.

## Setup, provenance and limits

All successful live scenarios use Codex **0.155.0-alpha.9.2**, **gpt-5.6-luna**, **low** reasoning. They use a separately owned daemon, ephemeral loopback port and fresh disposable data/workspace directories. Child-only Codex configuration is `on-request` approval, `read-only` sandbox and `user` approval reviewer. Saved user configuration is not changed. The crash harness validates the target thread's directory/state and verifies that the provider PID is still a direct child of its owned daemon before signaling it.

`check-provider.mjs` starts the isolated instance and handles approvals or holds it for Swift checks. For client checks, copy its `ready.json` into a fresh app-container temporary directory and replace `QA_OUTPUT` in `client-workflows.swift` with that directory. For retry, prepend the setup/helper section from `client-workflows.swift` to `client-retry.swift`; pass the same app-container directory as the harness's fourth argument so it can observe the explicit crash request. Run snippets with Xcode MCP, then create the harness output's `stop` file. `QA_DAEMON` selects an already-built daemon. Every retained run records successful owned-daemon cleanup.

The evidence manifest lists original paths, byte counts and SHA-256 hashes. Larger JSON snapshots/notifications are compressed losslessly. Databases, authentication files and native conversation stores are excluded. Live test conversations remain in Codex history; they were not silently deleted.

Harness limitations/failures are retained rather than counted as product failures:

- An initial `--help` probe briefly started the daemon against its default data directory because this executable does not parse flags. It was stopped before any test RPC. No before/after database hash exists, so this report does not claim byte-for-byte preservation from that startup; subsequent instances use explicit disposable data.
- The retired `untrusted` approval policy prevented the first isolated session from starting (`provider-approval-a`). The supported configuration above succeeded.
- The first Swift snippet failed to compile because a local helper needed main-actor isolation. The next attempt could not read the external QA cache through the app sandbox. Moving only QA input/output to a new app-container temporary directory resolved it; product sandbox permissions were not changed.
- The first expanded race run could not find Ghostty's pkg-config file. The configured rerun passed; both logs are retained.

Remaining release requirements include rendered approvals/errors, annotation selection and fork provenance, multi-page history, provider-version/registry behavior, attachments, accessibility, remaining iOS checks, and refreshed distribution validation. This branch is **not yet cleared for production**.
