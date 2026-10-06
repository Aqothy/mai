# Chat benchmarks

macOS renders chat with a custom AppKit transcript (an `NSScrollView` with a virtualized document, native prepared rows and SwiftUI interactive/live rows). iOS uses SwiftUI `List`. Debug macOS builds can switch to the original `List` with `-ChatBenchmarkUseList YES` as a comparison baseline; Release always uses the native transcript.

The benchmark fixtures and auto-run plans exist only in Debug builds. Build a signed Debug app in Xcode, then pass its product path (Products → mai.app → Show in Finder) to the scripts. Results are only comparable between builds with the same optimization settings.

Run from the repository root. Quit any running copy of the app first, keep the machine unlocked and the benchmark window visible, and avoid other work during timing. Use a fresh output directory for every invocation; the scripts refuse to overwrite results.

## macOS: `benchmark-containers.py`

```sh
python3 clients/swift/scripts/benchmark-containers.py path/to/mai.app /tmp/chat-scroll --plan scroll --runs 3
```

| `--plan` | Workload |
|---|---|
| `scroll` | Three automatic up/down sweeps at 1,200, 3,000 and 8,000 points/second. |
| `stream` | Feed 20,000 characters through the production streaming reducer; verify the exact final source. |
| `streamScroll` | Stream while scrolling at 3,000 points/second. |
| `open` | Fixture selection to a prepared, aligned viewport (excludes process startup and network restoration). |
| `lifecycle` | Pagination and resize anchor correctness; use with `--paginated`. |
| `scrub` | Traverse the loaded history repeatedly; requires `--scrub-period N` (seconds per one-way traversal). |
| `sessions` | Open five synthetic chats, retain prior sessions, sample process RSS. |
| `sessionsResize` | Five chats, each resized through several window widths; sample RSS. |

| Flag | Meaning |
|---|---|
| `--container custom` / `list` | Native AppKit transcript or SwiftUI `List`. Default `custom`. |
| `--turns N` | Synthetic turn count, default 300. `0` runs the mock chat lab instead of the production transcript. |
| `--runs N` | Fresh app launches, default 3. |
| `--paginated` | Load the normal recent page initially instead of the whole fixture. |
| `--timeout N` | Seconds per launch before failure, default 300. |
| `--scrub-period N` | Required positive for `scrub`. |
| `--float-window` | Float the window with the AeroSpace CLI so resize plans can change its size. |

Each output directory contains per-run `.json`, `.log`, `.stderr` and `.memory.json` files, plus `metadata.json` with the binary hash and configuration.

## iOS simulator: `benchmark-simulator.py`

```sh
python3 clients/swift/scripts/benchmark-simulator.py SIMULATOR_UUID /tmp/ios-chat-stream --plan stream --paginated --runs 3
```

Supports `scroll`, `stream` and `streamScroll` with `--runs`, `--turns`, `--timeout` and `--paginated`. The Debug app must already be installed on the simulator. The script replaces any running instance, so use a dedicated simulator. Simulator callback rates say nothing definitive about device refresh rates.

## Screen recording: `record-chat-stream.py`

Records the `stream` plan cropped to the app window for frame-by-frame inspection (requires `ffmpeg`). Flags: `--container custom|list`, `--rate`, `--activity`. This is for visual inspection, not timing.

## Manual launches

The same launch arguments work from Xcode (Edit Scheme → Run → Arguments):

| Argument | Meaning |
|---|---|
| `-ChatAutoBenchmark <plan>` | Run a plan from the table above and print `CHAT_BENCHMARK_RESULT` / `CHAT_BENCHMARK_COMPLETE` lines. |
| `-ChatBenchmarkSyntheticTurns N` | Seed an offline synthetic transcript with `N` turns. |
| `-ChatBenchmarkThread "<title substring>"` | Benchmark a real thread from the connected daemon instead. |
| `-ChatBenchmarkPaginatedHistory YES/NO` | Normal recent-page loading vs. the whole fixture up front. |
| `-ChatBenchmarkUseList YES/NO` | macOS `List` vs. native transcript. |
| `-ChatBenchmarkAnchorRow N` | Start sweeps at row `N` (the script uses 4800 for the 300-turn fixture). |
| `-ChatBenchmarkScrubPeriod N` | Seconds per one-way traversal for `scrub`. |
| `-ChatBenchmarkStreamActivity YES/NO` | Include thought/tool activity in the `stream` plan. |

Omit `-ChatAutoBenchmark` to open the synthetic chat for manual scrolling, resizing and selection without any automation; it does not connect to the daemon. macOS Debug builds also show a "Mock Chat" toolbar button that opens the mock chat lab.

## Reading results

`averageFPS` counts `CADisplayLink` callbacks per second, not verified presented frames. At 120 Hz the interval target is 8.33 ms; read p99 and maximum intervals alongside the average. RSS is whole-process memory. Discard hidden-window, incomplete or source-mismatch runs.
