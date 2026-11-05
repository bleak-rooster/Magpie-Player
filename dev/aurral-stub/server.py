#!/usr/bin/env python3
"""A stub Aurral 2.13 for Magpie's XCUITests (round 14 A1, fix round 1). Dev only, never shipped in the app.

Serves the same 2.13.0 shapes and fixtures as MagpieTestSupport's StubAurral (StubAurral+Discover.swift):
health, bootstrap, login/logout, auth/me, playlists status/jobs, Recommended, Trending, genre charts, Discover
playlists (editorial), editorial links, artist preview, search (unified and paged), release-group tracks, the four
writes, the preview's 302 (and its `?download` clip), the image proxy (A7), and round 15 C2's chart flows (the user's own
playlists: `POST /api/playlists/shared-playlists`, and `DELETE /api/playlists/shared-playlists/<id>`, listed in the
status's `sharedPlaylists`; fix round: the create is queued and a taken name fails silently, as 2.13's worker does;
`POST …/<id>/tracks` and `POST …/<id>/track-removals` add and remove songs, removals and DELETE delete files; the
worldwide chart playlist 3155776842 has 30 songs). `MagpieTests/AurralStubServerTests` checks it decodes as StubAurral's does.

Python standard library only. Listens on 127.0.0.1 only (default port 3901, `AURRAL_STUB_PORT`).

Scenarios: the Aurral base URL carries one as a path prefix, `http://127.0.0.1:3901/s/<scenario>`, so the app (which
sends no custom header) can be pointed at one; a test runner may instead send `X-Stub-Scenario: <scenario>`.
  default          2.13.0, user "magpie" (admin), a download source configured, region AU
  aurral210        2.10.0: no API contract (Magpie keeps today's behaviour); no Discover routes
  no-access-flow   the user is not an admin and has no accessFlow: flow reads and writes answer 403
  no-downloader    no download source configured (Download songs answers 409)
  region-us        Trending reports region US
  missing-sections Trending's songs, artists and genres have never loaded (null / [])
  genre-not-ready  every genre chart answers 404 "This genre chart isn't available yet"
  slow             each Discover answer waits 2 s
  failing          each Discover answer is a 502
  redirects        the preview's ?download and the image proxy's pictures answer a 302 (A7)
  oversized        the preview's ?download and the image proxy's pictures send 5 MB (A7)
  lidarr-artist    Trending's songs are credited to "Radiohead", the name Lidarr's lookup gives ARTIST_A (the one
                   artist MBID the editorial links answer), so S14 M2's name check (D116) passes for Whole artist
Control (never sent by the app): GET /__stub/ping, GET /__stub/log (the requests seen, newest last, as
"METHOD /path" without the scenario prefix and without query), GET /__stub/shared (the user's own playlists and their
songs), POST /__stub/reset.
"""
import base64
import hashlib
import json
import os
import re
import sys
import threading
import time
import uuid
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

# The sha256 of this file, reported by /__stub/ping so start.sh can tell a stub left running from older code and restart it.
with open(os.path.abspath(__file__), "rb") as _f:
    SOURCE_SHA = hashlib.sha256(_f.read()).hexdigest()

USERNAME = "magpie"
PASSWORD = "stub-aurral-password"
FEATURES_213 = ["discover", "flows", "playlistCoverTemplates", "activity", "review", "trackDownloads", "linkSearch",
                "downloadCancel", "shareImports", "trending", "flowAutoDownload"]
ARTIST_A = "a74b1b7f-71a5-4011-9441-d0b5e4122711"
# ARTIST_A is a real MusicBrainz id; Lidarr's artist/lookup?term=lidarr:<ARTIST_A> names it LIDARR_NAME_A.
LIDARR_NAME_A = "Radiohead"
ARTIST_B = "f59c5520-5f46-4d2c-b2c4-822eabf53419"
ARTIST_C = "8538e728-ca0b-4321-b7e5-cff6565dd4c0"
RELEASE_GROUP = "1dc4c347-a1db-32aa-b14f-bc9cc507b843"
PREVIEW_TARGET = "https://cdnt-preview.dzcdn.net/api/1/1/a/b/c/preview.mp3?hdnea=exp=1790000000~hmac=stub"
# Round 14 A7: the clip `?download` sends (Aurral fetches it from Deezer and sends the bytes itself).
PREVIEW_CLIP = b"ID3" + b"\xff" * 2045
# Round 14 A7: the image proxy serves this 1x1 PNG for every cached picture.
PROXIED_PICTURE = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")
SCENARIOS = {"default", "aurral210", "no-access-flow", "no-downloader", "region-us", "missing-sections",
             "genre-not-ready", "slow", "failing", "redirects", "oversized", "lidarr-artist"}
