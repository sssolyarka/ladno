#!/usr/bin/env bash
set -euo pipefail
# Test runners already include SQLite/OpenSSL. Avoid unrelated mirror outages.
if [[ "${1:-}" == '--checks' ]]; then
  if ldconfig -p | grep 'libsqlite3.so' >/dev/null && command -v openssl >/dev/null; then
    exit 0
  fi
  set -- libsqlite3-dev openssl
fi
# Hosted images may point at an unavailable Azure mirror. Use Ubuntu's signed
# canonical repository; do not weaken apt signature verification.
if [[ -f /etc/apt/apt-mirrors.txt ]]; then
  printf '%s\n' 'https://archive.ubuntu.com/ubuntu/' | sudo tee /etc/apt/apt-mirrors.txt >/dev/null
fi
if [[ -f /etc/apt/apt-security-mirrors.txt ]]; then
  printf '%s\n' 'https://security.ubuntu.com/ubuntu/' | sudo tee /etc/apt/apt-security-mirrors.txt >/dev/null
fi
sudo apt-get -o Acquire::Retries=1 -o Acquire::http::Timeout=20 -o Acquire::https::Timeout=20 -o APT::Update::Error-Mode=any update
sudo apt-get -o Acquire::Retries=1 -o Acquire::http::Timeout=20 -o Acquire::https::Timeout=20 install -y --no-install-recommends "$@"
