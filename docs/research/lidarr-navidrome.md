# Lidarr + Navidrome integration research

Research date: 2026-10-26. Versions checked: **Lidarr v3.1.6 (master) / v3.2.0 (develop)**, **Navidrome v0.64.2**.
Most findings come straight from the source code on the `develop` and `master` branches, with links below. Inferences are labelled as such.

---

## 0. TL;DR architecture

```
 Client app (web/mobile)
   │  only ever talks to ──►  OUR BACKEND ("broker")
   │                              │
   │        ┌─────────────────────┼──────────────────────────┬────────────────────┐
   │        ▼                     ▼                          ▼                    ▼
   │   Navidrome (Subsonic   Catalog/preview source     MusicBrainz WS/2      Lidarr API v1
   │   /rest + native /api)  (Deezer/iTunes: 30s        (ISRC→recording→      (/api/v1, X-Api-Key)
   │   library + playback    preview, ISRC)             release-group)              │
   │        ▲                                                                       │ webhook (Connect)
   │        └──── startScan(target=lib:folder) ◄── backend ◄── "Download" event ◄──┘
```

* The client never sees Lidarr or MusicBrainz IDs. The backend keeps a `requests` table
  (`user, recordingMbid, isrc, releaseGroupMbid, artistMbid, lidarrAlbumId, state`) and
  reports a simple state to the client: *requested → searching → downloading (n%) → importing → available*.
* **Unified search** = Navidrome `search3` (library) merged with the external catalogue, de-duplicated by
  **ISRC → recording MBID → (artist MBID + normalized title)**, in that order of preference.
* **"Get this song fast"** = `POST /api/v1/artist` with `addOptions.albumsToMonitor=[<release-group MBID>]` and
  `searchForMissingAlbums=true` (one call, atomic), or `POST /api/v1/album` if the artist already exists.
  **"Get the discography"** later = `PUT /api/v1/album/monitor` (or `PUT /api/v1/artist` + `monitorNewItems`) and
  `MissingAlbumSearch`/`ArtistSearch`.
* Completion: Lidarr **webhook `eventType: "Download"`** → backend → Navidrome `startScan?target=<libId>:<artistFolder>`
  → poll `getScanStatus` / look up by MBID → push "available" to the client.

---

## LIDARR

### 1. API v1 basics

