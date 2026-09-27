#!/usr/bin/env python3
"""Inspect recorded 1280x900 activity fixtures, retaining every frame's results.

The fixed working-row star is tracked across thought/tool/reply phases. Its
reference crop must be visually verified first. Motion disagreement only ranks
possible seams for inspection; it cannot prove that every rendered tile agrees.
Recording misses display frames, and these results are not FPS measurements.
"""
import argparse
import csv
import gzip
import hashlib
import json
import re
import subprocess
from collections import Counter
from pathlib import Path

import numpy as np
from PIL import Image


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("capture", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    metadata = json.loads((args.capture / "metadata.json").read_text())
    assert metadata["completed"] and metadata["activity"]
    probe = json.loads((args.capture / "frames.json").read_text())
    times = np.array([float(frame["best_effort_timestamp_time"]) for frame in probe["frames"]])
    reference = np.array(Image.open(args.capture / "frame-5.png").convert("L"))
    assert reference.shape == (900, 1280)
    # Visually inspected star at x=400–410, y=753–761 in both recordings.
    template = reference[750:765, 398:414].astype(np.int16)
    assert template.max() - template.min() > 50
    movie = args.capture / "stream.mov"
    process = subprocess.Popen([
        "ffmpeg", "-v", "error", "-i", str(movie), "-fps_mode", "passthrough",
        "-f", "rawvideo", "-pix_fmt", "gray", "-",
    ], stdout=subprocess.PIPE)
    rows, candidates = [], []
    previous = None
    shifts = np.arange(-100, 101)
    try:
        for index, timestamp in enumerate(times):
            raw = process.stdout.read(1280 * 900)
            if len(raw) != 1280 * 900:
                raise RuntimeError(f"Missing frame {index}")
            frame = np.frombuffer(raw, dtype=np.uint8).reshape(900, 1280)
            patch = frame[50:790, 398:414].astype(np.int16)
            views = np.lib.stride_tricks.sliding_window_view(patch, template.shape)[:, 0]
            errors = np.abs(views - template).mean(axis=(1, 2))
            best = int(errors.argmin())
            profiles = np.stack([
                (frame[50:650, x1:x2] > 85).mean(axis=1)
                for x1, x2 in [(405, 690), (800, 1150)]
            ])
            row = {"frame": index, "seconds": float(timestamp), "starY": 50 + best,
                   "starError": float(errors[best])}
            if previous is not None:
                bands = []
                for profile, old in zip(profiles, previous):
                    windows = np.lib.stride_tricks.sliding_window_view(profile, 200)[50:251]
                    scores = np.abs(windows - old[150:350]).mean(axis=1)
                    # Identical/repeated regions prefer the smallest movement.
                    chosen = int((scores + abs(shifts) * 1e-10).argmin())
                    bands.append({"shift": int(shifts[chosen]), "error": float(scores[chosen]),
                                  "zeroError": float(scores[100])})
                row["bands"] = bands
                row["motionDisagreement"] = abs(bands[0]["shift"] - bands[1]["shift"])
                if (row["motionDisagreement"] > 2
                        and all(band["zeroError"] > 0.008 and band["error"] < 0.008 for band in bands)):
                    candidates.append(index)
            previous = profiles
            rows.append(row)
        if process.stdout.read(1):
            raise RuntimeError("Decoded more frames than the timestamp manifest")
        assert process.wait() == 0
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
    matches = [row for row in rows if row["starError"] < 3]
    histogram = Counter(row["starY"] for row in matches)
    missing_between = []
    if matches:
        missing_between = [row["frame"] for row in rows[matches[0]["frame"]:matches[-1]["frame"] + 1]
                           if row["starError"] >= 3]
    intervals = np.diff(times) * 1000
    phases = [{"name": name, "secondsFromRecorderLaunch": float(when) - metadata["captureStartedAt"]}
              for name, when in re.findall(r"activity phase=(\S+) unixTime=([\d.]+)",
                                          (args.capture / "app.log").read_text())]
    summary = {
        "capture": str(args.capture), "movieSHA256": hashlib.sha256(movie.read_bytes()).hexdigest(),
        "movieBytes": movie.stat().st_size, "codeImageSHA256": metadata["codeImageSHA256"],
        "frames": len(rows), "durationSeconds": float(times[-1] - times[0]),
        "effectiveCaptureHz": float((len(times) - 1) / (times[-1] - times[0])),
        "captureIntervalMs": {"median": float(np.median(intervals)), "p99": float(np.percentile(intervals, 99)),
                              "maximum": float(intervals.max())},
        "starMatchedFrames": len(matches), "starYHistogram": dict(sorted(histogram.items())),
        "firstStarSeconds": matches[0]["seconds"] if matches else None,
        "lastStarSeconds": matches[-1]["seconds"] if matches else None,
        "unmatchedBetweenFirstAndLast": missing_between,
        "stationaryCapturedStar": len(matches) > len(rows) / 2 and list(histogram) == [750] and not missing_between,
        "seamCandidates": candidates, "phases": phases,
        "scope": "Recorded star tracking and seam candidate ranking only. Recorder launch is an approximate phase offset; capture startup adds latency. Missing display frames and all disclosure interactions remain outside this evidence.",
    }
    (args.output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    with gzip.open(args.output / "frame-analysis.json.gz", "wt") as file:
        json.dump(rows, file, separators=(",", ":"))
    with (args.output / "star.csv").open("w") as file:
        writer = csv.writer(file)
        writer.writerow(["frame", "seconds", "starY", "starError"])
        writer.writerows([row[key] for key in ["frame", "seconds", "starY", "starError"]] for row in rows)
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
