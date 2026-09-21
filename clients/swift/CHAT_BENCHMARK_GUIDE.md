# Running the chat benchmarks

Current main source uses the custom AppKit transcript on macOS: an NSScrollView with a virtualized document, native prepared content and SwiftUI interactive/live rows. It is not an NSTableView. iOS uses SwiftUI List. Debug macOS launches can select the original List with `-ChatBenchmarkUseList YES`; Release always selects native macOS.

## Manual synthetic chat — no automation

Use a Debug build. Quit that build first, then launch it without `ChatAutoBenchmark`:

```sh
open -n -a /tmp/maid-chat-perf/native-stream-layout-fixed/mai.app --args \
  -ChatPerformanceLab \
  -ChatBenchmarkSyntheticTurns 300 \
  -ChatBenchmarkPaginatedHistory YES \
  -ChatBenchmarkUseList NO
```

This opens the synthetic transcript already selected in the normal app shell. Scroll, resize, select/copy text, and expand thought/tool disclosures yourself. No automated scrolling, timing, streaming, or termination runs. The synthetic store does not connect to the daemon, so sending prompts and fetching remote tool details are not available.

Change `ChatBenchmarkUseList` to `YES` for original macOS List. Change `ChatBenchmarkPaginatedHistory` to `NO` to load all 300 turns up front; expect a longer preparation pause. With `YES`, older turns load as you scroll back. The same arguments work in Xcode's Run scheme; uncheck any existing `-ChatAutoBenchmark` argument. Do not launch through the Python harness for this mode: that harness is specifically for automated runs.

The `/tmp` app is a fixed snapshot. Replace its path with your newly built Debug product to inspect current source.

## Quick start

Run from the repository root. This signed snapshot is the optimized app used for the final September 11 validation; it does not rebuild when source changes and may eventually be removed from /tmp:

```sh
cd /Users/aqothy/Code/Personal/maiD
benchmark_app=/tmp/maid-chat-perf/native-stream-layout-fixed/mai.app
python3 clients/swift/scripts/benchmark-containers.py "$benchmark_app" /tmp/my-chat-native-scroll --plan scroll --container custom --runs 3
python3 clients/swift/scripts/benchmark-containers.py "$benchmark_app" /tmp/my-chat-list-scroll --plan scroll --container list --runs 3
```

Run the commands sequentially. Quit that build before starting; keep the laptop open, unlocked and the benchmark window visible. Avoid other builds, profiling and interaction during timing. Use a fresh output directory for every invocation. The harness launches synthetic chats, writes logs/results, validates completion, and terminates its own launched process. Synthetic streaming does not send prompts to a model.

For current source, build a signed Debug app in Xcode and replace `benchmark_app` with its product path (Products → mai.app → Show in Finder). The previous performance build used Swift `-O`, whole-module compilation and coverage disabled on the app target, with dependencies still Debug. Ordinary unoptimized Debug results are not comparable to those numbers. Benchmark fixtures require DEBUG; a normal Release build cannot substitute. The harness never builds or changes build settings.

## Plans

Replace the plan and output directory in the command above:

| `--plan` | Workload |
|---|---|
| `scroll` | Three automatic up/down sweeps at 1,200, 3,000 and 8,000 points/second. |
| `stream` | Feed 20,000 characters through the production streaming reducer; verify exact final source and completion. |
| `streamScroll` | Stream while scrolling at 3,000 points/second. |
| `open` | Measure fixture selection to prepared, aligned viewport; excludes process startup, network restoration and first presented frame. |
| `lifecycle` | Native pagination and resize anchor correctness; use `--container custom --paginated`. |
| `scrub` | Traverse the loaded history repeatedly; requires `--scrub-period`, e.g. `--scrub-period 2` means two seconds per one-way traversal. |
| `sessions` | Open five separate synthetic chats, retain prior sessions, sample process RSS. |
| `sessionsResize` | Five chats, each resized through 1,000, 800, 700 and 1,280-point window widths; sample RSS. |

Examples:

