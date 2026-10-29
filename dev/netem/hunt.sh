#!/usr/bin/env bash
# Streaming crash hunt: runs NetCrashHuntTests on a simulator of your choosing, through dev/netem/badnet.py.
#   dev/netem/hunt.sh <simulator-udid> [control-file] [derived-data]
# Start the proxy first:  python3 dev/netem/badnet.py --listen 4600 --upstream 4533 --control <control-file>
# Needs the dev stack (dev/bootstrap.sh) and dev/.env.local. Localhost only.
set -euo pipefail
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd "$(dirname "$0")/../.."
sim="${1:?simulator udid}"
control="${2:-$PWD/dev/netem/badnet.json}"
dd="${3:-$HOME/Library/Developer/Xcode/DerivedData/MagpieNetDebug}"
envfile="${MAGPIE_ENV_FILE:-dev/.env.local}"
grep -q "Magpie dev stack" "$envfile" || { echo "$envfile lacks the dev-stack marker; refusing" >&2; exit 1; }
envval() { grep -E "^$1=" "$envfile" | head -1 | cut -d= -f2-; }
export TEST_RUNNER_MAGPIE_IT=1
export TEST_RUNNER_MAGPIE_IT_URL="${MAGPIE_PROXY_URL:-http://127.0.0.1:4600}"
export TEST_RUNNER_MAGPIE_IT_USER="$(envval NAVIDROME_ADMIN_USER)"
export TEST_RUNNER_MAGPIE_IT_PASSWORD="$(envval NAVIDROME_ADMIN_PASSWORD)"
export TEST_RUNNER_MAGPIE_NETEM_CONTROL="$control"
export TEST_RUNNER_MAGPIE_NETEM_FORMATS="${MAGPIE_NETEM_FORMATS:-raw,aac,opus}"
export TEST_RUNNER_MAGPIE_NETEM_ROUNDS="${MAGPIE_NETEM_ROUNDS:-1}"
export TEST_RUNNER_MAGPIE_NETEM_ALBUM="${MAGPIE_NETEM_ALBUM:-0}"
xcodebuild test-without-building -project Magpie.xcodeproj -scheme Magpie -derivedDataPath "$dd" \
  -destination "platform=iOS Simulator,id=$sim" -only-testing:MagpieUITests/NetCrashHuntTests
