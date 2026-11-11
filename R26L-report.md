# R26L report: same-named Aurral playlists that aren't in Navidrome

**Status:** DONE_WITH_CONCERNS (see Concerns: one reproduction finding and three judgement calls for the controller)
Branch: `r26-L` (worktree `agent-aefbed56162a7fda9`), based on b7e240c; v0.0.1-custom merged (already up to date).

## Reproduction (step 1)

The hosted RED suite is `Tests/MagpieTests/R26LSameNameNotInNavidromeTests.swift`. It uses StubAurral and the mock
Navidrome. Jordan is signed in to Aurral (admin, or not); Sam owns the other "Chill"; both are Aurral shared playlists
(`sp-j` and `sp-s`).

**Finding about the owner's setup.** With **no** Navidrome playlist at all, build 27 shows **nothing** under both
settings, because Discover's rows were Navidrome playlists only. That does not match the owner's "everyone's: two
rows". The owner's exact symptom (everyone's shows two "Chill" rows with no owner; only mine shows nothing) appears
only when Navidrome holds **two empty "Chill" playlists**. Aurral 2.13 publishes an empty playlist like that before any
of the playlist's songs are in. So on the owner's server Magpie's account almost certainly sees two empty Aurral
playlists of that name, even though the owner sees no songs of theirs "in Navidrome". The two cases have the same
root cause and the same fix, and both are covered.

RED command (before the fix; `discoverRows()` then returned `discoverPlaylists()` unchanged):
`xcodebuild test -project Magpie.xcodeproj -scheme Magpie -destination "platform=iOS Simulator,name=Magpie X2" -derivedDataPath dd/L -quiet -only-testing:MagpieTests/R26LSameNameNotInNavidromeTests`
→ TEST FAILED, 4/4 failing:

```
playlists_admin_notInNavidrome(): only mine: []   everyone's: []            (wanted [Chill[-](sp-j)] / [Chill[-](sp-j), Chill[sam](sp-s)])
playlists_admin_twoEmptyInNavidrome(): only mine: []
  everyone's: [Chill[-](playlist:pl-e1), Chill[-](playlist:pl-e2)]          <- build 27's symptom exactly
  everyone's in the car: ["pl-e1", "pl-e2"]
playlists_admin_mineDownloading_notInNavidrome(): only mine: []   everyone's: []
playlists_notAdmin_notInNavidrome() (two empty): only mine: []
  everyone's: [Chill[-](playlist:pl-e1), Chill[-](playlist:pl-e2)]   car: ["pl-e1", "pl-e2"]
```

Package RED: `swift test --filter R26LItemRowsTests` fails to compile (`type 'DiscoverRules' has no member
'itemRows'`). This is a new API, so the RED is a compile error, not a behaviour failure. The behavioural RED is the
hosted one above.

## Root causes (line numbers at b7e240c)

1. **Rows were Navidrome playlists only.** `App/AppModel+Discover.swift:321–329` (`discoverPlaylists()`) is the only
   source of rows for Library › Discover (`App/Screens/Discover/DiscoverPlaylistView.swift:251`,
   `ForEach(playlists, id: \.id)`), Home's shelf and the car. An Aurral item with no Navidrome playlist had no row.
   The only exception was the user's own recipe flows (`App/AppModel+RecipeFlows.swift:35–37`,
   `unpublishedRecipeFlows`); never a shared playlist, never another user's.
2. **Identity needed evidence inside a playlist, and an empty playlist has none.**
   `Packages/MagpieKit/Sources/AurralKit/DiscoverIdentity.swift:226`: `fit` is nil when the playlist's songs are empty,
   so step 3 (songs) can't claim. Lines 96–100: step 4 (name) refuses a name that more than one item carries, or that
   more than one playlist carries for one item. R25J's per-item reads (D251) can't help either, because they too are
   compared against the playlist's songs. Neither empty "Chill" was claimed.
3. **An unclaimed playlist was "not mine" and had no owner.** `App/AppModel+DiscoverIdentity.swift:68` (`notMine`) and
   `:74` (Q1: no flow, no owner). Only mine therefore hid both, and everyone's listed both. The caption
   (`discoverOwnerCaption`, `:96`) is keyed by Navidrome playlist id and filled only for a claimed playlist, so neither
   row had a caption.

There was no other name-keyed decision about "mine" or the owner. `DiscoverRules.flowPlaylists`
(`AppModel+Discover.swift:240`) picks a candidate by name, but `identifyDiscoverPlaylists` replaces that candidate's
item afterwards. The saved others' set (`noteOthersPlaylists`) and the claims (D204) are keyed by ids. The name
problem was structural: when nothing proves which playlist is which, rows keyed by playlist can't carry an owner.

## Built (step 2)

