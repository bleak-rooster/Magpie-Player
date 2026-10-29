# Design language — Magpie

Status: proposal for owner review · 2026-10-26 · pairs with `docs/superpowers/specs/2026-10-26-serverless-architecture-design.md`
Storyboard canvas: https://claude.ai/artifact/XKKoxBkcMkM35MaWWPSq5p

## 1. The idea in one line

**Magpie**: the bird that collects shiny things and brings them home. The app does the same with music: it finds songs you don't have and brings the ones you love into your library.

**Music you own lives in its sleeve. Music you don't have yet is a bare record.**
Every surface of the app uses that one metaphor to show the only state that's new compared with Apple Music: *in your library* vs *not yet*. You never see Navidrome, Lidarr or ListenBrainz. You see records with sleeves and records without.

## 2. The Character dial

Settings → Appearance → **Character** has three positions. Navigation, layout and gestures are the same in all three, so muscle memory carries over. Only the skin changes.

| | **Classic** | **Signature** (default) | **Immersive** |
|---|---|---|---|
| Feels like | Apple Music, stock iOS 27 | Apple-native with a voice of its own | Signature plus the album art taking over |
| Type | SF Pro throughout | New York serif for display titles; SF Pro for text; SF Pro Rounded for numbers | Same as Signature, larger display sizes on Now Playing |
| Colour | System neutrals + one accent | Warm paper/ink neutrals + accent; album/artist pages tinted by their artwork ("sleeve tint") | Art-derived backgrounds everywhere, always dark |
| Not-yet songs | Square art at reduced opacity with a "Try" capsule | **Bare record**: round art with grooves and a spindle hole | Same as Signature |
| Motion | System defaults only | Record spin while fetching, sleeve morph on Keep, groove ripples | Plus particles and a visualizer on Now Playing, plus art parallax |
| Liquid Glass | Stock | Stock, tinted by the sleeve colour | Glass controls floating over full-bleed art |

Reduce Motion: no spin, morph or particles; crossfades only. Reduce Transparency: opaque surfaces. Low Power or serious thermal state: Immersive drops to a still art backdrop.

## 3. Signature motifs (the parts that make it ours)

1. **Sleeve vs record.** Library items: square art (the sleeve). Not-yet items: circular art with fine groove lines and a spindle hole (the bare record). The same shape language appears in search, artist pages, Home shelves and CarPlay artwork. CarPlay gets pre-rendered round art images.
2. **Spin-up.** While a song is being fetched, its record spins at 33⅓ rpm (1.8 s per turn). The wait screen shows grooves rippling outward from the record, with an honest estimate: "about 30 seconds", "a few minutes", "usually within the hour".
3. **Slip into the sleeve.** When you tap **Keep**, the record slides into a square sleeve. The circle morphs to a rounded square (450 ms spring) with a soft success haptic. This is the one bouncy moment in the app.
4. **Fade to keep.** A tried song loses colour day by day over its sample window (7 days by default). A thin arc around the record shows the days left. Keep brings full colour back at once. Nothing nags you. Untouched records quietly fade out.
5. **Hallmark.** Quality appears as a small stamp: "Sample" (MP3 trial), "Lossless soon" (upgrade queued), "Lossless" and "Hi-Res" (the route can carry it). The stamp shimmers once when a genuine lossless file replaces the sample.

## 4. Foundations

**Colour tokens**

| Token | Classic light / dark | Signature light / dark | Immersive |
|---|---|---|---|
| `bg` | #FFFFFF / #000000 | #FBFAF7 / #0E0D0C | art-derived, darkened |
| `surface` | #F2F2F7 / #1C1C1E | #F2EFE9 / #1A1816 | glass 14% white |
| `ink` | #000000 / #FFFFFF | #16130F / #F4F1EA | #FFFFFF |
| `ink2` | #6C6C70 / #98989F | #6B655C / #A39C90 | 72% white |
| `sep` | #D1D1D6 / #38383A | #E3DED5 / #2C2925 | 16% white |
| `accent` | user tint (default Sheen) | Sheen #3CC4B8 (text-safe #0E6F68 on light) | Sheen or the art's own accent |

Accent: **Sheen** (default), the iridescent teal of magpie plumage: fill #3CC4B8 with #04201D text on it, text-safe #0E6F68 on light. Alternatives: Tangerine #F25C05 (text #C2410C), Ultramarine #3D5AFE. Apple Music red and Spotify green are deliberately avoided.

**Sheen gradient** `linear-gradient(120deg,#2E6BD8,#24B3A8,#7B4FD6)`: special moments only (Keep, the Lossless shimmer). Never a background wash.

**Type scale** (iOS Dynamic Type sizes, in pt): Large title 34 · Title 1 28 · Title 2 22 · Title 3 20 · Headline 17 semibold · Body 17 · Callout 16 · Subhead 15 · Footnote 13 · Caption 12. Signature/Immersive set Large title, Title 1/2 and album titles in New York semibold with −0.4 pt tracking. All numbers (times, counts, days left) use SF Pro Rounded.

**Shape**: art corner radius 8 at ≤64 pt, 12 at hero sizes; cards 20; sheets use the system radius; capsule buttons. Spacing on a 4 pt rhythm, 16 pt side margins (20 pt for Large-title pages).

**Iconography**: SF Symbols only in the app (e.g. `record.circle`, `square.stack`, `sparkles`, `bolt.fill`, `hourglass`, `checkmark.seal`). Custom glyphs only for the record and sleeve motifs.

**Haptics**: Try → soft impact · ready to play → success · Keep → rigid impact + success · error → warning. No haptic for passive progress.

**Sound**: none of our own. The music is the sound.

## 5. Voice

Plain and warm, never technical. Talk about music, never about services.
- "Not in your library yet", never "Not in Navidrome".
- "Fetching… about 30 seconds", never "Lidarr searching indexers".
- "We'll keep looking and tell you when it's here", never "Download failed (no releases found)".
- Admin detail sits behind a single "Details" disclosure, and only for Curators.
- Never mention Soulseek, P2P, torrents or YouTube.

## 6. Roles in the UI

The spec calls them Keepers and Listeners. Because the main action is **Keep**, the UI calls the roles **Curator** (holds the keys, can manage the library) and **Listener**. This is open on the decision board.

## 7. Magpie in the system (decided 2026-10-26)

- **Pied neutrals:** black-and-white paper/ink is the magpie's plumage; Sheen is the iridescence.
- **Voice:** fetch steps read "Looking → Spotted it → Bringing it home → Ready". The shelf of tried songs is **Finds**; songs that just landed are **New finds**. The main action stays **Keep**.
- **Promise:** "Spots it. Brings it home. Keeps what you love."
- **Icon:** the green cover mark (owner decision 2026-10-29): the art-4 cover from Overview and Character dial, a forest-green diagonal field with a pale mint dome rising from the bottom centre. Light, dark and tinted variants. The bird lives in the name and the voice, not the logo (owner decision 2026-10-26).
