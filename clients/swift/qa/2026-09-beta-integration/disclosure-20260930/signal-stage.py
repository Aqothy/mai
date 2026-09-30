import json,sys,time
from pathlib import Path
p=Path(sys.argv[1]);current=sys.argv[2];expected=sys.argv[3]
assert json.loads((p/'stage.json').read_text())['name']==current
(p/(current+'.input-done')).touch()
for _ in range(50):
 time.sleep(.1)
 if (p/'result.json').exists():
  result=json.loads((p/'result.json').read_text());print({k:result.get(k) for k in ['passed','renderer','sourceCharacters','error']});break
 value=json.loads((p/'stage.json').read_text())
 if value['name']==expected:
  print(value);break
else: raise SystemExit('Next stage not ready')
