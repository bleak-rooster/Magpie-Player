# Magpie round 12, Y5: Find → Add design (plan items 8 and 9)

Status: **design, for critic review before any code.** Source: docs/superpowers/specs/2026-11-01-magpie-round-12-plan.md
items 8–9 and owner answer 3. Binding: G1–G9, M6 (save before every write), D7 (Ready = Navidrome lists it), D29, the
round-11 glossary (no service names in new copy). Decisions, not options; "Flagged" marks the calls the critic should test.

## 1. Principles

1. **Lidarr and Navidrome are the truth.** Tags + root path + track files (Lidarr) and listed songs (Navidrome) decide
   every status. The ledger is only *the record of what Magpie wrote*, for the gate. The request list holds intents and
   bookkeeping, never a status that contradicts a fresh read.
2. **Every write is intent → write → verify → commit.** The intent is on disk before the write (M6); the commit only
   follows a fresh read proving the write landed; a relaunch finds the intent and verifies, never re-sends blindly.
3. **One resolver, many readers.** `FindState` feeds the artist line, song/album rows, the Finds shelf, Activity and
   CarPlay (through the existing `AppModel+CarPlay` adapter only; Y2 owns CarPlay files).
4. **Never act on a name.** Every write needs a MusicBrainz id match (or the owner's explicit I3 pick).

## 2. FindState resolver (`Requests/FindState.swift`, pure, no I/O)

**Inputs** (a `FindSnapshot`, read once per pass): the Lidarr artist (id, MBID, tags, path, qualityProfileId), fresh
root folders, running commands, the artist's albums and track files (id, albumId, path, quality, size), the
`KeepSetup` (Finds root, main root, find tag, lossless profile), the artist's ledger entries, the artist's requests
(their `KeepIntent`, `LosslessWatch`, needs-attention flags), Lidarr server time, and the library MBID of the page.

**Output**
```swift
enum FindState { case notInLidarr(MBID?), unmatched, owners(monitored: Bool, searching: Bool),
  find(inPlaceLegacy: Bool), adding(AddPhase), inLibrary(Lossless), needsAttention(Attention) }
enum AddPhase { case queued, moving }          // "Adding when your server is free…" / "Adding to your library…"
enum Lossless { case lossless, waiting(mp3RemovedOn: Date), mp3Removed, merged }  // per album, worst wins per artist
```
**Precedence** (first match wins):
1. No MBID on either side and the name matches → `.unmatched` ("Couldn't match this artist", no action). Name-only
   matches never reach a write (item 9.9). `notInLidarr` keeps the I3 candidate pick (owner-confirmed MBID).
2. Artist not created by Magpie (ledger `created(_:)`, id + MBID) → `.owners` (today's monitored / not monitored).
3. A request of the artist has `keepNeedsAttention` or `notForMeNeedsAttention` → `.needsAttention`.
4. A `KeepIntent` exists → `.adding(.queued)` while phase is `queued`, else `.adding(.moving)`.
5. Lidarr says find: `magpie-find` in tags **or** path strictly inside the Finds root (`PathGuard`) → `.find`
   (`inPlaceLegacy` when the path is in Finds but the tag is gone: the old keptInPlace).
6. Otherwise (main root, untagged, Magpie-created) → `.inLibrary`, with `Lossless` derived from track files of the
   find's albums: all lossless → `.lossless`; lossy files present → `.waiting(deadline)`; recorded find files deleted
   and no lossless file yet → `.mp3Removed`.

A ledger "finds-mode, created, not kept" entry with neither tag nor Finds path is **not** a find: it is a Keep whose
commit was lost; reconciliation commits it (§4). Plan item 8's third criterion is therefore used only there.

**Copy** (design language §5; "MP3" and "lossless" are format words, already in Settings copy):
| State | Status line | Action |
|---|---|---|
| find | In your Finds | Add to your library |
| adding(queued) | Adding when your server is free… | none |
| adding(moving) | Adding to your library… | none |
| inLibrary(waiting) | In your library · lossless soon. The MP3 is removed on <date> unless a lossless copy turns up. | Remove the MP3 now |
| inLibrary(mp3Removed) | Waiting for a lossless copy | none |
| inLibrary(lossless) | In your library · Lossless | (R18 Add more) |
| unmatched | Couldn't match this artist | none |
Rows show their album's status; CarPlay the status text only. Flagged: plan's "Adding when Lidarr is free…" reworded (glossary).

## 3. Reconciliation tick

`tick()` keeps its order and `shouldStop` checkpoints, with three changes: it starts with **lease recovery** and a
**server-clock update**, each request's step is preceded by **fact folding**, and `followLossless()` runs after
`followKeeps()`.

**Derived every pass, never persisted as truth:** find / in-library status, album quality, whether the FLAC landed,
whether lossy files remain, Ready (Navidrome lists it), the Lidarr queue view.
**Persisted:** requests (intents, ids, deadlines), the ledger, `RunnerState` (`runner-state-<instance>.json`: leases,
history cursor in server time, clock offset, one-time migration flags).

**Fact folding** (`RequestRunner+Reconcile.swift`): before `advance`, each active request's facts become machine
events, strongest first: Navidrome lists it (any §6 match) → `.visibleInLibrary`; Lidarr has a track file for the
recording's album → `.imported`; a queue item → `.queueProgress`; the album unmonitored with no files, or the artist
404 → `.error(.stoppedInLidarr)`. `RequestMachine` stays the transition authority (pure, unchanged except §9).

**Idempotence.** Every write is guarded by a fresh read showing it is still needed (monitored? tagged? file still
lossy?). Test invariant: two ticks over an unchanged server send zero writes on the second.

**Leases (item 9.10, extends X5 I1).** `busy`, `keepingArtists`, `lettingGoArtists` and `searchAfterRemoval` move into
`RunnerState.leases: [Lease{key, op, requestId, startedAt, process}]`, saved before the work starts and dropped after.
`process` is a UUID made per runner launch. At load, a lease from another process is **orphaned**: the next pass runs
only that op's *follow/verify* path for it (never a fresh start) and then drops it. An in-process lease blocks a
second start, as today. A lease older than 30 min with no progress turns into needs attention.

## 4. Keep = "Add to your library" (intent → PUT → verify → commit)

`KeepIntent` replaces `KeepProgress` (same stored key, extra phases; old values decode):
`queued → intent → sent → (moving | untagging | restoring) → committed`.

1. **Tap.** Fresh checks as today (created, tagged or legacy in place, in Finds, roots valid). Save `KeepIntent(.queued)`
   and the ledger's new `keepIntentAt` (**not** `keptAt`). The gate treats `keepIntentAt` like kept for deletes and
   Not for me (G3.4), so nothing can delete a find while its move may be in flight.
2. **Queued (item 9.5).** Each pass, if Lidarr is idle (FL3 `holdsTheQueue` is false and no move of the artist runs),
   the destination is checked and the phase becomes `.intent`, then `.sent` is saved, then the PUT is sent. A busy
   Lidarr just waits; after 24 h queued: intent dropped, "Couldn't add it yet. Try again." Keep is never refused for
   being busy any more.
3. **Verify** as today (BulkMoveArtist after `commandBaseline`, artist path in main root, every file on disk there,
   Finds folder gone, tag off, Lossless profile). A failed move → `restoring` (as today) → intent cleared.
4. **Commit**, only after verify: ledger `keptAt = server now`, `keepIntentAt = nil`, and **`findFiles`** = the lossy
   track files of the find's albums (`{id, albumId, size}`); the request goes to `.kept`; a `LosslessWatch` starts
   (§5); then the scan and relink run as today.
5. **Launch recovery** (every load, and every pass for intents without a lease):
   - `queued` or `intent`: nothing was sent. Drop the intent if it's older than 24 h; otherwise it stays queued.
   - `sent`/`moving`, artist already in main root + untagged + files there → commit.
   - Still a tagged find and no move command after the baseline within `keepStartGrace` → the PUT never applied →
     clear the intent (the find stays, Add offered again).
   - Anything else → today's follow (limits, restore, needs attention).
   - **Legacy lock (the crash of item 9.4):** `keptAt` set, no intent, artist still tagged in the Finds root, no needs
     attention → clear `keptAt` (logged). Ledger finds-mode entry, no `keptAt`, artist untagged in main root → commit.
6. **Collision → merge (item 8, replaces keptInPlace).** When `<main root>/<Lidarr folder name>` already exists:
   merge only if (a) the folder name equals Lidarr's `folder` byte for byte, (b) Navidrome's main library lists songs
   under that folder and every one with an artist MBID has the find artist's MBID (at least one), (c) no Lidarr artist's
   path is that folder, (d) no file of the find has the same relative path as a file already there (Lidarr filesystem
   API). Then the same G4 move body is sent. Lidarr's folder transfer merges the folders; (d) means nothing is
   overwritten. Otherwise nothing is written and the page says: "Your library already has a folder for <artist>, so it
   stays in your Finds for now." The request stays `.ready` and is **not** called kept. The untag-only write is
   removed from new Keeps. Flagged: verify Lidarr 3.2's merge-move on the dev stack before relying on it (§10 test M).

## 5. Lossless search, upgrade watch, relink, MP3 rule (`RequestRunner+Lossless.swift`)

`LosslessWatch {albumIds, startedAt, deadline, searches, lastSearchAt, lastCheckAt, removed: Bool}` on the request.
- **Search:** right after commit, `POST /command {name: AlbumSearch, albumIds}` for the find's monitored albums (an
  existing gate shape). Then once per 24 h until lossless or 30 days, then Lidarr's own RSS monitoring carries on.
- **Watch** (each pass, throttled to 5 min in the foreground and every background pass): `trackFiles(albumId)`. The
  Magpie Lossless profile (FLAC only, upgrade allowed) makes Lidarr's import of a FLAC an upgrade, so the MP3 goes to
  Lidarr's recycle bin. When every track of the find's recordings is lossless → scan the artist folder (targeted, as
  Keep) → relink (§6) → `songSuffix` updated → `.lossless`. Flagged: test L confirms on 3.2 that an MP3 outside the
  profile's allowed set is upgraded.
- **MP3 rule (owner answer 3).** `deadline = commit server time + 7 days` (persisted, shown on the page). At or after
  it (server time), every file in `findFiles` that a fresh read shows still exists, still lossy, with the same size, is
  deleted through the gate (`DELETE /trackfile/bulk`, or one id at a time on 404/405 as Not for me does). The album
  stays monitored, `removed = true`, the targeted scan runs, and the request's `songId` is cleared (player entries for
  it are dropped by the existing `onRelinked` path with a nil song). Status: "Waiting for a lossless copy".
