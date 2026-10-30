# Crash hunt 4: hostile data and decoding

Hunter 4, branch `worktree-agent-aafa944aaf14cc6b8` (from 7f93d25, TestFlight 0.0.1 build 9). Simulator "Magpie Hunt 4"
(iPhone 18 Pro, iOS 27.0, created for this run and deleted at the end). No real servers and no dev-stack writes: everything
ran through `MockTransport` and in-memory models.

## What was swept

A seeded generative fuzzer, `MagpieTestSupport.JSONFuzzer` (SplitMix64, the same cases every run), mutates each fixture in
`Tests/Fixtures` and synthetic answers: fields deleted, nulled or given the wrong type; hostile numbers (`1e400`, `-1e400`,
`1e300`, `1e17`, `±2^63`, `2^64`, `5e-324`, `-1`, `1.5`); hostile strings (RTL overrides, 300 stacked combining marks,
ZWJ and flag emoji, escaped NUL, lone surrogates, 20,000 characters, path traversal, dates out of range); arrays of up to
2,000 copies (50,000 in the dedicated test); nesting 50 to 5,000 deep; duplicated elements and keys; and whole-body
replacements (HTML and XML with a 200, Subsonic error envelopes, empty, truncated, random bytes, odd statuses). It renders
raw JSON text, so it can send what `JSONSerialization` would refuse to write. Each sweep asserts no trap, a typed error
(`NavidromeError`, `LidarrError`, `ListenBrainzError`, `MusicBrainzError`) or sane values, no case over 1 s and the sweep
under 9 s. Every decoded model goes through `UISink`: the car's row builders, `clamp`, Home shelves, genre grouping, the
offline catalog, the match index and its snapshot, with D12's limits asserted (at most 12 items and 5 sections after
`clamp`, Home at most `maxSections` and `maxItems` with ≤ 4 tiles a shelf, `fitSearchItems` ≤ max, navigator depth ≤ 3).

| Sweep (package target `HostileDataTests`) | Cases |
|---|---|
| `NavidromeFuzzTests.subsonicEndpointsNeverTrap`: getAlbumList2, getAlbum ×2, getArtists, getArtist, getPlaylists, getPlaylist, search3, getTopSongs, getLyricsBySongId, getOpenSubsonicExtensions, getGenres, getStarred2, getSongsByGenre, getSong, getScanStatus | 5,008 |
| `NavidromeFuzzTests.nativeEndpointsLoginAndPingNeverTrap`: `/api/song` (songsPage, songs(inLibrary:), songs(recordingMBID:) ×2) with fuzzed `X-Total-Count`, `/api/library`, ping and `/auth/login` bodies on fresh clients | 5,200 |
| `NavidromeFuzzTests.hugeAnswersStayLinear`: 50,000 songs and 50,000 genres in one answer | 2 |
| `ExternalFuzzTests.lidarrEndpointsNeverTrap`: 21 LidarrClient reads (status, health, rootfolder, profiles, tags, plugins, recycle bin, lookup + raw lookup JSON, search, artists, artist, albums + `bringInOption`, trackfiles, queue, history, command(s), filesystem) + 200 audits | 5,019 + 200 |
| `ExternalFuzzTests.listenBrainzAndMusicBrainzNeverTrap`: labs search, created-for, playlist (JSPF), validate-token, MusicBrainz recording | 5,200 |
| `ModelFuzzTests.searchMatchAndBuildersNeverTrap` (6 kinds): `MergedSearch.merge`, match ladder, `MadeForYou.resolve/shelf`, `ArtistNotYet.excluding`, `GenreGroups.grouped` with random owner preferences, all `CarPlayRows` builders, `homeShelfSizes`, `clamp`, `CPNavigator`, duration text, with generated hostile models (NaN, ±inf, 1e300, Int.min/max, duplicate ids) | 6,000 |
| `ModelFuzzTests.matchIndexSnapshotsNeverTrap`: mutated `MatchIndexStore` snapshots loaded from disk | 5,000 |
| `ModelFuzzTests.normaliseStaysLinear`: 20,000-character adversarial names through Normalize, GenreGroups, ArtistNotYet | 7 |
| `PreferencesFuzzTests.randomStoredPreferencesAlwaysNormalise`: random JSON documents for every area + mutations of each area's stored defaults; each area must come back normalised and within its limits, and round-trip | 10,000 |
| `HostileDataRegressionTests`: one reduced test per crash below | 9 |

