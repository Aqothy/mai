#!/usr/bin/env python3
"""Run an already-built macOS app's chat benchmark; never builds the app.

Example: python3 scripts/benchmark-chat.py /path/to/mai.app results/before --runs 3
Keep the window visible and avoid other CPU/GPU workloads during measurement.
"""

import argparse
import hashlib
import json
import pathlib
import platform
import subprocess
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
    parser.add_argument("--plan", choices=["scroll", "stream", "streamScroll"], default="scroll")
    parser.add_argument("--turns", type=int, default=300)
    parser.add_argument("--timeout", type=float, default=300)
    parser.add_argument("--container", choices=["list", "table", "custom"], default="list")
    parser.add_argument("--prewarm", action="store_true")
    parser.add_argument("--scrub-period", type=float, default=0)
    args = parser.parse_args()
    if args.runs < 1 or args.timeout <= 0 or args.turns < 0:
        parser.error("Runs and timeout must be positive; turns must be nonnegative.")
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
        "container": args.container, "scheduledPrewarm": args.prewarm, "scrubPeriodSeconds": args.scrub_period,
        "syntheticTurns": args.turns if args.plan == "scroll" else None,
        "measurement": "display-link callback pacing, not presented FPS",
    }
    (args.output / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
    for run in range(1, args.runs + 1):
        log = (args.output / f"{args.plan}-{run}.log").resolve()
        if log.exists():
            parser.error(f"Refusing to overwrite {log}")
        command = ["open", "-n", "-a", str(app), "--stdout", str(log),
                   "--stderr", str(log.with_suffix(".stderr")), "--args",
                   "-ChatPerformanceLab", "-ChatAutoBenchmark", args.plan,
                   "-ChatBenchmarkAnchorRow", "4800",
                   "-ChatBenchmarkScrubPeriod", str(args.scrub_period),
                   "-ChatScheduledPrewarmExperiment", "YES" if args.prewarm else "NO",
                   "-ChatNativeTableExperiment", "YES" if args.container != "list" else "NO",
                   "-ChatCustomVirtualizationExperiment", "YES" if args.container == "custom" else "NO"]
        if args.plan == "scroll" and args.turns > 0:
            command += ["-ChatBenchmarkSyntheticTurns", str(args.turns)]
        subprocess.run(command, check=True)
        started = time.monotonic()
        woke = False
        try:
            while time.monotonic() - started < args.timeout:
                text = log.read_text(errors="replace") if log.exists() else ""
                if "\nCHAT_BENCHMARK_COMPLETE" in text:
                    reports = [json.loads(line.removeprefix("CHAT_BENCHMARK_RESULT "))
                               for line in text.splitlines()
                               if line.startswith("CHAT_BENCHMARK_RESULT ")]
                    expected = 3 if args.plan == "scroll" else 1
                    if len(reports) != expected:
                        raise RuntimeError(f"Expected {expected} reports, got {len(reports)}: {log}")
                    if "visible=false" in text:
                        raise RuntimeError(f"Occluded window invalidates run: {log}")
                    if "transcript warm timed out" in text:
                        raise RuntimeError(f"Unprepared transcript invalidates run: {log}")
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
            # No instance existed before this launch; only stop this build.
            for pid in app_pids(executable):
                subprocess.run(["kill", "-TERM", str(pid)], check=False)
            time.sleep(1)


if __name__ == "__main__":
    main()
