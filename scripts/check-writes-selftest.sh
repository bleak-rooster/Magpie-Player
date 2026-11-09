#!/usr/bin/env bash
# Round 12 security L1: plants each spelling of a forbidden Lidarr write into a throw-away copy of the product tree
# and checks that scripts/check-writes.sh refuses it (and that the clean copy passes). Nothing in the repo changes.
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d "${TMPDIR:-/tmp}/check-writes-selftest.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/scripts" "$work/Packages/MagpieKit" "$work/Tests"
cp "${CHECK_WRITES:-scripts/check-writes.sh}" "$work/scripts/check-writes.sh"
rsync -a --exclude '.build' Packages/MagpieKit/Sources "$work/Packages/MagpieKit/"
rsync -a --exclude 'dd' App "$work/"
mkdir -p "$work/Packages/MagpieKit/Tests"

"$work/scripts/check-writes.sh" >/dev/null 2>&1 || { echo "selftest: the clean copy fails check-writes" >&2; exit 1; }

planted=(
  'gate.send("DELETE", "trackFile/1", body: nil)'
  'gate.send("DELETE", "/trackfile/1", body: nil)'
  'gate.send("DELETE", "api/v1/trackfile/1", body: nil)'
  'gate.send("DELETE", "/API/V1//TrackFile/1", body: nil)'
  'gate.send("DELETE", "%74rackfile/1", body: nil)'
  'gate.send("DELETE", "\u{74}rackfile/1", body: nil)'
  'gate.send("delete", "trackfile/bulk", body: ids)'
  'gate.send("DELETE", path, body: nil)'
  'gate.send(method, "trackfile/1", body: nil)'
  'gate.send('
  'gate.send("DELETE", "Queue/7?removeFromClient=false", body: nil)'
  'gate.send("DELETE", "/api/v1/queue/7?\(Self.queueRemoval)", body: nil)'
  'gate.send("POST", "command", body: SearchBody(name: "ArtistSearch", artistId: 7))'
  'gate.send("POST", "Command", body: Body(name: "RenameFiles"))'
  'gate.send("POST", "command", body: body)'
  'removeCounting([item], for: id, manual: true, restartAny: true)'
  'gate.send("DELETE", "queue/\(queueId)?\(Self.queueRemoval)", body: nil, confinedAs: .queueRestartAny, allowForeign: true)'
  'gate.send("DELETE", "queue/\(queueId)?\(Self.queueRemoval)", body: nil, confinedAs: .queueRestartAny, allowForeign: flag)'
  'restarter.restart(row, allowForeign: true)'
  'restarter.restartAll(rows, includeForeign: true)'
  'restarter.restart(row, allowForeign: row.foreign)'
  'screen.restart([row], model: model, allowForeign: x)'
  'restarter.restartAll(rows, includeForeign: flag)'
  'restarter.restart(row)'
  'screen.restartAll(rows, model: model)'
  'LidarrDownloadRestarter(lidarr: client, gate: gate, runner: nil)'
  # Round 22 (D172): the kept single's delete named anywhere but its one pinned caller.
  'gate.send("DELETE", "trackfile/bulk", body: TrackFileIdsBody(trackFileIds: ids), confinedAs: .keptSingleDelete)'
  # Round 14 A1: Aurral routes outside the exact allow-list.
  'aurral.ok(method: "GET", path: "api/discover/refresh")'
  'aurral.ok(method: "GET", path: "api/discover/blocked-tags")'
  'aurral.ok(method: "GET", path: "api/discover/preferences")'
  'aurral.ok(method: "GET", path: "api/discover/editorial/1/library/x")'
  'aurral.ok(method: "GET", path: "api/library/downloads/track")'
  'aurral.ok(method: "GET", path: "api/library/albums/request")'
  'aurral.ok(method: "GET", path: "api/playlists/flows/" + id + "/tracks")'
  'aurral.ok(method: "GET", path: "api/playlists/shared-playlists/" + id + "/sync")'
  'aurral.ok(method: AurralRoute.discoverWriteMethod, path: "api/discover/feedback/reset")'
  # Round 14 A7: a Deezer or Apple host anywhere in product code, a second image-proxy send.
  'URLSession.shared.data(from: URL(string: "https://cdnt-preview.dzcdn.net/a.mp3")!)'
  'URLSession.shared.data(from: URL(string: "https://e-cdns-images.DZCDN.net/images/cover/1/1.jpg")!)'
  'URLSession.shared.data(from: URL(string: "https://api.deezer.com/chart")!)'
  'URLSession.shared.data(from: URL(string: "https://is1-ssl.mzstatic.com/image/thumb/a.jpg")!)'
  'URLSession.shared.data(from: URL(string: "https://rss.applemarketingtools.com/api/v2/au")!)'
  'URLSession.shared.data(from: URL(string: "https://itunes.apple.com/lookup?id=1")!)'
  'aurral.ok(method: AurralRoute.imageProxyMethod, path: "api/image-proxy", body: other)'
  # Round 22 R22A (D186): a third caller of Download songs.
  'client.downloadFlow("flow-1")'
  # Round 23 (D191): the blocklist clean-up named anywhere but its one pinned caller, or another blocklist delete.
  'gate.send("DELETE", "blocklist/bulk", body: BlocklistIdsBody(ids: ids), confinedAs: .blocklistCleanup)'
  'gate.send("DELETE", "Blocklist/5", body: nil)'
  # Round 23 (D192): an slskd write outside the clean slate, the channel sent outside its gate, a gate made elsewhere,
  # the key header built elsewhere.
  'slskd.gate.perform(.deleteFolder(name, only: []))'
  'access.perform(.removeTransfer(username: user, id: id))'
  'client.connection.send(.deleteFolder("Lowlands"))'
  'SlskdWriteGate(client: client, defaultsSuite: nil)'
  'request.setValue(key, forHTTPHeaderField: "X-API-Key")'
  # Fix round 1 M4: the slskd gate named (then used through another name) outside its one caller.
  'slskd.gate.enabled'
  'model.slskdAccess?.gate.enabled'
  'g as SlskdWriteGate'
  # Round 23 R23F (D200): a third caller of Retry a song (the research route).
  'client.retrySong(playlistId: "flow-1", jobId: "job-1")'
  # Round 24 (D242, D243): an owner's artist's change or clean-up named outside MonitoringChange.swift, or the ledger's
  # monitoring book (the consent the gate reads) written elsewhere.
  'gate.send("DELETE", "trackfile/bulk", body: TrackFileIdsBody(trackFileIds: ids), confinedAs: .unmatchedCleanup)'
  'gate.send("PUT", "artist/editor", body: ProfileBody(artistIds: [job.artistId], metadataProfileId: target), confinedAs: .ownedChange)'
  'ledger.saveIntent(intent)'
)
failed=0
for p in "${planted[@]}"; do
  printf 'func planted() async throws {\n    _ = try await %s\n}\n' "$p" > "$work/App/PlantedViolation.swift"
  if out=$("$work/scripts/check-writes.sh" 2>&1); then
    echo "selftest: NOT caught: $p" >&2; failed=1
  elif ! grep -qE 'L1:|G1:' <<< "$out"; then
    echo "selftest: failed without a G1/L1 reason: $p" >&2; failed=1
  fi
