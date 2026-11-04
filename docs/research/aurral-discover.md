# Aurral Discover / Trending / Recommended research (2026-11-04)

Read-only. Sources: owner's server (two unauthenticated GETs only), upstream source lklynet/aurral at tag v2.13.0 (clone at scratchpad/aurral213), v2.10.0 (scratchpad/aurral) for the diff, release notes 2.11–2.13, and one GET each to public fallback APIs. No secrets were printed and no logins were made.

## 0. Owner's server
`GET /api/health/bootstrap` and `GET /api/health` (open paths):
- appVersion **2.13.0**. That is also the **latest release** (published 2026-11-03), so the owner's version and latest are the same code.
- authRequired true; proxyAuth/OIDC/Google/Plex all off; onboardingRequired false.
- api.version 1; features: discover, flows, playlistCoverTemplates, activity, review, trackDownloads, linkSearch, downloadCancel, shareImports, **trending**, flowAutoDownload.
- matcher available, policyVersion aurral-native-6.
- Releases: 2.10.0 (09-23), 2.11.0 (10-20), 2.12.0 (10-27), 2.13.0 (11-03).

Magpie can feature-gate on `api.features` containing `"trending"` (2.13+) and `"discover"`.

## Auth (g)
- `POST /api/auth/login` with body `{username, password}` returns `{token, expiresAt, ...}`. This is unchanged from 2.10 and is rate-limited by signInLimit.
- Every other `/api/*` route accepts any of: `Authorization: Bearer <token>`, `x-api-key` (the admin API key, which can now be set with the AURRAL_API_KEY env), Basic auth, or proxy auth.
- Open paths (no auth): /api/health, /api/health/live, /api/health/bootstrap, auth login routes, **GET /api/deezer/preview/*** and **GET /api/image-proxy/***.
- Permissions: admins pass everything. Non-admin defaults are addArtist **true**, addAlbum **true**, accessFlow **false**, changeMonitoring false, deleteArtist/deleteAlbum/deleteTrack false.

## a. Recommended (per-user)
- `GET /api/discover?limit=&offset=` requires a signed-in user. limit is clamped to 1–200; with no limit it returns everything.
  - Scope is per user. Each user has their own pool built from their likes, plays, history (Last.fm/ListenBrainz/Koito/Spotify import) and the Library. If a user has no pool yet, it falls back to the global pool, which is chart-seeded on day one.
  - Library artists, blocked artists and blocked tags are filtered out.
  - Response:
    - `recommendations[]`, `recommendationCount`, `globalTop[]`
    - `basedOn[]` (seeds `{name, source,...}`), `topTags[]`, `topGenres[]`
    - `lastUpdated`, `recommendationQuality`, `isEnriching`, `discoveryRunId`, `enrichment*`
    - `configured`, `provider`, `discoveryMode`
  - Each recommendation (or globalTop item) is an **ARTIST ONLY**, with these fields:
    - `id` (= MusicBrainz artist MBID, or null), `navigateTo` (same MBID)
    - `name`, `type`, `image` (often null; the UI falls back to the artist cover route), `tags[]`, `matchedTags[]`
    - `sourceArtist`, `sourceArtists[]`, `sourceType`, `supportingSeeds[{artistName}]`
    - `discoveryTier`, `discoveryDepth` (1 = close, ≥2 = "further out"), `firstDiscoveredAt`
    - `score`, `scoreTotal`, `matchPercent`, `popularityLabel`, `popularityRank`, `listeners`, `playcount`
  - There are no album, track or preview fields.
- `GET /api/discover/status` returns `{isUpdating, updatePhase, updateProgress, updateProgressMessage, lastUpdated, error}`.
- Feedback (all requireAuth):
  - `GET /api/discover/feedback`
  - `POST /api/discover/feedback` with body `{action, artistId, artistName, sourceContext, tagContext[], seedContext[]}`
  - `DELETE /api/discover/feedback/:id`
  - `POST /api/discover/feedback/restore` and `POST /api/discover/feedback/reset`
- Blocked genres: `GET|POST|DELETE /api/discover/blocked-tags`.
- Preferences: `GET|POST /api/discover/preferences` and `POST /api/discover/preferences/reset`.
- Tags: `GET /api/discover/tags?q=&limit=` and `GET /api/discover/by-tag?tag=&limit=&offset=`.
- Admin only: `POST /api/discover/refresh`, `/clear` and `/clear-discovery`.
- Other per-artist routes:
  - `GET /api/artists/:mbid/similar?limit=(1-20, default 10)&artistName=` returns `{artists:[...]}`. It now falls back to Deezer.
  - `GET /api/artists/:mbid/preview?artistName=` returns `{tracks:[{id (Deezer track id), title, album, artworkUrl, preview_url, duration_ms}]}`. This is the Deezer top 6 tracks that have previews.
- How the web UI groups the "Recommended" page (frontend/src/pages/recommendedRails.ts). This happens on the client and is easy to mirror:
  - **Top pick**: the first item.
  - **New this week**: `firstDiscoveredAt` is within 7 days.
  - **"Because you like <seed>"** rails: up to 3 seeds, each needing at least 4 direct picks. The seed comes from `supportingSeeds`/`sourceArtists` matched against `basedOn` names.
  - **Close to home**: the remaining picks with depth < 2.
  - **Further out**: depth ≥ 2.
  - The card subtitle reads "like X, Y" for close picks and "via X" for further-out picks; if neither applies it shows the first genre.
  - The **All** tab is a sortable list (rank, name or first seen) with filters all/new/close/further/genre/seed.

## b. Trending / charts (new in 2.13)
- `GET /api/discover/trending` (requireAuth; served from the SQLite cache) returns:
  - `region` (ISO2, e.g. "AU"), `updatedAt` (ms)
  - `songs`: `{playlistId, playlistName ("Top Australia"), libraryPlaylistId|null, items[], spotlight:{ranks[14], daysAtTop}|null}`
  - `albums[]` (top 25 of Apple's 100), `genreShare` `{total, other, genres[{name,count}]}`
  - `artists[]` (25)
  - `genres[]`: `[{id, name, covers[4], artists[2]}]`
- Field shapes:
  - Song item: `{key (Deezer track id), trackName, artistName, albumName, deezerAlbumId, durationMs, artworkUrl (cover_medium), largeArtworkUrl (cover_xl), preview_url ("/api/deezer/preview/<id>.mp3"), position, movement (number | "new" | null)}`. There are **no MBIDs**.
  - Album item: `{key (Apple id), name, artistName, artworkUrl (500x500 mzstatic), releaseDate, genre, position}`. No MBIDs and no previews.
  - Artist item: `{key (Deezer artist id), name, imageUrl (picture_xl), fans, mbid (guessed; can be null), position}`.
- `GET /api/discover/trending/genres/:genreId` (genreId is 1–6 digits) returns `{id, name, region, updatedAt, items[50 songs as above]}`. It returns 404 `{"error":"This genre chart isn't available yet"}`.
  - Genre ids: 132 Pop, 116 Rap/Hip Hop, 152 Rock, 113 Dance, 165 R&B, 85 Alternative, 106 Electro, 129 Jazz, 464 Metal.
- Data sources (no API key needed):
  - Region = Deezer `GET /infos` → `country_iso`, which is the **geo-IP of the Aurral server**. If that fails, Aurral uses the last region it stored, else "US". **There is no country query parameter.** An AU-hosted server gets AU.
  - Songs = the Deezer editorial playlist named "Top <Country>", owned by Deezer user 637006841. It falls back to "Top Worldwide". I verified "Top Australia" exists as playlist **1313616925** (100 tracks).
  - Albums = Apple Music RSS `https://rss.marketingtools.apple.com/api/v2/<cc>/music/most-played/100/albums.json`, falling back to the US feed. I verified AU works.
  - Artists = Deezer `/chart/0/artists` (25). The MBID comes from Aurral's guessArtistMbid. No country parameter is passed, so Deezer applies geo-IP.
  - Genre charts = Deezer `/chart/{genreId}/tracks` (50 each). This is global or geo-IP; no country is passed.
  - **There is no top-tracks chart from Apple, and nothing from Last.fm or ListenBrainz.**
- Refresh and failure modes:
  - The system task "trending-charts-refresh" is considered fresh for 5h. Each section succeeds or fails on its own, and the task throws only if every section fails.
  - The response field is null when a chart has never been fetched.
  - Chart movement starts from the second day (30 days of history).
- UI (TrendingPage) sections:
  - "No. 1 song" spotlight
  - songs list with **Save as playlist**
  - "Top albums"
  - "Top artists"
  - "Charts by genre", which leads to TrendingGenrePage
  - "Popular playlists"
  - The Discover home page has a "Trending artists" rail.

## c. Previews
- All Deezer-sourced items carry `preview_url = "/api/deezer/preview/<deezerTrackId>.mp3"`. The route is **open, so no auth is needed**.
  - Aurral re-resolves the live link with Deezer `/track/<id>` (cached 5 min) and answers with a **302 redirect** to `cdnt-preview.dzcdn.net/...mp3?hdnea=exp=...`. That signed URL expires about 15 minutes after it is issued, which is why the proxy exists. The response sets Cache-Control: no-store.
  - `?download` makes Aurral proxy the bytes (audio/mpeg) instead of redirecting.
  - It returns 404 when there is no preview and 502 when Deezer is down.
  - Magpie should use the Aurral path, prefixed with the base URL, and not cache the raw Deezer URL. AVPlayer follows the 302.
- Apple album items have no preview.
- Recommendation artists have none either; use `GET /api/artists/:mbid/preview?artistName=`. `useArtistPreviewPlayback` does the same.

## d. Search
- `GET /api/search?q=&scope=artist|album|tag&limit=&offset=&releaseTypes=a,b&sort=relevance` searches the catalog through **BrainzMash**, Aurral's hosted MusicBrainz mirror. Results carry MBIDs.
- `GET /api/search/unified?q=&mode=suggest|full&limit(≤30)` returns:
  - `{query, mode, top, catalog:{artists[], albums[], tracks[] (always empty from catalog)}, localSearchConfigured, filters}`
  - artist: `{type:"artist", source:"brainzmash", id (MBID), name, sortName, inLibrary, hasMbid, score}`
  - album: `{type:"album", id (release-group MBID), title, artistName, artistMbid, primaryType, secondaryTypes, releaseDate, coverUrl, inLibrary}`
  - These are annotated against the Library and playlists.
- `GET /api/search/library?q=&limit` searches local Library tracks. Each track has `trackMbid`, `albumMbid`, `artistMbid`, `streamPath`.
- `GET /api/search/link?url=` resolves a streaming link (requireAuth).
- **There is no catalog track search and no Deezer or Last.fm search.** To get tracks, use `GET /api/artists/release-group/:mbid/tracks`.

## e. Request / add
- Artist: `POST /api/library/artists` (permission addArtist)
  - Body: `{foreignArtistId (MBID, required), artistName (required), monitorOption?, monitoring?:{monitored,useDefault,rules}, quality?, rootFolderPath?, qualityProfileId?, tagId?, releaseGroupMbid?, managedBy?: "aurral"|"lidarr"}`.
  - managedBy defaults to the active manager; asking for a non-active manager returns 409 library_manager_unavailable.
  - Returns 200 with the existing artist if it is already there.
- Album: `POST /api/library/albums/request` (addAlbum)
  - Body: `{albumMbid, albumName, artistMbid, artistName, triggerSearch?, managedBy?}`.
  - Alternatively `POST /api/library/albums` with `{artistId, releaseGroupMbid, albumName, managedBy?}` (all three required).
- Lidarr-only album routes:
  - `POST /api/library/downloads/album` with `{albumId}` (Lidarr album id) monitors the album and searches if searchOnAdd is on.
  - `POST /api/library/downloads/album/search` with `{albumId}` forces an AlbumSearch.
- Single track: `POST /api/library/downloads/track` (addAlbum)
  - Body: `{artistName*, trackName*, albumName?, artistMbid?, albumMbid?, releaseMbid?, trackMbid?, releaseYear?, durationMs?, trackNumber?, discNumber?, albumTrackCount?, albumTrackTitles?[], canonicalTrackId?}`.
  - It uses **Aurral's own downloader** (slskd/Usenet/Tidarr), not Lidarr.
  - Returns 202 `{success, queued, jobId,...}`, or 200 `{alreadyOwned:true}`.
- Lidarr is optional since 2.11; Aurral can manage its own library.
- To get MBIDs for chart or editorial Deezer tracks, call `GET /api/discover/editorial/links?artist=&album=&albumId=<deezerAlbumId>`. It returns `{artistMbid, albumMbid}` (requireAuth).
- Status: `GET /api/library/downloads`, `/downloads/status?albumIds=`, `/downloads/active`, `/downloads/status/all`.

## Discover Playlists (extra scope)
In 2.11+ "Discover Playlists" are **Deezer editorial playlists**. They replaced the generated Discover mixes from 2.10 (2.10 had `GET /api/discover/playlists/:presetId/previews` and `/artwork/:presetId`; those routes are gone in 2.13). The owner's version and latest are the same.

**List:** `GET /api/discover/editorial` (requireAuth) returns `{forYou: [summary], genres: [{id, name, playlists:[summary ×8]}]}`.
- summary = `{id (Deezer playlist id), name, description, trackCount, artworkUrl, curator}`.
- The genres are Popular(0) and the 9 above.
- "For you" comes from a Deezer playlist search over the user's topGenres/topTags (up to 12).
- The shelf is cached 24h (15 min when only part of it loaded).

**Tracks:** `GET /api/discover/editorial/:playlistId` (requireAuth) returns:
- `{id, name, description, curator, artworkUrl, tracks[], libraryPlaylistId|null}`
- track = `{artistName, trackName, albumName, durationMs, preview_url ("/api/deezer/preview/<id>.mp3"), artworkUrl, deezerAlbumId}`
- **There are no MBIDs**; resolve them with /editorial/links.
- Up to 2000 tracks, deduped.

**Add it:** `POST /api/discover/editorial/:playlistId/library` (requireAuth plus **accessFlow**). This makes a **synced static playlist**, not a Flow:
- Provider "deezer-playlist", syncEnabled, re-synced every 24h, keepRemovedTracks.
- It queues downloads for every track through Aurral's downloader, reusing tracks the Library already has.
- It generates artwork, MBID-enriches the tracks, and calls requestPlaylistSync, which **publishes the playlist to Navidrome** (NavidromePlaybackDestination).
- Returns `{playlistId, name, alreadyAdded:false, tracksQueued}`, or `{alreadyAdded:true, playlistId, name}` if it was already added.
- Manual re-sync: `POST /api/playlists/shared-playlists/:playlistId/sync`.
- Status: `GET /api/playlists/status` and `GET /api/playlists/jobs/:playlistId`.

**Add tracks to an existing playlist:** `POST /api/playlists/shared-playlists/:playlistId/tracks` (accessFlow) with body `{tracks:[{artistName, trackName, albumName?, artistMbid?, ...}]}`. This queues downloads.

**Flows (rule-based, a different thing):**
- `GET /api/playlists/flow-templates` (accessFlow) returns `{templates:[{id, name, description, available}]}`.
  - Template ids: discover-weekly, trending-mix, library-blend, focus-listening-history, release-radar. These are the old Discover mixes.
- `POST /api/playlists/flows` (accessFlow) with body `{templateId?, name?, mix?:{discover,mix,trending,focus,newReleases}, size?, deepDive?, recentListening?, recordHistory?, autoDownload?, yearFrom?, yearTo?, tags?[], excludeTags?[], relatedArtists?[], scheduleDays?[], scheduleTime?}`.
  - Template defaults: size 20, Friday 00:00.
  - Behaviour: it creates the flow, generates artwork and syncs it to Navidrome. autoDownload defaults to true when a download source is configured. **It does not run immediately.**
- `POST /api/playlists/start/:flowId` with body `{limit?}` runs a flow now.
- `POST /api/playlists/flows/:flowId/download` downloads saved picks when autoDownload is off.
- **There is no route that turns a Deezer editorial playlist into a Flow, or appends it to one.** Flows are generated from rules and do not take a fixed track list.
- The songs chart's "Save as playlist" uses the same editorial add, with `songs.playlistId` as the Deezer playlist id; `libraryPlaylistId` shows whether it has already been saved.

## f. UI sections (Discover home)
- Discover home (lib/discoverLayout.ts) section ids, in order: recentlyAdded, playlists, recommendedShows, recentReleases, news, recommended, globalTop, genreSections.
- The matching titles are:
  - "Recently added"
  - "Playlists"
  - "Shows near you"
  - "Recent & upcoming releases"
  - "Artist news"
  - "Recommended"
  - "Trending artists"
  - genre sections
- Related screens: "Customize Discover" modal, Trending page, Recommended page (For you / All), Discover Playlists page ("For you" plus genre shelves).

## h. Keys, limits, caching
- No Last.fm key is needed since 2.11. Last.fm, ListenBrainz and Koito are optional per-user history sources.
- Deezer and Apple RSS are keyless, and BrainzMash is Aurral-hosted.
- Deezer client limiter: about 110 ms between calls. Deezer quota (code 4 or HTTP 429) surfaces as 429 DEEZER_RATE_LIMITED; other failures surface as 502 DEEZER_UNAVAILABLE.
- Apple requests retry 3× on 502/503/504.
- The app rate-limits only the sign-in routes.
- Caching: trending is served from SQLite (5h freshness); /api/discover is private, no-cache; similar is cached 300s; artist preview 60s.

## Gaps and public fallbacks (each verified with one GET)
- Gap: no country parameter; the server geo-IP decides. If the owner's server egresses outside AU, the charts will not be AU.
  - Fallback 1: Deezer playlist **1313616925** "Top Australia": `https://api.deezer.com/playlist/1313616925/tracks`. The tracks have `preview`, which is a signed URL that expires about 15 minutes after it is issued.
  - Fallback 2: Apple `https://rss.applemarketingtools.com/api/v2/au/music/most-played/100/songs.json` (this redirects to rss.marketingtools.apple.com). Results are `{artistName, id, name, releaseDate, kind, artistId, artistUrl, artworkUrl100, genres[{genreId,name}], url}` with **no preview**. albums.json has the same shape.
- Gap: Apple chart items have no preview.
  - Fallback: iTunes Search `https://itunes.apple.com/search?term=<q>&entity=song&country=au&limit=1` returns `previewUrl` (an aac .m4a on audio-ssl.itunes.apple.com that is directly playable), plus `trackId`, `trackTimeMillis`, `artworkUrl100`.
- Gap: Deezer `/chart/{genre}/tracks` has no country parameter; it is geo-IP or global (verified: it returns the preview field).
- Gap: there are no MBIDs on chart or editorial tracks, and there is no catalog track search. Resolve through /api/discover/editorial/links, or do the lookup in Magpie.
- Gap: nothing turns an editorial playlist into a Flow. Use a synced static playlist via /editorial/:id/library, or append with /shared-playlists/:id/tracks.
