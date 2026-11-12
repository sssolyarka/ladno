#!/bin/bash
# Generate a vhost; --apply explicitly installs it without replacing other sites.
set -euo pipefail
port=18080
upstream=127.0.0.1
cert=/etc/letsencrypt/live/makar.frogville.fun/fullchain.pem
key=/etc/letsencrypt/live/makar.frogville.fun/privkey.pem
output=ladno-nginx.conf
apply=0
while (($#)); do
  case "$1" in
    --port) port=${2:?}; shift 2;;
    --upstream-host) upstream=${2:?}; shift 2;;
    --cert) cert=${2:?}; shift 2;;
    --key) key=${2:?}; shift 2;;
    --output) output=${2:?}; shift 2;;
    --apply) apply=1; shift;;
    *) echo 'Use: --port N --upstream-host IPv4 --cert PATH --key PATH --output FILE [--apply]' >&2; exit 2;;
  esac
done
[[ $port =~ ^[0-9]+$ ]] && ((port>=1024 && port<=65535)) || { echo 'Invalid allocation port' >&2; exit 2; }
python3 -c 'import ipaddress,sys; ipaddress.IPv4Address(sys.argv[1])' "$upstream"
for path in "$cert" "$key"; do [[ $path =~ ^/[a-zA-Z0-9_./-]+$ ]] || { echo 'Certificate paths must be absolute and contain no spaces' >&2; exit 2; }; done
[[ ! -e $output ]] || { echo "Refusing to overwrite $output" >&2; exit 1; }
cat > "$output" <<CONF
# Only this domain; existing sites and port 80 remain unchanged.
server {
    listen 443 ssl;
    server_name makar.frogville.fun;
    ssl_certificate $cert;
    ssl_certificate_key $key;
    ssl_protocols TLSv1.2 TLSv1.3;
    client_max_body_size 8m;
    client_body_timeout 15s;
    access_log off;
    add_header Strict-Transport-Security "max-age=31536000" always;
    add_header X-Content-Type-Options nosniff always;
    location / {
        proxy_pass http://$upstream:$port;
        proxy_set_header Host \$host;
        proxy_connect_timeout 5s;
        proxy_read_timeout 30s;
        proxy_send_timeout 15s;
    }
}
CONF
if ((apply)); then
  ((EUID==0)) || { echo 'Use root for --apply' >&2; exit 1; }
  [[ -s $cert && -s $key ]] || { echo 'Certificate or key missing' >&2; exit 1; }
  available=/etc/nginx/sites-available/ladno-makar.conf
  enabled=/etc/nginx/sites-enabled/ladno-makar.conf
  [[ ! -e $available && ! -L $enabled && ! -e $enabled ]] || { echo 'Ladno vhost already exists; review it manually' >&2; exit 1; }
  curl --fail --silent --max-time 5 "http://$upstream:$port/health" >/dev/null
  install -m 0644 "$output" "$available"
  ln -s "$available" "$enabled"
  if ! nginx -t; then rm -- "$enabled" "$available"; echo 'Config rejected; existing sites were not reloaded' >&2; exit 1; fi
  if ! systemctl reload nginx; then rm -- "$enabled" "$available"; echo 'Reload failed; generated vhost removed' >&2; exit 1; fi
fi
printf 'Generated %s for makar.frogville.fun -> %s:%s\n' "$output" "$upstream" "$port"
