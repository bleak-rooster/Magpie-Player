#!/usr/bin/env bash
set -euo pipefail
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
# Round 14: the localhost stub Aurral 2.13 (dev/aurral-stub), started if not running, for the tests that use it.
export MAGPIE_AURRAL_STUB_URL="$("$(dirname "$0")/../dev/aurral-stub/start.sh")"
cd "$(dirname "$0")/../Packages/MagpieKit"
MAGPIE_IT=1 swift test --filter IT --no-parallel
