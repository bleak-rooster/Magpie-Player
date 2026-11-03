#!/usr/bin/env bash
set -euo pipefail
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd "$(dirname "$0")/../Packages/MagpieKit"
MAGPIE_IT=1 swift test --filter IT --no-parallel
