# Magpie round 14: Aurral Discover, Trending, Recommended, previews (plan)

Owner request of 2026-11-04. Plan only: nothing is built until the owner confirms.
Research: `docs/research/aurral-discover.md` (Aurral **2.13.0** source, the owner's version and the
latest release) and the earlier `docs/research/aurral.md` (2.10). Calls marked **Decision** are mine
(the owner delegated design calls); the ones marked **Owner** need an answer.

## What the owner wants
- Three Aurral sections on **Home** and in **Library**:
  - **Discover**: the Aurral playlists that are already in Navidrome with downloaded music;
  - **Trending**: Aurral's charts, including Australian top songs, top charts by genre and top albums;
  - **Recommended**: new artists and albums to find.
- **Discover Playlists**: browse Aurral's Discover Playlists, see their songs, and add one to Aurral
  so it downloads and shows up in Magpie.
- A **30-second preview** of any Aurral song. From a preview the owner can:
  - **Listen to the full song** as a Find (a song they just want to listen to);
  - **Add the artist** to the main library.
- **Adding a preview to a playlist** formally adds the artist and the song to Lidarr. The owner picks
  either **just this song** (needs Tubifarry) or **the whole artist** (their usual defaults).
- **Search**: when Aurral is set up, songs, artists and albums are searched through Aurral, not
  Lidarr. Find and Add work exactly as they do today.

## What Aurral 2.13 gives us (and what it doesn't)
| Need | Aurral 2.13 | Gap and fix |
|---|---|---|
| Recommended | `GET /api/discover`, a per-user list of **artists** only, with MBIDs, match %, "because you like" seeds, and depth | There are no recommended albums. Each artist's page shows their albums, and the top 6 songs have previews (`GET /api/artists/:mbid/preview`). |
| Trending | `GET /api/discover/trending`: top 100 songs (with previews), 25 albums (Apple), 25 artists, and genre tiles. `GET /api/discover/trending/genres/:id`: 50 songs per genre (Pop, Rap/Hip Hop, Rock, Dance, R&B, Alternative, Electro, Jazz, Metal). | The country is the **Aurral server's own location** (no parameter). A home server in Australia gives "Top Australia". If it reports another region, Magpie loads Top Australia straight from Deezer's public chart (no account needed). |
| Previews | `/api/deezer/preview/<id>.mp3` needs no login. It redirects to a signed Deezer MP3 that expires after about 15 minutes. | Apple album items have no previews; an album's songs get previews from the artist preview or the matching Deezer song. |
| Discover Playlists | `GET /api/discover/editorial` (For you, plus 8 per genre) and `GET /api/discover/editorial/:id` (the songs, with previews) | There is **no route that turns one into a Flow**. Aurral's "Add" (`POST /api/discover/editorial/:id/library`) makes a **synced playlist**: it downloads every song, publishes the playlist to Navidrome, and re-syncs every 24 h. To the owner that behaves like a Flow. |
| Search | `GET /api/search/unified` (artists and albums with MBIDs, "in library" flag) and `GET /api/search?scope=&offset=` for paging | **Aurral has no song search.** See owner answer 5. |
| MBIDs for chart/playlist songs | `GET /api/discover/editorial/links` gives the artist and album MBIDs | Magpie then matches the recording in that release group through MusicBrainz, which it already uses. |

Permissions: Recommended, Trending and search need a normal user. Adding a Discover Playlist needs
Aurral's **accessFlow** permission, which ordinary users don't have by default. Magpie reads the
signed-in user's permissions from `/api/auth/me` and hides any action the user can't do.

## Decisions
1. **Downloads go through Lidarr, not Aurral's own downloader.**
   - Listen to the full song, Add artist and the playlist choice all use Magpie's existing Lidarr flows: Finds,
     Keep, addFlow, the write gate, the FLAC upgrade watch and the 7-day MP3 rule.
   - Aurral's single-track download (`/api/library/downloads/track`) and its add-artist route stay
     unused. That gives one download pipeline, everything stays in the main library, and the write
     gate keeps covering it.
   - Exception: **Discover Playlists** are added through Aurral, because that is the only way they
     become an Aurral playlist.
