#!/usr/bin/env python3
"""Exercise the installed Debug app's production iOS chat without a UI driver.

Use an isolated, booted simulator. This never builds or changes project settings.
Simulator callback pacing is not evidence of physical-device 60/120 Hz performance.
"""

import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import time


def simctl(*arguments):
    return subprocess.check_output(["xcrun", "simctl", *arguments], text=True).strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("device", help="UUID of the isolated, booted simulator")
    parser.add_argument("output", type=Path)
    parser.add_argument("--plan", choices=["scroll", "stream", "streamScroll"], required=True)
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--turns", type=int, default=300)
    parser.add_argument("--timeout", type=float, default=300)
    parser.add_argument("--paginated", action="store_true")
    args = parser.parse_args()
    if min(args.runs, args.turns, args.timeout) <= 0:
        parser.error("Runs, turns and timeout must be positive.")
    devices = json.loads(simctl("list", "devices", "-j"))["devices"]
    matches = [(runtime, device) for runtime, group in devices.items() for device in group
               if device["udid"] == args.device]
    if len(matches) != 1 or matches[0][1]["state"] != "Booted":
        parser.error("Select one existing booted simulator by UUID.")
    if args.output.exists() and any(args.output.iterdir()):
        parser.error("Use an empty output directory to preserve previous evidence.")
    bundle = "com.anthonyqiu.mai"
    app = Path(simctl("get_app_container", args.device, bundle, "app"))
    info = plistlib.loads((app / "Info.plist").read_bytes())
    code = app / "mai.debug.dylib"
    if not code.exists():
        code = app / info["CFBundleExecutable"]
    args.output.mkdir(parents=True, exist_ok=True)
    metadata = {
        "app": str(app), "bundleID": bundle, "runtime": matches[0][0],
        "deviceName": matches[0][1]["name"], "deviceUUID": args.device,
        "codeImageSHA256": hashlib.sha256(code.read_bytes()).hexdigest(),
        "plan": args.plan, "runs": args.runs, "syntheticTurns": args.turns,
        "paginated": args.paginated, "container": "iOS SwiftUI List",
        "measurement": "simulator display-link callbacks, not physical-device or presented FPS",
    }
    (args.output / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
    for run in range(1, args.runs + 1):
        log = (args.output / f"{args.plan}-{run}.log").resolve()
        launch = simctl(
            "launch", "--terminate-running-process", f"--stdout={log}",
            f"--stderr={log.with_suffix('.stderr')}", args.device, bundle,
            "-ChatPerformanceLab", "-ChatAutoBenchmark", args.plan,
            "-ChatBenchmarkSyntheticTurns", str(args.turns),
            "-ChatBenchmarkPaginatedHistory", "YES" if args.paginated else "NO")
        (log.with_suffix(".launch.txt")).write_text(launch + "\n")
        deadline = time.monotonic() + args.timeout
        try:
            while time.monotonic() < deadline:
                text = log.read_text(errors="replace") if log.exists() else ""
                if "\nCHAT_BENCHMARK_COMPLETE" in text:
                    stderr = log.with_suffix(".stderr")
                    diagnostics = text + (stderr.read_text(errors="replace") if stderr.exists() else "")
                    reports = [json.loads(line.split(" ", 1)[1]) for line in text.splitlines()
                               if line.startswith("CHAT_BENCHMARK_RESULT ")]
                    expected = 3 if args.plan == "scroll" else 1
                    invalid = [marker for marker in (
                        "invalid measurement:", "visible=false", "sourceMatches=false",
                        "transcript warm timed out", "benchmark skipped:",
                        "malloc: ***", "Fatal error:") if marker in diagnostics]
                    if len(reports) != expected or invalid:
                        raise RuntimeError(f"Invalid run ({len(reports)} reports, {invalid}): {log}")
                    if args.plan != "scroll" and "sourceMatches=true completed=true" not in text:
                        raise RuntimeError(f"Missing exact-source/completion verification: {log}")
                    log.with_suffix(".json").write_text(json.dumps(reports, indent=2) + "\n")
                    print(f"Completed {log}", flush=True)
                    break
                time.sleep(0.5)
            else:
                raise TimeoutError(f"Benchmark did not complete: {log}")
        finally:
            subprocess.run(["xcrun", "simctl", "terminate", args.device, bundle], check=False)


if __name__ == "__main__":
    main()
