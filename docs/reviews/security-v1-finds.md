# Magpie v1 security review: Finds and Polish (M6 + M7)

Date: 2026-10-27. Branch `v1-finds`, range `m8` (`399c4ea`) .. `06f01f1`. Read-only audit. The only repo write is this
file. Probes ran in the session scratchpad (`…/scratchpad/sec2`). The dev stack and external services were not
contacted.

Scope: `git diff m8..HEAD` (94 files). That covers M6 Finds mode (PathGuard, Finds setup, Finds-mode Try,
FindsIdentity, Keep, Not for me) and M7 (Character dial/Immersive, LandingRule, Bring in more, Made for you via
ListenBrainz, artist not-yet albums, CarPlay Finds / Keep / Try it next). Binding guards: v1-decision-review G0–G9 and
A1–A17, the global constraints in `global.md`, and D1–D29. Items fixed in `security-v1.md` are not re-reported
unless they regressed. None did.

## Summary

| Severity | Count |
|---|---|
| Critical | 0 |
| High | 0 |
| Medium | 2 |
| Low | 9 |

**Medium**
- **FM1.** The WriteGate allow-list now admits destructive shapes (track-file delete, artist move, artist delete) with no confinement at the gate. G3 and G4 depend only on runner code.
- **FM2.** D29 fails open. A freshly landed find sends "now playing" (and can be scrobbled) before the Finds ids are read, and the Finds identity is lost on Lidarr disconnect or rescope.

**Low:** FL1 PathGuard splits on grapheme clusters, not bytes. FL2 Not for me does not tie the Lidarr album to the request's release group. FL3 Keep's destination check races the queued `BulkMoveArtist`. FL4 Bring in more is outside the G7 5-active limit. FL5 CarPlay Keep is one tap with no confirm. FL6 Activity "Remove" drops a Keep that is still in flight. FL7 `check-writes.sh` does not scan `App/`. FL8 CarPlay search and the Artist page now send queries to outside services. FL9 The Keep restore's point-back root is not re-validated as a current root folder.

## Method / evidence log

| # | What was run | Result |
|---|---|---|
| F1 | `git diff --stat m8..HEAD`, then a full read of PathGuard, WriteGate (diff and full file), LidarrClient/DTOs/Audit diff, RequestRunner+Keep/+NotForMe/+BringInMore, the RequestRunner diff, FindsSetupStore, AppModel+Finds/+Keep/+NotForMe/+CarPlay/+MadeForYou/+Requests, NavidromeAdapters, the Player diff, the ListenBrainzClient diff, MadeForYou, ArtistNotYet, CarPlay FindsAndTry/Controller | See findings |
| F2 | Grep of every `gate.send` and write verb in `Packages/MagpieKit/Sources` and `App` | 14 gate call sites (Provisioner 1, RequestRunner 4, NotForMe 4, BringInMore 3, Keep 2). No write verb in `App/`. `LidarrConnection.send` is still `fileprivate` |
| F3 | Scratch `swiftc` probe: `PathGuard.swift` (lines 1–114) plus cases with combining marks after `/` and `..`, compared with a byte-level POSIX resolver | `"/finds/../\u{0338}x"` → `isInside == true`, but the server resolves it to `/\u{0338}x` (outside the root). See FL1 |
| F4 | Grep of the diff for `URLSession`, `URLCache`, `UserDefaults`, Keychain, `print(`, `privacy: .public`, `User-Agent` | No new sessions or caches in Sources/App. Public logs carry only `Log.category(of:)` and counts. Test-only `print` and `URLSession.shared` (FindsIT `devLidarr`, host-allowlisted by `TryDevStack.lidarrAccess`) |
| F5 | `Package.swift` diff and the plist/entitlement stat | No new dependencies. No ATS or entitlement change |

---

## Medium

### FM1. The WriteGate allow-list admits unconfined destructive writes. G3 and G4 rely only on runner code

- **Location**: `Packages/MagpieKit/Sources/LidarrKit/WriteGate.swift:228-245` (allow-list), `:285-305` (`editorReason`), `:249-258` (`artistDeleteReason`), `:260-267` (`trackFileBulkReason`).
- **What the gate now allows**:
  - `DELETE /trackfile/bulk {"trackFileIds":[…]}` with **any** ids, and `DELETE /trackfile/{id}` with any id. These delete media from disk, permanently when the recycle bin is unset.
  - `PUT /artist/editor` with any body except `deleteFiles`, `addImportListExclusion` or `applyTags: replace`. That includes `{"artistIds":[every id], "rootFolderPath":"/anything", "moveFiles":true, "qualityProfileId":…, "metadataProfileId":…, "monitored":false}`.
  - The new `monitorNewItems` rule only applies when that key is present. Any other editor body is unconstrained, so the rule "Magpie only ever adds; it doesn't stop following anything" is not enforced. For example, `{"artistIds":[…], "monitored":false}` passes.
  - `DELETE /artist/{id}?deleteFiles=false&addImportListExclusion=false` for any id. That removes an owner's artist from Lidarr (history, monitoring, profile), though not its files.