- **Remove the MP3 now:** the same delete at any time, after the confirmation "Remove the MP3 now?" with "This song
  leaves your library until a lossless copy arrives." and the buttons Remove / Cancel.
- With the recycle bin unset the delete is permanent. The owner ruled it automatic, so it runs anyway; the page's
  pre-deadline line is the warning.

## 6. Matching (item 9.2), Ready and relink

The order, used for Ready (`checkLibrary`), relink and the lossless relink:
1. the recording MBID (match index, as today);
2. **path:** Lidarr's track file path for the request's album (after import), mapped through the Finds `PathMapping`
   (or the same path when the mounts match) ↔ the Navidrome song path (library path + relative path), byte-equal
   after `PathGuard.standardize`;
3. **title + artist + duration:** `Normalize.name` equal on both, duration within ±3 s, only among songs under the
   artist's folder in that library, and only when exactly one song matches.
Never title + artist alone. Never a song outside the artist's folder, so the owner's own copy can't be taken.

## 7. Stalls, server time, RefreshArtist

- **Stall (item 9.6).** The signature is `sizeleft` + client + queue id: a status flip between ok and warning no
  longer restarts the clock. A warning item from any client is stalled only after `stallLimit` unchanged, never at once
  (Soulseek → the R17 removal; other clients → the `downloadFailed` wait). Client names are read every poll pass (one
  `GET /downloadclient` per pass; the per-runner cache goes). `StallLimit` gains `threeMinutes = 180` and `standard`
  becomes 3 min (choices 1/2/3/5/10); a one-time migration turns a saved 60 into 180. Flagged: overrides R17/R20's 1 min.
