# Older-runtime teardown and scripted simulator QA

Source: `b9a259a`, on `aq/beta-01-08-integration-20260912`. Host: macOS 27.0 / Xcode 27. Simulator: isolated iPhone 16, iOS 18.6 (22G86), UUID `9BE259FD-5083-4C60-9D6A-0AAC4CDB2F48`. The deployment target remains 18.6, as requested. No phone was connected.

## Failure and fix

The initial full iOS 18.6 suite passed 113 tests and crashed in 13, each with `pointer being freed was not allocated`. A debugger stopped at `malloc_error_break` and captured the path through `swift::TaskLocal::StopLookupScope`, `swift_task_deinitOnExecutorImpl`, and `ChatTimelineProjection.__deallocating_deinit`. This matches [Swift issue 88036](https://github.com/swiftlang/swift/issues/88036) and the [runtime allocation fix](https://github.com/swiftlang/swift/commit/29245e4).

Explicit nonisolated destructors in the timeline and layout caches removed 12 crashes. The remaining stack named `NativeStreamingBenchmarkState`, released by a UIKit hosting view after a commit. Fixing the test state yielded 126 passing tests, but this was insufficient coverage: most ordinary model tests run inside Swift tasks, where the older runtime does not take the failing path.

Nine new synchronous XCTest cases release chat presentation objects and JSON helpers inside a task-local scope and assert the weak reference becomes nil. Five additional chat-state cases failed before the broader fix. The generated JSON helper cases also failed. One intermediate run additionally failed its first annotation case; its crash stack was not captured, so no separate root cause is claimed for that intermediate failure. All nine cases pass in the final full runs.

The compiled-app audit identified the remaining synthesized isolated destructor paths, including UI bridge objects and both generated JSON helper classes. The handwritten types now declare empty `nonisolated deinit` explicitly; existing activation, cancellation, view recycling and teardown methods retain their behavior. This does not move model updates off the main actor or add asynchronous destruction. The generator now emits the same declaration for `JSONAny` and `JSONNull`; the user approved that regeneration. The other generated files are byte-identical. Both final Debug app symbol audits contain zero synthesized isolated destructors. This is a targeted compatibility audit, not proof that all memory/lifetime behavior is correct.

## Final verification

- macOS 27: **138 passed**, zero failures, skips or runtime warnings (`mac-full-suite.json`).
- iOS 18.6: **135 passed**, zero failures, skips or runtime warnings (`ios-full-suite.json`).
- Xcode MCP builds on both platforms succeed without reported warnings. The test summaries above come directly from the `.xcresult` bundles; MCP included cached tests from the other platform in its iOS count and initially returned the Mac bundle before it finished writing.
- Nine new synchronous lifetime regression cases run on both platforms. Existing row geometry, streaming, cache release/cancellation and model tests remain enabled.
- Generator syntax and whitespace checks pass. The isolated proposed regeneration matches the applied generated output.
- macOS code image SHA-256: `2cf275d7344a81e3cc86eeb2e07b20f7293d863ce683ffeebb9ca7ed33291c8b`.
- iOS code image SHA-256: `207c138d46c48574febf71277198ca08880e13c77b841d1784317c08f74b5ad0`.

The source patch, initial/partial/final results and two debugger stacks are retained here. No debugger or test build ran alongside a timed simulator benchmark.

## Scripted app scenarios

The user requested scripts where they provide equivalent evidence. `scripts/benchmark-simulator.py` launches the installed Debug app through `simctl`, opens the production synthetic transcript via the existing runner, drives its scroll/stream scenarios, validates source preservation/completion and retains logs, reports and binary/device metadata. It never builds or changes Xcode settings, and it uses only the isolated QA simulator.

`stream/` contains three successful runs on the intermediate two-cache fix, code hash `02d6eb1afc31d33a627b82199f7eb884d5a1ff7bc3f81bb3069b72f5780e047e`. All three preserved the exact 20,000-character source and completed. Mean callback rates were 52.10, 51.34 and 51.12 Hz; p99 intervals were 37.74–38.61 ms and maximum intervals 127.36–137.24 ms. These establish the scripted workflow and that intermediate artifact's behavior. Final-artifact scenarios are recorded separately below.

Simulator callback timing is not presented FPS or physical-device 60/120 Hz evidence. These runs do not establish selection menus, keyboard safe areas, actual tile coherence or hardware performance. Physical-device and final Release checks remain open in `RELEASE_QA.md`.

## Final scripted matrix (`b9a259a`)

Nine fresh app launches completed: three each for scrolling, streaming and streaming while scrolling. All 15 reports match their raw logs, use the final audited iOS code image, and pass the runner guards. All six streams preserved the exact source and completed. No fatal-error markers or stderr output were observed. Scroll logs also show successive history preparations while paging through the fixture.

| Scenario | Runs | Mean callback Hz | Worst-run p99 ms | Maximum interval ms |
| --- | ---: | ---: | ---: | ---: |
| real-cruise-1200pps | 3 | 59.21 | 33.33 | 48.08 |
| real-scroll-3000pps | 3 | 57.39 | 35.53 | 76.04 |
| real-fling-8000pps | 3 | 58.22 | 33.33 | 72.65 |
| production-stream-20000chars | 3 | 50.28 | 37.59 | 128.17 |
| production-stream-scroll-3000pps | 3 | 56.57 | 35.16 | 119.55 |

The simulator reports a 60 Hz maximum. These callback results do not measure physical iPhone performance and do not prove a 60 Hz limitation in SwiftUI List. Programmatic scrolling also does not exercise finger/trackpad intent events; those remain separate QA.
