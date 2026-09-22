# Controlled viewport, stress and memory QA — September 22

The native opening, pagination, resizing and five-chat scenarios complete successfully. Full-history stress remains substantially slower than normal paginated use; these results do not establish constant 120 fps. Recording/profiling/builds did not run during the timing or memory scenarios. A temporary `caffeinate -di` assertion prevented idle display sleep during the repeated memory and later timing runs; it did not disable locking or the visibility checks.

## Provenance and validity

macOS 27, Mac14,9, display maximum 120 Hz, verified 1280×900-point window, synthetic production thread/reducer/renderers, no daemon/provider. Base commit `2be528a`. `verified-build.json` identifies code image `bba11d79…1cc1e2c` and its successful Xcode MCP build; `source.patch` records the benchmark changes. The second valid List scrub used the later build in `viewport-timeout-build.json`; its only Swift difference was extending the bounded window-setup wait from 3 to 15 seconds and expanding failure diagnostics. Product rendering code was identical. The subsequent streaming-completion fix is documented separately in `../../rendering-20260922/REPORT.md` and does not change the non-streaming scenarios here.

The harness now verifies the actual window instead of trusting a resize request. It rejects lost visibility, source mismatches and incomplete preparation before accepting a result. Session tests also verify each requested resize. Setup/open checkpoints include the setup wait; scrolling timers start after preparation. Opening numbers measure the prepared/aligned viewport from the benchmark task, not process launch, network loading or the first presented frame. Raw per-run metadata/logs/results and `summary.json` are authoritative.

Excluded diagnostics are preserved:

- `native-scrub-wm-unavailable`: AeroSpace CLI existed but its server was not running. No valid measurement; no window manager was started.
- `native-scrub-wrong-width`: the old setup left a 504-point window. Its results are excluded from controlled-width comparisons.
- `native-five-rich-occluded`: all five initial checkpoints completed, but the first return visit lost visibility. No completed memory claim is made from that run. The valid retry is `native-five-rich`.
- `list-scrub/scrub-2` and `list-scrub-retry/scrub-1`: rejected at the original three-second setup deadline, before measurement. The longer bounded wait retains the same viewport validation.
- `list-scrub-settled/scrub-2`: setup passed, then visibility was lost during measurement. Excluded. Only two valid List stress repetitions are available, explicitly reported below.

## Extreme scrubbing

Each run traverses the full 300-turn history from end to end every 0.25 seconds, repeatedly reversing for 20 seconds. This intentionally differs from an ordinary fling. Rates are display-link callbacks, **not presented frames**.

| Renderer | Valid fresh runs | Mean callback Hz | p99 interval across runs | Worst interval |
| --- | ---: | ---: | ---: | ---: |
| Native | 3 | 39.88 | 42.57–45.64 ms | 79.04 ms |
| List | 2 | 17.80 | 290.96–371.04 ms | 947.03 ms |

Both exhibit substantial dropped pacing in this stress case. Native improves this particular comparison but is not hitch-free. No intentional blank-content mode was introduced.

## Opening and anchor correctness

Three fresh native launches per mode, same underlying 300-turn fixture:

| Opening mode | Loaded rows | Prepared/aligned checkpoint |
| --- | ---: | ---: |
| Normal pagination | 109 | 731.67–745.33 ms |
| Forced full history | 5,851 | 7,713.69–7,979.51 ms |

The actual lifecycle run grows the loaded transcript from 109 to 301 rows. Pagination preserves the anchor with **0-point error**. Resizing from 1280 to 700 points changes the transcript height from 50,639 to 56,323 points, with the same row identity and 829.5-point within-row offset: **0-point anchor error**. The run stays visible and reports passed. This is one pagination boundary/reflow probe, not a substitute for every disclosure/fullscreen case.

## Five chats, return visits and memory

Each scenario opens five distinct chats, then revisits them in order 1,5,2,4,3,1. All 11 checkpoints are aligned/visible. Every visit resizes to 1000,800,700,1280 points, for 44 verified resizes per run.

| Scenario | Fixture per chat | Final physical footprint | Peak physical footprint | Highest sampled RSS |
| --- | --- | ---: | ---: | ---: |
| Normal | 20 turns, normal pagination | 123.9M | 169.2M | 245.44 MiB |
| Full rich | 300 turns, forced full history | 486.8M | 494.5M | 561.34 MiB |

Physical footprint/peak come from final `vmmap -summary`, including the process's recorded peak. RSS was sampled approximately every 0.5 seconds and can miss brief peaks; it counts memory differently from physical footprint and is not interchangeable with it. Raw files preserve both; the `vmmap` text is losslessly gzip-compressed to retain its original padded columns. The early session metadata's generic `measurement` label says display-link callbacks; the actual reports are explicitly `sessionMemoryCheckpoint` and contain no FPS claim. Later harness metadata corrects that label.

Returning to a previously visited width retains the same selected layout count (266 normal; 14,700 rich). Rich initial visits plus four resizes take about 30–32 seconds each; revisits plus four resizes take about 25–26 seconds. These totals include all four width changes and settle waits, not just chat-switch latency. Full-document geometry alone takes roughly 4.5–4.8 seconds per width: a substantial stress limitation.

These scenarios exercise retention and repeated fixed widths. They do not prove bounded memory across arbitrarily many distinct widths or under OS memory pressure. Existing September 20 resource regressions separately verify cancellation, eviction of original presentation objects and fresh caches on reopening. Five retained chats are within the normal inactive-session cache policy; this whole-app run does not itself force eviction.
