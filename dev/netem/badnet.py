#!/usr/bin/env python3
"""badnet: a bad-network HTTP proxy for the Magpie dev stack (no sudo, localhost only).

    dev/netem/badnet.py --listen 4600 --upstream 4533 --control /tmp/badnet.json

Sign the app in to http://127.0.0.1:4600 instead of :4533. Every request goes to the dev Navidrome on
127.0.0.1; faults apply only to audio (`/rest/stream`, `/rest/download`) unless "all": true.

The control file (JSON, re-read for every request, so edit it while the app plays) picks the fault:

  {"mode": "good"}                                    pass through
  {"mode": "stall",  "after": 65536, "secs": 20}      send `after` body bytes, go silent `secs`, then carry on
  {"mode": "drip",   "rate": 4096}                    body at `rate` bytes/s
  {"mode": "drop",   "after": 65536}                  close the TCP connection (FIN) after `after` body bytes
  {"mode": "reset",  "after": 65536}                  RST the connection after `after` body bytes
  {"mode": "5xx",    "status": 503}                   retries (a Range request not from 0) get `status`
  {"mode": "5xx-all","status": 503}                   every audio request gets `status`
  {"mode": "hdelay", "secs": 15}                      hold the response headers `secs`
  {"mode": "flap",   "period": 6, "bad": {...}}       alternate good / `bad` every `period` seconds (by request start)
  {"mode": "chaos",  "seed": 1}                       a random fault per audio request (stall/drip/drop/reset/5xx/hdelay/good)

Extra keys: "format": "aac"|"opus"|"raw" and "maxBitRate": 128 rewrite the stream query (forces a transcode
without touching the app's settings); "all": true applies faults to every request.
Logs one line per request to stderr.
"""
import argparse
import asyncio
import json
import random
import socket
import struct
import sys
import time
import urllib.parse

UPSTREAM_HOST = "127.0.0.1"
AUDIO_PATHS = ("/rest/stream", "/rest/download")
START = time.monotonic()
counter = 0


def log(*a):
    print(f"[{time.monotonic() - START:8.2f}]", *a, file=sys.stderr, flush=True)


