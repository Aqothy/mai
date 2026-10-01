# Benchmarks and simulations to run

Start with the small normal-use set below. Broaden only for an observed issue or a candidate optimization. Do not rerun every historical experiment by default. Run one workload at a time, keep the app visible/unlocked at the verified window size, and avoid simultaneous builds, profiling, recordings and interaction during timed comparisons.

## Artifact and environment

Build through **Xcode MCP**. For comparative performance use the same signed, optimized Debug configuration on both sides; fixtures require DEBUG and a normal Release build excludes them. Do not silently change project settings or compare unoptimized Debug with older optimized results. Record the exact binary hash/commit, dirty diff, optimizer settings, provider version, OS/hardware, refresh setting, scale/window size, fixture and power/thermal conditions. The historical `/tmp/maid-chat-perf/...` apps are snapshots, not current source.

Known local Debug product path at handoff:

```sh
benchmark_app=/Users/aqothy/Library/Developer/Xcode/DerivedData/mai-ajvexhhktjwtgvgbkhqoplogzozb/Build/Products/Debug/mai.app
benchmark_output=$(mktemp -d /tmp/maid-qa-bench.XXXXXX)
```

Confirm it is the intended freshly built artifact before use. The commands below are examples to run from the repository root; they were **not executed during handoff preparation**. Each output child must be fresh. Harnesses replace/terminate their own test app instances; close a normal instance first and use disposable simulator data.

## Small normal-use set

```sh
python3 clients/swift/scripts/benchmark-containers.py "$benchmark_app" "$benchmark_output/open" --plan open --container custom --turns 20 --paginated --runs 3
python3 clients/swift/scripts/benchmark-containers.py "$benchmark_app" "$benchmark_output/scroll" --plan scroll --container custom --turns 300 --paginated --runs 3
python3 clients/swift/scripts/benchmark-containers.py "$benchmark_app" "$benchmark_output/stream" --plan stream --container custom --paginated --runs 3
python3 clients/swift/scripts/benchmark-containers.py "$benchmark_app" "$benchmark_output/stream-scroll" --plan streamScroll --container custom --paginated --runs 3
python3 clients/swift/scripts/benchmark-containers.py "$benchmark_app" "$benchmark_output/anchors" --plan lifecycle --container custom --paginated --runs 1
```

`scroll` covers 1,200/3,000/8,000 pt/s. `stream` feeds 20,000 characters through production streaming reduction and validates exact final text/completion. `lifecycle` checks native pagination/resize anchors. Repeat only the relevant comparison with `--container list` and a different output path; the lifecycle plan is native-specific. Source/anchor failure invalidates any apparent speedup.

## Extended workloads when justified

| Scenario | Invocation adjustments | Question answered |
| --- | --- | --- |
| Full-history opening | `--plan open --turns 300 --runs 3`, omit `--paginated` | Preparation cost for all history versus a recent page. This is not process/network/first-presentation latency. |
| Normal retained sessions | `--plan sessionsResize --turns 20 --paginated --runs 1 --timeout 600` | Five chats, revisits and four widths: retained/peak resources and stable reuse. |
| Rich stress sessions | `--plan sessionsResize --turns 300 --runs 1 --timeout 600` | Deliberate full-history memory/layout stress. Keep separate from normal UX claims. |
| Fast reverse traversal | `--plan scrub --scrub-period 2 --runs 3` | Long-history direction reversal. |
| Extreme scrub | `--plan scrub --scrub-period 0.25 --runs 3` | Pathological upper-bound stress, not ordinary scrolling. Previous native/List both missed 120 Hz badly. |
| Cold launch / real history | Dedicated process-start and daemon/history checkpoints | Existing `open` measures prepared/aligned selection, not cold startup/network. Add explicit measurement boundaries in the future CLI. |

Omission of `--paginated` loads the entire fixture. Do not accidentally call it a normal paginated benchmark. The existing harness records RSS; use physical footprint/peak tooling when that distinction matters. OS allocator retention is not automatically a leak.

## Visual streaming capture, separate from timing

```sh
python3 clients/swift/scripts/record-chat-stream.py "$benchmark_app" "$benchmark_output/native-activity-capture" --container custom --rate 120 --activity
python3 clients/swift/scripts/record-chat-stream.py "$benchmark_app" "$benchmark_output/list-activity-capture" --container list --rate 120 --activity
```

