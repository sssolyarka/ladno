#!/usr/bin/env bash
set -euo pipefail
# Test runners already include SQLite/OpenSSL. Avoid unrelated mirror outages.
if [[ "${1:-}" == '--checks' ]]; then
  if ldconfig -p | grep 'libsqlite3.so' >/dev/null && command -v openssl >/dev/null; then
    exit 0
  fi
  set -- libsqlite3-dev openssl
fi
# Use signed Ubuntu metadata from a reachable HTTPS mirror. The canonical
# endpoint can be unavailable on a hosted runner; Kernel.org mirrors Ubuntu.
source /etc/os-release
selected_mirror=''
for candidate in 'https://archive.ubuntu.com/ubuntu/' 'https://mirrors.edge.kernel.org/ubuntu/'; do
  if curl --fail --silent --show-error --connect-timeout 5 --max-time 12 --output /dev/null "${candidate}dists/${VERSION_CODENAME}/InRelease"; then
    selected_mirror="$candidate"
    break
  fi
done
if [[ -z "$selected_mirror" ]]; then
  echo 'No Ubuntu package mirror is reachable.' >&2
  exit 1
fi
for mirror_list in /etc/apt/apt-mirrors.txt /etc/apt/apt-security-mirrors.txt; do
  if [[ -f "$mirror_list" ]]; then
    printf '%s\n' "$selected_mirror" | sudo tee "$mirror_list" >/dev/null
  fi
done
sudo apt-get -o Acquire::Retries=1 -o Acquire::http::Timeout=20 -o Acquire::https::Timeout=20 -o APT::Update::Error-Mode=any update
sudo apt-get -o Acquire::Retries=1 -o Acquire::http::Timeout=20 -o Acquire::https::Timeout=20 install -y --no-install-recommends "$@"
