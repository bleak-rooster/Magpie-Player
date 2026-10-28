# Magpie 0.0.1: customisation, downloads, scrobbling, network and CarPlay

Date 2026-10-28. Owner request (paraphrased):
- Significantly more customisation: home order, hiding library elements such as genres, genres grouped into general groups with subgroups or shown as all genres, adjustable transcoding, and the number of downloads, how they are saved and how many songs are pre-downloaded.
- Add the common and useful features of comparable apps, "without overdoing it".
- Scrobble threshold (percentage or listen time), and a checkbox for scrobbling via Navidrome and/or directly to ListenBrainz.
- Plain http to `http://homeserver:4533` **and** to a local IP address must work. The owner called this essential.
- CarPlay fully functional. Version 0.0.1.
- Then design → tests → security review → flow review → final tests → TestFlight.

The owner delegated **every decision** ("you should do all of the decisions here"). Each choice below marked *(call)* is Claude's. Research: scratchpad `research-customisation.md` (12 apps surveyed). Current-state map: summarised in §1.

## 0. Intent, goals, non-goals, anti-goals

**Intent.** Magpie becomes the owner's daily driver at home, on mobile data and in the car. That needs control over what the screens show, what the stream costs, what lives on the phone, and when and where a play counts.

**Goals**
1. The home and library show what the owner wants, in the owner's order.
2. Genres are usable despite messy tags: grouped under parent genres, or as one flat list.
3. Streaming quality per network and download quality are adjustable.
4. Music plays offline: manual downloads, pre-downloaded upcoming songs, a cache with a limit, and offline mode.
5. Scrobbling is configurable: the threshold and the destination(s).
6. Plain http works to the home server by short name and by local IP in Release and TestFlight builds, on the phone and in the car.
7. CarPlay covers everything new that matters while driving (home order, downloads, genres) and is ready for the entitlement.
8. The marketing version is 0.0.1.

**Non-goals (this round).** These are the *(call)* cuts from the research "skip/should" list:
- Equaliser.
- Crossfade (it conflicts with the existing gapless AVQueuePlayer path).
- Playback speed and skip-silence.
- Widgets, Siri/App Intents.
- Ratings.
- Multi-server.
- Per-section card styles, grid/list toggles.
- Generated mixes.
- A concurrent-download setting beyond one simple control.
- Reordering CarPlay tabs.

**Anti-goals (failure even if it "works")**
- Settings sprawl. Every new setting sits in one of four clearly named Settings sections with a sensible default. Nothing becomes required.
- Breaking any existing guard: G0, G1, D29 (finds never scrobbled, now on *both* scrobble paths), D3, D12, D15, §5 voice.
- Downloads bloating iCloud backup, or being unreadable from the car while the phone is locked.
- Double-counting plays silently.
- Weakening ATS more than the owner's local-network need requires.

## 1. Current state (code map, verified 2026-10-28)
- **Home.** The order is hard-coded in `HomeView.swift:23-40`: Finish setting up card, Jump back in (`recent`), Made for you (ListenBrainz), Recently added (`newest`), Most played (`frequent`). There are 12 albums per shelf. CarPlay keeps its own copy of the order in `CarPlayUI/TemplateModels.swift:139-150`.
- **Library.** `LibraryView.swift:17-29` shows Playlists, Artists, Albums, Finds (if set up) and Requests, then a "Recently added" grid of 24. **There are no genres anywhere** (no API, model or view). There is no Songs list.
- **Settings.** `SettingsView.swift` (271 lines) has Appearance, Servers, Lidarr, ListenBrainz and Count plays. Settings live in UserDefaults; secrets live in the Keychain (`AfterFirstUnlockThisDeviceOnly`).
- **Playback.**
  - `NavidromeStreamURLs` already has `maxBitRate` and `format`, both always nil (`NavidromeAdapters.swift:108-123`). `Player.urlsInvalidated()` rebuilds URLs.
  - The engine is `AVQueueEngine` (AVQueuePlayer, `maxEnqueued 3`, `prefetchLead 20 s`). Gapless relies on encoder delay.
  - There is no disk cache (`urlCache = nil`), and no downloads, ReplayGain or sleep timer.
