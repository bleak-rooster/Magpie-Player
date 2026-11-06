# Magpie dev stack

A local Navidrome + Lidarr pair with a generated fixture library, for building and testing the app.
**Dev only.** Ports bind to `127.0.0.1`, and the credentials are throwaway.

| Service | Version (pinned) | URL |
|---|---|---|
| Navidrome | `deluan/navidrome:0.64.2` | http://127.0.0.1:4533 |
| Lidarr | `lscr.io/linuxserver/lidarr:develop-3.2.0.5144-ls269` (3.2.x is only on the develop channel; `latest` is 3.1.6) | http://127.0.0.1:8686 |
| slskd (optional profile `quickfetch`) | `slskd/slskd:0.26.2`, offline (`SLSKD_NO_CONNECT`) and no auth | http://127.0.0.1:5030 |

## Stub Aurral (round 14)

The dev stack has no Aurral. `dev/aurral-stub/start.sh` starts a small stdlib-Python stub Aurral 2.13 on
http://127.0.0.1:3901 (if it isn't running) serving the same fixtures as `MagpieTestSupport.StubAurral`; pick a scenario
by address, e.g. `http://127.0.0.1:3901/s/no-access-flow` (list in `dev/aurral-stub/server.py`). `MAGPIE_IT=1
scripts/test-app.sh` and `scripts/it.sh` start it. Tests and dev only: it is never part of the app.

## Run it

```sh
dev/bootstrap.sh     # generate fixtures if needed, start containers, configure everything (re-runnable)
dev/smoke.sh         # PASS/FAIL/SKIP for every API the app uses; exit code = number of FAILs
```

You need Docker, `curl`, `jq`, `openssl` and `ffmpeg` (`brew install ffmpeg`).

`bootstrap.sh` does the following, and every step is idempotent:

1. Runs `fixtures/make-library.sh` if `dev/data/music/library` is empty.
2. Runs `docker compose up -d` and waits for `/ping` on both services.
3. Navidrome:
   - creates the `admin` user (`POST /auth/createAdmin`, first run only) and the normal user `listener` (`POST /api/user`)
   - creates the **Samples** library at `/music/samples` (`POST /api/library`)
   - grants `listener` both libraries (`PUT /api/user/{id}/library`)
   - sets the listener's `scrobbleFilter` to exclude Samples
   - runs `startScan` and waits for the scan to finish