**Auth.** API key from Settings → General. Accepted as the `X-Api-Key` header, the `apikey` query parameter, or
`Authorization: Bearer <key>` (see `ApiKeyAuthenticationHandler.ParseApiKey`). For SignalR, the key goes in the
`access_token` query parameter. Basic auth was removed in v3.0 (forms auth only for the UI).
Source: [ApiKeyAuthenticationHandler.cs](https://github.com/Lidarr/Lidarr/blob/develop/src/Lidarr.Http/Authentication/ApiKeyAuthenticationHandler.cs), [Lidarr API docs](https://lidarr.audio/docs/api/).

Base path: `http://lidarr:8686/api/v1/…`. Controllers use the singular resource name (`/artist`, `/album`, `/track`, `/queue`).

#### Endpoint inventory (the parts we need)

| Purpose | Method + path | Notes |
|---|---|---|
| Artist search (metadata server) | `GET /api/v1/artist/lookup?term=…` | `term=lidarr:<artistMBID>` (or `mbid:`/`lidarrid:`) does an exact ID lookup, which is **much more reliable than text search** |
| Album search | `GET /api/v1/album/lookup?term=…` | `term=lidarr:<releaseGroupMBID>` |
| Combined search | `GET /api/v1/search?term=…` | Returns `[{id, foreignId, artist?, album?}]`, a mix of artists and albums |
| List/find artist | `GET /api/v1/artist`, `GET /api/v1/artist?mbId=<uuid>`, `GET /api/v1/artist/{id}` | Use `?mbId=` to check whether the artist already exists |
| Add artist | `POST /api/v1/artist` | See payload below |
| Update artist | `PUT /api/v1/artist/{id}?moveFiles=false` | Full resource round-trip |
| Bulk edit artists | `PUT /api/v1/artist/editor` | `{artistIds, monitored, monitorNewItems, qualityProfileId, metadataProfileId, rootFolderPath, tags, applyTags}` |
| List albums | `GET /api/v1/album?artistId=…` / `?foreignAlbumId=<rgMBID>` / `?albumIds=1&albumIds=2` | `includeAllArtistAlbums=true` with `foreignAlbumId` |
| Add one album | `POST /api/v1/album` | **Auto-adds the artist if missing** (see §2) |
| Update album | `PUT /api/v1/album/{id}` | Also used to pick the monitored *release* (edition) |
| Monitor/unmonitor albums | `PUT /api/v1/album/monitor` | `{albumIds:[…], monitored:true}` returns 202 |
| Tracks | `GET /api/v1/track?albumId=…` / `?artistId=…` | Each track has `foreignRecordingId` (recording MBID), `hasFile`, `trackFileId` |
| Track files | `GET /api/v1/trackfile?albumId=…` | Gives the on-disk `path`, which we need for a targeted Navidrome scan |
| Commands | `POST /api/v1/command`, `GET /api/v1/command/{id}`, `GET /api/v1/command` | |
| Interactive search | `GET /api/v1/release?albumId=…`, `POST /api/v1/release {guid, indexerId}` | Lets us choose the fastest release ourselves |
| Queue | `GET /api/v1/queue?page=1&pageSize=50&includeArtist=true&includeAlbum=true`, `GET /api/v1/queue/details?albumIds=…`, `DELETE /api/v1/queue/{id}?blocklist=true` | |
| History | `GET /api/v1/history?page=…&eventType=…&albumId=…`, `GET /api/v1/history/since?date=…`, `GET /api/v1/history/artist?artistId=…` | |
| Wanted | `GET /api/v1/wanted/missing?page=1&pageSize=50&monitored=true`, `GET /api/v1/wanted/cutoff` | |
| Profiles | `GET/POST/PUT /api/v1/metadataprofile`, `GET /api/v1/qualityprofile` | |
| Root folders | `GET /api/v1/rootfolder` | Each has `path`, `defaultQualityProfileId`, `defaultMetadataProfileId`, `defaultMonitorOption`, `defaultNewItemMonitorOption` |
| Webhooks | `GET/POST /api/v1/notification` | Lets us register our webhook programmatically on setup |
| Health / status | `GET /api/v1/health`, `GET /api/v1/system/status` | Check `health` for "metadata server unreachable"-type issues |

Sources: [AlbumController.cs](https://github.com/Lidarr/Lidarr/blob/develop/src/Lidarr.Api.V1/Albums/AlbumController.cs), [ArtistController.cs](https://github.com/Lidarr/Lidarr/blob/develop/src/Lidarr.Api.V1/Artist/ArtistController.cs), [ArtistEditorResource.cs](https://github.com/Lidarr/Lidarr/blob/develop/src/Lidarr.Api.V1/Artist/ArtistEditorResource.cs), [SearchController.cs](https://github.com/Lidarr/Lidarr/blob/develop/src/Lidarr.Api.V1/Search/SearchController.cs), [QueueResource.cs](https://github.com/Lidarr/Lidarr/blob/develop/src/Lidarr.Api.V1/Queue/QueueResource.cs), [SkyHookProxy.cs (`IsMbidQuery`)](https://github.com/Lidarr/Lidarr/blob/develop/src/NzbDrone.Core/MetadataSource/SkyHook/SkyHookProxy.cs).

#### Enums (from source)

* `addOptions.monitor` (`MonitorTypes`): `all | future | missing | existing | latest | first | none | unknown`
  ([MonitorTypes.cs](https://github.com/Lidarr/Lidarr/blob/develop/src/NzbDrone.Core/Music/Model/MonitorTypes.cs)).
* `monitorNewItems` (`NewItemMonitorTypes`): `all | none | new`
  ([NewItemMonitorTypes.cs](https://github.com/Lidarr/Lidarr/blob/develop/src/NzbDrone.Core/Music/Model/NewItemMonitorTypes.cs)).
* `addOptions` = `{ monitor, albumsToMonitor: string[] /* release-group MBIDs */, monitored, searchForMissingAlbums }`
  ([MonitoringOptions.cs](https://github.com/Lidarr/Lidarr/blob/develop/src/NzbDrone.Core/Music/Model/MonitoringOptions.cs), [AddArtistOptions.cs](https://github.com/Lidarr/Lidarr/blob/develop/src/NzbDrone.Core/Music/Model/AddArtistOptions.cs)).
  **If `albumsToMonitor` is non-empty it overrides `monitor`.** Exactly those albums are monitored and every other album is unmonitored
  ([AlbumMonitoredService.cs](https://github.com/Lidarr/Lidarr/blob/develop/src/NzbDrone.Core/Music/Services/AlbumMonitoredService.cs)).
* Album `addOptions` = `{ addType: automatic|manual, searchForNewAlbum: bool }`. A `POST /album` is always `manual`, so the
  album survives refreshes even if the metadata profile would filter it out
  ([AddAlbumOptions.cs](https://github.com/Lidarr/Lidarr/blob/develop/src/NzbDrone.Core/Music/Model/AddAlbumOptions.cs)).
* Primary album types: `0 Album, 1 EP, 2 Single, 3 Broadcast, 4 Other`.
  Secondary types: `0 Studio, 1 Compilation, 2 Soundtrack, 3 Spokenword, 4 Interview, 5 Audiobook, 6 Live, 7 Remix, 8 DJ-mix, 9 Mixtape/Street, 10 Demo, 11 Audio drama`.
  Release statuses: `0 Official, 1 Promotion, 2 Bootleg, 3 Pseudo-Release`.
* Monitor semantics (from `AlbumMonitoredService`): `missing` = monitor released albums *without* files; `existing` = only
  albums with files; `future` = unmonitor everything that exists now (only new releases get monitored, through `monitorNewItems`);
  `latest`/`first` = by release date; `none` = unmonitor all.

#### Example payloads

**Add artist, monitoring a single release group, and search immediately** (the main "get this song" call):
```http
POST /api/v1/artist
X-Api-Key: <key>
Content-Type: application/json

{
  "artistName": "Radiohead",
  "foreignArtistId": "a74b1b7f-71a5-4011-9441-d0b5e4122711",
  "qualityProfileId": 1,
  "metadataProfileId": 3,
  "rootFolderPath": "/music",
  "monitored": true,
  "monitorNewItems": "none",
  "tags": [],
  "addOptions": {
    "monitor": "none",
    "albumsToMonitor": ["b1392450-e666-3926-a536-22c65f834433"],
    "monitored": true,
    "searchForMissingAlbums": true
  }
}
```
Required by validators: `artistName`, `foreignArtistId` (must not already exist), a valid `qualityProfileId` and
`metadataProfileId`, and `rootFolderPath` (or an explicit `path`). Recommended: send back the whole object from
`/artist/lookup` with these fields overridden, because that is what the UI does.

**Add a single album (artist may or may not exist):**
```json
POST /api/v1/album
{
  "foreignAlbumId": "b1392450-e666-3926-a536-22c65f834433",
  "monitored": true,
  "anyReleaseOk": true,
  "artist": {
    "foreignArtistId": "a74b1b7f-71a5-4011-9441-d0b5e4122711",
    "artistName": "Radiohead",
    "qualityProfileId": 1,
    "metadataProfileId": 3,
    "rootFolderPath": "/music",
    "monitored": true,
    "monitorNewItems": "none",
    "addOptions": { "monitor": "none", "searchForMissingAlbums": false }
  },
  "addOptions": { "searchForNewAlbum": true }
}
```
`AddAlbumService` creates the artist when it does not exist yet. It also clears import-list exclusions for both MBIDs
([AddAlbumService.cs](https://github.com/Lidarr/Lidarr/blob/develop/src/NzbDrone.Core/Music/Services/AddAlbumService.cs)).
The safest way to build the body is to take the object from `GET /album/lookup?term=lidarr:<rgMBID>`, set `monitored`,
`addOptions` and the `artist` profile fields, and POST it.

**Monitor more albums / the whole discography later:**
```json
PUT /api/v1/album/monitor
{ "albumIds": [101, 102, 103, 117], "monitored": true }
```
```json
POST /api/v1/command
{ "name": "AlbumSearch", "albumIds": [101, 102, 103, 117] }
```
or, for the whole artist:
```json
PUT /api/v1/artist/editor
{ "artistIds": [42], "monitored": true, "monitorNewItems": "all" }
```
```json
POST /api/v1/command
{ "name": "ArtistSearch", "artistId": 42 }
```

**Commands** (all `POST /api/v1/command`, which returns `{id, name, status: queued|started|completed|failed, …}`. Poll with `GET /api/v1/command/{id}`):
```json
{ "name": "AlbumSearch",        "albumIds": [101] }
{ "name": "ArtistSearch",       "artistId": 42 }
{ "name": "RefreshArtist",      "artistId": 42 }          // or "artistIds": [..]
{ "name": "RefreshAlbum",       "albumId": 101 }
{ "name": "MissingAlbumSearch" }                           // all monitored missing albums
{ "name": "RescanFolders" }                                // re-import from disk
```
Source: [IndexerSearch commands](https://github.com/Lidarr/Lidarr/tree/develop/src/NzbDrone.Core/IndexerSearch), [Music/Commands](https://github.com/Lidarr/Lidarr/tree/develop/src/NzbDrone.Core/Music/Commands).

**Metadata profile that includes EPs (and optionally singles):**
```json
POST /api/v1/metadataprofile
{
  "name": "App: Albums+EPs+Singles",
  "primaryAlbumTypes": [
    { "albumType": { "id": 0, "name": "Album" },  "allowed": true },
    { "albumType": { "id": 1, "name": "EP" },     "allowed": true },
    { "albumType": { "id": 2, "name": "Single" }, "allowed": true },
    { "albumType": { "id": 3, "name": "Broadcast" }, "allowed": false },
    { "albumType": { "id": 4, "name": "Other" },  "allowed": false }
  ],
  "secondaryAlbumTypes": [
    { "albumType": { "id": 0, "name": "Studio" }, "allowed": true },
    { "albumType": { "id": 1, "name": "Compilation" }, "allowed": false },
    { "albumType": { "id": 2, "name": "Soundtrack" }, "allowed": true },
    { "albumType": { "id": 6, "name": "Live" }, "allowed": false },
    { "albumType": { "id": 7, "name": "Remix" }, "allowed": false }
    /* … remaining ids 3,4,5,8,9,10,11 allowed:false */
  ],
  "releaseStatuses": [
    { "releaseStatus": { "id": 0, "name": "Official" }, "allowed": true },
    { "releaseStatus": { "id": 1, "name": "Promotion" }, "allowed": false },
    { "releaseStatus": { "id": 2, "name": "Bootleg" }, "allowed": false },
    { "releaseStatus": { "id": 3, "name": "Pseudo-Release" }, "allowed": false }
  ]
}
```
The **built-in "Standard" profile is Album + Studio + Official only**, so EPs and singles never appear in it. A "None" profile
also exists and cannot be edited
([MetadataProfileService.cs](https://github.com/Lidarr/Lidarr/blob/develop/src/NzbDrone.Core/Profiles/Metadata/MetadataProfileService.cs)).
Recommendation: the backend creates **two profiles on setup**: "Albums+EPs" (the default discography scope the user asked for) and
"Albums+EPs+Singles", plus a user setting to choose between them.

**Webhook registration (Connect):**
```json
POST /api/v1/notification
{
  "name": "player-backend",
  "implementation": "Webhook",
  "configContract": "WebhookSettings",
  "onGrab": true, "onReleaseImport": true, "onUpgrade": true,
  "onDownloadFailure": true, "onImportFailure": true,
  "onArtistAdd": true, "onAlbumDelete": true, "onArtistDelete": true,
  "fields": [
    { "name": "url", "value": "http://backend:8080/hooks/lidarr" },
    { "name": "method", "value": 1 },
    { "name": "username", "value": "" }, { "name": "password", "value": "<shared-secret>" }
  ],
  "tags": []
}
```
(Field names: check `GET /api/v1/notification/schema` on the target version before relying on them.)

### 2. "Get this one song ASAP"

Lidarr's smallest unit is the **album = MusicBrainz release group**. Inside an album Lidarr picks one *release*
(edition), and tracks map to **recordings** (`track.foreignRecordingId`). Lidarr cannot fetch a single track.

#### ID mapping pipeline (backend)

1. **External catalogue hit → ISRC.** Deezer (`api.deezer.com/track/{id}` → `isrc`, `preview` 30s MP3) or the iTunes Search API
   (`previewUrl`, no ISRC on the free endpoint). *Spotify `preview_url` was deprecated for new apps in Nov 2024. Do not rely on it.*
2. **ISRC → recording MBID**: `GET https://musicbrainz.org/ws/2/isrc/{isrc}?inc=releases+release-groups&fmt=json`.
   Fallback: `GET /ws/2/recording?query=isrc:{isrc}` or `recording:"title" AND artist:"name"` (Lucene).
   MusicBrainz limits clients to about **1 req/s** and requires a meaningful `User-Agent`, so cache aggressively.
3. **Recording → release groups**: `GET /ws/2/recording/{mbid}?inc=releases+release-groups+artist-credits&fmt=json`.
   Each `release` carries `release-group {id, primary-type, secondary-types}` and `status`.
4. **Choose the release group** (ranking heuristic, which is an inference):
   1. `primary-type=Album`, no secondary types, `status=Official`, earliest release date (the "canonical" album);
   2. otherwise an `EP`;
   3. otherwise a `Single` (needs a profile that allows Single, or a manual `POST /album`, which bypasses the profile filter because `addType=manual`).
   Skip `Compilation`/`Live`/`Remix` unless that is the only option. Prefer release groups whose artist credit equals the track's primary artist, because Lidarr files albums under the *album artist*.
5. **Release group → Lidarr album**: `GET /api/v1/album?foreignAlbumId=<rgMBID>` → exists? Use its `id`. If not:
   `GET /api/v1/artist?mbId=<artistMBID>` → exists? `POST /api/v1/album`. If neither exists, `POST /api/v1/artist`
   with `albumsToMonitor`.
6. After the add, **verify the track is on the chosen release**: `GET /api/v1/track?albumId=…` and look for `foreignRecordingId == recordingMbid`.
   If the default selected *release* lacks the track (bonus tracks, regional editions), `PUT /api/v1/album/{id}` with the
   `releases[]` entry that contains it set `monitored:true`, or set `anyReleaseOk:true`.

#### Recommended flow

```
POST /artist (monitor=none, monitorNewItems=<user default>, albumsToMonitor=[rg], searchForMissingAlbums=true)
  └─ Lidarr: RefreshArtist (fetches the discography from api.lidarr.audio) → monitors only rg → AlbumSearch(rg)
```
* This is **one call and atomic**. You do not need "add with none, then PUT monitor, then AlbumSearch". That three-step version also works,
  but it races the async refresh: albums do not exist in Lidarr until `RefreshArtist` finishes. If you use the three-step version, poll
  `GET /album?artistId=` or the command status until the album appears.
* If the artist already exists: `PUT /album/monitor {albumIds:[id], monitored:true}` + `POST /command {name:"AlbumSearch", albumIds:[id]}`.
  If the album is missing because the profile filtered it out, use `POST /album` (manual add).
* **Speed lever:** skip Lidarr's automatic pick and do an *interactive search*. Call `GET /api/v1/release?albumId=X`, rank the results ourselves
  (Usenet first, then torrents by seeders, smallest acceptable size, `rejected=false`), and `POST /api/v1/release {guid, indexerId}`.
  This shortens time-to-first-play noticeably for poorly seeded albums (inference based on how the arr apps work).
* Optionally also monitor the **Single** release group that contains the recording, because singles are small and download fast. On public
  trackers singles are poorly indexed, though, so this mostly helps with Usenet or Soulseek (inference).
* **Expanding to the full discography** (user-selectable "default monitoring method"). Map the user choice to:
  * "Everything (albums + EPs)": switch the artist to the Albums+EPs profile, `PUT /album/monitor` for all albums returned by
    `GET /album?artistId=`, `monitorNewItems: "all"`, then `ArtistSearch`.
  * "Missing only": monitor only albums with `statistics.trackFileCount == 0`, which is equivalent to `monitor: missing`.
  * "Future releases only": `monitorNewItems: "new"` and nothing else.
  * "Latest / First album": select by `releaseDate`.
  * "Just this song": no change.
  Note that `addOptions.monitor` only applies at add time. For an existing artist we compute the albumIds ourselves and call
  `PUT /album/monitor`. Re-POSTing with addOptions is not possible because it fails with "artist exists".

#### Single-track alternatives (only if album granularity is unacceptable)
* **Lidarr plugins** are merged into Lidarr: "New: Plugin support" landed in v3.1.2 develop (Mar 2026), and plugin fixes appear in v3.2.0
  ([releases](https://github.com/Lidarr/Lidarr/releases)). Previously they required the `plugins` nightly branch/image.
  [Tubifarry](https://github.com/TypNull/Tubifarry) adds Soulseek (slskd), YouTube and other web clients as indexers/download clients,
  plus extra metadata sources. It is still album-oriented inside Lidarr, but Soulseek is often fast for singles. These are third-party
  sources, so check the legal and quality implications.
* Bypassing Lidarr (slskd or yt-dlp directly into a staging folder, then import) breaks Lidarr's model. Not recommended.

#### Metadata server dependence (biggest Lidarr risk)
* All lookups and refreshes go to **`https://api.lidarr.audio/api/v0.4/`** (SkyHook). It **cannot be self-hosted officially**
  ([LidarrCloudRequestBuilder.cs](https://github.com/Lidarr/Lidarr/blob/develop/src/NzbDrone.Common/Cloud/LidarrCloudRequestBuilder.cs)).
* Incident [#5498](https://github.com/Lidarr/Lidarr/issues/5498): from Apr 2025 there were 500/503 errors after a MusicBrainz schema change broke
  their migration. The cache was rebuilt Aug–Sep 2025 and the issue was closed in Oct 2025, then **reopened in Jan 2026 because "text searches are
  still functionally broken."** ID-based lookups (`lidarr:<mbid>`) work much better.
* **Design implication:** never use Lidarr for *search*. Search MusicBrainz, Deezer and the library ourselves, and give Lidarr only MBIDs.
  Expect `POST /artist` to take seconds or fail with 5xx when the metadata server is unhealthy. Implement retry with backoff and a "queued, will
  retry" state. The community mirror [blampe/hearring-aid](https://github.com/blampe/hearring-aid) is a community alternative
  metadata source (setup method varies by Lidarr version and needs verifying) and is the fallback if the official server degrades again.

### 3. Tracking progress and completion

* **Queue polling**: `GET /api/v1/queue?includeAlbum=true&pageSize=200` every 2–5 s while any request is active. Use these fields: `albumId`,
  `size`, `sizeleft` (progress = 1 − sizeleft/size), `timeleft`, `estimatedCompletionTime`, `status`
  (`queued|paused|downloading|completed|failed|warning|delay|downloadClientUnavailable`),
  `trackedDownloadStatus` (`ok|warning|error`), `trackedDownloadState` (`downloading|importBlocked|importPending|importing|imported|failedPending|failed|ignored`),
  `statusMessages[]`, `errorMessage`, `downloadId`.
  Map these to the user-facing states: `downloading`, then `importing` (`trackedDownloadState in importPending|importing`), then
  `needs attention` (`importBlocked`/`warning`). `importBlocked` usually means bad tags or a track mismatch, and an admin has to act in the
  Lidarr UI (Manual Import).
* **SignalR**: hub at **`/signalr/messages`** (ASP.NET Core SignalR, JSON protocol), auth with `?access_token=<apikey>`. It broadcasts
  `{name: "queue" | "album" | "artist" | "command" | "trackfile" …, body: {action: "updated"|"deleted"|"sync", resource}}`.
  `AlbumController` broadcasts on Grabbed, Imported, TrackImported and Updated events. This is good for real-time updates, but the protocol is
  undocumented and internal. Use it as an optimisation and keep queue polling as the source of truth.
* **Completion, authoritative**: **webhook `eventType: "Download"`** (`onReleaseImport`). The payload has `artist {id, name, path, mbId}`,
  `album {id, title, mbId (release-group), releaseDate…}`, `tracks[]`, `trackFiles[] {path, quality…}`, `isUpgrade`, `downloadId`.
  Other events: `Grab`, `DownloadFailure`, `ImportFailure`, `ArtistAdd`, `AlbumDelete`, `Retag`, `Rename`, `Health`
  ([WebhookEventType.cs](https://github.com/Lidarr/Lidarr/blob/develop/src/NzbDrone.Core/Notifications/Webhook/WebhookEventType.cs), [WebhookImportPayload.cs](https://github.com/Lidarr/Lidarr/blob/develop/src/NzbDrone.Core/Notifications/Webhook/WebhookImportPayload.cs)).
  Note that a partial album import fires `ImportFailure`/`AlbumImportIncomplete`, so the requested track may still be present. Check
  `GET /track?albumId=` for `hasFile` on the target recording.
* **Fallback reconciliation**: `GET /api/v1/history/since?date=<lastSeen>`. Event types: `grabbed, trackFileImported, downloadImported, downloadFailed, albumImportIncomplete, importFailed/downloadIgnored, trackFileDeleted`
  ([EntityHistory.cs](https://github.com/Lidarr/Lidarr/blob/develop/src/NzbDrone.Core/History/EntityHistory.cs)).
* **"Nothing found"**: the `AlbumSearch` command completes, but the queue and history stay empty for that album and `GET /wanted/missing`
  still lists it. Show "Not available yet. We'll keep looking." Lidarr's RSS sync keeps trying monitored albums automatically.

### 4. Pitfalls and limits

| Pitfall | Mitigation |
|---|---|
| Default metadata profile ("Standard") filters out EPs and singles, so the release group never appears in Lidarr and the add looks like it worked but nothing happens | Create our own profiles on setup. Use `POST /album` (manual add, which bypasses the filter) for out-of-profile release groups |
| `POST /artist` → **400 "This artist has already been added"** (ArtistExistsValidator); also a race if two users request at once | Always `GET /artist?mbId=` first. Serialize per-artist requests in the backend (mutex keyed by artist MBID). On 400, re-fetch and continue |
| Artist added with a different MBID (e.g., a collaboration "A & B" or an album artist other than the track artist) | Use the **release group's artist credit** as the Lidarr artist, not the track artist |
| `RefreshArtist` is slow (seconds to minutes for large discographies) and asynchronous. Albums do not exist right after POST | Use `albumsToMonitor` in a single call, or poll the command status |
| Metadata server outages / rate limits (see §2) | Retry queue, ID-only lookups, health check before showing the "Request" button |
| Album release choice: Lidarr monitors one *release*. The track may not be on that edition | Verify `foreignRecordingId` and switch the monitored release or set `anyReleaseOk` |
| Import blocked by tag mismatch (`importBlocked`) | Surface as "needs attention" to admins. Consider relaxing the "Allow Fingerprinting" and matching thresholds in Media Management |
| Lidarr "Unmonitor deleted tracks"/"Rescan" side effects | Leave defaults. Never delete files through Navidrome |
| Root folder mismatch: Lidarr's `rootFolderPath` must be inside a Navidrome library path, with the same path mapping if they run in different containers | Store a path-translation map (Lidarr path → Navidrome library id + relative path) |
| v3.0 removed Basic Auth and linux-x86. v3.x uses .NET 8. Plugins are now in mainline (≥3.1.2 develop) | Pin the Lidarr version in docker-compose. Test API compatibility on upgrade |
| Lidarr does no transcoding/streaming. Quality profiles decide FLAC vs MP3 size, which affects time-to-play | Offer a "fast" quality profile (MP3-320/AAC) for first-song requests (inference) |

---

## NAVIDROME

### 5. APIs

#### Subsonic / OpenSubsonic (`/rest/*`), the stable public contract
* Subsonic API 1.16.1 plus OpenSubsonic. Auth: `u` + `t`/`s` (token + salt) or `p`, and also an **API key** (`apiKeyAuthentication`
  extension). Add `f=json`, `c=<client>`, `v=1.16.1`. IDs are opaque strings.
* **OpenSubsonic extensions advertised** (`getOpenSubsonicExtensions`): `transcodeOffset v1`, `formPost v1`, `songLyrics v1,v2`,
  `indexBasedQueue v1`, `transcoding v1`, `playbackReport v1`, `topSongsByArtistId v1`, `apiKeyAuthentication v1`, and
  `sonicSimilarity v1` (only when a plugin provides it)
  ([opensubsonic.go](https://github.com/navidrome/navidrome/blob/master/server/subsonic/opensubsonic.go)).
* **Implemented endpoints** (from [api.go](https://github.com/navidrome/navidrome/blob/master/server/subsonic/api.go)):
  `ping, getLicense, tokenInfo, getMusicFolders, getIndexes, getArtists, getGenres, getMusicDirectory, getArtist, getAlbum, getSong,
  getAlbumInfo(2), getArtistInfo(2), getTopSongs, getSimilarSongs(2), getSonicSimilarTracks, findSonicPath, getAlbumList(2),
  getStarred(2), getNowPlaying, getRandomSongs, getSongsByGenre, setRating, star, unstar, scrobble, reportPlayback,
  get/create/update/deletePlaylist(s), get/create/deleteBookmark(s), getPlayQueue(ByIndex), savePlayQueue(ByIndex), search2, search3,
  getUser, getUsers (admin), getScanStatus, startScan (admin), getAvatar, getLyrics, getLyricsBySongId, stream, download,
  getTranscodeDecision, getTranscodeStream, getCoverArt, internet radio CRUD, shares CRUD, jukeboxControl`.
* **search3**: no Lucene syntax. It is a simple full-text/autocomplete match over normalized (accent-stripped, lowercased) title, artist and
  album, and a trailing `*` is stripped. Paging: `artistCount/artistOffset, albumCount/albumOffset, songCount/songOffset`, plus `musicFolderId`.
  An empty query (`""`) returns everything, which is useful for syncing. Do not expect fuzzy or typo tolerance. Our backend should add ranking
  ([searching.go](https://github.com/navidrome/navidrome/blob/master/server/subsonic/searching.go), [docs](https://www.navidrome.org/docs/developers/subsonic-api/)).
* **getArtistInfo2 / getAlbumInfo2 / getSimilarSongs2 / getTopSongs**: backed by "agents". Default `Agents = "deezer,lastfm,listenbrainz"`.
  **The Spotify agent was removed** (`Spotify.ID/Secret` are listed as removed options). Last.fm needs `LastFM.ApiKey/Secret` for full data.
  `EnableExternalServices=false` disables them all. **Similar songs and top songs return only tracks that exist in the library**, because they match
  external names against the library. For discovery of *non-library* music, call Last.fm/Deezer/ListenBrainz from our backend instead.
* **getRandomSongs** (`size, genre, fromYear, toYear, musicFolderId`), **getAlbumList2** types (`random, newest, frequent, recent, starred,
  alphabeticalByName/Artist, byYear, byGenre, highest`).
* **scrobble** `id, time, submission=true|false` (false = now playing). Plays count **only via scrobble**, not via stream. Navidrome forwards
  scrobbles to Last.fm/ListenBrainz per user. OpenSubsonic `reportPlayback` adds richer playback state.
* **stream**: `id, maxBitRate, format (mp3|opus|aac|…|raw), timeOffset (seconds, transcodeOffset ext), estimateContentLength`.
  `download` uses `bitrate`/`format`. The newer `getTranscodeDecision` + `getTranscodeStream` (OpenSubsonic `transcoding` ext) let the client
  describe its capabilities and let the server decide between direct play and transcoding
  ([stream.go](https://github.com/navidrome/navidrome/blob/master/server/subsonic/stream.go)).
  Transcoding needs `ffmpeg`. `DefaultDownsamplingFormat=opus`. Transcoding configs are editable in the UI only if `EnableTranscodingConfig=true`.
  `TranscodingCacheSize` defaults to 100MB.
* **getCoverArt** `id, size` (any pixel size, resized and cached server-side). Cover IDs look like `al-<id>`, `ar-<id>`, `mf-<id>`, `pl-<id>`.
* **ReplayGain**: every song (Child) has `replayGain {trackGain, albumGain, trackPeak, albumPeak}` read from tags. Lidarr does not compute ReplayGain,
  so run `rsgain` as a Lidarr custom script post-import (inference) or let the client normalise.
* **MusicBrainz IDs exposed** (critical for de-duplication), per [helpers.go](https://github.com/navidrome/navidrome/blob/master/server/subsonic/helpers.go):
  * Song `musicBrainzId` = **recording MBID** (`mbz_recording_id`). Song `isrc[]` = ISRC tags (OpenSubsonic). Also `bpm`, `moods`, `explicitStatus`,
    `displayArtist`, `contributors`, `sortName`.
  * Album `musicBrainzId` = **release MBID (`mbz_album_id`), *not* the release group**. Albums also expose `releaseTypes` and `originalReleaseDate`.
  * Artist `musicBrainzId` = artist MBID.
  * The **release-group MBID** (`mbzReleaseGroupId`), which is the key that equals Lidarr's `foreignAlbumId`, is available only through the
    **native API** (`/api/album` JSON: `mbzReleaseGroupId`, `mbzAlbumId`, `mbzAlbumArtistId`, `mbzAlbumType`) or the media file JSON
    (`/api/song`: `mbzRecordingID, mbzReleaseTrackId, mbzAlbumId, mbzReleaseGroupId, mbzArtistId`)
    ([model/album.go](https://github.com/navidrome/navidrome/blob/master/model/album.go), [model/mediafile.go](https://github.com/navidrome/navidrome/blob/master/model/mediafile.go)).
  * Lidarr writes MusicBrainz tags on import when tag writing is enabled, so Lidarr-imported music will carry all of these. Files added any other way may not.
* **startScan / getScanStatus**: `startScan` is **admin-only**. Params: `fullScan=true|false` and **`target=<libraryId>:<relative/folder>`
  (repeatable) for selective folder scans**. The call waits up to 3 s for the scan to start, then returns `scanStatus {scanning, count, folderCount,
  lastScan, error, scanType, elapsedTime}` ([library_scanning.go](https://github.com/navidrome/navidrome/blob/master/server/subsonic/library_scanning.go), [ParseTargets](https://github.com/navidrome/navidrome/blob/master/model/scanner.go)).
* **Multi-user / multi-library**: users have libraries assigned (`/api/user/{id}/library`, admin). Every Subsonic call is scoped to the user's
  libraries (`musicFolderId`). Per-user stars, ratings, play counts, play queue, and scrobble targets. Only admins can scan, manage users and see
  `getUsers`. Our backend should use an **admin service account** for scans and a **per-user account** (or API key) for playback and personal data.

#### Native REST API (`/api/*` + `/auth/login`), internal to the web UI
* `POST /auth/login {username, password}` returns `{token (JWT), id, name, isAdmin, subsonicSalt, subsonicToken, …}`. Send the token as
  **`X-ND-Authorization: Bearer <jwt>`**. A refreshed token comes back in the same response header, and `SessionTimeout` defaults to 48 h
  ([auth.go](https://github.com/navidrome/navidrome/blob/master/server/auth.go)).
* react-admin style resources: `/api/song, /api/album, /api/artist, /api/genre, /api/playlist (+ /{id}/tracks), /api/queue, /api/share,
  /api/radio, /api/tag, /api/scrobble, /api/player, /api/transcoding, /api/user, /api/library, /api/missing, /api/plugin, /api/config,
  /api/insights`. Filtering, sorting and paging use `_sort, _order, _start, _end` plus field filters, and `X-Total-Count` is returned
  ([native_api.go](https://github.com/navidrome/navidrome/blob/master/server/nativeapi/native_api.go)).
* **Server-sent events** at `/api/events` (JWT): `scanStatus`, `refreshResource`, `serverStart`, `keepAlive`. These are useful to learn that the scan finished.
* Smart-playlist rules can be created via `/api/playlist` with a `rules` object.
* **Undocumented and can change between releases.** A `DevAPIv1` flag hints that a versioned native API is in development. Use it only for what
  Subsonic lacks (release-group MBIDs, SSE, library/user admin, smart playlist CRUD) and wrap it behind an adapter.

#### Smart playlists (`.nsp`)
JSON files placed in a library folder or `PlaylistsPath` are auto-imported (`AutoImportPlaylists=true`) and refreshed lazily
(`SmartPlaylistRefreshDelay` 5 s):
```json
{
  "name": "Recently requested",
  "comment": "Added in the last 7 days",
  "all": [ { "inTheLast": { "dateAdded": 7 } } ],
  "sort": "dateAdded", "order": "desc", "limit": 100
}
```
Operators: `is, isNot, gt, lt, contains, notContains, startsWith, endsWith, inTheRange, before, after, inTheLast, notInTheLast, inPlaylist, notInPlaylist`,
nested `all`/`any`. Fields include `title, album, artist, albumartist, genre, year, rating, loved, playcount, lastplayed, dateadded, bpm,
filetype, comment`, and any tag. [Docs](https://www.navidrome.org/docs/usage/smartplaylists/).

#### Plugin system (WASM, Extism)
Navidrome loads **WebAssembly plugins** (`.ndp` = zip containing `manifest.json` and `plugin.wasm`) built with Extism PDKs (Go/TinyGo, Rust, JS, Python).
Config: `Plugins.Enabled`, `Plugins.Folder` (default `<DataFolder>/plugins`), `Plugins.AutoReload`, `Plugins.LogLevel`. Plugins are configured per
plugin with a JSON Schema in the UI. Manifest permissions gate host access (HTTP hosts with IP/CIDR validation for local services since v0.64.0)
([plugins README](https://github.com/navidrome/navidrome/blob/master/plugins/README.md), [docs](https://www.navidrome.org/docs/usage/features/plugins/)).
* **Capabilities** (functions a plugin exports): `MetadataAgent` (bio, images, similar artists, top songs…), `Scrobbler`, `Lyrics`,
  `SonicSimilarity` (powers `getSonicSimilarTracks`/`findSonicPath`), `TaskWorker`, `Lifecycle`, `SchedulerCallback`, `WebSocketCallback`.
* **Host services** (what a plugin can call): `HTTP, Scheduler, Cache, KVStore, Storage, Task (queue), WebSocket, Library (read metadata and
  files), Matcher, Artwork (public URLs), SubsonicAPI (in-process calls), Config, Users, ScrobbleRetriever`.
* **Relevance to us**: a plugin *could* react to scrobbles, run scheduled jobs, and call out to our backend, for example a scheduled "rescan on
  pending Lidarr imports" job or a metadata agent that serves our own external artist info. **A plugin cannot add new Subsonic endpoints or change
  search results**, so unified search must live in our backend. Keep the plugin optional.

### 6. Rescan after a Lidarr import, and how fast music appears

**Mechanisms**
1. **Filesystem watcher** (default on when `Scanner.Enabled=true`). It debounces `Scanner.WatcherWait` (5 s) and then runs an incremental
   scan of changed folders. On local disks, new Lidarr imports show up **about 5–30 s after files land**. **inotify/FSEvents do not fire on most
   NFS/SMB/FUSE mounts** or across some Docker bind setups, and then nothing happens until the next scheduled scan.
2. **Scheduled scan** `Scanner.Schedule` (cron, default disabled since the watcher exists).
3. **Explicit**: `startScan` with `target`, which is the one to use.

**Recommended pipeline**
```
Lidarr webhook (eventType=Download) ─► backend /hooks/lidarr
  1. map trackFiles[].path (Lidarr view) → Navidrome libraryId + relative artist/album folder
  2. GET /rest/startScan?target=<libId>:<Artist/Album>&f=json   (admin creds; debounce 10 s per library to coalesce multi-disc/album bursts)
  3. poll /rest/getScanStatus every 1–2 s until scanning=false (or listen to /api/events scanStatus)
  4. resolve: search3 by title+artist and match musicBrainzId/isrc (or a native /api/song filter, which is unverified, so test it)
  5. mark request "available", push to client (WebSocket/SSE/push notification), auto-enqueue or start playback if the user is waiting
```
* A targeted incremental scan of one album folder typically finishes in **under a few seconds** (inference from the selective-scan design in
  0.55+). A full-library scan can take minutes.
* Keep a reconciliation job (every 1–5 min) that compares Lidarr `trackfile` additions since the last check against Navidrome by MBID. This covers
  missed webhooks and watcher misses.
* Use `fullScan=false` always. `fullScan=true` re-reads every tag and is slow.
* `Scanner.PurgeMissing` (`never|always|full`) controls whether tracks removed by Lidarr upgrades disappear. Lidarr upgrades replace files, so
  Navidrome may briefly show missing files. Use `full` or `always` if upgrades are enabled.

---

## 7. De-duplication and matching (library ↔ external results)

| Level | Library (Navidrome) | External | Lidarr |
|---|---|---|---|
| Track | `song.musicBrainzId` (recording), `song.isrc[]` | Deezer `isrc` → MB recording | `track.foreignRecordingId` |
| Album | `/api/album.mbzReleaseGroupId` (native only), `album.musicBrainzId` = release | MB release-group | `album.foreignAlbumId` (= RG MBID) |
| Artist | `artist.musicBrainzId` | MB artist | `artist.foreignArtistId` |

Rules: (1) ISRC match, then (2) recording MBID, then (3) normalized `artist + title + duration ±3 s`. Album-level de-dup uses the release-group MBID.
That means the backend needs a **local index synced from the Navidrome native API** (`/api/album?_end=…` paging), refreshed after every scan,
because Subsonic alone does not give release groups. Also map "in library" to "in Lidarr but not downloaded" (Lidarr `album.statistics.trackFileCount`)
so the UI can show *Requested / Downloading* badges instead of offering a duplicate request.

## 8. Prior art
* [Aurral](https://github.com/lklynet/aurral): self-hosted discovery and request front-end with optional Lidarr and Navidrome playlist publishing,
  using MusicBrainz, ListenBrainz and Last.fm, with slskd/yt-dlp support. Worth studying for request UX and Lidarr defaults.
* Lidarr-integrated request apps (e.g. Overseerr-style forks) generally add whole artists. The `albumsToMonitor` trick is underused.

## 9. Sources
* Lidarr API docs: https://lidarr.audio/docs/api/
* Lidarr source (develop): https://github.com/Lidarr/Lidarr/tree/develop/src (files linked inline)
* Lidarr releases: https://github.com/Lidarr/Lidarr/releases
* Metadata server incident: https://github.com/Lidarr/Lidarr/issues/5498
* Lidarr FAQ (Servarr wiki): https://wiki.servarr.com/lidarr/faq
* hearring-aid metadata mirror: https://github.com/blampe/hearring-aid
* Tubifarry plugin: https://github.com/TypNull/Tubifarry
* Navidrome Subsonic compatibility: https://www.navidrome.org/docs/developers/subsonic-api/
* Navidrome smart playlists: https://www.navidrome.org/docs/usage/smartplaylists/
* Navidrome plugins: https://www.navidrome.org/docs/usage/features/plugins/ and https://github.com/navidrome/navidrome/blob/master/plugins/README.md
* Navidrome source: https://github.com/navidrome/navidrome (server/subsonic/*, server/nativeapi/*, conf/configuration.go, consts/consts.go)
* OpenSubsonic spec: https://opensubsonic.netlify.app/
* MusicBrainz WS/2: https://musicbrainz.org/doc/MusicBrainz_API (rate limit 1 req/s)
* Aurral: https://github.com/lklynet/aurral
