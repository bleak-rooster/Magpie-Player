#!/usr/bin/env bash
set -euo pipefail
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
here="$(dirname "$0")"
"$here/check-writes.sh"   # G1: no write verbs outside LidarrWriteGate
"$here/check-writes-selftest.sh"   # round 12 L1: planted spellings are caught
"$here/test-packages.sh"
"$here/test-app.sh"