- `AurralKit/DiscoverRules+ItemRows.swift`: `DiscoverRules.itemRows(items:linked:unclaimed:empty:)`, a pure function.
  - An Aurral item that no Navidrome playlist is known to be (not claimed this read, and not kept with an orphan
    playlist under D75) becomes a row of its own, keyed by its Aurral id.
  - Exception: an unclaimed Aurral playlist **with songs** that carries one of the item's Aurral names (D181's forms or
    a copy number). That playlist may be the item's, so it stays the item's row (D202's Q1, never guessed) and the
    item is never shown twice. The name can only withhold a row; it never decides whose anything is.
  - Unclaimed **empty** Aurral playlists are `hidden`: never rows.
- `App/AppModel+DiscoverRows.swift`:
  - New types `DiscoverRow` (`.playlist(Playlist)` or `.item(AurralFlow, mine:)`, with id `"playlist:<id>"` or
    `"item:<aurral id>"`), `DiscoverItemRow` and `DiscoverItemRead`.
  - `noteDiscoverItemRows` is the hook from `identifyDiscoverPlaylists` on each read. With no items listed (Z1) it
    clears both the item rows and the hidden set.
  - `discoverRows()`: playlists, then item rows. The user's own always; another user's only with "Show everyone's
    flows". It leaves out a recipe flow that Your flows already shows, and items being deleted.
  - `discoverOwnerCaption(row:)`: D205's rule with Aurral's own owner field (`OwnerCaption.text`). Nothing for the
    user's own, nothing unless everyone's is shown.
  - `discoverItemState`: the user's own item with songs on the way shows "Downloading d/t"; otherwise "Not ready yet.
    Check back later." Both strings already exist in `DiscoverPagesCopy`, so there is **no new copy**.
- "Mine" is decided by `AurralStatus.scoped` / `belongs(to:)`: Aurral's `ownerUserId`, else `ownerUsername`. Never a
  name.
- `isShownInDiscover` (`AppModel+DiscoverEveryone.swift`) now also excludes hidden playlists. Library › Discover,
  Home's shelf and the car therefore never list the two empty unclaimed playlists. They are still Aurral's
  (`discover.playlists`), so they stay out of Playlists (D182/D189 unchanged).
- `DiscoverState` (`App/AurralConnectionStore.swift`, hook lines only) gains `itemRows` and `hiddenPlaylistIds`,
  forgotten in `forgetReads()` (sign-out, another Aurral). They are held in memory only; nothing new is persisted.
- `DiscoverListView` lists `[DiscoverRow]`:
  - Playlist rows are unchanged (moved into `playlistRow`).
  - An item row has a symbol, the name, the `OwnerCaption`, and the state as text plus symbol. It is at least 44 pt
    tall, combined for VoiceOver ("Chill, made by sam, Not ready yet…"), with identifier `discover-item-<aurral id>`.
  - It does **not** open, because nothing of it plays yet; the row says why, so there is no dead button. Full opacity,
    to keep contrast.
- Reads only: no route added, no write, `check-writes.sh` unchanged and passing. No Deezer or Apple host.

## Step 3 checks

- **Flows** (two same-named flows, nothing in Navidrome or two empty playlists): the user's own flow stays Your flows'
  row (round 16, `unpublishedRecipeFlows`), never a second row. Sam's flow is a row under everyone's with "sam".
  Without flow management (Aurral 2.10), the user's own flow is a row here instead.
- **Not an admin:** Sam's item is invisible to the user. Only mine still shows theirs, and everyone's adds nothing.

## Decisions (proposed rows; the controller writes them)

| D271 | **An Aurral item no Navidrome playlist is known to be is a Discover row of its own, keyed by its Aurral id** (amends D202's "rows are Navidrome playlists"; owner, round 26). Whose it is comes from Aurral's owner fields (`AurralStatus.scoped`, D72 (5)), never a name. The user's own always; another user's only with "Show everyone's flows" (D189/D190), with D205's caption from Aurral's `ownerUsername` (`OwnerCaption.text`). The row doesn't open (nothing of it plays yet). It says why, as text beside a symbol: the user's own with songs on the way shows "Downloading d/t", otherwise "Not ready yet. Check back later." Library › Discover only: Home's shelf and the car list only what plays. A user's own recipe flow stays Your flows' row (round 16), never a second one; an item being deleted is left out. Held in memory per read, forgotten at sign-out. `DiscoverRules.itemRows`, `AppModel+DiscoverRows.swift`. | Owner, round 26 (§12) | Built R26L |
| D272 | **One item, one row.** An unclaimed Aurral playlist **with songs** that carries one of an item's Aurral names (D181 forms or a copy number) may be that item's: it stays the row (D202's Q1: no owner, never guessed), and the item gets no row of its own. A name only ever withholds a row; it never decides whose an item or playlist is. Once songs prove a playlist (D203), the playlist is the item's row and the item row goes. | Owner, round 26 | Built R26L |
| D273 | **Empty unclaimed playlists are never rows.** An Aurral Navidrome playlist named as an item, claimed by none and holding no songs (read empty, or Navidrome counts 0 when unread) is not listed in Library › Discover, Home or the car: nothing to play, no owner known, and its items are rows of their own (D271). It is still Aurral's: kept out of Playlists (D182, D189 unchanged). | Owner, round 26 | Built R26L |
| D274 | **Root cause recorded:** the owner's two "Chill" playlists showed twice with no owner because Discover's rows were Navidrome playlists and identity needed songs inside them. Two empty same-named playlists (what Aurral 2.13 publishes before songs arrive) can't be told apart, so neither was claimed (D202 Q1). D202–D205 and D251–D254 are unchanged for playlists that do hold songs. | Round 26 L | Done |
| D275 | Spare. | | |

## Tests

- RED: shown above (hosted 4/4 failing; package compile RED).
- GREEN, new tests:
  - `R26LSameNameNotInNavidromeTests`: 12 test functions, 14 cases with arguments: three admin playlist setups,
    not-admin ×2, flows admin ×2, flows without management, item state, empty unclaimed still out of Playlists, songs
    arrive → the playlist is the row, unproven with songs stays Q1 with no second row, sign-out forgets the rows,
    reads only.
  - `R26LItemRowsTests`: 7 functions, 11 cases.
- Package: `swift test` (Packages/MagpieKit), **1771 tests in 12 runs, all passed**, after the merge.
- `scripts/check-writes.sh`: passed, exit 0 (no routes or writes touched, so the selftest was not needed).
- Full hosted + UI run on "Magpie X2", after the merge: **1482 tests: 1430 passed, 0 failed, 52 skipped** (skips are the suites' own environment-gated tests; none are R24A, R25J or R26L tests). Includes R24AIdentityTests, R25JSameNameTests and R26L.

## Self-review against the brief

1. The RED hosted test covers StubAurral as admin, two same-named shared playlists owned by `jordan` (signed in) and
   `sam`, no Navidrome playlists, the downloading variant, and both settings. Done. I added the two-empty variant
   because it is the one that matches the owner's report.
2. The fix is at the root: rows are keyed by Aurral id, the owner comes from Aurral, and a Navidrome claim is needed
   only to open and play. The existing suites `R24AIdentityTests`, `R25JSameNameTests`, `R23FDiscoverTests`,
   `R22ADiscoverOnlyTests` and `DiscoverAppTests` are in the full hosted run. The car still lists only playable
   playlists.
3. Flows and non-admin are covered. Routes are untouched and everything is a read.
4. File ownership: only Discover files, plus two hook lines in `DiscoverState` (`App/AurralConnectionStore.swift`, not
   in L's listed files; needed for the state, and K1 does not touch it). No K1 files touched. `docs/decisions.md` and
   `docs/FLOWS.md` were not edited.

## Concerns / not done

- **Reproduction finding (above).** With truly no Navidrome playlist, build 27 shows nothing, not two rows. The
  owner's server most likely has two empty "Chill" playlists visible to Magpie's account. Both cases are fixed. Only
  the owner's server can confirm, and it was not touched.
- **Judgement calls, made within my decision range:**
  - (a) An item row does not open. The alternative is a new page listing the item's songs from Aurral, which would be
    new UI and copy. A row for the user's own item could link to "Songs still coming" later.
  - (b) Item rows appear in Library › Discover only, not on Home's shelf or in the car, because there is nothing to
    play.
  - (c) D272 keeps D202's Q1 for an unclaimed playlist that has songs. In that sub-case (both items' songs unreadable),
    everyone's still shows the playlists without an owner, as before.
- The hidden set is not saved. Before the first Aurral read of a launch (or with Aurral down), the empty unclaimed
  playlists can still show under everyone's from the saved ids. `discoverPlaylists` waits up to 3 s for the read.
- No UI test was added for the item row (the identifier is there for one). It is covered by hosted tests only.

## FLOWS / README changes needed (for the controller)

FLOWS, Discover › "Show everyone's" / identity: an Aurral flow or playlist that no Navidrome playlist is known to be
is listed in Library › Discover as its own row, by Aurral id, with the owner's name under another user's when
everyone's is shown, and "Downloading d/t" or "Not ready yet. Check back later."; it doesn't open. Aurral's empty
playlists that no item claims are never listed (still kept out of Playlists). README: no change.

## Commits

- 1df03cc R26L: reproduce same-named Aurral playlists not in Navidrome (RED), Discover rows as their own type
- 3e1a776 R26L: an Aurral item no Navidrome playlist is known to be is a Discover row of its own, by its Aurral id; empty unclaimed playlists are never rows
- be697ad R26L: Library › Discover lists an Aurral item with no Navidrome playlist as its own row, mine by Aurral's owner and "sam" under another user's; empty unclaimed playlists are no longer rows
