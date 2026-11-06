#!/usr/bin/env python3
"""A fake Newznab indexer for the Magpie dev stack (round 20, R20-IT). Dev and tests only, never shipped in the app.

Lets the dev Lidarr grab: `dev/fake-indexer/setup.sh` adds it to Lidarr as "Magpie Fake Indexer" (Newznab) next to a
"Magpie Blackhole" download client. What it offers is set by the test through the control API; by default it offers
nothing (an RSS request gets one harmless self-test item, so Lidarr's connection test passes).

Python standard library only. Listens on 127.0.0.1 (default port 3903, `FAKE_INDEXER_PORT`; `FAKE_INDEXER_BIND` to
change the address). The Lidarr container reaches it as http://host.docker.internal:3903 (Docker Desktop forwards
host.docker.internal to the Mac's loopback).

Newznab (what Lidarr calls):
  GET /api?t=caps                         categories 3000 Audio, 3010 Audio/MP3, 3040 Audio/Lossless; search (q) and
                                          music/audio search (q, artist, album)
  GET /api?t=music&artist=..&album=..     RSS items for the releases whose match terms all appear in the query
  GET /api?t=search&q=..                  the same, for a free-text query
  GET /api?t=search (no query)            RSS: the self-test item only
  GET /nzb/<id>                           a minimal NZB for release <id>
Control (never sent by Lidarr):
  POST /control/releases   a release, a list of them, or {"releases": [...]}; each one:
                           {"title": "Artist - Album (2021) [MP3 320]",   required
                            "size": 104857600,                            bytes (default 100 MB)
                            "match": ["solar power"],                     every term must appear in the query
                                                                          (case and punctuation ignored); [] = any
                                                                          search with a query
                            "delaySeconds": 90,                           wait this long before answering a query it
                                                                          matches (a slow Soulseek-like search)
                            "category": 3010,                             default 3010 (3040 for a FLAC title)
                            "id": "abc", "files": [...], "note": "..."}   optional; files/note are kept for the test
                           A title may be a template: "{artist} - {album} (2021) [MP3 320]" is filled in from each
                           music search's artist and album (a release that is "whatever was searched for"); such a
                           release answers only searches that name an album. Each filled-in title gets its own id.
                           answers {"ids": [...]}
  GET  /control/releases   the table
  POST /control/reset      empties the table and the log
  GET  /control/log        {"queries": [...], "grabs": [...]}: every query (t, q, artist, album, matched ids, the
                           delay applied, start and end times) and every NZB fetched
  GET  /control/ping       {"ok": true, "source": <sha256 of this file>}
"""
import hashlib
import json
import os
import re
import threading
import time
import uuid
from email.utils import formatdate
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit
from xml.sax.saxutils import escape, quoteattr

with open(os.path.abspath(__file__), "rb") as _f:
    SOURCE_SHA = hashlib.sha256(_f.read()).hexdigest()

LOCK = threading.Lock()
RELEASES = []          # dicts, in the order added
QUERIES = []
GRABS = []
DERIVED = {}           # id -> a templated release filled in for one query
SELF_TEST = {"id": "self-test", "title": "Magpie Fake Indexer Self Test (2000) [MP3 320]", "size": 1048576,
             "match": [], "delaySeconds": 0, "category": 3010}

CAPS = """<?xml version="1.0" encoding="UTF-8"?>
<caps>
  <server version="1.0" title="Magpie Fake Indexer" />
  <limits max="100" default="100" />
  <registration available="no" open="no" />
  <searching>
    <search available="yes" supportedParams="q" />
    <tv-search available="no" supportedParams="q" />
    <movie-search available="no" supportedParams="q" />
    <audio-search available="yes" supportedParams="q,artist,album" />
    <music-search available="yes" supportedParams="q,artist,album" />
    <book-search available="no" supportedParams="q" />
  </searching>
  <categories>
    <category id="3000" name="Audio">
      <subcat id="3010" name="Audio/MP3" />
      <subcat id="3040" name="Audio/Lossless" />
    </category>
  </categories>
</caps>
"""