```sh
python3 clients/swift/scripts/benchmark-containers.py "$benchmark_app" /tmp/my-chat-stream --plan stream --runs 3
python3 clients/swift/scripts/benchmark-containers.py "$benchmark_app" /tmp/my-chat-open --plan open --paginated --runs 3
python3 clients/swift/scripts/benchmark-containers.py "$benchmark_app" /tmp/my-chat-lifecycle --plan lifecycle --paginated --runs 1
python3 clients/swift/scripts/benchmark-containers.py "$benchmark_app" /tmp/my-chat-scrub --plan scrub --scrub-period 2 --runs 3
python3 clients/swift/scripts/benchmark-containers.py "$benchmark_app" /tmp/my-chat-five --plan sessions --paginated --runs 1
python3 clients/swift/scripts/benchmark-containers.py "$benchmark_app" /tmp/my-chat-five-resize --plan sessionsResize --runs 1 --timeout 600
```

The last command deliberately loads all 300 turns in every chat. Add `--paginated` for the normal recent-page workload.

## Harness flags

| Flag | Meaning |
|---|---|
| `--container custom` / `list` | Custom AppKit viewport or original SwiftUI List. Default `custom`. |
| `--turns N` | Synthetic turn count. Default 300. Keep positive for these production-transcript benchmarks; zero omits synthetic seeding. |
| `--runs N` | Fresh app launches, default 3. Each `scroll` launch includes all three speeds. |
| `--paginated` | Load the normal recent page initially. Omission deliberately prepares the entire fixture. |
| `--timeout N` | Maximum seconds per launch before failure, default 300. Does not change sweep speed or duration. |
| `--scrub-period N` | Seconds for a one-way full-history traversal; required positive for `scrub`. |
| `--float-window` | Optional AeroSpace integration: float the launched window so resize tests can change its actual size. Requires the AeroSpace CLI. |

## Xcode launch arguments / manual inspection

In Edit Scheme → Run → Arguments Passed On Launch, enable these arguments (the values belong with their respective flags):

```text
-ChatPerformanceLab
-ChatAutoBenchmark scroll
-ChatBenchmarkSyntheticTurns 300
-ChatBenchmarkPaginatedHistory NO
-ChatBenchmarkUseList NO
-ChatBenchmarkAnchorRow 4800
```

`ChatPerformanceLab` enables diagnostics. `ChatAutoBenchmark` selects the plan from the table. `ChatBenchmarkSyntheticTurns` supplies offline data. `ChatBenchmarkPaginatedHistory YES` selects normal initial pagination. `ChatBenchmarkUseList YES` switches macOS Debug to List; NO selects native. `ChatBenchmarkAnchorRow` starts sweeps at that row (the harness uses 4800 for the 300-turn full-history fixture). `ChatBenchmarkScrubPeriod` is the manual equivalent of `--scrub-period`.

For a real connected thread, omit `ChatBenchmarkSyntheticTurns` and use `-ChatBenchmarkThread "title substring"` with the scroll plan. This requires working provider history loading. The Python harness does not expose a real-thread title option. Use synthetic data for the stream and five-session plans.

Disable benchmark arguments to return to normal app startup. Direct Xcode/manual launches print `CHAT_BENCHMARK_RESULT` and `CHAT_BENCHMARK_COMPLETE`; the Python harness additionally validates, saves JSON and cleans up its launched app.

## Reading results

For an already-built Debug app installed on an isolated, booted iOS simulator, the same production transcript can run without a device-viewer session:

```sh
python3 clients/swift/scripts/benchmark-simulator.py SIMULATOR_UUID /tmp/ios-chat-stream --plan stream --paginated --runs 3
```

Use Xcode MCP to build and test, then `simctl install` if installation is needed. This script supports `scroll`, `stream` and `streamScroll`, opens the chat through the existing Debug runner, validates report count and exact streamed source, and terminates the app it launched. It replaces any running mai instance on the selected simulator, so use a dedicated QA device. Logs and binary/device metadata are retained in a fresh output directory. It does not automate keyboard or text-selection interactions. Simulator callback rates cannot establish physical iPhone 60/120 Hz performance.

Each macOS harness output directory contains plan/run `.json`, `.log`, `.stderr`, post-run `.memory.json`, and `metadata.json` with the binary hash and configuration. Session plans also have `.memory-samples.json`.

`averageFPS` is historically named: it measures CADisplayLink callbacks per second, not independently verified presented FPS. At 120 Hz the interval target is 8.33 ms. Read p99 and maximum intervals alongside the average. RSS is whole-process memory, not isolated cache size or a guaranteed peak. Hidden-window, incomplete or source-mismatch runs are invalid; do not include them in comparisons.

See [the results report](CHAT_PERFORMANCE_BALANCE.md) for measured tradeoffs and retained/rejected experiments.
