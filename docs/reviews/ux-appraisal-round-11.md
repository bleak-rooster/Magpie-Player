# UX appraisal: round 11 flows (artists, albums, songs, requests, queue, playlists, CarPlay)

Status: review for the controller and owner · 2026-10-30 · branch `v0.0.1-custom` at 2a86dce
Scope: round-11 spec R8–R12 and R15–R19, priority round P1–P3, and the current screens (Search, Artist, Album, Playlist, Library, Finds, Try, Activity, Now Playing, Queue, Settings › Requests, CarPlayUI).
Method: read the spec, the design language (§5 voice), FLOWS.md and the SwiftUI and CarPlay code, and compared with Apple Music, Spotify, Plexamp, Symfonium, Arpeggi and Manet. No servers were contacted.

This review recommends a single answer for each flow rather than listing options. Where it overrides the spec, the section is named and the change is spelled out. Copy is given in the §5 voice: plain and warm, about music rather than services, in sentence case. In-progress words end with "…".

---

## 0. The one model everything hangs on

Every item in Magpie has two independent facts. The UI must never mix them:

| Axis | Values | Shown by | Never shown by |
|---|---|---|---|
| **Where it lives** | In your library · In your Finds · On its way · Not in your library | Art shape (sleeve vs record), plus the row's **status line** (text and symbol, D3) | Buttons or colour alone |
| **On this iPhone** | Downloaded · Partly downloaded · not | The small `arrow.down.circle(.fill/.dotted)` **mark** beside the artist name (P1) | The status line |

There are three verbs for getting music. Each has exactly one word, and the words never overlap:

| Meaning | Word | Where it goes | Apple Music analogue |
|---|---|---|---|
| (a) Save to this phone for offline | **Download** | This iPhone | Download |
| (b) Bring music the owner doesn't have onto the server | **Try** (one song or album, on trial) / **Add to your library** (an artist, kept) | Your Finds / your library | Add to Library |
| (c) Move from Finds into the main library | **Keep** | Your library | (none) |

The rule that follows: **"download" only ever means this phone.** Nothing that touches the server says "download". Today "Add to Lidarr and download" (P3), "Download choices" and "Download defaults" (R18), "Simple downloads" (R18) and "Stalled downloads give up after" (R17) all break this rule. §8 renames every one of them.

Apple Music already taught users that "Add to Library" means "make it mine" and "Download" means "keep it on the phone". Magpie gets that understanding for free by using the same split.

---

## 1. Search results

### Problems, by user impact
1. **Dead taps (critical).**
   - Outside artist and album rows do nothing: they are information only (FLOWS §3e; `notYetArtistRow` and `NotYetAlbumRow` have no action).
   - In-library artist and album rows are reported dead too (R19 bug). Likely cause: `.simultaneousGesture(TapGesture())` on a `NavigationLink` inside a `List` in `SearchView.artistRow` and `albumRow`. In List rows on recent iOS, that gesture can swallow the link's activation. Record the recent search on `onAppear` of the destination, or in the `NavigationLink` value path, rather than with a competing gesture. Write the UI test first, as R19 says.
2. **The not-yet song row is only tappable on its "Try" capsule.** The row body is a dead zone. VoiceOver's default action is Try, but a finger on the title does nothing.
3. **A song tap plays the whole search-result list as the queue** (`app.play(songs, startAt: index)`). The next song is then a random result for the same query, which no comparable app does.
4. **The Try capsule uses the `play.fill` symbol**, including when it reads "Ask for it" (Patient tier), where nothing will play for hours. The symbol promises something that won't happen.
5. **A live request shows status, but the row still offers Try** in a few paths (R17 fixes this for search). This has to hold everywhere a not-yet item appears: Made for you, the Artist page's "Not in your library", and the outside pages.
6. **Request status words are inconsistent.** RequestCopy says "Looking" with no ellipsis, while the spec and wait screen say "Looking…".

### Recommended flow
The search field is unchanged: Library first, then **Not in your library** (D4).

