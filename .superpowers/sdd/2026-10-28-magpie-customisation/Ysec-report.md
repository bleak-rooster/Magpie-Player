# Round 12 security fixes (Ysec), branch `y8-security` off v0.0.1-custom (3706d04)

The input was `round12-security-review.md` (M1–M5, L1–L9). No server was contacted. Tests used mocks, URLProtocol stubs and temp files only. The simulator was "Magpie YS" (iPhone 18 Pro, iOS 27.0).

## Commits (prefix `Sec:`)

| Commit | Item |
|---|---|
| 8ac7f9d | M1: redirects |
| 6b40fa0 | M2 + M3: commands |
| 868cb57 | M4: Keep move destination at the gate |
| 260450c | M5: damaged runner state fails closed |
| 05b2c75 | L1: check-writes normalisation + planted-violation selftest |
| 55c0f7c | L3 + L7 |

## What changed

### M1: redirects (`MagpieCore/RedirectPolicy.swift`)
- `SameOriginRedirects.allows(original:to:)` follows a redirect only when all of these hold:
  - the original request is a GET or HEAD;
  - it carries no `X-Api-Key`, `X-ND-Authorization` or `Authorization` header;
  - the target has the same origin.
- Every write, and every keyed request (Lidarr, Aurral, Navidrome native, ListenBrainz), is refused on any 3xx, even on the same host. The 3xx comes back as the answer.
- So the gate and the Aurral allow-list are in effect re-run on every target: the only URL a keyed request is ever sent to is the one they checked.
- Unkeyed GETs (Subsonic query-auth streams and art) still follow same-origin redirects.

### M2: commands confined (`WriteGate.swift`, `WriteConfinement.swift`)
- `ArtistSearch` is confined. It needs `context.created(artistId)`: a ledger entry with `createdArtist` and a fresh MBID match.
- `RefreshAlbum` is removed from `allowedCommands` (nothing sent it).
- An unknown confined command now refuses instead of falling through.

### M3: exact command bodies (`commandReason`)
- AlbumSearch is exactly `{name, albumIds:[≥1 positive ints]}`.
- RefreshArtist and ArtistSearch are exactly `{name, artistId: positive int}`.
- Any extra key refuses, including `artistIds`, `isNewArtist`, or a key repeated in another case.
- String, float, bool, zero and negative ids refuse.

### M4: Keep move destination (`Context.editor`, `moveFiles: true`)
- After `findArtist`, the gate reads fresh in its confined turn:
  - `artistLookup(mbid).folder`
  - `directories(in: mainRoot)`
- It refuses when `WriteConfinement.moveDestinationTaken` is true. That rule moved from the runner's `mustStayInFinds`, which now delegates to it, so both use one rule: a loose case/diacritic/width match, or Lidarr's folder name drifting.
- An unreadable read gives `.unknown`.

### M5: runner state (`RunnerState.swift`, `RequestRunner.swift`, `RequestRunner+Reconcile.swift`)
- A new `RunnerState.read` replaces the old fail-open `load`. `load` remains only as a test helper.
- **Missing file:** empty state.
- **File that can't be read:** throws.
  - `modify` returns nil and saves nothing.
  - `tryAcquireArtist` returns false.
  - `foreignLease` reads as busy.
  - The runner's `load()` fails, so the pass is skipped.
- **File that reads but won't decode:**
  - It is renamed `<name>.corrupt`. A second damage gets `.corrupt-<time>-<id>`, so nothing is ever overwritten.
  - It is replaced at once by an empty state marked `damagedAt`.
  - If the move or the marker write fails, it throws.
- While `damagedAt` is set:
  - `migrateY5` never runs the destructive `clearLegacyLock` step (the locks stay), and logs it.
  - `RequestRunner.stateNeedsAttention` is true.
- Runner state is now excluded from backup (review §4).