- **Scrobbling.** Through Navidrome only, gated by Count plays. D29 is fail-closed.
- **CarPlay.** The tabs are Home, Library, Finds (on 4-tab head units) and Search. The entitlement variant is chosen by `MAGPIE_CARPLAY` (default NO for device builds). A post-build step strips the CarPlay scene when the entitlement is absent.
- **ATS.**
  - Release: `NSAllowsLocalNetworking` only.
  - Debug: `NSAllowsArbitraryLoads` only, swapped in by a post-build script.
  - `ServerAddress.atsBlocksPlainHTTP` pre-refuses 100.64/10, public IPs and dotted non-`.local` names.
  - Verified on the real server (H4): single-label names work over http in Release. 100.x IPs and `*.ts.net` names are blocked.
- **Version.** `MARKETING_VERSION "1.0"` (project.yml:14). `check-release.sh:25` asserts 1.0. The `SettingsView` fallback is "1.0". `TESTFLIGHT.md` says "stays 1.0".
- **Sizes.** `AppModel.swift` is 759 lines (extensions pattern), `CarPlayController.swift` 852, `RequestRunner.swift` 1146. New work goes into new files and extensions, not these.

## 2. Customisation model *(call: one store, one screen per area)*

A new `Preferences` value (Codable, versioned) is stored in UserDefaults under one key per area. Unknown or invalid values fall back to defaults; it never crashes on a bad decode. It is owned by `AppModel+Preferences.swift` and observable, so the phone and CarPlay react live.

Settings gains four sections. Each opens its own screen file.
1. **Home & Library**: layout.
2. **Playback**: quality, ReplayGain, sleep timer.
3. **Downloads & Storage.**
4. **Scrobbling**: replaces the lone "Count plays" toggle, which moves here.

## 3. Home & Library layout

**Home sections.** These are reorderable (drag handles in edit mode) and hideable (toggle per row):

| Section | Source | Default |
|---|---|---|
| Jump back in | `albumList(recent)` | on, 1st |
| Made for you | ListenBrainz (only when a token is set) | on, 2nd |
| Recently added | `albumList(newest)` | on, 3rd |
| Most played | `albumList(frequent)` | on, 4th |
| Favourites | `albumList(starred)` | off |
| Random albums | `albumList(random)` | off |
| Playlists | `getPlaylists` | off |
| Genres | top genre groups (§4) | off |
| Downloaded | local downloads (§6) | off; shown automatically in offline mode |

- The "Finish setting up" card stays pinned on top while it applies; it isn't a section.
- Shelf size: 12 (unchanged), not configurable *(call)*.
- Empty sections are skipped as today.
- "Reset to default order" restores the table.

**Library rows.** These are reorderable and hideable: Playlists, Artists, Albums, **Songs** *(call: new, paged via the existing `songsPage`)*, **Genres** (new), **Favourites** (new: starred songs and albums), **Downloads** (new), Finds (only if set up), Requests (only if Lidarr is connected). The "Recently added" grid at the bottom gets a toggle (default on). At least one row must stay visible; the last visible row's toggle is disabled.

