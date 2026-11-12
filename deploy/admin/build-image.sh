#!/bin/bash
set -euo pipefail
cd -- "$(dirname -- "$0")/../.."
command -v docker >/dev/null || { echo 'Docker must already be installed by the node administrator' >&2; exit 1; }
docker build -f deploy/pterodactyl/Dockerfile -t ladno-backend:pterodactyl .
printf '%s\n' 'Image built on this Wings node. Import deploy/pterodactyl/egg-ladno.json in the panel.'
