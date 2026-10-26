# Direct slskd "first song" path — research notes

Researched 2026-10-26. Question: can a Keeper device skip Lidarr's album-granular pipeline, fetch **one** good MP3 straight from the user's slskd, hand it to Lidarr via Manual Import, and let Lidarr upgrade the album to FLAC later?

Sources: slskd `master` (2b82734, 2026-10-25) plus the `0.26.2` tag (latest release, 2026-10-23); Lidarr `develop` (v3.2.0.5144) source; Tubifarry `develop`; Apple App Review Guidelines (fetched today); web search.
**Live tests** used throwaway containers `slskd/slskd:0.26.2` and `linuxserver/lidarr:latest` (3.1.6.5079) with a shared `/downloads` volume. slskd had **no Soulseek credentials** and a dead server address, so it never touched the network. The audio files were ffmpeg sine tones. The test artist was the CC-licensed act Brad Sucks, used only as metadata. Everything has been removed.

Legend: **[live]** = observed in the test containers · **[code]** = read in source · **[doc]** = official docs · **[est]** = estimate or inference.

---

## 0. Verdict

**It works, and it is the fastest first-song path available. Every step is verified except the actual Soulseek transfer.** Lidarr accepts a single-track manual import into an album and imports a tagless file in **about 0.6 s** [live]. It writes full MusicBrainz tags [live], leaves the album "missing" and "cutoff unmet" so Lidarr keeps working on it [live], and a later full-album FLAC import **replaces** the MP3 and fills in the remaining tracks [live]. slskd has CORS fully open [live] and a clean v0 REST API [live/code].

Four traps need specific handling (details below):
1. **Use `replaceExistingFiles` correctly.** Lidarr fires its import notifications, including the **Subsonic → Navidrome rescan**, *only* when `replaceExistingFiles: true`. That same flag **deletes every existing file of the album** [live+code]. Use `true` only when the album has 0 files. Otherwise use `false` and have the Keeper (a Navidrome admin) call `startScan` itself.
2. **Don't rely on slskd API key roles.** In the shipped 0.26.2, a key configured `readonly` can still start searches, enqueue downloads, rescan shares and delete downloaded files [live]. Proper per-endpoint role checks exist only on unreleased `master` [code]. Treat any slskd key as close to full control.
3. **App Store risk is real.** Guideline 5.2.3 bans apps that "facilitate illegal file sharing". LunaSea's developer said Apple rejects even *remote* P2P-client integrations, although several torrent-remote apps are on the store today. A first-class "Soulseek" feature in the iOS binary is the single biggest review risk in the project (§7).
4. **Turn on renaming.** With Lidarr's default `renameTracks: false`, the manually imported file lands loose in the **artist root** with its Soulseek filename [live]. Setup must enable track renaming.

**Recommendation:** ship it as an **owner-enabled, Keeper-only "fast lane" adapter**. Make it generic in UI and store copy, off by default, and Mac-helper-first if review pushes back (§8 tiers).

---

## 1. slskd REST API (v0) — verified shape

Base: `http(s)://host:5030/api/v0` (honours `web.url_base`). The OpenAPI/Swagger UI is available if the `swagger` feature is enabled [doc].

### 1.1 Auth
| Method | How | Notes |
|---|---|---|
| API key | header **`X-API-Key: <key>`** (SignalR: `?access_token=`) | Keys in `web.authentication.api_keys.<name>: {key (16–255 chars), role: readonly\|readwrite\|administrator, cidr}`; primary key via `SLSKD_API_KEY` defaults to **Administrator** [doc/code] |
| JWT | `POST /api/v0/session {username,password}` → `{token, expires, …}`; then `Authorization: Bearer` | Default creds `slskd/slskd`; TTL 7 days; random signing key per restart unless configured → tokens die on restart [doc/live] |
| none | 401 without credentials [live] | `SLSKD_NO_AUTH` disables auth entirely |

**Role enforcement in 0.26.2 [live, three keys tested]:**

| Endpoint | readonly key | readwrite key | admin key |
|---|---|---|---|
| `POST /searches` | **allowed** | allowed | allowed |
| `POST /transfers/downloads/batches` | **allowed** | allowed | allowed |
| `DELETE /files/downloads/files/{b64}` | **allowed** (if remote file mgmt on) | allowed | allowed |
| `PUT /shares` (rescan) | **allowed** | allowed | allowed |
| `GET /options` | 403 | 403 | 200 |
| `PUT /server` (connect/disconnect) | 403 | 403 | 200 |

