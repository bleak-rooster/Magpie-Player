#!/usr/bin/env bash
set -euo pipefail
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd "$(dirname "$0")/.."
xcodegen generate
xcodebuild build -project Magpie.xcodeproj -scheme Magpie -destination 'platform=iOS Simulator,name=iPhone 18 Pro,OS=27.0' -quiet
