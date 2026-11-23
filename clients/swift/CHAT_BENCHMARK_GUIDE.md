# Chat benchmarks

The benchmark fixtures and auto-run plans exist only in Debug/Profile builds (`#if DEBUG`). Build in Xcode (`mai Profile` for optimized timing), then pass the `.app` path to `benchmark-containers.py`. Compare only builds with matching optimization settings.

## macOS: `benchmark-containers.py`

```sh
python3 clients/swift/scripts/benchmark-containers.py path/to/mai.app .scratch/bench/after
python3 clients/swift/scripts/benchmark-containers.py --compare .scratch/bench/before .scratch/bench/after
```

By default, one single app launch runs the full **`suite`** plan (~20–25s) in the **background** (`open -g`, no focus steal, App Nap disabled, `.userInitiated` + `.latencyCritical` activity):

1. `open-1`, `open-2` — two cold switches to unique 1,000-turn chats (3 chats resident), measuring `visibleMilliseconds`, `settledMilliseconds`, and Mach `task_vm_info` physical footprint / peak footprint / RSS.
2. `cold-scroll-3000pps` — immediate 3s up + 3s down sweep (0 ms warmup sleep) catching cold on-demand parse+layout, `replaceRows`, accessory reuse, and warm steady-state scroll.
3. `cold-fling-8000pps` — 2s up + 2s down fast fling stressing `IOSurface` overscan rasterization.
4. `stream-4000cps` — 12,000 chars @ 4,000 chars/s with exact-source verification.
5. `stream-scroll-3000pps` — streaming @ 4,000 chars/s while scrolling at 3,000 pps.
6. `live-resize-2s` — 1280 → 600 → 1280 width sweep over 2s with reflow lag counters.
7. `memory-final` — end-of-suite physical footprint, peak footprint, and RSS.

| `--plan` | Workload |
|---|---|
| `suite` (default) | Single-launch full regression suite above (~20–25s). |
| `stream` | Standalone stream (used by `record-chat-stream.py` and stream-only profiling). |
| `markdown` | Headless Markdown/StreamWorker replay microbenchmark (no window; add `--app-arg=-ChatMarkdownReplayExtreme --app-arg=YES` for extreme stress fixtures). |

| Flag | Meaning |
|---|---|
| `--turns N` | Synthetic turn count, default 1000. |
| `--runs N` | App launches, default 1. |
| `--engine new\|legacy` | Transcript engine, default `new`. |
| `--foreground` | Activate and focus the benchmark window instead of running behind active windows. |
| `--with-chrome` | Keep sidebar, composer, and toolbar (default is transcript-only). |
| `--compare <dirs...>` | Print summaries for saved result directories without launching the app. |

> **Background visibility note:** macOS only drives `CADisplayLink` and Core Animation commits for windows with `occlusionState.contains(.visible) == true`. On multi-display setups the benchmark window automatically opens on a secondary display. On a single display, keep at least a strip of the window unobscured behind your active window (or pass `--foreground`).

## iOS simulator: `benchmark-simulator.py`

```sh
python3 clients/swift/scripts/benchmark-simulator.py SIMULATOR_UUID .scratch/bench/ios
```

Runs `suite` (default, skips macOS resize) or `stream` in a single launch. Simulator callback rates do not measure physical-device refresh pacing.

## Screen recording: `record-chat-stream.py`

Records the `stream` plan cropped to the app window for frame-by-frame inspection (`ffmpeg`). Flags: `--rate`, `--activity`.
