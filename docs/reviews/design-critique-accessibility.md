# Accessibility critique: Magpie storyboard

Status: review · 2026-10-26 · reviewer: accessibility (VoiceOver, Dynamic Type, WCAG 2.2 AA, Apple accessibility HIG)
Scope: `docs/storyboard/design-language.md`, `flows.md`, `carplay.md`, `canvas/KIT.md` and the `canvas/*.dc.html` artboards (CSS tokens, sizes, motion, ARIA in the mockups).
Method: I computed WCAG 2.x relative-luminance contrast for every token pair in all four Character/scheme combinations, plus Immersive worst cases over light artwork. I read the shared kit CSS and the screen-specific CSS and markup for Home, Search results, Artist/Album (not yet), Finds shelf, Try wait (Quick), Now Playing (find), Kept, Visualizers, Live Activity, and the CarPlay spec.

Cost key: **S** = under a day, **M** = 1–3 days, **L** = a week or more, or a design rework.

---

## Summary

The core idea (sleeve vs record, fade to keep) is strong, and the mockups already do several things right. Most not-yet rows carry a text "Try" capsule. The Finds shelf shows "5 days left" as text. CSS respects `prefers-reduced-motion`. Immersive NP labels its art. Search rows have `aria-label="Try Harbour Lights"`.

The main gaps:

