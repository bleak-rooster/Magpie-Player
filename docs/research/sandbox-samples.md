# "Sample by fetching": validation notes

Researched 2026-10-26. Sources: Lidarr `develop` source (shallow clone 982bb9f, 2026-10-25) and a live **Lidarr 3.1.6.5079** container (linuxserver `latest`); Navidrome `master` (ec2e0a9, 2026-10-23), the **v0.64.2** tag source, and a live **Navidrome 0.64.2** container (`deluan/navidrome:0.64.2`). Both containers shared bind-mounted `/music` and `/samples` folders and held generated test MP3s. Everything was removed afterwards.

Legend: **[live]** = tested against the running containers. **[src]** = read in source. **[inf]** = inference, not tested.

## The idea

There are no open-source previews for mainstream music. So when a user wants to hear a song that isn't in the library, the app asks Lidarr for the **smallest release** that contains it (Single → EP → Album). Lidarr downloads it into a separate **Samples** root folder, which Navidrome serves as a separate **library**. The user hears the song, then either taps **Keep** (move it into the main library and continue the normal discography flow) or does nothing (the app auto-deletes it after N days).

## Verdict

**Feasible, and cleaner than expected on the Navidrome side.** Navidrome 0.64 has the three pieces the design needs, and all three were verified live:

- separate libraries with per-user access
- `musicFolderId` scoping on the main list and search endpoints
- a per-user **scrobble filter** that can block `library_id = Samples` on the server side

Navidrome also detects a **cross-library move** and keeps the song ID, stars and play count when Keep moves the files.

On the Lidarr side the main limit is structural: **an artist lives in exactly one root folder**. Sampling therefore only goes to Samples for artists who aren't in Lidarr yet. Keep is one bulk-editor call that physically moves the artist folder.

Latency is the real weak point. Without Tubifarry a "sample" is often a wait of several minutes to hours, or never arrives, so the feature should be presented as **"Try it (arrives in a few minutes)"**, not as a preview. Keep MusicKit previews (spec §7) for instant listening. Sample-by-fetching is the fallback when there's no MusicKit (web, or no catalog match), or the "I want the real file now" path.

---

## 1. Lidarr: root folders, adding, moving

| Question | Answer |
|---|---|
| Several root folders? | Yes. `POST /api/v1/rootfolder {name, path, defaultQualityProfileId, defaultMetadataProfileId, defaultMonitorOption, defaultNewItemMonitorOption}` created `/music` and `/samples` **[live]**. A *nested* root (`/music/_samples`) was also accepted (no ancestor validator, `RootFolderController.cs`) **[live]**, but it isn't recommended (see §3). |
| Add an artist to the second root via API | Yes. `POST /api/v1/artist` with `rootFolderPath:"/samples"` gave `path:/samples/Portishead` **[live]**. |
| Same artist in two roots? | **No.** `Artist` has a single `Path`/`RootFolderPath`, and `Album` has no path of its own: track paths are built from `artist.Path` (`FileNameBuilder.cs` L170). A second `POST /artist` with the same MBID returns `ArtistExistsValidator: "This artist has already been added."` **[live]**. |
| Move via `PUT /api/v1/artist/editor {artistIds, rootFolderPath, moveFiles:true}` | **Moves the files on disk.** It queues `BulkMoveArtistCommand`, and `MoveArtistService` runs `TransferFolder(…, TransferMode.Move)`. `MediaFileService.Handle(ArtistMovedEvent)` rewrites the track-file paths. Live result: `/samples/Portishead/01 Mysterons.mp3` became `/music/Portishead/…`, `/trackfile` showed the new path, HTTP 202, and the command ran in about 25 ms **[live]**. |
| Move via `PUT /api/v1/artist/{id}?moveFiles=true` | Also works. Send the full resource with a new `path` and `rootFolderPath`; it queues `MoveArtistCommand` **[live]**. The editor call is simpler because it computes the folder name. |
| Move failure | On an `IOException` Lidarr logs the error and **reverts the artist path** (`RevertPath`). Same filesystem means a rename (instant); a different filesystem means copy then delete. Put Samples on the **same volume** as the main library. |
| Does the move rescan Navidrome? | **No.** The Subsonic connection calls `startScan` only on `OnReleaseImport`, `OnRename` and `OnTrackRetag`. On `OnArtistDelete` and `OnAlbumDelete` it only sends a chat notification, and there is no hook for moves (`Subsonic.cs`) **[src]**. Navidrome's watcher picked the change up in the live test. A Keeper (Navidrome admin) should still call `startScan` after Keep and after cleanup. |