# Round 14 A7 fix round 1: "redirects" answers the preview's ?download and the image proxy's pictures with a 302 (an
# Aurral that redirects anyway: Magpie must refuse it, never follow); "oversized" sends 5 MB for both (past the caps).
OVERSIZED = b"ID3" + b"\xff" * (5 * 1024 * 1024)

LOCK = threading.Lock()
STATE = {"sessions": {}, "log": [], "added": {}, "shared": {}}
# Round 15 C2: Deezer's "Top Worldwide" chart playlist (ChartPlaylists.json's `worldwide`).
WORLDWIDE_CHART = "3155776842"


def song(id_, title, artist, position=None, movement=None):
    s = {"key": str(id_), "trackName": title, "artistName": artist, "albumName": f"{title} (Single)",
         "deezerAlbumId": str(id_ + 1000), "durationMs": 180000 + id_ % 60 * 1000,
         "artworkUrl": f"https://cdn-images.dzcdn.net/images/cover/{id_}/250x250-000000-80-0-0.jpg",
         "largeArtworkUrl": f"https://cdn-images.dzcdn.net/images/cover/{id_}/1000x1000-000000-80-0-0.jpg",
         "preview_url": f"/api/deezer/preview/{id_}.mp3"}
    if position is not None:
        s["position"] = position
        s["movement"] = movement
    return s


SONGS = [song(3135556, "Harbour Lights", "Stub Arrows", 1, 0), song(3135557, "Paper Moon", "Stub Arrows", 2, 3),
         song(3135558, "Night Drive", "Low Tide Club", 3, -1), song(3135559, "Southerly", "Mallee Fowl", 4, "new"),
         song(3135560, "No Preview Song", "Mallee Fowl", 5)]


WORLD_SONGS = [song(3140000 + i, f"World Song {i + 1}", f"World Artist {i % 7 + 1}") for i in range(30)]


def shared_jobs(pid, playlist):
    return [{"id": t["jid"], "artistName": t["artistName"], "trackName": t["trackName"],
             "albumName": t.get("albumName") or "Single", "playlistId": pid, "playlistType": pid, "managedBy": "aurral",
             "status": "done", "downloadSource": "slskd", "durationMs": t.get("durationMs"), "streamFormat": "flac"}
            for t in playlist["tracks"]]


def clean_tracks(tracks):
    """The valid songs, each given a stable job id (Aurral's jobs keep theirs as songs come and go)."""
    out = []
    for t in tracks if isinstance(tracks, list) else []:
        if isinstance(t, dict) and str(t.get("artistName") or "").strip() and str(t.get("trackName") or "").strip():
            STATE["next_job"] = STATE.get("next_job", 0) + 1
            song = {k: t.get(k) for k in ("artistName", "trackName", "albumName", "durationMs")}
            song["jid"] = f"sjob-{STATE['next_job']}"
            out.append(song)
    return out


def song_key(t):
    return f"{str(t.get('artistName') or '').strip().lower()}|{str(t.get('trackName') or '').strip().lower()}"