1. Immersive puts small text and Sheen capsules over bright art with no luminance floor. They fail as low as 1.9:1.
2. Some surfaces carry state **only** in shape or saturation: shelf tiles, the Library Finds stack, Classic, and CarPlay image rows. Round shapes also already mean "artist".
3. There is no VoiceOver spec for the six song states, and the mini player's transport is unreachable for VoiceOver users.
4. Layouts are fixed-pixel and absolutely positioned, so they will break at accessibility text sizes.
5. Light-mode Sheen (#3CC4B8, 2.06:1) still leaks into text and indicators.
6. The visualizers are loudness-driven with no flash limit.

---

## Critical

### C1. Immersive text and capsules over artwork fail contrast (down to 1.9:1)
**Problem.** Immersive draws content over the art-derived backdrop (`filter: blur(48px) brightness(.55)`) with a scrim that is only `rgba(0,0,0,.15)` at the top and `.55` at the bottom. With light artwork (cream, pale sky, yellow), the top half of every Immersive screen falls well below AA. The Sheen capsule (Try/Keep/Play) is worst. Immersive Now Playing also puts "Playing from" (11 pt, 82% white) over **unblurred** hero art under a 50% top shade.
**Evidence (computed, worst-case light art, scrim .15):**
| Element | Ratio | Needs |
|---|---|---|
| Sheen capsule text #3CC4B8 on 16% tint over backdrop (art-5) | **1.93** | 4.5 |
| ink2 (72% white) on backdrop | **3.28** | 4.5 |
| ink2 on glass 14% over backdrop | **2.66** | 4.5 |
| White (ink) on glass 14% over backdrop | **3.59** | 4.5 (body) |
| NP "Playing from" kicker 82% white over hero art + 50% shade | **3.42** | 4.5 |
| White NP title over hero art + 50% shade | 4.20 | 4.5 |
**Recommended change.**
- **Luminance floor, not a fixed scrim.** After blurring, sample the backdrop's mean luminance in the top and bottom bands (a `CIAreaAverage` on the downsampled art, which you already compute for sleeve tint). Raise the scrim until the backdrop is at most **#2A2A2A (L ≈ 0.023)** under any text. At that floor: ink2 8.14, ink2 on glass 5.70, Sheen on tint 4.91. Implementation: `.overlay(Color.black.opacity(scrimFor(meanL)))` where `scrimFor` solves `bgL * (1 − a) ≤ 0.023`.
- **Immersive capsules become solid:** fill `#3CC4B8`, text `#04201D` (7.95:1, and independent of art). Drop the 16% tint style in Immersive.
- **Hero art on Immersive NP:** add a 0–35% top gradient of `rgba(0,0,0,.65)` behind the top bar. Under Increase Contrast, put the top bar on `.regularMaterial`.
- `text-shadow` / `.shadow` is not counted by WCAG, so keep it as a nicety only.
**Cost:** M.

### C2. State conveyed only by shape or saturation on several surfaces; round already means "artist"
**Problem.** Most rows pair the record shape with a "Try" capsule, but some surfaces do not:
- **Home › "Because you played Glasshouse":** the *Saltwater Hymns* tile is a bare record with only title and artist. Nothing says "not in your library". The *New finds* tile has only a hidden "New:" prefix.
- **Library › Finds:** a stacked preview of three records (`rec fade-3`, `rec fade-1`, `rec`) whose only state cue is roundness and greyness.
- **Search-Artist-NotYet discography tiles:** a record plus a year. This is acceptable in context because the page header says "not in your library", but the tile on its own is not.
- **Classic Character:** `.ch-classic .rec` becomes a square at `opacity:.55` with no grooves, and `.ch-classic .arc` is hidden. The shape cue disappears, and a dimmed square reads as *disabled*, not *not yet*.
- **Fade to keep:** saturation steps (`saturate(.75/.5/.25/.05)`) are invisible to people with achromatopsia or low vision. The steps between .75 and .5 are hard for anyone to tell apart. Text exists on the shelf and NP, but not on tiles or CarPlay image rows.
- **Shape collision:** iOS draws artists as circles. Magpie draws artists you have as plain circles and artists you don't have as a "record ring". At 44 pt in CarPlay and 96 pt in Search, that difference is a few grey rings (open question Q7).
- **The days-left arc** is colour-only and, in light mode, below 3:1 (see H3).
**Recommended change.**
- **Rule:** every not-yet, find, or fetching item carries a **text or SF Symbol cue** in addition to shape. Add a 12 pt status line, as Home's "New from artists you follow" already does (`state acc` "Not in your library yet"). Make it mandatory on all tiles: "Not in your library yet" · "Find · 5 days left" · "Bringing it home" · "Waiting for Sam's Mac".
- **Glyph badge (Differentiate Without Colour):** a 16 pt `record.circle` badge at the art's bottom-trailing corner for not-yet items, and `hourglass` + "5d" for finds. Show it always in Classic. In Signature/Immersive, show it when `@Environment(\.accessibilityDifferentiateWithoutColor)` is true.
- **Classic:** keep the square but drop the 0.55 opacity. Use full-opacity art plus the glyph badge, so it doesn't read as disabled.
- **Fade:** keep it, but never as the only signal. When `accessibilityDifferentiateWithoutColor` is on, render the days-left number inside the arc gap. CarPlay rows always carry the "5 days left" detail text, as `carplay.md` already says for the Finds tab, extended to Home and Library rows.
- **Artists:** give artists not in your library a rounded-square portrait with the record badge, or keep circles and add the "Not in your library yet" subtitle (already present in Search-Artist-NotYet). Do not rely on the grooves.
**Cost:** M (one shared `StateBadge` view plus copy on tiles).

### C3. No VoiceOver model for song states; the mini player's controls are unreachable
**Problem.**
1. The design never specifies what VoiceOver says for *not yet / bringing it home / find with N days / kept / lossless*. In the mockups the art `div`s are unlabelled. State lives in shape and colour, so a VoiceOver user hears "Harbour Lights, Corin Hale" for both an owned song and one that isn't there yet. On tiles without the Try capsule there is no way to tell.
2. **Mini player:** in every artboard the pause and next icons are `<span class="icon-btn" aria-hidden="true">` inside the `<a class="mini">` link. Built the same way in SwiftUI (one button wrapping everything), VoiceOver users cannot pause or skip without opening Now Playing.
3. **Try capsule as a separate element:** each not-yet row becomes two swipe stops. On a long result list that doubles navigation cost.
4. **Swipe to remove (Finds):** this is swipe-only. The `Remove` button sits under the row.
5. **Hidden progress:** the avatar progress ring ("something is being brought home") and the tab badge are visual-only.
**Recommended change (SwiftUI):**
- Song rows: `.accessibilityElement(children: .combine)`, with the **title + artist as `accessibilityLabel`** and **state as `accessibilityValue`**, so the label stays stable for rotor and search while the value changes. Actions go in `.accessibilityAction(named:)`, not separate stops. See the label spec table below.
- Mini player: the container is `.accessibilityElement(children: .contain)`. Play/pause and next are real `Button`s with labels ("Pause", "Next track"). Alternatively, use one element with `.accessibilityAction(.magicTap)` for play/pause plus `.accessibilityAction(named: "Next track")` and `.accessibilityAction(named: "Open Now Playing")`. Also add `.accessibilityAddTraits(.startsMediaSession)` on Play buttons.
- Finds rows: `.swipeActions` (which VoiceOver exposes automatically) **and** explicit `.accessibilityAction(named: "Keep")` and `.accessibilityAction(named: "Remove from Finds")`.
- Avatar: `.accessibilityLabel("Account and activity")` with `.accessibilityValue("1 song on its way")` while the ring shows.
- Hallmark stamp: give it its own value, appended after state ("Lossless", "Hi-Res lossless", "Sample quality", "Lossless on the way"). Not a separate stop on rows. On NP it is a button: label "Sound quality", value "Sample. Lossless after you keep it".
**Cost:** M.

---

## High

### H1. Dynamic Type: fixed pixel layouts will break at accessibility sizes
**Problem.** Every size in the kit is a fixed `px` (34/28/22/17/13/12/11/10). Several screens are **absolutely positioned at fixed y**:
- Try-Wait: text block at `top:456px`. Steps row uses `white-space:nowrap` at 12 px.
- Keep-Done: heading at `top:410px`, card at `top:556px`.
- Mini player: fixed `height:52px`.
- Rows: `white-space:nowrap; text-overflow:ellipsis` on both lines.
- Small text: hallmark 11–12 px, tab labels 10 px.
At AX5 (Large Title about 60 pt, Body 53 pt), the wait screen's four-step progress line ("Looking — Spotted it — Bringing it home — Ready") cannot fit. The heading collides with the card on Kept, and song titles truncate to two or three characters.
**Recommended change.**
- Map every kit size to a text style (`.largeTitle`, `.title`, `.title2`, `.headline`, `.body`, `.subheadline`, `.footnote`, `.caption`). For New York display, use `Font.custom("NewYork-Semibold", size: 34, relativeTo: .largeTitle)` or `.system(.largeTitle, design: .serif, weight: .semibold)`. Use `.system(.body, design: .rounded)` for numbers.
- Scale art and record sizes with `@ScaledMetric(relativeTo: .body) var thumb: CGFloat = 48`, capped at about 88 so text keeps room. Do the same for the arc stroke: `@ScaledMetric var arcWidth = 2.5`.
- `@Environment(\.dynamicTypeSize)` with `if size.isAccessibilitySize`:
  - **Rows:** switch from `HStack` to `VStack(alignment: .leading)`. Art goes above, and the title wraps with `.lineLimit(nil)`. Try/Keep moves to a full-width button under the text.
  - **Wait screens:** replace the fixed layout with a `ScrollView` whose order is record (shrunk to 160 pt) → title → status → steps. Steps become a vertical list with a check, current, and pending glyph per line.
  - **Mini player:** grows vertically. Title wraps to two lines. Next is hidden and offered via `.accessibilityAction`.
  - **Tab bar:** use the system `TabView`, which gives the Large Content Viewer on long-press for free. Never custom-draw 10 px labels.
  - **Hallmark:** at AX sizes, show it as plain text ("Lossless") rather than a bordered stamp.
- Large titles: allow two lines (`.lineLimit(2)`, `.minimumScaleFactor(0.8)` only above AX3).
**Cost:** L (touches every screen, but it's mechanical once the row and wait templates exist).

### H2. Liquid Glass mini player and tab bar fail when bright content scrolls under them
**Problem.** The kit hard-codes glass fills and puts fixed `ink`/`ink2` colours on top. Over bright content (a cream album tile scrolling under):
| Pair | Ratio |
|---|---|
| Signature dark glass (rgba(36,33,30,.62)) over white, ink #F4F1EA | 4.06 |
| Same glass, ink2 #A39C90 (mini player artist line) | **1.68** |
| Signature light glass (.70) over black art, ink2 #6B655C | **2.63** |
| Classic dark glass (.66) over white, ink2 #98989F | **1.72** |
**Recommended change.** Don't paint fixed hex colours on glass. Use the system material plus hierarchical styles, which get vibrancy and adapt automatically: `.glassEffect()` (iOS 26+) or `.background(.regularMaterial)`, with `.foregroundStyle(.primary)` and `.foregroundStyle(.secondary)`.
- Under **Reduce Transparency** (`@Environment(\.accessibilityReduceTransparency)`), swap to opaque `surface` (#F2EFE9 or #1A1816), where ink2 measures 5.03 and 6.50.
- Under **Increase Contrast** (`@Environment(\.colorSchemeContrast) == .increased`), use `.thickMaterial` and a 1 pt `sep` border at 100% ink 20%.
**Cost:** S–M.

### H3. Light-mode Sheen still used for text and indicators (2.06:1)
**Problem.** The token system defines `accent-ink` #0E6F68 for light, but several rules use `var(--accent)` (#3CC4B8) without a light override:
- **Album › playing track title** (`.trk.playing .t1{color:var(--accent)}`) in Classic light (2.15) and Signature light (2.06). The playing state is also colour-only, so the text fails 1.4.3 and the cue fails 1.4.1.
- **Days-left arc** `conic-gradient(var(--accent) … , var(--sep))`: Sheen vs track #E3DED5 is **1.60**, and vs #D1D1D6 in Classic it is 1.41. This fails 1.4.11 (3:1 for meaningful graphics).
- **Fetch progress ring** (`.prog .fill` stroke Sheen on a `sep` track): same failure.
- **New dot**, the starred icon on Signature light NP, and the switch "on" state (Sheen vs white knob, 2.15).
**Recommended change.**
- Light schemes: the arc, progress ring, and starred icon use **#0E6F68** on a track of **#CFC8BC** (arc vs track 3.62, arc vs bg 5.76). In dark mode Sheen is fine (6.74 vs track).
- Playing track: colour #0E6F68 **plus** the animated `speaker.wave.2.fill` glyph (static under Reduce Motion). VoiceOver value: "Now playing".
- Switches: use the system `Toggle` with `.tint(Color("AccentInk"))` so the iOS **On/Off Labels** setting works.
- Add a lint rule: any `color:var(--accent)` / `.foregroundStyle(Color.sheen)` must be inside a dark-scheme guard.
**Cost:** S.

### H4. Visualizers are loudness-driven with no flash ceiling
**Problem.** Grooves (rings pulsing at `opacity .75 → 0` with loudness), Aurora ("swells on loud passages") and Particles ("faster when louder") all map audio energy to large-area luminance and opacity changes over full-screen art. A bass-heavy track at 120–180 BPM can drive 2–3 Hz full-field pulses. Strobing EDM drops can exceed **3 flashes per second**, which fails WCAG 2.3.1 and is a photosensitive-epilepsy risk. Reduce Motion is handled, but iOS **Dim Flashing Lights** is not.
**Recommended change.**
- Envelope smoothing: an attack of at least 250 ms and a release of at least 600 ms on the loudness follower. The visual can then change by at most ±10% relative luminance per 333 ms window. Hard-cap pulse rate at 3 Hz whatever the tempo.
- Visual area: pulses limited to under 25% of the screen. In practice that means rings at 40% opacity, with blobs moving in position and scale but not brightness.
- Respect `MADimFlashingLightsEnabled()` (MediaAccessibility framework; observe `kMADimFlashingLightsChangedNotification`). When it's on, freeze loudness coupling and keep the slow drift only. Treat Reduce Motion as "Off" (still art), as designed.
- Low Power and thermal fallback are already in place. Keep them.
**Cost:** S (parameters) + M (testing with a flash analyser such as PEAT or Harding on recorded output).

### H5. Fetch progress: chatty live region now, silent milestones later
**Problem.** In Try-Wait-Fast, `role="status"` wraps "Spotted it · bringing it home… **12 s**". In SwiftUI, a live-updating value would announce every second, or never if done naively. The "Ready" moment is signalled by the music starting, a **success haptic**, and a Live Activity flip. When the app is foreground on another screen, nothing is spoken.
**Recommended change.**
- On the wait screen, the record element gets `.accessibilityLabel("Harbour Lights")`, `.accessibilityValue("Bringing it home, about 12 seconds left")` and `.accessibilityAddTraits(.updatesFrequently)`. VoiceOver then reads the latest value on focus without interrupting.
- **Announce stage changes only** (4 max): `AccessibilityNotification.Announcement("Spotted it. Bringing it home.").post()`. Set `accessibilitySpeechAnnouncementPriority = .low` for intermediate stages and `.high` for "Harbour Lights is ready. Playing now."
- Read seconds as words: `Text(timerInterval:)` or a value of "about 12 seconds", never "12 s" or "0:20" (VoiceOver says "zero colon twenty").
- Patient tier: no per-minute announcements. Announce once when it's ready (a notification if backgrounded).
**Cost:** S.

---

## Medium

### M1. Reduce Motion: the spec covers the wait screen, but other ambient motion isn't specified
**Problem.** `design-language.md` says "no spin, morph or particles; crossfades only". However, these motions are not mapped:
- The **spinning groove highlight on the Signature play button** (`.groove::after` spinning 5.4 s, always on while playing).
- The NP hero `scale(.86)` spring on pause.
- The search `eq` bars.
- The Keep morph (450 ms *bouncy* spring).
- The Lossless shimmer.
- Art parallax.
- Immersive's ambient particles across the app.
- The spinning record on wait screens, tiles and Activity rows, which runs continuously for minutes to hours. WCAG 2.2.2 requires a way to pause motion that lasts more than 5 s.
**Recommended change.** One `MotionPolicy` reading `@Environment(\.accessibilityReduceMotion)`. When it's on:
- The record is still, with a progress ring.
- Morph becomes a 200 ms crossfade from round to square.
- Shimmer becomes a static stamp swap.
- Parallax, groove spin, and eq are off. Use a static `speaker.wave.2.fill` instead of the eq.
- Use `.animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.45, dampingFraction: 0.6))`.
When it's off, still stop the spin after 30 s on list tiles, keep the shimmer under 1 s, and keep the full spin only on the focused wait screen.
**Cost:** S–M.

### M2. Increase Contrast and Differentiate Without Colour have no token set
**Problem.** No `prefers-contrast` or `colorSchemeContrast` handling anywhere (0 of 64 artboards). Several states lean on colour or weight alone:
- Wait steps: done = ink, current = accent + 600 weight, pending = ink2. Done has a check glyph, but current vs pending is colour only.
- Selected tab: colour plus an 8% tint.
- Dividers: `sep` at 1.28–1.79.
**Recommended change.**
- Add an **Increase Contrast token set**: Signature light ink2 **#4F4A43** (8.41), dark ink2 **#C4BDB2** (10.42), light accent-ink **#0A5550** (8.29), dark accent **#6FE0D5** (12.30). Add a 1 pt `ink @ 30%` border on capsules and glass, and capsule tint at 24%.
- Asset catalog: give each colour a "High Contrast" appearance variant so SwiftUI picks it up automatically.
- Steps: current step gets a filled `circle.inset.filled` glyph, pending gets `circle`. With Differentiate Without Colour on, prefix the current step with "Now:".
**Cost:** S.

### M3. Touch targets below 44 pt
**Problem.**
- The Try/Keep/Play `.capsule` is **30 pt** tall. That passes WCAG 2.5.8 (24 pt) but misses the HIG 44 pt, and it is the app's most important action.
- The hallmark link on NP (`<a class="hallmark">`) is about 18 pt tall.
- Filter chips are 36 pt.
- Banner `mini-btn` is 32 pt (a system-drawn control in the real build).
- On the 390 pt screen, the Remove swipe button sits flush against the row.
**Recommended change.** Keep the visuals and enlarge hit areas: `.frame(minHeight: 44).contentShape(Rectangle())` on capsules, with 7 pt padding above and below. On the hallmark, `.padding(.vertical, 13).contentShape(Rectangle())`. Chips get `minHeight: 44`. Check spacing so expanded hit areas don't overlap. Even better: make the whole row the Try target and have the capsule only show the action.
**Cost:** S.

### M4. CarPlay legibility of the record and fade metaphor
**Problem.**
- The round, grooved, faded art is pre-rendered into list images of about 44–60 pt and viewed at arm's length, often in glare. The grooves become noise, the spindle hole can read as a defect, and saturation steps are unreadable.
- The Keep custom button is **image-only** (Q5): a sleeve + check glyph that drivers have never seen.
- Artist circle vs record ring (Q7).
- Any `CPListImageRowItem` (image grid) row has no per-item state text.
**Recommended change.**
- Every not-yet or find row must set `detailText`: "Not in your library yet", "New find · 7 days", "5 days left", "On its way · about 20 s". The image is decoration, never the carrier.
- Bake in a higher-contrast record: 3 grooves, not fine lines; a 2 px light rim; no fade below 40% saturation in CarPlay renders.
- Q5: adopt `CPNowPlayingAddToLibraryButton` (the system "+", already understood). Keep remains available by voice: "Keep this song" via `INUpdateMediaAffinityIntent` / App Intent `updateAudioAffinity`.
- Q7: use rounded-square portraits for artists not in the library, or avoid image rows with mixed states.
- Do not put state in `CPListImageRowItem` grids unless each element title includes it.
**Cost:** M.

### M5. Live Activity / Dynamic Island: a spinning, shape-only compact state
**Problem.**
- Compact and minimal presentations show only a spinning round record (24 pt). The "minimal" one has nothing else.
- ActivityKit cannot run a continuous rotation; it only animates between updates.
- The minimal label "On its way, minimal" exposes an implementation word.
- The countdown "0:20" in Sheen on black is fine (9.78:1), and the 62% white secondary text on black is fine (7.84:1).
**Recommended change.**
- Compact leading: a static record image. Compact trailing: `ProgressView(timerInterval:countsDown:)` with a circular style tinted Sheen, or `Text(timerInterval:)`. Both are system-animated, read correctly by VoiceOver, and need no rotation.
- Minimal: the record inside a circular progress ring, so the ring is the activity cue rather than the shape.
- Labels: `.accessibilityLabel("Harbour Lights, bringing it home, about 20 seconds left")`; ready state "Harbour Lights is ready".
- Use text styles (`.headline`, `.footnote`) so the Lock Screen view scales within the system's Live Activity limits. Don't use fixed 13 px.
**Cost:** S.

### M6. Haptics and motion as the only confirmation
**Problem.**
- Keep = rigid + success haptic + morph. Under Reduce Motion the morph goes, and with system haptics off (or on an iPhone in a case on a table) the haptic goes too. Keep-Done shows "Kept.", so that screen is fine. But **Keep from the Finds row or the NP button** (`btn-fill keep` → `Kept`) changes only the label and art shape inline.
- Ready = success haptic plus playback starting. With a Bluetooth delay or muted volume there is no visible cue unless the user is on the wait screen.
**Recommended change.**
- Every haptic gets a visible state change plus an announcement. Inline Keep: the button becomes "Kept" with `checkmark.seal`, a "Kept. In your library" toast for about 3 s, and `AccessibilityNotification.Announcement("Kept. Saltwater Hymns is in your library.")`.
- Ready while the app is foreground: a "Harbour Lights is ready" banner in the mini player slot.
- Use `.sensoryFeedback(.success, trigger:)`, which respects the system haptics setting.
**Cost:** S.

### M7. Art-derived colours (sleeve tint, Immersive accent) and user tints have no contrast guard
**Problem.**
- Album pages use hand-picked tint text: Signature dark byline #B7E4C7, light #1B4332, and the playing track #B7E4C7. In production these come from artwork, which can be any colour.
- Classic takes "user tint". Of the offered alternatives, Tangerine fill with white text is **3.33** and Ultramarine as text on dark is **3.78**. Both fail.
- Immersive uses "the art's own accent".
**Recommended change.**
- A `ContrastSolver.adjust(color, against: bg, min: 4.5)` that walks lightness in OKLCH until the target ratio is met. Use 3.0 for non-text and 4.5 for text. Apply it to every art-derived or user-chosen colour before use.
- Per-accent on-colour tokens: Tangerine fill gets text **#1F0A00** (5.73). Ultramarine on dark gets **#8C9EFF** (7.81). Ultramarine fill with white is 5.13 (OK).
**Cost:** S–M.

---

## Low

### L1. Focus order, headings and modality
- Mark large titles and section titles as headers (`.accessibilityAddTraits(.isHeader)`) so the rotor works (Home has 6 shelves).
- **Kept screen:** on appear, move focus to "Kept." with `@AccessibilityFocusState`. The morph is `aria-hidden`, which is good.
- **Immersive NP:** the hero art is first in the DOM but full-bleed. Order should be close → Playing from → title → artist → Keep → scrubber → transport. Use `.accessibilitySortPriority` if the `ZStack` order differs.
- **Try sheet:** a system sheet already traps focus. If it's custom, add `.accessibilityAddTraits(.isModal)`.
- **Scrubber:** `.accessibilityAdjustableAction` steps of 10 s; value "2 minutes 14 seconds of 3 minutes 52 seconds".
**Cost:** S.

### L2. Copy that VoiceOver reads poorly or inconsistently
- "Fades in 7 days" (NP find) vs "leaves in 2 days" (shelf) vs "Finds leave after 7 days". The visual fades, but the meaning is *leaves*. For VoiceOver, say "Leaves in 7 days unless you keep it."
- Abbreviations: "12 s", "about 30 s", "5d". Spoken values should use words.
- "Hi-Res": give it `accessibilityLabel("High-resolution lossless")`.
**Cost:** S.

### L3. Signature hallmark is 12 px italic serif
Italic New York at 12 px in ink2 is the hardest text in the app to read, even though its contrast passes (5.0–7.1). At 11–12 pt use upright SF Pro semibold. Keep the italic serif for 15 pt and up (NP hallmark).
**Cost:** S.

### L4. Separators
`sep` is 1.28–1.79 vs bg. This is acceptable as decoration, since rows are also separated by spacing. Under Increase Contrast, raise it to ink at 25%.
**Cost:** S.

---

## VoiceOver label spec (song and album states)

Pattern: **label = what it is** (stable), **value = state** (changes), **hint = only when the action isn't obvious**, **actions = everything the visual offers**. The row is one element: `.accessibilityElement(children: .combine)`.

| State | accessibilityLabel | accessibilityValue | Hint | Custom actions / traits | Announcement on change |
|---|---|---|---|---|---|
| In library (sleeve) | "Harbour Lights, Corin Hale" | *(none; the default state is silent)*; add "Downloaded" if offline-available | — | Play (default), "Add to Up Next", "Go to album" | — |
| Not in library yet (record) | "Harbour Lights, Corin Hale" | "Not in your library yet" | "Double-tap to try it." | default = open Try sheet; "Play preview" (if a free preview exists) | — |
| Bringing it home (spinning) | "Harbour Lights, Corin Hale" | "Bringing it home, about 30 seconds" / "Looking for the best copy" / "Waiting for Sam's Mac" | — | `.updatesFrequently`; "Cancel" | Stage changes only: "Spotted it. Bringing it home." |
| Couldn't find yet | "Harbour Lights, Corin Hale" | "Still looking. We'll tell you when it's here." | — | "Stop looking" | — |
| Ready / new find | "Harbour Lights, Corin Hale" | "New find. 7 days to keep it." | — | Play (default), "Keep", "Not for me" | "Harbour Lights is ready." (+ "Playing now" if it auto-plays) |
| Find, N days left | "Analog Summer, Velvet Static" | "Find. 5 days left to keep it." · last day: "Find. Leaves today." | — | Play, "Keep", "Remove from Finds" | — |
| Kept (just now) | "Saltwater Hymns, Corin Hale" | "In your library. Lossless on the way." | — | Play | "Kept. Saltwater Hymns is in your library." |
| Lossless arrived | "Saltwater Hymns, Corin Hale" | "In your library. Lossless." | — | — | None (silent by design, decision 18) |
| Now playing (any row) | (as above) | prepend "Now playing." | — | — | — |
| Artist not in library | "Corin Hale, artist" | "Not in your library yet" | "Double-tap to see songs you can try." | "Keep artist" | — |
| Album not in library | "Saltwater Hymns, Corin Hale, album" | "Not in your library yet. 10 songs." | — | "Try a song", "Keep album" | — |
| Quality stamp (NP, standalone button) | "Sound quality" | "Sample" / "Lossless" / "High-resolution lossless" / "Lossless on the way" | "Double-tap for output details." | — | — |
| Mini player | "Now playing: Last Stop Lullaby, Ada Okafor" | "Playing" / "Paused" | — | Magic Tap = play/pause; "Next track"; "Open Now Playing" | — |
| Avatar | "Account and activity" | "1 song on its way" (when the ring shows) | — | — | — |

CarPlay: the same strings go in `detailText` (CarPlay has no VoiceOver, but the text is the non-shape cue). Live Activity uses the "Bringing it home" and "Ready" values above.

---

## Contrast table (WCAG 2.x, computed)

Thresholds: text 4.5 (3.0 for 18 pt+ or 14 pt bold); non-text UI and graphics 3.0. **Bold** = fails.

| Pair | Classic light | Classic dark | Signature light | Signature dark | Immersive (worst light art, scrim .15) | Immersive with proposed floor #2A2A2A |
|---|---|---|---|---|---|---|
| ink on bg | 21.00 | 21.00 | 17.74 | 17.21 | white 4.69 | — |
| ink2 on bg | 5.23 | 7.33 | 5.53 | 7.13 | **3.28** | 8.14 |
| ink2 on surface | 4.69 | 5.94 | 5.03 | 6.50 | on glass **2.66** | on glass 5.70 |
| accent-ink text on bg | 6.01 (#0E6F68) | 9.78 (#3CC4B8) | 5.76 (#0E6F68) | 9.04 (#3CC4B8) | — | — |
| accent-ink on surface | 5.39 | 7.92 | 5.24 | 8.25 | — | — |
| capsule text on 16% Sheen tint over bg | 5.34 | 7.97 | 5.11 | 7.02 | **1.93** | 4.91 (solid fill: 7.95) |
| capsule on 16% tint over surface | 4.85 | 5.87 | 4.71 | 6.14 | — | — |
| on-accent #04201D on Sheen fill | 7.95 | 7.95 | 7.95 | 7.95 | 7.95 | 7.95 |
| Days-left arc Sheen vs track (non-text) | **1.41** | 5.45 | **1.60** | 6.74 | — | — |
| Arc proposal #0E6F68 vs track #CFC8BC | 3.62 | — | 3.62 | — | — | — |
| Sheen as text on light (misuse, e.g. playing title) | **2.15** | — | **2.06** | — | — | — |
| sep vs bg (decorative) | 1.52 | 1.79 | 1.28 | 1.34 | — | — |
| Glass mini player ink2, worst content under it | — | **1.72** | **2.63** | **1.68** | — | — |
| NP "Playing from" 82% white over hero + 50% shade | — | — | — | — | **3.42** | — |
| Live Activity: Sheen count on black · 62% white on black | — | — | — | — | 9.78 · 7.84 | — |

Other accents: Tangerine #C2410C text on white 5.18 · Tangerine fill + white **3.33** (use #1F0A00, 5.73) · Ultramarine fill + white 5.13 · Ultramarine text on #0E0D0C **3.78** (use #8C9EFF, 7.81).
Increase Contrast proposals: Signature light ink2 #4F4A43 8.41 · dark ink2 #C4BDB2 10.42 · light accent-ink #0A5550 8.29 · dark accent #6FE0D5 12.30.

---

## Suggested order of work
1. C1 luminance floor + solid Immersive capsules; H3 light-Sheen fixes; H2 system materials. *(Colour work, mostly S.)*
2. C3 + the label spec table as a shared `SongRowAccessibility` modifier; H5 announcements; M6 confirmations.
3. C2 state badge + tile status lines (also fixes M4 CarPlay detail text).
4. H1 Dynamic Type templates (row, wait, mini player) before screens are built, not after.
5. H4 flash limits before the Immersive visualizer ships; M1 motion policy.
