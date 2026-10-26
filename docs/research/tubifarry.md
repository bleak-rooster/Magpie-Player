# Tubifarry (Lidarr plugin) — research notes

Researched 2026-10-26. Sources: shallow clones of `TypNull/Tubifarry` `master` (a8ab7d7, 2026-06-13) and `develop` (5d205f4, 2026-10-14); GitHub API (releases, issues, commits); Lidarr repo (`master`/`plugins` branches, release notes); a light web/Reddit search.

**Important:** all releases since mid-2026 are cut from **`develop`** (v2.3.0.2, 2026-10-14, marked pre-release; v2.3.0.1, 2026-10-12, stable). `master` lags by about 4 months. The README in both branches is stale. It still describes a "Spotify catalog" indexer that develop now hides, and it leaves out Streamrip, Invidious, Beets and ReplayGain. The GitHub wiki is empty. Everything below comes from the **develop source** unless marked otherwise.

Legend: **[code]** = read in source. **[api]** = checked against the Lidarr source. **[unverified]** = inferred, or from memory or community reports. Test it against a live instance.

---

## 1. Feature list

### Indexers + download clients (Settings → Indexers / Download Clients) [code]

| Display name (`implementationName`) | Indexer `implementation` | Client `implementation` | `protocol` string | What it is |
|---|---|---|---|---|
| Slskd | `SlskdIndexer` | `SlskdClient` | `SoulseekDownloadProtocol` | Soulseek through a user-run slskd. Many search strategies: base, templates, volume/roman-numeral variants, self-titled, VA, "Partial Album", artist alias, **"Track Fallback"** (searches by the most distinctive track name), per-user grab limits. API key optional since 2.3. |
| Youtube | `YouTubeIndexer` | `YoutubeClient` | `YoutubeDownloadProtocol` | YouTube Music album search, downloaded per track. Output is AAC/M4A (128k, or 256k with Premium cookies), with optional FFmpeg re-encode, SponsorBlock trimming and cookies + PO-token "Trusted Session Generator" (bgutil) against bot detection. |
| Invidious | `InvidiousIndexer` | `InvidiousClient` | `YoutubeDownloadProtocol` | YouTube via Invidious instances (new on develop). |
| Streamrip | `StreamripIndexer` | `StreamripClient` | `StreamripDownloadProtocol` | Wraps the Python `streamrip` tool through a uv-managed Python worker. Sources: **Qobuz, Deezer (ARL), Tidal (device login), SoundCloud**. Up to FLAC 24/192. Needs the user's own paid accounts. New in 2.3.0.1. |
| Lucida | `LucidaIndexer` | `LucidaClient` | `LucidaDownloadProtocol` | Third-party rip site (fronts Qobuz/Tidal/Deezer/Amazon, etc.). Uptime depends on that site. |
| SubSonic | `SubSonicIndexer` | `SubSonicClient` | `SubSonicDownloadProtocol` | Any Subsonic-API server as a source. |
| DABMusic | `DABMusicIndexer` | `DABMusicClient` | `QobuzDownloadProtocol` | **Hidden** from the schema on develop because it no longer works. |
| T2Tunes | `TripleTripleIndexer` | `TripleTripleClient` | `AmazonMusicDownloadProtocol` | Amazon Music rip service. **Hidden** on develop. |
| Tubifarry | `TubifarryIndexer` | (uses Youtube client) | `YoutubeDownloadProtocol` | The original "Spotify catalog → YouTube" indexer. **Hidden** on develop. |

On startup the plugin adds every Tubifarry protocol to all Delay Profiles as *allowed* (`Plugin.CheckDelayProfiles`).

### Metadata sources ("proxies", Settings → Metadata) [code]
These replace Lidarr's `IProvideArtistInfo`, `IProvideAlbumInfo`, `ISearchForNewArtist`, `ISearchForNewAlbum` and `ISearchForNewEntity`. That means they change what **`/api/v1/search`, `/api/v1/artist/lookup` and `/api/v1/album/lookup`** return.