def shared_answer(method, parts, body, accessflow):
    """Round 15 C2 (fix round): Aurral 2.13's own playlists (routes/playlists/handlers/staticPlaylists.ts). The create
    is queued and answers 200 whatever the name; a name the user already has (a playlist or a flow, trimmed and
    lower-cased) fails in the worker and the playlist never appears. `…/tracks` appends, `…/track-removals` takes songs
    out and deletes their files, DELETE removes it (and its files)."""
    if parts[:3] != ["api", "playlists", "shared-playlists"]:
        return None
    create = method == "POST" and len(parts) == 3
    append = method == "POST" and len(parts) == 5 and parts[4] == "tracks"
    removal = method == "POST" and len(parts) == 5 and parts[4] == "track-removals"
    delete = method == "DELETE" and len(parts) == 4
    if not (create or append or removal or delete):
        return None
    if not accessflow:
        return 403, {"error": "Forbidden", "message": "Missing permission: accessFlow"}
    with LOCK:
        shared = STATE["shared"]
        if create:
            name = str(body.get("name") or "").strip()
            if not name:
                return 400, {"error": "name is required"}
            pid = str(uuid.uuid4())
            flows, _ = flows_and_jobs()
            taken = {p["name"].strip().lower() for p in shared.values()} | {f["name"].strip().lower() for f in flows}
            if name.lower() in taken:
                STATE.setdefault("failed", []).append(name)   # 2.13: STATIC_PLAYLIST_NAME_CONFLICT in the worker
            else:
                shared[pid] = {"name": name, "sourceName": body.get("sourceName"), "tracks": clean_tracks(body.get("tracks"))}
            return 200, {"success": True, "playlistId": pid, "queued": True, "operationId": "op-create"}
        pid = parts[3]
        if pid not in shared:
            return 404, {"error": "Playlist not found"}
        playlist = shared[pid]
        if delete:
            STATE.setdefault("deleted", []).extend(song_key(t) for t in playlist["tracks"])
            del shared[pid]
            return 200, {"success": True, "playlistId": pid, "queued": True, "operationId": "op-delete"}
        if removal:
            ids = body.get("jobIds") if isinstance(body.get("jobIds"), list) else []
            if not ids:
                return 400, {"error": "jobIds must contain at least one track ID"}
            accepted = [t["jid"] for t in playlist["tracks"] if t["jid"] in ids]
            STATE.setdefault("deleted", []).extend(song_key(t) for t in playlist["tracks"] if t["jid"] in ids)
            playlist["tracks"] = [t for t in playlist["tracks"] if t["jid"] not in ids]
            return 200, {"queued": bool(accepted), "operationId": "op-remove", "acceptedJobIds": accepted,
                         "rejected": [{"jobId": j, "message": "Track not found in this playlist"} for j in ids if j not in accepted]}
        have = {song_key(t) for t in playlist["tracks"]}
        new = [t for t in clean_tracks(body.get("tracks")) if song_key(t) not in have]
        if not body.get("tracks"):
            return 400, {"error": "tracks are required", "message": "Add at least one valid track"}
        playlist["tracks"].extend(new)
        return 200, {"success": True, "playlistId": pid, "queued": True, "operationId": "op-append"}


def editorial_summary(id_, name):
    return {"id": id_, "name": name, "description": f"{name}, updated weekly", "trackCount": 4,
            "artworkUrl": f"https://cdn-images.dzcdn.net/images/playlist/{id_}/1000x1000.jpg",
            "curator": "Deezer Pop Editor"}


def recommended(id_, name, depth, seeds, days):
    first = (datetime.now(timezone.utc) - timedelta(days=days)).strftime("%Y-%m-%dT%H:%M:%SZ")
    return {"id": id_, "navigateTo": id_, "name": name, "type": "Artist", "image": None,
            "tags": ["indie pop", "dream pop"], "matchedTags": ["indie pop"],
            "sourceArtist": seeds[0] if seeds else None, "sourceArtists": seeds, "sourceType": "similar",
            "supportingSeeds": [{"artistName": s} for s in seeds],
            "discoveryTier": "further" if depth > 1 else "close", "discoveryDepth": depth, "firstDiscoveredAt": first,
            "score": 0.82, "scoreTotal": 12, "matchPercent": 82, "popularityLabel": "Rising", "popularityRank": 3,
            "listeners": 120000, "playcount": 2400000}


def user_for(scenario):
    if scenario == "no-access-flow":
        return {"id": 1, "username": USERNAME, "role": "user",
                "permissions": {"accessFlow": False, "addArtist": True, "addAlbum": True, "changeMonitoring": False}}
    return {"id": 1, "username": USERNAME, "role": "admin",
            "permissions": {"accessFlow": False, "addArtist": True, "addAlbum": True, "changeMonitoring": False}}


def may_access_flows(scenario):
    return scenario != "no-access-flow"


