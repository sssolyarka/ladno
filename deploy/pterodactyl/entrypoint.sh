#!/bin/sh
set -eu
cd /home/container
export DATA_DIR=/home/container/data
export PORT="${SERVER_PORT:?Pterodactyl must supply SERVER_PORT}"
case "$PORT" in ''|*[!0-9]*) echo 'Invalid SERVER_PORT' >&2; exit 1;; esac
if [ "$PORT" -lt 1024 ] || [ "$PORT" -gt 65535 ]; then echo 'SERVER_PORT must be 1024..65535' >&2; exit 1; fi
umask 077
mkdir -p "$DATA_DIR"
exec /usr/local/bin/ladno-server