done
rm -f "$work/App/PlantedViolation.swift"

# Fix M1: weakenings of the Aurral allow-list itself (one at a time, each on a fresh copy of AurralClient.swift) must be
# caught too: a read moved to a write verb, a route with a new query name, a token dropped or added, the retry route's
# continuation loosened.
aurral_src="$work/Packages/MagpieKit/Sources/AurralKit/AurralClient.swift"
cp "$aurral_src" "$work/AurralClient.orig"
weakened=(
  's/             .deezerPreview, .imageProxyFile: "GET"/             .deezerPreview: "GET"\n        case .imageProxyFile: Self.startMethod/'
  's/        case .health, .login, .deezerPreview, .imageProxyFile: false/        case .health, .login, .deezerPreview, .imageProxyFile, .imageProxy: false/'
  's/        case 2 where rest\[0\] == "image-proxy" \&\& isImageProxyKey(rest\[1\]): .imageProxyFile/        case 2 where rest[0] == "image-proxy": .imageProxyFile/'
  's/        case .deezerPreview: \["download"\]/        case .deezerPreview: ["download", "url"]/'
  's/        case .editorialAdd, .discoverFeedback, .flowDownload, .trackResearch: Self.discoverWriteMethod/        case .editorialAdd, .discoverFeedback, .flowDownload, .trackResearch, .trending: Self.discoverWriteMethod/'
  's/        case .recommendations: \["limit", "offset"\]/        case .recommendations: ["limit", "offset", "refresh"]/'
  's/        case .artistPreview: \["artistName"\]/        case .artistPreview: ["artistName"]\n        case .trending: ["download"]/'
  's/        case .health, .login, .deezerPreview, .imageProxyFile: false/        case .health, .login, .deezerPreview, .imageProxyFile, .bootstrap: false/'
  's/            \&\& isPlainId(rest\[4\]) \&\& rest\[5\] == "research": .trackResearch/            \&\& rest[5] == "research": .trackResearch/'
  's/return Set(names).count == names.count \&\& names.allSatisfy(route.queryNames.contains)/return true/'
)
for w in "${weakened[@]}"; do
  cp "$work/AurralClient.orig" "$aurral_src"
  sed -i '' "$w" "$aurral_src"
  if cmp -s "$work/AurralClient.orig" "$aurral_src"; then
    echo "selftest: the weakening didn't apply: $w" >&2; failed=1; continue
  fi
  if out=$("$work/scripts/check-writes.sh" 2>&1); then
    echo "selftest: NOT caught: $w" >&2; failed=1
  elif ! grep -qE 'G1:' <<< "$out"; then
    echo "selftest: failed without a G1 reason: $w" >&2; failed=1
  fi