def flows_and_jobs():
    flows = [{"id": "flow-dw", "name": "Discover Weekly", "ownerUserId": 1, "ownerUsername": USERNAME, "enabled": True,
              "size": 20, "scheduleDays": [5], "scheduleTime": "00:00", "nextRunAt": "2026-11-06T00:00:00.000Z",
              "lastRunAt": "2026-10-30T00:00:00.000Z", "mix": {"discover": 100}}]
    jobs = [{"id": "job-0", "artistName": "Stub Arrows", "trackName": "Harbour Lights", "albumName": "Single",
             "playlistId": "flow-dw", "playlistType": "flow-dw", "managedBy": "aurral", "status": "done",
             "downloadSource": "slskd", "artistMbid": ARTIST_A, "durationMs": 180000, "streamFormat": "flac"},
            {"id": "job-1", "artistName": "Mallee Fowl", "trackName": "Southerly", "albumName": "Single",
             "playlistId": "flow-dw", "playlistType": "flow-dw", "managedBy": "aurral", "status": "failed",
             "downloadSource": "slskd", "streamFormat": None}]
    return flows, jobs


def status_body():
    flows, jobs = flows_and_jobs()
    with LOCK:
        shared = {pid: dict(p) for pid, p in STATE["shared"].items()}
    stats = {"flow-dw": {"total": 2, "pending": 0, "downloading": 0, "done": 1, "failed": 1, "blocked": 0}}
    for pid, p in shared.items():
        n = len(p["tracks"])
        stats[pid] = {"total": n, "pending": 0, "downloading": 0, "done": n, "failed": 0, "blocked": 0}
    listed = [{"id": pid, "name": p["name"], "ownerUserId": 1, "ownerUsername": USERNAME, "trackCount": len(p["tracks"]),
               "sourceName": p.get("sourceName"), "sourceFlowId": None, "importedAt": "2026-11-05T00:00:00.000Z",
               "createdAt": "2026-11-05T00:00:00.000Z", "recordHistory": True, "showTrackAvailability": False,
               "artworkRevision": 1, "importSource": None} for pid, p in shared.items()]
    return {"worker": {"running": True, "processing": False, "activeCount": 0},
            "flowStats": stats,
            "flows": flows, "sharedPlaylists": listed,
            "operationQueue": {"processing": False, "pending": 0, "currentLabel": None},
            "hint": {"phase": "idle", "message": "Next update in 5 days"}}


def bootstrap_body(scenario, user):
    body = {"status": "ok", "authRequired": True, "onboardingRequired": False, "timestamp": "2026-11-04T00:00:00.000Z",
            "appVersion": "2.10.0" if scenario == "aurral210" else "2.13.0"}
    if scenario != "aurral210":
        body["api"] = {"version": 1, "features": FEATURES_213}
        body["matcher"] = {"available": True, "policyVersion": "aurral-native-6"}
    if user is not None:
        body["user"] = user
        body["authUser"] = user["username"]
        if scenario != "aurral210":
            on = scenario != "no-downloader"
            body["downloadSources"] = {
                "slskd": {"id": "slskd", "label": "Soulseek", "enabled": on, "configured": on, "priority": 1},
                "usenet": {"id": "usenet", "label": "Usenet", "enabled": False, "configured": False, "priority": 2},
                "deemix": {"id": "deemix", "label": "Deemix", "enabled": False, "configured": False, "priority": 3},
                "ytdlp": {"id": "ytdlp", "label": "yt-dlp", "enabled": False, "configured": False, "priority": 4},
            }
    return body


def trending_body(scenario):
    missing = scenario == "missing-sections"
    genres = [{"id": gid, "name": name, "covers": [s["artworkUrl"] for s in SONGS[:4]],
               "artists": ["Stub Arrows", "Low Tide Club"]} for gid, name in [(132, "Pop"), (116, "Rap/Hip Hop"), (152, "Rock")]]
    with LOCK:
        library_playlist = STATE["added"].get("1313616925")
    return {
        "region": "US" if scenario == "region-us" else "AU", "updatedAt": 1793000000000,
        "songs": None if missing else {"playlistId": "1313616925", "playlistName": "Top Australia",
                                       "libraryPlaylistId": library_playlist,
                                       "items": [dict(s, artistName=LIDARR_NAME_A) for s in SONGS]
                                       if scenario == "lidarr-artist" else SONGS,
                                       "spotlight": {"ranks": [3, 2, 1, None, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1], "daysAtTop": 9}},
        "albums": [{"key": "1440857781", "name": "Wide Open", "artistName": "Stub Arrows",
                    "artworkUrl": "https://is1-ssl.mzstatic.com/image/thumb/x/500x500bb.jpg", "releaseDate": "2026-10-01",
                    "genre": "Alternative", "position": 1},
                   {"key": "1440857782", "name": "Shoreline", "artistName": "Mallee Fowl", "artworkUrl": None,
                    "releaseDate": None, "genre": None, "position": 2}],
        "genreShare": {"total": 2, "other": 0, "genres": [{"name": "Alternative", "count": 1}]},
        "artists": None if missing else [
            {"key": "27", "name": "Stub Arrows", "imageUrl": "https://cdn-images.dzcdn.net/images/artist/27/1000x1000.jpg",
             "fans": 1200, "mbid": ARTIST_A, "position": 1},
            {"key": "28", "name": "Unknown Guess", "imageUrl": None, "fans": None, "mbid": None, "position": 2}],
        "genres": [] if missing else genres,
    }


