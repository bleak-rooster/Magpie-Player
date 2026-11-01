# Magpie round 12: plan (owner list of 2026-11-01)

Status: **PLAN ONLY, not started.** The owner asked for plans before any fixes.

Research behind this plan:
- docs/research/aurral.md, from a GET-only probe of the owner's Aurral v2.10.0;
- code investigations of search, Home, the pages, CarPlay, Now Playing, the buttons and the Finds/Lidarr flow (summarised inline, with file references).

The Aurral credentials live only in `~/.config/magpie/owner-servers.env` (mode 600), never in the repo.

Numbering follows the owner's list. The owner used "3" twice, so the CarPlay favourite button is **2b**.

---

## 1. Search understands "song + artist" in one query

**Cause.** The library search is one Subsonic `search3` call (NavidromeClient.swift:258, 20 songs / 10 albums / 5 artists), and Navidrome needs every word to match.
- "Hey Jude Beatles" matches songs, because a song's searchable text includes its artist and album. It never matches artists, and matches albums only by luck.
- The client doesn't re-rank anything. The Top result picks an exact or prefix match on the whole query (SearchSections.swift:79), which a mixed query never hits, so it falls back to the server's first song.

**Plan.**
1. **Query plan:** run the whole query, plus up to 4 parallel *split* queries. Each split tries one word boundary between title and artist, in both orders: "hey jude" + "beatles" and "beatles" + "hey jude". Each split searches the title part and keeps only songs and albums whose artist matches the other part.
   - With a cap on how many run at once, it stays under 6 requests per keystroke burst, debounced at 250 ms.
2. **Field-aware ranking** (new `SearchRanker` in Packages/MagpieKit/Sources/Search):
   - Score each hit by how many query words it covers in title, artist and album, with whole-word matches weighted above prefix matches, and diacritics and case folded.
   - A song covering all the words (title + artist) beats one covering only the title.
   - Use the same scorer for the Top result and for the order within each section.
   - Outside results (ListenBrainz/Lidarr) go through the same ranker.
3. **Artists and albums from a song query:** when the best song matches title + artist, also surface that song's artist and album as rows, even though Navidrome's artist search returned nothing.
4. **Recognise separators:** "title - artist", "artist - title", "by" and "–" parse straight into a (title, artist) split, with no guessing.
- **Tests:** a ranking table of about 30 real-world queries ("hey jude beatles", "beatles hey jude", "the national bloodbuzz", typos, articles, non-Latin), plus a fake server that implements Navidrome's AND-word semantics.

## 2. CarPlay: A–Z groups in long lists

**Cause.** The Artists, Albums, Playlists and Songs lists are one section with no headers, and `sectionIndexTitle` is always nil (CarPlayController.swift:575, TemplateModels.swift:233).

**Plan.**
- Build lists as one section per letter (A–Z, "#") with `sectionIndexTitle`, so CarPlay shows its letter scrubber. Drop leading articles, as the phone A–Z index does (W3).
- When a list is over `CPListTemplate.maximumItemCount` (it's the item limit that clamps today), show a **letters screen** first: a list of letter groups ("A", "B", … or merged ranges such as "X–Z" when they're small). Tapping one pushes that group's list, paged at the item limit.
- **Tests:** template model tests for sectioning, articles, the over-limit letter screen and the range merging.

## 2b. CarPlay: Favourite instead of Sleep timer

**Plan.**
- Remove `sleepButton()` (CarPlayController+Customisation.swift:180) and its sync (:198).
- Add a `CPNowPlayingImageButton` with star / star.fill that toggles the current song's favourite through X3's `setFavourite`, keeping X3's rollback-to-real-state rule.
- The phone's sleep timer stays.
- **Tests:** button state follows the song, a tap goes through favourites, and a failure rolls back.

## 3. Search: load more at the bottom

