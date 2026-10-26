#!/usr/bin/env bash
set -euo pipefail
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd "$(dirname "$0")/.."

# MAGPIE_IT=1: hand the dev-stack address and credentials to the UI tests (xcodebuild passes
# TEST_RUNNER_-prefixed variables to the test runner without the prefix). Guard G0: the file must
# carry the dev-stack marker and point at localhost. Credentials stay in dev/.env.local (git-ignored).
if [ "${MAGPIE_IT:-}" = "1" ]; then
  envfile=dev/.env.local
  [ -f "$envfile" ] || { echo "MAGPIE_IT=1 needs $envfile (run dev/bootstrap.sh)" >&2; exit 1; }
  grep -q "Magpie dev stack" "$envfile" || { echo "$envfile lacks the dev-stack marker; refusing" >&2; exit 1; }
  envval() { grep -E "^$1=" "$envfile" | head -1 | cut -d= -f2-; }
  it_url="$(envval NAVIDROME_URL)"
  case "$it_url" in
    http://127.0.0.1:*|http://localhost:*|https://127.0.0.1:*|https://localhost:*) ;;
    *) echo "NAVIDROME_URL ($it_url) is not local; refusing" >&2; exit 1 ;;
  esac
  export TEST_RUNNER_MAGPIE_IT=1
  export TEST_RUNNER_MAGPIE_IT_URL="$it_url"
  export TEST_RUNNER_MAGPIE_IT_USER="$(envval NAVIDROME_ADMIN_USER)"
  export TEST_RUNNER_MAGPIE_IT_PASSWORD="$(envval NAVIDROME_ADMIN_PASSWORD)"
  lidarr_url="$(envval LIDARR_URL)"
  case "$lidarr_url" in
    http://127.0.0.1:*|http://localhost:*|https://127.0.0.1:*|https://localhost:*)
      export TEST_RUNNER_MAGPIE_IT_LIDARR_URL="$lidarr_url"
      export TEST_RUNNER_MAGPIE_IT_LIDARR_KEY="$(envval LIDARR_API_KEY)" ;;
    "") ;;
    *) echo "LIDARR_URL ($lidarr_url) is not local; refusing" >&2; exit 1 ;;
  esac
fi

xcodegen generate
xcodebuild test -project Magpie.xcodeproj -scheme Magpie -destination 'platform=iOS Simulator,name=iPhone 18 Pro,OS=27.0' -quiet