def discover_answer(method, parts, query, body, scenario, user):
    """(status, json) for a Discover route, or None."""
    accessflow = user["role"] == "admin" or user["permissions"].get("accessFlow") is True
    if method == "GET" and parts == ["api", "discover"]:
        everyone = [recommended(ARTIST_A, "Stub Arrows", 1, ["Seed One"], 2),
                    recommended(ARTIST_B, "Low Tide Club", 1, ["Seed One"], 30),
                    recommended(ARTIST_C, "Mallee Fowl", 2, ["Seed Two"], 3),
                    recommended(None, "No Id Band", 3, [], 40)]
        offset = max(0, int(query.get("offset", "0") or 0))
        limit = min(200, max(1, int(query.get("limit", str(len(everyone))) or len(everyone))))
        return 200, {"recommendations": everyone[offset:offset + limit], "recommendationCount": len(everyone),
                     "globalTop": [recommended(ARTIST_B, "Low Tide Club", 1, [], 1)],
                     "basedOn": [{"name": "Seed One", "source": "library"}, {"name": "Seed Two", "source": "listenbrainz"}],
                     "topTags": ["indie pop"], "topGenres": ["indie", "pop"], "lastUpdated": "2026-11-04T00:00:00.000Z",
                     "recommendationQuality": "good", "isEnriching": False, "configured": True,
                     "provider": "brainzmash", "discoveryMode": "balanced"}
    if method == "GET" and parts == ["api", "discover", "trending"]:
        return 200, trending_body(scenario)
    if method == "GET" and len(parts) == 5 and parts[:4] == ["api", "discover", "trending", "genres"]:
        if scenario == "genre-not-ready" or not parts[4].isdigit():
            return 404, {"error": "This genre chart isn't available yet"}
        gid = int(parts[4])
        return 200, {"id": gid, "name": "Pop" if gid == 132 else f"Genre {gid}", "region": "AU",
                     "updatedAt": 1793000000000, "items": SONGS}
    if method == "GET" and parts == ["api", "discover", "editorial"]:
        return 200, {"forYou": [editorial_summary("908622995", "Indie Pop Picks"), editorial_summary("1479458365", "Dream Pop")],
                     "genres": [{"id": 0, "name": "Popular", "playlists": [editorial_summary("1313616925", "Top Australia")]},
                                {"id": 132, "name": "Pop", "playlists": [editorial_summary("1282483245", "Pop Hits")]}]}
    if method == "GET" and parts == ["api", "discover", "editorial", "links"]:
        if not query.get("artist"):
            return 400, {"error": "Failed to find this artist or album", "message": "artistName is required"}
        return 200, {"artistMbid": ARTIST_A, "albumMbid": RELEASE_GROUP if "album" in query else None}
    if method == "GET" and len(parts) == 4 and parts[:3] == ["api", "discover", "editorial"]:
        source = WORLD_SONGS if parts[3] == WORLDWIDE_CHART else SONGS[:4]
        tracks = [{k: v for k, v in s.items() if k not in ("key", "largeArtworkUrl", "position", "movement")} for s in source]
        with LOCK:
            added = STATE["added"].get(parts[3])
        name = "Top Worldwide" if parts[3] == WORLDWIDE_CHART else "Top Australia" if parts[3] == "1313616925" else "Indie Pop Picks"
        return 200, {"id": parts[3], "name": name, "description": "Fresh indie pop", "curator": "Deezer Pop Editor",
                     "artworkUrl": f"https://cdn-images.dzcdn.net/images/playlist/{parts[3]}/1000x1000.jpg",
                     "tracks": tracks, "libraryPlaylistId": added}
    if method == "POST" and len(parts) == 5 and parts[:3] == ["api", "discover", "editorial"] and parts[4] == "library":
        if not accessflow:
            return 403, {"error": "Forbidden", "message": "Missing permission: accessFlow"}
        with LOCK:
            existing = STATE["added"].get(parts[3])
            if existing is None:
                STATE["added"][parts[3]] = f"static-{parts[3]}"
        if existing:
            return 200, {"playlistId": existing, "name": "Indie Pop Picks", "alreadyAdded": True}
        return 200, {"playlistId": f"static-{parts[3]}", "name": "Indie Pop Picks", "alreadyAdded": False, "tracksQueued": 4}
    if method == "POST" and parts == ["api", "discover", "feedback"]:
        if body.get("action") not in ("more_like_this", "less_like_this", "block_artist") or not (
                body.get("artistId") or body.get("artistName")):
            return 400, {"error": "Failed to save discovery feedback", "message": "Invalid discovery feedback action"}
        return 200, {"success": True, "feedback": dict(body, id="fb-1"), "feedbackList": [body]}
    if method == "GET" and len(parts) == 4 and parts[1] == "artists" and parts[3] == "preview":
        return 200, {"tracks": [{"id": s["key"], "title": s["trackName"], "album": s["albumName"],
                                 "artworkUrl": s["artworkUrl"], "preview_url": s["preview_url"],
                                 "duration_ms": s["durationMs"]} for s in SONGS[:3]]}
    if method == "GET" and len(parts) == 5 and parts[1:3] == ["artists", "release-group"] and parts[4] == "tracks":
        out = []
        for n in range(1, 5):
            rec = f"{n}c5d7c4e-1f3b-4a6e-9d2c-7b1a2f3e4d5{n}"
            out.append({"id": rec, "mbid": rec, "title": f"Track {n}", "trackName": f"Track {n}", "trackNumber": n,
                        "discNumber": 1, "position": n, "releaseMbid": "b5cdfb5f-35a5-4bc5-bbca-57839a71813a",
                        "length": 200000 + n * 1000,
                        "preview_url": None if n == 4 else f"/api/deezer/preview/{3135555 + n}.mp3",
                        "previewProvider": None if n == 4 else "deezer",
                        "previewTrackId": None if n == 4 else str(3135555 + n)})
        return 200, out
    if method == "GET" and parts == ["api", "search", "unified"]:
        q = query.get("q", "")
        if not q:
            return 400, {"error": "q parameter is required"}
        return 200, {"query": q, "mode": query.get("mode", "suggest"), "top": None,
                     "catalog": {"artists": [{"type": "artist", "source": "brainzmash", "id": ARTIST_A, "key": ARTIST_A,
                                              "name": "Stub Arrows", "sortName": "Arrows, Stub", "inLibrary": True,
                                              "hasMbid": True, "score": 100},
                                             {"type": "artist", "source": "brainzmash", "id": ARTIST_B, "key": ARTIST_B,
                                              "name": "Low Tide Club", "sortName": "Low Tide Club", "inLibrary": False,
                                              "hasMbid": True, "score": 80}],
                                 "albums": [{"type": "album", "source": "brainzmash", "id": RELEASE_GROUP,
                                             "key": RELEASE_GROUP, "title": "Wide Open", "artistName": "Stub Arrows",
                                             "artistMbid": ARTIST_A, "primaryType": "Album", "secondaryTypes": [],
                                             "releaseDate": "2026-10-01",
                                             "coverUrl": f"/api/artists/release-group/{RELEASE_GROUP}/cover",
                                             "inLibrary": False}],
                                 "tracks": []},
                     "localSearchConfigured": True, "filters": {}}
    if method == "GET" and parts == ["api", "search"]:
        q = query.get("q", "")
        if not q:
            return 400, {"error": "q parameter is required"}
        total = 30
        offset = max(0, int(query.get("offset", "0") or 0))
        limit = max(1, int(query.get("limit", "24") or 24))
        rng = list(range(offset, min(total, offset + limit))) if offset < total else []
        if query.get("scope") == "album":
            return 200, {"scope": "album", "query": q, "sort": "relevance", "count": total, "offset": offset,
                         "hasMore": offset + len(rng) < total,
                         "items": [{"type": "album", "id": "00000000-0000-4000-8000-%012d" % i, "title": f"{q} album {i}",
                                    "artistName": "Stub Arrows", "artistMbid": ARTIST_A, "primaryType": "Album",
                                    "secondaryTypes": [], "releaseDate": None, "coverUrl": None, "inLibrary": i == 0,
                                    "status": "missing", "score": 100 - i} for i in rng]}
        return 200, {"scope": "artist", "query": q, "count": total, "offset": offset,
                     "items": [{"type": "artist", "id": "00000000-0000-4000-9000-%012d" % i, "name": f"{q} {i}",
                                "sortName": f"{q} {i}", "image": None, "imageUrl": None, "inLibrary": False, "score": 0}
                               for i in rng]}
    shared = shared_answer(method, parts, body, accessflow)
    if shared is not None:
        return shared
    if method == "GET" and len(parts) == 4 and parts[1:3] == ["playlists", "jobs"]:
        if not accessflow:
            return 403, {"error": "Forbidden"}
        with LOCK:
            mine = STATE["shared"].get(parts[3])
            mine = dict(mine) if mine else None
        if mine is not None:
            return 200, shared_jobs(parts[3], mine)
        _, jobs = flows_and_jobs()
        return 200, [j for j in jobs if j["playlistId"] == parts[3]]
    if method == "POST" and len(parts) == 5 and parts[1:3] == ["playlists", "flows"] and parts[4] == "download":
        if not accessflow:
            return 403, {"error": "Forbidden"}
        if scenario == "no-downloader":
            return 409, {"error": "No download source is configured", "message": "No download source is configured"}
        return 200, {"success": True, "flowId": parts[3], "queued": True, "operationId": "op-download"}
    if method == "POST" and len(parts) == 7 and parts[1:3] == ["playlists", "shared-playlists"] and parts[6] == "research":
        if not accessflow:
            return 403, {"error": "Forbidden"}
        return 200, {"success": True, "jobId": parts[5], "playlistId": parts[3], "queued": True, "operationId": "op-research"}
    return None