**Plan.**
- Each library section (Songs, Albums, Artists) pages with `search3` offsets (songOffset, albumOffset, artistOffset), 20/10/10 per batch.
- Reaching the end of a section loads the next batch automatically ("swipe up to load more"), with a footer spinner. "No more results" shows when a batch comes back short.
- The split queries from item 1 page the same way.
- **Tests:** offsets, stopping on a short batch, no duplicates across batches, cancellation when the query changes.

## 4. Pull to refresh on Artist, Album and Playlist pages

**Cause.** None of the three has `.refreshable`. They reload only on `.task(id: offlinePageKey)`.

**Plan.**
- Add `.refreshable` to all three. It:
  - reloads the page;
  - clears that page's PopularSongsCache entry, palette and artwork memory entry;
  - re-runs the Lidarr line and the not-yet albums.
- **To "capture new downloads",** the refresh also asks Navidrome for a quick scan (`startScan`, not a full scan), then reloads once `getScanStatus` says it's done (polling up to 20 s).
- Offline, the refresh re-reads the phone's downloads.
- **Tests:** refresh calls the loaders again, clears the caches, and waits for the scan (fake server).

## 5. Home shelves show the wrong content

**Finding so far.** A static trace found **no** mix-up between sections and their loaders:
- the loader table is AppModel+Home.swift:121-138;
- results are joined back by section, not by index;
- the cache, layout and CarPlay are all keyed by section.

Two things could still explain it:
- (a) Playlist tiles reuse the album tile, and Navidrome makes a playlist's cover from its albums, so playlists *look* like random albums.
- (b) There's no "Recently downloaded" shelf. "Downloaded" lists every downloaded album, unordered.

**Diagnosis (2026-11-01).** The diagnosis was run read-only against the owner's Navidrome, with a fresh install on a simulator, every shelf turned on, and screenshots and tile dumps compared. **No heading-to-content wiring bug reproduced:** every shelf matched the server, and taps opened the right kind of page. The complaint comes from design faults:
1. **Home mixes all three libraries.** No call sends `musicFolderId` (NavidromeClient.swift:173-186). The server has Music Library (1), Aurral Playlists (2) and Finds (3), so Aurral flow downloads turn up in Random albums and Recently added and read as "random albums".
2. **The Playlists shelf** is the first 12 playlists A–Z, unsorted (AppModel+Home.swift:121), so it starts with old playlists. Navidrome's covers are 2×2 album grids, so the tiles look like albums.
3. **"Downloaded"** is A–Z by name (OfflineCatalog.swift:31-35), takes the first 12, and ignores `downloadedAt`. Downloaded playlists show up as partial albums.
4. **CarPlay** uses the same calls, so it has the same faults.

**Plan.**
- **Main library only, everywhere:**
  - Home, Library lists, Search and CarPlay read the **main library** (`musicFolderId`), picked as in R18 ("Main library", automatic when the choice is obvious).
  - Aurral's library appears only under Discover (item 7), and Finds only under Finds.
  - Album artists only (R11) keeps working.
- **Playlists shelf:**
  - most recently changed first;
  - Aurral flow playlists left out (they live in Discover);
  - the owner's own playlists before public ones from others;
  - a distinct playlist tile (stacked frame, "Playlist · N songs").
- **Recently downloaded:** ordered by `downloadedAt`, newest first. Albums and playlists are listed as themselves, not split into partial albums. "See all" opens Downloads.
- **Stale cache:** a saved shelf whose tile kinds don't match its section is thrown away on load.
- **Tests:**
  - musicFolderId is sent on every list call;
  - Aurral and Finds albums never reach Home, Library or Search;
  - the playlist order;
  - the download-date order;
  - the stale-cache guard.

## 6. Settings › Downloads in Lidarr (all of Lidarr's downloads)

**Owner decision (2026-11-01).** This screen may restart **any** Lidarr download, not only Magpie's. It supersedes R17's "never touches downloads of anything else" for this screen only. Record it in docs/decisions.md.

