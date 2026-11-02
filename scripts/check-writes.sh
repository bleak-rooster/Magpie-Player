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
#   Packages/MagpieKit/Sources/AurralKit/AurralClient.swift  G1 allowlist: aurral start flow
#       Round 12 Y6 (D56): Aurral's Refresh Flow, `POST /api/playlists/start/:flowId`, the one write Magpie sends to
#       Aurral; the client's allow-list (`AurralRoute`) refuses every other call. Pinned below.
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
  "Packages/MagpieKit/Sources/AurralKit/AurralClient.swift|G1 allowlist: aurral start flow"
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
      # Y5 fix I9 merge: the restart's AlbumSearch, by the restarter only (the gate allows only albums it just restarted).
      "$restarter":*'gate.send("POST", "command", body: SearchBody(name: "AlbumSearch", albumIds: rest), confinedAs: .restartSearch)'*) ;;
      *) echo "G1: queueRestartAny not exactly a queue delete with the one query: ${s%%:*}" >&2; bad=1 ;;
    esac
  done <<< "$shaped"
  grep -qF 'static let queueRemoval = "removeFromClient=true&blocklist=true&skipRedownload=true"' "$restarter" ||
    { echo "G1: $restarter: queueRemoval isn't exactly removeFromClient=true&blocklist=true&skipRedownload=true" >&2; bad=1; }
fi
if [ -z "${G1_SRC:-}" ]; then
  # Y5: track files are deleted only by Not for me (a find's files) and the MP3 rule (a kept find's recorded MP3); the
  # gate confines both (findDelete / keptLossyDelete, one rule per call).
  tf_sends=$(grep -rlE --include='*.swift' 'gate\.send\("DELETE",[[:space:]]*"trackfile' "${product[@]}" | sort -u || true)
  for f in $tf_sends; do
    case "$f" in
      Packages/MagpieKit/Sources/Requests/RequestRunner+NotForMe.swift|Packages/MagpieKit/Sources/Requests/RequestRunner+Lossless.swift) ;;
      *) echo "G1: track file delete outside Not for me and the MP3 rule: $f" >&2; bad=1 ;;
    esac
  done
  # Y5 C5 (fix I4: per call site, not per file): every check that refuses on "kept" reads `isKeptOrKeeping` (a Keep
  # under way counts). A bare `.keptAt` is allowed only at these call sites (file|text on the line):
  #   the ledger's storage (init, decoding, the record merge), the gate's confirmed-Keep rule, the Keep's commit and
  #   clean-up, the migration's legacy lock, and the Try's carry-over of the album entry (which also carries the intent).
  kept_allow=(
    "Packages/MagpieKit/Sources/LidarrKit/Ledger.swift|self.keptAt = keptAt"
    "Packages/MagpieKit/Sources/LidarrKit/Ledger.swift|forKey: .keptAt"
    "Packages/MagpieKit/Sources/LidarrKit/Ledger.swift|e.keptAt = old.keptAt"
    "Packages/MagpieKit/Sources/LidarrKit/WriteConfinement.swift|!mine.contains { \$0.keepIntentAt != nil }"
    "Packages/MagpieKit/Sources/Requests/RequestRunner+Keep.swift|{ \$0.keptAt = at }"
    "Packages/MagpieKit/Sources/Requests/RequestRunner+Keep.swift|{ \$0.findFiles = nil }"
    "Packages/MagpieKit/Sources/Requests/RequestRunner+Reconcile.swift|let lockedArtists"
    "Packages/MagpieKit/Sources/Requests/RequestRunner+Reconcile.swift|ledger.update(artistId: artistId) { \$0.keptAt = nil }"
    "Packages/MagpieKit/Sources/Requests/RequestRunner.swift|keptAt: prior?.keptAt"
  )
  kept_hits=$(grep -rnE --include='*.swift' '\.keptAt\b' "${product[@]}" | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' | cut -d: -f1,2 || true)
  for hit in $kept_hits; do
    file="${hit%%:*}" line="${hit##*:}"
    text="$(sed -n "${line}p" "$file")"
    ok=0
    for entry in "${kept_allow[@]}"; do
      [ "$file" = "${entry%%|*}" ] && case "$text" in *"${entry#*|}"*) ok=1 ;; esac
    done
    if [ "$ok" = 0 ]; then
      echo "Y5 C5: a bare .keptAt at $file:$line; use isKeptOrKeeping (refusing) or isConfirmedKept (requiring)" >&2
      bad=1
    fi
  done
fi
if [ -z "${G1_SRC:-}" ]; then
  # Round 12 Y6 (D56): Aurral. The client allows exactly five calls (GET health, playlists status, playlists jobs,
  # library lookup; POST playlists start), and nothing in the product names Aurral's dangerous routes.
  aurral="Packages/MagpieKit/Sources/AurralKit/AurralClient.swift"
  for want in 'case 1 where rest[0] == "health": .health' \
              'case 2 where rest == ["playlists", "status"]: .playlistsStatus' \
              'case 2 where rest == ["playlists", "jobs"]: .playlistsJobs' \
              'case 3 where rest[0] == "library" && rest[1] == "lookup" && MBID(String(rest[2])) != nil' \
              'case 3 where rest[0] == "playlists" && rest[1] == "start" && isPlainId(rest[2]): .startFlow' \
              'case .health, .playlistsStatus, .playlistsJobs, .libraryLookup: "GET"' \
              'case .startFlow: Self.startMethod' \
              'guard AurralRoute.isAllowed(method: method, path: path),'; do
    grep -qF -- "$want" "$aurral" || { echo "G1: $aurral: the Aurral allow-list changed (missing: $want)" >&2; bad=1; }
  done
  [ "$(grep -cE 'case [0-9] where' "$aurral")" = 5 ] || { echo "G1: $aurral: the Aurral allow-list isn't exactly five routes" >&2; bad=1; }
  # Nobody names Aurral's settings, key, discover, add or track-delete routes (the stub for tests aside).
  if grep -rnE --include='*.swift' 'api/settings|api/auth/api-key|"api/discover|api/library/tracks|api/library/artists|lidarr-import-list' \
       "${product[@]}" | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' | grep -v '^Packages/MagpieKit/Sources/MagpieTestSupport/' | grep -q .; then
    echo "G1: a forbidden Aurral route is named in product code" >&2; bad=1
  fi
  # Only the Lidarr gate and the Aurral client put an API key on a request.
  for f in $(grep -rlE --include='*.swift' 'setValue\([^)]*forHTTPHeaderField: "X-Api-Key"' "${product[@]}" | sort -u || true); do
    case "$f" in
      "$aurral"|Packages/MagpieKit/Sources/LidarrKit/WriteGate.swift) ;;
      *) echo "G1: an API-key request built outside the Lidarr gate and the Aurral client: $f" >&2; bad=1 ;;
    esac
  done
fi
[ "$bad" = 0 ] || { echo "G1 check failed: route Lidarr writes through LidarrWriteGate (or extend the allowlist in $0)" >&2; exit 1; }
echo "G1 check: no write verbs outside LidarrWriteGate in ${product[*]}${tests[*]:+ and ${tests[*]}} (allowlisted: Navidrome auth/login, dev-only IT helpers)"
