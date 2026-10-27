# Magpie Runbook

Magpie v1 is an owner-only iOS 27 + CarPlay music app for your own Navidrome, with Lidarr for "Try this song". This page tells you how to run it against **your** servers. Details of what each milestone does are at the bottom (Reference).

Built so far: milestones M0 to M5 (sign in, browse, play, search, queue, lyrics, CarPlay library browsing, Lidarr connect, Try in "straight into your library" mode, Requests). Not built yet: see section 5.

## 1. Test on your own servers in 5 steps

**Step 1. Build and open it.** You need Xcode 27.1 at `/Applications/Xcode.app` and XcodeGen (`brew install xcodegen`).
```sh
cd /Users/dev/Dev/navidrome_player
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodegen generate
open Magpie.xcodeproj
```
In Xcode pick the **Magpie** scheme and the **iPhone 18 Pro** simulator (iOS 27.0 runtime), then press Run. Or from Terminal: `scripts/build.sh`.
- `xcode-select -p` currently points at the Command Line Tools, so bare `xcodebuild` and `simctl` fail. The scripts and the `export` line above work around it. To fix it for good: `sudo xcode-select -s /Applications/Xcode.app`. First run may also need `xcodebuild -runFirstLaunch` and accepting the license.

**Step 2. Connect to Navidrome.** The first screen asks for an address, user and password. Use an admin account if you want the pre-flight checks to be complete.
- Address: `https://music.example.com`, or `http://192.168.1.20:4533` on your LAN, or a Tailscale name. Several addresses are allowed (first one that answers wins). Include the base path if your proxy has one (`https://host/navidrome`).
- Typed without a scheme: it becomes `https://`, except private addresses (LAN, `.local`, single-word names, Tailscale 100.x), which become `http://`. A Tailscale MagicDNS name (`nas.tail1234.ts.net:4533`) becomes `https://`; Navidrome and Lidarr speak plain http on their own ports, so type `http://` in front (Connect says so if https fails).
- Plain `http://` to a public-looking address: Connect warns "This address isn't encrypted. Your password will be sent in the clear." and asks you to agree. The answer is remembered per address. Prefer HTTPS for anything outside your house.
- Self-signed certificate: Magpie does not trust it (playback would ignore any override). Install your CA in the simulator, then reconnect:
  `xcrun simctl keychain booted add-root-cert /path/to/ca.pem`
- Do not put `user:password@` in the address; it is refused.

