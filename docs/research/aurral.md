# Aurral: research notes (2026-11-01)

Read-only research. Sources: the upstream project (github.com/lklynet/aurral, MIT, JS/TS,
docs under `docs/src/content/docs`), read at tag **v2.10.0** (the version the owner's Aurral
reports) and at HEAD (v2.12+); plus GET-only probes of the owner's Aurral and GET-only
Subsonic reads of the owner's Navidrome. No POST/PUT/DELETE was sent. No secrets appear here.

## What Aurral is

A self-hosted "Overseerr for music": searches MusicBrainz/Last.fm, adds artists/albums to
Lidarr, builds recommendation-driven **flows** (scheduled, auto-regenerating playlists) and
static playlists, downloads single tracks itself via slskd / Usenet (Prowlarr+SABnzbd) /
yt-dlp / deemix, and publishes playlists to Navidrome, Plex or Jellyfin. It also has its own
Subsonic server at `/rest` (players can connect to Aurral directly).

## API basics

- JSON API base: `<aurral>/api`. (Subsonic API: `<aurral>/rest`.)
- Auth: header **`X-Api-Key: <key>`** (also accepted as `?api_key=` query; avoid). The key
  is instance-wide and gives **full admin** — there is no read-only mode. Some per-user
  actions (favorites, plays, scrobbling links) return 403 with the API key.
- With the key, `/api/auth/me` returns a synthetic user `{id:-1, username:"api", role:"admin"}`.
- `GET /api/health/bootstrap` (no auth): `appVersion`, `lidarrConfigured`,
  `slskdConfigured`, `downloadSources{slskd,usenet,deemix,ytdlp}{enabled,configured,priority}`, ...
- Avoid even as GET: `/api/auth/api-key` (reads **or creates** the key) and
  `/api/playlists/flows/:flowId/lidarr-import-list` (creates a feed token).
  `GET /api/discover` can kick a stale per-user discovery refresh; `/api/health` exposes
  discovery refresh state without that.
- Version note: the owner runs **2.10.0** (Express backend, `backend/routes/weeklyFlow`).
  HEAD has moved to Hono/TS and added routes (`/api/discover/status`,
  `/api/playlists/flow-templates`) that return **404 on the owner's Aurral**. Pin to 2.10
  behaviour; feature-detect.

## Endpoints probed (GET, owner's Aurral) and response shapes

| Endpoint | Result | Shape (field names) |
|---|---|---|
| `/api/health/live` | 200 | tiny ok body |
| `/api/health/bootstrap`, `/api/health` | 200 | see above; `/api/health` adds `library{artistCount,lastScan}`, `discovery{provider,isUpdating,updatePhase,updateProgress,lastUpdated,recommendationsCount,capabilities.flows{discover,trending,mix,focus}}` |
| `/api/auth/me` | 200 | `{user{id,username,role,permissions{accessSettings,accessFlow,addArtist,addAlbum,changeMonitoring,deleteArtist,deleteAlbum,deleteTrack}},expiresAt}` |
| **`/api/playlists/status`** | 200 | `worker{running,processing,activeCount,stats{total,pending,downloading,blocked,done,failed},settings{concurrency,existingFileMode}}`, `slskd{configured,connected,downloadPath,serverState}`, `flowStats{<flowId>:{...counts}}`, **`flows[]`**`{id,name,ownerUserId,ownerUsername,enabled,recordHistory,scheduleDays,scheduleTime,deepDive,yearFrom,yearTo,nextRunAt,lastRunAt,size,mix{discover,mix,trending,focus},tags,relatedArtists,discoverPresetId,description,lidarrFeedToken,createdAt}`, `sharedPlaylists[]`, `retryCyclePausedByPlaylist`, `operationQueue{processing,pending,currentLabel}`, `hint{phase,message}` (e.g. "Next update in 5 days") |
| **`/api/playlists/jobs`** (and `/jobs/:flowId`) | 200 | array of track jobs: `id, artistName, trackName, albumName, reason, artistMbid, albumMbid, trackMbid, releaseYear, durationMs, trackNumber, albumTrackCount, albumTrackTitles, artistAliases, playlistId/playlistType (=flowId), managedBy ("aurral"), status (pending/downloading/blocked/done/failed), startedAt, completedAt, stagingPath, finalPath, externalPath, error, downloadSource/downloadClient (slskd/ytdlp/usenet), releaseTitle, remoteUsername, remoteFilename, quality*` |
| `/api/playlists/worker/settings` | 200 | `{concurrency,retryPausedPlaylistIds,existingFileMode}` |
| `/api/settings` (admin) | 200 | top keys `downloadFolderPath, rootFolderPath, pathMappings[], flows[], sharedPlaylists, playlistWorker, integrations{lidarr,slskd,navidrome,plex,jellyfin,...}, subsonic, quality, qualityProfile, ...` — **contains every integration secret in clear; never log/persist it** |
| `/api/settings/playback`, `/download-clients` | 200 | integration field metadata |
| `/api/settings/storage-health` | 200 | last snapshot only (does not re-run checks): `sections[{id,title,status,steps[{id,status,label,detail}]}]` |
| `/api/settings/lidarr/test-library-access`, `/lidarr/root-folders` | 200 | Lidarr root folders + whether Aurral can read them |
| `/api/library/rootfolder` | 200 | `[{path}]` |
| `/api/library/lookup/:artistMbid` | 200 | `{exists, artist, albums[], canonical}` |
| `/api/requests` | 200 | artist/album request list |
| `/api/discover/status`, `/api/playlists/flow-templates` | **404** | HEAD-only routes |

