# Magpie round 13: plan (owner list of 2026-11-03)

The owner sent this list after build 12. The owner numbered "5" twice, so it is renumbered 1–14 here. The owner delegates design decisions (customisation-round memory); the calls made are marked **Decision**. The round ends with the **full test suite**, including the dev-stack tests (MAGPIE_IT=1). It was deferred at build 12. Then build 13.

## 1. Aurral: sign in with username and password, not an API key
- **The ask.** Aurral playlists are per user, so Magpie signs in as a user, and the API-key option is removed.
- **Plan.**
  - Research Aurral v2.10.0's user auth from the GitHub source at the v2.10.0 tag: the login route, the session cookie or JWT, its lifetime and refresh, and how the playlist and flow endpoints scope to the signed-in user.
  - Then **Settings › Accounts & Servers › Aurral** takes a URL, a username and a password.
  - The session token goes in the Keychain. The password is stored only if needed to re-login, in the Keychain under the same class, never logged.
  - Re-login happens on 401.
  - Sign-out clears everything.
- The five-call allow-list stays, plus the login and logout routes. The no-redirect rule for authorised requests stays.
- The API-key field and its stored key are removed; a stored key is deleted on upgrade.
- **Tests:** login, expiry and re-login, wrong password, user scoping (stub), migration that deletes the old key, redaction.

## 2. Pull to refresh shows "can't be loaded"
- **The bug.** Pull to refresh shows an error, and a second pull loads the page. It is most likely the refresh task's cancellation, or the reload racing the scan, being treated as a failure (Y3 refresh).
- **Plan.**
  - Reproduce it in a UI test on the dev stack (RED).
  - A cancellation or superseded load is never an error.
  - The refresh keeps the current content visible until new content arrives.
  - It shows an error only if the final load really fails.
- Covers Artist, Album and Playlist pages, and any other page with pull to refresh.

## 3. CarPlay: five letter groups in Artists, Songs and Albums
- **The ask.** Jump quickly by groups of letters.
- **Constraint.** CarPlay doesn't let an app put custom controls on the left edge. The left side is the system's tab and app area.
- **Decision.**
  - Artists, Songs and Albums (all albums) open on a **group screen** with five rows: **A–E, F–J, K–O, P–T, U–Z & #**. Each row shows its count.
  - Tapping a group opens that group's list, which keeps CarPlay's letter scrubber.
  - This replaces the over-limit-only letters screen from Y2 and applies always.
  - Depth stays within 5 (D12).

## 4. CarPlay: albums newest first
- **Decision.** The All Albums group screen gets a first row, **Newest**: every album, newest first, paged.
- Inside each letter group, albums are sorted newest first, as the owner asked, and the group is still filtered by letter.
- The release date comes from `year` and `created`.

## 5. Home still shows the wrong things
- **Symptoms:**
  - Discover is sometimes replaced by random albums;
  - the Playlists section disappears;
  - Playlists sometimes shows random albums.
- **Plan.**
  - Systematic diagnosis first: reproduce on the dev stack with an Aurral stub. Also run a read-only check against the owner's Navidrome; GETs only.
  - Suspects:
    - the shelf cache keyed by position, or the stale-kind guard not covering Discover and Playlists;
    - the Discover and Playlists split (Y6 `isDiscoverPlaylist`) racing the Aurral library load;
    - the Discover section falling back to another loader when Aurral is slow or unauthenticated;
    - the section→loader table after Y6 added Discover.
- Fix the root cause. Add regression tests for each symptom, including Aurral slow, down and signed out, and a cache from build 12.