- **Server time (item 9.7).** `LidarrClient` exposes each response's `Date` header; the runner keeps `clockOffset =
  serverDate − phone now` from the latest successful read, and `serverNow()` uses it for the history cursor,
  `searchStartedAtServer`, the event filters and the 7-day deadline. No header → offset 0.
- **RefreshArtist completion (item 9.8).** After `POST /artist` the runner saves `commandBaseline` and follows the newest
  `RefreshArtist` naming the artist: completed with the album still missing → `.noRelease` at once; failed → the
  `serviceUnavailable` wait; cleanup's `settling` ends on completion. None seen within 2 min → the existing
  `albumAppearLimit` / `addSettleTime` apply.

## 8. Gate (G1): every new or changed shape

| Shape | HTTP | Confinement |
|---|---|---|
| **keptLossyDelete** (new rule, existing verbs) | `DELETE /trackfile/{id}`, `DELETE /trackfile/bulk {trackFileIds}` | Every id: is in a ledger entry's `findFiles` for an artist the ledger says Magpie created (id + MBID) **and** `keptAt` set; a fresh `GET /trackfile/{id}` shows the same artist and album, the same size, and a quality that isn't lossless (FLAC/ALAC/WAV/APE/WavPack refused); its artist's path is strictly inside the current main root. A bulk delete is all-find (today's rule) or all-keptLossy, never mixed; at most 500 ids. |
| Not for me / find deletes (changed) | same | "Kept" now also means `keepIntentAt` set. |
| Lossless search | `POST /command {name: AlbumSearch, albumIds}` | Unchanged; albums must have a ledger entry (new check, matching album monitor). |
| Keep / merge move | `PUT /artist/editor` G4 `MoveBody` | Unchanged (merge uses the same body and the same confinement). The untag-only body is no longer sent by new Keeps. It stays allowed, for the restore. |

check-writes.sh pins:
- `gate.send("DELETE", "trackfile` appears only in RequestRunner+NotForMe.swift and RequestRunner+Lossless.swift;
- the new FindFlowIT helper is allowlisted like FindsIT (`G1 allowlist: devLidarr`).
The change log records every delete with its rule name.

## 9. Data and migration (all fields optional: old files decode)

- `MagpieRequest`: `keep: KeepIntent?` (KeepProgress renamed; new phases `queued`, `intent`, `sent`, `committed`;
  `phase` decoded leniently), `lossless: LosslessWatch?`, `searchStartedAtServer: Date?`, `addCommandBaseline: Int?`.
  `keptInPlace` stays decodable, is read only by migration, and is never set again.
- `LedgerEntry`: `keepIntentAt: Date?`, `findFiles: [FindFile]?` (`{id, albumId, size}`). An unknown or missing value
  decodes nil.
- **First pass after update** (`RunnerState.migrated["y5"]`):
  1. Clear the legacy locks (§4.5).
  2. Turn legacy keptInPlace finds into `.find(inPlaceLegacy)`. Their `keptAt` stays, so Not for me stays refused;
     "Add to your library" runs the merge, whose precondition accepts this one case.
  3. Every kept-and-moved request without a watch gets `LosslessWatch` with `deadline = now + 7 days`, never sooner,
     so nothing is deleted on update day. `findFiles` = its albums' lossy files now, and one AlbumSearch.
  4. Stall limit 60 → 180 once.
- `RequestMachine`: `.kept` stays terminal. The lossless follow-up lives outside the machine. `canBeRemoved` and
  `needsPolling` add `lossless != nil && !done`.

## 10. Tests

**Unit (MagpieKit, stubbed Lidarr/Navidrome; RED first):** resolver precedence table (one case per row, legacy in
place, unmatched by name, owner's artist); fact folding; two-tick idempotence; intent recovery for every phase × crash
point; legacy-lock clear; queued Keep busy → idle → sent; merge preconditions (a)–(d) with each refusal;
`keptLossyDelete` allow and refusals (FLAC id, unrecorded id, changed size, not kept, owner's artist, mixed bulk, main
root changed); deadline in server time; `Date` parsing and offset; stall warning, client re-read, 3-min default and
migration; RefreshArtist complete / failed / unseen; §6 match order (path, ±3 s, ambiguity refuses, outside the folder
refuses); lease orphan recovery; decoding of pre-Y5 requests, ledger and runner-state fixtures.

**End-to-end on the dev stack (`FindFlowIT`; G0 local only; creates and removes only its own objects):**
- Fixture: a `findflow` compose profile adds a ~60-line Torznab stub (`dev/fake-indexer`).
  - It offers an MP3 release, and on a toggle a FLAC release, of a fixture album.
  - Fetching a release's `.torrent` drops the album's files into a Lidarr **Torrent Blackhole** watch folder.
  - The test adds the indexer and download client and removes them afterwards.
  - This is the "fake slskd release": Lidarr's real search → grab → import path, with no Soulseek. Soulseek-only
    behaviour (stall removal) stays covered by stubs.
- Main run: Try → Find (Ready in Finds) → Add (moved, untagged, Lossless, AlbumSearch sent) → toggle FLAC → upgrade
  imported, MP3 in Lidarr's recycle bin → relinked, "Lossless".
- **L** (no FLAC):
  - a test-only grace of 30 s replaces 7 days;
  - the gated MP3 delete runs, the album stays monitored, and the status reads "Waiting for a lossless copy";
  - then the FLAC arrives → "Lossless".
- **M:** a pre-made main-root folder with a same-MBID tagged file → merge, owner file untouched (hash check); a
  different-MBID folder → refused, nothing written.

**Chaos (same IT, one parameterised test per row; each must reach the main run's end state):**
- kill at each step:
  - `FaultPoint` hooks before and after every write and save;
  - "kill" = drop the runner and build a new one from the same files, with a new process id;
- Lidarr busy: a client wrapper reports a queued command for N passes;
- the phone clock 10 min off (injected `now`);
- tagless files: ffmpeg `-map_metadata -1` → Ready through §6 path or ±3 s.


## 11. Files

- **New:** `Requests/{FindState,RequestRunner+Reconcile,RequestRunner+Lossless,RunnerState}.swift`,
  `App/AppModel+FindState.swift`, `RequestsTests/{FindStateTests,ReconcileTests,LosslessTests,FindFlowIT}.swift`,
  `dev/fake-indexer/`.
- **Changed:** `RequestRunner.swift` (tick, poll time, refresh, matching), `+Keep`, `+Stall`, `RequestStore.swift`,
  `ArtistLidarr.swift` (delegates to the resolver); LidarrKit `Ledger`, `WriteConfinement`, `DTOs` (command body
  artistId), the connection (`Date`); `ArtistLidarrLine`, `FindsShelf`, `RequestCopy`, the Settings stall picker;
  `scripts/check-writes.sh`; `docs/decisions.md` (MP3 rule, merge, 3-min default, server time).
- **Not touched:** CarPlay/ (Y2), library scoping (Y3).

## 12. Flagged for the critic

1. The copy reword ("your server", not "Lidarr").
2. Merge relies on Lidarr 3.2's folder transfer merging into an existing folder; test M must pass before it ships,
   otherwise collision = refuse only.
3. The MP3 upgrade from outside the profile's allowed set (test L).
4. The stall migration 60 → 180 overrides an owner-chosen 1 min, if they chose it.
5. Auto-delete runs with the recycle bin unset (owner's rule, permanent).
6. The fact-folding `stoppedInLidarr` on an unmonitored album with no files: confirm it can't fire during the add's
   refresh window. Proposed guard: only after RefreshArtist completes.
