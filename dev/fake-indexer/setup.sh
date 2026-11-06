#!/usr/bin/env bash
# Round 20 (R20-IT): lets the dev Lidarr grab, download and import, so Try and Finds can be tested end to end.
# Idempotent. Dev stack only (G0): refuses a Lidarr that isn't local or isn't the dev instance.
#
#   1. starts the fake Newznab indexer (start.sh, http://127.0.0.1:3903; Lidarr reaches it as host.docker.internal)
#   2. creates the blackhole folders on the host:  dev/data/downloads/magpie-blackhole/{nzb,complete}
#      (Lidarr sees them as /downloads/magpie-blackhole/{nzb,complete}; dev/docker-compose.yml mounts dev/data/downloads)
#   3. adds, only if missing, a Usenet Blackhole download client "Magpie Blackhole" (NZB folder .../nzb, watch folder
#      .../complete) and a Newznab indexer "Magpie Fake Indexer" (RSS off, automatic + interactive search on, tied to
#      that client). Nothing else in Lidarr is changed; an existing one of the same name is left as it is.
#
# Nothing downloads by itself: a test (DownloadFlowIT) tells the indexer what to offer and plays the downloader,
# turning each NZB Lidarr drops into .../nzb into a finished folder of audio files in .../complete.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
dev="$(cd "$here/.." && pwd)"
env_file="$dev/.env.local"
[ -f "$env_file" ] || { echo "no $env_file: run dev/bootstrap.sh first" >&2; exit 1; }
grep -q "Magpie dev stack" "$env_file" || { echo "$env_file lacks the dev marker" >&2; exit 1; }
LIDARR_URL="$(grep '^LIDARR_URL=' "$env_file" | cut -d= -f2-)"
LIDARR_API_KEY="$(grep '^LIDARR_API_KEY=' "$env_file" | cut -d= -f2-)"
case "$LIDARR_URL" in
  http://127.0.0.1:*|http://localhost:*) ;;
  *) echo "LIDARR_URL is not local; refusing" >&2; exit 1 ;;
esac
export LIDARR_URL LIDARR_API_KEY

indexer_url="${FAKE_INDEXER_LIDARR_URL:-http://host.docker.internal:${FAKE_INDEXER_PORT:-3903}}"
"$here/start.sh" >/dev/null
mkdir -p "$dev/data/downloads/magpie-blackhole/nzb" "$dev/data/downloads/magpie-blackhole/complete"

INDEXER_URL="$indexer_url" python3 - <<'PY'
import json, os, sys, urllib.request, urllib.error

base, key = os.environ["LIDARR_URL"].rstrip("/"), os.environ["LIDARR_API_KEY"]

def call(method, path, body=None):
    req = urllib.request.Request(f"{base}/api/v1/{path}", method=method,
                                 data=json.dumps(body).encode() if body is not None else None,
                                 headers={"X-Api-Key": key, "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            data = r.read()
            return json.loads(data) if data else None
    except urllib.error.HTTPError as e:
        sys.exit(f"{method} {path}: HTTP {e.code} {e.read().decode()[:1000]}")

status = call("GET", "system/status")
roots = {r["path"] for r in call("GET", "rootfolder")}
if status.get("instanceName") != "magpie-dev-lidarr" or roots != {"/music/library", "/music/samples"}:
    sys.exit("not the dev stack's Lidarr; refusing")

def fill(schema, values):
    for f in schema["fields"]:
        if f["name"] in values:
            f["value"] = values[f["name"]]
    return schema

clients = call("GET", "downloadclient")
client = next((c for c in clients if c["name"] == "Magpie Blackhole"), None)
if client is None:
    schema = next(s for s in call("GET", "downloadclient/schema") if s["implementation"] == "UsenetBlackhole")
    schema = fill(schema, {"nzbFolder": "/downloads/magpie-blackhole/nzb",
                           "watchFolder": "/downloads/magpie-blackhole/complete"})
    schema.update(name="Magpie Blackhole", enable=True, priority=1,
                  removeCompletedDownloads=True, removeFailedDownloads=True)
    client = call("POST", "downloadclient", schema)
    print(f"added download client Magpie Blackhole (id {client['id']})")
else:
    print(f"download client Magpie Blackhole already there (id {client['id']})")

indexers = call("GET", "indexer")
indexer = next((i for i in indexers if i["name"] == "Magpie Fake Indexer"), None)
if indexer is None:
    schema = next(s for s in call("GET", "indexer/schema") if s["implementation"] == "Newznab")
    schema = fill(schema, {"baseUrl": os.environ["INDEXER_URL"], "apiPath": "/api", "apiKey": "magpie-fake",
                           "categories": [3000, 3010, 3040]})
    schema.update(name="Magpie Fake Indexer", enableRss=False, enableAutomaticSearch=True,
                  enableInteractiveSearch=True, priority=25, downloadClientId=client["id"])
    indexer = call("POST", "indexer", schema)
    print(f"added indexer Magpie Fake Indexer (id {indexer['id']}) -> {os.environ['INDEXER_URL']}")
else:
    print(f"indexer Magpie Fake Indexer already there (id {indexer['id']})")
PY