The 0.26.2 tag's `SearchesController` has only `[Authorize(Policy = Any)]`. `master` adds `Roles = ReadWriteOrAdministrator` [code]. **Conclusion:** the app needs at least a readwrite-equivalent key, and today any non-admin key can do everything except options, server connection and logs. Recommend `cidr` restriction plus HTTPS (slskd docs themselves warn against API keys over plain HTTP).

### 1.2 CORS — works for the web app [live+code]
`Program.cs`: `AddCors("AllowAll", SetIsOriginAllowed(_ => true).AllowAnyHeader().AllowAnyMethod().AllowCredentials())`, with no config option. Preflight from `https://music.example.com` → `204`, `Access-Control-Allow-Origin` echoed, `x-api-key` allowed. The browser can call slskd directly. Mixed content and Chrome Local Network Access caveats are the same as for Lidarr, so the optional nginx pass-through applies.

### 1.3 Search
`POST /api/v0/searches` (body is `SearchRequest`):
```json
{ "id": "6f1c…(optional client GUID — lets you poll without parsing the response)",
  "searchText": "brad sucks making me nervous",
  "searchTimeout": 6000,          // MILLISECONDS (see note)
  "responseLimit": 60,
  "fileLimit": 2000,
  "filterResponses": true,
  "minimumResponseFileCount": 1,
  "minimumPeerUploadSpeed": 0,
  "maximumPeerQueueLength": 50 }
```
- **`searchTimeout` is milliseconds.** The DTO comment says "seconds", but the value goes straight to Soulseek.NET `SearchOptions(searchTimeout = 15000 ms)`, and Tubifarry sends `seconds*1000` [code]. The timeout counts **from the last response** (inactivity), so popular queries end on `responseLimit`/`fileLimit` rather than on time.
- **Responses are only available when the search ends.** `SearchService` collects them in memory and persists them on completion. While it runs, `GET /searches/{id}` shows only `responseCount`/`fileCount` [code]. Fast pattern: poll `GET /searches/{id}` every 500 ms. Once `responseCount ≥ ~15` or 5–6 s have passed, cancel with **`PUT /searches/{id}`**. A cancelled search still persists its collected responses (`State = Completed|Cancelled`) [code]. Then call `GET /searches/{id}/responses`.
- **Global one-at-a-time limiter:** a static `SemaphoreSlim(1,1)` guards the *start* of a search, and concurrent POSTs get **429** "Only one concurrent operation is permitted" [code]. Tubifarry hits the same instance, so retry 429 with jitter.
- Not logged in to Soulseek → **409** "The server connection must be connected and logged in…" [live]. Blank text → 400 [live]. Even failed searches leave a record (`state: "Completed, Errored"`) [live].
- Other calls: `GET /searches` (list), `GET /searches/{id}?includeResponses=true`, `DELETE /searches/{id}` (204). Searches are retained until `retention.search` (minutes) expires.

Response item (`GET /searches/{id}/responses`) [code]:
```json
[{ "username": "peer123", "token": 12345,
   "hasFreeUploadSlot": true, "uploadSpeed": 1843200, "queueLength": 0,
   "fileCount": 3, "lockedFileCount": 0, "lockedFiles": [],
   "files": [{ "filename": "@@abcde\\Music\\Brad Sucks\\I Don't Know What I'm Doing\\01 - Making Me Nervous.mp3",
               "size": 5843163, "extension": "mp3", "code": 1,
               "bitRate": 320, "isVariableBitRate": false, "sampleRate": 44100, "bitDepth": null,
               "length": 146, "isLocked": false }] }]
```
`bitRate`, `length`, `sampleRate` and `bitDepth` are nullable because peers don't always send attributes. `length` is in seconds. `uploadSpeed` is bytes/s.