Owner's state at probe time: two flows, both enabled, 20 tracks, scheduled Fridays 00:00:
**"Discover Weekly"** (mix discover=100) and **"Trending Mix"** (trending=100). 40 jobs:
30 done, 9 failed, 1 blocked. Sources: slskd 32, yt-dlp 8. Discovery provider: Last.fm.

## (a) Refresh Flow — NOT called

- **`POST /api/playlists/start/:flowId`**, JSON body `{ "limit": n }` optional (defaults to
  the flow's `size`). Response `{success, flowId, queued:true, operationId}`. It enqueues a
  regeneration + download run (one song per artist); each run **replaces** the flow's tracks.
- Related: `PUT /api/playlists/flows/:flowId/enabled`; `POST /api/playlists/research-missing`
  (re-search failed); `POST /api/discover/refresh` (admin: rebuild recommendations, not a flow run);
  `POST /api/playlists/playlist/:playlistType/create` (admin: re-sync playlists to media servers).
- Poll progress with `GET /api/playlists/status` (`operationQueue`, `flowStats`, `hint`).

## (b) Aurral playlists ↔ Navidrome

- **Same Navidrome** as Magpie talks to (Aurral is configured with the same port on the same
  machine via an internal hostname). Aurral publishes each flow / static playlist through the
  Subsonic API as a normal Navidrome playlist owned by the configured Navidrome account,
  **public**, named after the flow (owner has the "username - " prefix **off**). Aurral stores
  the Navidrome playlist ID per flow and renames/updates it in place.
- **Separate Navidrome library**: Aurral creates a library named **"Aurral Playlists"** rooted
  at its Downloads Folder. Owner's Navidrome libraries: `1 Music Library`, `2 Aurral Playlists`,
  `3 Finds` (Finds currently empty). All 14 "Discover Weekly" and 15 "Trending Mix" entries
  are in library 2 (verified via `search3?musicFolderId=`).
- Identify Aurral playlists in Navidrome: name equals an Aurral flow name (`/api/playlists/status`
  `flows[].name`) and/or every entry belongs to the "Aurral Playlists" music folder. Navidrome's
  own playlist `comment` is null, so there is no marker field.
- Aurral can also reuse a Lidarr file instead of downloading (`existingFileMode: "reuse"`);
  such entries would live in the main library. None of the owner's current flow tracks do.
- Navidrome only lists a track once indexed, so a playlist can be shorter than the flow
  (14/20, 15/20 now: failures plus unindexed).

## (c) Artist of each playlist song; add-artist action

- From Aurral: every job has `artistName` + **`artistMbid`** (also `albumMbid`, `trackMbid`).
  Join a Navidrome entry to its job by `musicBrainzId` (Navidrome's track MBID equals
  Aurral's `trackMbid` when tagged) or by title+artist.
- From Navidrome: playlist entries carry `artist`, `artistId`, `albumArtists[]`,
  `musicBrainzId`; the artist MBID is available via Navidrome's artist record.
- **Aurral has add-artist**: `POST /api/library/artists` with
  `{ foreignArtistId: <artistMbid>, artistName, monitorOption?, rootFolderPath?, qualityProfileId?, tagId?, managedBy? }`
  — with Lidarr connected this adds the artist to Lidarr using Aurral's Lidarr defaults
  (owner: quality profile 2, metadata profile 1, monitor "all", search on add, root `/music`).
  Returns the existing artist if already present. Check first with
  `GET /api/library/lookup/:artistMbid` (`exists`).
- Per-track keep: `POST /api/library/downloads/track` (`artistName, trackName, albumName,
  artistMbid, albumMbid, trackMbid, ...`) = the UI's "Add to library" (promotes into Aurral's
  permanent `Artist/Album/Track` tree, not Lidarr). The owner can alternatively add the
  artist in Lidarr directly (Magpie already has Lidarr access).

## (d) Where downloaded singles live

- Aurral Downloads Folder: **`/data/downloads/aurral`** (container path).
  - Flow tracks (temporary): `/data/downloads/aurral/_flows/<flowId>/<Artist>/<Album>/<Track>.<ext>`
    — all 30 of the owner's finished jobs are here (`finalPath`). Removed/replaced on the next run
    unless a static playlist references them.
  - Promoted ("Add to library") tracks: `/data/downloads/aurral/<Artist>/<Album>/<Track>`.
  - Artwork/sidecars: `aurral-weekly-flow/_playlists`.
  - slskd raw downloads: slskd `/app/downloads` mapped to `/data/downloads` (Aurral path mapping);
    `cleanupAfterRuns: true`.
- Lidarr roots (from Lidarr via Aurral): `/music` (main, "Music Library") and `/finds`
  ("Finds", own profiles, monitor none). **Aurral can read `/music` but not `/finds`**
  (library-access test fails on `/finds`).
- Replacement path for a later Lidarr copy: once Lidarr imports the album into `/music` and
  Navidrome scans it, the main library has its own copy; the Aurral copy stays in "Aurral
  Playlists" until the flow rotates it out (flow files) or it is deleted (promoted files,
  `DELETE /api/library/tracks/:id`, not called). Aurral deletes files only in its Downloads
  Folder, never Lidarr's. With `existingFileMode: reuse`, a later flow run picks the Lidarr file
  instead of downloading again. Magpie should not touch Aurral's files directly.

## Safety for Magpie integration

- Key = full admin. Keep it in the keychain; GET-only for status; the only intended write
  would be the user-initiated refresh (`POST /api/playlists/start/:flowId`) and optionally
  add-artist.
- Never fetch `/api/settings` in the app (secrets). Use `/api/playlists/status` for flows.
- Feature-detect by `appVersion` / 404s; HEAD routes differ from 2.10.
