#!/usr/bin/env bash
# G1 grep check: Lidarr writes only go through LidarrWriteGate.
#
# Product code (Packages/MagpieKit/Sources, which includes MagpieTestSupport, and App/) fails when anything outside
# LidarrKit/WriteGate.swift builds a request with a write verb:
#   - any `httpMethod = ...` other than "GET" or "HEAD" (a literal verb or a variable), or
#   - a "POST" / "PUT" / "DELETE" / "PATCH" literal, except as the verb of `gate.send(...)` (which is the gate).
# Test code (Packages/MagpieKit/Tests, Tests/) is scanned for the first rule only: tests name verbs all the time in
# mock stubs, but a test that builds and sets a write method on a real request must be allowlisted (security FL7).
# Comment lines are ignored.
#
# Allowlist (file relative to the repo, and a text that must appear on the 3 lines above the hit or on it):
#   Packages/MagpieKit/Sources/NavidromeKit/NavidromeClient.swift  auth/login
#       Navidrome sign-in, not Lidarr.
#   Packages/MagpieKit/Sources/MagpieTestSupport/SharedLoginTransport.swift  auth/login
#       IT helper sharing that Navidrome sign-in (H1); refuses every non-local host (H2b G0).
#   Packages/MagpieKit/Sources/ListenBrainzKit/ListenBrainzClient+Submit.swift  G1 allowlist: listenbrainz submit-listens
#       The one non-Lidarr, non-Navidrome POST: the owner's own ListenBrainz scrobbles (D31). The router (not this
#       client) enforces D29.
#   Packages/MagpieKit/Tests/RequestsTests/FindsIT.swift  G1 allowlist: devLidarr
#       Raw requests to the dev Lidarr for IT set-up and clean-up (manual import, removing the test artist), after
#       TryDevStack verified the host is local and the dev marker matches (G0). Never product code.
#   Packages/MagpieKit/Tests/MagpieCoreTests/HTTPTransportTests.swift  RedirectStub
#       A POST into a URLProtocol stub (redirect policy test); nothing leaves the process.
#   Packages/MagpieKit/Tests/MagpieCoreTests/SharedLoginTransportTests.swift  auth/login
#       A login request handed to MockTransport.
#
# G1_SRC overrides the product tree to scan and skips the others (used to check this script against a planted
# violation).
set -euo pipefail
cd "$(dirname "$0")/.."
if [ -n "${G1_SRC:-}" ]; then
  product=("$G1_SRC")
  tests=()
else
  product=(Packages/MagpieKit/Sources App)
  tests=(Packages/MagpieKit/Tests Tests)
fi
gate="Packages/MagpieKit/Sources/LidarrKit/WriteGate.swift"
[ -n "${G1_SRC:-}" ] && gate="$G1_SRC/LidarrKit/WriteGate.swift"
allow=(
  "Packages/MagpieKit/Sources/NavidromeKit/NavidromeClient.swift|auth/login"
  "Packages/MagpieKit/Sources/MagpieTestSupport/SharedLoginTransport.swift|auth/login"
  "Packages/MagpieKit/Sources/ListenBrainzKit/ListenBrainzClient+Submit.swift|G1 allowlist: listenbrainz submit-listens"
  "Packages/MagpieKit/Tests/RequestsTests/FindsIT.swift|G1 allowlist: devLidarr"
  "Packages/MagpieKit/Tests/MagpieCoreTests/HTTPTransportTests.swift|RedirectStub"
  "Packages/MagpieKit/Tests/MagpieCoreTests/SharedLoginTransportTests.swift|auth/login"
)
[ -n "${G1_SRC:-}" ] && allow=("$G1_SRC/NavidromeKit/NavidromeClient.swift|auth/login"
                               "$G1_SRC/MagpieTestSupport/SharedLoginTransport.swift|auth/login")

method_sets() {
  grep -rnE --include='*.swift' 'httpMethod[[:space:]]*=[^=]' "$@" \
    | grep -vE 'httpMethod[[:space:]]*=[[:space:]]*"(GET|HEAD)"' || true
}