**Step 3. Browse and play.** Tap "Start listening". Open an album, play a track, try Search, the queue (from Now Playing) and lyrics. Nothing is written to your servers yet, except scrobbles (see warnings in section 3: switch **Count plays** off in Settings if you don't want test plays recorded).

**Step 4. Connect Lidarr (read-only first).** Home › "Finish setting up" › Connect Lidarr. Enter the address and API key (Lidarr › Settings › General). Magpie checks the key and shows a summary: version, root folders and free space, whether Tubifarry was found, recycle bin, and Lidarr's health messages. Nothing is written. Read it (and section 2).

**Step 5. Allow changes, set up, and Try one song.**
1. Library › gear › Lidarr: switch on **Allow Magpie to change Lidarr** (off by default; per Lidarr).
2. Tap **Set up Magpie in Lidarr**. It creates only what is missing (section 3).
3. Choose **New music goes to** (your root folder; Magpie never guesses if you have several).
4. Search for a song you do not own. In the "Not in your library" band tap **Try** (or **Ask for it** if you have no Tubifarry). Watch Library › Requests. Then check **Settings › Lidarr change log** and Lidarr's own Activity page.

Start with one song by a small artist, preferably one you wouldn't mind seeing in Lidarr.

## 2. Pre-flight checks before you Try

Check these once; none of them need Magpie.

| Check | How | If it fails |
|---|---|---|
| Navidrome 0.64 or newer, and an admin login | Navidrome footer / About page | Older versions are untested. A non-admin works for listening but can't scan the library |
| Lidarr 3.x reachable from the Mac | Connect Lidarr shows its version | v1 was verified on 3.2.0.5144 (develop channel). 3.1.x should work. See the monitor note in section 3 |
| Lidarr recycle bin set | Lidarr › Settings › Media Management › Recycle Bin (the Connect Lidarr summary shows "deletes are permanent" if unset) | Set one. Magpie v1 never deletes, but you may |
| Same music folder seen by both | Compare Lidarr's root folder path with Navidrome's library path | v1 has no path mapping. If they differ, a song never becomes **Ready** even though Lidarr imported it (Magpie checks that Navidrome lists it) |
| Subsonic connection works | Connect succeeded and Home shows shelves | Check the base path and that the address returns Subsonic JSON, not a login page |
| `songLyrics` extension | Lyrics button appears in Now Playing | Without it the lyrics sheet is hidden. Not a fault |
| Last.fm agent (top songs) | Artist screen shows "Popular" | Hidden when your server has none. Not a fault |
| Tubifarry | Connect Lidarr summary says found / not found | Found: speed **Standard** ("Try it", live wait screen). Not found: **Patient** ("Ask for it", shows up later in Requests) |

## 3. What Try does to your Lidarr, exactly

The whole write list, nothing else is ever sent:
- **Set up Magpie in Lidarr** creates, only if missing: quality profiles *Magpie Fast Start* and *Magpie Lossless*; metadata profiles *Magpie Finds* and *Magpie Albums+EPs*; tags `magpie` and `magpie-find`. If a profile with one of those names exists with different settings, set-up stops and tells you. Nothing you already have is edited.
- **Try, artist already in Lidarr:** Magpie picks the smallest release by that artist containing the song, sets just that one album to monitored (`PUT /album/monitor`) and starts an `AlbumSearch`. The artist, its profile and tags are not touched.
- **Try, new artist:** one `POST /artist` to your chosen root folder with *Magpie Fast Start*, metadata profile *Magpie Finds*, tag `magpie`, "monitor new items: none", only that release monitored, search on add.
- **The `addOptions.monitor` deviation:** the design said to send `addOptions.monitor: "none"`. On Lidarr 3.2.0.5144 that unmonitors the artist and searches zero albums, so Magpie leaves it out. Result: the artist stays monitored, new items are not monitored, and only the one album is. If your Lidarr is a different version, check the artist in Lidarr after your first Try that its monitored albums are only the one you asked for.
- **Searching:** if nothing is found, Magpie sends `AlbumSearch` again after 1 min, 5 min, 15 min, then hourly, giving up after 24 h (about 25 searches per request, at most 5 requests active at once). That is real load on your indexers.
- **Never deletes.** v1 sends no delete to Lidarr for Try. **Stop looking** unmonitors an album only if Magpie was the one who monitored it. An artist Magpie added stays in Lidarr; remove it there yourself if you want it gone.
- **Change log = undo map.** Every write (method, path, body, no secrets) is recorded on the phone before it is sent: Settings › Lidarr change log. Magpie also keeps an on-device ledger of albums it touched, per Lidarr (address + key).

**Warnings (B8, B9):**
- Try causes **real indexer searches and downloads** on your Lidarr and adds artists to your library root. Look at the change log afterwards.
- **Count plays** is on by default: plays are scrobbled by Navidrome to your ListenBrainz/Last.fm. Turn it off in Settings while testing if you don't want that.
- The first Try goes straight into your library (there is no separate Finds folder yet, so the Try sheet says so).

## 4. CarPlay in the simulator

**CarPlay was not visually verified overnight.** It is covered by unit tests of the templates and a clean-launch check, but nobody has watched it run, because the CarPlay window can't be driven from the command line. Please look at it.

1. Run Magpie in the iPhone 18 Pro simulator and sign in (Step 1 to 2).
2. Open **DeviceHub** (`/Applications/Xcode.app/Contents/Applications/DeviceHub.app`; older Xcodes: Simulator). Menu **I/O › External Displays › CarPlay**.
3. Tap Magpie on the CarPlay home screen. Check: three tabs (Home, Library, Search); Library › Albums › an album › a track plays and Now Playing shows the cover with Shuffle and Repeat; Search › "Type a search" opens the keyboard; after signing out, Home says "Not set up on this iPhone yet".
4. Driving limits (only if your CarPlay window offers them): "Type a search" turns disabled ("Unavailable while driving") and long lists end with "Showing n of m".
- Device only: cold launch with a locked phone, and real head-unit artwork.
- CarPlay on a physical phone needs Apple's approved CarPlay audio entitlement in your provisioning profile; the simulator doesn't.

**On a real iPhone (not tested; the overnight test path is the simulator plus your real servers).** The project has no signing team (`DEVELOPMENT_TEAM: ""` in `project.yml`) and always applies `App/Magpie.entitlements`, which asks for `com.apple.developer.carplay-audio`. Until Apple approves that entitlement for your team, signing a device build fails with "provisioning profile doesn't include com.apple.developer.carplay-audio". To build for your phone without CarPlay:
1. Plug in the phone (Developer Mode on) and find your team id (Xcode › Settings › Accounts, or developer.apple.com › Membership).
2. Build and install with the team set and the entitlements file left out. Command-line overrides beat `project.yml` and survive `xcodegen generate`:
   ```sh
   export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
   xcodegen generate
   xcodebuild build -project Magpie.xcodeproj -scheme Magpie -configuration Debug \
     -destination 'generic/platform=iOS' -allowProvisioningUpdates \
     DEVELOPMENT_TEAM=YOURTEAMID CODE_SIGN_ENTITLEMENTS=
   ```
   Then run it from Xcode on the phone, or install the built app with Xcode › Window › Devices and Simulators. In the Xcode UI instead: target Magpie › Signing & Capabilities › pick your team, and in Build Settings clear **Code Signing Entitlements**. `xcodegen generate` resets both, so redo them after each generate (do not commit them).
3. Without the entitlement the app runs on the phone but never appears in CarPlay. With Apple's approval, keep `CODE_SIGN_ENTITLEMENTS` as is and just set the team.
- The bundle id `com.bleak-rooster.magpie` must be free for your team; if Xcode says it is taken, add `PRODUCT_BUNDLE_IDENTIFIER=com.yourname.magpie` to the command (Keychain items then start empty: sign in again).
- First device launch after a reboot before unlocking (CarPlay cold start) waits for the unlock, then restores Navidrome and Lidarr.

## 5. Known limits, risks and troubleshooting

**Not built yet** (overnight order was hardening before features):
- **M6 Finds**: a separate Finds folder, Keep / "Not for me", the Finds tab, CarPlay Try and Keep.
- **M7 polish**: Immersive look, Increase Contrast tokens, more themes, Finds on CarPlay, Siri.
- Also missing: Up Next list and Downloaded in CarPlay, path mapping, Live Activity, mailbox/Listener/invites (v2).
- Some small review items were parked, not fixed (listed in the SDD ledger).

**Accepted security risks** (docs/reviews/security-v1.md):
- Debug builds allow `http://` to any host name (so you can test with a hostname); the in-app consent prompt is the protection, not the OS.
- Plain `http://` to private/LAN addresses is not prompted; on a hostile network reusing your LAN range, an impostor server could get the password. Single-word host names (`music`, `nas`) count as home network.
- AVPlayer follows redirects itself, so the same-origin redirect rule covers browsing and artwork, not streams.
- Use HTTPS for anything that leaves your house. Plain http sends the password at sign-in, a replayable token on every stream URL and the Lidarr API key (full control of Lidarr).

**Navidrome login rate limit:** about 5 logins per 20 seconds, then **429**. If you reinstall and reconnect repeatedly, wait 20 s. Same for `scripts/it.sh` runs.

**Troubleshooting**
- LAN address times out but opens in Safari on the Mac: System Settings › Privacy & Security › Local Network, allow Xcode / Simulator. `localhost` in the simulator is the Mac.
- "Doesn't look like a music server": the address answered with a web page (router, captive portal, proxy login). Check the address and any proxy base path.
- Behind a reverse proxy at a sub-path, include the path in the address (`https://host/navidrome`, `https://host/lidarr`). If a proxy returns an HTML login page, Magpie shows an error instead of crashing; fix the proxy's auth (API paths must be reachable with the Subsonic/Lidarr credentials).
- Lidarr says wrong key: re-copy from Lidarr › Settings › General.
- Song stays "Bringing it home": see the path mapping row in section 2; after 20 minutes it says "Not showing up in your library yet" with **Check again**.
- Untrusted certificate: see Step 2.
- Disconnecting Lidarr, signing out, or connecting a different Lidarr turns the change switch off and forgets set-up; a new Lidarr always starts with changes off.

## 6. Dev stack and tests

- **Dev stack** (throwaway local Navidrome + Lidarr with a fixture library, bound to 127.0.0.1): see `dev/README.md`. `dev/bootstrap.sh` starts and configures it, `dev/smoke.sh` checks every API the app uses. Needs Docker, curl, jq, openssl, ffmpeg. Tests only ever talk to localhost (a dev marker is required); never your real servers.
- `scripts/test-all.sh`: package tests (`swift test` in `Packages/MagpieKit`) then app unit and UI tests on the iPhone 18 Pro simulator. `scripts/test-packages.sh` and `scripts/test-app.sh` run each half. `scripts/build.sh` builds only.
- `scripts/it.sh`: integration tests against the dev stack (`MAGPIE_IT=1`). `MAGPIE_IT=1 scripts/test-app.sh` adds the app flows. Wait about 20 s between runs (login rate limit).
- `Magpie.xcodeproj` and `App/Info.plist` are generated from `project.yml` (`xcodegen generate`) and are git-ignored.

---

# Reference: what each milestone does

## Details by milestone
- M5: Try (fallback mode) and Requests. **This is the path to test against your own Lidarr first.** It writes to Lidarr, so read the warnings below before you start.
  - **Settings** (Library › gear, replaces the account menu): Appearance (Signature; more looks in M7), Servers (addresses, signed-in user, Sign out), Lidarr (Connect / summary, "New music goes to" root folder, Speed, **Allow Magpie to change Lidarr**, **Set up Magpie in Lidarr**, **Lidarr change log**), ListenBrainz token (optional, Keychain only, sent only to api.listenbrainz.org), **Count plays**, About.
  - **Allow Magpie to change Lidarr** (G1) is off by default. Every Lidarr write goes through one gate that checks it, refuses anything not on its allow list, and logs method, path and body (no secrets) to the on-device change log before sending (Settings › Lidarr change log, newest first; it is your undo map).
  - **Set up Magpie in Lidarr** (needs the switch on) creates, only if missing, the quality profiles *Magpie Fast Start* and *Magpie Lossless*, the metadata profiles *Magpie Finds* and *Magpie Albums+EPs*, and the tags `magpie` and `magpie-find`. Same-named profiles with other settings stop it with a message; nothing you already have is changed.
  - **New music goes to**: with one Lidarr root folder it is used; with several you pick one (Magpie never guesses). Finds (a separate folder) arrive in M6, so everything goes straight into your library and the Try sheet says so.
  - **Try** on a "Not in your library" song: unavailable, with the reason and an Open Settings button, until the switch is on, set-up has run and a root folder is chosen. Speed tier: **Standard** when Tubifarry is found ("Try it", then the wait screen: Looking › Spotted it › Bringing it home › Ready, real % while you watch; "Leave" keeps it going), otherwise **Patient** ("Ask for it", a confirmation, no spinner; it shows up in Requests). Plain Lidarr is Patient.
  - What Try does in Lidarr: MusicBrainz is asked once for the song's releases (1 request/s). If the artist is **already in your Lidarr**, Magpie picks the smallest release that artist already has with the song, monitors that one album (`PUT /album/monitor`) and starts an `AlbumSearch`; the artist, its profiles and tags are never touched (A7, G6). If the artist is **new**, one `POST /artist` adds it to the chosen root with *Magpie Fast Start*, *Magpie Finds*, tag `magpie`, "monitor new items: none" and only that release monitored, searching on add (A6). Every album Magpie touches is recorded in the on-device ledger first. At most 5 requests at a time; the same song or release joins the request already running.
  - **Ready** means your library lists the song: after Lidarr imports, Magpie starts a quick library scan (`startScan`, no path mapping) and refreshes its match index (at most every 30 s) until the song shows up. A notification says so while the app is running. Polling: every 5 s in the foreground, 30 s otherwise; requests are saved and resume after a relaunch.
  - **Requests** (Library › Requests): In progress / Ready / Needs attention. "Still looking" after a search finds nothing for 10 minutes; Magpie searches again after 1 min, 5 min, 15 min, then hourly, and gives up after 24 h; a retry only searches again (no new MusicBrainz lookup, no re-monitoring), and if you unmonitored the album in Lidarr meanwhile the request stops as "Stopped in Lidarr" without writing anything. An import Lidarr blocks or fails waits with Lidarr's short note. Imported but not listed by the library after 20 minutes: "Not showing up in your library yet" (scans and index refreshes back off before that, and stop then) with **Check again**. Requests and the ledger are kept per Lidarr server (address + API key), so connecting another Lidarr never acts on the first one's albums. **Stop looking** (swipe or the request screen) unmonitors the album only if Magpie monitored it, and never deletes anything (for a new artist it keeps checking for 10 minutes, because Lidarr applies the monitoring when its refresh finishes).
  - **Count plays** (G8) on by default: plays are scrobbled by your server to your listening history. Off: no scrobbles.
  - Against the dev stack: `scripts/it.sh` runs `TryIT.fallbackOnDevStack` (checks the dev markers, sets up Magpie, Trys Judie Tzuke "Harbour Lights": new artist added to `/music/library` with the right profiles, tag and only that album monitored; Stop looking unmonitors it; then deletes only that artist with `deleteFiles=false`). It needs internet (MusicBrainz, Lidarr's metadata server) and prints SKIP without it. The dev Lidarr has no indexers, so nothing downloads. `MAGPIE_IT=1 scripts/test-app.sh` also runs `testSettingsShowLidarrControlsAndRequests` (read-only).
  - **Before you Try on your real Lidarr (B8, B9):**
    - Try triggers **real indexer searches and downloads** on your Lidarr, and adds artists to your library root. Look at the change log afterwards.
    - Turn **Count plays** off while you test if you don't want test plays scrobbled to your ListenBrainz/Last.fm.
    - Lidarr and Navidrome must see the same music folder (no path mapping in v1). If the song never becomes Ready after Lidarr imported it, check that Navidrome's library includes Lidarr's root folder.
    - To undo an add: the change log lists each write; remove an artist Magpie added in Lidarr itself (Magpie never deletes in this mode).
- M4: Lidarr (read-only) and merged search. Home's "Finish setting up" card opens **Connect Lidarr** (address + API key, kept in the Keychain next to the session; Sign-out forgets it): it checks the key against `/system/status`, then shows a read-only summary (version, sign-in on/off, root folders with free space, Tubifarry found or not, recycle bin set or "deletes are permanent", Lidarr's health messages) and offers Disconnect. Nothing is written to Lidarr. After sign-in (and at launch) the **match index** loads its last snapshot (Application Support/Magpie/MatchIndex/<hash of server+user>.json, written atomically, excluded from device backups) and rebuilds in the background from `/api/song` (pages of 1000 sorted by id, missing files skipped); search never waits for it. **Search** now runs the library (3 s), ListenBrainz labs (5 s, no credentials) and, when connected, Lidarr's search (5 s) in parallel: library rows appear as soon as the library answers, the top result is always from the library, and a "Not in your library" band follows with songs (round record, "Not in your library" + symbol, Try), artists and albums. Outside hits the library already has are dropped (match ladder: recording MBID 1.0, ISRC 0.95, artist MBID + title + ≤3 s 0.9, normalised artist + title + ≤3 s 0.8; a name-only match counts only when exactly one library song has that name and the title isn't marked as another version; version words such as Live, Acoustic, Remix, Demo, Edit stay in the name, so "Halo (Live)" is offered even when the library has the studio "Halo"; housekeeping asides such as Radio Edit, Album/Single Version and Original Mix count as the same recording), and repeats collapse to one row per artist + title. A source that fails or runs out of time adds nothing. Try opened a placeholder in M4 (replaced in M5). MusicBrainz is not called from search. CarPlay search is still library only.
  - Against the dev stack: `MAGPIE_IT=1 scripts/test-app.sh` also runs `testConnectLidarrShowsSummary` (passes `LIDARR_URL`/`LIDARR_API_KEY` from `dev/.env.local`, localhost only); `scripts/it.sh` runs `MatchIndexIT` (builds the index from the dev Navidrome and matches its own songs by MBID and by name). Not-yet results need internet (ListenBrainz labs, Lidarr's metadata server), so they are checked by unit tests, not against the dev stack.
- M3: CarPlay (library). Tabs Home · Library · Search, all list roots. Home: Jump back in, Recently added, Most played (4 albums each). Library: Playlists, Artists, Albums. Search: "Type a search" (pushes the car's search keyboard; shown disabled with "Unavailable while driving" when the car withholds the keyboard) and Recent searches (shared with the phone; tap re-runs the search as a list). Album and playlist screens list tracks (tap plays from there and opens Now Playing; Shuffle row); the artist screen plays an album on tap instead of pushing its tracklist, so browsing never goes deeper than tab root + 2 (Now Playing and Up Next always fit). Now Playing is the system template: real square cover, Shuffle and Repeat buttons, mini player on. Lists are built off the main thread; a list on screen is only updated in place (playing indicator, detail text), and a change of shape waits until it is off screen. Long lists end with a "Showing n of m" row instead of stopping silently. Cold launch from the car works without the phone UI: the scene restores the saved session; before first unlock it shows "Locked until this iPhone is unlocked", signed out "Not set up on this iPhone yet", and a library that doesn't answer "Your library is out of reach". Not yet: Finds tab (M7), Siri and the assistant cell, Up Next list, Downloaded.
- M2: search, queue, lyrics. Search tab searches the library as you type (250 ms pause, in-flight searches cancelled): Top result (best name match, else the first song), Songs, Artists, Albums, with All/Songs/Artists/Albums scopes and Recent searches (kept on the device, Clear). Tap a song to play the results from there; long-press for Play Next / Add to Queue. Queue sheet (from Now Playing): Now playing, Shuffle and Repeat (off / all / one) toggles, Up Next, Playing next; Edit gives drag handles, swipe removes, Clear drops everything after the current song. Lyrics sheet appears only when the server advertises `songLyrics`; synced lines follow the playback position (tap a line to jump), unsynced lyrics are plain text, empty state "No lyrics for this song". Network sessions are ephemeral with no URLCache, so Subsonic auth URLs never reach disk.
- M1: sign in, browse, play. Connect (one or more addresses, first answering wins; credentials and addresses in the Keychain, restored on launch; Sign-out clears them), tabs Home · Library · Search, Home shelves (Jump back in / Recently added / Most played) and a "Finish setting up" card, Library (Playlists, Artists, Albums, Recently added), Album, Artist (Popular hidden when the server has no top songs), Playlist, mini player and Now Playing (scrubber, star, Lossless hallmark, lyrics and up-next panels). Address failover mid-session: a connection error re-probes the addresses, rebuilds the client and the player's stream URLs. Signature and Classic looks (`-MagpieCharacter classic` launch argument).
  - Against the dev stack: `dev/` stack running (`http://127.0.0.1:4533`), then `MAGPIE_IT=1 scripts/test-app.sh` runs `BrowseFlowTests` (signs in, opens the first album, plays track 1, checks the mini player). The script reads the URL and admin credentials from `dev/.env.local` (dev marker and localhost required, G0) and passes them as `TEST_RUNNER_MAGPIE_IT_*`; nothing is committed. By hand: run the app in the simulator and sign in with `http://127.0.0.1:4533` and the `NAVIDROME_ADMIN_*` values from `dev/.env.local`.
- M0 — app launches to Connect: package skeleton, XcodeGen app shell, placeholder Connect screen, CarPlay scene delegate stub. Nothing else yet.
- MagpieCore primitives: `ServerEndpoint` (base-path-preserving URLs, failover), `HTTPTransport` / `URLSessionTransport`, `MockTransport` (in `MagpieTestSupport`), `Redactor`, `Log`, `KeychainStore`, `AtomicFile`.

## CarPlay simulator
Not automatable from the command line: the CarPlay window is a GUI menu item (UI scripting needs Accessibility permission for the terminal), and `simctl io` can't attach a CarPlay display. By hand:
1. `scripts/build.sh`, then run Magpie in the "iPhone 18 Pro" simulator (Xcode › Run, or `xcrun simctl install booted <DerivedData>/Build/Products/Debug-iphonesimulator/Magpie.app && xcrun simctl launch booted com.bleak-rooster.magpie`). Sign in (dev stack: `http://127.0.0.1:4533`, `NAVIDROME_ADMIN_*` from `dev/.env.local`).
2. In Xcode 27 the simulator window lives in **DeviceHub** (`/Applications/Xcode.app/Contents/Applications/DeviceHub.app`; older Xcodes: Simulator). Choose **I/O › External Displays › CarPlay**. Magpie appears on the CarPlay home screen; tap it.
3. Check: the three tabs; Library › Albums › an album › a track plays and Now Playing shows the cover with Shuffle and Repeat; the Search tab's "Type a search" opens the keyboard search; Home after signing out shows "Not set up on this iPhone yet".
4. Driving restrictions, where the CarPlay window offers them (limited keyboard / limited lists): the "Type a search" row turns disabled with "Unavailable while driving", and long lists end with "Showing n of m". Otherwise check this in a car.
- Entitlement: simulator builds carry `com.apple.developer.carplay-audio` in the simulated-entitlements section (`__TEXT,__entitlements`), not in the ad-hoc signature, so `codesign -d --entitlements -` shows an empty dict; that is expected. Check with `otool -X -s __TEXT __entitlements <Magpie.app>/Magpie` (hex of the plist) or the build's `Magpie.app-Simulated.xcent`. Putting the entitlement into the ad-hoc signature (`ENTITLEMENTS_DESTINATION=Signature`) makes the launch fail (`OS_REASON_EXEC`), so don't.
- Can't be tested in the simulator (device only): cold launch with the phone locked before first unlock; real head-unit artwork transparency.

## Connecting to a real server
- Self-signed HTTPS (B3): Magpie does not override certificate trust (AVPlayer would ignore it). Install your CA into the simulator with `xcrun simctl keychain booted add-root-cert <ca.pem>` (on a device, install and trust a profile). Connect says so when it sees an untrusted certificate.
- LAN address times out (B4) but opens in Safari on the Mac: check System Settings › Privacy & Security › Local Network for Xcode/Simulator. `localhost` in the simulator is the Mac.
- **Use HTTPS (a reverse proxy) for any address that leaves the house.** Plain `http://` sends the Navidrome password at sign-in, a replayable token on every stream URL and the Lidarr API key (full control of Lidarr) unencrypted.
- Plain HTTP outside the home network works only in Debug builds (B2); Release asks for HTTPS. Debug deliberately keeps `NSAllowsArbitraryLoads` (security review M2 ruling) so owner testing can use `http://` host names. The mitigation is in the app, not ATS: before the password or the Lidarr key goes over plain `http://` to an address that isn't loopback, LAN (10/8, 172.16/12, 192.168/16), link-local, `.local`, a single-label name, CGNAT/Tailscale (100.64/10) or IPv6 unique/link-local, Connect asks "This address isn't encrypted. Your password will be sent in the clear." The answer is remembered per address (scheme, host, port) in the app's settings.
- Addresses typed without `http://` or `https://` become `https://`, unless they are private (as above), which become `http://`. Addresses with `user:password@` are refused: enter credentials in their own fields.
- Before signing in, the address must answer `rest/ping` like a Subsonic server (`subsonic-response` with status ok, or failed with an authentication/missing-parameter error, which is how Navidrome answers a ping without credentials). A router, captive portal or proxy page that answers 200 gets nothing; Connect says the address "doesn't look like a music server".
- Redirects are followed only within the same scheme, host and port; a redirect elsewhere (or https to http) is refused and shows as an error.
- "Allow Magpie to change Lidarr" and the Lidarr set-up (profiles, tag, root folder) belong to one Lidarr (address + API key). Disconnecting Lidarr, signing out, or connecting another Lidarr turns the switch off and forgets the set-up; a newly connected Lidarr always starts with changes off.