def load_control(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {"mode": "good"}


async def read_head(reader):
    data = await reader.readuntil(b"\r\n\r\n")
    return data


def parse_headers(head: bytes):
    lines = head.decode("latin-1").split("\r\n")
    first = lines[0]
    headers = []
    for line in lines[1:]:
        if not line:
            continue
        k, _, v = line.partition(":")
        headers.append((k.strip(), v.strip()))
    return first, headers


def build_head(first, headers):
    return (first + "\r\n" + "".join(f"{k}: {v}\r\n" for k, v in headers) + "\r\n").encode("latin-1")


def header(headers, name):
    for k, v in headers:
        if k.lower() == name.lower():
            return v
    return None


def rewrite_target(target, ctl):
    if "format" not in ctl and "maxBitRate" not in ctl:
        return target
    parts = urllib.parse.urlsplit(target)
    q = urllib.parse.parse_qsl(parts.query, keep_blank_values=True)
    q = [(k, v) for k, v in q if k not in ("format", "maxBitRate")]
    if "format" in ctl:
        q.append(("format", ctl["format"]))
    if "maxBitRate" in ctl:
        q.append(("maxBitRate", str(ctl["maxBitRate"])))
    return urllib.parse.urlunsplit(parts._replace(query=urllib.parse.urlencode(q)))


def pick_fault(ctl, n):
    mode = ctl.get("mode", "good")
    if mode == "flap":
        period = ctl.get("period", 6)
        bad = ctl.get("bad", {"mode": "stall", "after": 32768, "secs": 10})
        return bad if int((time.monotonic() - START) / period) % 2 else {"mode": "good"}
    if mode == "chaos":
        rng = random.Random(ctl.get("seed", 1) * 100003 + n)
        return rng.choice([
            {"mode": "good"},
            {"mode": "stall", "after": rng.choice([0, 8192, 65536, 262144]), "secs": rng.choice([3, 8, 15, 30])},
            {"mode": "drip", "rate": rng.choice([2048, 4096, 8192])},
            {"mode": "drop", "after": rng.choice([0, 4096, 65536, 300000])},
            {"mode": "reset", "after": rng.choice([0, 4096, 65536, 300000])},
            {"mode": "5xx", "status": rng.choice([500, 502, 503])},
            {"mode": "5xx-all", "status": 503},
            {"mode": "hdelay", "secs": rng.choice([2, 8, 20])},
        ])
    return ctl


def rst(writer):
    sock = writer.get_extra_info("socket")
    if sock is not None:
        try:
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
        except OSError:
            pass
    writer.transport.abort()


async def handle(creader, cwriter, args):
    global counter
    try:
        while True:
            try:
                head = await read_head(creader)
            except (asyncio.IncompleteReadError, ConnectionError):
                return
            first, headers = parse_headers(head)
            method, target, version = first.split(" ", 2)
            body = b""
            cl = header(headers, "Content-Length")
            if cl:
                body = await creader.readexactly(int(cl))
            ctl = load_control(args.control)
            path = urllib.parse.urlsplit(target).path
            is_audio = path.startswith(AUDIO_PATHS)
            counter += 1
            n = counter
            fault = pick_fault(ctl, n) if (is_audio or ctl.get("all")) else {"mode": "good"}
            if is_audio:
                target = rewrite_target(target, ctl)
            rng = header(headers, "Range")
            keep = header(headers, "Connection")
            client_keepalive = not (keep and keep.lower() == "close")
            short = path + ("?" + "id=" + dict(urllib.parse.parse_qsl(urllib.parse.urlsplit(target).query)).get("id", "")
                            + " fmt=" + dict(urllib.parse.parse_qsl(urllib.parse.urlsplit(target).query)).get("format", "-")
                            if is_audio else "")
            log(f"#{n} {method} {short} range={rng} fault={json.dumps(fault)}")

            mode = fault.get("mode", "good")
            if mode in ("5xx", "5xx-all") and is_audio:
                retry = rng is not None and not rng.startswith("bytes=0-")
                if mode == "5xx-all" or retry:
                    status = fault.get("status", 503)
                    msg = b"server error\n"
                    cwriter.write(f"HTTP/1.1 {status} Error\r\nContent-Type: text/plain\r\nContent-Length: {len(msg)}\r\n"
                                  f"Connection: close\r\n\r\n".encode() + msg)
                    await cwriter.drain()
                    log(f"#{n} -> {status}")
                    cwriter.close()
                    return

            # One upstream connection per request, closed by upstream at the end of the body.
            ureader, uwriter = await asyncio.open_connection(UPSTREAM_HOST, args.upstream)
            uheaders = [(k, v) for k, v in headers if k.lower() not in ("connection", "keep-alive", "proxy-connection")]
            uheaders = [(k, (f"{UPSTREAM_HOST}:{args.upstream}" if k.lower() == "host" else v)) for k, v in uheaders]
            uheaders.append(("Connection", "close"))
            uwriter.write(build_head(f"{method} {target} {version}", uheaders) + body)
            await uwriter.drain()
            try:
                rhead = await read_head(ureader)
            except asyncio.IncompleteReadError:
                cwriter.close()
                return
            rfirst, rheaders = parse_headers(rhead)
            chunked = (header(rheaders, "Transfer-Encoding") or "").lower() == "chunked"
            has_len = header(rheaders, "Content-Length") is not None
            # Keep the client connection alive only when the body is delimited; otherwise close after it.
            reuse = client_keepalive and (has_len or chunked)
            rheaders = [(k, v) for k, v in rheaders if k.lower() not in ("connection", "keep-alive")]
            rheaders.append(("Connection", "keep-alive" if reuse else "close"))
            if mode == "hdelay":
                await asyncio.sleep(fault.get("secs", 10))
            cwriter.write(build_head(rfirst, rheaders))
            await cwriter.drain()
            log(f"#{n} <- {rfirst} len={header(rheaders, 'Content-Length')} chunked={chunked}")

            sent = 0
            stalled = False
            after = fault.get("after", 65536)
            while True:
                chunk = await ureader.read(16384 if mode != "drip" else max(256, fault.get("rate", 4096) // 4))
                if not chunk:
                    break
                if mode in ("drop", "reset") and is_audio and sent + len(chunk) > after:
                    cut = max(0, after - sent)
                    if cut:
                        cwriter.write(chunk[:cut])
                        await cwriter.drain()
                    log(f"#{n} {mode} after {sent + cut} bytes")
                    uwriter.close()
                    if mode == "reset":
                        rst(cwriter)
                    else:
                        cwriter.close()
                    return
                if mode == "stall" and is_audio and not stalled and sent + len(chunk) > after:
                    cut = max(0, after - sent)
                    cwriter.write(chunk[:cut])
                    await cwriter.drain()
                    log(f"#{n} stall {fault.get('secs', 20)}s at {sent + cut} bytes")
                    await asyncio.sleep(fault.get("secs", 20))
                    stalled = True
                    chunk = chunk[cut:]
                    sent += cut
                cwriter.write(chunk)
                await cwriter.drain()
                sent += len(chunk)
                if mode == "drip" and is_audio:
                    await asyncio.sleep(len(chunk) / max(1, fault.get("rate", 4096)))
            uwriter.close()
            log(f"#{n} done {sent} bytes")
            if not reuse:
                cwriter.close()
                return
    except (ConnectionError, asyncio.IncompleteReadError, OSError) as e:
        log(f"conn error: {e!r}")
        try:
            cwriter.close()
        except Exception:
            pass


async def main():
    p = argparse.ArgumentParser()
    p.add_argument("--listen", type=int, default=4600)
    p.add_argument("--upstream", type=int, default=4533)
    p.add_argument("--control", default="badnet.json")
    args = p.parse_args()
    server = await asyncio.start_server(lambda r, w: handle(r, w, args), "127.0.0.1", args.listen)
    log(f"badnet on 127.0.0.1:{args.listen} -> {UPSTREAM_HOST}:{args.upstream}, control {args.control}")
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    asyncio.run(main())
