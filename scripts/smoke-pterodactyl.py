"""Check the custom image under Pterodactyl-like stdin/volume/port settings."""
import json
import re
import selectors
import subprocess
import time
import urllib.request
import uuid

name='ladno-ptero-test'
subprocess.run(['docker','run','-d','-i','--name',name,'-e','SERVER_PORT=18080','-p','127.0.0.1:18080:18080','-v','ladno-ptero-test:/home/container','ladno-backend:pterodactyl'],check=True,stdout=subprocess.DEVNULL)
base='http://127.0.0.1:18080'
for _ in range(30):
    try:
        with urllib.request.urlopen(base+'/health',timeout=2) as response:
            before=json.load(response)['deviceId']
        break
    except OSError:
        time.sleep(1)
else:
    raise RuntimeError('Pterodactyl image did not start on SERVER_PORT')
attached=subprocess.Popen(['docker','attach','--sig-proxy=false',name],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,bufsize=0)
try:
    time.sleep(1)
    attached.stdin.write(b'invite\n');attached.stdin.flush()
    selector=selectors.DefaultSelector();selector.register(attached.stdout,selectors.EVENT_READ)
    output=b'';deadline=time.monotonic()+15;token=None
    while time.monotonic()<deadline:
        if selector.select(timeout=1):
            output+=attached.stdout.read(4096)
            found=re.search(rb'One-use invite \(10 minutes\): ([A-Za-z0-9_-]{43})',output)
            if found:
                token=found.group(1).decode();break
    assert token, 'Console invite command failed'
    request=urllib.request.Request(base+'/v1/enroll',data=json.dumps({'protocol':1,'deviceId':str(uuid.uuid4()),'invite':token,'name':'Pterodactyl test'}).encode(),headers={'Content-Type':'application/json'})
    with urllib.request.urlopen(request,timeout=5) as response:
        assert json.load(response)['deviceId']==before
    attached.stdin.write(b'stop\n');attached.stdin.flush()
    for _ in range(20):
        state=subprocess.check_output(['docker','inspect','-f','{{.State.Running}}',name],text=True).strip()
        if state=='false':break
        time.sleep(0.5)
    else: raise RuntimeError('Console stop did not stop container')
finally:
    attached.terminate()
    attached.wait(timeout=5)
subprocess.run(['docker','start',name],check=True,stdout=subprocess.DEVNULL)
for _ in range(30):
    try:
        with urllib.request.urlopen(base+'/health',timeout=2) as response:
            assert json.load(response)['deviceId']==before
        break
    except OSError: time.sleep(1)
else: raise RuntimeError('Persistent directory was not restored')
print('Pterodactyl image: allocation, console invite/stop and persistent data passed')
