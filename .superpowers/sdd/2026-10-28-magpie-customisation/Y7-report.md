# Y7 report: a consistent, well-planned UI (plan item 10), phase 1

Branch `y7-ui` (off v0.0.1-custom 3dbf99d). Discover (Y6) files untouched.

Commits:
- 7861681 Y7: ActionBar in the design system; every Play/Shuffle/Download row and `.bordered` use replaced; tinted capsule labels clear AA for every accent
- dd4a28a Y7: page layout tests and the audit's screen gallery
- a0e49f4 Y7: audit fixes (Immersive secondary shade, one-column album grids at AX sizes, Library icons scale)
- (this report)

## 1. What was built

**`ActionBar` (Packages/MagpieKit/Sources/DesignSystem/Components/ActionBar.swift)**
- A custom `Layout`: items share one width per row and one height (at least 44 pt, `Tokens.minHitSize`). Two items go on a row; a third (Download) takes the next row at full width, so it never squeezes Play and Shuffle and the bar doesn't move when the download status text changes length.
- If a label wouldn't fit its slot on one line, the whole bar stacks rather than truncating. At accessibility sizes it always stacks (D15).
- The bar keeps the 16 pt side margins itself (`insetsMargins: false` for a bar inside a stack that already has them, e.g. the Outside album header).
- `ActionBarArrangement` is the pure rule (tested without drawing). `actionBarProbe` is an environment hook that reports each item's frame to the tests.
- `ActionCapsule` / `ActionButton`: symbol plus one-line label, 6 pt icon gap, 16 pt horizontal padding, `Theme.actionFont` (subheadline semibold; Immersive uses compressed bold callout). It has a `progress` fill for Download and a `busy` spinner (Try sheet). Inside a bar, capsules fill the bar's height; alone they span the row at their own height.
- Disabled capsules dim to 45 %. `ActionPressStyle` scales to 0.97 when pressed, and only dims under Reduce Motion; the progress animation is also off under Reduce Motion.
- `ActionStyle.colors`: Play (primary) is filled with the accent; the rest are tinted (accent at 16 %). Immersive stays solid (a11y C1). Its secondary items use a deep opaque shade of the accent with a white label, so they no longer look like Play.
- Tinted labels deepen toward ink until they reach AA on the darkest part of the capsule (audit #2). `CapsuleButton` uses the same colours.

**Download (App/Screens/Shared/DownloadButton.swift)**
- `DownloadControl(status:)` is the same tinted capsule in every state: "Download", then "Downloading 4 of 10" with a 40 % progress fill, then "Downloaded" (D3 symbol), plus every other status. After a download starts, the capsule opens the existing menu (Try again / Download the rest / Cancel or Remove download).
- VoiceOver label "Download", value = status text and id `download` are unchanged, so the UI tests keep working.
- The "already on the phone" footnote moved out of the button into `DownloadNote`, under the bar.

**Pages switched to ActionBar**
- Album and Playlist: Play/Shuffle, then Download on its own row.
- Artist: the bar was moved out of the padded header (now `header(_:)`), so the margins match Album.
- Made for you, Genre (the duplicate `wide` helper was removed), and Genre group (Shuffle only, D41, full row).
- Outside album: "Try this album" is the page's one filled action.
- `PlayShuffleActions` keeps the `play` and `shuffle` ids, and the Artist page now has them too.
- `CapsuleRow` was removed; it had no remaining users.

**`.bordered` / `.borderedProminent` removed** (none left in App/)
- RootView's "Play now" banner now uses the filled `CapsuleButton`.
- Request page: Play (filled), Keep, Find another copy and Check again now use `ActionButton`.
- Try sheet: the start button is a filled `ActionButton` with a busy spinner, and "Open Settings" is a tinted `ActionButton`.
- Settings › Downloads in Lidarr: "Restart" is a tinted `CapsuleButton`.

Copy is unchanged; no glossary violations were found on the touched screens. New SF Symbols were added to buttons that had none: Find another copy (`arrow.triangle.2.circlepath`), Check again and Restart (`arrow.clockwise`), Open Settings (`gearshape`), and Try (`sparkles`, as elsewhere).

Not changed, by design:
- **Favourites** has no Play/Shuffle/Download row (rows play from the tapped song), so nothing to replace. Adding one would be new behaviour.
- **Outside artist** has no capsule row; its action lives in `ArtistLidarrLine`.

## 2. Audit (screens × looks)

**Tooling.** I couldn't dispatch subagents, so I applied the impeccable / design-critique / accessibility-review checklist myself. `ScreenGalleryTests` signs in against stubs (no server) and hosts 8 main screens: Album, Artist, Playlist, Genre, Favourites, Library, Home and Settings. It uses a 402×874 window on the "Magpie Y7" simulator, with the root tint as RootView sets it, and draws each screen in 6 looks:
- Classic light and dark
- Signature light and dark
- Immersive
- Signature at accessibility XL (accessibility3)

It runs only when `TEST_RUNNER_Y7_SHOTS_DIR` is set, so it is a no-op in normal runs. Now Playing is covered by the existing never-scroll tests (`NowPlayingSmallPhoneTests`, `LayoutSettleSweepTests`), which still pass.

**Shots** (untracked, in the main checkout): `/Users/dev/Dev/navidrome_player/.superpowers/sdd/2026-10-28-magpie-customisation/y7-shots/`
- `before/`: 48 PNGs (`<screen>-<look>.png`) from base 3dbf99d, with only the gallery test added.
- `after1/`: 48 PNGs after the ActionBar, before the audit fixes.
- `after/`: 48 PNGs, final.
- `sheets/`: one contact sheet per screen per phase (`<phase>-<screen>.png`, the six looks side by side), e.g. `before-album.png` vs `after-album.png`.

**Findings and fixes**

| # | Screen / look | Finding | Fix |
|---|---|---|---|
| 1 | Album, Playlist, Artist, Genre, Made for you (all looks) | Play/Shuffle were small natural-width capsules spread apart; Download was a separate centred capsule that turned into a plain text menu; widths and heights differed per page; the Artist row was built separately | ActionBar everywhere: equal widths, one 44 pt height, 16 pt margins (tested per page and Character) |
| 2 | Every page, Tangerine/Ultramarine accents, light | Tinted capsule label (accent-ink on a 16 % tint) measured 3.9–4.3:1, below AA; also affected CapsuleButton (Try, Keep, …) | Label deepens toward ink until ≥ 4.6:1 on the darkest part of the capsule (`everyCapsuleMeetsContrast`) |
| 3 | Immersive | Play and Shuffle/Download were identical solid accent capsules (no primary) | Secondary = deep opaque accent shade, white label, AA-checked |
| 4 | Genre, Library, Favourites, Artist album grids at AX XL | Tiles widen to 220 pt at AX sizes, but the grid kept two columns of about 171 pt: tiles overlapped and ran off screen, with no margin | `AlbumGrid.columnCount`: one column on a phone at AX sizes |
| 5 | Library rows at AX XL | Fixed 28 pt icon column: large icons ran into the titles | `@ScaledMetric` icon width |
| 6 | Request page, Try sheet, Play-now banner, Lidarr downloads | iOS bordered styles (system shapes, not the design system) | ActionButton / CapsuleButton |
| 7 | Settings at AX XL | One-line summaries truncate ("Original · AA…") | Not changed: a recorded controller ruling in `SettingsSummaries.swift` ("never wraps, so the top level keeps its height"); flagged for the owner |
| 8 | Home at AX XL | Shelves scroll sideways with 220 pt tiles | None needed |

Tap targets: every bar item and capsule is at least 44 pt (asserted). Spacing: bars use `Tokens.Spacing.s` between items and `Tokens.Spacing.margin` at the sides. Type: the only new text style is `Theme.actionFont`; the rest already came from Theme.

## 3. Tests (TDD evidence)

**RED**
- `ActionBarTests` before the component existed: `error: cannot find 'ActionBarArrangement' in scope`, plus `ActionProminence` and others (compile failure).
- First run after building it: `everyCapsuleMeetsContrast` failed with 8 pairs, e.g. "signature ultramarine light secondary fill = 3.94", "classic tangerine light secondary fill = 4.28". That led to fix 2.
- Audit tests: `primaryIsFilledAndSecondaryTinted` failed with `Expectation failed: secondary.fill != primary.fill` and `…relativeLuminance <…`; `albumGridIsOneColumnAtAccessibilitySizes` failed with `type 'AlbumGrid' has no member 'columnCount'`.
- `PageLayoutTests` measure through the new probe, so they couldn't build against the old code. The before shots show the problems they guard against.

**GREEN**
- `ActionBarTests` (11), `PageLayoutTests` (2) and `DesignTokenTests` (9): 22 tests passed.
- ActionBar states: equal widths and heights in all three Characters; the Download capsule is the same size in all 8 statuses; stacking at accessibility3; a single item fills the row; the arrangement rules; contrast for every Character × accent × scheme × (fill, progress); the album-grid column rule.
- Pages: Album, Playlist, Artist and Genre in all three Characters share one bar, with Play the same width on every page; Album and Artist stack at accessibility3.

**Full runs** (once, at the end, on "Magpie Y7" after uninstalling the app):
- `scripts/check-writes.sh` OK (no new write shapes).
- `scripts/check-release.sh` OK.
- `scripts/test-packages.sh` exit 0, all suites passed.
- App suite (`MAGPIE_IT=1`, localhost dev stack): ** TEST SUCCEEDED **. Unit/hosted: 963 tests in 106 suites passed. UI: 29 tests, 0 failures, 3 skipped (the opt-in monkey ×2 and the netem crash hunt, as usual). This includes the download UI tests that drive the Download capsule (BrowseFlow, DownloadingNow).

## 4. Decisions
- **D-Y7a:** two items per row, with Download on its own full-width row. This keeps the bar stable across status text lengths, and three equal slots (about 115 pt) can't hold "Downloading 12 of 12" without truncating.
- **D-Y7b:** a label that would truncate stacks the whole bar (never truncates or shrinks text).
- **D-Y7c:** D3 symbols kept for Download states. The brief's "Downloaded ✓" is shown with `arrow.down.circle.fill` per D3.
- **D-Y7d:** Play is the only filled bar action. A genre group's lone Shuffle stays tinted; Outside album's Try is filled as that page's primary.
- **D-Y7e:** the audit gallery uses stubbed hosted rendering instead of the live app, for deterministic shots in every look with no server.

## 5. Concerns / phase 2
- Phase 2: apply ActionBar/ActionButton to Y6's Discover screens after Y6 merges.
- Hosted renders show placeholder art and the Immersive floor colour, not real art-derived backgrounds. The contrast tests cover that worst-case floor, and art palettes keep `ArtPalette`'s own AA check.
- Settings summaries truncate at AX sizes by an earlier ruling (audit #7). The owner may want to revisit it.
