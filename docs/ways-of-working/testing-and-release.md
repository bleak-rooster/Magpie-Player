# Testing and release

## Test layers

| Layer | Where | Run with | Notes |
|---|---|---|---|
| Package tests | `Packages/MagpieKit/Tests/<Module>Tests` | `cd Packages/MagpieKit && swift test` | macOS, seconds. Most logic is tested here. |
| Hostile data | `Packages/MagpieKit/Tests/HostileDataTests` | (part of `swift test`) | Seeded fuzzing of every decoder and model builder. |
| Hosted app tests | `Tests/MagpieTests` | `scripts/test-app.sh` or `xcodebuild test … -only-testing:MagpieTests` | On the dedicated "Magpie Tests" simulator only (`scripts/test-sim.sh`); ~8 minutes. |
| UI tests | `Tests/MagpieUITests` | `scripts/test-app.sh` | XCTest. Reset the simulator's Keychain; never run on a simulator signed in to real servers. |
| Integration (dev stack) | `*IT.swift` | `scripts/it.sh` (`MAGPIE_IT=1`) | Real Navidrome + Lidarr on `127.0.0.1`; tests create and remove their own artists. |
| Live | e.g. `LiveSongMatchIT`, `PopularSinglesDevStackIT` | `MAGPIE_LIVE=1` (plus `MAGPIE_IT=1`) | Real MusicBrainz / metadata servers; only with the owner's leave. |

Fakes live in `MagpieTestSupport` (`MockTransport`, `StubAurral`, `JSONFuzzer`, …) and in the test harnesses
(`RunnerHarness` with `FakeLidarr`, the app's fakes). Prefer them to anything networked.

## The dev stack

`dev/bootstrap.sh` starts a local Navidrome and Lidarr (Docker, `127.0.0.1` only), configures them and writes throwaway
credentials to the git-ignored `dev/.env.local`. `dev/smoke.sh` checks every API the app uses. `dev/aurral-stub/start.sh`
serves a stub Aurral. See `dev/README.md`. Don't tear it down between runs; reuse logins (Navidrome rate-limits about
5 logins per 20 s); never write to anything a test didn't create.

## Gates before a build

1. `scripts/check-writes.sh` (and `check-writes-selftest.sh`) — no unpinned Lidarr write, Aurral route or forbidden host.
2. Package suite — all green.
3. App suite (hosted + UI) — all green.
4. `scripts/check-release.sh` — both variants' Info.plist, ATS, privacy manifest and entitlements.
5. `scripts/test-all.sh` runs all of the above, including the Release-configuration legs.

## Archive and upload (controller only)

```sh
scripts/archive.sh --team <TEAM_ID> --build <N> --upload      # CarPlay variant (default)
scripts/archive.sh --team <TEAM_ID> --build <N> --no-carplay   # without CarPlay
```

`--upload` runs the Release test legs first unless `--skip-release-tests` (only if they already passed on that
commit). The build number must go up every upload. Without `--upload` an `.ipa` is exported for Xcode Organizer or
Transporter. The full TestFlight walkthrough is `docs/TESTFLIGHT.md`; never commit a team id, signing identity or
App Store Connect credential.
