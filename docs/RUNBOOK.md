# Magpie Runbook

## Toolchain
Every shell: `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` (xcode-select points to CLT). The scripts do this for you. Requires XcodeGen (`brew install xcodegen`).

## Scripts
- `scripts/test-packages.sh` runs `swift test` in `Packages/MagpieKit`.
- `scripts/test-app.sh` runs `xcodegen generate`, then unit and UI tests on the "iPhone 18 Pro" simulator.
- `scripts/test-all.sh` runs both.
- `scripts/it.sh` runs server integration tests (`MAGPIE_IT=1`, dev stack only).
- `scripts/build.sh` generates the project and builds the app.

`Magpie.xcodeproj` and `App/Info.plist` are generated from `project.yml` and are git-ignored.

## What works
- M0 (in progress): package skeleton, XcodeGen app shell, placeholder Connect screen, CarPlay scene delegate stub.