**Plan.**
- **Screen:** Settings › "Downloads in Lidarr", shown when Lidarr is connected. It reads `queue/details` (whole queue) and `downloadClients` every 5 s while open.
  - **Active:** downloading items with progress, speed and client.
  - **Stalled:** no progress past the stall limit (a request-independent StallWatch, reused from X6).
  - **Failed:** failed, importBlocked or warning, with Lidarr's status message.
- **Actions:** **Restart** on each stalled or failed row (swipe or button), plus **Restart all stalled and failed** (one confirmation). Restart means:
  1. `DELETE /queue/{id}?removeFromClient=true&blocklist=true&skipRedownload=true`;
  2. then a gated `AlbumSearch` for that album.
- **Gate.** A new confined shape, `queueRestartAny`, with the exact same query string. Before sending, it re-reads the item fresh, and it:
  - refuses items that are importing or imported/completed;
  - refuses a downloadId shared with an item in those states;
  - sends restarts one at a time, at most 25 per bulk tap.
  - check-writes.sh pins it.
- **Magpie's own requests:** a restart that hits one goes through X6's `removeCounting`, so its 5-removal cap and state stay true.
- **Safety:** everything is logged to the change log, and "Allow changes" (G1) still applies.
- **Tests:** classification, the exact query shape, refusals, bulk limits, and request counter sync.

## 7. Aurral integration (Discover)

**Facts** (docs/research/aurral.md):
- Aurral v2.10.0. The API is at `/api` with an `X-Api-Key` header. The key is **full admin**.
- Flows are listed by `GET /api/playlists/status`; per-track rows (artist MBID, status, path) come from `GET /api/playlists/jobs`. **Refresh** = `POST /api/playlists/start/:flowId` (replaces the flow's tracks).
- Aurral publishes each flow to the **same Navidrome** as a public playlist named after the flow. Its files sit in a separate Navidrome library, "Aurral Playlists".

**Plan.**
- **Setup:** Settings › Services › Aurral (URL + API key, Keychain only). Off unless set up.
  - The client **allow-lists** exactly: `GET /api/health`, `GET /api/playlists/status`, `GET /api/playlists/jobs`, `POST /api/playlists/start/:flowId` and `GET /api/library/lookup/:mbid`.
  - It never calls `/api/settings` (it returns every secret in clear), `/api/auth/api-key` or `GET /api/discover`.
  - Version-check via `/api/health`.
- **Discover section** on Home and in Library (only when Aurral is set up): the Navidrome playlists whose names match Aurral's flows, kept apart from Playlists and hidden there.
  - Each Discover playlist page has a **Refresh Flow** button (confirmation: "Replaces this playlist's songs") and shows the worker's progress from `/playlists/status`.
- **Easier to add artists:**
  - every song row and the page header offer **Add <artist> to your library**, using Magpie's own R18 Add flow through the gate (Magpie's defaults and choices, not Aurral's);
  - a per-playlist **"Artists in this playlist"** list with an Add on each one not yet in Lidarr (the status comes from Lidarr lookup).
- **No duplicates once an artist is in the main library:**
  - when the main library has the same recording (by MBID, else title+artist+duration ±3 s), Discover plays and shows the **main-library copy** in place of the Aurral single;
  - the Aurral copy is hidden from Discover, search and Library;
  - **Replacing the file (research: docs/research/aurral.md, "Replacing a flow track"):** Aurral 2.10.0 has **no** supported way to replace or delete one flow track.
    - Its per-track delete doesn't apply to flows.
    - Its "research" route finds its own file first.
    - `DELETE /api/library/tracks/:id` would delete the **Lidarr** copy, so it is never used.
  - **Chosen approach: swap the playlist entry.**
    - The flow playlists in Navidrome belong to the owner's user and are writable.
    - When a Discover playlist is opened, and after a matching import, Magpie rewrites the playlist in its existing order with the main-library copies in place of the Aurral entries.
    - It uses `updatePlaylist` (remove all, re-add), sends once (X3 rule), re-reads to verify, and skips while Aurral's worker is busy.
    - The same swap runs in the owner's own playlists that hold the Aurral copy, so Aurral isn't made to keep the file.
    - Aurral's next republish undoes the swap, so it's redone on each open.
  - **The Aurral file itself** stays on disk until the flow's next weekly run deletes it (it's no longer referenced). Magpie never touches Aurral's files.