| Row | Tap | Trailing control | Leading swipe → | ← Trailing swipe | Long-press |
|---|---|---|---|---|---|
| Library song | Plays **this song, then the rest of its album**. "Playing from" shows the album. Respects "Ask before replacing" | none | Add to queue | Play next | Play next · Add to queue · Add to playlist… · Favourite · Download · Go to album · Go to artist |
| Library artist | Opens Artist page | none | Add to queue (In order) | Play next (In order) | Play · Shuffle · Favourite · Download… · Reload artwork |
| Library album | Opens Album page | none | Add to queue | Play next | Play · Shuffle · Play next · Add to queue · Add to playlist… · Favourite · Download · Go to artist · Reload artwork |
| Not-yet song | Opens **Try sheet** (whole row) | `Try` capsule, symbol `plus.circle`; Patient: `Ask for it`, no symbol | none | none | Try · Go to artist · Go to album (both open outside pages) |
| Not-yet song with a live request | Opens **that request's page** | none (status replaces the button) | none | none | Open request · Stop looking… |
| Not-yet artist | Opens **outside Artist page** (R19) | none | none | none | none |
| Not-yet album | Opens **outside Album page** (R19) | none | none | none | Try this album · Go to artist |

Notes on the table:
- The library-song **Tap** column assumes one `getAlbum` call. Play the song at once, then append the album when it arrives. If that call fails, the song plays alone.
- The **Long-press** column lists menus in the order they appear (§4).

**Status line copy.** A row shows one line, always text plus a symbol:

| State | Text | Symbol |
|---|---|---|
| Not in your library | `Not in your library` | `circle.dashed` (existing badge) |
| Resolving / adding / searching | `Looking…` | spinning record |
| Grabbed, 0% | `Spotted it` | spinning record |
| Downloading on the server | `Bringing it home · 40%` | spinning record |
| Importing | `Bringing it home · almost there` | spinning record |
| Stuck or retrying | `Still looking…` | `magnifyingglass` |
| Ready, library | the row **becomes a library row** in place (R17) | sleeve |
| Ready, Finds | `New find` | record, with Keep available |

**Do not add:**
- a "Try" button on album or artist rows (tap opens the page, and the page has the actions);
- swipe actions on not-yet rows;
- a separate "Requests" section inside Search.

---

## 2. Artist and Album pages (library and outside)

### Problems, by user impact
1. **Too many competing header elements on one Artist page.** With R4, R7, P3 and R18 stacked, the header can show all of these at once:
   - the downloaded mark;
   - a Lidarr status line;
   - "Add to Lidarr and download";
   - an "Only in Finds" line with "Add to your library";
   - Play and Shuffle;
   - "Download all songs";
   - a star;
   - a hint and "Open Settings".

   That is up to five capsules and three status lines, and the user can't tell which "download" is which.
2. **"Add to Lidarr and download" (P3) breaks §5 twice.** It names a service, and it uses "download" for a server fetch right next to the phone "Download".
3. **"In Lidarr · Monitored / Not monitored / Not in Lidarr" is service language** shown to every user. The owner asked for this information (P3), and it is valid for a Curator, but §5 says admin detail lives behind "Details".
4. **R18's "Add to your library" for an Only-in-Finds artist is Keep under another name.** The find song menu also gets "Add to your library…". Two verbs for one action means users can't predict which one does what.
5. **R19 "Try in Finds" is wrong whenever Finds isn't set up.** Try then goes straight into the library (fallback mode), so the label is false.
6. **Per-track Try on an outside Album page causes duplicate requests.** Try's release picker often brings in the whole album anyway (FLOWS §3f, "Known behaviour"). Three track Tries mean three requests for one album, three of the five places, and three wait screens.
7. **"Not in your library" on the library Artist page is a dead end.** Its footnote says "To try one, search for a song from it." R19 builds outside Album pages but never says these rows should open them.
8. **The R4 "Download all songs" confirmation doesn't say where the songs go.**

### Recommended Artist page (library artist)

```
[ round artist picture ]
Artist Name                                   ☆ (toolbar)  ⋯ (toolbar)
<one status line>            ↓ Downloaded (mark, if any)
[ ▶ Play ]  [ ⤮ Shuffle ]
[ + Add more to your library ]   ← only when there is something to add and it's allowed
Popular
Albums
Not in your library   (each row opens the outside Album page)
```

- **Toolbar:**
  - **star** (Favourite, R7);
  - **⋯ More** (`ellipsis.circle`), containing:
    - `Download to this iPhone…`, or `Remove download` once downloaded;
    - `Reload artwork`;
    - `Details` (Curator only).
- **One status line.** The first one that applies wins:
  1. `Only in your Finds` (`record.circle`);
  2. `On its way: 2 albums` (spinning record), from live requests or the artist's monitored queue;
  3. `Following new releases` (`bell`);
  4. no line.
