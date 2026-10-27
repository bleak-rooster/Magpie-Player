#!/usr/bin/env bash
# G1 grep check: Lidarr writes only go through LidarrWriteGate. Fails when package code outside
# LidarrKit/WriteGate.swift builds a request with a write verb:
#   - any `httpMethod = ...` other than "GET" (a literal verb or a variable), or
#   - a "POST" / "PUT" / "DELETE" / "PATCH" literal, except as the verb of `gate.send(...)` (which is the gate).
# Comment lines are ignored. Allowlist (file, and a path that must appear on the 3 lines above the hit):
#   NavidromeKit/NavidromeClient.swift  auth/login   Navidrome sign-in, not Lidarr.
#   MagpieTestSupport/SharedLoginTransport.swift  auth/login   IT helper sharing that Navidrome sign-in (H1).
# G1_SRC overrides the tree to scan (used to check this script against a planted violation).
set -euo pipefail
cd "$(dirname "$0")/.."
src="${G1_SRC:-Packages/MagpieKit/Sources}"
gate="$src/LidarrKit/WriteGate.swift"
allow=("NavidromeKit/NavidromeClient.swift|auth/login" "MagpieTestSupport/SharedLoginTransport.swift|auth/login")

hits=$(
  {
    grep -rnE --include='*.swift' 'httpMethod[[:space:]]*=[^=]' "$src" \
      | grep -vE 'httpMethod[[:space:]]*=[[:space:]]*"GET"' || true
    grep -rniE --include='*.swift' '"(POST|PUT|DELETE|PATCH)"' "$src" | grep -vE 'gate\.send\("' || true
  } | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' | grep -v "^$gate:" | cut -d: -f1,2 | sort -u
)

bad=0
for hit in $hits; do
  file="${hit%%:*}" line="${hit##*:}"
  ok=0
  for entry in "${allow[@]}"; do
    if [ "$file" = "$src/${entry%%|*}" ] &&
       sed -n "$((line > 3 ? line - 3 : 1)),${line}p" "$file" | grep -qF "${entry##*|}"; then ok=1; fi
  done
  if [ "$ok" = 0 ]; then
    echo "G1: write verb outside LidarrWriteGate: $file:$line: $(sed -n "${line}p" "$file" | sed 's/^[[:space:]]*//')" >&2
    bad=1
  fi
done
[ "$bad" = 0 ] || { echo "G1 check failed: route Lidarr writes through LidarrWriteGate (or extend the allowlist in $0)" >&2; exit 1; }
echo "G1 check: no write verbs outside LidarrWriteGate (allowlisted: Navidrome auth/login)"
