# Magpie 0.0.1: round 11 (owner requests, 2026-10-31) → build 11

The owner delegated all decisions; the *(call)*s below are the controller's. Unchanged guards:
- G0, G1, D3, D12, D15, D29, §5 voice, offline (T14), and the consent gate;
- the owner-data rules: tests touch only the dev stack, and app actions on the owner's own Navidrome data happen only on an explicit, confirmed user action.

Prior spec: docs/superpowers/specs/2026-10-30-magpie-priority-round-design.md (P1–P6), which this round extends.

## R1. Downloads resume (owner 1) + background downloads (owner 9)
- **Background downloads** *(call: yes)*.
  - Manual downloads, album/playlist/artist downloads and pre-downloads run on a background `URLSession` (`URLSessionConfiguration.background(withIdentifier: "com.bleak-rooster.magpie.downloads")`, `sessionSendsLaunchEvents = true`, `isDiscretionary = false`), so they continue when Magpie is closed or the phone locks.
  - Implement `application(_:handleEventsForBackgroundURLSession:completionHandler:)`. Finished files are moved into the store on delegate callbacks, even after a relaunch. The store, index and file protection rules are unchanged: CUFUA, and excluded from backup.
- **P1's foreground-only rule is replaced.** No pause on background, and the "Keep Magpie open to finish downloading" banner goes.
  - New setting "Download in the background" (Downloads & Storage), default **on**. When off, P1's foreground-only behaviour applies, which already exists.
  - "Keep screen on while downloading" stays, and only applies while the app is active.
  - Wi-Fi-only and the cellular rules still apply. Set `allowsCellularAccess` per the setting, and re-evaluate on change.
- **Resume** *(owner 1)*: a download stopped part-way continues from where it left off.
  - **Background session:** keep `resumeData` from cancellations and errors (`NSURLSessionDownloadTaskResumeData`), persisted per job in the store's partials folder. Resume with `downloadTask(withResumeData:)`.
  - **Fallback when there's no resumeData**, but a partial file exists and the server sent `Accept-Ranges`/`ETag` for an original-format stream: an HTTP `Range` request appends to the partial. Implementers verify against the dev Navidrome whether `/rest/stream` with `format=raw` honours Range, and document it.
  - **Transcoded downloads** can't be byte-resumed. A transcoded partial restarts from zero, while an original resumes.
  - Partials count toward the storage limit, are removed when cancelled, and are removed on sign-out.
- **Security:**
  - Background-session URLs carry the Subsonic token in the query, as streaming does today. The system daemon stores the request; this is accepted and documented in decisions.md.
  - The session identifier is per app, not per account. On sign-out: `invalidateAndCancel`, delete partials, and recreate the session lazily.
  - Never log URLs.
- **Downloading now** shows "Paused · 2.1 of 8.4 MB" for resumable partials, and Resume works.

## R2. Letter index feedback (owner 2)
While a finger is on the A–Z bar (custom and native), a large centred letter bubble shows the current letter, with a haptic tick per change, and fades out 0.4 s after release.
- Use a material background with the theme's accent.
- VoiceOver is unchanged (adjustable). Reduce Motion means no scale animation.
- If the system index API gives no drag callback, replace it on all lists with the custom bar, so behaviour is uniform.

## R3. Popular songs cached (owner 3)
- The artist page's Popular (top songs) is stored per scope and artist id: song ids plus row metadata, no secrets, Application Support, excluded from backup.
- It's shown instantly when the page opens, then refreshed. The list is replaced only if it differs, with no flicker or reorder animation storm.
- Same pattern as HomeFeed's saved shelves. Removed on sign-out.

## R4. Artist "Download all" (owner 4)
- The artist page action is "Download all songs".
- It confirms with the count and size estimate when known: "Download 143 songs by X? About 1.2 GB."
- It downloads every album of the artist, with the reason `.artist(id)`, so it shows on the artist's mark and can be removed as a group ("Remove downloads" when it's downloaded).
- It respects the storage limit and Wi-Fi rules. New albums later are not auto-added *(call)*.

## R5. Transcoding presets (owner 5)
Every transcode choice (Wi-Fi streaming, cellular streaming, download format when transcoded) becomes format × **High / Medium / Low** *(call)*:

| Format | High | Medium | Low |
| --- | --- | --- | --- |
| MP3 | 320 | 192 | 128 |
| AAC | 256 | 160 | 96 |
| Opus | 320 | 160 | 96 |

- Plus "Original" (no transcode).
- Rows show "High · 320 kbps".
- Saved preferences migrate to the nearest preset (ties go up).
- D42 (AAC) and D45 (Opus) still hold.
- CarPlay follows the phone's setting.