- **Scenario**: a runner bug, or a future caller in the `Requests` module, sends the wrong ids or a wider body. The new `internal` visibility of `RequestRunner.gate`/`lidarr`/`ledger` widens who can do this. Examples: a stale `KeepProgress` restore, a mis-scoped `artistIds`, a `trackFiles(artistId:)` result used where `albumId` was meant. The gate logs the write and sends it. The PathGuard, ledger, `magpie-find` and MBID checks all live in `RequestRunner+Keep/+NotForMe`. G1 describes the gate as the single backstop, and for G3/G4 it is now a shape check only.
- **Impact**: the owner's media could be deleted, or the owner's artists bulk-moved or unmonitored, with only a change-log line as evidence. No current code path does this (F2: every call site builds exactly the G3/G4 body after a fresh proof), so the issue is defence in depth, not a live bug.
- **Fix**:
  1. Constrain the shapes at the gate:
     - `PUT /artist/editor` takes exactly one `artistIds` element.
     - `moveFiles: true` only together with `rootFolderPath` equal to a root the gate was configured with (the main root), and only with the G4 key set `{artistIds, rootFolderPath, moveFiles, qualityProfileId, tags, applyTags}`.
     - `moveFiles: false` only with `rootFolderPath` equal to the configured Finds root.
     - Refuse `monitored`, `metadataProfileId` and `monitorNewItems` other than `new` everywhere.
  2. Give the gate the confirmed Finds root (a `PathGuard`). Before `DELETE /trackfile/*`, have it GET each id and refuse unless every path is `isInside` the Finds root and the artist carries `magpie-find`. Before `DELETE /artist/{id}`, have it refuse unless the artist carries `magpie-find` and its path is inside the Finds root. This duplicates the runner's proof, so the gate holds even if the runner is wrong.
  3. Add WriteGateTests for each refusal. Close the older L9: `PUT artist/{id}` and `PUT album/{id}` still accept any body and still have no caller.

### FM2. D29 fails open: finds can be "now playing"/scrobbled to the owner's ListenBrainz/Last.fm

- **Location**: `App/Playback/NavidromeAdapters.swift:60-67` (`FindsIdentity.isFind`), `App/AppModel+Requests.swift:292-294` (`requestBecameReady` starts `refreshFinds()` and `land()` as two independent Tasks), `App/AppModel+Requests.swift:285-288` (`readySong` uses Subsonic `getSong`, so `libraryId == nil`), `Packages/MagpieKit/Sources/Playback/Player.swift:326-328` (the scrobble guard), `App/AppModel+Finds.swift:17-27,166-177`, `App/AppModel.swift:585` (`disconnectLidarr` sets `findsSetup = nil`), `NavidromeClient.swift:320` (`maxPages: 20`).
- **Scenarios**:
  1. **First play of a landed find (common path).** A Finds-mode Try becomes ready while its wait screen is showing, so `LandingRule` returns `.play`. `land()` reads the song through Subsonic (no `libraryId`) and plays it at once. `Player.loadCurrent` then sends `scrobble?submission=false`. The `refreshFinds()` Task started next to it reads up to 10k songs from the native API and usually finishes later. Meanwhile `songIds` holds the previous read, which is not nil and does not contain the new song, so `isFind` returns false. Navidrome forwards the "now playing" to ListenBrainz/Last.fm. If the refresh fails (offline, 5xx), the full scrobble at the half-way mark also goes out.
  2. **Identity lost.** `isFind` returns false whenever `findsSetup?.library` is nil, which happens on any of:
     - Lidarr disconnect (`findsStore.clear` plus `findsSetup = nil`);
     - a Lidarr API key rotation or address change (new `instanceScope`, so `load` returns an empty setup);
     - a change of the first Navidrome address (new `navidromeScope`);
     - a launch where the Lidarr connection can't be read.

     The Finds library and its songs still exist on Navidrome, and every song in it is scrobbled from then on.
  3. **Finds library larger than 20 × 500 songs.** The songs past the cap are never in `songIds`, so they count as library songs.
