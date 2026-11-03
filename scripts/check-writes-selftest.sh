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
[ "$failed" = 0 ] || exit 1
echo "check-writes selftest: all ${#planted[@]} planted violations caught; the clean tree passes"