## R6. Shuffle and repeat on Now Playing (owner 6)
- Two buttons flank the transport row:
  - **Shuffle** (`shuffle`, highlighted when on);
  - **Repeat**, cycling Off → All → One (`repeat`, `repeat` highlighted, `repeat.1`).

  VoiceOver: "Shuffle, on", "Repeat, one".
- These use the player's existing shuffle and repeat state. Add repeat-one if the player lacks it: the song restarts at its end, and next/previous behave as usual.
- CarPlay Now Playing already shows shuffle and repeat: make sure they mirror the same state, including One.
- No page scroll: D43/P6 fit tests stay green.

## R7. Favourites (owner 7)
- The Now Playing star truly favourites the current song via Subsonic `star`/`unstar` (id), with optimistic UI, rolled back with a message if it fails.
- The state comes from the song's `starred`.
- Also:
  - **albums** (`albumId`): star in the album page header, plus a long-press menu;
  - **artists** (`artistId`): star in the artist page header, plus a long-press menu.

  Navidrome supports all three. Verify on the dev stack first; if unsupported, hide.
- The Favourites screen/shelf shows songs, albums and artists if it already lists them, or extend it.
- Offline: queue the star and send it when back online *(call)*, or show "You're offline" if no queue exists. The implementer picks the simpler and records it.

## R8. Playlists (owner 7b + owner 10)
- **Add to playlist:**
  - a song's long-press menu (everywhere songs appear), Now Playing's More menu, and the album/playlist menus ("Add all to playlist");
  - opens a sheet listing playlists (editable ones only: owned by the user), with "New playlist…" at top;
  - Subsonic `updatePlaylist?playlistId&songIdToAdd` (repeat), or `createPlaylist?name&songId`;
  - duplicates are allowed, but warn: "Already in X. Add again?"
- **Create:** a "+" in the Playlists list toolbar → a name alert → `createPlaylist`.
- **Playlist page More menu** (`ellipsis.circle`): Rename… (alert, `updatePlaylist name`), Download / Remove download, Shuffle, Add to queue, Delete playlist… (destructive, confirmed: "Delete 'X'? This removes it from Navidrome for everyone using it." → `deletePlaylist`).
  - Only for playlists the user owns. Read-only ones show only the non-editing items.
- **Remove songs:** in a playlist page, swipe a row → "Remove from playlist" (`updatePlaylist songIndexToRemove`). An Edit mode for multi-remove and reorder is optional *(call: skip reorder)*.
- Lists refresh after each change.
- **Owner-data rule for tests:** integration tests create their own playlists on the dev stack and delete only those.