Inspect thought/tool/reply transitions, working-row position and mixed-frame seams. Use numbered/unique text to disambiguate visually repeated sections. Existing analyzers and retained candidates are under `qa/2026-09-beta-integration/activity-20260927` and `rendering-20260922`. Requested recording rate is not achieved capture rate; measure actual timestamps/gaps. Historical recordings averaged about 79 captured frames/s and cannot certify every 120 Hz display frame. Instrumentation can itself affect performance.

## iOS simulator: functional, not ProMotion certification

Build through Xcode MCP, install on a dedicated booted simulator if necessary, verify actual installed binary/runtime, then:

```sh
qa_simulator=9BE259FD-5083-4C60-9D6A-0AAC4CDB2F48
python3 clients/swift/scripts/benchmark-simulator.py "$qa_simulator" "$benchmark_output/ios-stream" --plan stream --paginated --runs 3
python3 clients/swift/scripts/benchmark-simulator.py "$qa_simulator" "$benchmark_output/ios-scroll" --plan scroll --paginated --runs 3
python3 clients/swift/scripts/benchmark-simulator.py "$qa_simulator" "$benchmark_output/ios-stream-scroll" --plan streamScroll --paginated --runs 3
```

That UUID was the actual iOS 18.6 / 22G86 device at handoff; verify availability, do not assume it still exists. This automates exact streaming and scripted movement, not keyboard, picker, VoiceOver or physical scrolling. Extract `.xcresult` runtime metadata for tests. A selected Xcode destination did not reliably identify `RunCodeSnippet` preview-host runtimes.

Physical 60 Hz and 120 Hz devices need their own runs and actual display/hitch measurements. The user's optional iPhone 14 cannot supply the 120 Hz result. Keep Low Power/thermal/display settings recorded rather than making global changes to get a desired number.

## Correctness and failure simulations for the next agent

| Simulation | Existing starting point |
| --- | --- |
| Two thoughts + tools + exact final reply; reload/annotation replay; fractional timestamps | `maiTests/ChatProviderReplayTests.swift`, `WireJSONTests.swift`, `qa/.../runtime-replay-20260927` (two known iOS 18.6 generated-decoder failures still open) |
| Reasoning selection through thread start/resume and turn | `internal/adapters/codexapp/adapter_integration_test.go`, `qa/.../reasoning-20260921` |
| Provider crash, reconnect, retry, queue, approvals, steering | `qa/.../workflows-20260922`, `live-release-20260921`, adapter/orchestration/daemon tests |
| Missing/failed history page and older/current runtime | `qa/.../history-20260923`, Codex history tests |
| Unicode/draft/completion races | `ChatBetaIntegrationTests`, `PromptCompletionModel`, `qa/.../composer-20260927`, `keyboard-20260927` |
| Row reuse, clipboard/selection, stale height revisions and anchors | `ChatNativeTranscriptTests`, `ChatNativeSelectionReuseTests`, `ChatMacScrollPositionPreserverTests`, corresponding QA reports |
| Real request/response date parsing and terminal notifications | `qa/.../runtime-replay-20260927/date-wire-server.go` and its preserved runtime harness |
| Metadata upgrade/rollback and provider update during activity | `qa/.../metadata-20260926`, `registry-20260923`; isolated copies only |
| Terminal ordering, resize, reconnect, late-run output and large output | `internal/terminal`, `internal/daemon/terminal_*_test.go`, `qa/.../terminal-20260921` |

Go direct commands need the configured native library search path:

```sh
export PKG_CONFIG_PATH="$PWD/build/ghostty-vt/_deps/ghostty-src/zig-out/share/pkgconfig"
go test ./...
go vet ./...
go test -race ./internal/adapters/codexapp ./internal/orchestration ./internal/providerservice ./internal/daemon ./internal/terminal/...
make fff-verify
```

Use the existing Makefile to prepare missing native dependencies; don't interpret a missing pkg-config path as a product regression. Swift tests/builds still go through Xcode MCP. Gate live Codex calls deliberately; use the saved scripts/fixtures and a small disposable session rather than repeatedly paying for broad live runs.

## Reading and accepting results

`averageFPS` is a legacy field name for display-link callbacks per second. Compare p50/p95/p99/worst intervals, stalls, exact source/identity, input responsiveness, preparation latency and memory. A 120 Hz callback is not proof a fresh frame was presented. Reject hidden-window, wrong-size, source-mismatch, partial, timeout and stale-binary runs explicitly.

For a proposed optimization: one smoke run first; profile only the observed bottleneck; make the smallest causal change; then at least three comparable fresh launches for the affected workload. Keep a change only when improvement exceeds run-to-run noise and relevant correctness/visual/memory results do not regress. If no meaningful opportunity remains, report that and stop.