done
cp "$work/AurralClient.orig" "$aurral_src"

# A7 fix round 1: the one refused-host list weakened (a host dropped, a host named on another line, subdomains let
# through), outside art's refusal dropped, and a Deezer host named in another MagpieCore file.
hosts_src="$work/Packages/MagpieKit/Sources/MagpieCore/RefusedMediaHosts.swift"
art_src="$work/Packages/MagpieKit/Sources/MagpieCore/OutsideArt.swift"
cp "$hosts_src" "$work/RefusedMediaHosts.orig"; cp "$art_src" "$work/OutsideArt.orig"
host_weakened=(
  "$hosts_src|s/\"mzstatic.com\", \"apple.com\"\]/\"mzstatic.com\"]/"
  "$hosts_src|s/^public enum RefusedMediaHosts {/public enum RefusedMediaHosts {\n    static let extra = \"cdn.dzcdn.net\"/"
  "$hosts_src|s/return domains.contains { name == \$0 || name.hasSuffix(\".\" + \$0) }/return domains.contains { name == \$0 }/"
  "$art_src|s/, !RefusedMediaHosts.refuses(host: host) else { return nil }/ else { return nil }/"
  "$art_src|s/^public enum OutsideArtPolicy {/public enum OutsideArtPolicy {\n    static let deezer = \"e-cdns-images.dzcdn.net\"/"
)
for w in "${host_weakened[@]}"; do
  file="${w%%|*}" expr="${w#*|}"
  cp "$work/RefusedMediaHosts.orig" "$hosts_src"; cp "$work/OutsideArt.orig" "$art_src"
  cp "$file" "$work/before"
  sed -i '' "$expr" "$file"
  if cmp -s "$work/before" "$file"; then echo "selftest: the weakening didn't apply: $expr" >&2; failed=1; continue; fi
  if out=$("$work/scripts/check-writes.sh" 2>&1); then
    echo "selftest: NOT caught: $expr" >&2; failed=1
  elif ! grep -qE 'G1:' <<< "$out"; then
    echo "selftest: failed without a G1 reason: $expr" >&2; failed=1
  fi
done
cp "$work/RefusedMediaHosts.orig" "$hosts_src"; cp "$work/OutsideArt.orig" "$art_src"
weakened+=("${host_weakened[@]}")

