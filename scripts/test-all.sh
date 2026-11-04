#!/usr/bin/env bash
set -euo pipefail
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
here="$(dirname "$0")"
"$here/check-writes.sh"   # G1: no write verbs outside LidarrWriteGate
"$here/check-writes-selftest.sh"   # round 12 L1: planted spellings are caught
"$here/test-packages.sh"
"$here/test-app.sh"
# B1 (D120): the optimised builds too; a Release-only miscompile shipped in build 14.
"$here/test-packages.sh" --release
"$here/test-app.sh" --release
