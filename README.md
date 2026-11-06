# Magpie

An iOS and CarPlay music player for your own **Navidrome** server — and, if you run them, a friendly front end for
**Lidarr** (bring in music you don't have yet), **Aurral** (charts, recommendations, flows) and **ListenBrainz**
(scrobbling and recommendations).

- **Play your library** at home and in the car: albums, artists, genres, playlists, favourites, offline downloads,
  gapless playback, lyrics, a customisable Home and CarPlay layout.
- **Try something new.** Ask for a song or an album you don't have; it arrives in a separate **Finds** folder to try
  for a week. **Keep** it (it moves into your library and upgrades to lossless) or say **Not for me** (it's removed).
- **Discover** through Aurral's charts and flows, and ListenBrainz's recommendations, with previews.
- **Safe with your server.** Magpie never changes Lidarr unless you switch that on, and then only through a write
  gate that confines every change to what Magpie itself did.

Every feature works, or is hidden or explained, whether you connect Navidrome alone or with Lidarr, Aurral or both.

## Requirements

- Xcode 27.1 and iOS 27 (simulator or device), [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- A Navidrome server for real use; Lidarr (with Tubifarry), Aurral and ListenBrainz are optional
- For the local dev stack: Docker, `curl`, `jq`, `openssl`, `ffmpeg`

## Build and test

```sh
scripts/build.sh                              # xcodegen generate + build for the simulator
cd Packages/MagpieKit && swift test           # package tests (macOS)
scripts/test-app.sh                           # app + UI tests on the dedicated "Magpie Tests" simulator
scripts/test-all.sh                           # every gate a release needs
```

The Xcode project is generated from `project.yml`; open `Magpie.xcodeproj` after `xcodegen generate`. A local
Navidrome + Lidarr for development: `dev/bootstrap.sh` (see [`dev/README.md`](dev/README.md)). Installing on a
phone through TestFlight: [`docs/TESTFLIGHT.md`](docs/TESTFLIGHT.md).

## How it's put together

| Part | What it holds |
|---|---|
| `App/` | The SwiftUI app and CarPlay scene: `AppModel` (+ one file per feature), screens, downloads, playback glue |
| `Packages/MagpieKit/Sources/MagpieCore` | Models, networking, Keychain, redaction, preferences |
| `NavidromeKit` · `LidarrKit` · `AurralKit` · `ListenBrainzKit` | One client per service (Lidarr writes only through `LidarrWriteGate`) |
| `Requests` | The Try / Finds machinery: request state machine, runner, ledger-confined clean-up, Keep, Not for me |
| `Search` · `MatchIndex` | Merged search, outside songs and pages, library matching |
| `Playback` | Player, queue, audio engine, scrobbling, offline storage, previews |
| `DesignSystem` · `CarPlayUI` | Theme, tokens and components; CarPlay templates |
| `MagpieTestSupport` | Fakes and stub servers for tests |

## Documentation

- [`docs/decisions.md`](docs/decisions.md) — every product and engineering decision, numbered, with its reason
- [`docs/FLOWS.md`](docs/FLOWS.md) — how each flow behaves · [`docs/RUNBOOK.md`](docs/RUNBOOK.md) — running and testing
- [`docs/ways-of-working/`](docs/ways-of-working/README.md) — how the project is built (process, rules, templates, GitHub)
- [`docs/reviews/`](docs/reviews/) and [`docs/superpowers/plans/`](docs/superpowers/plans/) — past reviews and plans

## Contributing

Read [`CONTRIBUTING.md`](CONTRIBUTING.md). If you work with an AI assistant, it should start from
[`AGENTS.md`](AGENTS.md) (Claude Code also reads [`CLAUDE.md`](CLAUDE.md) and the role definitions in
[`.claude/agents/`](.claude/agents/)).
