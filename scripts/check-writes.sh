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
#       Aurral's data; the client's allow-list (`AurralRoute`) refuses every other call. Pinned below.
#   Packages/MagpieKit/Sources/AurralKit/AurralClient.swift  G1 allowlist: aurral session
#       Round 13 (D70): Aurral's `POST /api/auth/login` and `POST /api/auth/logout` (Magpie signs in as a user; they
#       change only Aurral's own sessions). Pinned below.
#   Packages/MagpieKit/Sources/AurralKit/AurralClient.swift  G1 allowlist: aurral discover writes
#       Round 14 A1 (D82): Add flow (`POST /api/discover/editorial/:id/library`), Not for me
#       (`POST /api/discover/feedback`), Download songs (`POST /api/playlists/flows/:flowId/download`) and Retry a song
#       (`POST /api/playlists/shared-playlists/:playlistId/tracks/:jobId/research`), each only on the owner's tap.
#       Pinned below.
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
  "Packages/MagpieKit/Sources/AurralKit/AurralClient.swift|G1 allowlist: aurral session"
  "Packages/MagpieKit/Sources/AurralKit/AurralClient.swift|G1 allowlist: aurral discover writes"
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
      # Round 13 item 6 (D63): another app's download, only by the restarter, the flag a literal `true` (the restarter
      # sets it only when its caller passed `allowForeign`, which only the flagged confirmation does; pinned below).
      "$restarter":*'gate.send("DELETE", "queue/\(queueId)?\(Self.queueRemoval)", body: nil, confinedAs: .queueRestartAny, allowForeign: true)') ;;
      # Y5 fix I9 merge: the restart's AlbumSearch, by the restarter only (the gate allows only albums it just restarted).
      "$restarter":*'gate.send("POST", "command", body: SearchBody(name: "AlbumSearch", albumIds: rest), confinedAs: .restartSearch)'*) ;;
      *) echo "G1: queueRestartAny not exactly a queue delete with the one query: ${s%%:*}" >&2; bad=1 ;;
    esac
  done <<< "$shaped"
  grep -qF 'static let queueRemoval = "removeFromClient=true&blocklist=true&skipRedownload=true"' "$restarter" ||
    { echo "G1: $restarter: queueRemoval isn't exactly removeFromClient=true&blocklist=true&skipRedownload=true" >&2; bad=1; }
  # Round 13 item 6 (D63; Z4 review I1): every `allowForeign:` / `includeForeign:` ARGUMENT in product code, whatever
  # its value (a literal, a variable, an expression), must be one of these exact lines, each exactly once: the screen's
  # flagged confirmation and Restart all's second button (the only places it's turned on), the lines that pass it on
  # (screen → restarter → gate) and the gate's own. Declarations (`allowForeign: Bool`) don't count. And only the
  # screen makes a restarter or a screen state, or calls restart/restartAll on them.
  view="App/Screens/Settings/LidarrDownloadsView.swift"
  lk="Packages/MagpieKit/Sources/LidarrKit"
  flagged=$(grep -rnE --include='*.swift' '(allowForeign|includeForeign):' "${product[@]}" |
            grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' |
            perl -ne 'my ($f, $n, $t) = /^([^:]+):(\d+):(.*)$/ or next; (my $u = $t) =~ s/(allowForeign|includeForeign):\s*Bool//g;
                      next unless $u =~ /(allowForeign|includeForeign):/; $t =~ s/^\s+|\s+$//g; print "$f|$t\n"' || true)
  allowed_flag_lines=(
    "$view|Task { await screen.restart([row], model: model, allowForeign: true) }"
    "$view|Task { await screen.restartAll(rows, model: model, includeForeign: true) }"
    "$view|message = LidarrDownloadsCopy.summary([await restarter.restart(row, allowForeign: allowForeign)])"
    "$view|message = LidarrDownloadsCopy.summary(await restarter.restartAll(rows, includeForeign: includeForeign))"
    "$restarter|return await restartOne(row, allowForeign: allowForeign)"
    "$restarter|let outcome = await restartOne(row, allowForeign: includeForeign && row.foreign)"
    "$restarter|"'_ = try await gate.send("DELETE", "queue/\(queueId)?\(Self.queueRemoval)", body: nil, confinedAs: .queueRestartAny, allowForeign: true)'
    "$lk/WriteGate.swift|try await send(method, path, body: body, shape: shape, allowForeign: allowForeign)"
    "$lk/WriteGate.swift|confined = .queueRestartAny(id, allowForeign: allowForeign)"
    "$lk/WriteConfinement.swift|return await Self.queueRestartAny(id, allowForeign: allowForeign, lidarr: lidarr)"
  )
  seen_flag_lines=""
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    ok=0
    for a in "${allowed_flag_lines[@]}"; do [ "$s" = "$a" ] && ok=1 && break; done
    if [ "$ok" = 0 ]; then
      echo "G1: allowForeign/includeForeign passed outside its pinned lines: ${s%%|*}" >&2; bad=1
    elif grep -qxF -- "$s" <<< "$seen_flag_lines"; then
      echo "G1: a pinned allowForeign/includeForeign line appears twice: ${s%%|*}" >&2; bad=1
    else
      seen_flag_lines+="$s"$'\n'
    fi
  done <<< "$flagged"
  callers=$(grep -rnE --include='*.swift' '(restarter|screen)\.(restart|restartAll)\(|LidarrDownloadRestarter\(|LidarrDownloadsScreen\(' \
              "${product[@]}" | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' | grep -v "^$view:" || true)
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    echo "G1: the restarter is made or called outside Downloads in Lidarr's screen: ${s%%:*}" >&2; bad=1
  done <<< "$callers"
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
  # Round 12 Y6 (D56), round 13 (D70), round 14 A1 (D81): Aurral. The client allows exactly the calls below, each its
  # own `case N where` line (25 routes: the round-12/13 seven plus round 14's 2.13 reads and four writes), and nothing
  # in the product names Aurral's dangerous routes.
  aurral="Packages/MagpieKit/Sources/AurralKit/AurralClient.swift"
  aurral_discover="Packages/MagpieKit/Sources/AurralKit/AurralClient+Discover.swift"
  preview_resolver="Packages/MagpieKit/Sources/AurralKit/PreviewResolver.swift"
  for want in 'case 1 where rest[0] == "health": .health' \
              'case 2 where rest == ["playlists", "status"]: .playlistsStatus' \
              'case 2 where rest == ["playlists", "jobs"]: .playlistsJobs' \
              'case 3 where rest[0] == "library" && rest[1] == "lookup" && MBID(String(rest[2])) != nil' \
              'case 3 where rest[0] == "playlists" && rest[1] == "start" && isPlainId(rest[2]): .startFlow' \
              'case .health, .playlistsStatus, .playlistsJobs, .libraryLookup: "GET"' \
              'case .startFlow: Self.startMethod' \
              'case 2 where rest == ["auth", "login"]: .login' \
              'case 2 where rest == ["auth", "logout"]: .logout' \
              'case .login, .logout: Self.sessionMethod' \
              'static let sessionMethod = "POST"' \
              'case .health, .login, .deezerPreview: false' \
              'case 2 where rest == ["health", "bootstrap"]: .bootstrap' \
              'case 2 where rest == ["auth", "me"]: .authMe' \
              'case 1 where rest[0] == "discover": .recommendations' \
              'case 2 where rest == ["discover", "trending"]: .trending' \
              'case 4 where rest[0] == "discover" && rest[1] == "trending" && rest[2] == "genres" && isDigits(rest[3], max: 6): .trendingGenre' \
              'case 2 where rest == ["discover", "editorial"]: .editorialShelf' \
              'case 3 where rest == ["discover", "editorial", "links"]: .editorialLinks' \
              'case 3 where rest[0] == "discover" && rest[1] == "editorial" && isDigits(rest[2], max: 20): .editorialPlaylist' \
              'case 4 where rest[0] == "discover" && rest[1] == "editorial" && isDigits(rest[2], max: 20) && rest[3] == "library": .editorialAdd' \
              'case 2 where rest == ["discover", "feedback"]: .discoverFeedback' \
              'case 3 where rest[0] == "artists" && isMBID(rest[1]) && rest[2] == "preview": .artistPreview' \
              'case 4 where rest[0] == "artists" && rest[1] == "release-group" && isMBID(rest[2]) && rest[3] == "tracks": .releaseGroupTracks' \
              'case 1 where rest[0] == "search": .search' \
              'case 2 where rest == ["search", "unified"]: .searchUnified' \
              'case 3 where rest[0] == "playlists" && rest[1] == "jobs" && isPlainId(rest[2]): .playlistJobsById' \
              'case 4 where rest[0] == "playlists" && rest[1] == "flows" && isPlainId(rest[2]) && rest[3] == "download": .flowDownload' \
              'case 6 where rest[0] == "playlists" && rest[1] == "shared-playlists" && isPlainId(rest[2]) && rest[3] == "tracks"' \
              'case 3 where rest[0] == "deezer" && rest[1] == "preview" && isPreviewFile(rest[2]): .deezerPreview' \
              'case .editorialAdd, .discoverFeedback, .flowDownload, .trackResearch: Self.discoverWriteMethod' \
              'static let discoverWriteMethod = "POST"' \
              'guard AurralRoute.isAllowed(method: method, path: path),' \
              'AurralRoute.isAllowed(method: method, path: path, query: query),'; do
    grep -qF -- "$want" "$aurral" || { echo "G1: $aurral: the Aurral allow-list changed (missing: $want)" >&2; bad=1; }
  done
  [ "$(grep -cE 'case [0-9] where' "$aurral")" = 25 ] || { echo "G1: $aurral: the Aurral allow-list isn't exactly 25 routes" >&2; bad=1; }
  # Fix M1: the verb, token and query-name switches are pinned whole (each read GET, only the seven writes POST, only
  # health, login and the preview without the token, the six routes with queries and exactly their names), and the
  # trackResearch route's continuation line too.
  aurral_block() {   # the body of `<decl> {` up to its closing brace at the same indentation
    awk -v decl="$1" 'index($0, decl) && !on { on = 1; match($0, /^ */); ind = RLENGTH; next }
                      on { match($0, /^ */); if (RLENGTH == ind && $0 ~ /^ *}$/) exit; print }' "$aurral"
  }
  want_method='        switch self {
        case .health, .playlistsStatus, .playlistsJobs, .libraryLookup: "GET"
        case .startFlow: Self.startMethod
        case .login, .logout: Self.sessionMethod
        case .bootstrap, .authMe, .recommendations, .trending, .trendingGenre, .editorialShelf, .editorialLinks,
             .editorialPlaylist, .artistPreview, .releaseGroupTracks, .search, .searchUnified, .playlistJobsById,
             .deezerPreview: "GET"
        case .editorialAdd, .discoverFeedback, .flowDownload, .trackResearch: Self.discoverWriteMethod
        }'
  want_authorised='        switch self {
        case .health, .login, .deezerPreview: false
        default: true
        }'
  want_queries='        switch self {
        case .recommendations: ["limit", "offset"]
        case .search: ["q", "scope", "limit", "offset"]
        case .searchUnified: ["q", "mode", "limit"]
        case .editorialLinks: ["artist", "album", "albumId"]
        case .artistPreview: ["artistName"]
        case .releaseGroupTracks: ["artistMbid", "artistName", "albumTitle", "deezerAlbumId"]
        default: []
        }'
  [ "$(aurral_block 'var method: String {')" = "$want_method" ] ||
    { echo "G1: $aurral: AurralRoute.method changed (each read GET, only the seven writes POST)" >&2; bad=1; }
  [ "$(aurral_block 'var isAuthorised: Bool {')" = "$want_authorised" ] ||
    { echo "G1: $aurral: AurralRoute.isAuthorised changed" >&2; bad=1; }
  [ "$(aurral_block 'public var queryNames: [String] {')" = "$want_queries" ] ||
    { echo "G1: $aurral: AurralRoute.queryNames changed" >&2; bad=1; }
  for want in '            && isPlainId(rest[4]) && rest[5] == "research": .trackResearch' \
              'return Set(names).count == names.count && names.allSatisfy(route.queryNames.contains)' \
              'static let startMethod = "POST"'; do
    grep -qF -- "$want" "$aurral" || { echo "G1: $aurral: the Aurral allow-list changed (missing: $want)" >&2; bad=1; }
  done
  # Round 14 A1 (D82): the four discover writes are sent only from these four exact lines (each path a literal, no
  # body but the feedback's), and Not for me's action is exactly block_artist.
  writes=$(grep -rnF --include='*.swift' 'AurralRoute.discoverWriteMethod' "${product[@]}" | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' || true)
  [ "$(printf '%s\n' "$writes" | grep -c .)" = 4 ] || { echo "G1: Aurral's discover writes aren't exactly four sends" >&2; bad=1; }
  while IFS= read -r w; do
    [ -n "$w" ] || continue
    [ "${w%%:*}" = "$aurral_discover" ] || { echo "G1: an Aurral discover write outside $aurral_discover: ${w%%:*}" >&2; bad=1; }
  done <<< "$writes"
  for want in 'try await ok(method: AurralRoute.discoverWriteMethod, path: "api/discover/editorial/" + id + "/library"))' \
              '_ = try await ok(method: AurralRoute.discoverWriteMethod, path: "api/discover/feedback", body: body)' \
              'try await ok(method: AurralRoute.discoverWriteMethod, path: "api/playlists/flows/" + flowId + "/download"))' \
              'path: "api/playlists/shared-playlists/" + playlistId + "/tracks/" + jobId + "/research"))' \
              'var o: [String: Any] = ["action": "block_artist", "artistName": name, "sourceContext": "recommended",'; do
    grep -qF -- "$want" "$aurral_discover" || { echo "G1: $aurral_discover: an Aurral write changed (missing: $want)" >&2; bad=1; }
  done
  # Round 14 A1 (D83): the preview resolver sends no login or cookie, follows no redirect, and accepts only https
  # *.dzcdn.net.
  if grep -nE 'Authorization|Bearer|X-Api-Key|Cookie"|session\.token|currentToken' "$preview_resolver" | grep -vE '^[0-9]+:[[:space:]]*//' | grep -q .; then
    echo "G1: $preview_resolver: the preview fetch names a login" >&2; bad=1
  fi
  for want in 'request.httpShouldHandleCookies = false' 'config.httpCookieStorage = nil' 'config.urlCache = nil' \
              'newRequest request: URLRequest) async -> URLRequest? { nil }' 'guard url.scheme?.lowercased() == "https"' \
              'return host == "dzcdn.net" || host.hasSuffix(".dzcdn.net")' 'case 302:'; do
    grep -qF -- "$want" "$preview_resolver" || { echo "G1: $preview_resolver: the preview's safety changed (missing: $want)" >&2; bad=1; }
  done
  # Round 13 (D70): the API key is gone. No product code sends an X-Api-Key to Aurral, and only the Aurral client sends
  # its Bearer token.
  if grep -nE 'X-Api-Key|apiKey' "$aurral" | grep -vE '^[0-9]+:[[:space:]]*//' | grep -q .; then
    echo "G1: $aurral: the Aurral client names an API key again" >&2; bad=1
  fi
  # Nobody names Aurral's settings, key, users, admin Discover, blocked-tags, add, download or track-delete routes (the
  # stub for tests aside).
  if grep -rnE --include='*.swift' 'api/settings|api/auth/api-key|api/auth/oidc|api/users|api/discover/refresh|api/discover/clear|blocked-tags|api/library/tracks|api/library/artists|api/library/albums|api/library/downloads|lidarr-import-list' \
       "${product[@]}" | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' | grep -v '^Packages/MagpieKit/Sources/MagpieTestSupport/' | grep -q .; then
    echo "G1: a forbidden Aurral route is named in product code" >&2; bad=1
  fi
  # Round 14 A4 fix round 1 (owner, 2026-11-04): the app never calls Deezer's or Apple's APIs or feeds itself;
  # everything goes through the Aurral server (the stub for tests aside; pictures and previews are A7's).
  if grep -rnE --include='*.swift' 'api\.deezer\.com|deezer\.com/|marketingtools\.apple\.com|applemarketingtools|itunes\.apple\.com|music\.apple\.com' \
       "${product[@]}" | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' | grep -v '^Packages/MagpieKit/Sources/MagpieTestSupport/' | grep -q .; then
    echo "G1: a direct Deezer or Apple API host is named in product code" >&2; bad=1
  fi
  # Round 14 A1 (D81): `api/discover` only as one of the allowed spellings, and the flow write routes only in the
  # Aurral client (the stub for tests aside).
  discover_names=$(grep -rnoE --include='*.swift' 'api/discover[A-Za-z0-9/_.?&=-]*' "${product[@]}" |
                   grep -v '^Packages/MagpieKit/Sources/MagpieTestSupport/' || true)
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    file="${d%%:*}" rest="${d#*:}" line="${rest%%:*}" name="${rest#*:}"
    sed -n "${line}p" "$file" | grep -qE '^[[:space:]]*//' && continue
    case "$name" in
      api/discover|api/discover/trending|api/discover/trending/genres/|api/discover/editorial|api/discover/editorial/|\
      api/discover/editorial/links|api/discover/feedback) ;;
      *) echo "G1: an Aurral Discover route outside the allow-list: $file:$line: $name" >&2; bad=1 ;;
    esac
  done <<< "$discover_names"
  for f in $(grep -rlE --include='*.swift' 'api/playlists/flows|shared-playlists|api/deezer/preview' "${product[@]}" | sort -u || true); do
    case "$f" in
      "$aurral_discover"|"$aurral"|Packages/MagpieKit/Sources/AurralKit/AurralPreview.swift|Packages/MagpieKit/Sources/MagpieTestSupport/*) ;;
      *) grep -nE 'api/playlists/flows|shared-playlists|api/deezer/preview' "$f" | grep -vE '^[0-9]+:[[:space:]]*//' | grep -q . &&
           { echo "G1: an Aurral flow or preview route named outside AurralKit: $f" >&2; bad=1; } ;;
    esac
  done
  # Playlist writes (X3's checked path) are sent only from the owner's playlist edits and Y6's "Use your library's
  # copy" (AppModel+DiscoverSwap.swift: the whole list rewritten in place, after X3's ownership check, never on a
  # Discover playlist). Both go through `ownPlaylist`, which refuses Discover's (Aurral's) playlists.
  for hit in $(grep -rnE --include='*.swift' '(\$0|client)\.(updatePlaylist|deletePlaylist|createPlaylist)\(' "${product[@]}" |
               grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' | cut -d: -f1 | sort -u || true); do
    case "$hit" in
      App/AppModel+Playlists.swift|App/AppModel+DiscoverSwap.swift) ;;
      *) echo "G1: a playlist write outside X3's checked path: $hit" >&2; bad=1 ;;
    esac
  done
  grep -qF 'guard Self.isOwn(fresh, by: user), !isDiscoverPlaylist(fresh) else { throw PlaylistEditError.notYours }' App/AppModel+Playlists.swift ||
    { echo "G1: App/AppModel+Playlists.swift: ownPlaylist no longer refuses Discover's playlists" >&2; bad=1; }
  grep -qF 'let (fresh, songs) = try await ownPlaylist(playlist)' App/AppModel+DiscoverSwap.swift ||
    { echo "G1: App/AppModel+DiscoverSwap.swift: the swap no longer goes through ownPlaylist" >&2; bad=1; }
  # Only the Lidarr gate and the Aurral client name an API-key header or parameter (the redactor and the test stub aside).
  for f in $(grep -rlE --include='*.swift' '[Xx]-[Aa]pi-[Kk]ey"|"api_key' "${product[@]}" | sort -u || true); do
    case "$f" in
      "$aurral"|Packages/MagpieKit/Sources/LidarrKit/WriteGate.swift|Packages/MagpieKit/Sources/MagpieTestSupport/StubAurral.swift|Packages/MagpieKit/Sources/MagpieCore/Redactor.swift|Packages/MagpieKit/Sources/MagpieCore/RedirectPolicy.swift) ;;
      *) echo "G1: an API-key request built outside the Lidarr gate and the Aurral client: $f" >&2; bad=1 ;;
    esac
  done