- **Impact**: trial plays leak to the owner's public listening history, against D29 ("Finds are never scrobbled") and the fail-closed note in `FindsIdentity`'s own doc comment. That comment covers only the "never read" case.
- **Fix**:
  1. In `isFind`, also treat as a find any `songId` of a request with `isFind && state == .ready` (the runner already knows these), and do it before `land()` runs. Or have `requestBecameReady` await `refreshFinds()` before `land()`.
  2. Key the Finds library id and its song-id cache by `navidromeScope` only, independent of the Lidarr scope. Keep the identity (fail closed) through a Lidarr disconnect or rescope until the owner explicitly clears Finds.
  3. When the song cap is hit, set `songIds = nil` (unknown, so fail closed).
  4. Add tests: a ready find played before the refresh completes, and a Lidarr disconnect followed by a Finds song.

## Low

### FL1. PathGuard splits paths on grapheme clusters, so a combining mark can hide a `..` from the `..` refusal
- **Location**: `Packages/MagpieKit/Sources/LidarrKit/PathGuard.swift:56` (`path.split(separator: "/")`), `:87`, `:97-99`. The same pattern appears in `RequestRunner+Keep.swift:590-592` (`lastComponent`) and `NavidromeClient.swift:345-356`.
- **Evidence (F3)**: `/finds/../\u{0338}x` splits into Swift components `["finds", "../̸x"]`, because `/` plus U+0338 is one `Character`. That passes `isInside`. A POSIX server resolves the same bytes to `/\u{0338}x`. Any grapheme extender works the same way (U+0301, U+200D…).
- **Impact**: low. The escaped component always starts with a combining mark, so it can't name an existing owner folder such as `/music`. Lidarr (.NET `GetFullPath`) never reports `..`. The gate refuses non-ASCII in URL segments, but paths reach Lidarr only as data. Still, the doc's "refuses any path with a `..` component" is not byte-true.
- **Fix**: split and compare on `path.utf8` with the byte `0x2F` (and in `lastComponent`), and refuse any component that begins with a Unicode combining or extend scalar. Add F3's cases to `PathGuardTests`.

### FL2. Not for me does not tie the Lidarr album to the request's release group
- **Location**: `RequestRunner+NotForMe.swift:397-398,405,419-420`. The proof matches a ledger entry by `albumId` only. It never checks the album's `foreignAlbumId` against `entry.rgMbid` or `r.plan.releaseGroupMBID`.
- **Scenario**: Lidarr deletes and re-creates album rows on a metadata refresh, and SQLite can reuse a max row id. A stale `albumId` would then select another album's track files under the same find artist.
- **Impact**: the files are still confined to the Magpie-created, tagged find artist folder in the Finds root. Extremely unlikely.
- **Fix**: GET the album (or filter `albums(artistId:)`) and require `foreignAlbumId == entry.rgMbid == plan.releaseGroupMBID` in `proveLetGo`.

### FL3. Keep's destination check races the queued `BulkMoveArtist`
- **Location**: `RequestRunner+Keep.swift:173-181` (`directories(in: mainRoot)`) → `:204` (PUT). Lidarr runs the move later as a queued command.
- **Scenario**: a folder of the same name appears in the main root between the listing and the command's execution, for example from the owner's own copy or another tool. Lidarr's `TransferFolder` merges into an existing target and overwrites same-named files.
- **Impact**: same-named owner files in that one folder could be overwritten. The window is seconds, longer while Lidarr's queue is busy.
- **Fix**: this can't be fully closed client-side. Document it in the RUNBOOK. Optionally re-list immediately before the PUT, and refuse while Lidarr's command queue is busy (`commands()` has non-finished items).

### FL4. Bring in more sits outside G7
- **Location**: `RequestRunner+BringInMore.swift:89` (`bringInLimit = 20`), `:186` (only checks fewer than 5 active), `:135` (one `AlbumSearch` for up to 20 albums).
- **Scenario**: each tap monitors and searches 20 more releases, and taps can repeat until the whole discography (`everything` includes singles and compilations) is requested. None of it counts toward the 5 active requests.
- **Impact**: indexer and download-client load, and real downloads on the owner's stack. It is owner-initiated and the sheet shows the count.
- **Fix**: get a ruling against G7 ("Batch Try is not in v1"). If it stands, add a per-artist cooldown or cumulative cap, for example one Bring in more per artist per day or at most 20 releases in flight.

