"""Exercise the actual Compose deployment through verified HTTPS. No token output."""
import base64
import hashlib
import json
import ssl
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid

context = ssl.create_default_context(cafile=sys.argv[1])
url = 'https://localhost'

def cli(*args):
    return subprocess.check_output(['docker', 'compose', 'exec', '-T', 'backend', 'ladno-server', *args], text=True).strip()

def post(path, data, device=None, expected=200):
    headers = {'Content-Type': 'application/json'}
    if device:
        headers.update({'Authorization': 'Bearer ' + device['token'], 'x-ladno-device-id': device['id']})
    req = urllib.request.Request(url + path, data=json.dumps(data).encode(), headers=headers)
    try:
        with urllib.request.urlopen(req, context=context, timeout=20) as response:
            assert response.status == expected
            return json.load(response)
    except urllib.error.HTTPError as error:
        if error.code != expected:
            raise RuntimeError('Unexpected API status: ' + str(error.code)) from None
        return json.load(error)

for _ in range(60):
    try:
        with urllib.request.urlopen(url + '/health', context=context, timeout=2) as response:
            assert json.load(response)['ok'] is True
        break
    except (OSError, AssertionError):
        time.sleep(1)
else:
    raise RuntimeError('HTTPS health check failed')

post('/v1/pull', {'protocol': 1, 'ack': []}, expected=403)
devices=[]
for name in ['desktop', 'android']:
    device={'id': str(uuid.uuid4())}
    enrolled=post('/v1/enroll', {'protocol':1,'deviceId':device['id'],'name':name,'invite':cli('invite')})
    device['token']=enrolled['token']
    device['server']=enrolled['deviceId']
    devices.append(device)
a,b=devices
payload=b'Docker attachment test'
hash_value=hashlib.sha256(payload).hexdigest()
descriptor={'hash':hash_value,'name':'fixture.txt','size':len(payload)}
operation={'version':1,'origin':a['id'],'sequence':1,'logical':1,'objectId':str(uuid.uuid4()),'kind':'note','parents':[],'fields':{'title':'Docker test','body':'Round trip','deleted':False,'attachments':[descriptor]}}
batch={'protocol':1,'operations':[operation]}
assert post('/v1/push',batch,a)['ack']==[a['id']+':1']
assert post('/v1/push',batch,a)['ack']==[a['id']+':1']
file_data={'protocol':1,'descriptor':descriptor}
post('/v1/file/append',{**file_data,'offset':0,'data':base64.b64encode(payload).decode()},a)
post('/v1/file/finish',file_data,a)
subprocess.run(['docker','compose','restart','backend'],check=True,stdout=subprocess.DEVNULL)
for _ in range(30):
    try:
        pulled=post('/v1/pull',{'protocol':1,'ack':[]},b)
        break
    except (OSError, RuntimeError):
        time.sleep(1)
else:
    raise RuntimeError('Restart failed')
assert pulled['deviceId']==a['server']
assert pulled['batch']['operations'][0]['objectId']==operation['objectId']
assert base64.b64decode(post('/v1/file/read',{**file_data,'offset':0},b)['data'])==payload
cli('revoke',a['id'])
post('/v1/pull',{'protocol':1,'ack':[]},a,expected=403)
print('Docker HTTPS round trip, attachment, restart and revocation passed')