2. **Previews use their own lightweight player**, not the main queue.
   - Scrobbling, play counts, Finds watching and the cache all assume a Navidrome song, so they never
     see a preview.
   - Starting a preview pauses the main player. When previews stop, the main player stays paused, and
     the mini player shows a Resume button.
   - A **Play previews** button plays a chart or playlist 30 seconds at a time, in order.
3. **Preview safety.**
   - Magpie fetches the Aurral preview link itself, with no login attached, and follows the redirect
     only to Deezer's HTTPS audio hosts (`*.dzcdn.net`). Only then does it hand the final link to the
     player. Anything else is refused.
   - Signed links are never cached.
4. **"Just this song" = a Find that is kept straight away.**
   - It goes through the existing request: the album search grabs it, Tubifarry makes it fast, and
     only that song is kept.
   - On arrival it is **moved to the main library** (Keep) instead of staying in Finds.
   - The option shows only when Tubifarry is detected. Without it, the owner sees only "Whole artist",
     with a note.
   - "Whole artist" = the existing Add-artist flow with the owner's defaults.
5. **Playlist adds wait for the song.**
   - Navidrome playlists can only hold songs it has. Adding a preview to a playlist saves a pending
     add with the request.
   - The playlist page shows it as a greyed "Coming" row with progress.
   - When the song lands (matched by recording MBID, else title + artist + duration, never by name
     alone, as Finds already do), Magpie adds it to the playlist and the row turns normal.
   - If the request fails, the row says so, with Retry and Remove.
6. **Chart country.**
   - Trending follows Aurral's region. Australia is expected, because the owner's server is at home.
   - If Aurral reports another region, Magpie shows **Top Australia** from Deezer's public chart
     playlist and the AU album chart from Apple's public feed.
   - Genre charts are worldwide (Deezer has no country version), and they are labelled that way.
7. **Home and Library never wait on Aurral.**
   - Round 13's lessons are applied to the three new sections:
     - each section loads and fails on its own;
     - the last good copy is kept and shown at launch;
     - a section is never replaced by another shelf;
     - a section that has never loaded shows a calm "Aurral is updating" card.
8. **Search fallback.**
   - If Aurral is down or slow (a short timeout), search quietly falls back to today's Lidarr search
     and says "Searching Lidarr".
   - Load more also pages the outside (Aurral) results, which today only page the library.
9. **Not for me** on a recommended artist hides it in Magpie and tells Aurral, through
   `POST /api/discover/feedback`, so Aurral learns from it.
10. **CarPlay** is not changed this round. A Trending shelf for CarPlay Home can come later.

## Owner answers (2026-11-04)
1. **Discover** shows your current flows, then the **"For you"** playlists automatically underneath,
   then **Browse more playlists** (all genres). The action on a playlist is **Add flow**. It uses
   Aurral's synced playlist under the hood: it downloads every song, publishes to Navidrome, and
   updates daily.
2. **The word "Aurral" never appears** in the browsing, playing or adding screens.
   - **Decision:** Settings › Accounts & Servers keeps the service's name, because it is the server
     you sign in to.
   - Everywhere else uses "flow", "Discover", "Recommended" and "Trending".
3. **Trending uses "Save to playlist"** (not "Save as playlist").
   - It is per song: pick an existing playlist or **New playlist…**. The picker already has that row.
   - A song you don't have yet asks Just this song / Whole artist, then waits as a "Coming" row
     (decision 5).
   - **Decision:** a whole chart can still be followed with **Add flow** (a daily-updated playlist).
     There is no "save all 100 songs" button, because that would fire 100 Lidarr requests at once.
4. **Home is rebuilt to feel like Spotify** and is **fully customisable** (see "Home"). Discover and
   Recommended lead, and Trending sits lower down.
