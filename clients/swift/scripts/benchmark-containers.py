#!/usr/bin/env python3
"""Run an already-built macOS app's chat benchmark; never builds the app.

Example: python3 scripts/benchmark-containers.py /path/to/mai.app results/before --runs 3
Keep the window visible and avoid other CPU/GPU workloads during measurement.
"""

import argparse
import hashlib
import json
import pathlib
import platform
import subprocess
import shutil
import time


def app_pids(executable):
    output = subprocess.check_output(["ps", "-axo", "pid=,command="], text=True)
    return {
        int(line.strip().split(None, 1)[0])
        for line in output.splitlines()
        if line.strip().split(None, 1)[-1].startswith(str(executable) + " ")
        or line.strip().split(None, 1)[-1] == str(executable)
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=pathlib.Path)
    parser.add_argument("output", type=pathlib.Path)
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--plan", choices=["scroll", "stream", "streamScroll", "open", "lifecycle", "scrub", "sessions", "sessionsResize"], default="scroll")
    parser.add_argument("--turns", type=int, default=300)
    parser.add_argument("--timeout", type=float, default=300)
    parser.add_argument("--container", choices=["list", "custom"], default="custom")
    parser.add_argument("--scrub-period", type=float, default=0)
    parser.add_argument("--paginated", action="store_true")
    parser.add_argument("--float-window", action="store_true", help="Float only the launched app window in AeroSpace for resize testing.")
    args = parser.parse_args()
    if args.plan == "scrub" and args.scrub_period <= 0:
        parser.error("The scrub plan requires a positive --scrub-period.")
    if args.runs < 1 or args.timeout <= 0 or args.turns < 0:
        parser.error("Runs and timeout must be positive; turns must be nonnegative.")
    if args.float_window and not shutil.which("aerospace"):
        parser.error("--float-window requires the AeroSpace CLI.")
    if args.float_window:
        probe = subprocess.run(["aerospace", "list-workspaces", "--all"],
                               capture_output=True, text=True, timeout=5)
        if probe.returncode:
            parser.error("--float-window requires a running AeroSpace server.")
    app = args.app.resolve()
    executable = app / "Contents/MacOS/mai"
    if not executable.is_file():
        parser.error(f"Missing executable: {executable}")
    if app_pids(executable):
        parser.error("Quit this build of mai before starting the harness.")
    if args.output.exists() and any(args.output.iterdir()):
        parser.error("Use an empty output directory to preserve existing results.")
    args.output.mkdir(parents=True, exist_ok=True)
    code_image = executable.with_name("mai.debug.dylib")
    if not code_image.is_file():
        code_image = executable
    metadata = {
        "app": str(app),
        "codeImageSHA256": hashlib.sha256(code_image.read_bytes()).hexdigest(),
        "macOS": platform.mac_ver()[0],
        "machine": subprocess.check_output(["sysctl", "-n", "hw.model"], text=True).strip(),
        "plan": args.plan,
        "container": args.container, "scrubPeriodSeconds": args.scrub_period,
        "syntheticTurns": args.turns,
        "measurement": ("prepared aligned viewport" if args.plan == "open" else
                        "session checkpoints, sampled RSS and final/peak physical footprint"
                        if args.plan in ("sessions", "sessionsResize") else
                        "display-link callback pacing, not presented FPS"),
        "paginated": args.paginated, "floatingBenchmarkWindow": args.float_window,
    }
    (args.output / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
    for run in range(1, args.runs + 1):
        log = (args.output / f"{args.plan}-{run}.log").resolve()
        if log.exists():
            parser.error(f"Refusing to overwrite {log}")
        command = ["open", "-n", "-a", str(app), "--stdout", str(log),
                   "--stderr", str(log.with_suffix(".stderr")), "--args",
                   "-ChatAutoBenchmark", args.plan,
                   "-ChatBenchmarkAnchorRow", "4800",
                   "-ChatBenchmarkPaginatedHistory", "YES" if args.paginated else "NO",
                   "-ChatBenchmarkScrubPeriod", str(args.scrub_period),
                   "-ChatBenchmarkUseList", "YES" if args.container == "list" else "NO"]
        if args.turns > 0:
            command += ["-ChatBenchmarkSyntheticTurns", str(args.turns)]
        subprocess.run(command, check=True)
        started = time.monotonic()
        woke = False
        floated = set()
        memory_samples = []
        try:
            while time.monotonic() - started < args.timeout:
                if args.float_window and time.monotonic() - started < 15:
                    launched = app_pids(executable)
                    windows = json.loads(subprocess.check_output(["aerospace", "list-windows", "--all", "--format", "%{window-id} %{app-pid}", "--json"], text=True))
                    for window in windows:
                        if window["app-pid"] in launched and window["window-id"] not in floated:
                            subprocess.run(["aerospace", "layout", "--window-id", str(window["window-id"]), "floating"], check=True)
                            floated.add(window["window-id"])
                text = log.read_text(errors="replace") if log.exists() else ""
                for marker in ("invalid measurement:", "sourceMatches=false",
                               "visible=false", "transcript warm timed out"):
                    if marker in text:
                        raise RuntimeError(f"Invalid benchmark ({marker}): {log}")
                if args.plan in ("sessions", "sessionsResize"):
                    resident = {}
                    for pid in app_pids(executable):
                        sample = subprocess.run(["ps", "-p", str(pid), "-o", "rss="], text=True, capture_output=True)
                        if sample.returncode == 0 and sample.stdout.strip():
                            resident[str(pid)] = int(sample.stdout.strip())
                    memory_samples.append({"elapsedSeconds": time.monotonic() - started,
                                           "completedCheckpoints": text.count("CHAT_BENCHMARK_RESULT "),
                                           "residentKiB": resident})
                if "\nCHAT_BENCHMARK_COMPLETE" in text:
                    reports = [json.loads(line.removeprefix("CHAT_BENCHMARK_RESULT "))
                               for line in text.splitlines()
                               if line.startswith("CHAT_BENCHMARK_RESULT ")]
                    expected = 11 if args.plan == "sessionsResize" else 5 if args.plan == "sessions" else 3 if args.plan == "scroll" else 1
                    if len(reports) != expected:
                        raise RuntimeError(f"Expected {expected} reports, got {len(reports)}: {log}")
                    if args.plan in ("open", "sessions", "sessionsResize") and any(not r.get("aligned") or not r.get("visible") for r in reports):
                        raise RuntimeError(f"Unaligned or hidden opening invalidates run: {log}")
                    if args.plan == "lifecycle" and any(not r.get("passed") for r in reports):
                        raise RuntimeError(f"Lifecycle correctness failure: {log}")
                    resident = {}
                    for pid in app_pids(executable):
                        sample = subprocess.run(["ps", "-p", str(pid), "-o", "rss="], text=True, capture_output=True)
                        if sample.returncode == 0 and sample.stdout.strip():
                            resident[str(pid)] = int(sample.stdout.strip())
                    log.with_suffix(".memory.json").write_text(json.dumps({"residentAfterMeasurementKiB": resident, "measurement": "post-run RSS, not peak or allocation count"}, indent=2) + "\n")
                    if memory_samples:
                        log.with_suffix(".memory-samples.json").write_text(json.dumps(memory_samples, indent=2) + "\n")
                        for pid in app_pids(executable):
                            footprint = subprocess.run(["vmmap", "-summary", str(pid)],
                                                       capture_output=True, text=True, timeout=30)
                            log.with_suffix(f".{pid}.vmmap.txt").write_text(
                                footprint.stdout + footprint.stderr)
                    log.with_suffix(".json").write_text(json.dumps(reports, indent=2) + "\n")
                    print(f"Completed {log}", flush=True)
                    break
                # A second LaunchServices open delivers the reopen event if
                # restored window state left the process idle with no window.
                if not woke and time.monotonic() - started > 3:
                    subprocess.run(["open", "-a", str(app)], check=True)
                    woke = True
                time.sleep(0.5)
            else:
                raise TimeoutError(f"Benchmark did not finish: {log}")
        finally:
            # Preserve samples from rejected/timeout runs too. Their logs still
            # determine validity; saving diagnostics must not make them passes.
            if memory_samples:
                log.with_suffix(".memory-samples.json").write_text(
                    json.dumps(memory_samples, indent=2) + "\n")
            # No instance existed before this launch; only stop this build.
            for pid in app_pids(executable):
                subprocess.run(["kill", "-TERM", str(pid)], check=False)
            time.sleep(1)


if __name__ == "__main__":
    main()
