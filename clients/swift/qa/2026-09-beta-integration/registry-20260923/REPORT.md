# Registry update lifecycle — September 23

Base `5b84983`, plus the source changes identified by `manifest.json` and `source.patch.gz`; new test files are committed alongside them.

## Defect and resulting behavior

Updating a registry agent called `startRegistryAgent(restart: true)` whenever its provider was initialized. That replaces the process even if it owns an active turn. Removing the restart alone was insufficient: the backend retained the old launch configuration, so recovery after a process exit could start the old version again.

Updates now persist the selected version ceiling and register it for the next launch. Existing processes and sessions continue unchanged. An ordinary start reuses an existing process; the next launch after exit, an explicit restart, or a daemon restart uses the saved definition. Registration is serialized with launch so an update cannot be overwritten by an older in-flight factory. Explicit custom executable choices remain intact when no subsequent manifest update supersedes them. The registry explains that updates take effect when the agent next starts; idle running agents also continue until their next launch.

The client regression failed on the original source because it requested `restart: true`. Both backend cases failed on the original source: lazy recovery reused the old configuration, and an ordinary start with the updated definition returned a configuration-mismatch error. The first backend implementation exposed a custom-executable recovery regression; its failed result is retained and the final implementation uses a separate pending-update map. All final regressions pass.

## Executed checks

| Check | Evidence and outcome |
| --- | --- |
| Real npm acquisition and running-process lifecycle | npm 11.9.0, Node 24.14.0, actual local HTTP package registry, actual WebSocket RPC, actual acquired package/process and existing ACP protocol helper. Version 2 is advertised as latest while the initial ceiling is 1. Version 1 is acquired; an active prompt remains running with the same process ID through installation of version 2 and an ordinary start request. Releasing the prompt yields exactly one original user message and one completed assistant reply. After the owned idle process exits, ordinary session recovery acquires version 2. Exactly one tarball per version is fetched, and a fresh manifest reader sees version 2. Passes standalone and under the race detector. |
| Configuration and concurrency | Pending-update recovery, ordinary start reuse, registration during launch, custom executable preservation and existing private-manifest persistence checks pass. |
| Full backend suite | 505 top-level tests pass across 14 packages, no failures. Five opt-in tests skip: three live-provider/history checks, this npm scenario and API-example capture. The npm scenario is separately enabled and passes. No live Claude request runs. |
| Race detector | Complete provider-service and daemon packages: 112 top-level passes, no failures; only API-example capture skips. After the concurrent-registration regression was added, all four manifest tests also pass under the race detector. |
| Static checks | `go vet ./...`, Go formatting and diff checks pass. |
| Swift client | Five registry tests pass on macOS 27 and five on an actual iOS 18.6 simulator result bundle, with no failures, skips or runtime warnings. Both app/test-target builds pass through Xcode MCP. Warning queries report no compiler issues; raw logs retain the unrelated skipped App Intents metadata-extraction warning. |
| User-facing notice | Final Xcode previews show the complete update-timing notice on macOS 27 and iPhone 18 Pro/iOS 27. Preview OS is distinct from the iOS 18.6 runtime test destination. The preview-only model now avoids a real connection attempt that previously overlaid its fixture with a connection-error alert. |

The npm check uses only locally generated packages. Its package launches the existing deterministic ACP helper; it does not run a real model or establish compatibility with every public registry package. npm prefixes, cache and configuration files live in the test's disposable directory. Provider processes close with the test server. Existing custom-definition identity/collision, private manifest permissions and command/environment persistence checks also pass in the full suite.

## Retained setup failures and limits

- The first Swift test fixture omitted required timestamp fields and failed decoding; the corrected fixture then reproduced the restart defect. These are separate recorded failures.
- The first npm harness expected the QA provider to be the server's only configured provider, overlooking built-in definitions. The corrected assertion selects its own instance. The next attempt found that the existing fake agent advertised resume without handling `session/resume`; the helper now implements that response. Neither harness failure is counted as a product regression.
- One iOS tool call reported an incomplete result bundle. No test process remained active; subsequent inspection of that exact bundle showed five passes with no runtime warnings. A fresh final run also passed. Both the tool error and recovered summary are retained.
- Initial previews attempted to contact a daemon and presented an error; final static previews use only fixture data. They include a static Claude catalog row but perform no Claude authentication or model request.
- Registry uninstall is not an existing feature: the wire registry exposes list, installed, install, add-custom and start, and the UI exposes no uninstall action. The earlier checklist's deletion wording was too broad; no uninstall feature was added as QA work.
- Account-specific/public ACP runtime behavior, migration/downgrade of substantial native histories, rendered accessibility and final Release artifacts remain covered by their separate open requirements. This report does not clear the whole app for production.

## Reproduction

Use the repository's configured Ghostty pkg-config directory for Go commands. The local npm integration is explicitly enabled with `MAID_REGISTRY_NPM_QA=1` and run as `go test ./internal/daemon -run '^TestACPRegistryNPMUpdatePreservesActiveTurn$' -count=1 -v`. It serves and acquires both package versions locally; no public package installation is required. The default full suite skips this optional executable-dependent check.

`backend-summary.json` counts actual JSON test events. `*-tests-summary.json` comes from the actual Xcode result bundles. Raw output is retained, including expected injected-error logs. The active Xcode destination is restored to My Mac.
