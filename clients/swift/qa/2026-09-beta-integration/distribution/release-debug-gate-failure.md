# Release benchmark gate failure

The initial September 14 macOS archive (`macos-archive.json`, executable hash `1ff9cb66da255bd0ae9d3335c2dffc72f6c9d0120f413bdb4f253144ecc0f41a`) was launched with `-ChatPerformanceLab -ChatBenchmarkSyntheticTurns 300 -ChatAutoBenchmark scroll`. The actual UI opened Mock Chat with a 10,000-row fixture and printed `benchmark start: cruise-10k-1200pps`. Its synthetic-store constructor was Debug-only, but `ChatPerformanceLab.isEnabled` explicitly accepted the launch flag in Release.

The owned process was terminated. `ChatPerformanceLab.isEnabled` now returns false outside Debug. A replacement Release archive must ignore these arguments and expose the ordinary app shell without benchmark output.
