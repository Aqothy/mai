import pathlib, subprocess, time
root=pathlib.Path('/tmp/maid-chat-perf')
out=root/'list-renewed-profile'
app=root/'balanced-final/mai.app'
proc=subprocess.Popen(['python3','/Users/aqothy/Code/Personal/maiD/clients/swift/scripts/benchmark-containers.py',str(app),str(out),'--container','list','--plan','scroll','--runs','1'])
try:
    while proc.poll() is None:
        log=out/'scroll-1.log'
        if log.exists() and 'benchmark start: real-fling-8000pps' in log.read_text(errors='replace'):
            lines=subprocess.check_output(['ps','-axo','pid=,command='],text=True).splitlines()
            matches=[line.strip().split(None,1)[0] for line in lines if line.strip().split(None,1)[-1].startswith(str(app.resolve()/'Contents/MacOS/mai')+' ')]
            assert len(matches)==1, matches
            subprocess.run(['sample',matches[0],'8','1','-file',str(out/'main.sample')],check=True)
            break
        time.sleep(.5)
finally:
    proc.wait(timeout=300)