**CarPlay** uses the same home order and visibility. Sections the car can't show are skipped, while D12 limits still apply. The car's Library shows the visible rows in the same order, but always omits Requests and Songs (too long for driving; the car's Search covers songs) *(call)*.

## 4. Genres

**Data.** Use Subsonic `getGenres` (name, songCount, albumCount), `getAlbumList2 type=byGenre&genre=` and `getSongsByGenre` (paged). New NavidromeClient calls go to the dev stack ITs.

**Views.** The Library › Genres row has a segmented control: **Grouped** (default) | **All genres**.
- **All genres:** a flat A–Z list with album counts. Genres with zero albums and songs are hidden.
- **Grouped:** parent groups (e.g. Rock) expand to show their subgenres (Indie Rock, Alt Rock…), each with counts.
  - Tapping a **group** opens a group page: all albums whose genre is in the group (merged and de-duplicated), plus Play/Shuffle of the group's songs (capped at 500 songs, shuffled; the cap is a *(call)*).
  - Tapping a **subgenre** opens the genre page: albums plus Play/Shuffle.

**Grouping** *(call: no bundled third-party taxonomy)*. The beets tree derives from a Wikipedia scrape (CC BY-SA provenance) and Every Noise has no licence. Magpie instead ships its own small, hand-written rule table, `GenreGroups.swift`:
- About 16 parent groups: Rock, Pop, Electronic, Hip-Hop & Rap, R&B & Soul, Jazz, Blues, Classical, Country & Folk, Metal, Punk, Reggae & Ska, Latin, World, Soundtrack & Stage, Other.
- Assignment: first an exact alias map (e.g. "dnb" → Electronic, "alt-rock" → Rock), then ordered keyword rules (e.g. contains "metal" → Metal *before* "rock" → Rock; "hip hop"/"rap"/"trap" → Hip-Hop & Rap). Comparison is case- and diacritic-insensitive.
- Unmatched genres go to **Other**.
- Multi-value strings the server didn't split (`;`, `/`, `,`, ` & ` only when both halves match known rules) are split client-side for grouping only.

**Owner overrides:** on a genre's page, "Move to group…" lets the owner reassign it to any group, or to a new group they name. Groups can be renamed and hidden. Overrides are stored in Preferences and survive refreshes.

**CarPlay:** Library › Genres shows the groups, then the subgenres, then Play/Shuffle (D12 depth limits).

## 5. Playback quality, ReplayGain, sleep timer

**Quality** *(call: one compact model)*. There are three independent settings: **Wi-Fi**, **Mobile data**, **Downloads**. Each is one picker of presets:
- Original (no transcoding; `format=raw`).
- High: AAC 256 kbps.
- Medium: AAC 160 kbps.
- Low: AAC 96 kbps.
- Opus variants: High 192, Medium 128, Low 64.
- MP3 320 and MP3 192, for older servers.

Defaults: Wi-Fi Original, Mobile data AAC 160, Downloads Original.

These map to `stream?format=&maxBitRate=`.
- **Network** comes from `NWPathMonitor` (`usesInterfaceType(.cellular)`, or `isExpensive`).
- **When the network changes during playback,** the next songs use the new quality via `urlsInvalidated()`. The current song continues.
- **Format support.** The server's transcoding config decides what's possible. If a transcoded stream fails (HTTP error, or AVPlayer can't open it), Magpie falls back to Original for that song. It shows the hint "Your server couldn't convert this song; playing the original" once per session, in §5 voice.
- **Dev stack.** The Navidrome dev stack ITs verify that AAC, Opus and MP3 transcoding produce playable audio. If the dev image lacks ffmpeg for a format, the IT records the fallback path instead.
- "Low Data Mode" on: Mobile data quality is used even on Wi-Fi *(call)*.
- **Transcoded streams** *(call: accepted and documented)*.
  - Gapless is exact only for Original (encoder-delay metadata). Transcoded streams may have a tiny gap between songs.
  - Seeking uses `estimateContentLength=true`. Durations and the scrobble threshold use the API's song `duration`, never the stream's.
  - Downloads default to Original, so offline and car playback of downloads stays gapless.
  - Settings shows "Gapless works best with Original" under the quality pickers.

**ReplayGain:** Off | Track | Album (default **Track**). It uses OpenSubsonic `replayGain` (trackGain, albumGain, trackPeak, albumPeak) from song responses, applied as `AVMutableAudioMix` input-parameter volume.
- *(call)* **Attenuation only.** Positive gains are clamped to 0 dB, because AVPlayer volume can't exceed 1.0, and an audio tap would put gapless and CarPlay playback at risk. The range is −15 dB … 0 dB.
- Loud masters are levelled down. Quiet tracks play as recorded.
- Songs without tags play at unity gain.
- There is no pre-amp setting.

**Sleep timer:** on Now Playing (phone) and from a Settings default. Options are 15/30/45/60/90 minutes and "End of song". When it fires, playback pauses with a 5 s fade-out. It is also available in CarPlay's Now Playing as a button only if the template allows; otherwise phone only *(call)*.

## 6. Downloads and storage

**What can be downloaded:**
- a song;
- an album;
- a playlist (a snapshot of its songs at download time, refreshed when the playlist is opened with a connection) *(call)*;
- all Favourites, as a toggle: "Keep favourites downloaded".

Download buttons appear on album and playlist headers and in song context menus. A status line follows D3 (text plus symbol): "Downloaded", "Downloading 3 of 12", "Waiting for Wi-Fi".

**Kinds of stored audio** (one store, two kinds):
1. **Downloads** are kept until the owner removes them. They are never auto-evicted.
2. **Cache** holds pre-downloaded upcoming songs, plus recently played songs if "Keep recently played" is on. It is evicted least-recently-played first, under the cache limit.

**Settings (Downloads & Storage):**

| Setting | Options | Default |
|---|---|---|
| Download quality | from §5 | Original |
| Download on mobile data | toggle | off ("Waiting for Wi-Fi") |
| Downloads at the same time | 1–4 | 2 |
| Pre-download upcoming songs | 0–10 | 3 |
| Keep recently played songs | toggle | on |
| Cache limit | 500 MB, 1, 2, 5, 10 GB | 2 GB |
| Downloads limit | None, 5, 10, 20, 50 GB | None |
| Offline mode | Automatic / On / Off | Automatic |

The screen also shows storage used, with Remove all downloads and Clear cache (each behind a confirmation dialog).

**How they are saved** *(call)*:
- Files live in `Application Support/Magpie/Audio/<serverScope>/<sha256(songId+quality)>.<ext>` with a JSON index (song id, quality, size, kind, lastPlayed, downloadedAt).
- They are excluded from iCloud backup (`isExcludedFromBackup`).
- File protection is `completeUntilFirstUserAuthentication`, so the car can play with the phone locked.
- File names are never derived from server strings, which rules out path traversal.
- When the downloads limit is reached, new downloads stop with "Downloads are full" and nothing is evicted.
- Changing download quality doesn't re-download existing files *(call)*. A "Re-download at new quality" action exists.
- Sign-out removes all audio for that server scope, consistent with the sign-out privacy rule.

**Playback source:**
- Play order is: local download or cache hit → stream.
- A pre-download runs ahead of the queue position by N songs, using the current network's quality.
- **On mobile data, pre-download is always allowed** at the mobile quality. It fetches the same bytes streaming would, so the only extra data is songs that get skipped. **Only manual downloads** (and "Keep favourites downloaded") wait for Wi-Fi unless "Download on mobile data" is on *(call)*.
- **How songs enter the cache** *(call: no resource-loader or proxy, which protects the gapless path)*. Only pre-downloaded songs are cached. They are fetched by download tasks, never by capturing a stream.
  - "Keep recently played songs" means pre-downloaded songs stay in the cache after they've played, LRU, under the limit. When it's off, they are removed once played.
  - A song that was only streamed (pre-download 0, or reached before its pre-download finished) is not cached.
- **Local file versus stream** *(call)*. The engine decides when it enqueues an item. That happens about 20 s before the previous song ends (`topUp`), by which time N ≥ 1 pre-downloads have normally finished. An item already enqueued as a stream is never swapped mid-queue.
- The engine is `URLSession` background-capable download tasks, with concurrency per setting. They resume after relaunch where iOS allows.

**Offline metadata** *(call: no full library database)*. Each index entry also stores a metadata snapshot: song id, title, artist, artist id, album, album id, track and disc number, duration, genre, cover art id, plus the playlist ids it was downloaded with. Cover art for downloaded albums and playlists is saved alongside (one 600 px image per album). This is enough for offline browsing of what is on the phone. It is not a mirror of the server library.

**Offline mode:**
- **Automatic** switches on when the server is unreachable (existing failover/probe), and switches off on reconnect.
- **On** forces it.

While offline:
- Home shows the Downloaded section first, followed by nothing that needs the server.
- The Library shows only **Downloads**, which is browsable by Albums, Artists, Playlists and Songs from the snapshot, plus Genres built from the snapshot genres. Rows that need the server are hidden.
- Search searches the snapshot (downloads, plus cached songs listed as "Recently played on this phone").
- Cached songs play offline when reached through the queue or Recently played, but are not listed as downloads.
- Requests and Lidarr actions are disabled with "You're offline".
- CarPlay mirrors this: Home leads with Downloaded, and Library hides non-downloaded content.

## 7. Scrobbling

The Settings › Scrobbling section contains:
- **Count plays** (master toggle, existing default).
- **Send plays through Navidrome** (checkbox, default on).
- **Send plays directly to ListenBrainz** (checkbox, default off). It is enabled only when a ListenBrainz token is saved. It uses ListenBrainz `submit-listens` (`playing_now` and `single`) with the stored token.
- When both are on, the note reads: "If your Navidrome also sends plays to ListenBrainz, they'll be counted twice."
- **Counts as played after:** a percentage slider from 10% to 90% in steps of 5 (default 50%) **and** "or after" minutes from 1 to 10 or Never (default 4 minutes). Whichever comes first triggers. Songs under 30 s are never counted. The ListenBrainz and Last.fm rules are the defaults.
- **Now playing:** sent on start to each enabled destination.

**Rules:**
- **D29.** Finds are never scrobbled on either path. The same fail-closed `FindsIdentity` check runs before any submission. New tests cover the direct ListenBrainz path.
- **Listened time.** Measured as actual listened time, so seeks don't count towards the threshold.
- **Offline queue.** Plays made offline, or that failed to send, go to a persisted queue per destination: `scrobble-queue.json`, with song id, timestamp and metadata for ListenBrainz, max 500 entries, oldest dropped. It is retried on reconnect and at launch. Navidrome submissions carry the original `time` parameter; ListenBrainz gets `listened_at`.
- Sign-out clears the queue.

## 8. Network: plain http to the home server (essential)

**Requirement.** In Release and TestFlight, on both the phone and CarPlay, plain http must reach:
- `http://homeserver:4533`, a single-label name. Already verified on the real server (H4).
- `http://<private LAN IP>:4533`, i.e. 192.168/16, 10/8 or 172.16/12. **Not yet verified.**

**ATS spike result** (2026-10-28, Release build, iOS 27 simulator; scratchpad `ats-spike/report.md`). With `NSAllowsLocalNetworking` only:

| Address | Result |
|---|---|
| `127.0.0.1` | OK |
| `localhost` | OK |
| **private LAN IP `192.168.0.77`** | **OK** |
| `<name>.local` | OK |
| single-label name | OK |
| AVURLAsset stream from the LAN IP | OK |
| `100.64.x` IP | blocked (-1022) |

With `NSAllowsArbitraryLoads`, everything was OK. Adding a `ts.net` exception domain builds and leaves local results unchanged; it couldn't be exercised without a reachable ts.net host.

**Decision** *(call)*:
- Keep Release `NSAllowsLocalNetworking`. This satisfies the owner's essential requirement (short name **and** private LAN IP) without weakening ATS.
- Add `NSExceptionDomains { "ts.net": { NSIncludesSubdomains: true, NSExceptionAllowsInsecureHTTPLoads: true } }`, so Tailscale MagicDNS names (`http://<machine>.<tailnet>.ts.net:4533`) work away from home and in the car. WireGuard already encrypts that traffic.
- `atsBlocksPlainHTTP` stops refusing `*.ts.net`. The `100.64/10` IP literal stays refused, with the hint "Use your Tailscale name (….ts.net) instead of its 100.x address".
- `check-release.sh` asserts the exception exists, `NSAllowsLocalNetworking` is true, and there is no `NSAllowsArbitraryLoads` in Release.
- "Local IP" means the home server's private LAN address (192.168/16, 10/8, 172.16/12), which is what the owner asked for ("local network servers… as well as a local ip address").
- The private-IP and `.local` results come from the simulator. Device confirmation goes on the owner's TestFlight checklist (DNS and mDNS resolution of the short name and the Local Network prompt are device-only).

Either way:
- A Release-config app test pins the result. It asserts that `atsBlocksPlainHTTP` agrees with the bundle's ATS dictionary for each address class.
- `RUNBOOK`, `TESTFLIGHT` and `FLOWS` state exactly which address forms work.
- The Local Network permission prompt must be answered on the phone. If the first-ever launch comes from the car, the car shows "Open Magpie on your iPhone once to allow local network access" *(call)*.

## 9. CarPlay

The Apple carplay-audio entitlement is required on a device. It can't be granted by code. TestFlight upload policy:
1. Try a `--carplay` archive.
2. If signing fails because the entitlement isn't on the App ID, upload the non-CarPlay variant and tell the owner exactly how to request it.

The code must be complete and CarPlay-Simulator-verified regardless.

This round adds to CarPlay:
- Home order and visibility from Preferences (§3).
- Library rows from Preferences (minus Requests and Songs).
- Genres (§4).
- **Downloads** in Library, and the offline mode behaviour (§6).
- Playback uses local files when present (§6).
- The scrobbling rules (§7) apply unchanged.
- Locked-phone playback of downloads works, because of the file protection class.

Verification:
- CarPlay template-model unit tests (existing pattern).
- An Xcode simulator CarPlay external display run with screenshots: home, library, genres, downloads, offline and now playing.
- A device CarPlay check stays on the owner's manual list until the entitlement exists.

## 10. Version
- `MARKETING_VERSION` becomes **0.0.1**.
- The build number keeps increasing (`archive.sh --build N`, next N = 2, since build 1 was uploaded as 1.0) *(call)*. App Store Connect accepts a new, lower version train while no version has been approved. Build 1 (1.0) went to internal TestFlight testing only: no beta review, no approval. If the upload is still refused, report it to the owner. Never silently pick another version.
- `check-release.sh`, the `SettingsView` fallback, `TESTFLIGHT.md` and the MusicBrainz user agent (`Magpie/0.0.1`, derived from the bundle version) are updated.
- Tag: `v0.0.1`.

## 11. Security considerations (for the security review)
- **ATS (§8).** If arbitrary loads are enabled, the consent gate and its tests are the control, so review them adversarially.
- **Downloaded files:**
  - backup exclusion;
  - the file protection class;
  - no server-derived paths;
  - quota enforcement so storage can't be exhausted;
  - the index file is tolerant of corruption (corrupt → rebuild by scanning, never crash);
  - signed-out scopes are removed.
- **Scrobble queue:**
  - no credentials in the file;
  - bounded size;
  - D29 enforced on dequeue as well as on enqueue;
  - the ListenBrainz token is read from the Keychain only at send time.
- **Background downloads:**
  - no token in a URL that's logged;
  - Subsonic auth query parameters are redacted by the existing `Log` sanitiser;
  - verify the background-session URLs are never persisted in plain logs.
- **Preferences decode:** hostile or corrupt values fall back safely.

## 12. Process (owner's required steps)
1. ATS spike → finalise §8 (done 2026-10-28).
2. Design builder check (this document).
3. `writing-plans` → plan with tasks.
4. Subagent-driven build: an implementer per task, task review, and fix rounds.
5. Dedicated security review of the round, then a fix wave.
6. A FLOWS.md update covering every new flow, then flow verifiers that check the code against FLOWS and write tests.
7. Final tests:
   - `MAGPIE_IT=1 scripts/test-all.sh` twice green;
   - `check-release.sh` OK;
   - CarPlay simulator captures.
8. Merge to main, tag `v0.0.1`, archive with `--build 2` (`--carplay` if signing allows), and upload to TestFlight.
9. Report to the owner: the calls made, and the manual checks.

Guards unchanged:
- G0: tests only touch the dev stack. The owner's real servers are used only under the existing rules, and not this round unless needed for §8 *(call: not needed if the spike is conclusive)*.
- G1, D3, D12, D15, D29, §5 voice.

## 13. Left to the builder
- Exact file split within the existing patterns.
- The visual treatment of edit mode, consistent with the design language.
- The exact alias and keyword table contents for genres, within the rules above.
- Background URLSession versus foreground with resume, whichever meets "resumes after relaunch where iOS allows" with the least code.