- **Tests:** the endpoint allow-list (any other path is refused), never calling settings, flow↔playlist matching, the duplicate swap, and Refresh confirming and refusing while a run is active.

## 8. Finds: the right status, and "Add to your library" that finishes the job

**Causes:**
- Every Find artist is created with `monitored: true`, on purpose: Lidarr won't download otherwise (RequestRunner.swift:803).
- `ArtistLidarr.state` reports `.monitored` without checking the Finds tag or root, so a Find says **"In Lidarr · Monitored"**.

**Plan.**
- Add a `.find` state to ArtistLidarr: the magpie-find tag, or a path in the Finds root, or a ledger createdArtist that hasn't been kept.
  - The status line reads **"In your Finds"**, and the action reads **"Add to your library"**. Song and album rows say the same.
- **Add to your library**, all of it, tracked to the end:
  1. move to the main root, switch to Magpie Lossless and remove the find tag (already done);
  2. **new:** send `AlbumSearch` for the kept albums right away, so the FLAC is searched for;
  3. **new:** watch for the lossless import. Lidarr's upgrade replaces the MP3 file and deletes it into Lidarr's recycle bin;
  4. **new:** after the import, rescan and relink by MBID, and show "Lossless" when it lands.
  - **The MP3 (owner ruling 2026-11-01):**
    - it stays, playable, until the FLAC lands (Lidarr's upgrade then replaces and deletes it), **or until 7 days pass**, whichever comes first;
    - after 7 days with no FLAC, Magpie deletes the MP3 automatically (a gated trackfile delete, confined to files Magpie's find created), and the album stays monitored, so the FLAC is still searched for;
    - the song is then gone from the library until a FLAC arrives. The page says so beforehand ("The MP3 is removed on <date> unless a lossless copy turns up") and afterwards ("Waiting for a lossless copy");
    - **Remove the MP3 now** is offered at any time, with a confirmation.
- **Folder collision (keptInPlace):** currently "kept" but left in Finds. Instead, merge into the existing main-library artist when the MBID matches; otherwise show a clear message and don't call it kept.

## 9. Make Find → Add rock solid

**Plan.** Rework the request runner around *reconciliation*: each tick derives every request's state from the servers instead of trusting saved steps. The top fragile spots from the investigation, with fixes:
1. **Lossless never searched after Keep:** item 8.
2. **Ready depends on an MBID match in Navidrome; Soulseek files often lack tags.** Add a fallback match on Lidarr's imported trackfile path ↔ Navidrome song path, then title+artist+duration.
3. **Several sources of truth** (request list, ledger, Lidarr tags/paths, Navidrome Finds library). Make Lidarr (tags + root path) and Navidrome the truth. The ledger stays only as the record of what Magpie wrote, for the write gate. One `FindState` resolver feeds the status line, Finds, rows and CarPlay.
4. **`keptAt` is written before the PUT,** so a crash can lock the artist forever. Write intent → PUT → verify → commit, and recover intents on launch.
5. **Keep is refused while any Lidarr command runs.** Queue the Keep and run it when Lidarr is idle, showing "Adding when Lidarr is free…".
6. **Stall heuristic:** treat the "warning" status as stalled after the limit, re-read the client names every pass, and raise the default stall limit to 3 min (60 s kills slow-but-alive transfers).
7. **History cursor and clock skew:** use Lidarr's server time from response headers, not the phone clock.
8. **Album appearance after add:** wait for the RefreshArtist command to finish, not a fixed settle time.
9. **Name-only artist matches:** never act on one; show "Couldn't match this artist" instead.
10. **In-memory busy sets:** persist them with the runner state, so a background relaunch can't double-act (extends X5 I1).

**Proof:**
- an end-to-end integration suite on the dev stack, covering Try → Find → Ready → Add → lossless upgrade → MP3 gone, with a fake slskd release and a FLAC upgrade release;
- a chaos variant: kill the app at each step, Lidarr busy, a clock 10 min off, tagless files.
- Each must reach the right end state.

## 10. A consistent, well-planned UI

**Cause.**
- Play, Shuffle and Download are built in several ways: PlayShuffleButtons (AlbumView.swift:123), the artist page's own row without margins (ArtistView.swift:95), Genre's duplicate helper, and a natural-width DownloadButton that turns into a plain text menu.
- Several screens use iOS `.borderedProminent` and `.bordered` instead of the design system.

**Plan.**
1. **Design system:**
   - one `ActionBar` component: equal widths, one height (44 pt), consistent icon and label spacing;
   - the primary action (Play) filled, the rest tinted;
   - Download is the same capsule in every state (Download → Downloading 40% → Downloaded ✓ with a menu);
   - it stacks at accessibility sizes.
   - Every page uses it, and the `.bordered` uses are replaced.
2. **Screen-by-screen audit:**
   - with the design and accessibility review tools (impeccable / design-critique / accessibility-review skills) and screenshots of every screen in light, dark and the three Characters;
   - spacing and type scale tokens enforced, with a list of fixes per screen.
3. **Snapshot tests** for ActionBar states and the main pages, so it stays consistent.
- This runs **last**, after items 1–9 land, so it covers their new screens.

## 11. Now Playing says when a song is transcoded

**Cause.** The Hallmark shows the *original* file's quality even when the stream is transcoded. `SongInfo.Source` already knows the truth (SongInfoSheet.swift:16-81).

**Plan.**
- Under the scrubber, show what you're actually hearing:
  - "Lossless · FLAC 24/96";
  - "Transcoded · Opus 160 kbps (from FLAC)";
  - "MP3 320" for a lossy original;
  - "On this iPhone · …" for downloads.
- The Hallmark follows what's playing.
- The fallback hint stays.
- **Tests:** label for each source (original, transcoded, fallback to original, downloaded).

---

## Workstreams and order

| WS | Items | Notes |
|---|---|---|
| Y0 | 5 (diagnosis) | Done 2026-11-01: no wiring bug; causes recorded in item 5. |
| Y1 | 1, 3 | Search ranking and paging. |
| Y2 | 2, 2b | CarPlay. |
| Y3 | 4, 11, 5 (fix) | Pages, Now Playing and Home. |
| Y4 | 6 | Settings › Downloads in Lidarr + gate. |
| Y5 | 8, 9 | Find/Add rework. The biggest; its design gets a critic pass before code. |
| Y6 | 7 | Aurral; after Y5, because it reuses the Add flow and the FindState resolver. |
| Y7 | 10 | UI consistency pass; last. |

Y1–Y5 run in parallel, at most 4 at a time to limit machine load. Y6 follows Y5, and Y7 comes last. Each workstream goes through tests (TDD) → review → fixes → merge. Then a full suite, a security review of the new write shapes and the Aurral client, and the next TestFlight build (12).

## Owner answers (2026-11-01)

1. **Home:** Magpie runs the read-only diagnosis against the owner's server itself; the owner sends screenshots only if it can't be reproduced.
2. **Aurral duplicates:** find a supported way to replace the Aurral file with the main-library copy. If there is none, leave it until the flow rotates it out, with Magpie hiding the duplicate meanwhile. The research is in docs/research/aurral.md, "Replacing a flow track".
3. **MP3 after Add:** kept until a FLAC replaces it, or auto-deleted after 7 days whichever comes first; manual delete any time (see item 8).
4. **Plan only for now:** no building until the owner says go.
