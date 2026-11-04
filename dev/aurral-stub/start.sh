#!/usr/bin/env bash
# Starts the stub Aurral 2.13 (dev/aurral-stub/server.py) on 127.0.0.1 if it isn't answering yet, and prints its base
# URL. Dev and tests only: never the owner's Aurral, never shipped in the app. Leaves it running (like the dev stack).
set -euo pipefail
port="${AURRAL_STUB_PORT:-3901}"
url="http://127.0.0.1:$port"
if curl -fsS --max-time 2 "$url/__stub/ping" >/dev/null 2>&1; then echo "$url"; exit 0; fi
log="${TMPDIR:-/tmp}/magpie-aurral-stub.log"
AURRAL_STUB_PORT="$port" nohup /usr/bin/env python3 "$(dirname "$0")/server.py" >"$log" 2>&1 &
for _ in $(seq 1 50); do
  if curl -fsS --max-time 1 "$url/__stub/ping" >/dev/null 2>&1; then echo "$url"; exit 0; fi
  sleep 0.1
done
echo "aurral stub didn't start (see $log)" >&2
exit 1