# S14 L5 (D119): the id validators, Not for me's body, the picture fetch's allow-list check and the 8 MB cap weakened.
discover_src="$work/Packages/MagpieKit/Sources/AurralKit/AurralClient+Discover.swift"
proxy_src="$work/Packages/MagpieKit/Sources/AurralKit/AurralImageProxy.swift"
for f in "$aurral_src" "$discover_src" "$proxy_src"; do cp "$f" "$f.orig"; done
s14_weakened=(
  "$aurral_src|s/!s.isEmpty \&\& s.count <= 100 \&\& s.unicodeScalars.allSatisfy {/!s.isEmpty \&\& s.count <= 100 \&\& s.unicodeScalars.allSatisfy { \$0 == \"\/\" ||/"
  "$aurral_src|s/            (\"a\"...\"z\").contains(\$0) || (\"A\"...\"Z\").contains(\$0) || (\"0\"...\"9\").contains(\$0) || \$0 == \"-\" || \$0 == \"_\"/            (\"a\"...\"z\").contains(\$0) || (\"A\"...\"Z\").contains(\$0) || (\"0\"...\"9\").contains(\$0) || \$0 == \"-\" || \$0 == \"_\" || \$0 == \".\"/"
  "$aurral_src|s/!s.isEmpty \&\& s.count <= max \&\& s.unicodeScalars.allSatisfy { (\"0\"...\"9\").contains(\$0) }/!s.isEmpty \&\& s.count <= max/"
  "$aurral_src|s/        s.hasSuffix(\".mp3\") \&\& isDigits(s.dropLast(4), max: 20)/        s.hasSuffix(\".mp3\")/"
  "$aurral_src|s/        guard parts.count == 2 else { return true }/        guard parts.count >= 2 else { return true }/"
  "$aurral_src|s/static func isMBID(_ s: Substring) -> Bool { MBID(String(s)) != nil \&\& UUID(uuidString: String(s)) != nil }/static func isMBID(_ s: Substring) -> Bool { !s.isEmpty }/"
  "$aurral_src|s/return try await transport.send(request, maxBytes: maxResponseBytes)/return try await transport.send(request)/"
  "$aurral_src|s/public static let maxResponseBytes = 8 \* 1024 \* 1024/public static let maxResponseBytes = 800 * 1024 * 1024/"
  "$discover_src|s/        if let mbid = artist.mbid { o\[\"artistId\"\] = mbid.rawValue }/        if let mbid = artist.mbid { o[\"artistId\"] = mbid.rawValue }\n        o[\"reset\"] = true/"
  "$discover_src|s/\"sourceContext\": \"recommended\",/\"sourceContext\": artist.name,/"
  "$proxy_src|s/        guard AurralRoute.isAllowed(method: \"GET\", path: path, query: \[\]),/        guard true,/"
)
for w in "${s14_weakened[@]}"; do
  file="${w%%|*}" expr="${w#*|}"
  for f in "$aurral_src" "$discover_src" "$proxy_src"; do cp "$f.orig" "$f"; done
  cp "$file" "$work/before"
  sed -i '' "$expr" "$file"
  if cmp -s "$work/before" "$file"; then echo "selftest: the weakening didn't apply: $expr" >&2; failed=1; continue; fi
  if out=$("$work/scripts/check-writes.sh" 2>&1); then
    echo "selftest: NOT caught: $expr" >&2; failed=1
  elif ! grep -qE 'G1:' <<< "$out"; then
    echo "selftest: failed without a G1 reason: $expr" >&2; failed=1
  fi
done
for f in "$aurral_src" "$discover_src" "$proxy_src"; do cp "$f.orig" "$f"; rm -f "$f.orig"; done
weakened+=("${s14_weakened[@]}")

