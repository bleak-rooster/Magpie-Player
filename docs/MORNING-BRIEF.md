# Magpie: morning brief

Branch `v1-build`, 58 commits ahead of `main`. Full how-to: `docs/RUNBOOK.md`. Every decision: `docs/decisions.md`.

## Where it stands
- **Highest milestone tagged: `m5`** (tags m0 to m5). Task 8.1 (edge cases) and 8.2 (security) are done and reviewed after it; they have no tag of their own.
- **Works:** sign in to Navidrome (multi-address failover), browse, play, queue, lyrics, library search; CarPlay Home / Library / Search with Now Playing; read-only Lidarr connect and audit; search that adds a "Not in your library" band; **Try** a song into Lidarr (new artist or existing), Requests screen with retries up to 24 h; Settings with the master "Allow Magpie to change Lidarr" switch and a change log.
- **Not built:** M6 Finds (separate folder, Keep / Not for me, CarPlay Try/Keep) and M7 polish (Immersive look, high-contrast tokens). I ran hardening first because you'd test the M5 path against real servers first.
- **Not seen by a human:** CarPlay UI (can't be driven headless). Please look.
- **Today's test is the simulator plus your real servers.** A build on your iPhone needs a signing team and, until Apple approves the CarPlay entitlement, a build without it (RUNBOOK section 4, "On a real iPhone"). Untested.

## Try this first (about 15 minutes)
1. `cd /Users/dev/Dev/navidrome_player && export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer && xcodegen generate && open Magpie.xcodeproj`. Scheme **Magpie**, simulator **iPhone 18 Pro**, Run.
2. Connect to your Navidrome (HTTPS if it leaves the house; self-signed cert needs `xcrun simctl keychain booted add-root-cert ca.pem`). Browse, play a track, try Search and lyrics.
3. In Settings turn **Count plays** off if you don't want test scrobbles.
4. Home › Finish setting up › **Connect Lidarr** (read-only summary). Read the summary against the pre-flight table in RUNBOOK section 2 (recycle bin, same music folder, Tubifarry).
5. Gear › Lidarr: switch on **Allow Magpie to change Lidarr** › **Set up Magpie in Lidarr** › choose root folder.
6. Search a song you don't own, tap **Try** (or **Ask for it**). Watch Requests, then Settings › Lidarr change log and Lidarr's Activity. It triggers real indexer searches.
7. Then CarPlay: DeviceHub › I/O › External Displays › CarPlay (RUNBOOK section 4).

## Decided overnight, without you
Each with the cost if I got it wrong.

**Scope and look**
- v1 is owner-only, direct to your Navidrome and Lidarr: no mailbox, Listener role, invites or Mac helper (D1). Cost: the shared-household idea waits for v2.
- Character dial stays in v1 (Classic, Signature, Immersive-lite), because you prioritised the look (D2). Cost: Immersive isn't built yet; M7 time.
- Round-record motif kept, but never alone: always text plus a symbol (D3). Library results rank first in search (D4). Cost: small visual compromise.
- Milestone order changed: **hardening (8.1, 8.2) before Finds (M6) and polish (M7)**. Cost: Finds mode isn't ready for your first test; Try goes straight into your library.

**Safety (your real servers)**
- Everything Magpie writes to Lidarr is behind one gate: off by default, allow-list only, logged before sending (G1). Never deletes in v1. Cost: some legitimate actions are refused until deliberately added.
- Tests only touch the local dev stack (D19). Cost: real-server behaviour is untested; see "check on your version" below.
- "Allow changes" and set-up are per Lidarr; connecting another Lidarr starts with changes off. Cost: a re-toggle.
- Plain `http://` to a public-looking address needs a consent tap; schemeless addresses default to https unless private. Cost: one extra tap; single-word host names count as home (a DNS hijack could slip past).
- Debug builds keep `NSAllowsArbitraryLoads` so you can test with hostnames over http. Cost: weaker OS-level protection in Debug (Release is local-only).

**Lidarr behaviour**
- **Omitted `addOptions.monitor: "none"`** when adding an artist: on Lidarr 3.2.0.5144 it unmonitors the artist and searches nothing. Cost: on a different Lidarr version the artist might monitor more than the one album. Check your first Try.
- AlbumSearch retries with backoff up to 24 h (about 25 searches per request). Cost: indexer load.
- A retry never re-monitors; if you unmonitored the album yourself the request stops as "Stopped in Lidarr". Cost: it won't override you.
- "Ready" means Navidrome lists the song, not that Lidarr imported it (D7). Cost: with different folder paths it never reaches Ready.
- Stop looking only unmonitors what Magpie monitored; a new artist stays in Lidarr. Cost: manual cleanup in Lidarr.

**Search and matching**
- Version words (Live, Acoustic, Remix, Demo) are kept, so you can Try other versions; housekeeping asides (Radio Edit, Album Version) count as the same song. Cost: a rare duplicate row, or a different radio edit merged with the album cut.
- A single name-only match hides the outside hit. Cost: an occasional missed not-yet row.

**Playback**
- A track that fails to load pauses and shows the error instead of skipping on. Cost: you tap Next.
- Auth URLs never hit disk caches. Cost: no URL caching for API calls.
- iOS-only code is guarded so `swift test` runs on the Mac. Cost: none.

**CarPlay**
- Tabs are lists only, at most two screens below a tab root; Now Playing shows the real cover (D12). Cost: less rich than a custom UI.
- Simulator builds carry the CarPlay entitlement in a way `codesign` shows as empty, by design.

**Other**
- Keep voice "Bringing it home" stays (D14); full disclosure instead of blander copy.
- No automatic expiry or deletes of finds (D10).

## Needs you
- **D13 App Store posture (OWNER TO CONFIRM):** full disclosure in Review Notes, remove tier names and "absent from App Review demo setups" copy from store builds, ship any Mac helper separately and disclosed, demo server with CC-licensed music only. Irrelevant to tonight's build; decide before any TestFlight.
- **CarPlay Keep button (M6):** D5 says Keep = release only with no sheet; D12 says use the system add-to-library button. A custom Keep glyph is clearer but a system add may be what App Review expects. Pick one before M6.
- **Real CarPlay on a device** needs Apple's CarPlay audio entitlement approval.
- **Do you want M6 (Finds) and M7 next?** Or fix what you find in the M5 path first?
- Check on your Lidarr: the monitored-albums result of the first Try (version difference above), and whether your recycle bin is set.
- Optional `sudo xcode-select -s /Applications/Xcode.app` so plain `xcodebuild` works.

## Known gaps and accepted risks
- Open Low items from the security review (L1 to L5, L7 to L12) and a list of parked minors are in `docs/reviews/security-v1.md` and `.superpowers/sdd/2026-10-27-magpie-v1/progress.md`.
- Accepted: AVPlayer follows redirects itself; http to private addresses isn't prompted.
- Navidrome allows about 5 logins per 20 s (429 after); wait if you reconnect repeatedly.

## How it was built
Design critiques (UX, accessibility, CarPlay/App Review, feasibility, devil's advocate) → triaged into decisions D1 to D20 → a decision review against the real Navidrome and Lidarr APIs (17 API corrections, safety guards G0 to G9, 10 blockers) → a plan with milestones → subagent build: a fresh implementer per task, then an independent reviewer per task, with fix rounds until clean → edge-case pass (8.1) and a read-only security audit (0 critical, 2 high, 6 medium, 12 low) with fixes and re-review (8.2).
- 20 tasks reviewed to clean: 19 build and hardening tasks, plus the security audit.
- 22 fix rounds across them (Task 5.3, the Lidarr request runner, took 5).
- About 420 test functions across the packages and app; 58 commits on `v1-build`.
- Run everything with `scripts/test-all.sh`. Re-run it before trusting any of this after your own edits.