class Handler(BaseHTTPRequestHandler):
    server_version = "AurralStub/2.13"

    def log_message(self, fmt, *args):  # quiet; the request log is /__stub/log
        pass

    def reply_bytes(self, status, data, content_type):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def reply(self, status, obj=None, headers=None):
        data = b"" if obj is None else json.dumps(obj).encode()
        self.send_response(status)
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        if obj is not None:
            self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def handle_any(self, method):
        split = urlsplit(self.path)
        path = split.path
        query = {k: v[0] for k, v in parse_qs(split.query, keep_blank_values=True).items()}
        if path == "/__stub/ping":
            return self.reply(200, {"ok": True, "source": SOURCE_SHA})
        if path == "/__stub/log":
            with LOCK:
                return self.reply(200, {"requests": list(STATE["log"])})
        if path == "/__stub/shared":
            with LOCK:
                return self.reply(200, {"playlists": [{"id": pid, "name": p["name"], "trackCount": len(p["tracks"]),
                                                       "tracks": [t["trackName"] for t in p["tracks"]]}
                                                      for pid, p in STATE["shared"].items()],
                                        "deletedFiles": list(STATE.get("deleted", [])),
                                        "failedCreates": list(STATE.get("failed", []))})
        if path == "/__stub/reset" and method == "POST":
            with LOCK:
                STATE.update(sessions={}, log=[], added={}, images={}, shared={}, deleted=[], failed=[])
            return self.reply(200, {"ok": True})
        scenario = self.headers.get("X-Stub-Scenario") or "default"
        m = re.match(r"^/s/([a-z0-9-]+)(/.*)$", path)
        if m:
            scenario, path = m.group(1), m.group(2)
        if scenario not in SCENARIOS:
            return self.reply(404, {"error": f"unknown scenario {scenario}"})
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        try:
            body = json.loads(raw) if raw else {}
            if not isinstance(body, dict):
                body = {}
        except ValueError:
            body = {}
        with LOCK:
            STATE["log"].append(f"{method} {path}")
            del STATE["log"][:-500]
        parts = [p for p in path.split("/") if p]
        user = user_for(scenario)
        if method == "GET" and path == "/api/health":
            return self.reply(200, {"status": "ok", "appVersion": "2.10.0" if scenario == "aurral210" else "2.13.0"})
        if method == "POST" and path == "/api/auth/login":
            if str(body.get("username", "")).strip().lower() != USERNAME or body.get("password") != PASSWORD:
                return self.reply(401, {"error": "Invalid username or password"})
            token = uuid.uuid4().hex
            with LOCK:
                STATE["sessions"][token] = scenario
            return self.reply(200, {"token": token, "expiresAt": int((time.time() + 30 * 86400) * 1000), "user": user})
        auth = self.headers.get("Authorization", "")
        token = auth[7:] if auth.startswith("Bearer ") else None
        with LOCK:
            signed_in = token is not None and token in STATE["sessions"]
        if method == "GET" and path == "/api/health/bootstrap":
            return self.reply(200, bootstrap_body(scenario, user if signed_in else None))
        if method == "GET" and path.startswith("/api/deezer/preview/") and scenario != "aurral210":
            track = path[len("/api/deezer/preview/"):]
            if not re.match(r"^\d{1,20}\.mp3$", track) or track.startswith("3135560"):
                return self.reply(404, {"error": "Preview not found"})
            if "download" in query:   # round 14 A7: Aurral sends the clip itself
                if scenario == "redirects":
                    return self.reply(302, None, {"Location": f"/s/default{path}?download", "Cache-Control": "no-store"})
                if scenario == "oversized":
                    return self.reply_bytes(200, OVERSIZED, "audio/mpeg")
                return self.reply_bytes(200, PREVIEW_CLIP, "audio/mpeg")
            return self.reply(302, None, {"Location": PREVIEW_TARGET, "Cache-Control": "no-store"})
        # Round 14 A7: the image proxy's file route is open (2.13 guards.ts isOpen).
        m = re.match(r"^/api/image-proxy/([a-f0-9]{64})(?:\.[a-z0-9]+)?$", path)
        if method == "GET" and m:
            with LOCK:
                cached = m.group(1) in STATE.setdefault("images", {})
            if not cached:
                return self.reply(404, {"error": "Image not found"})
            if scenario == "redirects":
                return self.reply(302, None, {"Location": f"/s/default{path}"})
            if scenario == "oversized":
                return self.reply_bytes(200, OVERSIZED, "image/png")
            return self.reply_bytes(200, PROXIED_PICTURE, "image/png")
        if not signed_in:
            return self.reply(401, {"error": "Unauthorized", "code": "AUTH_REQUIRED" if token is None else "SESSION_INVALID"})
        if method == "POST" and path == "/api/auth/logout":
            with LOCK:
                STATE["sessions"].pop(token, None)
            return self.reply(200, {"success": True})
        if method == "POST" and path == "/api/image-proxy":   # round 14 A7
            src = str(body.get("src") or "").strip()
            if not re.match(r"^https?://", src, re.I):
                return self.reply(400, {"error": "An http or https image URL is required"})
            key = hashlib.sha256(src.encode()).hexdigest()
            with LOCK:
                STATE.setdefault("images", {})[key] = src
            return self.reply(200, {"url": f"/api/image-proxy/{key}.png"})
        if method == "GET" and path == "/api/auth/me":
            return self.reply(200, {"user": user, "expiresAt": None})
        flow_reads = (method == "GET" and path in ("/api/playlists/status", "/api/playlists/jobs"))
        if flow_reads and scenario != "aurral210" and not may_access_flows(scenario):
            return self.reply(403, {"error": "Forbidden", "message": "Missing permission: accessFlow"})
        if method == "GET" and path == "/api/playlists/status":
            return self.reply(200, status_body())
        if method == "GET" and path == "/api/playlists/jobs":
            _, jobs = flows_and_jobs()
            return self.reply(200, jobs)
        if scenario != "aurral210":
            if scenario == "slow":
                time.sleep(2)
            if scenario == "failing" and parts[:2] in (["api", "discover"], ["api", "artists"], ["api", "search"]):
                return self.reply(502, {"error": "Stub failure"})
            answer = discover_answer(method, parts, query, body, scenario, user)
            if answer is not None:
                return self.reply(*answer)
        return self.reply(404, {"error": "Not found"})

    def do_GET(self):
        self.handle_any("GET")

    def do_POST(self):
        self.handle_any("POST")

    def do_PUT(self):
        self.handle_any("PUT")

    def do_DELETE(self):
        self.handle_any("DELETE")


def main():
    port = int(os.environ.get("AURRAL_STUB_PORT", "3901"))
    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    print(f"aurral stub on http://127.0.0.1:{port}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        server.server_close()


if __name__ == "__main__":
    sys.exit(main())
