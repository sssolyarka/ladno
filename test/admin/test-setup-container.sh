#!/bin/bash
# Destructive fixture setup is allowed ONLY in a disposable test container.
set -euo pipefail
[[ ${LADNO_SETUP_TEST_CONTAINER:-} == 1 && -f /.dockerenv ]] || { echo 'Disposable Docker fixture only' >&2; exit 1; }
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends curl ca-certificates python3 nginx openssl >/dev/null
mkdir -p /tmp/ladno-test-bin /tmp/ladno-fixtures
cat > /tmp/ladno-test-bin/docker <<'MOCK'
#!/bin/sh
case "$1" in info|build) printf '%s\n' "$*" >> /tmp/ladno-docker-calls;; *) exit 1;; esac
MOCK
cat > /tmp/ladno-test-bin/systemctl <<'MOCK'
#!/bin/sh
[ "$1" = reload ] && [ "$2" = nginx ] || exit 1
exec /usr/sbin/nginx -s reload
MOCK
chmod +x /tmp/ladno-test-bin/*
export PATH="/tmp/ladno-test-bin:$PATH"
bash /work/deploy/admin/setup-ladno.sh prepare --dir /opt/ladno-test
[[ -s /opt/ladno-test/deploy/pterodactyl/egg-ladno.json ]]
grep -q 'ladno-backend:pterodactyl' /tmp/ladno-docker-calls
if bash /work/deploy/admin/setup-ladno.sh prepare --dir /opt/ladno-test; then echo 'Existing directory was unexpectedly accepted' >&2; exit 1; fi
bash /work/deploy/admin/setup-ladno.sh build --dir /opt/ladno-test
cat > /tmp/ladno-fixtures/health.py <<'PY'
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != '/health':
            self.send_error(404); return
        body=json.dumps({'ok':True,'protocol':1,'deviceId':'80b1251b-10be-4fa4-9737-6a5c4c25f3ab'}).encode()
        self.send_response(200); self.send_header('Content-Type','application/json'); self.send_header('Content-Length',str(len(body))); self.end_headers(); self.wfile.write(body)
    def log_message(self, *args): pass
HTTPServer(('127.0.0.1',18080),Handler).serve_forever()
PY
python3 /tmp/ladno-fixtures/health.py &
fixture_pid=$!
trap 'kill "$fixture_pid" 2>/dev/null || true; nginx -s quit 2>/dev/null || true' EXIT
for _ in {1..30}; do if curl --noproxy '*' --fail --silent http://127.0.0.1:18080/health >/dev/null; then break; fi; sleep .1; done
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=makar.frogville.fun -addext subjectAltName=DNS:makar.frogville.fun -addext basicConstraints=critical,CA:TRUE -keyout /tmp/ladno-fixtures/privkey.pem -out /tmp/ladno-fixtures/fullchain.pem >/dev/null 2>&1
cat > /etc/nginx/sites-enabled/unchanged-test.conf <<'CONF'
server {
  listen 80;
  server_name existing.fixture;
  location / { return 200 'existing-service'; }
}
CONF
existing_hash=$(sha256sum /etc/nginx/sites-enabled/unchanged-test.conf)
nginx
bash /work/deploy/admin/setup-ladno.sh proxy --dir /opt/ladno-test --port 18080 --cert /tmp/ladno-fixtures/fullchain.pem --key /tmp/ladno-fixtures/privkey.pem
[[ $(sha256sum /etc/nginx/sites-enabled/unchanged-test.conf) == "$existing_hash" ]]
[[ $(curl --noproxy '*' --silent -H 'Host: existing.fixture' http://127.0.0.1/) == existing-service ]]
printf '\n127.0.0.1 makar.frogville.fun\n' >> /etc/hosts
export CURL_CA_BUNDLE=/tmp/ladno-fixtures/fullchain.pem
export NO_PROXY=127.0.0.1,localhost,makar.frogville.fun
sleep .3
bash /work/deploy/admin/setup-ladno.sh check --port 18080
vhost_hash=$(sha256sum /etc/nginx/sites-available/ladno-makar.conf)
if bash /work/deploy/admin/setup-ladno.sh proxy --dir /opt/ladno-test --port 18080 --cert /tmp/ladno-fixtures/fullchain.pem --key /tmp/ladno-fixtures/privkey.pem; then echo 'Duplicate vhost was unexpectedly accepted' >&2; exit 1; fi
[[ $(sha256sum /etc/nginx/sites-available/ladno-makar.conf) == "$vhost_hash" ]]
printf '%s\n' 'Admin setup: pinned download, image command, real Nginx HTTPS, existing site and duplicate protection passed'