**Implication: the artist is already in Lidarr.**
- *Already in **Samples*** (sampled before): monitor the other single on the same artist. It lands in Samples too. Fine.
- *Already in **main*** ("kept"): there is nowhere to sample into. **Recommendation: do not sample, just request.** Monitor the smallest release in the main root and run the normal song-first request. The user already chose this artist, so a single in the library costs nothing. Offer "Remove" on that release for a while. Remove means `DELETE /api/v1/trackfile/bulk {trackFileIds}` plus `PUT /album/monitor {monitored:false}`. Don't delete the album entity (see §2). In the UI it shows as a normal library item, and there is no scrobble suppression (none is needed).
- *Unknown artist*: this is the only true sample case.

**Critical edge case:** any *normal* request (song/album/artist or discography expansion) for an artist whose `rootFolderPath == samples` **must first run the Keep move**. Otherwise the discography downloads into Samples and the cleanup job deletes it. Put this check into the request state machine (spec §8, step 2).

## 2. Deleting a sample and preventing re-download

| Action | Behaviour |
|---|---|
| `DELETE /api/v1/artist/{id}?deleteFiles=true&addImportListExclusion=true` | Removes the artist and **its whole folder from disk**: `/samples/Portishead` was gone, and an exclusion `{foreignId: <artist MBID>}` was created **[live]**. Safety guard: files are skipped if the artist path is a parent of, or equal to, another artist's path (`MediaFileDeletionService.HandleAsync(ArtistsDeletedEvent)`). |
| Recycle bin | With `config/mediamanagement.recycleBin` set, "deleteFiles" **moves the files to the recycle bin** instead (cleared after `recycleBinCleanupDays`, default 7). Disk space is freed later. Default is empty, meaning permanent delete **[live config]**. Setup should show the effective value. |
| Re-adding after an exclusion | `POST /artist` for an excluded MBID **still succeeds**, but the exclusion row stays **[live]**. The exclusion only stops *import lists* (for example Tubifarry's ListenBrainz lists, which would otherwise re-add a rejected sample artist). `AddAlbumService` deletes exclusions; `AddArtistService` does not. **Recommendation:** add the exclusion only when import lists exist (`GET /importlist` not empty). When the user later requests that artist, delete the exclusion (`DELETE /importlistexclusion/{id}`). |
| `DELETE /api/v1/album/{id}?deleteFiles=true&addImportListExclusion=…` | Deletes the album row and its files. **Without the exclusion, the next artist refresh re-adds the album** (`RefreshArtistService.GetRemoteChildren` filters only excluded album IDs, L216–221). It would then be monitored again if the artist's `monitorNewItems` is `all`, and downloaded again. Use it only together with the exclusion, or (preferred for kept artists) delete the track files and unmonitor the album instead. |
| No re-download for samples | Add sample artists with `monitored:true`, `monitorNewItems:"none"`, `addOptions:{monitor:"none", searchForMissingAlbums:false}`, and monitor only the one release. After the file imports, the app may unmonitor that release. Then nothing is "wanted", and RSS sync, Search Sniper and missing-search all ignore it. |

## 3. Navidrome multi-library (v0.64.2)

| Question | Answer |
|---|---|
| Create a library | Admin-only native API: `POST /api/library {name, path, defaultNewUsers:false}` returned `{"id":"2"}`. Saving it starts a watcher and an initial scan (`core/library.go` `Save`) **[live]**. The path must be **absolute and exist inside Navidrome's container**. If the owner's compose file mounts only `/music`, they must add a mount, which is a one-time manual step the app can't do. |
| Workaround without a new mount | Use a nested folder and `.ndignore`. Put `/music/.ndignore` containing `_samples`, then create library `/music/_samples`. Result: library 1 ignored the folder and library 3 indexed it **[live]**. Lidarr accepts the nested root too. The risk is that Lidarr's scans of `/music` also walk `_samples` **[inf, untested]**. Prefer **sibling folders on the same volume** (`/data/music`, `/data/samples`) and use the nested setup only as a fallback. |
| Per-user access | `PUT /api/user/{id}/library {libraryIds:[1,2]}` (admin). Non-admins **can** be given Samples. Admins automatically get every library and can't be assigned manually. New users get only libraries with `defaultNewUsers=true`, so the app must add Samples when it creates users or invites them **[live, src]**. A user without access gets neither the folder nor its songs: `getMusicFolders` showed only library 1, and `search3` returned only the main song **[live]**. |
| Scoping out samples | `musicFolderId` (repeatable) is honoured by `search2/3`, `getRandomSongs`, `getAlbumList/2`, `getSongsByGenre`, `getStarred/2`, `getIndexes` and `getArtists` (`selectedMusicFolderIds`). With no parameter, the user gets **all** their libraries. Live `search3`: no param → main + sample; `=1` → main; `=2` → sample; `=1&=2` → both **[live]**. **Not scoped:** `getArtist`/`getAlbum`/`getSong` (by ID), `getSimilarSongs*`, `getTopSongs`, `getArtistInfo`, and playlists. Smart playlists the app creates can add `{"isNot":{"library_id":<samples>}}`, since `library_id` is a valid criteria field (`model/criteria/fields.go`). For the rest, the client filters with its match index: the native `/api/song` and `/api/album` include `libraryId` **[live]**. |
| Scrobbles | Plays count only through Subsonic `scrobble` or OpenSubsonic `reportPlayback` (or the Jellyfin-compat session API). `stream` doesn't scrobble, which the live stream test confirmed: no scrobble log line. Note that **`reportPlayback state=stopped` at ≥ 50 % (or 4 min) *does* scrobble** unless `ignoreScrobble=true` is sent (`play_tracker.go` L363–383). Navidrome's own ListenBrainz/Last.fm forwarding runs only from those paths. So the client simply makes no scrobble or reportPlayback call for samples. |
| Server-side guarantee | **Per-user `scrobbleFilter`** (in v0.64.2; admin can set it via `PUT /api/user/{id}`, the user too if `EnableUserEditing`). Set `{"all":[{"is":{"library_id":2}}]}` and the live result was: scrobbling the sample logged `Ignoring external Scrobble for filtered track`, while the main-library song went through **[live]**. It also blocks NowPlaying (`Ignoring external NowPlaying update for filtered track`) **[src]**. Local play count still goes up. If a user already has a filter, merge it with `any`. This covers other clients (Feishin, Navidrome web UI) too. |
| Keep → move between libraries | Moving `/samples/Sample Artist` to `/music/…`: Navidrome's "process cross-library moves" scanner phase kept the **same song ID**, with the star and playCount preserved and `libraryId` now 1 **[live]**. So starring a sample and then keeping it doesn't lose anything. In the live run the watcher saw the move on Docker Desktop. On NFS/SMB it won't, so call `startScan`. |
| Deleted samples leave "missing" rows | `Scanner.PurgeMissing` defaults to `never`, so deleted samples stay as `missing` media files. They're hidden from search, but they pile up, and quick move-then-delete churn produced duplicate missing rows **[live]**. A Keeper calls `DELETE /api/missing?id=…` (or with no IDs, which purges all; the live call returned 200 `{"ids":null}`) after cleanup. Alternatively the owner sets `ND_SCANNER_PURGEMISSING=always`. |

## 4. Rescans (Lidarr Subsonic connection)

Lidarr calls `GET /rest/startScan` with **no `target`** (`SubsonicServerProxy.Update`). On Navidrome that is an incremental scan of **every library**: the live log showed both `libraryId=1` and `libraryId=2` being processed. So imports into Samples are covered **[live, src]**. Moves and deletes are **not** covered (§1). The watcher handles those on local disks, and as a backup the Keeper calls `startScan?target=<libId>:<Artist>` for both libraries after Keep or cleanup.

## 5. Latency (what to promise)

Chain: [artist add + metadata refresh] → `AlbumSearch` → indexer search → grab → download → Lidarr's `RefreshMonitoredDownloads` poll (**every 1 min**, `TaskManager.cs` L71) → import → Subsonic `startScan` → Navidrome indexes it (seconds) → app poll.

- **Artist add + refresh**: the live Portishead refresh took **23.5 s** (small discography). Big discographies take minutes, and SkyHook outages block it completely. This step is skipped for sampling a second song by an artist already in Samples.
- **Plain Lidarr + Usenet**: if a single exists on the indexers, roughly search 5–30 s + download < 1 min + up to 1 min poll + import, so **about 2–5 min end to end** **[inf]**. Singles and EPs are often **not indexed at all**. The fallback is the full album (bigger and slower), or nothing.
- **Plain Lidarr + torrents**: seeder-dependent. Minutes to hours, often never for singles **[inf]**.
- **Tubifarry (YouTube/Streamrip/Lucida/slskd)**: per-track sources find singles reliably. A 1-track release downloads in seconds, so **about 1–3 min** including refresh and the 1-min poll **[inf, from tubifarry.md]**. slskd varies with peers.

UX: present it as **"Get it to try"**, with a progress card and an "I'll tell you when it's ready" state. Never call it a "preview".

## 6. Abuse, storage, cleanup

- **Cap**: per-user open samples (for example 10) and a household cap (for example 50), stored in the mailbox like requests (`kind:"sample"`). Listeners create samples through the mailbox, and Keepers run them.
- **Size**: give samples a dedicated **"Sample" quality profile** (good lossy, `upgradeAllowed:false`). It downloads faster and is about 5–10 MB per single. On Keep, the editor switches `qualityProfileId` to the main profile, so the cutoff is unmet and Lidarr upgrades the file to lossless. Measure usage with `GET /artist` → `statistics.sizeOnDisk` summed where `rootFolderPath == samples`, plus `GET /rootfolder` → `freeSpace`. Refuse new samples above a quota (for example 2 GB). If only an Album is available, ask "this is a 14-track album, try anyway?" or count it against the quota.
- **Shared state without a server**: tag sample artists in Lidarr (`POST /tag {label:"sample"}`, set on add). Expiry uses `artist.added`, or "last played" from Navidrome's album `played`, so **any Keeper device** can run cleanup and no extra store is needed. A Listener's Keep goes through the mailbox (`kind:"keep"`).
- **Cleanup job** (Keeper sweep): for artists tagged `sample` and still in the samples root that are older than N days (default 7) and weren't played in the last 2 days: `DELETE /artist/{id}?deleteFiles=true` (plus the exclusion only if import lists exist), then Navidrome `startScan` and `DELETE /api/missing`.
- **Sample whose artist was later kept**: there is no orphan. Keep (or any normal request, §1) moves the whole artist, including the sampled single, and removes the `sample` tag. The cleanup job matches only tagged artists *still in the samples root*, so a kept artist can't be deleted by mistake.
- **Two users, same artist**: the per-artist lock (spec §8) applies. Keep is household-wide: once anyone keeps the artist, it stays.
- **Legal and App Review**: a "sample" is a full download, the same as a request. It's subject to the same source caveats as tubifarry.md §5, and adds no new risk class.

## 7. Navidrome internet radio (not useful here)

`getInternetRadioStations` returns admin-created `{streamUrl, homePageUrl}` entries, and creating, updating or deleting them is admin-only (`api.go` L199–204). Navidrome doesn't proxy or transcode them; the client plays the URL directly. It's a bookmark list for live streams, not a way to fetch per-track external audio. There's no other Navidrome feature that streams non-library audio. Plugins can't add Subsonic endpoints (lidarr-navidrome.md).

## Recommended flow

```
User taps "Try it" on a non-library song (Keeper device, or Listener → mailbox kind:"sample")
 1. Resolve recording → artist MBID, release groups (spec §8 step 1)
 2. Lidarr artist?
      none          → POST /artist rootFolderPath=<samples>, tag "sample", quality "Sample",
                      metadata profile incl. singles/EPs, monitor none, no search; wait for refresh
      in samples    → reuse
      in main       → NOT a sample: run the normal song-first request (offer "Remove" later)
 3. Pick smallest release group (Single → EP → Album; confirm if Album); PUT /album/monitor; AlbumSearch
 4. Track via queue/history (spec §8); Lidarr's Subsonic connection rescans both libraries
 5. Ready → play from library <samples> (client sends no scrobble/reportPlayback;
    server-side scrobbleFilter library_id=<samples> as the backstop); UI badge "Trying"
 6a. Keep → PUT /artist/editor {rootFolderPath:<main>, moveFiles:true, qualityProfileId:<main>,
            tags:[sample], applyTags:"remove"} → expand discography per default → Keeper startScan
            (Navidrome keeps song IDs/stars across the library move)
 6b. Ignore → after N days unplayed: DELETE /artist?deleteFiles=true (+exclusion only if import lists)
            → startScan → DELETE /api/missing
Guard: any normal request for an artist in <samples> runs 6a first.
```

**Setup additions (owner, once):** create the Lidarr root `<samples>` (same volume as main) and a Navidrome library on the same path (needs the mount); grant Samples to every user (and to the invite flow); set each user's `scrobbleFilter`; create the "Sample" quality profile and the `sample` tag; check the recycle-bin setting; optionally set `PurgeMissing`. If Navidrome can't see a samples path, hide the feature. Spec §9's "features that don't exist are absent" rule applies.
