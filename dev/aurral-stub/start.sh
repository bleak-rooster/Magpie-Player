#!/usr/bin/env bash
# Starts the stub Aurral 2.13 (dev/aurral-stub/server.py) on 127.0.0.1 if it isn't answering yet, and prints its base
# URL. Dev and tests only: never the owner's Aurral, never shipped in the app. Leaves it running (like the dev stack).
# A stub already answering is reused only when it runs this exact server.py (its /__stub/ping reports the file's
# sha256); a stub left running from older code (another worktree, an earlier round) is stopped and restarted, so
# tests never hit routes or scenarios that stub doesn't have. Only a process whose command line is
# dev/aurral-stub/server.py is ever stopped.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
port="${AURRAL_STUB_PORT:-3901}"
url="http://127.0.0.1:$port"
want="$(shasum -a 256 "$here/server.py" | cut -d' ' -f1)"

ping_source() {  # prints the running stub's source sha ("" for an old stub without one); fails if nothing answers
  local body
  body="$(curl -fsS --max-time "${1:-2}" "$url/__stub/ping" 2>/dev/null)" || return 1
  printf '%s' "$body" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("source",""))' 2>/dev/null || echo ""
}

if have="$(ping_source 2)"; then
  if [ "$have" = "$want" ]; then echo "$url"; exit 0; fi
  echo "aurral stub on $url runs other code (${have:-no version}); restarting it" >&2
  for pid in $(lsof -nP -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null || true); do
    cmd="$(ps -o command= -p "$pid" 2>/dev/null || true)"
    case "$cmd" in
      *aurral-stub/server.py*) kill "$pid" 2>/dev/null || true ;;
      *) echo "port $port is held by something that isn't the aurral stub ($cmd); not touching it" >&2; exit 1 ;;
    esac
  done
  for _ in $(seq 1 50); do
    lsof -nP -iTCP:"$port" -sTCP:LISTEN -t >/dev/null 2>&1 || break
    sleep 0.1
  done
fi

log="${TMPDIR:-/tmp}/magpie-aurral-stub.log"
AURRAL_STUB_PORT="$port" nohup /usr/bin/env python3 "$here/server.py" >"$log" 2>&1 &
for _ in $(seq 1 50); do
  if have="$(ping_source 1)" && [ "$have" = "$want" ]; then echo "$url"; exit 0; fi
  sleep 0.1
done
echo "aurral stub didn't start (see $log)" >&2
exit 1
