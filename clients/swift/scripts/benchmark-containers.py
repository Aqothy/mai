#!/usr/bin/env python3
"""Run an already-built macOS app's chat benchmark in a single background launch.

Example:
  python3 clients/swift/scripts/benchmark-containers.py /path/to/mai.app .scratch/bench/after
  python3 clients/swift/scripts/benchmark-containers.py --compare .scratch/bench/before .scratch/bench/after

Runs in the background without stealing focus by default (with App Nap disabled
and latency-critical QoS). Keep at least a strip of the window unobscured on an
active display (or attach a second display), or pass --foreground.
"""

import argparse
import hashlib
import json
import pathlib
import platform
import statistics
import subprocess
import sys
import time


def app_pids(executable):
    output = subprocess.check_output(["ps", "-axo", "pid=,command="], text=True)
    return {
        int(line.strip().split(None, 1)[0])
        for line in output.splitlines()
        if line.strip().split(None, 1)[-1].startswith(str(executable) + " ")
        or line.strip().split(None, 1)[-1] == str(executable)
    }


def report_key(report):
    if "label" in report:
        return report["label"]
    if "fixture" in report:
        return f"{report['fixture']}|{report.get('mode', '')}|{report.get('chunkBytes', '')}"
    return "?"


def load_reports(root: pathlib.Path):
    by_label = {}
    for path in sorted(root.glob("*-[0-9]*.json")):
        for report in json.loads(path.read_text()):
            by_label.setdefault(report_key(report), []).append(report)
    return by_label


def med(items, key):
    values = [item[key] for item in items if key in item]
    return statistics.median(values) if values else float("nan")


