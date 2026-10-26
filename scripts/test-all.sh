#!/usr/bin/env bash
set -euo pipefail
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
here="$(dirname "$0")"
"$here/test-packages.sh"
"$here/test-app.sh"