### FL5. CarPlay Keep is one tap with no confirm while driving
- **Location**: `CarPlayController.swift:405-437` (`CPNowPlayingAddToLibraryButton` calls `keepCurrent()`).
- **Impact**: an accidental tap moves the whole artist into the main root and switches it to "Magpie Lossless", which then triggers upgrade grabs. Reversible by hand, not destructive. D12 accepted Keep as the add-to-library button.
- **Fix**: none required. Note in the RUNBOOK that car Keep moves the whole artist and upgrades quality.

### FL6. Activity "Remove" forgets a request with a Keep in flight
- **Location**: `RequestRunner.swift:259-262` (`forget` refuses only active, `cleanupPending` and `notForMe` requests), `App/Screens/Activity/ActivityView.swift:50-51` (the swipe "Remove" shows for any non-cancellable state, including `.ready`).
- **Impact**: a `keep != nil` request leaves the list, so `followKeeps` never settles or restores it. The ledger keeps saying kept, so nothing gets deleted (fail-safe). But a failed move is never put back (tag and profile), no "needs attention" is shown, and `relinkPending` is dropped (the queue keeps the stale song id).
- **Fix**: `forget` also refuses `keep != nil`, `relinkPending == true`, `keepNeedsAttention` and `notForMeNeedsAttention`.

### FL7. `scripts/check-writes.sh` scans only `Packages/MagpieKit/Sources`
- **Location**: `scripts/check-writes.sh:11`.
- **Impact**: `App/` holds the Lidarr API key (`LidarrConnectionStore`) and builds transports. A future raw `URLRequest` write there would not be flagged. Nothing in `App/` writes today (F2).
- **Fix**: scan `App` too, with the same allowlist mechanism.

### FL8. CarPlay search and the Artist page now send queries to outside services
- **Location**: `App/AppModel+CarPlay.swift:56-61` (car search now uses `mergedSearch`: `labs.api.listenbrainz.org` plus Lidarr search, which Lidarr forwards to its metadata server), `App/AppModel+MadeForYou.swift:90-93` / `ArtistNotYet.swift:27-38` (every Artist page view does a Lidarr lookup by MBID or name).
- **Impact**: privacy. In m8, car search went to the library only. No credentials are sent (A9 holds: labs gets no token).
- **Fix**: none required. Mention in the privacy notes and RUNBOOK (D4 covers the phone).

### FL9. The Keep restore's point-back root is not re-validated as a current root folder
- **Location**: `RequestRunner+Keep.swift:405-435`. The restore uses `p.findsRoot` from the saved `KeepProgress` and builds `findsGuard` from fresh roots, but never calls `findsRootStillValid`.
- **Impact**: if the owner removed or changed the Finds root after a failed move, `rootFolderPath: p.findsRoot, moveFiles: false` points the artist at a path that is no longer a root. This is a database-only change and no files move. `filesNeverLeft` already requires the folder to be listed there.
- **Fix**: require `findsRootStillValid(p.findsRoot, main: p.mainRoot, roots:)` before a point-back, else needs attention.

---

## Residual risks (accepted or out of client reach)

- **A compromised Lidarr is already all-powerful.** It can delete or move anything itself. Magpie adds no write capability beyond the owner's API key. Crafted paths, ids or command lists from Lidarr cannot redirect a write to another host: `SameOriginRedirects` applies, and every write goes to `<base>/api/v1`. Within those bounds, the worst a lying Lidarr gets is Magpie deleting the files of Magpie's own tagged finds.
- **Symlinks inside the Finds folder.** Lidarr reports a link's unresolved path. A link such as `/finds/Artist/Album -> /music/Owner/Album` placed by someone with server access would let Not for me delete through it. PathGuard's comment documents this. The ledger, `magpie-find` tag and MBID checks still have to pass.
- **Alias roots.** Two Lidarr roots that are the same directory by symlink or bind mount can't be detected lexically. Keep would see the find's own folder as "existing" and untag only, which is fail-safe.
- **A TOCTOU between the proof and Lidarr executing the delete** remains in principle, for example the owner moving the artist in Lidarr's UI during that window. Deletes are by track-file id, and the records were proven on disk a moment earlier.
- **Older Lows still open from `security-v1.md`**:
  - L1: sign-out keeps the ListenBrainz token, and now the Made for you shelf with it.
  - L5: ListenBrainz path segments are now also built from the server-supplied `validate-token` `user_name` (host fixed, GET only).
  - L7: no response size cap.
  - L8: AirPlay stream credentials.
  - L9: unused `PUT artist/{id}` / `PUT album/{id}` (folded into FM1).
  - L10: `adoptCreatedArtist`. This one is now contained: Not for me and Keep also need `magpie-find`, a path in the Finds root and a matching artist MBID.
  - L11, L12.

