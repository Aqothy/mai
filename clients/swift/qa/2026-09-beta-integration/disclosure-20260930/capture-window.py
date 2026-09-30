"""Capture each explicit window checkpoint from window-check.swift."""
import json
from pathlib import Path
import subprocess
import sys
import time

output = Path(sys.argv[1])
deadline = time.monotonic() + 900
seen = set()
while time.monotonic() < deadline:
    request = output / "capture-request.json"
    if request.exists():
        state = json.loads(request.read_text())
        name = state["name"]
        if name not in seen:
            subprocess.run(["/usr/sbin/screencapture", "-x", "-l", str(state["windowID"]), str(output / (name + ".png"))], check=True)
            (output / (name + ".done")).touch()
            seen.add(name)
            print(name, flush=True)
    if (output / "result.json").exists():
        print((output / "result.json").read_text(), flush=True)
        break
    time.sleep(0.04)
else:
    raise SystemExit("Timed out waiting for window checkpoints")