App target (`Tests/MagpieTests/HostileNumberAppTests`): `BringInCopy.size`, `FindsShelf.daysLeft`, `DurationText`
(clock, spoken, minutes), `RequestCopy.percent` with every hostile Double, plus a 5,000-value seeded sweep.

## Crashes found and fixed

| # | Crash | Root cause | Fix | Test |
|---|---|---|---|---|
| 1 | NSInvalidArgumentException "Invalid number value (infinite) in JSON write" (uncatchable) | `Packages/MagpieKit/Sources/MagpieCore/Preferences.swift:189` (`decoded`): `JSONSerialization` reads a stored `-1e400` as -infinity; the merge wrote it back with `JSONSerialization.data(withJSONObject:)`. At launch, so a crash loop. | Refuse objects `JSONSerialization.isValidJSONObject` rejects before writing. | `HostileDataRegressionTests.preferencesWithAnInfiniteNumberFallBackToDefaults` |
| 2 | Trap "Double value cannot be converted to Int" | `Packages/MagpieKit/Sources/LidarrKit/DTOs.swift:54` (`KeyedDecodingContainer.int`): `Int(d)` for a finite `d` past Int (`"id": 1e300`). Every Lidarr DTO's ids and counts. | `Int(exactly: d.rounded(.towardZero))`: out of range reads as missing (the row is dropped when it's the id). | `lidarrIdsOutOfIntRangeDropTheRow` |
| 3 | Trap "… to Int64" | `DTOs.swift:146` (`RootFolder.freeSpace`): `Int64($0)` on `1e300`. | `Int64(exactly:)`: unknown. | `lidarrFreeSpaceOutOfRangeIsUnknown` |
| 4 | Trap "… to Int" | `Packages/MagpieKit/Sources/LidarrKit/JSONValue.swift:47` (`intValue`): integral doubles past Int (`1e300`) passed the `d == d.rounded()` check. Provisioner and the runner read profile, command and artist ids with it. | `Int(exactly: d)`. | `jsonValueIntegralDoubleOutOfRangeIsNotAnInt` |
| 5 | Arithmetic overflow trap | `Packages/MagpieKit/Sources/Search/GenreGroups.swift:87`: a group's album and song counts summed with `+` (two genres reporting `9223372036854775807`). | `GenreGroups.total`: saturating sum. | `genreGroupCountsSaturate` |
| 6 | SIGBUS (stack overflow) | `Packages/MagpieKit/Sources/LidarrKit/LidarrClient.swift:74,86`: `JSONSerialization` recurses once per nested object with no limit; ~500 levels overflow a 512 KB Swift concurrency thread. `/system/plugins` (the audit) and `config/mediamanagement`. Same in `Preferences.decode` (`Preferences.swift:175`). | New `MagpieCore.JSONNesting` measures untrusted bytes first (limit 64, as `JSONKeyScan` in the write gate). | `lidarrDeeplyNestedAnswersDontOverflow`, `preferencesDeeplyNestedDontOverflow` |
| 7 | SIGBUS (stack overflow) | `JSONValue.swift:13` (`init(from:)`): one recursion per level, as deep as `JSONDecoder` allows (512); 300 levels overflowed in a debug build. `artistLookupJSON`, provisioning reads, POST answers. | Refuse past `JSONNesting.limit` via `decoder.codingPath.count`. | `jsonValueDeepDocumentsDontOverflow` |
| 8 | Main-thread stall (watchdog risk) | `Packages/MagpieKit/Sources/MatchIndex/Normalize.swift` `dashSplit` and `Search/ArtistNotYet.swift:51`: `range(of:options: .backwards)` is quadratic on a run of flag emoji (regional indicators): 20,000 flags took ~3 s per `Normalize.name` (13.8 s for the test). `AppModel.bridgeMix` (car "Try it next", `@MainActor`) normalises up to 100 uncapped Navidrome artist names. | `Normalize.lastRange(of:in:)`: forward searches from each match (same last, overlapping match); 0.06 s. | `normalisingAFlagRunIsLinear` |
| 9 | Trap "… to Int" (hunter 1's report) | `App/AppModel+BringInMore.swift:32` (`BringInCopy.size`): Lidarr release lengths ≥ ~3e22 s passed `isFinite`. | `Int(exactly:)`: an impossible length is unknown (no size line). | `HostileNumberAppTests.bringInSizeHoldsForHugeLengths` |
| 10 | Trap "… infinite or NaN" / "> Int.max" (hunter 2's report) | `App/Screens/Finds/FindsShelf.swift:71` (`daysLeft`): `createdAt` from the server or a saved copy; a NaN or far date. | Held to ±1e9 days, NaN as today. | `findDaysLeftHoldsForAnyDate` |
| 11 | NSInternalInconsistencyException "isfinite(timeInterval)" | `App/Screens/Shared/ScreenKit.swift:149` (`DurationText.spoken`): DateComponentsFormatter on NaN or ±inf. Latent: today's callers (Now Playing's VoiceOver value, album rows) only pass finite values since the net hunt's hardening. | Non-finite is spoken as 0, like `clock`'s 0:00. | `spokenDurationHoldsForNonFiniteValues`, `formattersHoldForEveryValue` |

`ScrobbleRouter.listen` (`App/Playback/ScrobbleRouter.swift:316`, `Int(song.duration * 1000)` traps at ≥ ~9.2e15 s) was
also found by this sweep; hunters 1 and 2 fixed it on their branches with `NavidromeClient.scrobble` and
`ListenBrainzClient.submitListens`, so it is left untouched here to avoid a merge conflict.

## Checked and holding (no change)

- Every NavidromeKit, LidarrKit, ListenBrainzKit and MusicBrainzClient decode throws its typed error for HTML, XML,
  truncated, empty and random bodies and for nesting to 5,000; `JSONDecoder` rejects `1e400`, so no infinity reaches a
  model from the network (only huge finite values, which the fixes above cover).
- `LossyArray` advances past bad elements (verified: no infinite loop on `[1,"x",2]`).
- D12: `clamp`, `home`, `homeShelfSizes`, `fitSearchItems`, `CPNavigator` held for every generated input, including
  negative and Int.min/Int.max counts and limits.
- `CarPlayRows.duration`, `DurationText.clock/minutes`, `RequestCopy.percent`, `QueueItem.progress` (0…1),
  `MatchIndexStore` snapshot loading, `OfflineCatalog`, `MadeForYou.shelf` (≤ 6), `MergedSearch` band limits.
- 50,000 songs decode, index and build car rows in about 4 s (debug); 50,000 genres group linearly.

## Suspected, not reproduced

- SwiftUI `ForEach`/`List` with duplicate server ids (search, starred, playlists with a song twice): the car rows dedupe
  or index them, but the phone's lists were not driven with duplicates here. SwiftUI usually logs rather than crashes.
- `MusicBrainzClient` reads a `length` of `5e-324` ms as 0 s (not used by any caller today).
- `MatchIndex(songs:)` with an infinite song length would make the snapshot unwritable (`JSONEncoder` throws; logged,
  no crash). The network can't produce one (`JSONDecoder` rejects `1e400`).

## Commits

- `de9a0f2` Hostile numbers: infinite stored preference, Lidarr ids/sizes beyond Int, genre count overflow (+ fuzzer, target)
- `8e1f128` Deeply nested JSON (JSONNesting, JSONValue depth); client fuzz sweeps
- `30ca516` Linear Normalize on flag runs; model, snapshot and preferences sweeps
- `4641568` App formatters: BringInMore:32, FindsShelf:71, DurationText.spoken
- this report

## Test results (simulator "Magpie Hunt 4", own DerivedData)

- Package (`swift test`): 656 tests in 9 test targets, all passed (HostileDataTests: 19 tests, 25 s in the parallel run).
- App (`xcodebuild test`, scheme Magpie, script logic of `scripts/test-app.sh` with this UDID, no MAGPIE_IT): MagpieTests
  678 tests in 71 suites passed; MagpieUITests 28 run, 27 skipped (need MAGPIE_IT), 0 failures. `** TEST SUCCEEDED **`.