# Round 23 (D192): the slskd allow-list and gate weakened: a read turned into a write, a sixth route, a name allowed to
# climb out of the downloads folder, the write switch dropped, the GET-only read channel loosened.
slroute_src="$work/Packages/MagpieKit/Sources/SlskdKit/SlskdRoute.swift"
slclient_src="$work/Packages/MagpieKit/Sources/SlskdKit/SlskdClient.swift"
for f in "$slroute_src" "$slclient_src"; do cp "$f" "$f.orig"; done
slskd_weakened=(
  "$slroute_src|s/        case .downloads, .downloadsFolder: \"GET\"/        case .downloads: \"GET\"\n        case .downloadsFolder: Self.deleteMethod/"
  "$slroute_src|s/^    case deleteFolder(String)/    case deleteFolder(String)\n    case clearCompleted/"
  "$slroute_src|s/s != \".\", s != \"..\", //"
  "$slroute_src|s/\$0 == \"\\\\\\\\\" || //"
  "$slroute_src|s/            return \[\"transfers\", \"downloads\"\]/            return [\"transfers\", \"downloads\", \"all\", \"completed\"]/"
  "$slclient_src|s/        guard enabled else { throw SlskdGateError.disabled }/        _ = enabled/"
  "$slclient_src|s/        guard route.method == \"GET\" else { throw SlskdError.forbidden }//"
)
for w in "${slskd_weakened[@]}"; do
  file="${w%%|*}" expr="${w#*|}"
  for f in "$slroute_src" "$slclient_src"; do cp "$f.orig" "$f"; done
  cp "$file" "$work/before"
  sed -i '' "$expr" "$file"
  if cmp -s "$work/before" "$file"; then echo "selftest: the weakening didn't apply: $expr" >&2; failed=1; continue; fi
  if out=$("$work/scripts/check-writes.sh" 2>&1); then
    echo "selftest: NOT caught: $expr" >&2; failed=1
  elif ! grep -qE 'G1:' <<< "$out"; then
    echo "selftest: failed without a G1 reason: $expr" >&2; failed=1
  fi
done
for f in "$slroute_src" "$slclient_src"; do cp "$f.orig" "$f"; rm -f "$f.orig"; done
weakened+=("${slskd_weakened[@]}")

# Round 24 (D243): the owned-artist proofs weakened one at a time: the clean-up's cap, the fresh size check, the
# monitoring switch, the editor's two keys, the unmonitored-album check.
owned_src="$work/Packages/MagpieKit/Sources/LidarrKit/WriteConfinement+Owned.swift"
ownedgate_src="$work/Packages/MagpieKit/Sources/LidarrKit/WriteGate.swift"
for f in "$owned_src" "$ownedgate_src"; do cp "$f" "$f.orig"; done
owned_weakened=(
  "$owned_src|s/    public static let maxCleanupFiles = 50/    public static let maxCleanupFiles = 500/"
  "$owned_src|s/guard let size = file.size, size == recorded.size else/guard let size = file.size else/"
  "$owned_src|s/== \[\"artistids\", \"metadataprofileid\"\], body.count == 2,/.contains(\"artistids\"),/"
  "$owned_src|s/}), !album.monitored else {/}) else {/"
  "$ownedgate_src|s/guard monitoringChangesEnabled else { throw refused(target, \"changing what Lidarr monitors is off\") }/_ = monitoringChangesEnabled/"
)
for w in "${owned_weakened[@]}"; do
  file="${w%%|*}" expr="${w#*|}"
  for f in "$owned_src" "$ownedgate_src"; do cp "$f.orig" "$f"; done
  cp "$file" "$work/before"
  sed -i '' "$expr" "$file"
  if cmp -s "$work/before" "$file"; then echo "selftest: the weakening didn't apply: $expr" >&2; failed=1; continue; fi
  if out=$("$work/scripts/check-writes.sh" 2>&1); then
    echo "selftest: NOT caught: $expr" >&2; failed=1
  elif ! grep -qE 'G1:' <<< "$out"; then
    echo "selftest: failed without a G1 reason: $expr" >&2; failed=1
  fi
done
for f in "$owned_src" "$ownedgate_src"; do cp "$f.orig" "$f"; rm -f "$f.orig"; done
weakened+=("${owned_weakened[@]}")

[ "$failed" = 0 ] || exit 1
echo "check-writes selftest: all ${#planted[@]} planted violations and ${#weakened[@]} allow-list weakenings caught; the clean tree passes"