5. **Combined search (owner, 2026-11-04): songs from Lidarr and Navidrome, merged into one search.**
   - What each service can search:
     - **Navidrome** (`search3`) searches the songs you have.
     - **Lidarr** has no song search (only `artist/lookup`, `album/lookup` and `search`, which return
       artists and albums).
     - Aurral has no song search either.
   - **Decision**, so songs come only from Navidrome and Lidarr, with no Deezer call from the phone:
     - **Songs** = your Navidrome songs first, then songs from outside the library. Outside songs come
       from the **albums that Lidarr's search returns** for the term: their tracklists, read through
       MusicBrainz, which Lidarr itself uses, keeping the songs whose title matches. They carry MBIDs,
       so Find and Add work as today.
     - ListenBrainz song search stays only as a backup when Lidarr has no album hit.
     - Duplicates are removed by recording MBID, and songs you already have get an "In your library"
       badge.
     - **Artists and albums** = the server's (Aurral) results merged with Lidarr's, removing
       duplicates by MBID. If either one fails or is slow, the other's results still show.
     - **Previews for outside songs** come from the server's artist preview, which covers each
       artist's top songs. A song outside those has a plain row with no preview button. The phone
       never calls Deezer directly.

6. **A setting for where an artist's Top songs come from** (owner, 2026-11-04).
   - It lives in **Settings › Home & Library › Artist top songs**. Settings may name the services.
   - It applies to the Top songs row on every artist page (in your library and outside it), and to the
     previews offered in search.
   - The options:
     - **Automatic** (default): Aurral first; if it has nothing, ListenBrainz; if that has nothing,
       your library.
     - **Aurral**: the artist's top songs, by Deezer popularity, all with previews.
     - **ListenBrainz**: the most-listened songs worldwide (`/1/popularity/top-recordings-for-artist`,
       to be verified in A1). A song gets a preview only when it also appears in Aurral's list.
     - **Your library**: Navidrome's top songs for the artist (`getTopSongs`), only songs you have,
       which play in full.
   - If the chosen source fails or has nothing, the row falls back in the Automatic order, with a small
     "from ListenBrainz" note, rather than staying empty.
   - This also fixes the earlier leftover where the outside artist page had no Popular source.

7. **Previews for ListenBrainz songs** (owner, 2026-11-04).
   - When Aurral is configured, Magpie tries to find the same song among everything Aurral can preview:
     - the artist's top songs;
     - the Trending and genre charts;
     - the Discover playlist songs it has loaded.
   - The match is by artist (MBID, else name), title (normalised) and duration (±3 s).
   - Aurral has no song search, so a song outside those lists shows **"No preview available"** in place
     of the play button. Nothing is guessed from a similar title.
8. **Full song = Finds.**
   - The song menu's first action is **Listen to the full song**, with the subtitle "Goes into your
     Finds". It is the existing Find request.
   - Finds work with **Navidrome + Lidarr alone**. They never depend on Aurral.
9. **Every setup must work fully, not just "with Aurral"** (owner, 2026-11-04).

   | Setup | Home | Search | Artist Top songs | Previews | Finds / Add |
   |---|---|---|---|---|---|
   | Navidrome only | Spotify-style from your library: greeting, quick grid, Jump back in, Recently added, Favourites, Most played, Made for you, Playlists, Genres | Your library | Your library | none (no preview controls at all) | hidden (needs Lidarr) |
   | Navidrome + Lidarr | as above, plus Finds and Requests | Your library, plus Lidarr artists and albums, plus outside songs from Lidarr's album tracklists (ListenBrainz backup) | Automatic = ListenBrainz → your library | none; outside songs offer **Listen to the full song (Finds)** | yes |
   | Navidrome + Aurral | plus Discover, Recommended and Trending, with previews | plus Aurral artists and albums | Automatic = Aurral → ListenBrainz → library | yes, or "No preview available" | hidden (needs Lidarr) |
   | All three | everything | everything, merged | everything | yes | yes |

   - Sections, settings options and menu actions that need a missing service are **hidden**, not
     broken.
   - In the Home editor, those sections are listed greyed out with "Needs Aurral" or "Needs Lidarr".
   - Without Aurral, the Artist top songs setting offers Automatic, ListenBrainz and Your library only.
   - Aurral's session ending or the server going down never empties Home: its sections keep their last
     copy, or hide when there was none. An explicit **sign-out in Settings** disconnects Aurral, so its
     sections hide and their saved copies are removed (controller ruling, A4 review I3).
   - **Tests:** UI tests run Home, Search, an artist page and the song menu in all four setups, using
     stubs.