## R9. Now Playing More menu (owner 7b, controller decides contents)
An `ellipsis.circle` button in Now Playing's top bar opens a menu:
- Add to playlist…
- Go to album
- Go to artist
- Favourite / Unfavourite
- Download / Remove download
- Sleep timer (move it here if it lives elsewhere; keep any existing entry point)
- Song info (a sheet: title, artist, album, year, genre, duration, format/bitrate being played, original format, file size, play count, path-free)
- Share is skipped *(call: nothing to share outside the owner's server)*

Lyrics stays its own button.

## R10. Now Playing title links (owner addendum)
- In Now Playing, the artist name is a button to the artist page, and the album name (at the top) is a button to the album page.
- They dismiss the Now Playing sheet and push onto the current tab's navigation stack.
- VoiceOver hints: "Opens the artist".
- Multiple artists → open the primary artist.
- Offline: open the downloaded-catalog version if one exists; otherwise disabled.

## R11. Album artists only (owner addendum)
- New preference "Album artists only", default **on**.
- **On:** the Artists list shows only album artists (Navidrome `getArtists` already returns album artists. Verify on the dev stack; if Navidrome exposes the role filter (native `/api/artist?role=albumartist` or `_filters`), use it).
- **Off:** it shows every artist, including track-only artists (native API without the role filter, or `role=artist|albumartist` as supported). Document what the dev Navidrome supports.
- The toggle is in Settings › Library and in the Artists page toolbar menu (`line.3.horizontal.decrease.circle`), bound to the same preference.
- The A–Z index and the downloaded marks keep working. CarPlay's Artists list follows the setting.

## R12. Swipe actions and queue replace (owner 11)
- **Songs (rows everywhere):**
  - swipe right (leading edge) = **Add to end of queue**; swipe left (trailing edge) = **Play next**;
  - a full swipe triggers the action;
  - a brief toast confirms ("Playing next" / "Added to queue").
- **Customisable:** Settings › Playback › Swipe actions, with "Swipe right" and "Swipe left" pickers: Play next, Add to end of queue, Add to playlist…, Download, Favourite, None.
  - Rows that have their own destructive swipe (a playlist's Remove, Downloads' Remove, Finds' Not for me) keep that on the trailing edge. Their custom trailing action moves to the long-press menu *(call)*.
- **Albums, playlists, artists** (rows and tiles where a swipe is possible: list rows; grids use the long-press menu):
  - the same direction mapping (right = end of queue, left = next);
  - a popup then asks "In order" or "Shuffled".
  - artist = all their songs (album order).
- **Tap to play** replaces the queue with the selection, as today; verify. A new setting, "Ask before replacing the queue", is default **off**. When on, tapping to play while a queue of more than 1 song exists asks: "Replace your queue? (n songs)" with Replace / Play next / Cancel.
- **CarPlay:** tap-to-play behaviour is unchanged, with no confirmation in the car (D12).

## R13. Immersive look (owner 8)
Immersive becomes a distinct theme, not one font swap:
- a display typeface pairing for titles, section headers and Now Playing title (system fonts only, e.g. a serif display such as New York with SF Pro Rounded or SF Compressed accents, decided by the implementer with the design language);
- bolder size contrast;
- colours drawn from the current artwork: a dominant/accent palette extracted on-device, cached per cover id, contrast-checked to WCAG AA against text, with a fallback to the theme accent;
- tinted backgrounds/gradients on Now Playing, album and artist pages;
- accent-coloured controls.

The other themes are unchanged. D15: Increase Contrast and large text are respected. Use only fonts available on iOS 27, with no bundled third-party fonts *(call: licensing)*.

## R14. Alternate app icons (owner)
- **4 designs × 3 colourways = 12** alternate icons, plus the current green art-4 as the default.
  - Each is flat and matte, at most 3 colours, with no gradients or gloss.
  - Designs are created in code (CoreGraphics or SwiftUI render, like `icon-preview-render.swift`) to 1024 px PNGs, light-mode only, plus the iOS 27 dark/tinted variants if the asset catalog requires them.
- **Concepts** *(call; refine visually)*:
  1. **Record:** a vinyl disc with a magpie-beak label.
  2. **Magpie:** a minimal geometric magpie silhouette.
  3. **Wave:** a sound-wave "M" monogram.
  4. **Nest:** concentric arcs forming a nest or headphone shape.
- **Colourways each:** e.g. Forest (greens + cream), Ink (navy + bone + coral), Sunset (rust + sand + charcoal). The implementer may tune them.
- **Settings › Appearance › App icon:** a grid of previews, using `UIApplication.setAlternateIconName`. Set `CFBundleAlternateIcons` via the asset catalog (`ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES`).
- The icon preview sheet PNG is committed in docs for the owner.

## Release process for build 11
1. Merge the workstreams.
2. Full package + app tests (MAGPIE_IT=1), check-writes, check-release.
3. CarPlay check: the CarPlay test suites, plus a scripted CarPlay simulator pass that walks every tab, plays, and uses shuffle/repeat/favourite/Keep.
4. A crash sweep: rerun the hunt sweeps and the XCUITest monkey over the new screens (swipes, menus, playlist editing).
5. A security review of the new surface (background session, playlist writes, the artwork palette cache) and the deferred T24 items that fit.
6. Upload build 11 (`--carplay`) to TestFlight. App Store review submission is NOT done without the owner's explicit confirmation.

Workstreams *(parallel worktrees)*:
- **X1** = R1 + R4 (downloads);
- **X2** = R5 + R6 + R9 + R10 + R12 (playback, queue, Now Playing);
- **X3** = R2 + R3 + R7 + R8 + R11 (library, playlists, favourites, artists);
- **X4** = R13 + R14 (look and icons).

Overlaps:
- Now Playing: X2 owns the layout and adds the More button. X3 provides `AddToPlaylistSheet(songIds:)` and the favourite APIs. X2's More menu calls them by those exact names. If not merged yet, stub behind the same names; reconcile at merge.
- Song rows: X2 adds swipe actions, X3 adds context-menu items.

## R15. Artwork for search results outside the library (owner addendum)
- **Search results not in the library** (songs and albums from MusicBrainz, artists) show artwork. Songs and albums use their release cover; artists use their picture.
- **Sources** *(call)*:
  - **Songs and albums:** Cover Art Archive (`https://coverartarchive.org/release-group/<rg-mbid>/front-250`, following its redirect, HTTPS only), keyed by the release-group MBID the search already resolves.
  - **Artists:** when Lidarr is connected, the `images` from Lidarr's `artist/lookup?term=lidarr:<mbid>` (poster/headshot `remoteUrl`, HTTPS only), fetched only for the visible rows (at most about 8 lookups per search, cancelled when the query changes).
  - **Without Lidarr, or with no image:** the existing placeholder (round record / monogram).
- **Not cached** *(owner)*:
  - outside images come from an ephemeral `URLSession` (no URLCache, no cookies);
  - they're held only in memory for the current result set and dropped when the results change or the search closes;
  - they're re-fetched on every new search;
  - they're never written to disk, the artwork disk cache (P4) or the backup.
- **In-library results** keep using the P4 persistent cache.
- **Privacy and safety:**
  - Requests carry the app's MusicBrainz User-Agent constant and no personal identifiers.
  - Only HTTPS URLs from expected hosts are followed: coverartarchive.org, archive.org redirects, and image hosts Lidarr returns, with HTTPS required.
  - Images are size-capped (≤ 2 MB) and decoded with downsampling.
  - An outage, a 404 or offline means the placeholder, silently.
  - Offline mode On sends nothing.
- **CarPlay:** the car search's "Not in your library" rows show the same art (in-memory, same rules), within the CarPlay image limits.
- **Workstream X5** (R15).

## R16. Request screens show art and keep working when you leave (owner addendum)
- **Art:** the Try sheet and the request wait/detail screens ("Looking…", "Spotted", "Bringing it home", Ready, etc.), the Activity/requests list rows, and the Play now banner show artwork:
  - the song's or album's cover, from the release group;
  - for an artist request, the artist picture.
  - Before the item is in the library, R15 rules apply: Cover Art Archive or Lidarr images, in memory only, re-fetched when the screen opens.
  - Once Navidrome lists it, the library cover is used through the P4 cache.
  - When nothing is available, the placeholder.
- **Leaving the screen** *(owner: "you should be able to leave it and it should work in the background")*:
  - Verify, with tests, that a request keeps going when its screen is dismissed or the user navigates elsewhere. The RequestRunner is owned by the model, not the view.
  - Verify that a request found ready while the user is elsewhere lands per D6 (queued next and the Play now banner) and posts the ready notification.
  - Fix anything that ties progress to the view's lifetime.
- **App in the background** *(call)*:
  - Register a `BGAppRefreshTask` (`com.bleak-rooster.magpie.requests`) that, when iOS grants time, runs one bounded runner pass: Lidarr queue/history reads and a Navidrome match check, with no new writes except the already-scheduled retry searches the runner would send anyway, and posts the ready notification.
  - Scheduled whenever requests are live; at most every 15 min (the iOS minimum hint).
  - Documented as best-effort: iOS decides when it runs.
  - Also, while audio plays in the background the process stays alive, and the runner keeps its 30 s cadence (verify).
- **Workstream X5** (R15 + R16).

## R17. Requests: get back to them, stalled Soulseek downloads, search again, live search rows (owner addendum)
- **Get back to a request:**
  - In search (phone and CarPlay-irrelevant), a "Not in your library" song/album/artist row that has a live request shows that request's status ("Looking…", "Bringing it home"…) instead of Try. Tapping it opens that request's page, never a second Try.
  - The same applies from Activity, from the Play now banner, and from the song row anywhere it appears.
- **Live rows:**
  - When a request becomes Ready, search results showing it update in place, without leaving search: the row becomes the library song (playable, normal row, P4 cached art), and its request page shows Ready with Play.
  - The same applies to the request page while it is open.
  - The trigger is the runner's ready event or the match index refresh. No polling from views.
- **Stalled Soulseek downloads** *(owner: "if there is no change in the download for 1 minute, then it should be deleted, blocked, and a new search performed")*:
  - Magpie sees slskd through Lidarr: the owner's Lidarr uses a Soulseek/slskd download client.
  - Detection: the queue item's `downloadClient` matches a download client whose `implementation`/`implementationName` is a Soulseek/slskd client (from `GET /api/v1/downloadclient`, read-only, cached per session).
  - A Magpie request's queue item from such a client whose progress (`sizeleft`, plus status/trackedDownloadState) has not changed for **60 s** *(call: "Stalled downloads give up after", Settings › Requests: 1, 2, 5, 10 min, default 1 min; Soulseek only)*:
    1. `DELETE /api/v1/queue/{id}?removeFromClient=true&blocklist=true&skipRedownload=true`;
    2. then the runner's `AlbumSearch` for that album, so the search is ours and counted.
  - The request shows "That source stalled. Looking for another…".
  - At most 5 automatic stall-retries per request *(call)*. After that it waits as "Still looking" with Search again.
- **Search again** (manual) on the request page, for a live request not yet imported:
  - if a Magpie-request queue item exists, remove it with the same DELETE (blocklist=true);
  - then `AlbumSearch`;
  - confirmed with "Search again? The current download will be removed and blocked.", shown only when a download exists;
  - rate-limited to once per 30 s.
- **Owner-data rule:**
  - The queue DELETE is allowed only through LidarrWriteGate, with exactly `removeFromClient=true&blocklist=true&skipRedownload=true`.
  - Only for a queue item whose `albumId` belongs to a live Magpie request for which the ledger shows Magpie monitored/added it.
  - It is re-read fresh right before (id, albumId, downloadClient).
  - It never touches downloads of anything else. It never deletes library files: the queue only, before import.
  - check-writes.sh covers it, and the write is logged in the change log.
- **Tests:**
  - dev stack: no Soulseek, so use stubs;
  - a read-only probe of the owner's real Lidarr `GET /api/v1/downloadclient` and `GET /api/v1/queue` shapes is allowed, under the owner-real-servers rules: reads only, never print credentials, no writes.
- **Workstream X6** (R17).

## R18. "Only in Finds" → add to your library, download choices, simple mode (owner addendum; absorbs the queued Lidarr release-type round)
- **Main library:**
  - Finds setup gains **Main library**: the Navidrome library that is your main collection, picked from `/api/library` and required when there's more than one library. It's stored with the Finds setup.
  - Also **Main folder**: Lidarr's main root folder, which already exists as Lidarr setup's main root. Show it alongside, so the pair is explicit.
  - The main library is used for targeted scans after Keep, and to decide "in your library" vs "only in Finds".
  - With exactly one non-Finds library, it's picked automatically.
- **Only in Finds:**
  - An artist whose every song Magpie knows is in the Finds library shows an info line on the artist page: "Only in Finds" (`sparkles` or the Finds symbol), plus a primary button **Add to your library**.
  - A find song's Now Playing More menu (R9) and the long-press menu get **Add to your library…**
  - For an artist Magpie added (ledger), this runs Keep (move into the main root, Lossless profile, remove `magpie-find`), then Bring in more per the choices below.
  - For anything else, it's informational only (owner-data rule): "Added outside Magpie. Change it in Lidarr."
- **Download choices sheet**, used by Add to your library, Bring in more, and the artist page's "Add to Lidarr and download" (W3):
  - **What:**
    - This album only;
    - The whole artist, with release types:
      - Albums / Albums + EPs / Albums + EPs + Singles;
      - plus Studio, Soundtrack, Live as toggles (Studio on by default);
      - Official releases only (always, not a choice).
  - **Quality:**
    - Lossless (FLAC), the Magpie Lossless profile;
    - Smaller files (MP3), the Magpie Fast Start profile or an MP3 profile Magpie provisions.

    The implementer verifies the existing Magpie profiles and names them clearly in the UI.
  - **Follow new releases** toggle.
  - Each choice shows "about N hours" when known (existing Bring in more logic).
- **Metadata profiles for release types:**
  - Magpie provisions, on demand, metadata profiles named `Magpie <Types> · <Secondary>` (e.g. `Magpie Albums+EPs · Studio+Live`), Official status only.
  - Created only if missing. An existing profile with that name but different settings stops with an explanation (existing provisioning rule).
  - Applied only to artists Magpie added (ledger). Gate shape: `PUT /artist/editor {artistIds:[id], metadataProfileId}`, plus the existing quality and monitor shapes.
  - Never changes artists the owner added.
- **Simple downloads** (Settings › Requests, default **ON**):
  - When on, every one of these actions skips the sheet and uses the defaults set in Settings › Requests › **Download defaults**: What (default The whole artist), Types (default Albums + EPs, Studio), Quality (default Lossless), Follow new releases (default off).
  - The defaults can't be changed per download. The confirmation stays a single "Add <artist> to your library?" with a one-line summary of the defaults.
  - When off, the sheet appears every time, preset with the defaults.
- **Try (single song)** is unchanged *(call)*: one release, the Fast Start profile, and the Magpie Finds metadata profile for new artists. The release types only matter once more is brought in.
- **Tests:**
  - dev Lidarr with gated writes on the test's own fixture artists only, cleaned up afterwards;
  - profile provisioning is idempotent;
  - gate refusals for non-Magpie artists;
  - simple mode on/off flows;
  - the Only in Finds detection, including mixed artists (some in main → not "only in Finds");
  - Main library auto-pick and picker.
- **Workstream X7** (R18). It touches the gate after X6; it's merged after X6.