- **Details** (Curator, one disclosure sheet) is where the owner's P3 information goes, verbatim: `In Lidarr · Monitored`, the quality profile, root folder, and "Added by Magpie" or "Added outside Magpie". This keeps P3's intent and also obeys §5.
- **Single secondary capsule rule.** At most one capsule under Play and Shuffle:
  - Only in Finds → **`Keep <artist>`**: runs Keep on every find of the artist, then the Add sheet preset to "Their other albums";
  - not in Lidarr, or Magpie-added and not monitored → **`Add more to your library`**: opens the Add sheet (§5);
  - otherwise → none.
- **Changes switched off.** Replace the capsule with a footnote: `Turn on Allow Magpie to change your library in Settings › New music to add more.`, plus `Open Settings`. Never show both.
- **Added outside Magpie** (owner-data rule): no capsule. Details says `Added outside Magpie. Change it where you added it.`
- **Download to this iPhone…** confirmation: `Download 143 songs to this iPhone? About 1.2 GB.` with the buttons `Download` and `Cancel`.

### Recommended outside Artist page (R19)
- The header uses the R15 picture, plus the status line `Not in your library` (D3 symbol).
- Primary capsule: **`Add to your library`**, which opens the Add sheet. The secondary text button is gone; Play and Shuffle don't exist here.
- Sections: Albums, EPs, Singles; More (other secondary types); Popular if a source exists.
  - Each album row opens the outside Album page.
  - Each song row has a **`Try`** capsule. Never "Try in Finds": the Try sheet already says where it lands (`model.tryNote`).
- If an album of this artist has a live request, its row shows status and opens that request.
- When the artist arrives in the library, the page swaps itself for the library Artist page in place, keeping scroll position where possible (R17 live rows).

### Recommended outside Album page (R19)
- Cover, title, artist (which opens the outside Artist page), year and type.
- Primary capsule: **`Try this album`**.
- Secondary text button: `Add <artist> to your library`.
- **Track rows have no per-track Try.** Tapping a track runs **Try this album, starting from this song**: the request targets the album's release group, and when it's ready, playback starts at that track (D6 still governs landing).
- **Dedupe rule:** a Try for any song whose album already has a live request attaches to that request. It never starts a second one.

### Recommended Album page (library)
- The header is unchanged, plus a star and ⋯ in the toolbar.
- ⋯ contains `Add to playlist…`, `Go to artist`, `Reload artwork` and `Details` (Curator).
- The Download capsule stays under Play and Shuffle, as today and as in Apple Music. Its confirmation for large albums isn't needed, but its menu reads `Remove download`.
- If the album is a find, a `Keep` capsule appears instead of the Download capsule. Downloading a find stays possible from ⋯.

**Do not add:**
- a Lidarr status line on Album pages;
- "Monitor album" toggles;
- any release-type controls on the page itself (they live in the Add sheet only);
- Popular on outside pages unless a source already exists (R19 call is right).

---

## 3. Request lifecycle: Try → wait → leave and return → Ready → play

### Problems, by user impact
1. **A ready find has no Keep on its own request page.** Ready shows only `Play`, so the user must go to Library › Finds to Keep the thing they're looking at.
2. **The wait screen lives inside a modal sheet whose button says "Leave".** "Leave" reads as "abandon". The hint telling users where to find it later ("Library, Requests") is only spoken by VoiceOver.
3. **"Requests" means two things.** Library › Requests is the list of what's on its way. Settings › Requests is the Lidarr setup page. The Try sheet's "Open Settings" goes to the second, and the Patient copy points to the first.
4. **The R17 copy is technical:**
   - "That source stalled";
   - "The current download will be removed and blocked";
   - the setting "Stalled downloads give up after".
5. **R17's stall timer counts from the start of the queue item.** Soulseek peers often sit "queued remotely" for minutes before the first byte arrives. At the owner's 1-minute default, Magpie will blocklist good sources that simply hadn't started, and use up all five retries in about five minutes. Each blocklist entry also stays in the owner's Lidarr permanently.
6. **The returning user gets no single obvious place to look.** The Play now banner (D6) appears only on Ready, so nothing is visible while a request is in progress.

