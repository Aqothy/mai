#!/usr/bin/env python3
"""Export candidates and adjacent recorded frames without resampling time."""
import argparse
import json
import subprocess
from pathlib import Path

from PIL import Image

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("analysis", type=Path)
args = parser.parse_args()
summary = json.loads((args.analysis / "summary.json").read_text())
capture = Path(summary["capture"])
candidates = summary["seamCandidates"]
indices = sorted({index + offset for index in candidates for offset in [-1, 0, 1]})
destination = args.analysis / "candidates"
destination.mkdir(exist_ok=True)
if indices:
    select = "select=" + "+".join(f"eq(n\\,{index})" for index in indices)
    subprocess.run([
        "ffmpeg", "-v", "error", "-i", str(capture / "stream.mov"), "-vf", select,
        "-fps_mode", "passthrough", "-y", str(destination / "raw-%03d.png"),
    ], check=True)
    from PIL import ImageDraw
    mapping = {index: destination / f"raw-{position + 1:03d}.png" for position, index in enumerate(indices)}
    for index in candidates:
        sheet = Image.new("RGB", (2340, 775), "white")
        draw = ImageDraw.Draw(sheet)
        for position, neighbour in enumerate([index - 1, index, index + 1]):
            with Image.open(mapping[neighbour]) as frame:
                sheet.paste(frame.crop((390, 25, 1170, 780)), (position * 780, 20))
            draw.text((position * 780 + 10, 3), f"frame {neighbour}", fill="black")
        sheet.save(destination / f"candidate-{index}.png")
    for offset in range(0, len(candidates), 6):
        subset = candidates[offset:offset + 6]
        sheet = Image.new("RGB", (1560, 775 * ((len(subset) + 1) // 2)), "white")
        for position, index in enumerate(subset):
            with Image.open(destination / f"candidate-{index}.png") as strip:
                sheet.paste(strip.crop((780, 0, 1560, 775)), ((position % 2) * 780, (position // 2) * 775))
        sheet.save(args.analysis / f"overview-{offset // 6 + 1}.png")
print(f"Exported {len(candidates)} candidates and their adjacent frames")