def print_summary(root: pathlib.Path):
    print(f"## {root}")
    for label, reports in load_reports(root).items():
        sample = reports[0]
        kind = sample.get("measurementKind", "")
        if "averageFPS" in sample:
            extra = ""
            if "misplacedRows" in sample:
                extra += f" | misplaced {max(r.get('misplacedRows', 0) for r in reports)}"
            print(
                f"  {label:24s} n={len(reports)} fps {med(reports, 'averageFPS'):5.1f}"
                f" hitches {med(reports, 'hitchCount'):3.0f}"
                f" | main p50 {med(reports, 'p50MainThreadMilliseconds'):4.1f}"
                f" p95 {med(reports, 'p95MainThreadMilliseconds'):4.1f}"
                f" p99 {med(reports, 'p99MainThreadMilliseconds'):4.1f}"
                f" max {med(reports, 'maxMainThreadMilliseconds'):4.1f}"
                f" | >8.3 {med(reports, 'framesOver120HzBudget'):3.0f}"
                f" >16.7 {med(reports, 'framesOver60HzBudget'):2.0f}"
                f" of {med(reports, 'frameCount'):4.0f}{extra}"
            )
        elif kind == "openCheckpoint":
            print(
                f"  {label:24s} n={len(reports)}"
                f" visible {med(reports, 'visibleMilliseconds'):5.0f} ms"
                f" settled {med(reports, 'settledMilliseconds'):5.0f} ms"
                f" | footprint {med(reports, 'footprintMB'):5.1f} MB"
                f" (peak {med(reports, 'peakFootprintMB'):5.1f} MB, RSS {med(reports, 'residentMB'):5.0f} MB)"
            )
        elif kind == "memoryCheckpoint":
            print(
                f"  {label:24s} n={len(reports)}"
                f" footprint {med(reports, 'footprintMB'):5.1f} MB"
                f" (peak {med(reports, 'peakFootprintMB'):5.1f} MB, RSS {med(reports, 'residentMB'):5.0f} MB)"
            )
        elif "fixture" in sample:
            mode = sample.get("mode", "")
            if mode == "one-shot parse":
                print(
                    f"  {sample['fixture']:24s} one-shot {med(reports, 'totalMilliseconds'):5.1f} ms"
                    f" ({med(reports, 'mebibytesPerSecond'):5.1f} MiB/s)"
                )
            else:
                print(
                    f"  {sample['fixture']:24s} {mode:17s} chunk={sample.get('chunkBytes')}"
                    f" p50 {med(reports, 'medianMilliseconds'):4.2f}"
                    f" tail {med(reports, 'lastTenthMedianMilliseconds'):4.2f}"
                    f" max {med(reports, 'maxMilliseconds'):5.2f} ms"
                )


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("app", nargs="?", type=pathlib.Path)
    parser.add_argument("output", nargs="?", type=pathlib.Path)
    parser.add_argument("--compare", nargs="+", type=pathlib.Path, help="Print side-by-side summaries for result dirs and exit.")
    parser.add_argument("--plan", choices=["suite", "stream", "markdown", "giant", "extreme", "bare-resize"], default="suite")
    parser.add_argument("--runs", type=int, default=1)
    parser.add_argument("--turns", type=int, default=1000)
    parser.add_argument("--timeout", type=float, default=180)
    parser.add_argument("--engine", choices=["new", "legacy"], default="new")
    parser.add_argument("--foreground", action="store_true", help="Activate and bring the benchmark window to the front.")
    parser.add_argument("--with-chrome", action="store_true", help="Keep sidebar, composer, and toolbar.")
    parser.add_argument("--app-arg", action="append", default=[], metavar="ARG",
                        help="Extra launch argument for the app, repeatable.")
    args = parser.parse_args()

    if args.compare:
        for directory in args.compare:
            print_summary(directory)
        return

    if not args.app or not args.output:
        parser.error("Provide <app> and <output>, or use --compare <dir>...")
    if min(args.runs, args.turns, args.timeout) <= 0:
        parser.error("Runs, turns and timeout must be positive.")

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
    background = not args.foreground
    metadata = {
        "app": str(app),
        "codeImageSHA256": hashlib.sha256(code_image.read_bytes()).hexdigest(),
        "macOS": platform.mac_ver()[0],
        "machine": subprocess.check_output(["sysctl", "-n", "hw.model"], text=True).strip(),
        "plan": args.plan,
        "runs": args.runs,
        "syntheticTurns": args.turns,
        "engine": args.engine,
        "background": background,
        "transcriptOnly": not args.with_chrome,
        "appArguments": args.app_arg,
    }
    (args.output / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")

    for run in range(1, args.runs + 1):
        log = (args.output / f"{args.plan}-{run}.log").resolve()
        open_flags = ["open", "-n"] + (["-g"] if background else []) + [
            "-a", str(app),
            "--stdout", str(log),
            "--stderr", str(log.with_suffix(".stderr")),
            "--args",
            "-NSAppSleepDisabled", "YES",
            "-ChatAutoBenchmark", args.plan,
            "-ChatBenchmarkBackground", "YES" if background else "NO",
            "-ChatBenchmarkSyntheticTurns", str(args.turns),
            "-ChatBenchmarkUniqueAnswers", "YES",
            "-ChatBenchmarkTranscriptOnly", "NO" if args.with_chrome else "YES",
            "-ChatTranscriptEngine", args.engine,
            *args.app_arg,
        ]
        subprocess.run(open_flags, check=True)
        started = time.monotonic()
        woke = False
        try:
            while time.monotonic() - started < args.timeout:
                text = log.read_text(errors="replace") if log.exists() else ""
                for marker in ("invalid measurement:", "sourceMatches=false",
                               "visible=false", "transcript warm timed out"):
                    if marker in text:
                        reason = next(line for line in text.splitlines() if marker in line)
                        raise RuntimeError(
                            f"Invalid benchmark: {reason.removeprefix('CHAT_BENCHMARK_TRACE ')} ({log})")
                if "\nCHAT_BENCHMARK_COMPLETE" in text:
                    reports = [
                        json.loads(line.removeprefix("CHAT_BENCHMARK_RESULT "))
                        for line in text.splitlines()
                        if line.startswith("CHAT_BENCHMARK_RESULT ")
                    ]
                    if args.plan == "suite" and len(reports) != 8:
                        raise RuntimeError(f"Expected 8 suite reports, got {len(reports)}: {log}")
                    if args.plan == "stream" and len(reports) != 1:
                        raise RuntimeError(f"Expected 1 stream report, got {len(reports)}: {log}")
                    if args.plan == "suite" and any(
                        r.get("measurementKind") == "openCheckpoint" and (not r.get("aligned") or not r.get("visible"))
                        for r in reports
                    ):
                        raise RuntimeError(f"Unaligned or hidden opening invalidates run: {log}")
                    log.with_suffix(".json").write_text(json.dumps(reports, indent=2) + "\n")
                    elapsed = time.monotonic() - started
                    print(f"Completed {log.name} in {elapsed:.1f}s", flush=True)
                    break
                if not woke and args.plan != "markdown" and time.monotonic() - started > 3 and not text:
                    reopen = ["open"] + (["-g"] if background else []) + ["-a", str(app)]
                    subprocess.run(reopen, check=True)
                    woke = True
                time.sleep(0.25)
            else:
                raise TimeoutError(f"Benchmark did not finish: {log}")
        finally:
            for pid in app_pids(executable):
                subprocess.run(["kill", "-TERM", str(pid)], check=False)
            deadline = time.monotonic() + 5
            while app_pids(executable) and time.monotonic() < deadline:
                time.sleep(0.1)

    print_summary(args.output)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"ERROR: {error}", file=sys.stderr)
        sys.exit(1)