def norm(text):
    """Lower case, punctuation as spaces, single spaces: "Good Luck, Babe!" -> "good luck babe"."""
    return " ".join(re.sub(r"[^0-9a-z]+", " ", (text or "").lower()).split())


def matches(release, query):
    q = f" {norm(query)} "
    if not q.strip():
        return False
    return all(f" {norm(term)} " in q for term in release.get("match") or [])


def filled(release, params):
    """A templated release's title filled in from the search; None when the search names no album."""
    if "{" not in release["title"]:
        return release
    artist, album = params.get("artist"), params.get("album")
    if not (artist and album):
        return None
    title = release["title"].replace("{artist}", artist).replace("{album}", album)
    rid = f"{release['id']}-{hashlib.sha1(title.encode()).hexdigest()[:8]}"
    return dict(release, id=rid, title=title, template=release["title"])


def normalised(raw):
    r = dict(raw)
    if not r.get("title"):
        raise ValueError("a release needs a title")
    r["id"] = str(r.get("id") or uuid.uuid4().hex[:12])
    r["size"] = int(r.get("size") or 100 * 1024 * 1024)
    r["match"] = list(r.get("match") or [])
    r["delaySeconds"] = float(r.get("delaySeconds") or 0)
    r["category"] = int(r.get("category") or (3040 if "flac" in r["title"].lower() else 3010))
    r["addedAt"] = time.time()
    return r


def rss(items, base):
    out = ['<?xml version="1.0" encoding="UTF-8"?>',
           '<rss version="2.0" xmlns:atom="http://www.w3.org/2005/Atom" '
           'xmlns:newznab="http://www.newznab.com/DTD/2010/feeds/attributes/">',
           "<channel><title>Magpie Fake Indexer</title><description>dev only</description>"
           f"<link>{escape(base)}</link>"]
    for r in items:
        url = f"{base}/nzb/{r['id']}"
        published = formatdate(r.get("addedAt", time.time()) - 3600, usegmt=True)
        out.append(
            "<item>"
            f"<title>{escape(r['title'])}</title>"
            f"<guid isPermaLink=\"false\">magpie-fake-{escape(r['id'])}</guid>"
            f"<link>{escape(url)}</link>"
            f"<comments>{escape(base)}/details/{escape(r['id'])}</comments>"
            f"<pubDate>{published}</pubDate>"
            f"<category>Audio</category>"
            f"<enclosure url={quoteattr(url)} length=\"{r['size']}\" type=\"application/x-nzb\" />"
            f"<newznab:attr name=\"category\" value=\"3000\" />"
            f"<newznab:attr name=\"category\" value=\"{r['category']}\" />"
            f"<newznab:attr name=\"size\" value=\"{r['size']}\" />"
            "<newznab:attr name=\"grabs\" value=\"10\" />"
            "</item>")
    out.append("</channel></rss>")
    return "\n".join(out)


def nzb(release):
    name = escape(release["title"])
    now = int(time.time())
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE nzb PUBLIC "-//newzBin//DTD NZB 1.1//EN" "http://www.newzbin.com/DTD/nzb/nzb-1.1.dtd">
<nzb xmlns="http://www.newzbin.com/DTD/2003/nzb">
  <head><meta type="name">{name}</meta></head>
  <file poster="magpie@example.invalid" date="{now}" subject="&quot;{name}.rar&quot; yEnc (1/1)">
    <groups><group>alt.binaries.magpie.fake</group></groups>
    <segments><segment bytes="{release['size']}" number="1">magpie-fake-{escape(release['id'])}@example.invalid</segment></segments>
  </file>