### Recommended flow
1. **Search → tap a not-yet song.** The Try sheet shows:
   - the record art (R16 cover);
   - the title and `Artist · Album · 3:58`;
   - the line `Not in your library`;
   - the tier line, then the note:
     - Finds on: `New artists go into your Finds first, so you can try them before they join your library.`
     - Finds off: `It goes straight into your library.`
   - the button **`Try it`**, or **`Ask for it`** on the Patient tier.
2. **Tap Try it.** The soft haptic plays and the sheet becomes the wait view: `Looking…` → `Spotted it` → `Bringing it home · 40%` → `Ready`. The toolbar button reads **`Done`**, never "Leave". The footnote under the stages reads `You can keep browsing. It plays next when it's here.`
3. **Done.** The user is back on the search list at the same scroll position. The row now shows the status line, and its tap opens this request (R17).
4. **Return paths, all showing the same live status:**
   - the search row;
   - Library › **Requests**, with the "2 on their way" detail;
   - the Artist page status line `On its way: …`;
   - the local notification;
   - the Play now banner.
5. **Ready.**
   - Still on the wait view, with nothing playing: it plays.
   - Otherwise: it goes next, with the banner `<Title> is here · Play now`, and the search row turns into a library row in place (R17).
6. **A Ready find's request page** shows **`Play`**, then **`Keep`**, then `Not for me…`. Keep's result appears inline on the page, followed by the Add sheet preset to "Their other albums" (D5).
7. **A stall.** The status reads `That copy stopped coming. Looking for another…`. After five automatic retries: `Still looking…`, with **`Find another copy`**.
8. **Find another copy** (the manual retry, renamed from Search again). Only when a copy is in progress, confirm with:
   - title: `Look for another copy?`
   - message: `Magpie drops the copy it's getting now and won't pick that one again.`
   - buttons: `Find another copy` and `Cancel`.

   It is rate-limited to once per 30 s, as specced. While limited, the button shows `Find another copy` disabled with the footnote `You can ask again in a moment.`
9. **Stop looking.** Keep the current copy: `Stop looking for <title>?` / `Magpie stops asking for it. Nothing is deleted.`

### Spec changes
- **R17 stall rule.** Start the 60 s clock only once the item has made progress at least once (`sizeleft` < `size`), or once its tracked state is downloading. A remote queue counts as "still looking", not as stalled. Keep the owner's 1-minute default. Rename the setting to **`Give up on a stuck copy after`** (1, 2, 5, 10 min).
- **R17 copy:**
  - "That source stalled. Looking for another…" becomes `That copy stopped coming. Looking for another…`
  - "Search again" becomes `Find another copy`
  - the confirmation becomes the one in step 8.
- **R16 / Activity.** The Ready-find request page adds Keep and Not for me. Library › Requests rows for Ready finds get a leading swipe **Keep**.
- **Settings › Requests** becomes **Settings › New music** (Lidarr connection, Finds, "When you add an artist" defaults, the change log). Library › Requests keeps its name. Update every "Open Settings" pointer and the hint strings, for example `ArtistLidarrPresentation.hintText`.
- **RequestCopy.** `"Looking"` becomes `"Looking…"`, and the hint texts say "Allow Magpie to change your library" in place of "change Lidarr". This is UI copy only; the setting's identity is unchanged.

**Do not add:**
- a Live Activity or Dynamic Island (D7 stands);
- a request-count badge on the tab bar;
- a "pause request" control;
- per-request source details for anyone but the Curator, and for the Curator only behind Details.

---

## 4. Queue interactions

### Problems, by user impact
1. **Full swipe on a trailing edge that sometimes destroys.** R12 makes trailing = Play next everywhere, except playlist, Downloads and Finds rows, where trailing stays destructive. A full trailing swipe in a playlist would delete a song from a shared server playlist when the user meant "Play next". Muscle memory makes this mistake certain.
2. **The collection swipe popup ("In order / Shuffled") turns a one-motion gesture into two steps.** It interrupts the very gesture meant to be quick. No comparable app asks.
3. **"Ask before replacing" triggers on any queue of more than one song.** Almost every queue qualifies, so a user who turns it on gets asked constantly and turns it back off. The queue worth protecting is the one the user built by hand.
4. **The R9 More menu duplicates the Sleep timer**, which already lives in the bottom row (D43), and puts eight items in one flat list.
5. **Context menus use Title Case** ("Play Next", "Add to Queue") while the rest of the app uses sentence case.