## 6. Downloads in Lidarr: restart anything, with a warning
- **The ask.** Restart any download, including ones Lidarr or Magpie didn't start, and including downloads that aren't progressing (not only import-blocked ones). Restart means remove + blocklist + search again.
- **Decision.** This supersedes D49's refusal of not-grabbed items: the owner asks for it explicitly.
  - Every queue row offers **Restart**.
  - Rows **not started by your library** (no grab history) need a flagged confirmation: "This download wasn't started by your library — it may belong to another app. Restart anyway?"
  - Rows that are stalled or not progressing (downloading, no progress past the limit, or Lidarr's own stalled or warning status) get Restart directly.
  - Restart all covers stalled, failed and couldn't-import items. It never includes another app's downloads unless the owner turns that on in its confirmation.
- **Gate.** `queueRestartAny` keeps the exact query and the fresh re-read. It refuses only importing or imported items. A not-grabbed item needs an explicit `allowForeign` flag that only the flagged confirmation sets. The search after it runs only for an album id the queue row names. Pinned in check-writes.
- **Tests:** a foreign item without the flag is refused, and with it allowed; a non-progressing item; importing still refused.

## 7. Playback: replace a cached copy that isn't the right quality
- **The ask.** If a song is played from the cache at a different quality than the current stream setting for the connection (Wi-Fi or cellular), fetch the right version (transcoded or original) and replace the cached copy.
- **Decision.**
  - Applies to the **cache** only.
  - **Downloads** (songs saved on purpose) keep the quality they were downloaded at.
  - Playback starts from the cached copy immediately. Its quality is known (stored format and bitrate) and is compared with the target for the current network.
  - On a mismatch, a background fetch at the right quality replaces the cache entry. The swap happens on the next play, never mid-song.
  - Nothing is refetched on cellular when cellular downloads are off. Bounded: at most one replacement fetch at a time.
- **Tests:** mismatch → refetch and replace; match → nothing; network change; cellular off; a download is never replaced.

## 8. Now Playing says where the song comes from
- **Decision.** The source line reads one of:
  - **Downloaded** (saved on this iPhone);
  - **From cache** (temporary copy);
  - **Streaming**.
- It is combined with Y3's quality text, for example "Streaming · Transcoded · Opus 160 kbps (from FLAC)" or "Downloaded · Lossless · FLAC 16/44.1".
- Song info shows the same.
- Tests for each source; Now Playing still never scrolls.

## 9. CarPlay: the queue from Now Playing
- Enable CarPlay's **Up Next** button (`isUpNextButtonEnabled`, top right). It opens a list of the queue: the current song marked, tap to jump.
  - The list is limited to CarPlay's item limit, and shows a "Showing N of M" row when it is longer.
  - Depth stays within limits.
- Tests.

## 10. CarPlay: a tab you choose instead of Finds
- Remove the Finds tab.
- The third tab is chosen in **Settings › CarPlay**: Playlists (default), Artists, Albums, Songs, Genres, Favourites, Discover (when Aurral is set up) or Downloads.

## 11. CarPlay: choose what Home shows
- **Settings › CarPlay › Home**: an ordered, toggleable list of shelves:
  - Discover, Playlists, Recently added, Recently downloaded, Most played, Jump back in, Favourites, Random albums, Made for you.
- It is separate from the phone's Home layout. The default copies the phone's layout.
- CarPlay Home renders only the selected shelves, in that order.

## 12. App icons: two more colourways of the original
- The original icon (Default: the forest-green gradient with the mint "beak" dome) gets **Ink** and **Sunset** versions, using the same palettes as the other icon families.
- They are rendered with the existing scripts (byte-for-byte reproducible), added as alternate icons with previews, and appear in the picker.
- check-release covers them.

## 13. Home and Library: reorder buttons
- A top-right toolbar button on **Home** and on **Library** opens the same layout editor as Settings (reorder and hide), as a sheet.
- Changes apply immediately. The Settings entry stays.
- UI tests.

## 14. Settings: one place for accounts and servers
- **Decision.** One section, **Accounts & Servers**, near the top of Settings. It has four rows:
  - **Navidrome**: server, user, sign out, library choice and main library;
  - **Lidarr**: URL, API key, consent, Allow changes, Finds setup and the downloads screen link;
  - **Aurral**: URL, user and sign out;
  - **ListenBrainz**: token and scrobbling.
- Each row opens that service's page with all of its settings, moved from where they are today. No setting is lost.
- Old locations are removed or link to the new pages. UI tests navigate each one.

---

## Workstreams

| WS | Items | Notes |
|---|---|---|
| Z1 | 1, 14 | Aurral user login and Settings › Accounts & Servers. Owns the Settings root. |
| Z2 | 5, 2, 13 | Home bug, refresh error, reorder buttons. Systematic debugging; RED reproductions first. |
| Z3 | 3, 4, 9, 10, 11 | CarPlay. Owns CarPlay files and the Settings › CarPlay pages (adds one row to the Settings root). |
| Z4 | 6 | Lidarr restart anything. |
| Z5 | 7, 8 | Playback cache quality and source line. |
| Z6 | 12 | Icons (small). |

Z1–Z4 first (at most 4 at once), then Z5 and Z6. Each one goes through TDD → review → fixes → merge. Then a security look at the Aurral auth and gate changes, the **full suite including MAGPIE_IT**, and build 13.
