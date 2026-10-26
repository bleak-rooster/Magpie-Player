# Apple-platform Navidrome/Subsonic clients: research report

Research date: 2026-10-26. Sources: App Store listings, navidrome.org/apps, GitHub repos and issues, Lemmy/PieFed threads (Reddit mirrors were mostly not reachable), developer docs. **Three open-source Swift codebases were cloned and read**: Amperfy, Minidisc and Cassette (Minidisc is a fork of Cassette).

> **Verification legend**: unmarked = verified from source code or official listing. **[listing]** = taken from the App Store or developer marketing copy and not checked independently. **[unverified]** = conflicting or missing evidence.

---

## 1. Identifying the apps

| Name in brief | Actual app | Status |
|---|---|---|
| Arpeggi | **Arpeggi** by Reilly Wilkinson, App Store id6503619183 (it was TestFlight-only before) | Found. Closed source. |
| Narjo | **Narjo – Music Player** by Arturo Yumpo, id6748359006 | Found. Closed source. |
| Minidisc | **Minidisc** by Bruno Durand (GitHub `Loriage/Minidisc`), App Store id6794636813 | Found. **Open source, MPL-2.0**, fork of Cassette. |
| Navibeat | **NaviBeat** by Nenad Jokic, id6763518834, navibeat.app | Found. Closed source. |
| Amperfy | `BLeeEZ/amperfy`, id1530145038 | Found. GPL-3. Code read in depth. |
| play:Sub | play:Sub Music Streamer by Michael Hansen, id955329386 | Found. Closed source. |
| substreamer | Substreamer by Gaven Henry, `ghenry22/substreamer` | Found. GPL-3. |
| Symfonium | **Android only.** It has no iOS version. It is the feature benchmark that users often name. | Found. Not an Apple client. |
| *(bonus)* Cassette | `CassetteLab/cassette`, MPL-2.0. iOS/macOS, CarPlay in progress (v2.0) | Found. Code read. |

The field is now crowded. navidrome.org/apps lists more than 30 iOS/macOS/tvOS clients, for example AmpSonic, Cadence, Dromify, Nautiline, Primuse, RoadSonic (CarPlay-first), Shelv (which also has a Docker web build), SubSonify, Sonora and Yuzic. Our differentiator cannot be "a native Navidrome client". It must be **Spotify-grade polish together with CarPlay, Lidarr and ListenBrainz-driven discovery**.

---

## 2. Comparison table

