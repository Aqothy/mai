#!/usr/bin/env python3
"""Record only the explicitly owned window announced by capture-snippet.swift."""
import argparse
import importlib.util
import json
import pathlib
import signal
import subprocess
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('output', type=pathlib.Path)
args = parser.parse_args()
out = args.output.resolve()
out.mkdir(parents=True, exist_ok=True)
if any(out.iterdir()):
    parser.error('Use an empty output directory')
spec = importlib.util.spec_from_file_location('recorder', pathlib.Path(__file__).resolve().parents[3] / 'scripts/record-chat-stream.py')
recorder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(recorder)

def wait_for(name, seconds):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if (out / 'failure.json').exists():
            raise RuntimeError((out / 'failure.json').read_text())
        if (out / name).exists():
            return
        time.sleep(.05)
    raise TimeoutError(name + ' did not arrive')

capture = None
metadata = {'completed': False, 'scope': 'Actual owned-window sampled frame inspection, not presented FPS'}
try:
    wait_for('ready.json', 180)
    ready = json.loads((out / 'ready.json').read_text())
    geometry = recorder.window_geometry(ready['pid'], ready['windowID'])
    bounds, scale = geometry['bounds'], geometry['scale']
    if any(abs(bounds[key] - ready[key.lower()]) > 1 for key in ['Width', 'Height']):
        raise RuntimeError('Window bounds differ from snippet')
    x, y, width, height = [round(bounds[key] * scale) for key in ['X', 'Y', 'Width', 'Height']]
    w, h = round(bounds['Width']), round(bounds['Height'])
    if x < 0 or y < 0 or width <= 0 or height <= 0:
        raise RuntimeError('Invalid owned window bounds')
    command = ['ffmpeg', '-hide_banner', '-nostdin', '-f', 'avfoundation', '-framerate', '120',
               '-capture_cursor', '0', '-pixel_format', 'nv12', '-probesize', '32', '-analyzeduration', '0',
               '-i', 'Capture screen 0:none', '-an', '-vf', f'crop={width}:{height}:{x}:{y},scale={w}:{h}',
               '-c:v', 'h264_videotoolbox', '-b:v', '40M', '-realtime', '1', '-fps_mode', 'passthrough',
               '-video_track_timescale', '120000', '-t', '75', str(out / 'stream.mov')]
    metadata.update({'ready': ready, 'geometry': geometry, 'command': command, 'captureStartedAt': time.time()})
    with (out / 'capture.log').open('w') as log:
        capture = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT)
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            if capture.poll() is not None:
                raise RuntimeError('Capture exited before recording')
            if 'frame=' in (out / 'capture.log').read_text(errors='replace'):
                break
            time.sleep(.05)
        else:
            raise TimeoutError('Capture did not produce frames')
        metadata['recordingMarkerAt'] = time.time()
        (out / 'recording').touch()
        wait_for('done.json', 65)
        result = json.loads((out / 'done.json').read_text())
        if not all(result[key] for key in ['completed', 'sourceMatches', 'visible', 'unchangedFrame']):
            raise RuntimeError('Snippet validation failed')
        metadata['result'] = result
        time.sleep(.5)
        capture.send_signal(signal.SIGINT)
        capture.wait(timeout=15)
        metadata['captureStoppedAt'] = time.time()
    probe = subprocess.check_output(['ffprobe', '-v', 'error', '-select_streams', 'v:0', '-show_entries',
                'stream=width,height,avg_frame_rate,r_frame_rate,duration,nb_frames:frame=best_effort_timestamp_time,pkt_duration_time',
                '-of', 'json', str(out / 'stream.mov')], text=True)
    (out / 'frames.json').write_text(probe)
    if len(json.loads(probe).get('frames', [])) < 100:
        raise RuntimeError('Insufficient capture frames')
    metadata['completed'] = True
    print('PASS: owned-window capture ' + str(out), flush=True)
except Exception as error:
    metadata['failure'] = str(error)
    raise
finally:
    if capture is not None and capture.poll() is None:
        capture.send_signal(signal.SIGINT)
        try:
            capture.wait(timeout=15)
        except subprocess.TimeoutExpired:
            capture.kill()
            capture.wait()
    metadata['captureExitCode'] = capture.returncode if capture else None
    (out / 'metadata.json').write_text(json.dumps(metadata, indent=2) + '\n')
    (out / 'captured').touch()
