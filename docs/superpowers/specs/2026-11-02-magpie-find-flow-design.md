# Magpie round 12, Y5: Find → Add design (plan items 8 and 9)

Status: **revised per critic (Y5-design-review.md; controller rulings C1–C5, I1–I12, M1–M8 adopted).** Source: docs/superpowers/specs/2026-11-01-magpie-round-12-plan.md
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
  find, keptInFinds, adding(AddPhase), inLibrary(Lossless), needsAttention(Attention) }
enum AddPhase { case queued, moving }          // "Adding when your server is free…" / "Adding to your library…"
enum Lossless { case lossless, waiting(mp3RemovedOn: Date?), mp3Removed }  // nil date: no auto-delete (C2)
```
**Precedence** (first match wins):
1. I9: an artist one of Magpie's own requests names (request `lidarrArtistId` + ledger `created`) resolves through
   the request first, tagless files or not. Otherwise: no MBID on either side and the name matches → `.unmatched` ("Couldn't match this artist", no action). Name-only
   matches never reach a write (item 9.9). `notInLidarr` keeps the I3 candidate pick (owner-confirmed MBID).
2. Artist not created by Magpie (ledger `created(_:)`, id + MBID) → `.owners` (today's monitored / not monitored).
3. A request of the artist has `keepNeedsAttention` or `notForMeNeedsAttention` → `.needsAttention`.
4. A `KeepIntent` exists → `.adding(.queued)` while phase is `queued`, else `.adding(.moving)`.
5. Lidarr says find: `magpie-find` in tags → `.find`. Path inside the Finds root, tag gone, ledger kept → the legacy
   keptInPlace: `.keptInFinds` (I4: stays as it is, refuse-only, "Kept · in your Finds folder for now").
6. Otherwise (main root, untagged, Magpie-created) → `.inLibrary`, with `Lossless` derived from track files of the
   find's albums: all lossless → `.lossless`; lossy files present → `.waiting(deadline or nil)`; the watch removed
   the MP3 (read-confirmed) and no lossless file yet → `.mp3Removed`.

A ledger "finds-mode, created, not kept" entry with neither tag nor Finds path is **not** a find: it is a Keep whose
commit was lost, or a find someone moved by hand; it goes to **verify** (§4.3), never straight to commit (C2), and it
gets the watch without auto-delete.

**Copy** (design language §5; "MP3" and "lossless" are format words, already in Settings copy):
| State | Status line | Action |
|---|---|---|
| find | In your Finds | Add to your library |
| adding(queued) | Adding when your server is free… | none |
| adding(moving) | Adding to your library… | none |
| inLibrary(waiting) | In your library · lossless soon. The MP3 is removed on <date> unless a lossless copy turns up. (No date without auto-delete. I7: + "This can't be undone." when the recycle bin is empty.) | Remove the MP3 now |
| inLibrary(mp3Removed) | Waiting for a lossless copy | none |
| inLibrary(lossless) | In your library · Lossless | (R18 Add more) |
| unmatched | Couldn't match this artist | none |
| needsAttention(mp3) | Couldn't remove the MP3 · needs a look | none |
| keepFailed (M7) | Couldn't add it to your library this time. It's still in your Finds. | Add to your library |
| collision (C1) | Your library already has a folder for <artist>, so it stays in your Finds for now. | none |
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
`RunnerState.leases: [Lease{key, op, requestId, startedAt, renewedAt, process}]`, saved before the work starts and
dropped after; the holder renews `renewedAt` every pass and every follow step (I1 heartbeat). `process` is a UUID per
runner. A lease of another process is **orphaned only when stale** (`renewedAt` older than 2 min or 2 passes); then the
next pass runs that op's *follow/verify* path only (never a fresh start) and drops it. A fresh foreign lease blocks
(another runner, e.g. a background pass, is working). M5: Keep intents are per artist; a Keep re-checks `notForMe`
and the letting-go lease before every write.

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
3. **Verify** as today, timed from **`sentAt`** (I2: `keepStartGrace`, `keepMoveLimit` and the `commandBaseline`
   read just before the PUT all count from the send, not the tap) (BulkMoveArtist after `commandBaseline`, artist path in main root, every file on disk there,
   Finds folder gone, tag off, Lossless profile). A failed move → `restoring` (as today) → intent cleared.
4. **Commit**, only after verify, as **one atomic ledger save** (I10 `Ledger.update(artistId:)`): `keptAt = server
   now`, `keepIntentAt = nil`; the request goes to `.kept`; a `LosslessWatch(autoDelete: true)` starts (§5); then the
   scan and relink run as today. **`findFiles`** are recorded at **intent** time (C3), from the find's track files
   inside the Finds folder: `{id, albumId, foreignTrackId, relativePath, size, quality}` (relative to the artist folder).
5. **Launch recovery** (every load, and every pass for intents without a lease):
   - `queued` or `intent`: nothing was sent. Drop the intent if it's older than 24 h; otherwise it stays queued.
   - `sent`/`moving`, artist already in main root + untagged → verify (files on disk there), then commit.
   - Still a tagged find and no move command after the baseline within `keepStartGrace` of `sentAt` → the PUT never
     applied → clear the intent (the find stays, Add offered again).
   - Anything else → today's follow (limits, restore, needs attention).
   - **Legacy lock (the crash of item 9.4), I3:** `keptAt` set, no intent, a request of the artist exists with no
     `keepNeedsAttention`, the artist still tagged and its path **== that request's `keep.fromPath`** exactly → clear
     `keptAt` (logged to the change log). Anything less certain stays locked.
   - **Adopted** (finds-mode created, no `keptAt`, artist untagged in main root, no intent): verify as in 3; if it
     holds, commit with `LosslessWatch(autoDelete: false)` (C2).
6. **Collision (C1): refuse only, no merge.** When `<main root>/<Lidarr folder name>` exists (or the name drifted),
   nothing is written, no intent stays, nothing is "kept"; the page says "Your library already has a folder for
   <artist>, so it stays in your Finds for now." The untag-only write is no longer sent by new Keeps (allowed for the
   restore only).

## 5. Lossless search, upgrade watch, relink, MP3 rule (`RequestRunner+Lossless.swift`)

`LosslessWatch {albumIds, startedAt, autoDelete, deadline?, searches, lastSearchAt, lastCheckAt, removed, doneAt?}`.
- **Search:** right after commit, `POST /command {name: AlbumSearch, albumIds}` for the find's monitored albums (an
  existing gate shape). Then once per 24 h until lossless or 30 days, then Lidarr's own RSS monitoring carries on.
- **Watch** (each pass, throttled to 5 min in the foreground and every background pass): `trackFiles(albumId)`. The
  Magpie Lossless profile (FLAC only, upgrade allowed) makes Lidarr's import of a FLAC an upgrade, so the MP3 goes to
  Lidarr's recycle bin. When every track of the find's recordings is lossless → scan the artist folder (targeted, as
  Keep) → relink (§6) → `songSuffix` updated → `.lossless`. Flagged: test L confirms on 3.2 that an MP3 outside the
  profile's allowed set is upgraded.
- **MP3 rule (owner answer 3; C2, C3).** Auto-delete only when `autoDelete` (a Y5 owner-tapped Keep): `deadline =
  commit server time + 7 days`. Adopted, hand-moved and pre-Y5 kept finds: watch + search + manual only.
  Removal (auto or manual) = **re-map then delete**: `POST /command RefreshArtist {artistId}` and wait for that command
  to complete; then for each recorded find file, the fresh track file at exactly `<artist folder>/<relativePath>`
  (M3 loose compare: standardised, case- and NFC-folded) whose track's `foreignTrackId` is the recorded one, whose
  quality is on the **lossy allowlist** (M2: MP3-*, AAC-*, OGG/Vorbis-*, Opus-*, WMA; anything unknown refuses) and
  whose size equals the recorded size. A size change or no mapping → needs attention "Couldn't remove the MP3" (Lidarr
  rewriting tags changes the size; trackfile ids go stale after the move, Keep.swift:30,334). Delete via the gate
  (`DELETE /trackfile/bulk`, one at a time on 404/405); then **read again**: `removed` is set only when the files are
  gone (never claimed without a read). I6: re-read the album; if Lidarr unmonitored it, re-monitor it (`PUT
  /album/monitor true`, the existing shape, ledger entry present). Then the targeted scan, and M1: the new
  `onMP3Removed(request, songId)` callback drops queue entries and the phone download of that song id; stars and plays
  stay on Navidrome's (now gone) song id, documented in decisions.md.
- **I5:** after removal the watch checks at most daily; it ends (`doneAt`) at lossless or 30 days after start. A gate
  refusal or a missing ledger record → needs attention. `Ledger.forgetFinished` keeps an instance whose entries back an
  active watch (the entry stays open until `doneAt`).
- **Remove the MP3 now:** confirmation "Remove the MP3 now?" / "This song leaves your library until a lossless copy
  arrives." (+ I7 "This can't be undone." when `mediamanagement.recycleBin` is empty) / Remove / Cancel. One delete:
  manual and deadline share the request's lease, the second sees `removed` or no mappable file.

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
  becomes 3 min (choices 1/2/3/5/10). I11: a saved value is **not** migrated; only the default changes.
- **Server time (item 9.7).** `LidarrClient` exposes each response's `Date` header; the runner keeps `clockOffset =
  serverDate − phone now` from the latest successful read, and `serverNow()` uses it for the history cursor,
  `searchStartedAtServer`, the event filters and the 7-day deadline. No header → offset 0. M4: cached or 304
  responses and offsets over 1 day are ignored; an offset change over 60 s resets the history cursor (with the minute
  of overlap); migration (§9.3) uses `serverNow`.
- **RefreshArtist completion (item 9.8, I12).** After `POST /artist` the runner saves `commandBaseline` and follows the
  newest `RefreshArtist` after it whose `artistIds` is **non-empty and names the artist** (a global RefreshArtist never
  counts): completed with the album still missing → `.noRelease` at once; failed → the `serviceUnavailable` wait;
  cleanup's `settling` ends on completion. None seen within 2 min, or the command disappeared (pruned) → unknown → the
  existing `albumAppearLimit` / `addSettleTime` apply. Fact-folding `stoppedInLidarr` only fires after that refresh
  completed **and** the album was listed at least once (I12/6).

## 8. Gate (G1): every new or changed shape

| Shape | HTTP | Confinement |
|---|---|---|
| **keptLossyDelete** (new rule, existing verbs) | `DELETE /trackfile/{id}`, `DELETE /trackfile/bulk {trackFileIds}` | Every id, from a fresh `GET /trackfile/{id}` + `GET /track?albumId=`: its artist the ledger says Magpie created (id + MBID) with a **confirmed** `keptAt` and no intent; its path strictly inside the current main root and equal (M3 loose) to `<artist path>/<relativePath>` of a recorded `findFiles` item of the same album, whose `foreignTrackId` is the file's track's; same size; quality on the lossy allowlist (M2). |
| findDelete (existing rule) | same | Unchanged checks, but "kept" means `isKeptOrKeeping` (C5). |
| One rule per call (C4) | | `Verdict.confined(artists:, rule: .findDelete / .keptLossyDelete)`; ids that would need both rules, or neither, refuse. Last-moment check per rule: findDelete → none of the artists `isKeptOrKeeping`; keptLossyDelete → every artist still confirmed kept, no intent. |
| Lossless search | `POST /command {name: AlbumSearch, albumIds}` | Unchanged; albums must have a ledger entry (new check, matching album monitor). |
| Keep / merge move | `PUT /artist/editor` G4 `MoveBody` | Unchanged (merge uses the same body and the same confinement). The untag-only body is no longer sent by new Keeps. It stays allowed, for the restore. |

C5: `LedgerEntry.isKeptOrKeeping` (`keptAt != nil || keepIntentAt != nil`) replaces bare `keptAt` in every refusing
reader (WriteConfinement kept/stillUnkept/albumMonitor/queueDelete, RequestRunner cleanup, Stall `mayRemoveDownloads`,
NotForMe 408/457, ArtistLidarr state). Plain `keptAt` only where a **confirmed** Keep is required (BringInMore,
keptLossyDelete). check-writes.sh pins:
- a bare `.keptAt` read outside Ledger.swift, the Keep commit and those two is flagged (allowlist by file);
- `gate.send("DELETE", "trackfile` appears only in RequestRunner+NotForMe.swift and RequestRunner+Lossless.swift;
- the new FindFlowIT helper is allowlisted like FindsIT (`G1 allowlist: devLidarr`).
The change log records every delete with its rule name.

## 9. Data and migration (all fields optional: old files decode)

- `MagpieRequest`: `keep: KeepProgress?` (new phase `queued`; new `sentAt`), `lossless: LosslessWatch?`,
  `searchStartedAtServer: Date?`, `addCommandBaseline: Int?`, `mp3NeedsAttention`, `collision`. `keptInPlace` stays
  (I4) and is never set by new Keeps.
- `LedgerEntry`: `keepIntentAt: Date?`, `findFiles: [FindFile]?`. `TrackFile.size` (M6, exists) and a new `LidarrTrack`
  DTO (`id, albumId, trackFileId, foreignTrackId, foreignRecordingId`). An unknown or missing value decodes nil.
- **First pass after update** (`RunnerState.migrated["y5"]`, set **last**, so a crash re-runs it; every step
  idempotent):
  1. Clear the legacy locks (§4.5, I3 rules).
  2. Legacy keptInPlace finds stay as they are (I4).
  3. Every kept-and-moved request without a watch gets `LosslessWatch(autoDelete: false)` (C2), started at `serverNow`,
     and one AlbumSearch. Without recorded `findFiles`, "Remove the MP3 now" is not offered for it (no record, no
     delete: the gate needs one).
  M8: once migrated, rolling back to v1.0-rc is unsupported (rc ignores the new fields and could re-offer Keep);
  recorded in decisions.md.
- `RequestMachine`: `.kept` stays terminal. The lossless follow-up lives outside the machine. `canBeRemoved` and
  `needsPolling` add `lossless != nil && !done`.

## 10. Tests

**Unit (MagpieKit, stubbed Lidarr/Navidrome; RED first):** resolver precedence table (one case per row, legacy in
place, unmatched by name, owner's artist); fact folding; two-tick idempotence; intent recovery for every phase × crash
point; legacy-lock clear; queued Keep busy → idle → sent; collision refuses with nothing written;
`keptLossyDelete` allow and refusals (FLAC id, unrecorded path, changed size, not kept, intent only, owner's artist,
mixed bulk, main root changed); deadline in server time; `Date` parsing, offset, 304/cached and >1 day ignored; stall
warning, client re-read, 3-min default, saved value untouched; RefreshArtist complete / failed / unseen / global /
pruned; §6 match order (path, ±3 s, ambiguity refuses, outside the folder
refuses); lease orphan recovery; decoding of pre-Y5 requests, ledger and runner-state fixtures.

**The critic's 16 (each its own test):** (1) every refusing keptAt reader with only an intent; (2) stillUnkept vs
keptLossyDelete races both ways; (3) stale (pre-move) ids, (4) re-imported ids, (5) changed sizes; (6) adopted and
(7) legacy finds never auto-deleted; (8) auto-unmonitor after delete → re-monitored; (9) recycle-bin-empty copy;
(10) forget / sign-out with an active watch; (11) manual delete vs deadline → one delete; (12) two runners with a
delayed write (lease heartbeat); (13) a queued Keep sent after the grace (timed from sentAt); (14) a crash after a
mixed commit (atomic ledger); (15) migration idempotent and re-run; (16) a tagless own find, and the partial-album
fold (.imported per recording).

**Step 0 spike (dev stack, before code; I12):** (2) collision refusal sends nothing; (3) does Lidarr 3.2 upgrade an
MP3 outside the Lossless allowed set to FLAC on import? (6) RefreshArtist command shape and timing after an add
(artistIds, global vs targeted, pruning). Results in §13. Fallback for (3): if no upgrade, the 7-day delete makes the
track missing and the daily AlbumSearch brings the FLAC.

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
- **M:** a pre-made main-root folder with the artist's name → refused, nothing written, owner file untouched.

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
  `scripts/check-writes.sh`; `docs/decisions.md` (MP3 rule, collision refusal, 3-min default, server time, M1, M8).
- **Not touched:** CarPlay/ (Y2), library scoping (Y3).

## 12. Critic rulings applied

C1 refuse-only collisions; C2 auto-delete only for Y5 owner-tapped Keeps; C3 path + track re-mapping after a
RefreshArtist; C4 one rule per call with per-rule last-moment checks; C5 `isKeptOrKeeping` everywhere a reader refuses;
I1–I12 and M1–M8 as above. The copy keeps "your server" (glossary).

## 13. Step 0 spike results

Dev Lidarr 3.2.0.5144, 2026-11-02, test artist (Judie Tzuke) created and removed by the spike script.
- **(6) RefreshArtist.** `POST /artist` queues `RefreshArtist` with `body.artistIds == [id]` (non-empty, names the
  artist) and a `RescanFolders` with the same ids; it completed within ~4 s. A runner-sent `{name: RefreshArtist,
  artistId}` is listed with `body.artistIds == [id]` too. Global refreshes (the scheduled one) carry no ids. So the
  §7 rule (non-empty ids naming the artist, newer than the baseline) is sound.
- **(3) Upgrade outside the allowed set: yes.** With the artist on Magpie Lossless (FLAC only), an MP3-192 file
  imported, then a FLAC of the same track imported: no "not an upgrade" rejection; the FLAC replaced the track file
  and the MP3 left the disk (recycle bin empty on the dev stack, so permanently). The album stayed monitored.
  `wanted/cutoff` did **not** list the album while it held the MP3 (Lidarr's cutoff query skips qualities outside the
  profile), so Lidarr's own cutoff search won't look for it: Magpie's daily AlbumSearch (§5) is required, not optional.
- **I6.** Deleting a track file did not unmonitor the album on the dev stack (that is an owner setting); the re-monitor
  stays, for owners who have "Unmonitor deleted tracks" on.
- **(2) Collision.** Refuse-only; covered by unit tests and IT test M (nothing sent).
