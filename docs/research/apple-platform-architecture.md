# Apple Platform & Web Architecture Research — Navidrome Premium Player

_Research date: 2026-10-26. Platform baseline: **iOS/iPadOS/macOS/tvOS 27** (WWDC26, June 8–12 2026; iOS 27 public Sept 14 2026), **Xcode 27 / Swift 6.4**, Liquid Glass (revised in 27)._

Confidence legend: **[Verified]** = read in Apple docs/PDF/session page during this research; **[Reported]** = reputable secondary source, not confirmed in Apple docs; **[Opinion]** = engineering recommendation.

---

## 0. Platform landscape check (what is "current" in Oct 2026)

| Item | Status | Source |
|---|---|---|
| iOS 27 | Announced WWDC26 (June 8 2026), released Sept 14 2026. Liquid Glass revised (less default transparency, user-adjustable translucency slider). **[Reported]** | [Wikipedia: iOS 27](https://en.wikipedia.org/wiki/IOS_27), [AppleInsider](https://appleinsider.com/articles/26/03/26/stop-holding-out-hope-liquid-glass-will-be-mandatory-in-ios-27) |
| Liquid Glass opt-out | Apps built with the iOS 27 SDK can no longer opt out (`UIDesignRequiresCompatibility` ignored); scene-based lifecycle required. **[Reported]** | [classmethod migration guide](https://dev.classmethod.jp/en/articles/ios27-xcode27-migration-preparation-guide/), [Wikipedia: Liquid Glass](https://en.wikipedia.org/wiki/Liquid_Glass) |
| Foldable iPhone | **Exists: "iPhone Duo"**, announced Sept 9 2026, $1,999, available Oct 23 2026. Book-style, 7.8" inner display, outer compact display. **[Reported, multiple outlets]** | [CNBC live blog](https://www.cnbc.com/2026/09/09/apple-event-today-live-updates.html), [MacRumors guide](https://www.macrumors.com/guide/foldable-iphone/) |
| iPhone Duo developer guidance | Apple Tech Talk "Prepare your app for iPhone Duo"; Xcode 27.1 Device Hub simulator. **[Verified – session page]** | [Tech Talk 111461](https://developer.apple.com/videos/play/tech-talks/111461/) |
| CarPlay in iOS 27 | MiniPlayer, scrubbing, **Search template now allowed for audio apps**, richer list cards, video apps category. **[Verified – CarPlay Developer Guide 2026‑10‑13 + WWDC26 212]** | [WWDC26 "Rev up your CarPlay app"](https://developer.apple.com/videos/play/wwdc2026/212/), [CarPlay Developer Guide PDF](https://developer.apple.com/download/files/CarPlay-Developer-Guide.pdf) |
| SiriKit | Docs now describe SiriKit/Intents as "legacy support"; App Intents is the path to Siri AI. New **`.audio` App Schema domain** (`playAudio`, `addToLibrary`, `addToPlaylist`, `createStation`, `updateAudioAffinity`, …). **[Verified – Apple docs]** | [SiriKit](https://developer.apple.com/documentation/sirikit), [Audio schema domain](https://developer.apple.com/documentation/appintents/app-schema-domain-audio) |

> Note: the dev machine currently only has Command Line Tools with SDK 26.5 — **Xcode 27.x must be installed** before any of the iOS 27 APIs below can be used.

---

## 1. Project structure

### 1.1 Recommended layout **[Opinion]**

```
NavidromePlayer.xcworkspace
├── Packages/
│   ├── CoreModels        (pure Swift, Sendable value types: Track, Album, Artist, Playlist, ReplayGain…)
│   ├── SubsonicKit       (OpenSubsonic/Navidrome REST client, auth, URL builders, async/await, no UI)
│   ├── LibraryStore      (GRDB/SQLiteData cache + offline index, migrations, FTS5 search)
│   ├── PlaybackEngine    (queue, decoder, renderer, gapless/crossfade, ReplayGain, FFT tap, NowPlaying/RemoteCommands)
│   ├── DownloadManager   (background URLSession, storage quotas, file protection)
│   ├── VisualsKit        (Metal shaders, particle systems, palette extraction; per-platform budgets)
│   └── DesignSystem      (Liquid-Glass-native components + "Immersive" theme tokens)
├── Apps/
│   ├── App (multiplatform SwiftUI target: iOS + iPadOS + macOS)   + CarPlay scene (iOS only)
│   ├── TVApp (separate tvOS target)
│   └── Widgets/LiveActivity extension, App Intents (in-app, not extension, for playback)
└── web/ (see §7)
```

- **One multiplatform SwiftUI app target for iPhone/iPad/Mac**, plus a **separate tvOS target**. tvOS shares packages but its UI (focus engine, 10‑ft layouts, no CarPlay, no downloads-as-guarantee) diverges enough that `#if os(tvOS)` sprawl in a shared target becomes a liability.
- **Mac: native SwiftUI (AppKit-backed), not Mac Catalyst.** Native gives proper menu bar commands, `Settings` scene, multiple windows, `MenuBarExtra` mini player, keyboard shortcuts and media keys via `MPRemoteCommandCenter`. Catalyst only makes sense if you have heavy UIKit to reuse; we don't. (CarPlay APIs are irrelevant on Mac.)
- **Swift 6 language mode, strict concurrency complete.** Use Xcode's *Default Actor Isolation = MainActor* for the app target (Swift 6.2+ "approachable concurrency", carried forward in Xcode 27/Swift 6.4 **[Reported]** — [Massicotte WWDC26 notes](https://massicotte.org/blog/wwdc26-unanswered-qa/)), but keep **packages nonisolated by default** with explicit actors (`PlaybackEngine` uses a dedicated serial executor/queue for the render pipeline; `LibraryStore` is an actor or uses GRDB's `DatabasePool`).
- **Observation (`@Observable`)** for view models / player state. Keep the audio render thread completely outside Observation; publish coarse state (position at ~4–10 Hz, track changes) to a `@MainActor @Observable PlayerState`.

### 1.2 SwiftData vs GRDB for the library cache **[Opinion, backed by community evidence]**

Recommend **GRDB 7 (or Point-Free's SQLiteData on top of GRDB)**:

- Library caches of 50k–500k tracks need FTS5 search, bulk upserts from `getAlbumList2`/`search3` sync, and cheap `Sendable` value types across actors. GRDB/SQLiteData gives SQL control, `ValueObservation` for SwiftUI, and WAL concurrency.
- SwiftData in iOS 27 gained sectioned queries, `ResultsObserver`, `HistoryObserver`, compound predicates ([Apple SwiftData updates](https://developer.apple.com/documentation/updates/swiftdata)), but practitioners still report `ModelActor` running on main, `propertiesToFetch` not honoured, and no performance leap ([Michael Tsai roundup, June 2026](https://mjtsai.com/blog/2026/06/23/swiftdata-in-appleos-27/)). Benchmarks cite GRDB/SQLiteData as 10–50× faster at 10k+ rows ([comparison](https://hackernoon.com/swiftdata-core-data-or-grdb-choose-by-the-queries-you-actually-run), [blakecrosley](https://blakecrosley.com/blog/swiftdata-performance-storage-engine)).
- Prior art: Amperfy (open-source Subsonic iOS player with CarPlay) uses Core Data + the AudioStreaming engine; it's a useful reference for what's painful.

### 1.3 tvOS constraints **[Verified via Apple forums/Xamarin docs on tvOS storage]**

- Only ~**500 KB persistent local storage** (`UserDefaults`); everything else goes into Caches and **may be purged when the app is not running** ([Apple forum](https://developer.apple.com/forums/thread/16967), [tvOS storage overview](https://learn.microsoft.com/nl-nl/previous-versions/xamarin/ios/tvos/app-fundamentals/resources-data-storage)). → Treat the tvOS library DB as a rebuildable cache; store server config/credentials in Keychain (+ iCloud Keychain/`NSUbiquitousKeyValueStore` for convenience); no "offline downloads" promise on tvOS.
- App bundle limit 200 MB (+ On‑Demand Resources).
- **No WebKit/WKWebView**; all UI must be native (fine — SwiftUI).
- **Focus engine**: use `focusable`, `@FocusState`, `.focusSection()`, button styles `.card`/`.borderless`; Cover Flow-style carousels map very naturally to focus-driven horizontal scroll with `scrollTransition`.
- AirPlay / Now Playing on tvOS: `MPNowPlayingInfoCenter` and `MPRemoteCommandCenter` work; the Siri Remote play/pause maps to remote commands.

### 1.4 iPhone Duo (foldable) **[Verified – Tech Talk 111461]**

- Outer display: compact width (like a normal iPhone). Inner display: **regular × regular** size classes and **does not honour supported interface orientations** → never lay out by orientation, only by size class / available geometry.
- All apps participate in 50/50 Split View on the inner display → the regular layout must also work at half width; safe areas can be **asymmetric**.
- Use `NavigationSplitView` / `TabView` with `.defaultTabBarPlacement(.sidebar)` (iPad-style sidebar on inner display); iOS 27.1 adds `ReservedRegion` for custom bars. Replace `UIScreen.main` with `traitCollection.displayScale` / `windowScene.screen`.
- Test in Xcode 27.1 Device Hub (fold/unfold/rotate controls).
- Product idea: unfolded = iPad-like library + persistent Now Playing column; fold → seamlessly hand off to compact Now Playing (keep the `PlayerState` scene-independent).

---

## 2. Audio engine

### 2.1 Options compared

| Approach | Gapless | Crossfade | Real-time PCM (visualizer, ReplayGain, EQ) | AirPlay 2 enhanced buffering | HTTP streaming & caching | Effort |
|---|---|---|---|---|---|---|
| **AVQueuePlayer** | Yes *if* the file carries encoder-delay/padding metadata (AAC/ALAC with iTunSMPB/edit lists; MP3 only with LAME/Xing info tag) ([Apple forum](https://developer.apple.com/forums/thread/111413), [Wikipedia](https://en.wikipedia.org/wiki/Gapless_playback)) | No native; needs two players + volume ramps (breaks gapless, AirPlay sync) | Only via `MTAudioProcessingTap` on `AVPlayerItem.audioMix` — works for progressive HTTP once the asset track is loaded, **not for HLS** ([Apple forum 45966](https://developer.apple.com/forums/thread/45966)); fragile | **Yes, automatic** ([WWDC23 10238](https://developer.apple.com/videos/play/wwdc2023/10238/)) | `AVAssetResourceLoaderDelegate` custom scheme + range requests ([Jared Sinclair guide](https://jaredsinclair.com/2016/09/03/implementing-avassetresourceload.html)) | Low |
| **AVAudioEngine** (`AVAudioPlayerNode`, e.g. [AudioStreaming](https://github.com/dimitris-c/AudioStreaming) used by Amperfy) | Yes (you schedule buffers back-to-back; you must trim priming/padding yourself) | Yes (two player nodes + mixer) | **Yes, trivially** (`installAudioTap(onBus:…)` new Sendable API in iOS 27 **[Verified]**; EQ via `AVAudioUnitEQ`; ReplayGain via mixer volume) | **No** – engine output to AirPlay is real-time route (no enhanced buffering); higher latency/robustness issues on HomePod | DIY: URLSession byte stream → `AudioFileStream` → `AudioConverter` | Medium–High |
| **AVSampleBufferAudioRenderer + AVSampleBufferRenderSynchronizer** (Apple's "custom player") | Yes (you decode + trim) | Yes (you mix PCM before enqueue) | **Yes** (you own PCM before enqueue) | **Yes** — "flexible enhanced buffering… to AirPlay-enabled devices and supported CarPlay vehicles" **[Verified]** ([doc](https://developer.apple.com/documentation/avfoundation/implementing-flexible-enhanced-buffering-for-your-content), [sample](https://developer.apple.com/documentation/avfaudio/playing-custom-audio-with-your-own-player)) | DIY (same as AVAudioEngine) | High |

### 2.2 Recommendation **[Opinion]**

**Phase 1 (ship fast, CarPlay first): AVQueuePlayer** with:
- Request gapless-friendly formats from Navidrome: prefer **original FLAC/ALAC/AAC**; when transcoding, use **AAC (fMP4/M4A)** or Opus-in-CAF rather than MP3. Native FLAC/Opus decode is supported by Apple's audio stack; Ogg containers are not by AVPlayer.
- `AVAssetResourceLoaderDelegate` cache layer (custom `navicache://` scheme → serve byte ranges from disk, fetch misses with `URLSession`). This doubles as "play while downloading" for offline.
- Preload next 1–2 items (`AVQueuePlayer.insert`) with `automaticallyWaitsToMinimizeStalling` tuned.
- ReplayGain via `AVMutableAudioMix` input parameters `setVolume` (≤ 1.0 — can't boost; use peak-aware attenuation-only, or pre-amp down globally).

**Phase 2 (premium engine): custom `AVSampleBufferAudioRenderer` pipeline** behind the same `PlaybackEngine` protocol:
`URLSession (range, cache) → AudioFileStream parse → AudioConverter decode to Float32 PCM → trim encoder delay/padding (iTunSMPB, LAME tag, FLAC exact) → ReplayGain (+limiter for positive gain) → crossfade mixer → FFT tap (vDSP) → enqueue LPCM CMSampleBuffers → renderer/synchronizer`.
This is the only Apple-blessed design that gives true gapless, crossfade, ReplayGain with boost, real-time FFT **and** AirPlay 2 / CarPlay enhanced buffering simultaneously. Keep AVAudioEngine only for an optional local-only "DSP mode" (EQ) if needed.

### 2.3 Session, interruptions, routes **[Verified/standard API]**

- `AVAudioSession.setCategory(.playback, mode: .default, policy: .longFormAudio)` once at launch; **activate only when playback actually starts** (CarPlay guide: activating early kills the car's FM radio) **[Verified – CarPlay guide]**.
- `UIBackgroundModes: audio`.
- Handle `AVAudioSession.interruptionNotification` (resume if `.shouldResume`), `routeChangeNotification` (pause on `.oldDeviceUnavailable` — headphones unplugged), `mediaServicesWereResetNotification` (rebuild engine).
- **Now Playing:** `MPNowPlayingInfoCenter` (title, artist, album, artwork, duration, elapsed, rate, `MPNowPlayingInfoPropertyAssetURL`, queue index/count) and `MPRemoteCommandCenter` (play/pause/toggle, next/prev, `changePlaybackPosition` — required for CarPlay iOS 27 scrubbing — like/dislike/bookmark → map to Navidrome star/rating). On iOS, AVPlayer can auto-publish via `MPNowPlayingSession`; with a custom renderer publish manually.
- **AirPlay 2:** `AVRoutePickerView` (UIKit/AppKit) wrapped for SwiftUI; set `prioritizesVideoDevices = false`. Long-form policy routes the whole app to AirPlay.
- **Spatial/lossless:** AirPlay transports ALAC ≤ 16‑bit/44.1–48 kHz; hi-res FLAC is downsampled on AirPlay/Bluetooth. Head-tracked "Spatialize Stereo" is a system feature for stereo content; true Atmos requires Dolby Atmos/EC‑3 assets (Navidrome libraries rarely have them) — de-scope. Show a "lossless/hi-res" badge only when the output route is wired/USB DAC.
- **ReplayGain:** OpenSubsonic exposes `replayGain {trackGain, albumGain, trackPeak, albumPeak, baseGain, fallbackGain}` on songs ([OpenSubsonic spec](https://opensubsonic.netlify.app/docs/responses/replaygain/)). Apply album gain when playing an album in order, track gain on shuffle; clamp with peak (`gain_linear * peak ≤ 1`) or soft limiter.

---

## 3. Visualizers & immersive effects

### 3.1 Getting spectrum data **[Opinion, with verified constraints]**

- With **AVQueuePlayer**: `MTAudioProcessingTap` on `AVMutableAudioMix` works for progressive HTTP/local files once the `AVAssetTrack` is available, **never for HLS** ([Apple DTS via forum](https://developer.apple.com/forums/thread/45966), [rymc.io](https://rymc.io/blog/2014/recording-live-audio-streams-on-ios/)). It's Obj‑C/C callbacks, real-time thread, and breaks easily with AirPlay (tap may not run or runs ahead when buffering remotely).
- With the **custom renderer** (Phase 2) you have PCM before enqueue: compute FFT with **Accelerate `vDSP.FFT` / `vDSP.DCT`** (1024–2048 bins, Hann window, log-frequency bands), store frames in a ring buffer **keyed by presentation timestamp**, and the UI reads the frame matching `renderSynchronizer.currentTime()` — essential because AirPlay enhanced buffering enqueues seconds ahead.
- **Pragmatic fallback for Phase 1 / AirPlay / CarPlay-only cases:** "pseudo‑visualizer" driven by pre-computed per-track loudness envelopes (compute once when cached/downloaded, store in DB as a ~10 Hz RMS + 8-band array) — cheap, perfectly synced to `currentTime`, works on every route, and is battery-friendly. Recommend shipping this first and the live FFT in Phase 2.

### 3.2 Rendering **[Verified APIs; Opinion on budgets]**

- **SwiftUI shaders** (`colorEffect`, `distortionEffect`, `layerEffect`, iOS 17+) driven by `TimelineView(.animation)`; WWDC26 "Compose advanced graphics effects with SwiftUI" literally demos a **cover-art background warp** via `layerEffect` + noise texture ([WWDC26 322](https://developer.apple.com/videos/play/wwdc2026/322/)). Use this for: album-art-derived animated mesh/gradient backgrounds (also `MeshGradient`), bloom, ripple on beat.
- **Particles:** `Canvas` + `TimelineView` is fine up to ~500–1,000 sprites; beyond that use a small **Metal (`MTKView`) compute+instanced draw** system, or SpriteKit `SKEmitterNode` (easiest, also on tvOS). Recommend Metal for the hero immersive view (one render pass shared by particles + spectrum bars), Canvas for small widgets.
- **Cover Flow:** SwiftUI `ScrollView(.horizontal)` + `scrollTransition` / `visualEffect` with `rotation3DEffect` and reflection; on tvOS it maps to focus.
- **Budgets:** cap immersive mode at 60 fps (ProMotion 120 only when charging or user-enabled); pause `TimelineView` when not visible (`.paused` schedule / scenePhase), when Low Power Mode (`ProcessInfo.isLowPowerModeEnabled`), thermal state ≥ `.serious`, and when the screen is locked (Now Playing on lock screen gets static art). Target < 10% GPU on A17-class at 60 fps; measure with Instruments (Metal System Trace, Energy Log).
- **Accessibility:** honour `@Environment(\.accessibilityReduceMotion)` (static gradient, no particles, crossfade instead of 3D Cover Flow), `accessibilityReduceTransparency` (Liquid Glass fallbacks), and avoid flashing (> 3 Hz luminance flashes) on beat-reactive effects.
- **Liquid Glass coexistence:** System chrome (tab bar, toolbars, `tabViewBottomAccessory` mini player — iOS 26+ **[Verified]**) is Liquid Glass in iOS 27 and can't be opted out; "Immersive" mode should be a full-bleed custom view *under* glass controls (`glassEffect(_:in:)`, `GlassEffectContainer`), which actually suits album-art backgrounds well.
- **CarPlay:** no custom drawing at all — templates only; lyrics are forbidden on CarPlay **[Verified]**.

---

## 4. CarPlay (top priority)

### 4.1 Entitlement & setup **[Verified – CarPlay Developer Guide, rev. 2026‑10‑13]**

- Request at [developer.apple.com/carplay](https://developer.apple.com/carplay/) → choose **Audio** category, accept the CarPlay Entitlement Addendum; Apple adds `com.apple.developer.carplay-audio` to your account; regenerate provisioning profile; add boolean key to entitlements. Lead time is typically days–weeks — **apply on day 1**.
- One CarPlay category per app (audio cannot be combined with others). CarPlay audio apps also appear on **Apple HomeView** automatically.
- Scene-based: declare `CPTemplateApplicationSceneSessionRoleApplication` with a `CPTemplateApplicationSceneDelegate`; app may be launched **only** on the CarPlay screen — the playback engine and library must boot without the phone UI.
- CarPlay runs while the **iPhone is locked**: files with `NSFileProtectionComplete`/`CompleteUnlessOpen` and Keychain items `WhenUnlocked*` are **inaccessible** → use `completeUntilFirstUserAuthentication` / `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` for DB, cache, downloads and credentials **[Verified]**.

### 4.2 Templates available to audio apps (iOS 27) **[Verified – table p.15]**

| Template | Audio apps |
|---|---|
| Tab bar (`CPTabBarTemplate`) | ✅ — **max 4 tabs for audio apps**; read `CPTabBarTemplate.maximumTabCount` |
| List (`CPListTemplate`) | ✅ — incl. `CPListImageRowItem` with Row/Card/Condensed/Grid/Image-grid element styles (iOS 26), pinned header grid buttons (iOS 26), **portrait/landscape images, progress overlays, details header (iOS 27)** |
| Grid (`CPGridTemplate`) | ✅ — up to 8 buttons |
| Now Playing (`CPNowPlayingTemplate.shared`) | ✅ — custom buttons (`CPNowPlayingShuffleButton`, `…RepeatButton`, `…PlaybackRateButton`, `…AddToLibraryButton`, `…MoreButton`, `…ImageButton`); "Up Next" pushes a list; **MiniPlayer automatic in iOS 27** (`allowsMiniPlayer`, iOS 27.0 **[Verified]**); scrubbing via `changePlaybackPosition` |
| Alert, Action sheet (iOS 17+) | ✅ |
| **Search (`CPSearchTemplate`)** | ✅ **iOS 27 or later only** — keyboard may be unavailable while driving; must be an alternative, never the primary path |
| Voice control (`CPVoiceControlTemplate`) | ✅ iOS 27+ |
| Information, Contact, Map, POI | ❌ (runtime exception) |

- **Depth limit: 5 templates including root** for audio apps.
- **Lists:** some cars dynamically limit to **12 items**; always read `CPListTemplate.maximumItemCount` / `maximumSectionCount` at runtime and paginate ("More…" item → push next page counts against depth!) — better: smart top-N lists (Recently Played, Starred, Recently Added, Random Album) rather than full A–Z browsing.
- **Image sizes:** use `CPListItem.maximumImageSize` / `CPListImageRowItem.maximumImageSize`; fixed sizes: grid icon 40 pt (120 px @3x), tab icon 24 pt (72 px), now-playing button 20 pt (60 px). Provide light/dark variants; fetch Navidrome `getCoverArt?size=` sized to the car's `carTraitCollection.displayScale`. Test screens 748×456 @2x up to 1920×720 @3x and portrait 900×1200.
- **Handlers:** in `CPListItem.handler`, start playback asynchronously and call `completion()` (spinner shows until then), then push `CPNowPlayingTemplate.shared`.
- Content rules: no lyrics, never ask the driver to use the phone (e.g. "Not signed in — sign in when parked").
- **iOS 27 extras:** `CPPlaybackConfiguration` (elapsed/duration/playbackAction on list thumbnails) — great for "resume album" cards ([WWDC26 212](https://developer.apple.com/videos/play/wwdc2026/212/)). iOS 26: `CPListImageRowItem` element styles + sports Now Playing mode ([WWDC25 216](https://developer.apple.com/videos/play/wwdc2025/216/)).
- Open question: Apple Music shows a magnifier beside the MiniPlayer; no public API confirmed for third parties yet ([forum 849281](https://developer.apple.com/forums/thread/849281)).

### 4.3 CarPlay Ultra
All framework features (widgets, Live Activities, templates) appear in CarPlay Ultra automatically; no separate work for audio apps beyond respecting variable screen sizes **[Verified – WWDC25 216]**.

### 4.4 Siri / App Intents **[Verified – Apple docs]**
- SiriKit `INPlayMediaIntent` still works ("legacy support") and is what many cars' voice button invokes today; App Intents is the forward path. Ship **both**:
  1. `INPlayMediaIntent` + `INAddMediaIntent` + `INUpdateMediaAffinityIntent` handled **in-app** (iOS 14+ in-app intent handling so playback starts in the main process).
  2. App Intents **`.audio` schema domain**: adopt `playAudio` **together with** an `IntentValueQuery` that receives the `MediaIntents` `AudioSearch` and returns `AudioEntity` (song/album/artist/playlist/station) — Xcode warns if only one half of the "use-case group" is implemented ([doc](https://developer.apple.com/documentation/appintents/app-schema-domain-audio)). Also `updateAudioAffinity` ("I like this song" → star), `addToPlaylist`. Mark playback intents `AudioPlaybackIntent` ([doc](https://developer.apple.com/documentation/appintents/audioplaybackintent)).
- Index library entities into Spotlight (`IndexedEntity`) so Siri AI can resolve vague requests.

### 4.5 Testing
- **CarPlay Simulator** (Additional Tools for Xcode, macOS app, iPhone over USB) — tests real device incl. locked state, widgets, Live Activities; plus Xcode's simulator "I/O → External Displays → CarPlay". Test the 12-item limit and keyboard-limited UI configurations. Real-car testing (wired + wireless) before release.

---

## 5. Offline downloads

- **Background `URLSession`** (`URLSessionConfiguration.background(withIdentifier:)`), `isDiscretionary = false` for user-initiated, `sessionSendsLaunchEvents = true`; reconnect in `application(_:handleEventsForBackgroundURLSession:)` (SwiftUI: `.backgroundTask(.urlSession(...))`). Download tasks only (no data tasks) in background sessions; one task per track; resume data on failure.
- **Low Data Mode / cellular:** `allowsConstrainedNetworkAccess = false` (Low Data Mode, iOS 13+ **[Verified]**), `allowsExpensiveNetworkAccess` per user setting ("Download over cellular"), and for streaming pick a lower `maxBitRate` transcode when `NWPathMonitor` reports `isConstrained`/`isExpensive`.
- **Storage:** store under `Application Support/Downloads` (not Caches) with `isExcludedFromBackup = true`; streaming cache in `Caches` with LRU cap (e.g. 1–5 GB user-configurable); show usage via `volumeAvailableCapacityForImportantUsage`. tvOS: cache only.
- **File protection:** `.completeUntilFirstUserAuthentication` (CarPlay + background playback while locked require it) **[Verified – CarPlay guide]**.
- Download originals (FLAC) or a transcoded "offline quality" profile; record ReplayGain/loudness envelope at download time.

---

## 6. Security

- **Credentials:** Keychain, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (works locked/CarPlay). Prefer OpenSubsonic **`apiKey` auth extension** where the server advertises it (`getOpenSubsonicExtensions`); otherwise token+salt (`t`/`s`) — never store or send the plain password per request. Share via Keychain access group with widgets/intents.
- **ATS & plain HTTP LAN servers** **[Verified behaviour]**:
  - `NSAllowsLocalNetworking = YES` covers **unqualified hostnames, `.local`, and IP addresses** without needing review justification; ATS doesn't apply to raw IP connections anyway ([OWASP MASTG](https://mas.owasp.org/MASTG/iOS/0x06g-Testing-Network-Communication)).
  - Do **not** ship `NSAllowsArbitraryLoads` (requires App Review justification). Users with `http://music.mydomain.com` over the internet: show a strong warning and recommend HTTPS (Tailscale/Caddy/Let's Encrypt). If you must support it, `NSAllowsArbitraryLoadsForMedia` only covers AVFoundation media, not API calls — so arbitrary-load is the only full route; justify as "user-configured self-hosted server" (Amperfy ships `NSAllowsArbitraryLoads` and is on the App Store, so it is approvable, but it's a review risk).
- **Local Network privacy:** add `NSLocalNetworkUsageDescription` (iOS 14+, macOS 15+). There's no API to query/request it; it fires on first LAN connection — trigger it deliberately during onboarding ("Test connection") and detect failure (`NWPath` + error codes) with a "Open Settings" hint. macOS Sequoia/Tahoe have reported flakiness with direct-IP connections ([forum 814226](https://developer.apple.com/forums/thread/814226), [Eclectic Light](https://eclecticlight.co/2026/01/14/how-local-network-privacy-could-affect-you/)).
- **Self-signed certs / pinning:** don't pin by default (users rotate Let's Encrypt certs). Offer opt-in **TOFU (trust-on-first-use) pinning of the leaf/SPKI hash** for self-signed servers via `URLSessionDelegate` `didReceive challenge`, with explicit user confirmation of the fingerprint. Custom trust must also be applied in the `AVAssetResourceLoader`/download sessions (AVPlayer won't call your delegate for its own loads — another reason to route media through your own URLSession).
- **Lidarr / ListenBrainz / Last.fm secrets never on clients.** Clients talk only to Navidrome and to your **BFF**; the BFF holds Lidarr API key, ListenBrainz token (or per-user tokens encrypted at rest), and exposes narrow endpoints (`POST /requests/album {mbid}` with authz + rate limiting). Authenticate BFF calls with a session derived from Navidrome login (BFF validates against Navidrome `ping`/`getUser`) or OIDC if the household uses one.

---

## 7. Web app (Docker)

### 7.1 Stack recommendation **[Opinion]**

- **Frontend: SvelteKit 2 (Svelte 5 runes) as SPA/PWA** — small bundles and fine-grained reactivity make the persistent player bar + huge virtualized lists feel "Spotify-smooth". Alternatives: SolidStart (equally fast, smaller ecosystem) or React 19 + TanStack (biggest ecosystem; Feishin's web player is React + react-query + a dual-`<audio>` engine and is good prior art).
- **BFF: Go** (single static binary, tiny Docker image, great reverse-proxy/streaming via `httputil.ReverseProxy`) **or** Bun/Hono if the team wants one language. Responsibilities: serve the SPA, proxy/augment Navidrome (CORS, auth), hold Lidarr/ListenBrainz secrets, cache MusicBrainz/cover lookups, rate-limit, audit log. Stream audio **directly from Navidrome** (or pass-through without buffering) to avoid doubling bandwidth.
- **Docker:** multi-stage build → distroless/alpine image; config via env + secrets (`/run/secrets`); healthcheck; runs behind the user's existing reverse proxy; compose file next to Navidrome.

### 7.2 Gapless & crossfade in browsers

- `<audio>` elements cannot be made truly gapless (decoder delay + scheduling jitter); dual-`<audio>` handoff (Feishin approach) gets "near-gapless" (~10–50 ms) and easy crossfade via `MediaElementAudioSourceNode` → `GainNode`.
- **True gapless:** Web Audio `AudioBufferSourceNode.start(when)` scheduling of **fully decoded** next track (memory: ~10 MB/min stereo float) — use **Gapless‑5's hybrid pattern** (start current track on HTML5 Audio, switch to WebAudio buffer once decoded) ([Gapless 5](https://cdn.jsdelivr.net/npm/@regosen/gapless-5@1.6.2/README.md)), **or MSE** with `timestampOffset` + `appendWindowStart/End` to trim encoder delay (works for MP3/AAC/fMP4/Opus-WebM; Safari MSE support for audio is limited on iPhone — iOS 17.1+ `ManagedMediaSource`) ([web.dev MSE for audio](https://web.dev/articles/mse-seamless-playback)).
- **Recommendation:** Web Audio graph `[MediaElementSource | AudioBufferSource] → ReplayGain GainNode → crossfade GainNodes → AnalyserNode (visualizer) → destination`; gapless via pre-decoded next buffer on desktop, dual-element fallback on mobile/low-memory. Note: `AnalyserNode` on cross-origin media requires CORS headers from Navidrome/BFF (`crossorigin="anonymous"`), otherwise output is zeroed — proxy through the BFF same-origin.
- **Media Session API** (Chrome 73+, Firefox 82+, Safari 15+; artwork on iOS lock screen fixed in 16.4) for metadata, `play/pause/previoustrack/nexttrack/seekto`, `setPositionState` ([web.dev](https://web.dev/articles/media-session), [dbushell on iOS PWA](https://dbushell.com/2023/03/20/ios-pwa-media-session-api/)).
- **PWA:** manifest + service worker (Workbox) for app shell and artwork cache; don't cache audio in SW Cache API at scale (quota; use OPFS for "offline in browser" only as a stretch). iOS home-screen PWAs can background-play `<audio>` but Web Audio contexts get suspended when backgrounded — another reason the mobile web fallback should use `<audio>` elements.

---

## 8. Biggest risks

1. **CarPlay entitlement lead time / rejection** — apply immediately; the app must be "primarily audio".
2. **Gapless + visualizer + AirPlay conflict** — AVQueuePlayer gives AirPlay/CarPlay buffering but poor PCM access; AVAudioEngine gives PCM but loses enhanced buffering. Only the `AVSampleBufferAudioRenderer` route solves all three, at high engineering cost (decoder, delay trimming, seeking, sync).
3. **MP3 libraries without LAME/iTunSMPB tags** will never be perfectly gapless with AVQueuePlayer; mitigate by server-side transcode to AAC/Opus or custom decoder.
4. **Plain-HTTP self-hosted servers vs ATS/App Review**, plus macOS/iOS Local Network permission flakiness.
5. **Locked-device data access** (CarPlay, background) — wrong file-protection or Keychain accessibility class silently breaks CarPlay launches.
6. **iOS 27 SDK mandates** (Liquid Glass non-optional, scene lifecycle, deprecated `installTap`/`connect` APIs reported) — design the immersive mode to live under glass chrome; target iOS 26 minimum only if willing to `#available`-gate the 27 APIs (CarPlay search, MiniPlayer, `installAudioTap`, audio App Schemas).
7. **Battery/thermal** from immersive visuals — enforce budgets and Reduce Motion from day one.
8. **iPhone Duo** is a brand-new form factor (shipped Oct 23 2026); real-device behaviour (fold transitions mid-playback, Split View) is untested in the wild.
9. **Browser gapless** remains a best-effort feature, especially on iOS Safari.

## 9. Key sources

- CarPlay Developer Guide (rev. 2026‑10‑13): https://developer.apple.com/download/files/CarPlay-Developer-Guide.pdf
- WWDC26 212 "Rev up your CarPlay app": https://developer.apple.com/videos/play/wwdc2026/212/
- WWDC25 216 "Turbocharge your app for CarPlay": https://developer.apple.com/videos/play/wwdc2025/216/
- MacRumors – CarPlay in iOS 27: https://www.macrumors.com/2026/06/08/new-apple-carplay-features-ios-27/
- `CPNowPlayingTemplate.allowsMiniPlayer`: https://developer.apple.com/documentation/carplay/cpnowplayingtemplate/allowsminiplayer
- `CPListTemplate.maximumItemCount`: https://developer.apple.com/documentation/carplay/cplisttemplate/maximumitemcount
- `CPSearchTemplate`: https://developer.apple.com/documentation/carplay/cpsearchtemplate
- App Intents audio domain: https://developer.apple.com/documentation/appintents/app-schema-domain-audio
- Apple Intelligence & Siri AI: https://developer.apple.com/documentation/appintents/apple-intelligence-and-siri-ai
- AudioPlaybackIntent: https://developer.apple.com/documentation/appintents/audioplaybackintent
- Flexible enhanced buffering: https://developer.apple.com/documentation/avfoundation/implementing-flexible-enhanced-buffering-for-your-content
- Playing custom audio with your own player: https://developer.apple.com/documentation/avfaudio/playing-custom-audio-with-your-own-player
- WWDC23 10238 Tune up your AirPlay audio experience: https://developer.apple.com/videos/play/wwdc2023/10238/
- `AVAudioNode.installAudioTap` (iOS 27): https://developer.apple.com/documentation/avfaudio/avaudionode/installaudiotap(onbus:buffersize:format:tapprovider:)
- `tabViewBottomAccessory`: https://developer.apple.com/documentation/swiftui/view/tabviewbottomaccessory(content:)
- `glassEffect(_:in:)`: https://developer.apple.com/documentation/swiftui/view/glasseffect(_:in:)
- WWDC26 322 Compose advanced graphics effects with SwiftUI: https://developer.apple.com/videos/play/wwdc2026/322/
- Prepare your app for iPhone Duo: https://developer.apple.com/videos/play/tech-talks/111461/
- `allowsConstrainedNetworkAccess`: https://developer.apple.com/documentation/foundation/urlsessionconfiguration/allowsconstrainednetworkaccess
- MTAudioProcessingTap + HLS limitation: https://developer.apple.com/forums/thread/45966
- AVQueuePlayer gapless discussion: https://developer.apple.com/forums/thread/111413
- AVAssetResourceLoaderDelegate guide: https://jaredsinclair.com/2016/09/03/implementing-avassetresourceload.html
- AudioStreaming (AVAudioEngine streaming lib): https://github.com/dimitris-c/AudioStreaming
- SwiftData in appleOS 27 roundup: https://mjtsai.com/blog/2026/06/23/swiftdata-in-appleos-27/
- OpenSubsonic ReplayGain: https://opensubsonic.netlify.app/docs/responses/replaygain/
- Navidrome Subsonic API compatibility: https://www.navidrome.org/docs/developers/subsonic-api
- OWASP MASTG iOS network: https://mas.owasp.org/MASTG/iOS/0x06g-Testing-Network-Communication
- Local network privacy (2026): https://eclecticlight.co/2026/01/14/how-local-network-privacy-could-affect-you/
- Gapless 5: https://cdn.jsdelivr.net/npm/@regosen/gapless-5@1.6.2/README.md
- MSE seamless audio: https://web.dev/articles/mse-seamless-playback
- Media Session API: https://web.dev/articles/media-session
- Prior art inspected locally: Amperfy (iOS Subsonic player, CarPlay, AudioStreaming engine w/ EQ+ReplayGain+FFT), Feishin (React/Electron web player, dual-`<audio>` gapless/crossfade).