### Recommended model
- **Tap to play replaces the queue** with the context: the album, the playlist, or for search a song plus its album. Apple Music, Spotify and Plexamp all agree on this.
- **Swipes on song rows** (owner defaults kept):
  - leading (→) = `Add to queue`, full swipe allowed;
  - trailing (←) = `Play next`, full swipe allowed.

  The toast lasts about 1.5 s: `Playing next` / `Added to queue`. VoiceOver announces the same text.
- **Rows with a destructive action** (playlist, Downloads, Finds) have two trailing buttons: [`Play next`] [`Remove from playlist`, red]. **Full swipe is off on that edge**, so a destructive action always takes a deliberate second tap.

  This changes R12. R12 moves the custom trailing action to the long-press menu; instead, it stays on the edge without full swipe.
- **Swipes on album, playlist and artist rows** play in order, with no popup. The toast has one action: `Added 12 songs to the queue · Shuffle` (the button lasts 4 s and reshuffles just that block). Shuffled insertion stays one tap away without blocking the gesture.

  This changes R12. Drop the popup.
- **Ask before replacing the queue** (default off, kept). It triggers only when **Up Next contains songs the user added** with Play next or Add to queue. The dialog:
  - title: `Replace your queue?`
  - message: `You added 4 songs to Up next.`
  - buttons: `Replace` · `Play next` · `Cancel`.

  It never triggers in CarPlay (R12, D12).
- **Long-press menus share one order**, with groups separated by dividers:
  1. Play next · Add to queue
  2. Add to playlist… · Favourite (or Unfavourite)
  3. Download (or Remove download)
  4. Go to album · Go to artist
  5. Finds only: Keep · Not for me…
  6. Collections only: Reload artwork
- **Now Playing More menu (R9).** The `ellipsis.circle` sits in the top bar's empty right slot. It is added on the right in Classic too. Its groups:
  1. A find: **Keep** · Not for me…
  2. Add to playlist… · Favourite (shown in lyrics mode only, where the star is hidden, D47)
  3. Download / Remove download
  4. Go to album · Go to artist
  5. Song info

  Changes from R9:
  - remove Sleep timer, which stays in the bottom row;
  - remove "Add to your library…", which is Keep for a find;
  - Favourite appears only when the star isn't visible.
- **R10** title links are right. The album name in "Playing from" and the artist name are buttons.

**Do not add:**
- queue history;
- "Play last" as a third option;
- per-swipe haptic patterns beyond the system's;
- a queue-save-as-playlist (later, if ever);
- swipe customisation beyond the R12 picker (no per-screen settings).

---

## 5. Adding an artist: the choices sheet and simple mode (R18)

### Problems, by user impact
1. **The "Simple downloads" toggle saves no taps.**
   - Simple mode shows a confirmation alert with one tap to confirm.
   - The sheet with the defaults preselected and one primary button also takes one tap.

   The toggle adds a setting the user has to understand, and hides consequential choices (a whole discography, lossless) behind an alert. It is a mistake. Remove it.
2. **"Download choices" and "Download defaults" collide with phone downloads** (Settings › Downloads & Storage).
3. **The default "The whole artist" can pull hundreds of gigabytes** behind a one-line alert.
4. **The release-type UI is jargon.** "Studio" as a toggle that's on by default invites switching off the albums themselves. "Official releases only (always, not a choice)" doesn't need to be shown at all.
5. **"This album only" appears where there is no album context**, for example on the Artist page.