| Name | `implementation` | Notes |
|---|---|---|
| Lidarr Default | `SkyHookMetadataProxy` | Stock api.lidarr.audio (MusicBrainz-based). |
| Lidarr Custom | `CustomLidarrMetadataProxy` | Points to an alternative MusicBrainz-compatible metadata server (placeholder `https://api.musicinfo.pro`). Warns "could void your Servarr support". |
| Deezer | `DeezerMetadataProxy` | IDs look like `12345@deezer`. |
| Discogs | `DiscogsMetadataProxy` | Needs a token. IDs look like `a123@discogs`, `m…@discogs`, `r…@discogs`. |
| Last.fm | `LastfmMetadataProxy` | Needs an API key. IDs look like `artist::album@lastfm`. |
| MetaMix | `MixedMetadataProxy` | Merges sources by priority and threshold. |
| Similar Artists (Last.fm) | `SimilarArtistsProxy` | Search with the `~Artist`, `~<mbid>` or `similar:Artist` prefix to get similar artists. Needs MetaMix + Lidarr Default enabled. |

There is **no direct MusicBrainz proxy**. MusicBrainz data still arrives through Lidarr Default or Lidarr Custom.

### Other metadata consumers / tasks (Settings → Metadata) [code]
- **Lyrics Enhancer** (`LyricsEnhancer`). Providers: LRCLIB, Genius, Binimum, LyricsPlus, Unison and NetEase. Writes LRC/ELRC/TTML/Lyricsfile/TXT sidecars and/or embeds lyrics. Supports word-synced lyrics. Refreshes on a schedule. Command: `LyricsUpdateCommand`.
- **Codec Tinker** (`AudioConverter`). Converts formats with FFmpeg on import, using rules like `wav->flac` or `AAC>=256k->MP3:300k`, plus per-artist tags.
- **Search Sniper** (`SearchSniperTask`). Searches a few random wanted, missing or cutoff-unmet albums each interval and pauses when the queue gets long. Command: `SearchSniperCommand`.
- **FFmpeg** (`FFmpegMetadata`) and **Beets** (`BeetsMetadata`, retag/sync, `BeetsSyncCommand`). Both new on develop.

### Connections (Settings → Connect, `/api/v1/notification`) [code]
- **Queue Cleaner** (`QueueCleaner`). On a failed import it can rename from tags, fill missing tags, retag with beets, retry the import, remove and/or blocklist, and re-search. Trigger: "When Missing Tracks", "When Album Info Incomplete" or "Always".
- **Playlist Export** (`PlaylistExportNotification`). Exports import-list playlists, such as ListenBrainz or Spotify playlists, as playlist files.
- **ReplayGain** (`ReplayGainNotification`, runs rsgain), **FlareSolverr** (`FlareSolverrNotification`), **YouTube Proxy** (`YouTubeProxyNotification`).

### Import lists (`/api/v1/importlist`) [code]
`ArrSoundtrackImport` (soundtracks from Sonarr/Radarr), `LastFmRecommend`, `SpotifyUserPlaylistImport`, and four ListenBrainz lists: `ListenBrainzCFRecommendationsImportList`, `ListenBrainzCreatedForPlaylistImportList` (Weekly Jams/Exploration), `ListenBrainzPlaylistImportList` and `ListenBrainzUserStatsImportList`.

### Telemetry [code]
Builds that are not from master (that is, **all current develop releases**) start Sentry error reporting when a DSN is baked in, with `SendDefaultPii = false`. Users who care about privacy should know this.

---

## 2. Single-track downloads / faster first song

**Short answer: no true single-track grab exists.** This is a Lidarr limit, not a Tubifarry one. Lidarr's search, grab, queue and import pipeline works on albums: indexers get `AlbumSearchCriteria` or `ArtistSearchCriteria`, and there is no track search criteria. Tubifarry follows the same model [code]:

- **YouTube client** resolves the YT Music *album*, then downloads its tracks **one after another** (`ProcessAlbumAsync` → per-track request, awaited each time). Track 1 reaches the download folder early, but Lidarr imports only when the whole item completes.
- **Slskd "Track Fallback"** only changes the *search query*: it searches by the album's most distinctive track name. The grab is still the whole matching folder or release.
- **Lucida / T2Tunes** check `isSingle`: if the wanted release's minimum `TrackCount == 1`, they return a track result. **Streamrip** works on albums.