</nzb>
"""


class Handler(BaseHTTPRequestHandler):
    server_version = "MagpieFakeIndexer/1.0"

    def log_message(self, fmt, *args):  # quiet; /control/log is the record
        pass

    def send(self, status, body, ctype="application/json", headers=None):
        data = body.encode() if isinstance(body, str) else body
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def json(self, status, obj):
        self.send(status, json.dumps(obj, indent=1))

    def base(self):
        return f"http://{self.headers.get('Host') or 'host.docker.internal:3903'}"

    def do_GET(self):
        parts = urlsplit(self.path)
        params = {k: v[-1] for k, v in parse_qs(parts.query).items()}
        path = parts.path.rstrip("/") or "/"
        if path in ("/api", "/api/v1/api"):
            return self.api(params)
        if path.startswith("/nzb/"):
            rid = path[len("/nzb/"):]
            with LOCK:
                release = next((r for r in RELEASES if r["id"] == rid), None) or DERIVED.get(rid)
                release = release or (SELF_TEST if rid == SELF_TEST["id"] else None)
                GRABS.append({"id": rid, "title": release and release["title"], "at": time.time()})
            if release is None:
                return self.send(404, "no such release", "text/plain")
            return self.send(200, nzb(release), "application/x-nzb",
                             {"Content-Disposition": f"attachment; filename=\"{release['title']}.nzb\""})
        if path == "/control/log":
            with LOCK:
                return self.json(200, {"queries": QUERIES, "grabs": GRABS})
        if path == "/control/releases":
            with LOCK:
                return self.json(200, {"releases": RELEASES})
        if path == "/control/ping":
            return self.json(200, {"ok": True, "source": SOURCE_SHA})
        self.send(404, "not found", "text/plain")

    def do_POST(self):
        path = urlsplit(self.path).path.rstrip("/")
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        if path == "/control/reset":
            with LOCK:
                RELEASES.clear(); QUERIES.clear(); GRABS.clear(); DERIVED.clear()
            return self.json(200, {"ok": True})
        if path == "/control/releases":
            try:
                body = json.loads(raw or b"null")
                items = body.get("releases") if isinstance(body, dict) and "releases" in body else body
                items = items if isinstance(items, list) else [items]
                new = [normalised(r) for r in items]
            except (ValueError, AttributeError, TypeError) as e:
                return self.json(400, {"error": str(e)})
            with LOCK:
                RELEASES.extend(new)
            return self.json(200, {"ids": [r["id"] for r in new]})
        self.send(404, "not found", "text/plain")

    def api(self, params):
        t = params.get("t", "search")
        if t == "caps":
            return self.send(200, CAPS, "application/xml")
        if t not in ("search", "music", "audio"):
            return self.send(200, rss([], self.base()), "application/rss+xml")
        query = " ".join(x for x in (params.get("artist"), params.get("album"), params.get("q")) if x)
        entry = {"t": t, "q": params.get("q"), "artist": params.get("artist"), "album": params.get("album"),
                 "cat": params.get("cat"), "start": time.time()}
        if not query.strip():
            items = [SELF_TEST]
        else:
            with LOCK:
                items = [filled(r, params) for r in RELEASES if matches(r, query)]
                items = [r for r in items if r is not None]
                DERIVED.update({r["id"]: r for r in items if r.get("template")})
        delay = max([r.get("delaySeconds", 0) for r in items] or [0])
        entry.update(matched=[r["id"] for r in items], delaySeconds=delay)
        with LOCK:
            QUERIES.append(entry)
        if delay:
            time.sleep(delay)
        entry["end"] = time.time()
        self.send(200, rss(items, self.base()), "application/rss+xml")


def main():
    port = int(os.environ.get("FAKE_INDEXER_PORT", "3903"))
    bind = os.environ.get("FAKE_INDEXER_BIND", "127.0.0.1")
    server = ThreadingHTTPServer((bind, port), Handler)
    server.daemon_threads = True
    print(f"Magpie fake indexer on http://{bind}:{port}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