hits=$(
  {
    method_sets "${product[@]}"
    grep -rniE --include='*.swift' '"(POST|PUT|DELETE|PATCH)"' "${product[@]}" | grep -vE 'gate\.send\("' || true
    [ ${#tests[@]} -eq 0 ] || method_sets "${tests[@]}"
  } | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' | grep -v "^$gate:" | cut -d: -f1,2 | sort -u
)

bad=0
for hit in $hits; do
  file="${hit%%:*}" line="${hit##*:}"
  ok=0
  for entry in "${allow[@]}"; do
    if [ "$file" = "${entry%%|*}" ] &&
       sed -n "$((line > 3 ? line - 3 : 1)),${line}p" "$file" | grep -qF "${entry##*|}"; then ok=1; fi
  done
  if [ "$ok" = 0 ]; then
    echo "G1: write verb outside LidarrWriteGate: $file:$line: $(sed -n "${line}p" "$file" | sed 's/^[[:space:]]*//')" >&2
    bad=1
  fi
done
# R17: the one queue write, DELETE /queue/{id}, is sent only with the runner's `queueRemoval` query, spelled exactly
# removeFromClient=true&blocklist=true&skipRedownload=true (the gate refuses any other shape too).
if [ -z "${G1_SRC:-}" ]; then
  queue_sends=$(grep -rnE --include='*.swift' 'gate\.send\("DELETE",[[:space:]]*"queue/' "${product[@]}" || true)
  while IFS= read -r q; do
    [ -n "$q" ] || continue
    case "$q" in
      *'?\(Self.queueRemoval)"'*) ;;
      *) echo "G1: queue delete without the one allowed query: ${q%%:*}" >&2; bad=1 ;;
    esac
  done <<< "$queue_sends"
  stall="Packages/MagpieKit/Sources/Requests/RequestRunner+Stall.swift"
  grep -qF 'static let queueRemoval = "removeFromClient=true&blocklist=true&skipRedownload=true"' "$stall" ||
    { echo "G1: $stall: queueRemoval isn't exactly removeFromClient=true&blocklist=true&skipRedownload=true" >&2; bad=1; }
  # D49 (round 12 item 6): the gate's `queueRestartAny` shape (Settings › Downloads in Lidarr restarts ANY download) is
  # named only by the screen's restarter and the runner's counted removal, only as a queue delete with the same exact
  # query, never through a variable.
  restarter="Packages/MagpieKit/Sources/Requests/DownloadsInLidarr.swift"
  shaped=$(grep -rnE --include='*.swift' 'confinedAs:' "${product[@]}" | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' |
           grep -v "^Packages/MagpieKit/Sources/LidarrKit/WriteGate.swift:" || true)
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    case "${s%%:*}" in
      "$stall"|"$restarter") ;;
      *) echo "G1: queueRestartAny named outside its two callers: ${s%%:*}" >&2; bad=1; continue ;;
    esac
    case "$s" in
      *'gate.send("DELETE", "queue/\(queueId)?\(Self.queueRemoval)", body: nil, confinedAs: .queueRestartAny)'*) ;;
      *) echo "G1: queueRestartAny not exactly a queue delete with the one query: ${s%%:*}" >&2; bad=1 ;;
    esac
  done <<< "$shaped"
  grep -qF 'static let queueRemoval = "removeFromClient=true&blocklist=true&skipRedownload=true"' "$restarter" ||
    { echo "G1: $restarter: queueRemoval isn't exactly removeFromClient=true&blocklist=true&skipRedownload=true" >&2; bad=1; }
fi
[ "$bad" = 0 ] || { echo "G1 check failed: route Lidarr writes through LidarrWriteGate (or extend the allowlist in $0)" >&2; exit 1; }
echo "G1 check: no write verbs outside LidarrWriteGate in ${product[*]}${tests[*]:+ and ${tests[*]}} (allowlisted: Navidrome auth/login, dev-only IT helpers)"