**Practical approach for "get me this song fast":**
1. Look up the recording's release groups in MusicBrainz (or ListenBrainz metadata). If a **Single or EP** release group contains the track, add or monitor *that* album in Lidarr (`PUT /api/v1/album/monitor`, then `POST /api/v1/command {name:"AlbumSearch", albumIds:[…]}`). Per-track sources (YouTube, Streamrip, Lucida, slskd) find singles far more reliably than Usenet or torrents do. This is the biggest practical gain from Tubifarry.
2. Otherwise grab the full album. With YouTube, 1-track singles finish in seconds. A 12-track album takes about as long as 12 sequential downloads plus random anti-bot delays (Delay Min/Max settings).

**Partial-album import** [unverified, based on how Lidarr's import works]: Lidarr matches the downloaded folder against a release. Missing tracks add distance, so a heavily incomplete folder is rejected with "Album match is not close enough" and sits in the queue as `importPending`/`importBlocked`. Your options:
- Tubifarry's Queue Cleaner can retag, retry, blocklist or re-search, but it cannot accept a partial import on its own.
- The client can call `GET /api/v1/manualimport?downloadId=…`, then `POST /api/v1/command {name:"ManualImport", files:[…], importMode:"auto"}` to force-import whatever tracks exist. This works in plain Lidarr too.
- Lidarr imports partial albums cleanly when the user picks a release in Lidarr that matches what was downloaded.

---

## 3. Detecting Tubifarry and its configuration through Lidarr's API [api]+[code]

Plugin support is in **mainline Lidarr since v3.1.2.4938 (2026-03-30)**. "New: Plugin support" appears in that release's notes, and `PluginController` exists on `master`. The separate `plugins` branch is no longer required (it is 4 commits ahead and 63 behind master).

1. **Plugin installed:** `GET /api/v1/system/plugins` returns a list of `{ name, owner, githubUrl, installedVersion, availableVersion, updateAvailable }`. Check for `name == "Tubifarry"` (case-insensitive) or `githubUrl` containing `TypNull/Tubifarry`. On pre-plugin Lidarr (< 3.1.2) this endpoint returns 404, which itself means "plain Lidarr". Compare `installedVersion` with the feature set you need (Streamrip needs ≥ 2.3.0.1).
   - Also read `GET /api/v1/system/status` → `version` to gate on Lidarr ≥ 3.1.6 (the current Tubifarry minimum).
2. **Configured indexers:** `GET /api/v1/indexer` returns `[{ id, name, implementation, implementationName, protocol, enableRss, enableAutomaticSearch, enableInteractiveSearch, supportsSearch, priority, fields[] }]`.
   - Tubifarry sources: `implementation ∈ {SlskdIndexer, YouTubeIndexer, InvidiousIndexer, StreamripIndexer, LucidaIndexer, SubSonicIndexer, DABMusicIndexer, TripleTripleIndexer, TubifarryIndexer}`, or `protocol` ending in `DownloadProtocol` other than `UsenetDownloadProtocol`/`TorrentDownloadProtocol`.
   - Treat an indexer as usable when `enableAutomaticSearch || enableInteractiveSearch`.
   - For Streamrip, read `fields[name=="source"].value` to see whether it uses Qobuz, Deezer, Tidal or SoundCloud. The field name is presumably the camel-cased property; confirm by inspecting a live response.
3. **Configured download clients:** `GET /api/v1/downloadclient` returns `[{ implementation, implementationName, protocol, enable, … }]`. Look for `implementation ∈ {SlskdClient, YoutubeClient, InvidiousClient, StreamripClient, LucidaClient, SubSonicClient, …}` with `enable == true`. A source only works if **both** an indexer and a client exist for the same `protocol`.
4. **Metadata, lyrics, sniper, codec:** `GET /api/v1/metadata` returns `[{ implementation, name, enable, fields[] }]`. Check these implementations: `LyricsEnhancer`, `AudioConverter`, `SearchSniperTask`, `DeezerMetadataProxy`, `DiscogsMetadataProxy`, `LastfmMetadataProxy`, `MixedMetadataProxy`, `SkyHookMetadataProxy`, `CustomLidarrMetadataProxy`, `SimilarArtistsProxy`, `BeetsMetadata` and `FFmpegMetadata`. Use `enable` to tell whether each is active.
5. **Connections:** `GET /api/v1/notification` → `implementation ∈ {QueueCleaner, PlaylistExportNotification, ReplayGainNotification, FlareSolverrNotification, YouTubeProxyNotification}`.
6. **Import lists:** `GET /api/v1/importlist` → `implementation` starting with `ListenBrainz…`, or `LastFmRecommend`, `ArrSoundtrackImport`, `SpotifyUserPlaylistImport`.
7. **Do not rely on schema endpoints for detection.** Tubifarry adds middleware (`HiddenProviderStartupFilter`) that **removes** DABMusic, T2Tunes and the Tubifarry indexer/clients from `GET /api/v1/indexer/schema` and `/api/v1/downloadclient/schema`. Those schemas show what *can* be added (for example `YouTubeIndexer`), not what is configured.
8. Auth: all of these use the `X-Api-Key` header. Reading `/system/plugins` and settings needs the admin API key. In this architecture the user supplies that key.

Suggested capability flags: `tubifarry.installed`, `.version`, `.sources = {youtube, slskd, streamrip:<service>, lucida, subsonic}`, `.lyrics`, `.similarArtists`, `.queueCleaner`, `.searchSniper`, `.metadataSource = musicbrainz|deezer|discogs|mixed`.

---

## 4. Previews and search

- **No preview URLs through the Lidarr API.** Deezer's records include `preview` (a 30-second MP3 URL) [code: `DeezerRecords.cs`], but `DeezerMappingHelper` does not map it, and Lidarr's Track/Album models have no field for it.
- What you *do* get with the Deezer proxy active: album `links` include `{name:"Deezer", url:"https://www.deezer.com/album/…"}` and a `upc:` link, artist IDs look like `NNN@deezer`, and you get Deezer cover art in `images`/`remoteCover`. A native client could take the Deezer album ID from the link and call Deezer's public API (`api.deezer.com/album/{id}/tracks` → `preview`). That breaks the "only Navidrome, Lidarr and ListenBrainz" rule, and Deezer's API has no CORS for the web build. See `listenbrainz-discovery-previews.md` for alternatives.
- **Richer search through Lidarr:** with Deezer, Discogs or MetaMix enabled, `/api/v1/search?term=` and `/api/v1/album/lookup` return results from those catalogs. This is often faster and broader than MusicBrainz-only, and covers material missing from MusicBrainz. Similar-artist discovery works through `GET /api/v1/search?term=~Radiohead` (needs Similar Artists + MetaMix + Lidarr Default) [code; response shape unverified].
- **Caveat:** artists or albums added from a non-MusicBrainz source get non-MBID `foreignArtistId`/`foreignAlbumId` values (`…@deezer`). Your app's MBID joins between Navidrome, ListenBrainz and Lidarr break for those items. Prefer the MusicBrainz-backed source (Lidarr Default or Custom) for requests your app creates, and treat `@` IDs as non-MBIDs.

---

## 5. Install, requirements, stability, legal

- **Install:** in Lidarr go to **System → Plugins**, paste `https://github.com/TypNull/Tubifarry` (stable track), or `Tubifarry@TypNull#develop` as the release notes say, then click Install and restart Lidarr. Plugins are built into **mainline Lidarr ≥ 3.1.2**. Older guides say to switch Lidarr to the `plugins` branch or use hotio's `pr-plugins` image; that is no longer needed. Current Tubifarry requires **Lidarr ≥ 3.1.6.0** (v3.1.6.5079 shipped 2026-10-26). Built for net8.0. Docker users: YouTube needs FFmpeg (auto-downloaded) and optionally Node or bgutil for PO tokens. Streamrip installs its own Python through uv.
- **Maintenance:** active. 1,071 stars, last push 2026-10-14, a release every 1–4 weeks (2.1.1.1 Jul → 2.3.0.2 Oct 2026), and only 3 open issues. One of them is #222, "Fix Lidarr 3.1.5 compatibility". The plugin is tied to Lidarr internals, so **Lidarr updates can break it** until Tubifarry ships a fix; that has happened before. Essentially one maintainer (TypNull/Meyn), so the bus factor is 1.
- **Stability [community, unverified]:** Reddit reports are mixed. Slskd matching sometimes picks wrong or slow peers and needs tuning. YouTube needs cookies and PO tokens or it hits bot blocks. Lucida, DAB and T2Tunes come and go, and two are already hidden. The README itself warns "Some details in this documentation may vary from the current implementation."
- **Legal:** MIT-licensed code, but the *sources* are the issue. YouTube download breaks YouTube's ToS. Soulseek is P2P file sharing that usually involves copyrighted material and **uploads** (seeding) through slskd. Lucida, DAB and T2Tunes are piracy or rip services. Streamrip with Qobuz, Tidal or Deezer breaks those services' ToS and DRM terms even with a paid account. Lidarr's support policy treats plugin users as unsupported. **App Store risk:** an iOS/macOS app that advertises or automates "download from YouTube/Soulseek" can be rejected under guidelines 5.2.2/5.2.3 (third-party content and downloading from third-party services) [unverified, but plausible]. Keep the app source-agnostic: it only talks to the user's Lidarr, and Tubifarry should never be named as a download source in store copy.

---

## 6. App features possible only WITH Tubifarry vs plain Lidarr

| Feature | Plain Lidarr | With Tubifarry |
|---|---|---|
| Request album → it eventually arrives | Yes (Usenet/torrent indexers the user sets up separately) | Yes, plus YouTube, Soulseek, Streamrip and others. Much higher hit rate for obscure or new releases, and usually minutes instead of hours. |
| "Get this song fast" (request the single or EP) | Weak: singles are rare on Usenet and torrents | **Realistic**: YouTube, Streamrip and Lucida find 1-track releases quickly |
| Real-time per-track download progress | Queue progress per album | Same (album-level `/api/v1/queue`), but YouTube items fill track by track (only visible as a percentage) |
| Synced lyrics in the player (served by Navidrome from LRC sidecars or embedded tags) | No | **Yes**, through Lyrics Enhancer. Navidrome serves them through OpenSubsonic `getLyricsBySongId`. [Navidrome sidecar `.lrc` support: verify the version] |
| Similar-artist discovery through Lidarr search (`~artist`) | No | Yes (needs a Last.fm key). You can also do this with ListenBrainz directly. |
| Search results beyond MusicBrainz (Deezer/Discogs catalog, better art) | MusicBrainz only | Yes, but the IDs are not MBIDs |
| Auto-retry and cleanup of failed imports ("request never gets stuck") | Manual | Queue Cleaner + Search Sniper |
| Auto-adding ListenBrainz recommendations or playlists to Lidarr | Lidarr has a basic ListenBrainz list? [verify] | Four ListenBrainz import lists plus Playlist Export. The app can also do this itself. |
| Format normalization (e.g. everything → FLAC/Opus), ReplayGain | No | Codec Tinker, ReplayGain (rsgain) |
| 30-second previews | No | **No** (Tubifarry does not expose them either) |
| True single-track (not single-release) download | No | **No** |

**Recommendation for the app:** run detection once at setup and refresh it occasionally (§3), then use it to:
(a) show an "instant" or "song request" path that targets single or EP releases when a fast source (YouTube, Streamrip, Lucida, slskd) is enabled.
(b) show expected-wait wording ("minutes" vs "may take hours or days").
(c) turn on a lyrics UI hint and similar-artist surfaces.
(d) offer a "force import what we got" action through the manualimport API in both modes.
Keep previews and similar artists on ListenBrainz so both modes behave the same.
