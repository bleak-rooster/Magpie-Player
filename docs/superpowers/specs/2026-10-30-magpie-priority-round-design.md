# Magpie 0.0.1: priority round (owner request, 2026-10-30)

Owner's six priority items, verbatim intent:
1. Downloads:
   - currently active downloads can be accessed, perhaps in Settings;
   - a downloaded song shows a notice next to it, and albums, playlists and artists too, with partial downloads made clear;
   - the download concurrency is selectable;
   - for now, downloads don't happen in the background, and the app is kept open.
2. Artists, albums, songs, genres and playlists get an alphabetic scroll index on the right.
3. An artist page makes clear whether the artist is in Lidarr. If not, offer to monitor them on Lidarr and start the download.
4. Album art goes into a cache, kept until actively deleted, along with playlist art and artist pictures. The user can delete all artwork cache data in Settings and reload individual artwork.
5. Home needs refreshing too often. It should feel seamless; the general design is good.
6. Lyrics in place of the art is good, but the lyrics area should be larger.

The owner delegated all decisions. The *(call)*s below are the controller's. Guards unchanged: G0, G1, D3, D12, D15, D29, §5 voice, the consent gate, offline (T14), and the owner-data rules (Magpie never alters Lidarr items it didn't add).

## P1. Downloads
- **Downloading now screen** *(call)*:
  - reached from a row at the top of Settings › Downloads & Storage ("Downloading now · 3", hidden when idle), and from a banner row at the top of Library › Downloads while anything is active;
  - lists running jobs (song, artist, progress bar plus "x of y MB"), then waiting ("Waiting for Wi-Fi" / "Waiting for a connection" / "Downloads are full"), then failed ("Couldn't download");
  - per-row actions: Cancel, and Try again (failed);
  - top actions: Pause all / Resume all, Cancel all (confirmed);
  - progress comes from URLSession task progress, published at most about 4×/s.
- **Downloaded marks** (D3: a symbol plus a VoiceOver label):
  - **Songs:** every song row (album, playlist, search, songs list, favourites, genre, queue) shows a small `arrow.down.circle.fill` when the song's file is on the phone as a download, and VoiceOver says "Downloaded". Cached-only songs show no mark *(call: only downloads count)*.
  - **Albums, playlists, artists** (tiles, rows and page headers):
    - fully downloaded: `arrow.down.circle.fill` plus "Downloaded";
    - partial: `arrow.down.circle.dotted` plus "k of m downloaded";
    - none: no mark.
  - **Artists** count over the artist's songs that Magpie knows from the downloads index and the artist's albums. On the artist list, the mark shows only "Downloaded" or "Some downloaded", because the full song count isn't known there *(call)*.
  - Marks update live when a download lands or is removed.
- **Concurrency:** "Downloads at the same time" is selectable 1–6 (was 1–4), applied live.
- **Foreground only** *(call)*:
  - When the app leaves the foreground (scenePhase background), running downloads pause: cancel in-flight jobs back to queued without counting an attempt.
  - They resume on return.
  - While anything is active, a banner on Downloading now and Library › Downloads says "Keep Magpie open to finish downloading".
  - New setting "Keep screen on while downloading" (default on) sets `isIdleTimerDisabled` only while downloads are running and the app is active, restoring it after.
  - Pre-downloads follow the same rule.
  - Playback continues in the background as normal.