fi
if [ -z "${G1_SRC:-}" ]; then
  # Round 12 security L1: the pins above match exact spellings. The gate lower-cases and fully decodes the path, so
  # every `gate.send(` is also checked normalised: lower case, `%XX` and `\u{X}` decoded, leading `/` and `api/v1/`
  # dropped, `//` collapsed. Its verb and path must both be literals on the line (Provisioner's profile/tag create
  # aside: POST only, a path from its own constants), and then:
  #   - DELETE trackfile… only from Not for me and the MP3 rule;
  #   - DELETE queue… only with the one allowed query (`?\(Self.queueRemoval)`), from Stall and the restarter;
  #   - POST command only naming AlbumSearch (runner, Lossless, Bring in more, restarter), RefreshArtist (Lossless)
  #     or ArtistSearch (ArtistLidarr).
  # `removeCounting(…, restartAny: true)` (the queueRestartAny shape) only from the restarter.
  rq="Packages/MagpieKit/Sources/Requests"
  sends=$(grep -rnE --include='*.swift' 'gate\.send\(' "${product[@]}" | grep -v "^$gate:" |
          grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' || true)
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    file="${s%%:*}" rest="${s#*:}"; line="${rest%%:*}" text="${rest#*:}"
    parsed=$(printf '%s\n' "$text" | perl -ne '
      s/\\u\{([0-9a-fA-F]+)\}/chr(hex($1))/ge; s/%([0-9a-fA-F]{2})/chr(hex($1))/ge; $_ = lc;
      if (/gate\.send\(\s*"([a-z]+)"\s*,\s*"([^"]*)"/) {
        my ($v, $p) = ($1, $2); $p =~ s#/{2,}#/#g; $p =~ s#^/##; $p =~ s#^api/v1/##; $p =~ s#^/##;
        print "$v $p\n";
      } else { print "-\n"; }')
    if [ "$parsed" = "-" ]; then
      case "$file|$text" in
        "Packages/MagpieKit/Sources/LidarrKit/Provisioner.swift|"*'gate.send("POST", path, body: body)'*) ;;
        *) echo "L1: gate.send without a literal verb and path: $file:$line" >&2; bad=1 ;;
      esac
      continue
    fi
    verb="${parsed%% *}" path="${parsed#* }"
    case "$verb $path" in
      "delete trackfile"*)
        case "$file" in
          "$rq/RequestRunner+NotForMe.swift"|"$rq/RequestRunner+Lossless.swift") ;;
          *) echo "L1: track file delete outside Not for me and the MP3 rule: $file:$line" >&2; bad=1 ;;
        esac ;;
      "delete queue"*)
        case "$file" in
          "$rq/RequestRunner+Stall.swift"|"$rq/DownloadsInLidarr.swift") ;;
          *) echo "L1: queue delete outside Stall and the restarter: $file:$line" >&2; bad=1 ;;
        esac
        case "$path" in
          *'?\(self.queueremoval)') ;;
          *) echo "L1: queue delete without the one allowed query: $file:$line" >&2; bad=1 ;;
        esac ;;
      "post command"*)
        name=$(printf '%s\n' "$text" | perl -ne 'print lc($1) if /name:\s*"([^"]*)"/')
        case "$name|$file" in
          "albumsearch|$rq/RequestRunner.swift"|"albumsearch|$rq/RequestRunner+Lossless.swift"|\
          "albumsearch|$rq/RequestRunner+BringInMore.swift"|"albumsearch|$rq/DownloadsInLidarr.swift"|\
          "refreshartist|$rq/RequestRunner+Lossless.swift"|"artistsearch|$rq/ArtistLidarr.swift") ;;
          *) echo "L1: a Lidarr command (${name:-no literal name}) outside its pinned callers: $file:$line" >&2; bad=1 ;;
        esac ;;
    esac
  done <<< "$sends"
  for f in $(grep -rlE --include='*.swift' 'restartAny:[[:space:]]*true' "${product[@]}" | sort -u || true); do
    [ "$f" = "Packages/MagpieKit/Sources/Requests/DownloadsInLidarr.swift" ] ||
      { echo "L1: removeCounting(restartAny: true) outside the restarter: $f" >&2; bad=1; }
  done
fi
[ "$bad" = 0 ] || { echo "G1 check failed: route Lidarr writes through LidarrWriteGate (or extend the allowlist in $0)" >&2; exit 1; }
echo "G1 check: no write verbs outside LidarrWriteGate in ${product[*]}${tests[*]:+ and ${tests[*]}} (allowlisted: Navidrome auth/login, dev-only IT helpers)"
