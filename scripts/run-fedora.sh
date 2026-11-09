#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "$0")/.."
if [[ -x .tooling/flutter/bin/flutter ]]; then
  exec .tooling/flutter/bin/flutter run -d linux
fi
exec flutter run -d linux