10. **Add flow downloads everything in the background, through whatever downloader is already set up**
    (owner, 2026-11-04). Navidrome is the only service that is guaranteed.
    - **Add flow** makes the server create the flow and queue a download of every song straight away
      (the response's `tracksQueued`). Magpie starts nothing itself and never needs the app open: the
      server runs the downloads.
    - **The server's own setup decides how songs are fetched.** In 2.13 that is its download sources
      (Soulseek, Usenet, yt-dlp, Tidarr, as configured, in its priority order).
      - When the server is linked to Lidarr, songs already in Lidarr's library are reused rather than
        downloaded again.
      - Magpie does **not** also send Lidarr requests for flow songs. That would download every song
        twice and fire dozens of Lidarr album searches.
      - Lidarr stays the route for Finds and Add artist.
    - Before Add flow, Magpie reads `/api/health/bootstrap` `downloadSources` (no login).
      - If **no download source is configured**, the button still works but explains: "Songs already
        in your library will appear; others can't be downloaded until a downloader is set up on your
        server."
      - The flow shows "Waiting for a downloader" rather than spinning.
    - Progress: "Downloading 12/40" on the flow, from `/api/playlists/status` and `jobs/:id`, polled
      gently (every 30 s while visible, otherwise on open).
    - As songs land, Navidrome scans them and they appear in the flow under Your flows. Failed songs
      show as "Couldn't download" with Retry, which is the server's re-search for that song.
    - If a flow was created with auto-download off, Magpie shows **Download songs**
      (`POST /api/playlists/flows/:flowId/download`, accessFlow; added to the allow-list).
    - **Tests:**
      - Add flow with a downloader → queued and progress;
      - with no downloader → the explanation;
      - with Lidarr linked or not → no Magpie-sent Lidarr writes;
      - a failed song → Retry;
      - Navidrome-only and Navidrome + Lidarr setups → Add flow is hidden.

11. **No direct calls to Deezer or Apple from the phone** (owner, 2026-11-04). Everything goes through
    the Aurral server; this supersedes the public Deezer/Apple fallbacks in Decisions 3 and 6. All
    three routes below were verified in the v2.13.0 source:
    - **Top Australia when the server's region isn't AU:** Deezer's "Top Australia" playlist read
      through Aurral, `GET /api/discover/editorial/1313616925`. Aurral accepts any Deezer playlist id.
    - **Top albums for a non-AU region:** shown as Aurral's albums, labelled with their region.
      Aurral has no Australian album chart.
    - **Previews:** `GET /api/deezer/preview/<id>.mp3?download`. Aurral fetches the clip and sends it
      itself (200 `audio/mpeg`), so the phone never contacts Deezer's CDN. No redirect is followed at
      all; the clip must come from the Aurral host.
    - **Artwork:** for Deezer and Apple cover links that Aurral returns, the phone asks Aurral's image
      proxy for them:
      - `POST /api/image-proxy {src}` caches the image on the server and returns a local url;
      - `GET /api/image-proxy/<key>` serves it;
      - Aurral refuses private hosts.
      Magpie only sends `src` values that Aurral itself returned, and remembers the mapping.
    - check-writes bans Deezer/Apple hosts in app code.
    - Workstream **A7** (previews and artwork) follows A4.

## Home (Spotify-style, fully customisable)
- **Top of the page, in order:**
  - a greeting ("Good evening") with the Edit Home button;
  - **filter chips**: All · Discover · Recommended · Your library. A chip narrows the page to those
    sections;
  - a **quick-access grid** of 8 compact tiles (two columns, art on the left, name on the right), like
    Spotify. It shows what you played most recently: albums, playlists and flows. One tap plays or
    opens it.
- **Default sections below:**
  1. **Your flows**: your current flows, then the For you playlists, then Browse more playlists.
  2. **Recommended for you**: artist circles, Top pick first.
  3. **New this week**: newly recommended artists.
  4. **Because you like X** (up to 3 rows): recommended artists for each seed.
  5. **Jump back in** (existing).
  6. **More playlists for you**: one Discover genre shelf, rotating daily.
  7. **Recently added**, **Favourites**, **Most played** (existing).
  8. **Close to home** / **Further out**: two more recommended artist shelves.
  9. **Trending**: the top songs chart.
  10. **Charts by genre**.
  11. Then the existing shelves: Recently downloaded, Random albums, Made for you, Playlists, Genres.
- **Fully customisable**, in the layout editor (Edit Home, or Settings):
  - every section can be reordered and hidden, including the greeting, chips and quick-access grid;
  - each shelf has a size (small, medium or large cards) and an item count;
  - "Because you like" can be set to 0–3 rows;
  - Reset to default restores this order.
- **Without Aurral:** the Discover, Recommended and Trending sections hide themselves, and the page
  is the same Spotify-style layout built from your library.
- **Existing layouts:** owners who rearranged Home keep their order, and the new sections are
  inserted in their default positions.
- **CarPlay Home** keeps its own list from round 13. The new sections aren't added to CarPlay this
  round.

## Screens
- **Discover › Browse more playlists:** "For you", then one shelf per genre.
  - A playlist page shows the cover, curator and track count, then **Play previews** and **Add flow**.
    Add flow's state is Adding, Downloading 12/40, or In your flows.
  - Then the songs. Songs you already have play the real file. Each other song has a preview button
    and a menu: Listen to the full song (Finds), Add artist, Save to playlist.
  - Once added, the playlist appears under **Your flows** as its songs arrive.
- **Trending** page:
    - Top songs (100), with Play previews, **Add flow** (follow the chart) and per-song **Save to
      playlist**;
    - Top albums;
    - Top artists;
    - Charts by genre (9 tiles, 50 songs each);
    - Popular playlists.
  - Chart movement arrows (▲3, NEW) appear when Aurral provides them.
- **Recommended** page: Top pick, New this week, "Because you like X" (up to 3), Close to home,
    Further out, and All (sortable).
  - An artist opens the existing outside-artist page, with a new **Top songs (previews)** row, and the
    Add artist and Not for me actions.
- **Library**: three rows, Discover (which includes Browse more playlists), Trending and Recommended,
  opening the same pages.
  - They can be reordered and hidden like every other row.
  - Existing layouts gain them after Discover.
- **Preview row**: a play button with a 30-second ring, title, artist, an "In your library" tick when
  it matches, and a ⋯ menu (Listen to the full song · Add artist · Save to playlist).
  - **Save to playlist** opens a choice: **Just this song** (Tubifarry) or **Whole artist**, then the
    playlist picker.
- **Search** (when Aurral is set up): Songs, Artists and Albums from Aurral (songs as in owner answer 5),
  with "In your library" badges, previews, Load more, and the same Find and Add buttons as today.

## Workstreams (same process as before)
Each workstream follows the same process:
- a brief and an isolated worktree;
- TDD (red first);
- review against reviewer-prompt.txt;
- fixes, re-review, then merge into `v0.0.1-custom`;
- logged in `.superpowers/sdd/2026-10-28-magpie-customisation/progress.md`.

| WS | What | Depends on |
|---|---|---|
| **A1** | **AurralKit 2.13.** Models and decoding for discover, trending, genre chart, editorial list and playlist, editorial links, artist preview, search unified/paged, release-group tracks, and the auth/me permissions. The allow-list grows from 7 to about 18 exact routes. `check-writes.sh` replaces the blanket `api/discover` ban with an exact list. Still banned: `discover/refresh`, `blocked-tags` writes, `library/artists`, `library/downloads/*`, `api/settings` and `api/users`. Feature detection uses `api.features` (2.10 keeps today's behaviour). Fixtures come from the 2.13 source shapes, plus StubAurral routes. Decisions are added to `docs/decisions.md`. | — |
| **A2** | **Preview player.** The `PreviewPlayer` (its own AVPlayer, audio-session hand-off with the main player), the redirect resolver with the dzcdn host pin, Play previews in sequence, the mini-player state, the `PreviewRow` design-system component, and the Deezer and Apple fallbacks (chart country, no direct Deezer call for search). | A1 |
| **A3** | **Find and Add from a preview.** `OutsideSong` (no MBID) → MBIDs through editorial links → recording match in MusicBrainz, then "in your library" detection. The ⋯ menu wires Listen to the full song (Find), Add artist (addFlow) and Save to playlist with the choice. A new pending playlist add is stored with the request (`RequestStore`) and applied when the song resolves, shown as "Coming" rows. "Just this song" = Find + Keep on arrival. Also the **Artist top songs** setting (owner answer 6), with its sources, fallback and tests. | A1, A2 |
| **A4** | **Home and Library sections.** New `HomeSection.trending` and `.recommended`, `LibraryRow.trending` and `.recommended`, with migration. Discover = Your flows, then For you, then Browse more playlists. The playlist pages (songs, **Add flow** with progress through `/api/playlists/status` and `jobs/:id`). No "Aurral" in any of this copy (a UI test checks for it). Also the Trending and Recommended pages, the per-section caches and failure states, and Not for me feedback. The Home and Library layout editors pick these up. | A1, A2 (A3 for the menus) |
| **A6** | **Spotify-style Home.** The greeting, filter chips, quick-access grid (recently played), new shelf styles (artist circles, compact tiles, large cards), and the sections in the default order above. The layout editor gains size, count and Because-you-like rows, and Reset. Existing layouts migrate. Home never waits on a section, so round 13's regression tests are kept. | A4 |
| **A5** | **Search through Aurral.** A `MergedSearch` `.aurral` source replaces `.lidarr` when Aurral is set up, with a quiet fallback to Lidarr on a timeout. Outside results are paged for Load more, and "in library" badges added. Songs = Navidrome library + Lidarr album tracklists (via MusicBrainz), with ListenBrainz as the backup, de-duplicated by MBID; previews come through the artist preview only. | A1 (A2 for previews) |

Order:
1. A1 first.
2. Then A2, A4 (its screens without the menus) and A5 in parallel, at most 3 at once.
3. Then A3 and A6 in parallel.
4. Then A4's menus are finished on top.

Each write route goes through a **security review**:
- the Aurral POSTs (editorial add, feedback);
- the redirect handling for previews;
- the third-party calls.

Then comes the **full suite including MAGPIE_IT**. The UI tests use StubAurral; the dev stack has no
Aurral, so stubs cover it. Then **build 14** goes to TestFlight.

## Tests (beyond each workstream's unit tests)
- **Allow-list:**
  - each new route allowed;
  - banned routes refused;
  - no login token on preview fetches;
  - a redirect to a non-Deezer host refused.
- **Trending:**
  - region AU from Aurral;
  - a non-AU region falls back to Deezer Top Australia;
  - a genre chart not available yet (404);
  - per-section failure.
- **Home:**
  - Aurral slow, down or signed out keeps the last Trending and Recommended;
  - no shelf is ever replaced by random albums (round 13 regression).
- **Previews:**
  - pause/resume hand-off;
  - sequence;
  - expired link refetch;
  - 404 "No preview" state.
- **Requests:**
  - preview → Find;
  - preview → playlist with Just this song (Tubifarry present or absent);
  - Whole artist;
  - pending add applied on arrival, and failure → Retry/Remove;
  - never matched by name alone.
- **Discover Playlists:**
  - list, songs, add (already added, permission missing);
  - progress, then the playlist appears in Discover.
- **Search:**
  - Aurral results with paging;
  - fallback to Lidarr;
  - "in library" badge;
  - Find and Add unchanged.

## Not this round
- CarPlay Trending.
- Aurral's own single-track downloader.
- Creating or editing Flows (unless the owner picks that in question 1).
- Aurral's "Shows near you", "Artist news" and release-radar sections.
- Changing anything on the owner's Aurral other than the actions the owner taps (Add flow, Not
  for me).