| | **Amperfy** | **Arpeggi** | **Narjo** | **Minidisc** | **NaviBeat** | **play:Sub** | **Substreamer** | **Cassette** |
|---|---|---|---|---|---|---|---|---|
| Platforms | iPhone, iPad, Mac (Catalyst), CarPlay | iPhone, iPad, Mac (M1+), CarPlay | iPhone, iPad, Mac, Watch, TV, CarPlay [listing] | iPhone only (iOS 26.1+) | iPhone, iPad, Mac, TV, Watch, Vision, CarPlay. Also Android, Windows and Linux | iPhone, iPad, Mac (M1+), CarPlay | iPhone, iPad, Mac, Watch, TV, Vision, CarPlay; Android | iOS/iPadOS 18+, macOS 15+; CarPlay in progress |
| Tech | Swift 6, **UIKit + SwiftUI** (settings), Core Data, Alamofire, **AudioStreaming (AVAudioEngine)** | **SwiftUI** [listing] | Native Swift [unverified framework] | Swift 6, **SwiftUI**, SwiftData, **AudioStreaming** (default) plus an AVQueuePlayer fallback | Native SwiftUI (Mac is "not Catalyst/Electron") [listing] | Native [unverified] | **React Native 0.88 + Expo 58**, `react-native-queue-player`, op-sqlite/drizzle | Swift 6, SwiftUI, SwiftData, AudioStreaming, SwiftSonic |
| Servers | Subsonic, Ampache | OpenSubsonic (Navidrome, Gonic) | Navidrome, Subsonic, **Jellyfin, Emby, Plex** | Subsonic/OpenSubsonic | Navidrome 0.50+, Airsonic-Adv, Gonic | Navidrome, Gonic, Ampache, Funkwhale… | Navidrome, Gonic, Nextcloud, Ampache… | Subsonic/OpenSubsonic |
| Gapless | Yes (except MP3: AudioStreaming leaves a small MP3 gap) | Yes (AAC/FLAC/ALAC/Opus) | Yes | Yes | Yes | Yes ("flawless" per reviews) | Yes | Yes |
| Crossfade | **No** (open request #652) | No [unverified] | Yes, plus **BPM-aware "AutoMix"** | Yes (two-deck, equal-power) | Yes | Yes | Yes | Sequential fade only (fade out, then fade in) |
| Transcoding | Per network (Wi-Fi/cell): raw / mp3 / server default, plus maxBitRate. Separate cache format | MP3/Opus | Separate stream and download quality | Per network. "Original" = `format=raw` | Opus/AAC/MP3 tiers plus passthrough | "Granular" | Yes | Yes |
| Offline | Yes: background URLSession, cache limit, auto-cache | Background multi-file downloads | Yes, with re-sync on reconnect | Durable downloads plus a bounded LRU auto-cache | LRU cache plus "pins", offline metadata | Download/cache with **Auto Sync** | Yes | Yes |
| Queue prefetch | Next **3** songs pre-downloaded. Next stream queued **10 s** before the end | ? | ? | Preload next track. Cache fill starts after 30 s of listening | ? | Auto-cache | Yes | Yes |
| CarPlay | Yes: 4 tabs (Home/Library/Cached/Playlists) | Yes (some freeze reports) | Yes, with ratings/favourites | **No** (iOS-only phone UI). Cassette has it | Yes, with **voice search** | Yes, with server switching | Yes | v2.0 WIP: Home/Recents/Library/Search |
| Lyrics | OpenSubsonic `getLyricsBySongId` | ? | Synced: server, embedded, LRC, **LRCLIB**, translation | Yes plus LRCLIB fallback | Synced and plain | ? | ? | Yes |
| Radio/mixes | Random, similar songs (`getSimilarSongs2`), internet radio | Song/Artist **Stations**, continuous queue | Smart playlists, AudioMuse-AI | **ListenBrainz recs**, AudioMuse-AI mood playlists, "Wrapped" | Smart playlists, internet radio, stats | Auto DJ, artist radio | "Tuned In" smart mixes, analytics | ListenBrainz fresh releases |
| Scrobbling | Subsonic `scrobble` (offline queue, 50%/4 min rule) | Local cache, then server | Yes | **ListenBrainz direct** | Via server (Last.fm/LB) | **Last.fm** (incl. cached plays) | Yes, offline-synced | ListenBrainz |
| Lidarr | No | No | Optional integration [listing] | **Built in** (add artist, interactive search, queue, manual import) | No | No | No | No |
| Jellyfin | No (open #173) | No | **Yes** | No | No | No | No | No |
| Price | Free | Free | Free with IAP: $1.99/mo or **$29.99 lifetime**, 7-day trial | Free (sideload IPA / App Store) | **$5.99 one-time universal** (+$3.99/$4.99 add-ons) | **$4.99** + tips | Free | Free |
| Rating | n/a | **4.9 (105)** | 4.2 (37) | ~4 | 4.5 (34) | 4.5 (432) | 4.0 (144) | TestFlight |

---

## 3. Per-app notes

### Amperfy (open source, studied in depth; see §4)
- The most established open-source iOS client (1.8k stars). Users praise it for "rock-solid playback, gapless works flawlessly, CarPlay, EQ, ReplayGain" (from issue #652).
- Complaints: CarPlay UI got slower after an overhaul (#647: selection jumps while browsing, freezes on iOS 27 #857). Some CarPlay playlists are missing (#779, #764). Transcoding is fragile (#672: server-default Opus/AAC will not play, progress bar is missing, cache downloads the original instead of the transcode). Songs restart from the beginning when the stream length is unknown (#305). Storage overhead from full-size duplicated artwork (#318).
- **Project-health risk:** the maintainer said in #850 (2026) that he is "not sure how to proceed with Amperfy in the long term", and contributors are forking. Do not depend on it as a library.

### Arpeggi (closed, SwiftUI)
- Positioned as "the same clean aesthetic as Apple's apps". Customisable home screen and player view. **Continuous playback** means that tapping a song while browsing does not wipe your queue, and users single this out. Song/Artist Stations. Server play-queue sync (manual button). Playlist editing.
- Praise: the cleanest UI. Lemmy users call it "favourite after trying dozens".
- Complaints: CarPlay freezing, library-based queue limitations, early search scroll bugs. A TestFlight-era user also worried about the business model ("may charge later") and a stray location-permission prompt.
- App Store version metadata conflicts: one source gives "1.5.4, Oct 2024" and another says "released Apr 2026". **[unverified]** which is current.

### Narjo (closed; the most feature-dense)
- Multi-backend (Navidrome/Subsonic/Jellyfin/Emby/Plex). Lossless, gapless, crossfade, BPM-aware AutoMix, ReplayGain, 10-band EQ with 18 presets. Separate stream and download quality. Synced lyrics from several sources with on-device translation. Animated WebP/video artwork on the lock screen. Casting to AirPlay, Sonos and UPnP/DLNA (DSD passthrough). Apple Watch with Digital Crown. Widgets, Siri/Shortcuts. mTLS, custom headers, and **automatic home/remote URL switching**.
- Integrations: AudioMuse-AI, **Lidarr**, Bandcamp, SoulSync and others. **[listing]**: the depth of these integrations was not verified.
- Praise: the developer is attentive and fixes bugs fast, with a clean iOS and CarPlay UI. Complaint: slow UPnP device discovery.

### Minidisc (open source, MPL-2.0; the closest analogue to our plan)
- An opinionated, iOS-only Apple Music clone (Liquid Glass, tab bar plus mini-player, Home shelves). It combines **ListenBrainz scrobbling and recommendations, a full Lidarr UI, AudioMuse-AI mood playlists and a yearly "Wrapped"**. Per-network streaming quality, LRCLIB lyric fallback, custom headers for Cloudflare Access/Authelia, Keychain credentials.
- **It has no CarPlay** (the parent Cassette is adding it).
- Its `docs/AudioStreamingEvaluation.md` (in French) is the best engineering write-up on iOS Subsonic playback that we found. §5 summarises it.

### NaviBeat (closed; the broadest Apple-platform coverage)
- One $5.99 universal purchase covers iPhone, iPad, Mac, **tvOS**, Watch (offline pinned playback) and Vision Pro, plus Android, Windows and Linux. Gapless, crossfade, EQ, track/album ReplayGain, Opus/AAC/MP3 tiers, internet radio, classical work/movement grouping, smart playlists, listening-stats heatmaps. **Cross-device resume, which pauses the originating device**. CarPlay voice search in 12 languages. Tailscale, mTLS and Cloudflare/Authelia headers. LRU cache plus "pins". RockBox sync add-on.
- Praise: the Watch and tvOS apps, reliability, a responsive developer.

### play:Sub (closed, paid)
- The long-standing default recommendation ("everyone I know on iPhone uses play:sub"). Hi-res up to 24/192, gapless, crossfade, Auto DJ, artist radio, EQ, speed, podcasts and audiobooks, 20k internet radio stations, Last.fm. **Auto Sync** for automated downloads (Oct 2026). CarPlay with queue control and server switching.
- Complaint: the UI could be cleaner and looks dated next to the newer SwiftUI clients.

### Substreamer (open source, React Native/Expo)
- The most feature-rich free option. "Tuned In" smart mixes from listening history, analytics, fuzzy and voice search, offline-synced scrobbles, many platforms.
- Complaints: complex UI for non-technical users, slow playlist generation.
- Proof that cross-platform RN can ship CarPlay (`react-native-queue-player` plus a CarPlay config plugin). For us it is a counter-example on polish.

### Symfonium (Android only)
- Users name it as the gold standard and wish it existed on iOS: a multi-source aggregator, up to 256-band EQ/AutoEQ, gapless, Android Auto, deep customisation, and a strong caching and transcoding model. Its support forum documents Navidrome pitfalls that we should learn from. For example, seeking a transcoded MP3 restarts at 0 unless `timeOffset` is used.

---

## 4. Amperfy source deep dive

Files are under `AmperfyKit/` and `Amperfy/` in the shallow clone at `scratchpad/amperfy`.

### 4.1 Playback engine and gapless (`AmperfyKit/Player/BackendAudioPlayer.swift`)
- **Not AVPlayer/AVQueuePlayer.** It uses [`dimitris-c/AudioStreaming`](https://github.com/dimitris-c/AudioStreaming), an **AVAudioEngine/AudioToolbox**-based streaming player (`AudioStreamingPlayer: AudioStreaming.AudioPlayer`).
- **Gapless mechanism:** a 1 s timer (`checkForPreloadNextPlayerItem`) asks for the next playable when **less than 10 s remain**. It then calls `player.queue(url:headers:)`, which appends the item to AudioStreaming's internal decode queue so frames run back-to-back. When the item finishes, `handleRequest` sees that `nextPreloadedPlayable == playable` and does nothing: the audio is already flowing.
- History (#96): the maintainer chose AudioStreaming after evaluating it and **would not write his own gapless engine**. A known limitation is that **MP3 still has a small gap** because of encoder delay/padding (AudioStreaming issue #38). Other formats are fine.
- Audio graph: `player.attach(nodes: [AVAudioUnitEQ(10 bands), AVAudioMixerNode (ReplayGain)])`. ReplayGain is applied as `pow(10, dB/20)` on the mixer `outputVolume`, multiplied by EQ volume compensation. An `AudioAnalyzer` tap on the EQ drives the visualiser.
- Lyrics timing uses a separate 0.1 s timer.
- Error handling: on `audioPlayerUnexpectedError` it **throws away and recreates the whole player and its nodes** (`restartPlayer`), then re-inserts the current playable once (`triggerReinsertPlayableCB`).
- MIME hints: it builds `AVURLAsset(... "AVURLAssetOutOfBandMIMETypeKey")` when the server content type is iOS-compatible. If the type is not playable on iOS and transcoding is off, it shows a "turn on transcoding" popup.

### 4.2 Streaming, caching and prefetch
- **No AVAssetResourceLoader and no tee-to-disk.** The stream and the cache are **two separate HTTP fetches**. While a song streams, `isAutoCachePlayedItems` also starts a **background URLSession download** of the same song (`getPlayableDownloaderCB(accountInfo).download(object:)`), which doubles bandwidth for that track.
- `PlayerDownloadPreparationHandler.preDownloadCount = 3`: on `didStartPlayingFromBeginning`, it pre-downloads the next 3 items (user queue first, then the context queue). Users asked for this explicitly in #719 because they wanted playback to survive network loss.
- Playback chooses its source in this order: preloaded item → **local cached file** (`fileManager.fileExits`) → stream (unless in offline mode).
- Cache limit: `settings.user.cacheLimit` (bytes). Downloads stop when it is exceeded. **There is no LRU eviction in the download path that we saw.** Minidisc and NaviBeat use LRU instead.

### 4.3 Transcoding URLs (`AmperfyKit/Api/Subsonic/SubsonicServerApi.swift`)
- Stream: `rest/stream.view?id=…&format={mp3|raw|<omit>}&maxBitRate=…`. The bitrate and format are chosen **per network type** (`StreamingMaxBitrates`, `StreamingTranscodings` with `.wifi` and `.cellular` values, read from `NetworkMonitor`).
- Cache download: `download.view` for raw files, otherwise `stream.view?format=mp3`. A separate setting, `cacheTranscodingFormatPreference`, controls this.
- **Pitfall (#672, #305):** with transcoding the server does not send Content-Length, so **duration is unknown**. The UI shows "--:--", there is no CarPlay scrubber, and the song can restart at the end of the buffer. Server-default Opus/AAC output also fails to play, because AudioStreaming has no Opus decoder and raw ADTS AAC is problematic. Use the metadata `duration` from the API as the authority. Add `estimateContentLength=true` to stream requests. Prefer formats the decoder supports. Use the OpenSubsonic `transcodeOffset` extension (`timeOffset=`) for seeking inside transcodes **[verify against the current Navidrome version]**.

### 4.4 Offline download management (`AmperfyKit/Download/*`, `MetaManager.swift`)
- Each account gets its own **`URLSessionConfiguration.background(withIdentifier: "<bundle>.<account>.PlayableDownloader.background")`** with `URLSessionDownloadTask`. Downloads are gated by an `OperationQueue` with `maxConcurrentOperationCount = parallelDownloadsCount`.
- Artwork uses a separate `.default` session with a validation callback (download once, never, or once per session).
- Persistent request queue in Core Data (`DownloadRequestManager`, `DownloadMO`). Downloads respect offline mode and network-change notifications.
- `didFinishDownloadingTo`: the file is moved **synchronously** to a temp file with a unique name (required, because iOS deletes it when the delegate returns). It then validates that the size is greater than 0 and finishes the request asynchronously.
- `urlSessionDidFinishEvents(forBackgroundURLSession:)` calls the stored AppDelegate completion handler.
- It deliberately **ignores `didWriteData` progress**, because writing progress to Core Data used too much CPU. Throttle progress UI accordingly.
- Custom HTTP headers (reverse-proxy auth) are applied per `URLRequest`.

### 4.5 CarPlay (`Amperfy/CarPlay/*`)
- Entitlement: `com.apple.developer.carplay-audio` (older README mentions `playable-content`, which is deprecated). Uses `CPTemplateApplicationSceneDelegate`.
- **Hierarchy:**
  - `CPTabBarTemplate` (capped with `.prefix(CPTabBarTemplate.maximumTabCount)`, which is **4 for audio apps**):
    - **Home** `CPListTemplate`, made of `CPListImageRowItem` "shelves" (recent albums, random, etc.). Tapping a shelf title pushes a detail list. Assistant cell `CPAssistantCellConfiguration(position: .top, visibility: .always, assistantAction: .playMedia)` for Siri "Play…".
    - **Library** `CPListTemplate`: an image-row of library types (Artists, Albums, Songs, Genres, Podcasts, Radios…), a "Play random" image row, quick actions (offline toggle, switch account) and the assistant cell.
    - **Cached** `CPListTemplate`: the same structure but only downloaded content (for offline drives).
    - **Playlists** `CPListTemplate`.
  - Drill-down: Artist → Albums → Songs (each a `CPListTemplate`). The first row in a list is "Shuffle", and `maxTreeDepth = 4`.
  - `CPNowPlayingTemplate.shared` with `CPNowPlayingRepeatButton`, `CPNowPlayingShuffleButton`, a favourite `CPNowPlayingImageButton` and `CPNowPlayingPlaybackRateButton` (podcasts). `isUpNextButtonEnabled = true` pushes a queue `CPListTemplate`. `isAlbumArtistButtonEnabled` pushes the album.
- **Limits are read from the API and never hardcoded:** `CPListTemplate.maximumItemCount` and `maximumSectionCount`. For alphabet-sectioned artist and album lists, it divides `maximumItemCount` across sections (`maximumItemCount / sections.count`) and uses `sectionIndexTitle` for letter jumping. Songs are capped at `maximumSectionCount - 2`.
- Lists are lazily populated in `CPInterfaceControllerDelegate.templateWillAppear`, from Core Data `NSFetchedResultsController`s. Artwork rows are refreshed when artwork downloads finish.
- **Pitfalls from issues:**
  - #647/#796: `controllerDidChangeContent` calls `updateSections` on the visible list while the user is browsing, because a sync or download saves to Core Data. **This makes rotary-knob and touch focus jump**, so the wrong item opens. *Lesson: never rebuild a visible CPListTemplate during background sync. Diff it, or defer until the template is not on top.*
  - #779/#764: lists are truncated ("only A–H"). The per-section division of `maximumItemCount` plus a partially synced library produces a silently short list.
  - #857: on iOS 27 the CarPlay UI freezes and the app exits. Suspected main-thread work during template build.
  - #764: songs that are not cached will not play from CarPlay (they do play from the phone). Network and auth from the CarPlay scene must be identical to the phone path.
  - Wishes: scrubbing on CarPlay (#762), skip ±15 s buttons (#614), lyrics on CarPlay (#547), format/bitrate shown (#542), artist overview (#589).

### 4.6 Now Playing and remote commands
- `RemoteCommandCenterHandler`: play, pause, toggle, stop, previous, next, `changeRepeatMode`, `changeShuffleMode`, skip back/forward with `preferredIntervals` (podcasts), `changePlaybackRate`, `changePlaybackPosition` (scrubbing), `ratingCommand` (0–5) and `likeCommand` (favourite, `isActive` reflects state).
- Commands are **enabled and disabled per content type**: songs have no skip-intervals, podcasts have no shuffle, radio has no seek.
- `NowPlayingInfoCenterHandler` sets the media type to audio, `ServiceIdentifier`, `IsCloudItem = !cached`, title/album/artist, duration, elapsed time, `IsLiveStream` for radio, default and current rate, and artwork. It sets `playbackState` explicitly (`.playing`, `.paused`, `.stopped`).
- `AudioSessionHandler`: `.playback` category. On interruption it resumes only when `.shouldResume` is set. On route change `.oldDeviceUnavailable` (headphones unplugged) it pauses.

### 4.7 Auth (`SubsonicServerApi.createAuthApiUrlComponent`)
- `u`, `v`, `c=Amperfy`. If the server API version is at least the token version: a fresh **16-char random salt per request** and `t = md5(password + salt)` in lowercase hex. Otherwise it falls back to legacy `p=` plaintext.
- Versions are negotiated with `ping`. The app also calls `getOpenSubsonicExtensions` to feature-gate (for example `songLyrics`).
- Logs are sanitised: `cleanse(url:)` replaces host, `u`, `p`, `t` and `s` before logging. **Copy this pattern.** Credentials appear in every stream URL, so they must never reach logs, crash reports or diagnostics.
- An extra `httpHeaders` dictionary on the credentials is added to API, stream and download requests (Cloudflare Access/Authelia style).
- Endpoints used: `getArtists`, `getArtist`, `getAlbum`, `getAlbumList2`, `getSong`, `search3`, `getPlaylists`/`getPlaylist`/`createPlaylist`/`updatePlaylist`, `getStarred2`, `star`/`unstar`, `setRating`, `getRandomSongs`, `getSimilarSongs2`, `getLyricsBySongId`, `getGenres`, `getPodcasts`, `getInternetRadioStations`, `scrobble`, `stream`, `download`, `getCoverArt`. Amperfy does **not** use `savePlayQueue`/`getPlayQueue` (#603 requests cross-device handoff).

### 4.8 Scrobbling (`ScrobbleSyncer.swift`)
- It counts *actual* listened time (excluding pauses and seeks) and submits at **50% of duration or 240 s, whichever comes first**, following the Last.fm/ListenBrainz convention. It sends a now-playing ping at start and a submission at end.
- Offline plays are stored as `ScrobbleEntryMO` in Core Data and uploaded later in the background.

---

## 5. Minidisc and Cassette engine findings (high-value lessons)

From `Minidisc/Services/Audio/*` and `docs/AudioStreamingEvaluation.md`:

1. **Two engines behind one `AudioEngine` protocol.** `AVPlayerEngine` and `AudioStreamingEngine` are swappable in `AppContainer` (`MINIDISC_AUDIO_ENGINE=avplayer`). PlayerService owns the queue, scrobbling and source resolution. The engine only plays. **We should copy this seam.**
2. **The AVPlayer design (1,471 lines)** uses **two `AVQueuePlayer` "decks"**. Sequential and gapless playback use the active deck's native queue (`insert(_:after:)` for the preloaded item). Crossfade starts the standby deck and ramps equal-power gains. **AirPlay forces sequential mode**, because two simultaneous players cannot be crossfaded over AirPlay. Positive ReplayGain needs an **`MTAudioProcessingTap`**, because `AVPlayer.volume` cannot exceed 1.0.
3. **AudioStreaming is now the default, with known caveats:**
   - Its URL path decodes to an internal **Float32 stereo 44.1 kHz** format, so 96/192 kHz sources are resampled. It is not bit-perfect.
   - `seek(to:)` gives no completion callback. Minidisc seeks muted and confirms with two advancing frame-count observations.
   - `removeFromQueue` and `playNextInQueue` do not affect entries that are already decoded, so editing a preloaded queue can cause a re-buffer.
   - Ogg Vorbis is supported but **Opus is not established**, and Ogg seeking is not supported.
   - Open bugs: FLAC seek drift (#133) and MP3 seek after pause (#126).
   - Cassette's settings: `bufferSizeInSeconds: 20`, `secondsRequiredToStartPlaying: 1`, `secondsRequiredToStartPlayingAfterBufferUnderrun: 1`, `flushQueueOnSeek: true`.
4. **Seeking in transcoded MP3:** Navidrome transcodes do not support HTTP Range, so Minidisc (`TranscodedSeekFile`) **downloads the complete transcode to a temp file** to make it seekable. A better fix is to stream with `timeOffset` (OpenSubsonic `transcodeOffset`).
5. **Cache policy:**
   - The auto-cache is a **bounded LRU** of compressed files, filled by a separate transfer **after 30 s of listening**. Durable downloads live in a separate store.
   - Cache transfers request `estimateContentLength=false` so they get real framing, while playback may use estimated length.
   - The cellular preference is set on the `URLRequest` (`allowsCellularAccess`), so it survives network handovers.
   - **Cache traffic is suspended near a track transition** to avoid competing with the preload.
   - A stalled remote stream can swap to a completed local copy at the same position.
6. **Robustness:**
   - Every load has a monotonic token, so late callbacks from previous items are rejected.
   - `AVError.mediaServicesWereReset` means the player objects must be rebuilt.
   - Bluetooth disconnects can leave an interruption without an "ended" notification, so a successful re-activation on Play must clear the stale interruption.
   - Re-apply the session category, mode and policy on every activation.
   - Prefer the decoder's parsed duration over catalogue duration, falling back to catalogue duration.
7. **Cassette CarPlay:**
   - It uses `CPSessionConfiguration` to detect `limitedUserInterfaces.contains(.keyboard)` while driving, and hides or disables Search instead of leaving a dead row.
   - `CPSearchTemplate` must not go directly into `CPTabBarTemplate`, because that "takes the whole root down". Wrap it in a list tab.
   - Artwork is resized to `CPListImageRowItem.maximumImageSize` (memory).
   - Image rows cap at about 8 elements, and the extras are dropped silently.

---

## 6. What users praise and what they wish for

**Praised:** gapless that "just works"; Apple-Music-like familiarity (tab bar, mini-player, shelves); continuous queue; offline pins; responsive solo developers; no accounts or tracking; one-time pricing; Watch and tvOS apps (NaviBeat); smart mixes (Substreamer "Tuned In").

**Complaints and wishes (recurring):**
1. **CarPlay reliability**: freezes, lists that jump during sync, truncated lists, cannot play non-cached songs, no scrubbing, no skip ±15 s, no lyrics, no artist overview.
2. **Transcoding correctness**: unknown duration, broken seek, Opus/AAC failures, cache ignoring the transcode setting (cellular data burn).
3. **Network continuity**: cache the next N songs and keep them when skipping. **Auto-switch between LAN and Tailscale/remote URL** (Amperfy #512; Narjo and NaviBeat already do this).
4. **Cross-device handoff**: `savePlayQueue`/`getPlayQueue` (Amperfy #603; Arpeggi and NaviBeat have it).
5. **Crossfade** and Spotify-style **radio / similar tracks / daily mixes**.
6. OpenSubsonic **multi-artist** fields (`artists`, `albumArtists`), more sort options, client certificates (mTLS), custom headers.
7. Storage hygiene: artwork stored at full size twice (Amperfy #318). Show the true app size.
8. An Apple TV app (Amperfy #477, 6 votes) and Jellyfin support (#173).
9. Something like "Symfonium for iOS": deep customisation together with a polished default.

---

## 7. Concrete iOS implementation recommendations

### Audio engine
- **Define an `AudioEngine` protocol** (play/queueNext/seek async→Bool/pause/crossfade/gain/state stream) with per-load tokens, so the engine can be swapped.
- **v1 engine: `AVQueuePlayer`, two decks (Minidisc model).** Reasons:
  - It is first-party, so AirPlay 2, CarPlay, background audio and media-services-reset behaviour come from Apple.
  - It has native gapless with `AVPlayerItem` preloading (plus the gapless metadata in AAC/ALAC).
  - It has **no 44.1 kHz resample**.
  - Use `MTAudioProcessingTap` for ReplayGain greater than 0 dB.
  - Keep AudioStreaming (AVAudioEngine) as a behind-a-flag alternative if we need EQ or Vorbis.
  - Note that `AVPlayer` cannot play FLAC-in-Ogg or Opus-in-Ogg reliably. Ask Navidrome for `format=aac` (or `raw` for FLAC/ALAC/MP3/AAC) on cellular, not Opus, unless we ship an Opus decoder.
- **Preload** the next item about 15–20 s before the end (Amperfy uses 10 s, which is too tight on cellular). Re-preload after any seek or queue edit.
- **Crossfade**: a second deck with an equal-power curve, disabled on AirPlay and for albums tagged gapless/continuous (skip crossfade when the next track is from the same album).
- Use the API `duration` as the scrubber authority until the decoder reports a real duration. Always send `estimateContentLength=true` for transcoded playback. Implement seeking in transcodes via `timeOffset` when `getOpenSubsonicExtensions` reports `transcodeOffset`. Otherwise fall back to "seek within buffered range only" or a full-file temp download.

### Caching, prefetch and offline
- **Three tiers:**
  1. The streaming buffer.
  2. An **LRU "auto-cache"** (user-capped in GB) that pre-fetches the **next 3 queue items**. Keep cached items when the user skips. Pause it during track transitions.
  3. **Pinned downloads** (albums, playlists, artists, "Liked") that are never evicted and are synced on reconnect.
- One background `URLSession` (`.background(withIdentifier:)`) per server, with `isDiscretionary = false` for user-initiated downloads and `true` for bulk sync. Set `allowsCellularAccess` per request from settings. Persist the request queue (SwiftData/GRDB). Move the file synchronously in `didFinishDownloadingTo`. Throttle progress UI (do not write progress to the DB on every chunk). Handle `application(_:handleEventsForBackgroundURLSession:)`.
- **Avoid Amperfy's double-fetch.** Either tee the stream into the cache with `AVAssetResourceLoaderDelegate` (custom scheme, serves byte ranges from a growing file), or accept the double fetch only on Wi-Fi. The resource-loader approach is more complex but saves cellular data. Prototype it, and fall back to the separate-transfer approach (Minidisc) if it misbehaves with AirPlay. Note that a custom-scheme resource loader does not work for AirPlay video, but audio-only AirPlay 2 routes locally rendered audio, so verify this.
- Store artwork once, resized to two sizes (thumb and hero), not the original.
- Download the format separately from the stream format (Narjo and Amperfy both do this), and verify the server actually honoured it.

### Networking and auth
- Subsonic token auth: a per-request random salt and `md5(password+salt)`. Prefer **OpenSubsonic `apiKey`** when the server advertises it. Keep the password in the Keychain only.
- **Redact `u/p/t/s/apiKey` from every log and diagnostic.** Copy Amperfy's `cleanse(url:)`.
- Support custom headers (Cloudflare Access, Authelia), mTLS client certificates and self-signed certificates.
- **Multiple base URLs with automatic failover** (LAN → Tailscale → public) driven by `NWPathMonitor` and ping.
- Call `getOpenSubsonicExtensions` at login and feature-gate: `songLyrics`, `transcodeOffset`, `formPost`, `apiKeyAuthentication`, and so on.
- Sync queue state with `savePlayQueue`/`getPlayQueue` to the server (automatically, debounced) for Spotify-like "continue on Mac/TV/web". This also feeds our web app.

### CarPlay (top priority)
- Entitlement `com.apple.developer.carplay-audio`. Use a dedicated `CPTemplateApplicationSceneDelegate`. **The CarPlay scene must work when the phone app has never been opened** (cold launch from the car), so do not depend on phone UI state.
- **Root:** `CPTabBarTemplate`, **at most 4 tabs** for audio apps. Recommended tabs:
  - **Home**: `CPListImageRowItem` shelves for Recently played, Daily mixes / ListenBrainz recs, Recently added, Downloaded.
  - **Library**: Playlists, Artists, Albums, Liked, Genres, Radio (stations).
  - **Downloads/Offline**.
  - **Search**: a list tab that pushes `CPSearchTemplate`. Hide it when `CPSessionConfiguration.limitedUserInterfaces` contains `.keyboard`. Rely on Siri via `CPAssistantCellConfiguration(.playMedia)` plus `INPlayMediaIntent` handling.
- Stack depth is at most 5 for audio apps. Design Root → Category → Entity → Tracks (4).
- **Never hardcode limits.** Read `CPListTemplate.maximumItemCount`, `maximumSectionCount`, `CPTabBarTemplate.maximumTabCount` and `CPListImageRowItem.maximumImageSize`. For long lists, use alphabet sections with `sectionIndexTitle` and paging ("Show more…" rows), and avoid silent truncation.
- **Do not mutate the visible template while the user browses.** Snapshot data when it appears and apply updates only when the template is not on top or the user pulls a refresh row (this fixes the Amperfy #647 focus jumps). Do all fetching off the main actor. Build items quickly with placeholder art, then set `item.setImage` asynchronously.
- `CPNowPlayingTemplate.shared`: shuffle, repeat, like (`CPNowPlayingImageButton`), "Start radio" button. `isUpNextButtonEnabled` shows the queue. `isAlbumArtistButtonEnabled`. Enable `changePlaybackPositionCommand` (scrubbing, a top user wish). Expose ±15 s only for podcasts and audiobooks.
- Playback requested from CarPlay must use exactly the same resolve, auth and cache path as the phone. Test with the network lost mid-drive, a cold start in airplane mode (only Downloads tab content should be playable, and other rows should be greyed or hidden), and the CarPlay Simulator plus a real head unit with a rotary knob.

### Now Playing and system integration
- Use `MPRemoteCommandCenter` with commands toggled per content type (copy Amperfy's matrix), including `likeCommand` mapped to Subsonic `star`.
- Update `MPNowPlayingInfoCenter` on every item change, rate change and seek, and set `playbackState` explicitly.
- `AVAudioSession` `.playback` with `.longFormAudio` route-sharing policy. Handle interruptions (resume on `.shouldResume` only), `oldDeviceUnavailable` (pause), and `mediaServicesWereReset` (rebuild players). Re-assert the category on activation.
- Use App Intents and `INPlayMediaIntent` for Siri ("play my Liked songs on <app>"), and Widgets/Live Activity (optional).

### Discovery (our differentiator)
- **ListenBrainz**: submit listens directly (50% or 4 min rule, offline queue). Pull recommendations, "Created for you" playlists and fresh releases. Map MBIDs to local tracks with Navidrome MBID tags.
- **Radio:** `getSimilarSongs2`/`getTopSongs` plus ListenBrainz similar-artists/LB Radio to seed an endless queue (Spotify "Go to radio").
- **Lidarr:** when a ListenBrainz recommendation or a search result is not in the library, offer "Add to Lidarr" (Minidisc proves the UX). Show the download queue, then the item appears in Navidrome after a rescan.

### Platform strategy
- A shared Swift package (API client, models, playback core, cache) for iOS, iPadOS, macOS (native SwiftUI, not Catalyst; NaviBeat users praise this), tvOS (focus UI, no CarPlay, AVPlayer engine only) and watchOS later.
- One universal purchase, if paid. The market accepts about $5 one-time (NaviBeat, play:Sub) or a $30 lifetime (Narjo). Free open source competes on trust (Amperfy, Minidisc, Substreamer).

---

## 8. Could not verify
- Internal tech (SwiftUI vs UIKit, playback engine) of **Narjo, NaviBeat, play:Sub and Arpeggi**: these are closed source, and listings only say "native" or "SwiftUI".
- Arpeggi's current version and date (sources conflict), crossfade and lyrics status.
- Depth of Narjo's Lidarr/AudioMuse integrations (listing claim only).
- Reddit threads: r/navidrome and r/selfhosted pages were not fetchable directly. User sentiment comes from Lemmy/PieFed mirrors, App Store reviews and GitHub issues.
- Exact current numeric values of `CPListTemplate.maximumItemCount` and `maximumSectionCount`. They vary by iOS version and head unit, so read them at runtime. The 4-tab and depth-5 audio limits come from Apple's CarPlay guidelines as quoted by secondary sources.
- Which Navidrome versions support the OpenSubsonic `transcodeOffset` extension. Check `getOpenSubsonicExtensions` on our server.

## 9. Sources
- Amperfy: https://github.com/BLeeEZ/amperfy (issues #96, #305, #318, #512, #603, #647, #652, #672, #719, #764, #779, #850, #857)
- Minidisc: https://github.com/Loriage/Minidisc (PR #6, docs/AudioStreamingEvaluation.md, docs/PlaybackContinuity.md)
- Cassette: https://github.com/CassetteLab/cassette
- AudioStreaming: https://github.com/dimitris-c/AudioStreaming (issue #38: MP3 gap)
- Substreamer: https://github.com/ghenry22/substreamer, https://apps.apple.com/us/app/substreamer/id1012991665
- Arpeggi: https://apps.apple.com/us/app/arpeggi/id6503619183, https://piefed.jeena.net/post/312372
- Narjo: https://apps.apple.com/us/app/id6748359006
- NaviBeat: https://apps.apple.com/app/id6763518834, https://navibeat.app
- play:Sub: https://apps.apple.com/us/app/play-sub-music-streamer/id955329386
- Minidisc listing: https://alternativeto.net/software/minidisc/about/
- Navidrome app directory: https://www.navidrome.org/apps/
- CarPlay UX thread: https://tildes.net/~tech/1kea/iphone_music_players_with_good_carplay_experience
- Symfonium transcoding/seek threads: https://support.symfonium.app/t/seeking-plays-song-from-beginning-if-transcoding-to-mp3-is-enabled/7325