### Recommended: one Add sheet everywhere
This sheet is used by: Add to your library (outside artist), Add more to your library (library artist), Keep → more (after Keep, replacing the Bring in more sheet's body), and the old P3 add.

It is a half-height sheet (`.medium` detent, expandable):
```
Add <Artist> to your library                      [Cancel]
What to add
  ◉ Their albums and EPs            about 14 hours
  ○ Just albums                     about 9 hours
  ○ Everything, singles too         about 17 hours
  ○ Just this album                 (only with an album in context)
  Also add   [ ] Live albums   [ ] Soundtracks
Quality
  ◉ Lossless          ○ Smaller files
[ ] Follow new releases
    New albums come in by themselves.
[        Add to your library        ]      ← primary
```
- **Presets.** The selections come from **Settings › New music › When you add an artist**.
  - The defaults are: Albums and EPs, Lossless, Follow off.
  - That Settings page is the R18 "Download defaults", renamed.
- **The primary button's label matches the context:**
  - `Add to your library`;
  - `Add more to your library`;
  - after Keep: `Add more` (the sheet title is `Kept. Add more from <artist>?`, with `Not now` as cancel).
- **Size before commitment.** The "about N hours" detail is always shown when known. When "Everything" exceeds 50 hours, add the footnote `That's a lot of music. It can take a while to arrive.`
- **After tapping:**
  - the sheet closes;
  - the page's status line becomes `On its way: 9 albums`;
  - the albums appear as on-their-way rows in "Not in your library".
- Studio is always included. Official releases only is applied silently.

### Spec changes
- **R18:**
  - delete "Simple downloads" and its alert;
  - rename "Download choices sheet" to **Add sheet**;
  - rename "Download defaults" to **When you add an artist**;
  - remove the Studio toggle (always on);
  - show "Just this album" only with an album in context.
- **R18 "Only in Finds → Add to your library"** becomes **`Keep <artist>`**: Keep each find, then the Add sheet. The find song's More and long-press item is **`Keep`**, not "Add to your library…".
- **P3 "Add to Lidarr and download"** becomes the Add sheet via `Add more to your library`. P3's confirmation alert is replaced by the sheet. The pick-one-of-several-artists step stays, as a list inside the sheet's first screen:
  - `Which <artist>?`
  - each candidate's disambiguation.
- **Try (single song) is unchanged** (R18 call is right): no sheet, Fast Start, Finds.

**Do not add:**
- per-download quality overrides beyond Lossless and Smaller files;
- a compilations toggle;
- monitor-option jargon ("future", "missing", "existing");
- a summary screen after adding.

---

## 6. Playlists (R8)

### Problems, by user impact
1. **The delete confirmation names Navidrome:** "This removes it from Navidrome for everyone using it".
2. **R8 puts "Download / Remove download" inside the playlist More menu**, while albums keep a header capsule. The same thing ends up in two places on sibling pages.
3. **Read-only playlists aren't distinguished visibly.** Edit items vanish, but nothing says why.
4. **The duplicate warning is the right call, but the copy needs to name the playlist and the song.**

### Recommended
- **Add to playlist…** (song, album, playlist and Now Playing menus) opens a sheet titled `Add to playlist`:
  - the first row is `New playlist…`;
  - then the user's own playlists, most recently changed first, with cover and count.

  A tap adds, closes the sheet, and shows the toast `Added to <Playlist>`. If the song is already in that playlist, an alert:
  - title: `Already in <Playlist>`
  - message: `Add <Song> again?`
  - buttons: `Add again` · `Cancel`.

  When adding several songs, only the duplicates are asked about, in one alert: `3 of these are already in <Playlist>.`, with the buttons `Add all` · `Skip those` · `Cancel`.
- **New playlist…** shows a name alert:
  - title: `New playlist`
  - placeholder: `Name`
  - buttons: `Create` · `Cancel`.

  From the Add sheet, it creates and adds in one go. The Playlists list toolbar has a `+` that opens the same alert.
- **Playlist page:** the header capsules are Play · Shuffle, and the Download capsule as on Album (consistent). The ⋯ menu holds:
  - `Add to queue`
  - `Rename…`
  - `Delete playlist…`
  - `Reload artwork`
- **Rename alert:**
  - title: `Rename playlist`
  - buttons: `Save` · `Cancel`.
- **Delete confirmation:**
  - title: `Delete "<Name>"?`
  - message: `It's deleted from your music server for everyone who uses it.`
  - buttons: `Delete playlist` (destructive) · `Cancel`.
- **Remove a song:** the trailing swipe has `Remove from playlist` (red, **no full swipe**, see §4), with no confirmation. The row animates out, and VoiceOver announces `Removed from <Playlist>`.
- **Read-only playlists:** a footnote under the count says `Made by <owner>. You can play it but not change it.` They show no edit items.

**Do not add:**
- reorder (R8 call is right);
- multi-select edit mode;
- playlist folders, smart playlists or custom covers;
- an undo after remove (Subsonic can't reinsert at an index, so an "undo" would silently move the song).

---

## 7. CarPlay parity and what stays simpler (D12)

### What the car gets in round 11
- **Search:**
  - library songs and albums play or open, and the R19 fix must cover the car's album rows too;
  - not-yet songs offer `Try it next` / `Cancel`, as today;
  - a not-yet song with a live request shows its status as the row detail (`Bringing it home · 40% · Artist`). Tapping it shows the alert `On its way` / `It goes next when it's here.` with `OK`. **Never a second Try** (dedupe; R17 says "CarPlay-irrelevant", which is wrong).
- **Now Playing:** shuffle and repeat mirror the phone, including Repeat one (R6). The like button is Favourite (R7). The add-to-library (+) button is Keep for a find (D12).
- **Album artists only** applies to the car Artists list (R11).
- **Tap to play replaces the queue**, with no confirmation in the car (R12).

### What stays phone-only
- the Add sheet, Add to your library, Keep <artist>, Not for me, Find another copy;
- outside Artist and Album pages; outside artist and album search rows (they are left out in the car);
- playlist editing, Add to playlist, swipe actions, downloads management, Details.

### Copy in the car describes and never instructs (D12)
| Situation | Car copy |
|---|---|
| A tap on a live request | `On its way` / `It goes next when it's here.` |
| Try isn't set up | `Bringing songs home isn't set up on this iPhone.` (existing) |
| Five on their way | `Five songs and releases are already on their way.` (existing) |

**Do not add:** a Requests tab or list, Downloads management, or a "Try this album" in the car. Each is a decision a driver shouldn't make.

---

## 8. Spec errata: everything this review changes

| Where | Current | Change to |
|---|---|---|
| P3 | Status `In Lidarr · Monitored` / `Not monitored` / `Not in Lidarr` on the page | One voiced status line (§2). The Lidarr wording moves to **Details** (Curator) |
| P3 | Button `Add to Lidarr and download`, plus a confirmation alert | `Add more to your library` → Add sheet |
| P3 hint | `Turn on Allow Magpie to change Lidarr in Settings › Requests…` | `Turn on Allow Magpie to change your library in Settings › New music to add more.` |
| R4 | `Download all songs` capsule; `Download 143 songs by X? About 1.2 GB.` | ⋯ → `Download to this iPhone…`; `Download 143 songs to this iPhone? About 1.2 GB.` |
| R8 | `This removes it from Navidrome for everyone using it.` | `It's deleted from your music server for everyone who uses it.` |
| R8 | Playlist Download inside More | Download capsule under Play / Shuffle, as on Album |
| R9 | Sleep timer in More; Favourite always; no Keep | Sleep timer stays in the bottom row only; Favourite only in lyrics mode; Keep and Not for me first for a find |
| R12 | Custom trailing action moves to long-press on destructive rows | Keep both on the trailing edge; destructive **never** full-swipe |
| R12 | Collection swipe → "In order / Shuffled" popup | No popup: in order, with a toast `· Shuffle` action |
| R12 | Ask before replacing when queue > 1 song | Only when Up next holds songs the user added |
| R17 | `That source stalled. Looking for another…` | `That copy stopped coming. Looking for another…` |
| R17 | `Search again` / "…removed and blocked." | `Find another copy` / `Magpie drops the copy it's getting now and won't pick that one again.` |
| R17 | Stall clock from queue-item start | From first progress; a remote queue isn't a stall |
| R17 | `Stalled downloads give up after` | `Give up on a stuck copy after` |
| R17 | Live-request rows "CarPlay-irrelevant" | The car shows the status and never offers a second Try |
| R18 | `Simple downloads` toggle and alert | Removed. The Add sheet is always shown, with defaults preselected |
| R18 | `Download choices sheet` / `Download defaults` | **Add sheet** / **When you add an artist** |
| R18 | Studio toggle, "Official only" shown | Studio always on, not shown. Official applied silently |
| R18 | Only in Finds → `Add to your library`; find menu `Add to your library…` | `Keep <artist>`; find menu `Keep` |
| R19 | `Try in Finds` | `Try` (the sheet says where it lands) |
| R19 | Per-track Try on outside Album page | A track tap = Try this album, starting from that song. Dedupe by album |
| R19 | Library Artist page "Not in your library" rows: no action | Each row opens the outside Album page. Delete the footnote "To try one, search for a song from it." |
| Settings | `Settings › Requests` | `Settings › New music` (Library › Requests keeps its name) |
| Try sheet | `Leave` | `Done`, plus the footnote `You can keep browsing. It plays next when it's here.` |
| Request page | Ready find: `Play` only | `Play` · `Keep` · `Not for me…` |
| Search | Song tap queues all results | The song, then its album |
| Search | `.simultaneousGesture` on NavigationLink rows | Remove it (probable cause of the R19 dead taps) |
| SongRow | `Try` capsule with `play.fill` | `plus.circle` for Try; no symbol for `Ask for it` |
| Copy | `Play Next` / `Add to Queue`; VoiceOver `Star`; `Remove from this phone` | `Play next` / `Add to queue`; `Favourite`; `Remove download` |

---

## 9. Glossary: one word per concept, used everywhere

| Concept | UI word(s) | Never in the UI |
|---|---|---|
| The main collection on the server | **your library** | Navidrome, server library, main library (except the Finds setup picker label) |
| The trial area | **Finds**; one item is **a find**; unplayed ones are **New finds** | samples, trial folder, Finds library |
| Not on the server | **Not in your library** | missing, unavailable, not in Navidrome |
| Fetch one song or album on trial | **Try** · **Try this album** · Patient tier: **Ask for it** | Try in Finds, request, download, grab |
| A fetch in progress | **on its way**; steps **Looking… → Spotted it → Bringing it home → Ready** | queued, searching indexers, downloading |
| The record of a fetch | **request**; the list is **Requests** (Library) | job, task, order |
| Stop a fetch | **Stop looking** | cancel request, delete |
| Get a different copy | **Find another copy** | search again, blocklist, retry |
| Find → library | **Keep** (also **Keep <artist>**) | add to library, move, import |
| Delete a find | **Not for me** | delete, remove, reject |
| Bring an artist's music in, kept | **Add to your library** · **Add more to your library** · after Keep: **Add more** | Add to Lidarr, monitor, download, Bring in more (retired as a label) |
| Automatic new releases | **Follow new releases**; status **Following new releases** | monitor new items |
| Settings for the above | **Settings › New music** · **When you add an artist** | Requests (in Settings), Download defaults |
| Save for offline | **Download** · **Downloaded** · **Partly downloaded** · **Remove download** · "to this iPhone" | Save, Offline, Remove from this phone |
| Downloads in progress | **Downloading now** | Transfers, Queue |
| Queue placement | **Play next** · **Add to queue**; toasts **Playing next** / **Added to queue** | Play last, Add to end of queue, Play Next (title case) |
| The queue's front | **Up next** | Up Next |
| Star | **Favourite** / **Unfavourite**; list **Favourites** | Star, Like, Love |
| Quality choice | **Lossless** · **Smaller files**; hallmarks **Sample** · **Lossless soon** · **Lossless** · **Hi-Res** | FLAC, MP3, profile names |
| Playlists | **Add to playlist…** · **New playlist…** · **Rename…** · **Delete playlist…** · **Remove from playlist** | Edit playlist, update |
| Admin detail | **Details** (Curator only), the only place service names may appear | |

---

## 10. Seamlessness principles to enforce (review checklist)

1. **No dead taps.** Every row opens something sensible: a library item plays or opens; a not-yet item opens Try or its page; a live request opens its request. A UI test walks every row type in Search, Artist, Album, Playlist and Finds and asserts that a tap changes the screen or the queue.
2. **One status, where the item is.** An item's status is shown on its own row and page header, in text plus a symbol (D3), and updates live from the runner and match-index events. Views never poll. No toast-only or banner-only status.
3. **No duplicate requests.** Requests are keyed by recording MBID and by album release group. Any Try, Add or Keep for something with a live request opens or attaches to that request. This applies on the phone and in the car.
4. **One verb per concept** (§9). "Download" means this iPhone only. Service names appear only under Details.
5. **Never lose your place.** Sheets dismiss back to the same scroll position. Search keeps its query and results across pushes and tab switches. Pages update in place when an item lands (R17). Now Playing links push onto the current tab rather than switching tabs (R10).
6. **Consequential actions show their size first.** Anything that adds more than one album to the server, or more than one album to the phone, shows "about N hours" or "about N GB" before the button.
7. **Destructive actions never fire from a full swipe**, and never sit on the same edge as a default action without a second tap.
8. **One primary capsule per page header** beyond Play and Shuffle. Everything else goes in the toolbar ⋯.
9. **The car does less, not differently.** The same words and rules apply, with fewer actions and no decisions that need reading. It describes and never instructs (D12).
10. **Settings only when a sensible default can't serve.** No toggle that merely skips a confirmation (this is the reason Simple downloads is removed).
