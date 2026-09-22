#!/usr/bin/env python3
"""Record an already-built synthetic chat stream, cropped to its verified window.

The recording is for frame inspection, not an uninstrumented FPS benchmark.
No audio is captured. The capture stops before the owned app is closed.
"""

import argparse
import hashlib
import json
import pathlib
import signal
import subprocess
import time


def app_pids(executable):
    rows = subprocess.check_output(["ps", "-axo", "pid=,command="], text=True)
    return {int(parts[0]) for row in rows.splitlines()
            if len(parts := row.strip().split(None, 1)) == 2
            and (parts[1] == str(executable) or parts[1].startswith(str(executable) + " "))}


def window_geometry(pid):
    script = """
ObjC.import('CoreGraphics'); ObjC.import('AppKit');
var windows=ObjC.deepUnwrap(ObjC.castRefToObject($.CGWindowListCopyWindowInfo(1,0)));
var owned=windows.filter(function(w){return w.kCGWindowOwnerPID===QA_PID && w.kCGWindowLayer===0;});
owned.sort(function(a,b){return b.kCGWindowBounds.Width*b.kCGWindowBounds.Height-a.kCGWindowBounds.Width*a.kCGWindowBounds.Height;});
var screens=$.NSScreen.screens;
if(Number(screens.count)!==1 || owned.length===0) throw Error('Expected one display and a visible owned window');
JSON.stringify({windowId:owned[0].kCGWindowNumber,bounds:owned[0].kCGWindowBounds,
scale:Number(screens.objectAtIndex(0).backingScaleFactor),screen:screens.objectAtIndex(0).frame});
""".replace("QA_PID", str(pid))
    return json.loads(subprocess.check_output(["osascript", "-l", "JavaScript", "-e", script], text=True))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=pathlib.Path)
    parser.add_argument("output", type=pathlib.Path)
    parser.add_argument("--container", choices=["custom", "list"], default="custom")
    parser.add_argument("--rate", type=int, default=120)
    args = parser.parse_args()
    app = args.app.resolve()
    executable = app / "Contents/MacOS/mai"
    if not executable.is_file() or app_pids(executable):
        parser.error("Use an existing app build with no running instances.")
    if args.output.exists() and any(args.output.iterdir()):
        parser.error("Use an empty output directory.")
    if not 1 <= args.rate <= 240:
        parser.error("Capture rate must be between 1 and 240.")
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    log = out / "app.log"
    image = executable.with_name("mai.debug.dylib")
    if not image.is_file():
        parser.error("The recording scenario requires a Debug app build.")
    metadata = {"app": str(app), "codeImageSHA256": hashlib.sha256(image.read_bytes()).hexdigest(),
                "requestedCaptureHz": args.rate, "container": args.container,
                "scope": "captured frame inspection; capture overhead invalidates FPS comparisons"}
    capture = None
    metadata["completed"] = False
    try:
        subprocess.run(["open", "-n", "-a", str(app), "--stdout", str(log),
                        "--stderr", str(out / "app.stderr"), "--args", "-ChatPerformanceLab",
                        "-ChatBenchmarkSyntheticTurns", "20", "-ChatAutoBenchmark", "stream",
                        "-ChatBenchmarkUseList", "YES" if args.container == "list" else "NO",
                        "-ChatBenchmarkPaginatedHistory", "YES"], check=True)
        deadline = time.monotonic() + 90
        with (out / "capture.log").open("w") as capture_log:
            while time.monotonic() < deadline:
                text = log.read_text(errors="replace") if log.exists() else ""
                if any(marker in text for marker in ["invalid measurement:", "visible=false", "sourceMatches=false", "transcript warm timed out"]):
                    raise RuntimeError("App rejected the recording scenario; inspect app.log")
                if capture is None and "benchmark viewport verified" in text:
                    pids = app_pids(executable)
                    if len(pids) != 1:
                        raise RuntimeError("Expected exactly one owned app process")
                    geometry = window_geometry(next(iter(pids)))
                    bounds, scale = geometry["bounds"], geometry["scale"]
                    if abs(bounds["Width"] - 1280) > 1 or abs(bounds["Height"] - 900) > 1:
                        raise RuntimeError(f"Unexpected capture bounds: {bounds}")
                    x, y, w, h = [round(bounds[k] * scale) for k in ["X", "Y", "Width", "Height"]]
                    command = ["ffmpeg", "-hide_banner", "-nostdin", "-f", "avfoundation",
                               "-framerate", str(args.rate), "-capture_cursor", "0", "-pixel_format", "nv12",
                               "-probesize", "32", "-analyzeduration", "0", "-i", "Capture screen 0:none",
                               "-an", "-vf", f"crop={w}:{h}:{x}:{y},scale=1280:900",
                               "-c:v", "h264_videotoolbox", "-b:v", "40M", "-realtime", "1",
                               "-fps_mode", "passthrough", "-video_track_timescale", "120000",
                               "-t", "60", str(out / "stream.mov")]
                    metadata.update({"geometry": geometry, "captureCommand": command,
                                     "captureStartedAt": time.time()})
                    capture = subprocess.Popen(command, stdout=capture_log, stderr=subprocess.STDOUT)
                if capture is not None and capture.poll() is not None:
                    raise RuntimeError(f"Capture exited early ({capture.returncode}); inspect capture.log")
                if "\nCHAT_BENCHMARK_COMPLETE" in text:
                    if capture is None:
                        raise RuntimeError("Stream completed before recording began")
                    metadata["appCompletedAt"] = time.time()
                    metadata["completed"] = True
                    break
                time.sleep(0.05)
            else:
                raise TimeoutError("Synthetic stream did not finish")
    finally:
        if capture is not None and capture.poll() is None:
            capture.send_signal(signal.SIGINT)
            try:
                capture.wait(timeout=15)
            except subprocess.TimeoutExpired:
                capture.kill()
                capture.wait()
        if capture is not None:
            metadata["captureExitCode"] = capture.returncode
        for pid in app_pids(executable):
            subprocess.run(["kill", "-TERM", str(pid)], check=False)
        (out / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
    probe = subprocess.check_output(["ffprobe", "-v", "error", "-select_streams", "v:0",
                                     "-show_entries", "stream=width,height,avg_frame_rate,r_frame_rate,duration,nb_frames:frame=best_effort_timestamp_time,pkt_duration_time",
                                     "-of", "json", str(out / "stream.mov")], text=True)
    (out / "frames.json").write_text(probe)
    print(f"Recording complete: {out}", flush=True)


if __name__ == "__main__":
    main()