4. Lidarr:
   - reads `ApiKey` from `/config/config.xml`
   - sets UI forms login (`admin` + generated password)
   - adds root folders `/music/library` and `/music/samples`
   - adds a **Subsonic connection to Navidrome** (`http://navidrome:4533`, "Update Library" on; Lidarr's connection test passes)
   - turns on track renaming and audio tag writing for new files
5. Prints a summary.

It deliberately does **not** create the app-specific Lidarr objects: the Fast Start and Lossless quality profiles, the Albums+EPs metadata profile, and the `sample` tag. Creating those is the app's setup flow (spec §13), and this stack is where that flow gets tested.

## Credentials

All credentials are in **`dev/.env.local`**. The file is gitignored, `chmod 600`, and written by bootstrap. It holds:

- `NAVIDROME_ADMIN_USER` / `NAVIDROME_ADMIN_PASSWORD`
- `NAVIDROME_LISTENER_USER` / `NAVIDROME_LISTENER_PASSWORD`
- `NAVIDROME_MAIN_LIBRARY_ID` / `NAVIDROME_SAMPLES_LIBRARY_ID`
- `LIDARR_API_KEY`
- `LIDARR_UI_USER` / `LIDARR_UI_PASSWORD` (the same as the Navidrome admin password)

Passwords are generated on first run and reused afterwards. If you delete `.env.local` but keep the volumes, bootstrap can't log in. Run `dev/reset.sh` in that case.

## Reset

```sh
dev/reset.sh                 # asks first; removes containers, compose volumes, dev/data/ and dev/.env.local
dev/reset.sh --yes --keep-music   # no prompt; keeps dev/data/music (skips regenerating fixtures)
```

`reset.sh` only touches the `magpie-dev` compose project and paths inside `dev/`.

## Layout

```
dev/data/music/library   -> /music/library   Navidrome library 1 + Lidarr root folder
dev/data/music/samples   -> /music/samples   Navidrome library 2 "Samples" + Lidarr root folder
dev/data/downloads       -> /downloads       Lidarr (and slskd) downloads
navidrome_data, lidarr_config, slskd_app     named volumes (SQLite stays off the macOS bind mount)
```

Both containers mount the same `/music` tree, so Lidarr and Navidrome paths are identical and no path mapping is needed. Samples sits on the same volume as the library, so Lidarr's Keep move is a rename.

To test from a physical iPhone on the LAN: `MAGPIE_BIND=0.0.0.0 dev/bootstrap.sh`. Then use your Mac's LAN IP.

Optional profiles:
- `docker compose -f dev/docker-compose.yml --profile quickfetch up -d slskd` starts slskd for API-shape testing only. It never connects to Soulseek.
- `tubifarry` is a TODO, and the compose file has a commented sketch. Tubifarry installs as a Lidarr plugin (mainline since 3.1.2-develop) and should run in its own config volume.

## Fixture library (`fixtures/make-library.sh`)

The fixtures are 41 tracks in 6 albums by 4 main artists plus Various Artists (with 2 extra compilation-only artists), and 1 track in Samples. Each track is 8–20 s of sine or chirp audio with light noise. Every file has full tags and an embedded PNG cover. Generation takes about 10 s.

| Album | Format | Edge case |
|---|---|---|
| Aurora Field – *Continuum* (2019) | FLAC | **Gapless**: one continuous chirp split at sample-exact boundaries, so any gap or click is audible. Full MBIDs, ISRC, label, folder `cover.png`. |
| Aurora Field – *Lowlands* (2016) | MP3 CBR 192 | **With** the Xing/LAME header (encoder delay and padding for gapless), embedded cover only. |
| Éléonore Brûlé – *Café de la Mémoire* (2008) | MP3 CBR 160 | **No** Xing/LAME header (`-write_xing 0`). Accents in artist, album, titles and paths (`Œ`, `Ç`, `'`). **No MusicBrainz IDs.** |
| 坂本光 – *夜明けの街* (2021) | AAC/M4A | CJK names and a **~150-character title**. No MBIDs: ffmpeg can't write iTunes freeform atoms. |
| The Midnight Cartographers – *Atlas of Small Hours* (2022) | FLAC | **Multi-disc** (2×5) split across `CD1/` and `CD2/`, a featured artist, `:` in a filename. |
| Various Artists – *Late Night Finds, Vol. 1* (2023) | MP3 V0 | **Compilation** (`TCMP=1`, the real MB "Various Artists" MBID) with artists inside and outside the library. |
| *Samples:* Kites Over Lagos – *Paper Planes* (2024) | MP3 | Single in the Samples library, by an artist whose only other track is on the compilation. |

MBIDs are deterministic v4-style UUIDs derived from the names. They look real but don't resolve on MusicBrainz, apart from the Various Artists one. Re-running the script only creates missing files. `--force` regenerates everything.

Cover text needs ffmpeg's `drawtext`. Homebrew's ffmpeg lacks it, so the script renders covers with the ffmpeg inside the pinned Navidrome image and a host Unicode font (`Arial Unicode.ttf` on macOS; override with `FONT=`). If neither is available, covers are plain gradients.

## Smoke test coverage

- **Navidrome:**
  - `/auth/login` for admin and listener
  - `ping` with client-side `t`/`s` token auth
  - `getOpenSubsonicExtensions` and `getMusicFolders` (listener sees Samples)
  - `search3`: plain, CJK, accent-folding, and `musicFolderId` scoping
  - `getAlbumList2`: all, and scoped to the main library
  - `getAlbum`: multi-disc, compilation, MBID and ISRC tags
  - MP3 TXXX MBID mapping
  - `stream`: Range 206, HEAD, and FLAC→MP3 transcode
  - `getCoverArt`, `getScanStatus`
  - native `/api/album` (paged, `X-Total-Count`), `/api/song?library_id=`, `/api/library`
- **Lidarr:**
  - `system/status`, `rootfolder` (both roots), `qualityprofile`, `metadataprofile`, `artist`, `queue/status`, `notification` (Subsonic)
  - a request without a key gets 401
  - `artist/lookup` reports **SKIP** instead of FAIL when the external metadata server is unreachable

## Fake indexer and blackhole: real grabs and imports (round 20)

Out of the box the dev Lidarr has no indexer and no download client, so nothing downloads. `dev/fake-indexer/` adds
both, for tests that need the whole grab → download → import path (Try and Finds end to end):

```sh
dev/fake-indexer/setup.sh    # idempotent: starts the indexer, creates the blackhole folders, adds both to Lidarr if missing
cd Packages/MagpieKit && MAGPIE_IT=1 MAGPIE_LIVE=1 swift test --filter DownloadFlowIT
```

- `server.py`: a stdlib-Python Newznab indexer on http://127.0.0.1:3903 (`FAKE_INDEXER_PORT`). Lidarr reaches it as
  `http://host.docker.internal:3903` (Docker Desktop forwards that to the Mac's loopback; no compose change). It offers
  nothing until a test says what to offer: `POST /control/releases` (title, size, match terms, `delaySeconds` for a
  slow Soulseek-like search; a title like `{artist} - {album} (2021) [MP3 320]` is filled in from each search),
  `POST /control/reset`, `GET /control/log` (every query and NZB fetch). Details at the top of the file.
- `setup.sh` adds a Newznab indexer **Magpie Fake Indexer** (RSS off, so nothing is grabbed unasked) and a Usenet
  Blackhole download client **Magpie Blackhole**: NZB folder `/downloads/magpie-blackhole/nzb`, watch folder
  `/downloads/magpie-blackhole/complete` (host: `dev/data/downloads/magpie-blackhole/…`). Nothing else is changed;
  remove them in Lidarr's settings to go back to a stack that never downloads.
- Nobody downloads anything: the test plays the downloader. When an NZB appears it builds a folder named like the
  release in the watch folder (silent 320 kbit/s MP3s as long as Lidarr's tracks, tagged with the MusicBrainz ids, via
  ffmpeg; without ffmpeg, copies of the fixture single), and Lidarr's completed-download handling imports it.
- `DownloadFlowIT` uses Lorde's "Solar Power" (a Single and a studio album of that name), so the dev Lidarr must not
  have Lorde, and real MusicBrainz (`MAGPIE_LIVE=1`). It removes the artist it added (`deleteFiles=false`), then the
  files it made on the host. In a git worktree, link `dev/.env.local` and `dev/data` to the main checkout's first.
