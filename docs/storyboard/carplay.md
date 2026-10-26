# CarPlay — Magpie

Status: proposal for owner review · 2026-10-26 · pairs with `design-language.md` and the product spec (`docs/superpowers/specs/2026-10-26-serverless-architecture-design.md`). Research basis: `docs/research/apple-platform-architecture.md` §4 and the Amperfy CarPlay notes in `docs/research/ios-clients.md` §4.5.

Artboards (canvas, 800×480 each): `CP-Home`, `CP-Library`, `CP-Album`, `CP-Search`, `CP-SearchResults`, `CP-TryAlert`, `CP-NowPlaying`, `CP-NowPlaying-Sample`, `CP-ReadyToTry`, `CP-States`. File names are kept so links don't break: `CP-ReadyToTry` is the **Finds** tab and `CP-NowPlaying-Sample` is Now Playing for a find.

## 1. What we can and can't change

CarPlay audio apps draw nothing of their own. Everything is a system template. We control five things:

1. **Artwork images.** We pre-render them. In-library items get the square sleeve. Not-yet items get a **round record image** with grooves and a spindle hole, rendered into the PNG. Finds (songs brought home to try) also get the days-left arc and the fade baked in.
2. **Text.** Titles and detail lines. Detail lines carry our state words: "Not in library", "Just landed", "On its way · about 20 s", "5 days left", "New find · 7 days". The quality stamp "Sample" (the MP3 trial file) stays a stamp; it never names the shelf.
3. **Accessories and state.** Playing indicator, disabled rows (`isEnabled = false`), tab badge (`showsTabBadge`), iOS 27 progress overlays on list images, and custom accessory images such as the "Try" capsule.
4. **Tint.** Sheen (#3CC4B8), used only as tint (selected tab icon, playing indicator, Try capsule, Keep button).
5. **Now Playing custom buttons.** `CPNowPlayingImageButton` lets us draw our own glyphs, such as the sleeve-with-check for Keep.

All text uses the system font. There's no New York serif and no motion in CarPlay. The Character dial changes only the artwork renderer: Classic draws not-yet items as a dimmed square, Signature and Immersive draw the record. The artboards expose this as the `character` tweak.

## 2. Template tree

Depth counts the root tab bar as 1. The audio-app limit is **5**.

```
CPTabBarTemplate (root, 4 tabs = the audio-app maximum)          depth 1
├─ Home      CPListTemplate                                       depth 1 (tab root)
│   ├─ "Jump back in"  CPListImageRowItem (5 elements, card style)
│   │     tap element → play album/mix → push Now Playing         depth 2
│   │     tap row title → CPListTemplate "Jump back in" (top 12)  depth 2 → album 3 → NP 4
│   ├─ Daily Jams            → play → Now Playing                 depth 2
│   ├─ Weekly Exploration    → play → Now Playing                 depth 2
│   └─ New finds (n)         → switches to the Finds tab (no push)
├─ Library   CPListTemplate
│   ├─ Playlists  → CPListTemplate (smart top-N)                  depth 2 → playlist 3 → NP 4
│   ├─ Artists    → CPListTemplate (A–Z sections, paged)          depth 2 → artist 3 → album 4 → NP 5  ← deepest path, exactly at limit
│   ├─ Albums     → CPListTemplate (Recently added / A–Z)         depth 2 → album 3 → NP 4
│   ├─ Downloaded → CPListTemplate                                depth 2 → album 3 → NP 4
│   └─ Finds (n)  → switches to the Finds tab
├─ Finds     CPListTemplate, sections: New finds · On its way · Still deciding
│   ├─ new find row → play now → Now Playing                      depth 2
│   ├─ on-its-way row → disabled (nothing to do yet)
│   └─ find row    → play → Now Playing (Keep button)             depth 2
└─ Search    CPSearchTemplate (iOS 27; see open question Q1)
    ├─ empty text → recent searches as result items
    ├─ library result → play → Now Playing                         depth 2
    ├─ not-yet result → CPActionSheetTemplate (modal, no depth)
    │     Try it → Now Playing (waiting state) · Up Next → stays put
    └─ artist result → CPListTemplate artist songs                 depth 2 → NP 3

Modals (presented, not pushed): CPActionSheetTemplate (Try), CPAlertTemplate (Couldn't spot it yet).
Now Playing: CPNowPlayingTemplate.shared, pushed; "Up Next" (nav-bar button) pushes the queue list (+1).
MiniPlayer: allowsMiniPlayer = true, so the system shows it on browse screens and we don't draw it.
```

**Depth guard.** The Artists path reaches 5 at Now Playing. From the artist screen, *Play* and *Shuffle* jump straight to Now Playing, so we skip the album push there. Any "More…" pagination is done **in place** (we replace the list's sections) and never pushes, because pushing would cost depth. Up Next from the deepest path pops one level first. Code asserts `templates.count ≤ 5` before every push.

**Item limits.** Read `CPListTemplate.maximumItemCount` / `maximumSectionCount` at runtime. In limited UI it's often 12, and we never hard-code it.
- Home shows at most 1 image row plus 3 to 5 rows, so it fits any limit.
- Long lists are **smart top-N** (Recently played, Recently added, Starred, Downloaded). A–Z browsing exists only under Artists and Albums, paged in place with a final "Show 12 more" row.
- When the limit truncates a list, the last row says so ("Showing 12 of 214 · Show more"). It never truncates silently. This is Amperfy bug #779/#764, where lists stopped at "A–H".
- The limit is per list, not per section: divide by section count and drop empty sections first.
- `CPListImageRowItem.maximumImageCount` caps "Jump back in". We render up to 5 and degrade to fewer.

**Artwork.** Size every image to `maximumImageSize` × `carTraitCollection.displayScale`. Render light and dark variants: the record's spindle hole shows the list background. Cache rendered records/sleeves on disk under after-first-unlock protection. A record image for a find is re-rendered daily as its arc shrinks and its colour fades.

## 3. Screen notes

| Artboard | Template | Notes |
|---|---|---|
| CP-Home | Tab bar › List | "Jump back in" image row mixes sleeves and one find (Analog Summer) as a record with its arc. Last row "New finds (1) · Harbour Lights". The Finds tab carries a badge dot while a new find is waiting. |
| CP-Library | List | Five rows only. "Finds (3)" uses a record image. |
| CP-Album | List with iOS 27 details header | Header: art, title, artist, "10 songs · 41 min · Downloaded", Play / Shuffle. Playing track shows the leading playing indicator in tint. Not-downloaded tracks would carry the system cloud accessory. |
| CP-Search | CPSearchTemplate | Field with the car's dictation button; recent searches as items. The keyboard is the car's own and may be unavailable while moving; voice is always available. |
| CP-SearchResults | CPSearchTemplate results | Library results first (spec: library always outranks), then not-yet songs as records with "Not in library" plus a Try capsule accessory, then the artist. An artist not in the library sits in a record ring; artists you have are plain circles. |
| CP-TryAlert | CPActionSheetTemplate | Title + one message line pair (≤2 lines): "Quick fetch · about 30 seconds. It plays once it's home." Three actions; "Try it" is the tinted default. |
| CP-NowPlaying | CPNowPlayingTemplate | Custom buttons: Favourite (star, tinted when on), Shuffle, Repeat. Up Next = system nav-bar button. Playback rate deliberately hidden. Scrubbing via `changePlaybackPosition`, which needs a known duration (see §6). |
| CP-NowPlaying-Sample | CPNowPlayingTemplate | Round record artwork with full arc; album line "Saltwater Hymns · New find · 7 days". **Keep** (sleeve + check) replaces Favourite. After Keep: the image swaps to the square sleeve, the album line becomes "Saltwater Hymns · Kept · Lossless soon", and the button becomes a filled sleeve that can't be tapped again. |
| CP-ReadyToTry | List (the Finds tab) | Same shelf as the phone: **New finds** — Harbour Lights (Corin Hale, 7 days); **Still deciding** — Analog Summer (Velvet Static, 5 days left), Copper Wire (Ines Morrow, leaves in 2 days, most faded). New-find rows end in a play glyph. When something is on its way, an "On its way" row appears, disabled, with an iOS 27 progress overlay ring on the record plus "On its way · about 20 s". Finds show days left as text and as the baked arc and fade. |
| CP-States | Composite board | 1: restarted and never unlocked; 2: cold launch, never set up; 3: library out of reach, downloads only (other rows disabled); 4: CPAlert "Couldn't spot … yet — we'll keep looking". |

## 4. Driver-safety rules (non-negotiable)

1. **No typing outside the search template.** No sign-in, no setup and no settings in the car. Anything that needs input says "Do it when you're parked" and nothing more.
2. **Try costs at most one confirmation tap.** Tapping a not-yet song opens one action sheet; "Try it" is the default. No second sheet and no quality, discography or "Add" questions. Those choices use the household defaults.
3. **Never interrupt the current song for something the driver didn't just ask for.** A song that becomes ready joins **Up Next** if anything is playing. It plays immediately only if nothing is playing.
   - The exception is the driver's own explicit "Try it": if the driver is waiting on it, it starts when ready. If music was playing, the current song keeps going until the tried song is ready, then crossfades. *(Owner check: Q4.)*
4. **Glanceable copy.** Titles ≤ ~32 characters; messages ≤ 2 lines; numbers in plain words ("about 30 seconds", "5 days left").
5. **No modal for passive events.** Songs brought home in the background go to the Finds tab badge, never to an alert. An alert is shown only if the driver is waiting on that exact song (State 4).
6. **Never ask the driver to touch the phone.** Locked-phone and setup states say "when you're parked".
7. **No lyrics, no video, no visualizer** in CarPlay.
8. **No service words.** Never Navidrome, Lidarr, ListenBrainz, Soulseek or "server". The library is "your library"; "Home" is only the tab.

## 5. Siri and App Intents

Ship both stacks (research §4.4): SiriKit `INPlayMediaIntent` / `INAddMediaIntent` / `INUpdateMediaAffinityIntent` handled in-app, and App Intents `.audio` schema (`playAudio` + `IntentValueQuery` over `AudioEntity`, `updateAudioAffinity`). Index library entities with `IndexedEntity` so vague requests resolve.

| Phrase | Resolves to | Result |
|---|---|---|
| "Play Glasshouse in Magpie" | album in library | plays now |
| "Play Juniper and the Fold in Magpie" | artist in library | artist shuffle |
| "Play Daily Jams in Magpie" | mix | plays now |
| "Shuffle my downloads in Magpie" | Downloaded | plays offline set |
| "Try Harbour Lights by Corin Hale" / "Play Harbour Lights by Corin Hale in Magpie" | **not in library** | Siri replies "It's not in your library yet. Bringing it home now. It'll play in about 30 seconds." Same rules as the Try sheet: plays when ready if nothing is playing, otherwise goes to Up Next. |
| "Keep this song" / "Add this to my library" | current find | Keep (`INAddMediaIntent`) |
| "I like this song" | current track | Favourite (`updateAudioAffinity`) |
| "What are my new finds?" | Finds list | Siri reads up to 3 titles, then "Want me to play them?" |

For a not-yet match, Siri never asks a follow-up beyond one yes/no confirmation, and only when the match is ambiguous ("Harbour Lights by Corin Hale?"). The assistant cell (`CPAssistantCellConfiguration`, `.playMedia`) sits at the top of Home and Search.

## 6. Locked phone and cold launch

- **Default: it just works.** The database, artwork cache, downloads and credentials use `completeUntilFirstUserAuthentication` / `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. Once the phone has been unlocked once since boot, CarPlay runs fully while it's locked.
- **Cold launch from the car.** The CarPlay scene boots the playback engine, library cache and network layer without the phone UI (no dependency on the phone scene). It shows cached Home immediately and refreshes in the background, with no spinner on the root.
- **Before first unlock after a restart** (rare): nothing is readable, so the root list shows an empty view: "Unlock your iPhone once to connect" plus "It restarted, so your music stays locked until then. Do it when you're parked." It recovers by itself on unlock.
- **Never set up on this iPhone:** "Set up Magpie on your iPhone" plus "Do it when you're parked."
- **Library out of reach (not on Home Wi-Fi, no Away route, or no signal):** a section header reads "Playing downloads — your library is out of reach". Downloaded rows stay enabled and everything else is disabled with "Back when your library is in reach". Try is unavailable, so not-yet rows are disabled. Recovers silently.
- **Scrubbing** needs a known duration. Use the API `duration` as the authority and `estimateContentLength=true` for transcodes (Amperfy #305/#672), so the scrubber never disappears.
- **Same code path as the phone.** Uncached songs must stream from CarPlay exactly as they do on the phone (Amperfy #764). Template building stays off the main thread (Amperfy #857 freeze).

## 7. Open questions for the owner

- **Q1. Tabs: Home · Library · Finds · Search.** That uses all 4 slots. If `CPSearchTemplate` can't be a tab root in iOS 27, the Search tab becomes a list ("Search by voice", "Type a search", recents) that pushes the search template (+1 depth). Alternative: drop the Finds tab, move New finds into Home and Library › Finds, and use the freed slot for Playlists.
- **Q2. Finds tab when empty.** Keep it with an empty view ("No finds yet. Try a song from Search."), or hide it and show the tab only when something is new or on its way? Swapping tabs on the fly can surprise a driver, so we recommend keeping it.
- **Q3. Weekly Exploration in the car.** Most of it is not-yet songs. Should the app bring the week's picks home as finds overnight (on Wi-Fi) so they play instantly in the car, or should the car play only the songs already home? This costs disk and the Finds cap.
- **Q4. "Try it" while music is playing.** Should the tried song cut in when ready (crossfade), or play after the current song ends? We recommend after the current song ends, which makes "Try it" and "Add to Up Next when ready" nearly the same. In that case the sheet could drop to two buttons: "Try it next" / "Cancel".
- **Q5. Keep without a label.** Now Playing custom buttons are image-only, so the sleeve-and-check glyph has no word next to it. The "New find · 7 days" album line explains it. Alternatively use the system `CPNowPlayingAddToLibraryButton` (a plus), which drivers already know, and give up our glyph.
- **Q6. Server name "Home" vs the Home tab.** Resolved: we no longer say "Home isn't reachable". The copy is "Your library is out of reach · Playing downloads".
- **Q7. Artist images vs records.** Artists are also round. Artists you have are plain circles; an artist not in the library sits in a record ring (grooves, no spindle hole). Is that distinct enough at 44 pt, or should artist rows use a rounded-square portrait?
- **Q8. Long waits.** On the Patient tier ("can take a few hours"), the Try sheet should say "Patient · can take a few hours. We'll put it in Finds." with buttons "Try it" / "Cancel". Is that acceptable, or should Try be hidden in the car when neither Quick fetch nor Standard is available?
