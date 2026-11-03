#!/usr/bin/env bash
set -euo pipefail
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd "$(dirname "$0")/../Packages/MagpieKit"
if [ "${MAGPIE_IT:-}" = "1" ]; then
  # Dev-stack integration suites share test artists on the one dev Lidarr: run them one at a time,
  # after the rest of the package tests (which may run in parallel).
  swift test --skip 'IT$|IT/'
  swift test --filter 'IT$|IT/' --no-parallel
else
  swift test
fi