## Verified safe

- **G2.** The Finds root is chosen only from Lidarr's root list, with an explicit confirm dialog ("Use … for Finds? Magpie will only delete files it brought in here"). It is never inferred. `validateRoot` refuses equal, nested and `/` roots against every other root and the main root, ignoring case. Before every Finds-mode add and every Keep or Not for me it is re-validated byte-exact against fresh `rootfolder` (`findsRootStillValid`). If it fails, Try falls back to the main root and says so.
- **G3 (Not for me).** Before every write, a fresh proof checks:
  - the ledger says `createdArtist`, there is an entry for the album with `wasMonitoredBefore == false`, and nothing of the artist is kept;
  - the artist carries `magpie-find` and its MBID matches the plan;
  - the artist path is strictly inside the Finds root and inside no other root;
  - every artist and album track file is inside both the Finds root and the artist folder (case-sensitive, byte-exact accept);
  - every album file is on disk where Lidarr records it;
  - no `BulkMoveArtist` is running;
  - the recycle-bin state matches what the owner confirmed (otherwise `confirmAgain`).

  Writes are saved before sending (M6) and bounded (`writeBudget`, 3 lost answers, 30 min). Artist removal is always `deleteFiles=false&addImportListExclusion=false`, only with no track files, no other monitored album and an empty folder walk (≤ 50 folders). A malformed track file in the `LossyArray` is skipped, which can only delete less. Hidden for existing-artist (G6) and fallback rows (`letGoCandidate`). Not offered in CarPlay.
- **G4 (Keep).** Keep:
  - checks the ledger `createdArtist`, the tag, the MBID and the Finds path on fresh state;
  - requires the Lidarr-named folder to be byte-equal to the current one, and no same or similar name in the main root (case, diacritic and width folded);
  - sends exactly the G4 body with one `artistIds` element;
  - is saved and ledgered as kept before the write;
  - follows the `BulkMoveArtist` and verifies files on disk;
  - restores only the fields it changed. A path point-back (`moveFiles:false`) happens only after a fresh proof that nothing moved.

  One Keep, Not for me or Bring in more per artist at a time (`keepingArtists`, with no await between check and insert).
- **G5 / G6.** Bring in more acts only on a kept, moved, Magpie-created artist (ledger, MBID, untagged, path in the main root). It only adds (monitor and search); `monitorNewItems` is only ever `new`; and its ledger entries are kept and closed, so Cancel and Not for me never touch them. An existing artist's Try stays `.fallback` (`monitorExisting`).
- **G1.** The gate checks the switch on every send. Change-log write failures block the send. `JSONKeyScan`, normalisation and the never-call list are unchanged. Non-GET calls are still confined to `WriteGate.swift`.
- **Credentials.** No new secret storage. The ListenBrainz token stays in the Keychain, goes only to `api.listenbrainz.org` (validate-token, createdfor, playlist), is rate-limited (2/s) and has a 5 s deadline. A shelf read made with a superseded token is dropped. The Finds setup, played finds and song-id caches in UserDefaults hold paths and ids only, scoped per Lidarr/Navidrome account, and are cleared on sign-out (Navidrome scope) and disconnect (Lidarr scope). New public logs carry only error categories and counts. The change log now holds `rootFolderPath` and track-file ids, which are not secrets.
- **Crafted server data.** Lidarr ids are `Int`. MBIDs are UUID-validated before reaching any URL (playlist ids, recording ids). ListenBrainz/JSPF strings are capped. Lidarr paths reach Navidrome only as quick-scan targets (`fullScan=false`) and as local filters.
- **DoS bounds.** Keep polls every 2 s for at most 90 s inline, then every 30 s up to 30 min. Not for me is bounded by writes, lost answers and 30 min. Relink runs every 15 s for at most 30 min. The Finds library read stops at 20 pages. Made for you reads at most 6 songs at once. Artist not-yet has a 5 s deadline and a cap of 30.
- **CarPlay.** Not for me and Bring in more are absent. Try it next needs an action-sheet confirm. Keep is the phone's Keep with every check (see FL5).
- **G0.** New integration tests (FindsIT) check that the host is `127.0.0.1`/`localhost` and use the dev-instance marker. The raw `devLidarr` helper used for test fixtures bypasses the gate by design and is test-only.
- **Supply chain.** No new dependencies. No ATS or entitlement changes.
