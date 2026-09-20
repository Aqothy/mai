# Plain streaming and corrected List comparison

App source: `217e4886faa6bfb9ef13dbdaf7f97ca495060ddf`. Code image SHA-256: `b121cf4480f260ff6e55bf6221a9ba54395538d804ab3a879c523df11b032e35`. macOS 27.0, ordinary Debug build, 120 Hz maximum display rate. Same 300-turn synthetic transcript and 1280 × 900 content window. Full history for scroll/stream plans; paginated history for opening/lifecycle.

Three fresh visible launches per configuration. Every raw log reached completion, contains its expected reports and passes visibility, preparation and source-equality guards. No profiler, screenshot loop, build or test ran concurrently. The preceding occluded attempt is retained separately and excluded. Raw metadata and reports are beside this file.

**These are display-link callback intervals, not measured presented FPS.** The average is the arithmetic mean of three run averages; p99 is the worst run’s p99; maximum is the largest individual interval.

| Configuration | Scenario | Mean callback Hz | Worst run p99 (ms) | Longest interval (ms) |
| --- | --- | ---: | ---: | ---: |
| custom-scroll | real-cruise-1200pps | 118.87 | 8.33 | 164.58 |
| custom-scroll | real-scroll-3000pps | 118.47 | 12.87 | 227.04 |
| custom-scroll | real-fling-8000pps | 116.52 | 17.39 | 23.56 |
| list-scroll | real-cruise-1200pps | 109.06 | 22.36 | 95.96 |
| list-scroll | real-scroll-3000pps | 96.71 | 22.35 | 28.21 |
| list-scroll | real-fling-8000pps | 59.06 | 75.25 | 1216.22 |
| custom-stream | production-stream-20000chars | 108.13 | 25.88 | 58.33 |
| list-stream | production-stream-20000chars | 93.12 | 33.33 | 296.41 |
| custom-streamScroll | production-stream-scroll-3000pps | 117.91 | 16.67 | 25.00 |
| list-streamScroll | production-stream-scroll-3000pps | 102.32 | 18.90 | 88.15 |

Native scrolling is generally close to 120 callbacks/s but is not hitch-free: slow/ordinary sweeps included 164.58/227.04 ms outliers. Corrected List is not capped at 60 Hz: slow scrolling averaged 109.06 Hz, while fast flinging fell to 59.06 Hz with a 1.216 s worst interval. Streaming and scrolling during streaming favor native in this fixture. This does not establish iOS performance or rule out a partially updated presented frame.

List anchors preserved the existing horizontal origin (−280 points); the earlier shifted List matrix is excluded from this controlled comparison. No intentional content blanking was introduced.

Paginated prepared-and-aligned opening took 599.84, 777.13 and 600.00 ms for 109 rows. This excludes process startup/network and is not a first-presented-frame measurement. The native lifecycle run expanded 109 to 301 rows; pagination and resize anchor errors were both zero. Resizing to a 700-point window produced a 420-point transcript, preserving the same row and its 829.5-point internal offset.

Still open: final-build extreme scrubbing/full-history opening and session switching/resizing memory observations; presented-frame streaming coherence; physical-device iOS measurements. Earlier data for those scenarios remain scoped to their recorded older source.
