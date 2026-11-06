#!/usr/bin/env bash
# Starts the fake Newznab indexer (dev/fake-indexer/server.py) on 127.0.0.1 if it isn't answering yet, and prints its
# base URL. Dev and tests only. Leaves it running (like the dev stack). A server left running from other code (another
# worktree, an older round) is stopped and restarted; only a process whose command line is
# dev/fake-indexer/server.py is ever stopped.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
port="${FAKE_INDEXER_PORT:-3903}"
url="http://127.0.0.1:$port"
want="$(shasum -a 256 "$here/server.py" | cut -d' ' -f1)"

ping_source() {
  local body
  body="$(curl -fsS --max-time "${1:-2}" "$url/control/ping" 2>/dev/null)" || return 1
  printf '%s' "$body" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("source",""))' 2>/dev/null || echo ""
}

if have="$(ping_source 2)"; then
  if [ "$have" = "$want" ]; then echo "$url"; exit 0; fi
  echo "fake indexer on $url runs other code; restarting it" >&2
  for pid in $(lsof -nP -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null || true); do
    cmd="$(ps -o command= -p "$pid" 2>/dev/null || true)"
    case "$cmd" in
      *fake-indexer/server.py*) kill "$pid" 2>/dev/null || true ;;
      *) echo "port $port is held by something that isn't the fake indexer ($cmd); not touching it" >&2; exit 1 ;;
    esac
  done
  for _ in $(seq 1 50); do
    lsof -nP -iTCP:"$port" -sTCP:LISTEN -t >/dev/null 2>&1 || break
    sleep 0.1
  done
fi

log="${TMPDIR:-/tmp}/magpie-fake-indexer.log"
FAKE_INDEXER_PORT="$port" nohup /usr/bin/env python3 "$here/server.py" >"$log" 2>&1 &
for _ in $(seq 1 50); do
  if have="$(ping_source 1)" && [ "$have" = "$want" ]; then echo "$url"; exit 0; fi
  sleep 0.1
done
echo "fake indexer didn't start (see $log)" >&2
exit 1