### 1.4 Download (enqueue)
Preferred (≥ 0.26.0, July 2026): **`POST /api/v0/transfers/downloads/batches`** [code+live validation]
```json
{ "id": "b7e0…(optional GUID)", "searchId": "6f1c…(optional)",
  "username": "peer123",
  "files": [{ "filename": "@@abcde\\Music\\…\\01 - Making Me Nervous.mp3", "size": 5843163 }],
  "options": { "destination": "fastlane/req-8c1e", "externalId": "req-8c1e" } }
```
- `options.destination` is **relative to the downloads dir**, overrides the user's `transfers.download.destination.subdirectory` pattern, and rejects absolute paths and `..` (`400 "must be a relative path"`) [live]. This gives the app a **known, private, collision-free folder** that it tells Lidarr about.
- Responses: 201 Created / 207 partial / 200 (all duplicates) / 409 duplicate batch id / 429 / 500 (`"…must be connected and logged in to fetch user endpoint"` when offline [live]).
- Legacy: `POST /api/v0/transfers/downloads/{username}` with `[{filename,size}]` → `201 {enqueued, failed}`. Path-traversal filenames → 400 [live].
- The default destination without batches is `${SOURCE_DIRECTORY}` (the peer's leaf folder name), which can collide across peers and with Tubifarry. Always use batch destinations.

### 1.5 Progress and completion
- `GET /api/v0/transfers/downloads/{username}` (or `/downloads` for all, `?includeRemoved=true`). Shape: `{username, directories:[{directory, fileCount, files:[Transfer]}]}` [code].
- `Transfer` fields: `id, username, filename, size, state, stateDescription, requestedAt, enqueuedAt, startedAt, endedAt, bytesTransferred, averageSpeed, percentComplete, bytesRemaining, elapsedTime, remainingTime, placeInQueue, attempts, nextAttemptAt, exception, batchId` [code].
- `state` is a flags string: `Requested`, `Queued, Remotely` (peer has no free slot), `Initializing`, `InProgress`, then terminal `Completed, Succeeded` | `Completed, Cancelled|TimedOut|Errored|Rejected|Aborted` [code].
- `GET …/{username}/{id}/position` refreshes the queue position. `GET /transfers/downloads/batches/{id}` returns the batch.
- `GET /api/v0/events?offset=&limit=` gives `DownloadFileComplete {localFilename, remoteFilename, transfer}`, the **authoritative local path**, which matters if the `Exists: rename` strategy changed the name [code; endpoint returned `[]` live].
- Cancel/remove: `DELETE /transfers/downloads/{username}/{id}?remove=true`. `DELETE /transfers/downloads/all/completed` clears **all** completed records, including other clients' (Tubifarry uses it too) [code].

### 1.6 Files API (cleanup)
`GET /api/v0/files/downloads/directories[/{base64RelDir}]?recursive=` (listing is always allowed). `DELETE /files/downloads/directories/{base64}` and `DELETE /files/downloads/files/{base64}` require **`remote_file_management: true`** (default **false**) [doc+live: the delete reached the filesystem when enabled]. Paths are base64-encoded, relative to the downloads dir, and confined to app-controlled dirs [code].
Lidarr's Manual Import **moves the file but leaves the empty `fastlane/req-*` folder** [live]. Either enable remote file management and delete it, or let `retention.files.complete` expire it (it only ever holds empty folders).

### 1.7 Directories and other config [doc]
`directories.downloads` / `incomplete` (`SLSKD_DOWNLOADS_DIR`), default `APP_DIR/downloads`. `transfers.download.destination.permissions.mode` (e.g. 664) is useful so Lidarr's PUID can move files. `retention.search`, `retention.transfers.download.*` and `retention.files.complete` are in minutes. `GET /api/v0/options` (admin only) returns `directories.downloads`, which is how Tubifarry discovers the path [code].

### 1.8 Etiquette and rate limits
- No documented hard search rate limit. slskd serializes search *starts*. The Soulseek server is reported to have an **anti-flood mechanism** (aioslsk docs: "be careful when connecting and disconnecting too quickly or you will get banned") [doc, third-party]. Search spam can also get you ignored or banned by individual peers [est].
- App policy [est, conservative]: at most **1 search per request** (2 with a fallback query), never more than ~1 search per 5 s per slskd, no repeat search for the same recording within 10 min, at most 1 file per request, and at most 2 concurrent transfers per peer. Respect `queueLength`.
- **Sharing:** Soulseek etiquette and many peers expect you to share. slskd *uploads* to others. That is the user's setup, but the app must never configure shares.

---

## 2. Choosing the file

Inputs from MusicBrainz/ListenBrainz: artist credit, title, recording length (ms), album titles.

**Query.** Use `"{artist} {title}"`, normalized: strip punctuation, `feat.`, and bracketed version tags unless the user wants them. Fallback: `"{title} {album}"` when the artist name is very common. Never query with fewer than 3 characters per term, because many peers filter those (see slskd `filters.search.request`).

**Hard filters (reject):**
- `extension ∉ {mp3}` for the fast lane. Optionally allow `m4a`/AAC ≥ 256 and OGG, which Lidarr groups as "High Quality Lossy". FLAC is fine for small tracks if the peer is fast; still one file.
- `isLocked`, `size < 1.5 MB`, `size > 25 MB` (MP3).
- Bitrate: CBR `bitRate ≥ 320`, or VBR with `isVariableBitRate && bitRate ≥ 220` (≈ V0). Reject anything else.
- `|length − mbLength| > 3 s` when both are known; reject when `length` is null and size/bitrate disagree.
- Filename tokens: the normalized basename must contain all title tokens. Reject `live|remix|edit|instrumental|karaoke|cover|8d|nightcore|sped up|slowed` unless they are in the MB title. The full path should contain the artist token.
- `queueLength > 0 && !hasFreeUploadSlot` → deprioritize heavily (queued peers can take minutes to hours).

**Score (higher is better):** `+40 hasFreeUploadSlot`, `+min(uploadSpeed/100 KB/s, 30)`, `−5·queueLength`, `+15 duration within 1 s`, `+10 path contains album title of the target release group`, `+8 CBR 320 / +6 V0`, `+5 track number matches`, `−20 if the folder looks like a compilation ("VA", "Various", "Now That's")`.

**Execution:** enqueue the best candidate. If the transfer isn't `InProgress` within **8 s**, or stays `Queued, Remotely`, cancel it (`DELETE …?remove=true`) and try the next candidate from a **different user**, up to 3 attempts. Then fall back to the normal Lidarr flow.

**Time-to-first-byte [est, not measurable without connecting]:** peers with a free slot usually start in 1–5 s. A 7–10 MB MP3 at 0.5–3 MB/s takes 3–20 s. Queued peers range from minutes to never.

---

## 3. Lidarr manual import of one file — verified

### 3.1 Calls
1. Ensure the artist and album exist (`POST /artist`, existing flow). **Check `artist.monitored`.** With `addOptions.monitor: "none"`, Lidarr stored `monitored: false` even though we sent `true` [live]. An unmonitored artist hides its albums from `wanted/missing?monitored=true` and from RSS/automatic searches [live], so `PUT /artist/editor {artistIds, monitored:true}` afterwards.
2. Pick `albumId`, the **monitored release** id (`GET /album/{id}` → `releases[].monitored`) and the `trackId` (`GET /track?albumReleaseId=…`, match by `foreignRecordingId`). The track resource has no `albumReleaseId` field, so query by release [live].
3. *(Optional)* `GET /api/v1/manualimport?folder=/downloads/fastlane/req-8c1e&artistId=1` took **4.8 s** [live]. It returns `quality` (`MP3-320`, or `MP3-VBR-V0` for an `-q:a 0` file [live]), `audioTags`, `rejections`. For a tagless file it returned `album: null`, `tracks: []`, and the rejection *"Couldn't find similar album"* [live], which doesn't matter because we pass ids explicitly. **Skip this call.** Map quality from slskd metadata yourself: Lidarr ids `MP3-320 = 4`, `MP3-VBR-V0 = 2`, `AAC-320 = 11`, `FLAC = 6` [live `/qualitydefinition`].
4. Import:
```json
POST /api/v1/command
{ "name": "ManualImport", "importMode": "move", "replaceExistingFiles": true,
  "files": [{ "path": "/downloads/fastlane/req-8c1e/01 - Making Me Nervous.mp3",
              "artistId": 1, "albumId": 1, "albumReleaseId": 1, "trackIds": [1],
              "quality": { "quality": { "id": 4 }, "revision": { "version": 1, "real": 0 } },
              "indexerFlags": 0, "disableReleaseSwitching": false }] }
```
→ poll `GET /command/{id}` → `completed`, message "Manually imported 1 files", **≈0.6 s** [live].

### 3.2 What Lidarr does [live + code]
- **Partial import is accepted.** The `ManualImport` command does **not** run import specifications. The only check is that the artist path is inside a root folder (`ManualImportService.Execute`) [code]. It imported 1 of 12 tracks [live].
- **Tags:** with *Write Audio Tags = New Files* (default **No**), Lidarr rewrote the tone file's tags: album, album artist, `track 1/12`, date, genre, and **MusicBrainz Album Id / Release Group Id / Artist Id / Release Track Id** [live, ffprobe]. The recording id is written as an ID3 UFID frame (ffprobe doesn't print it) [code: `MusicBrainzTrackId`]. Setup must set `writeAudioTags: newFiles` (or `allFiles`), otherwise our MBID match ladder depends on whatever tags the peer had.
- **Naming:** with `renameTracks: false` (default) the file went to `/music/Brad Sucks/Brad Sucks - Making Me Nervous.mp3`, outside any album folder. With `renameTracks: true` it went to `/music/Brad Sucks/I Don't Know What I'm Doing (2003)/Brad Sucks - I Don't Know What I'm Doing - 02 - Look and Feel Years Younger.mp3` [live]. **Setup must enable renaming.**
- **Release pinning:** the import sets the chosen `albumReleaseId` as the album's monitored release (`_releaseService.SetMonitored`) [code]. Choose the release Lidarr already monitors unless you mean to switch.
- **Notification quirk (important):** `AlbumImportedEvent.NewDownload` is set from `replaceExistingFiles` [code], and `NotificationService` returns early when `!NewDownload` [code]. Verified with a webhook: `replaceExistingFiles:false` → **no Download/OnReleaseImport event** (so no Subsonic rescan of Navidrome). `replaceExistingFiles:true` → event fired [live]. Automatic download imports always pass `true` [code].
- **`replaceExistingFiles:true` deletes all of the album's existing files** (`RemoveExistingTrackFiles`, to the recycle bin if one is configured, otherwise deleted). Verified: importing track 2 with `true` removed track 1 [live].
  ⇒ Rule: `replaceExistingFiles = (album.statistics.trackFileCount == 0)`, re-read just before POSTing and under the per-artist lock. When it is `false`, trigger Navidrome yourself (Keeper is a Navidrome admin → Subsonic `startScan`; otherwise rely on Navidrome's file watcher).

### 3.3 Album state afterwards and the upgrade path [live]
- With the artist and album monitored, the partial album appears in **both** `GET /wanted/missing` and `GET /wanted/cutoff` (MP3-320 is below the Lossless cutoff) [live]. Lidarr's RSS sync, `MissingAlbumSearch` and Tubifarry's Search Sniper therefore keep targeting it.
- `UpgradeDiskSpecification`: when **any track is missing**, it accepts *any* release without a quality comparison [code]. A later album grab is never blocked by our MP3. The profile's order decides which release wins, so put Lossless above HQ Lossy.
- **Full FLAC import verified.** A 12-track FLAC folder imported through `DownloadedAlbumsScan` (the same path as a completed download, `replaceExisting: true`) imported 12/12. The MP3 was removed and the webhook reported `isUpgrade: true, deletedFiles: 1` [live]. Album stats went from 1/12 to 12/12.
- If the later release is *also* lossy at the same quality, per-track import specs may skip tracks that are "not an upgrade". The album-level replace still removes old files only for approved decisions [code, low risk].

### 3.4 Quality profile (setup provisions it) [live]
`"Fast first, then lossless"`: allowed = **High Quality Lossy** group (MP3-VBR-V0, AAC-VBR, MP3-320, OGG Q9, AAC-320, OGG Q10) + **Lossless**, `cutoff = 1005` (Lossless group), `upgradeAllowed: true`. Created by cloning profile "Any" and toggling `items[].allowed` [live]. Manual import ignores the profile's allowed list [code], but keeping MP3-320 allowed means the profile's own grabs stay consistent.

### 3.5 Path requirement
Lidarr must see slskd's downloads dir at a path it can read **and write** (move = rename or copy+delete). Options: the same volume in both containers (`/downloads`), or the app translating paths using an owner-entered mapping (`slskdPrefix → lidarrPrefix`). Lidarr's *Remote Path Mappings* only apply to download clients Lidarr knows about, not to our manual import. Setup check: enqueue nothing, `GET /api/v1/filesystem?path=<mapped downloads dir>` in Lidarr, and confirm `fastlane/` is listed after slskd creates it [est; endpoint exists in Lidarr].

---

## 4. Coexistence with Tubifarry on the same slskd [code]
- Tubifarry's slskd client polls `GET /transfers/downloads` and assigns transfer groups to its own grabs by grab history (username + filename + batch). Files it didn't grab are ignored **unless the "Inclusive" option (advanced, default off) is enabled**. With Inclusive on, our fast-lane download is reported to Lidarr as an untracked download item and Lidarr may try to auto-import it, racing our manual import. Detect it: `GET /api/v1/downloadclient` → `SlskdClient` `fields[name=Inclusive].value`. If true, warn the owner or add the file to Lidarr's queue knowledge. Simplest fix: ask the owner to keep Inclusive off.
- Tubifarry calls `DELETE /transfers/downloads/all/completed`, so our completed transfer *records* can vanish. Use `/events` or our own polling state, not record persistence.
- Tubifarry's "Clean Directories" only deletes folders of its own items and checks that other items aren't using them [code]. Our unique `fastlane/req-*` destination avoids any overlap with album folders (`${SOURCE_DIRECTORY}` / Tubifarry's artist–album names).
- Search contention: both use the one-at-a-time search start → handle 429 with retry. Tubifarry has a "Concurrent Search Limit" setting, typically 1.
- Duplicate work: after our MP3 lands, Tubifarry may still grab the **whole album** (good: that's the FLAC path). If the owner's profile sorts MP3 albums first, it may grab an MP3 album. Fine, it still fills the album.
- If Tubifarry is installed, its slskd URL and key can be read from `GET /api/v1/downloadclient` (`SlskdClient.fields`: `baseUrl`, `apiKey`). Lidarr returns `apiKey` **masked** (`********`) for privacy-flagged fields [est; the field is `PrivacyLevel.ApiKey`], so the owner must still paste the key.

---

## 5. What the user must provide
1. **slskd URL** (home/away list like the other servers) and an **API key**. Today any key can search, download, browse users, send chat messages, rescan shares and, with remote file management on, delete downloaded files. An admin key can also change options. Recommend a dedicated key with `cidr` limited to LAN/Tailscale, plus HTTPS.
2. **A shared path:** slskd's downloads dir must be visible to Lidarr (same Docker volume, or a path mapping entered once). Recommend `transfers.download.destination.permissions.mode: 664` and matching PUID/PGID.
3. *(Optional)* `remote_file_management: true` so the app can delete empty `fastlane/req-*` folders.
4. Lidarr settings (setup can do these over the API): `writeAudioTags: newFiles`, `renameTracks: true`, the fast-first profile, monitored artist.
5. Soulseek account, shares and VPN are all owned by the user in slskd. The app never configures them.

---

## 6. Latency comparison [est unless marked]

| Step | Direct slskd fast lane | Tubifarry (slskd via Lidarr, single/EP) | Plain Lidarr (Usenet/torrent) |
|---|---|---|---|
| Resolve + ensure artist/album in Lidarr | 1–10 s (metadata server; parallel with search) | same | same |
| Search | **5–8 s** (cancel early at ~15 responses) | 15 s default timeout × Tubifarry strategies; Lidarr search command overhead | indexer queries 5–60 s |
| Grab → first byte | 1–5 s (free-slot peer) | similar, but picks a whole folder/release | Usenet seconds–minutes; torrents minutes–hours |
| Download | **one file**, 7–15 MB: 3–20 s | whole single/EP (1–6 files) or album (60–500 MB FLAC): 20 s–10 min+ | album size |
| Import | **0.6 s** [live] | Lidarr polls the client (~60 s *Check For Finished Download* interval) + import | same polling + import |
| Navidrome visible | Subsonic connection rescan or our `startScan`: 2–15 s quick scan [est] | same | same |
| **Typical total** | **≈ 20–45 s** | **≈ 1.5–5 min** (single), longer for albums | **10 min – hours** |

The biggest structural win is skipping Lidarr's finished-download polling and the album-sized transfer.

---

## 7. Apple App Review risk

- **Guideline 5.2.3 (verbatim, 2026):** *"Apps should not facilitate illegal file sharing or include the ability to save, convert, or download media from third-party sources (such as Apple Music, YouTube, SoundCloud, Vimeo, etc.) without explicit authorization from those sources."* 5.2.2: you must be permitted to use third-party services. The current text has no explicit "P2P" clause.
- **Precedents that pass today:** BitTorrent *remote controllers*: **BitManager – Remote Control** (qBittorrent + Transmission), **Transmission Pocket** (released Jul 2026), **qBitConnect** (Jan 2026), **NASCTL – Transmission/qB remote**. Apple has also approved Transmission RPC remotes in the past (Cult of Mac). Radarr/Sonarr remotes (LunaSea historically; Ruddarr, etc.) passed.
- **Counter-precedent:** LunaSea's FAQ said torrent-client support was "not possible because of the restrictions Apple has put forward… including linking to a P2P client that is running on an external machine". LunaSea's own *arr remote shipped, but without the torrent part. Enforcement is inconsistent and reviewer-dependent.
- **No Soulseek/slskd client or remote exists on the App Store**; the historical ones (iSlsk, MewSeek) were jailbreak-only.
- **Assessment:** an iOS app that *searches a P2P network for a specific copyrighted song and downloads it* is closer to the 5.2.3 core than a generic torrent remote, which merely manages a queue. Risk of rejection, or of later removal after a complaint, is **moderate to high** for an explicit "Soulseek" feature, and **low to moderate** if presented as a generic owner-configured "download helper" that reviewers never see by default. Our Lidarr integration already sits in the same grey zone as Radarr/Sonarr remotes. The direct slskd lane moves the *search and pick* logic into our binary, which is the material difference.
- **Mitigations:** (1) off by default, enabled only in owner settings under a neutral name ("Fast lane: connect a download helper"), with no "Soulseek/P2P" wording anywhere in UI, metadata or screenshots. (2) Reviewer demo account without it configured, plus truthful review notes ("connects to the user's own self-hosted library services"). (3) Owner-only Keeper feature, never available to Listeners. (4) **Put the slskd adapter in the Mac menu-bar helper first** (Mac App Store review is similar, but the helper can also ship outside the store via notarized direct download). The iPhone then only *requests*, and the helper performs the fast lane. (5) Web app (Docker, not reviewed) can have it fully. (6) Keep a server-side-free kill switch: feature-flag via a remote config file we host. Optional; the spec otherwise has no backend.
- Legal/ToS: Soulseek usage is the user's choice. The app should not advertise piracy (already an anti-goal in the spec).

---

## 8. Recommended tiered strategy

| Tier | When available | First-song path | Expected wait |
|---|---|---|---|
| **T0 — Fast lane (direct slskd)** | Owner has entered slskd URL + key **and** the path check passes; runs on a Keeper (Mac helper preferred; iOS Keeper optional per review outcome; web Keeper) | Search (≤ 8 s) → best single MP3-320/V0 → batch download to `fastlane/req-*` → Lidarr `ManualImport` (`replaceExistingFiles` iff album empty) → rescan → play. **In parallel** monitor the smallest release group + `AlbumSearch` so FLAC follows | ~20–45 s |
| **T1 — Tubifarry** | Tubifarry with a usable source detected | Existing spec: monitor smallest release group (Single → EP → Album) + `AlbumSearch`; optional interactive `GET/POST /release` ranking | ~1.5–5 min |
| **T2 — Plain Lidarr** | Always | Same as T1 with the user's indexers | 10 min – hours |
| **Then (all tiers)** | — | Fast-first profile → cutoff Lossless upgrades the MP3 automatically; expand to the household discography preference | background |

T0 falls back to T1/T2 automatically on: no acceptable candidate, three failed peers, a 60 s overall budget exceeded, or a 409 (slskd not logged in). Since T1/T2 were fired in parallel, the fallback costs nothing.

**Implementation notes:** a `FastLane` module inside `Requests` behind a protocol (`DownloadHelper`), with a single concrete `SlskdHelper`. The per-artist lock covers the `trackFileCount` re-check and the import. Request mailbox states gain `fetching` (slskd) before `importing`. Contract tests run against `slskd:0.26.x` (search 409 offline, batch validation, CORS) and a Lidarr fixture (manual-import + notification quirk).

### Open items to verify on a real (owner's) setup
- Real search latency and response counts. Tune the early-cancel threshold.
- Navidrome quick-scan time on a large library after a Subsonic-connection rescan.
- Whether Lidarr masks Tubifarry's `apiKey` field in `/downloadclient`.
- Lidarr `GET /filesystem` as the path check for the shared volume.
- Behaviour when the owner's Lidarr has a recycle bin configured (then `replaceExisting` is recoverable).
