#!/usr/bin/env python3
"""Rank captured frames for inspection; this is not a visual-correctness oracle.

Specific to the verified 1280x900 synthetic fixture. Tracks the constant
'Working' label and compares vertical motion on opposite sides of the upper
transcript. Mismatches nominate frames for human review, not automatic failure.
"""
import argparse, json, subprocess
from pathlib import Path
import numpy as np
from PIL import Image

p=argparse.ArgumentParser(); p.add_argument('capture',type=Path); p.add_argument('output',type=Path)
p.add_argument('--require-stationary-working-label',action='store_true',
               help='Fail if the fixed-bottom fixture shows its label at multiple positions, or lacks sufficient matches.')
a=p.parse_args(); a.output.mkdir(parents=True,exist_ok=True)
meta=json.loads((a.capture/'frames.json').read_text())
times=np.array([float(f['best_effort_timestamp_time']) for f in meta['frames']])
# The reference image has already been visually inspected at this position.
reference=np.array(Image.open(a.capture/'frame-15.png').convert('L'))
template=reference[714:729,400:447].astype(np.int16)
process=subprocess.Popen(['ffmpeg','-v','error','-i',str(a.capture/'stream.mov'),'-fps_mode','passthrough','-f','rawvideo','-pix_fmt','gray','-'],stdout=subprocess.PIPE)
rows=[]; previous=None
for i,t in enumerate(times):
 raw=process.stdout.read(1280*900)
 if len(raw)!=1280*900: raise RuntimeError(f'Missing frame {i}')
 frame=np.frombuffer(raw,dtype=np.uint8).reshape(900,1280)
 patch=frame[630:785,400:447].astype(np.int16)
 views=np.lib.stride_tricks.sliding_window_view(patch,template.shape)[:,0]
 errors=np.abs(views-template).mean(axis=(1,2)); best=int(errors.argmin())
 profiles=np.stack([(frame[50:650,x1:x2]>85).mean(axis=1) for x1,x2 in [(405,690),(800,1150)]])
 row={'frame':i,'seconds':float(t),'workingY':630+best,'workingTemplateError':float(errors[best])}
 if previous is not None:
  # Compare the same old upper region against possible new vertical locations.
  # Signed shift: positive means the current content moved down.
  scores=[]
  for profile,old in zip(profiles,previous):
   shifts=range(-100,101)
   errs=np.array([np.abs(old[150:350]-profile[150+s:350+s]).mean() for s in shifts])
   j=int(errs.argmin()); scores.append({'shift':j-100,'error':float(errs[j]),'zeroError':float(errs[100])})
  row['bands']=scores
  row['motionDisagreement']=abs(scores[0]['shift']-scores[1]['shift'])
 previous=profiles
 rows.append(row)
assert process.wait()==0
intervals=np.diff(times)*1000
# Only compare close template matches; absence/transition is not a displaced label.
valid=[r for r in rows if r['seconds']>4 and r['workingTemplateError']<6]
positions={str(y):sum(r['workingY']==y for r in valid) for y in sorted({r['workingY'] for r in valid})}
all_matches=[r for r in rows if r['workingTemplateError']<6]
all_positions=sorted({r['workingY'] for r in all_matches})
stationary=len(all_matches)>len(rows)/2 and all_positions==[714]
summary={'frames':len(rows),'durationSeconds':float(times[-1]-times[0]),'effectiveCaptureHz':float((len(times)-1)/(times[-1]-times[0])),
 'captureIntervalMs':{'median':float(np.median(intervals)),'p99':float(np.percentile(intervals,99)),'maximum':float(intervals.max())},
 'workingLabelMatchedFramesAfter4Seconds':len(valid),'workingLabelYHistogram':positions,
 'stationaryCapturedLabelCheck':{'passed':stationary,'matchedFrames':len(all_matches),'yValues':all_positions},
 'scope':'Candidate generation only. Capture misses some display frames; repeated motifs can confuse motion matching.'}
(a.output/'frame-analysis.json').write_text(json.dumps({'summary':summary,'frames':rows},indent=2)+'\n')
print(json.dumps(summary,indent=2))
if a.require_stationary_working_label and not stationary:
 raise SystemExit('Captured working-label regression failed; inspect the positions and neighbouring frames.')