## P2. Alphabetic index
- Artists, Albums, Songs, Genres (All genres A–Z; in Grouped, the groups list) and Playlists get a right-edge A–Z + "#" index *(call: the system `sectionIndexLabel`/`listSectionIndexVisibility` on iOS 27 if available; otherwise a custom index bar with drag, haptic tick and VoiceOver adjustable)*.
- Sections are grouped by the first letter, folded case- and diacritic-insensitively. Digits and symbols go under "#". A leading "The " is not ignored *(call: matches Navidrome's own sort)*.
- **Songs** (server-paged): tapping a letter jumps to the first song with that letter. Use the native API's sort plus a filter or offset lookup if Navidrome supports it; otherwise page forward until reached, bounded, with a spinner. The implementer verifies against the dev stack and documents.
- **Offline:** the index works over the downloaded catalog.
- D15: the index is reachable with VoiceOver (adjustable, "Letter index") and hidden at accessibility text sizes if it can't fit, with the list still usable.

## P3. Artist Lidarr status
- **Header line** on the artist page (when Lidarr is connected):
  - "In Lidarr · Monitored" (`checkmark.circle`);
  - "In Lidarr · Not monitored" (`pause.circle`);
  - "Not in Lidarr" (`plus.circle`).

  Matching is by MusicBrainz artist id when known, otherwise by name through the existing match index. Without Lidarr, nothing is shown.
- **Not in Lidarr → button "Add to Lidarr and download".**
  - A confirmation lists what happens: "Adds \(artist) to Lidarr, monitors their albums and starts searching. This may download a lot of music."
  - It goes through LidarrWriteGate (G1), and only when "Allow Magpie to change Lidarr" is on. When it's off, the button is replaced by "Turn on Allow Magpie to change Lidarr in Settings › Requests to add artists." with a link.
  - Uses the existing Magpie root folder and the Magpie quality/metadata profiles (provisioned in v1), monitor = all, then search for missing.
  - Records the artist in the ledger as Magpie-created (MBID-checked, T11/V-fix rules).
  - Status then shows "In Lidarr · Monitored · Searching…" and the existing request tracking.
- **In Lidarr but not monitored:** informational only. Magpie never changes artists it didn't add *(call: owner-data rule)*. If the ledger shows Magpie added it, offer "Monitor".
- Offline or forced On: the status line shows "You're offline", with no request.

## P4. Artwork cache
- A persistent disk cache for every artwork request (album, playlist, artist, CarPlay), under `Application Support/Magpie/Artwork/<scope>/<sha256(coverArtId|size)>`.
  - Excluded from backup.
  - File protection `completeUntilFirstUserAuthentication` (the car).
  - **Never keyed by a URL**: URLs carry auth.
  - Kept until the user clears it: no automatic eviction *(owner's words)*.
  - A cached image is served without a network request; online, nothing is re-fetched unless the user reloads.
- **Settings › Downloads & Storage**:
  - shows "Artwork · 84 MB";
  - "Clear artwork cache" is confirmed;
  - downloaded albums' covers (T12) are kept regardless.
- **Context menus:** album, artist and playlist rows, tiles and page headers get "Reload artwork", which drops that item's cached sizes and re-fetches.
- Sign-out removes the scope's artwork (privacy, consistent with downloads).
- **Offline:** cached art shows; uncached shows the placeholder art.

## P5. Seamless Home *(investigate first: superpowers:systematic-debugging)*
- Find why Home needs manual refreshes. Suspects:
  - a cancelled read now throws CancellationError (0a6d4da) and HomeView may record it as failed;
  - LoadKey churn at launch cancelling loads;
  - no persisted shelves, so launch starts blank;
  - failed sections only retrying on a key change.
- **Target behaviour:**
  - Last shelves are persisted per scope (small JSON of item ids, titles and cover ids, no secrets) and shown instantly at launch.
  - A background refresh replaces them silently.
  - CancellationError is never a failure.
  - Failed sections retry automatically, with backoff (5 s, 30 s, 2 min), on reconnect, and on returning to the foreground.
  - On foregrounding after more than 10 min, a silent refresh runs.
  - Pull to refresh still works.
  - The "Couldn't load X" line appears only after the retries fail.
  - No spinner flash when cached shelves exist.
- Tests reproduce the owner's symptom before fixing.

## P6. Bigger lyrics
- Lyrics mode expands the lyrics area to fill everything between the top bar and the scrubber:
  - the title and artist collapse to a single compact line above the scrubber;
  - Up next and the hint lines are hidden while lyrics show;
  - the transport and bottom row stay.
- Leaving lyrics mode restores the art layout.
- Still no page scroll at standard sizes (D43); lyrics scroll inside their area.
- Tests: at 375×667 the lyrics area is at least 1.6× the art slot's height, and everything fits.

## Process
- Three parallel implementers in isolated worktrees:
  - W1 = P1 + P4 (storage and settings);
  - W2 = P5 + P6 (Home and Now Playing);
  - W3 = P2 + P3 (lists and artist).
- Each is reviewed, then merged. The crash-hunt merge is reviewed separately.
- Then the full test-all, check-release, and build 10 (`--carplay`).