### L1: check-writes (`scripts/check-writes.sh`, new `scripts/check-writes-selftest.sh`)
- Every `gate.send(` is normalised, with Perl:
  - lower-cased;
  - `%XX` and `\u{X}` decoded;
  - leading `/` and `api/v1/` dropped, and `//` collapsed.
- Verb and path must both be literals on the line. Provisioner's `gate.send("POST", path, body: body)` is allow-listed.
- Pins:
  - track-file deletes only from Not for me and the MP3 rule;
  - queue deletes only from Stall and the restarter, and only with `?\(Self.queueRemoval)`;
  - AlbumSearch, RefreshArtist and ArtistSearch each only from their callers; any other command name refuses;
  - `restartAny: true` only in `DownloadsInLidarr.swift`.
- The selftest copies Sources and App to a temp dir and plants 16 spellings. It is wired into `test-all.sh`.
- Two small changes keep the M1 code and tests passing the script:
  - `RedirectPolicy.swift` is added to the "names an API-key header" allow-list (it only refuses).
  - Two new test lines carry the `RedirectStub` allow-list marker.

### Lows also fixed (cheap)
- **L3:** `grabbed(downloadId:)` requires `record.downloadId == downloadId`.
- **L7:** `keepIntentAt` is decoded with `try`. A malformed value now fails the entry, so the ledger file is kept aside and every check fails closed.

### Not done (Lows)
- L2, L4: accepted by design.
- L5, L6, L8, L9: left for a later round. They need product-flow changes and their own tests.

## TDD evidence (RED, then GREEN)

| Item | RED | GREEN |
|---|---|---|
| M1 | 16 issues: keyed DELETE 301/302/307/308, POST/PUT/DELETE/PATCH and keyed GETs all landed on the same-origin target; the policy rules failed 5 times | HTTPTransportTests 10/10 |
| M2/M3 | 20 issues: extra keys, string/float ids, `artistIds`, ArtistSearch for artists 99 and 7, RefreshAlbum all sent | Round12GateTests |
| M4 | All 6 cases sent the move: taken (exact, case, diacritic+case), drifted name, no name, reads down | Green |
| M5 | Compile RED: `read`, `damagedAt` and `stateNeedsAttention` were absent (tests written first, sources reverted to check) | RunnerStateDamageTests 6/6 |
| L1 | The selftest against the pre-fix script: all 16 planted violations NOT caught | All 16 caught; clean tree passes |
| L3/L7 | Both failed | Green |

Two existing tests were adjusted:
- `WriteGateAllowListTests` no longer sends ArtistSearch through a gate without a ledger (it is confined now).
- `rawBodiesAreScannedAsSent` moved its "sibling keys are fine" case to `POST /artist`, and now asserts that the AlbumSearch body with an extra key is refused.

## Final runs
- Package suite (`swift test`): exit 0, every run passed.
- App suite (Magpie YS, app uninstalled first): TEST SUCCEEDED (960 Swift Testing cases passed, 0 failed; XCTest UI cases skipped without MAGPIE_IT). The first attempt was killed by my 60-minute background limit while still running (no result); the second ran to completion (~75 min).
- `check-writes.sh`: pass. `check-writes-selftest.sh`: pass.
- `check-release.sh`: OK (both variants).

## Concerns
- **M1 is stricter than the review asked.** Keyed GETs no longer follow even a same-origin redirect. If a Navidrome or Lidarr behind a proxy relies on a GET redirect (for example adding a trailing slash) for a keyed call, that call now fails with a 3xx instead of silently following. Unkeyed Subsonic GETs are unaffected.
- **M5's needs-attention is not shown to the owner yet.** `stateNeedsAttention` is exposed on the runner and logged, but no screen reads it; wiring it to a banner is left for the UI owner. `damagedAt` stays set until the file is deleted (sign-out removes it).
- **M5 leaves migration flags on the state file.** The review's alternative, moving the Y5 flag into the ledger, wasn't done. The damage marker blocks the destructive step instead.
