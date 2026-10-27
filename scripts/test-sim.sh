#!/usr/bin/env bash
# C-I1 (G0): tests only ever run on a simulator of their own, "Magpie Tests" (iPhone 18 Pro, iOS 27.0).
# Prints its UDID, creating it first if it is missing. Never touches, erases or boots any other simulator:
# the owner's simulators may be signed in to real servers, and hosted tests launch the real app.
set -euo pipefail
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

name="Magpie Tests"
devtype="com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro"
runtime="com.apple.CoreSimulator.SimRuntime.iOS-27-0"

udid="$(xcrun simctl list devices -j | /usr/bin/python3 -c '
import json, sys
name, runtime = sys.argv[1], sys.argv[2]
devices = json.load(sys.stdin)["devices"].get(runtime, [])
match = [d["udid"] for d in devices if d["name"] == name and d.get("isAvailable", True)]
print(match[0] if match else "")
' "$name" "$runtime")"

if [ -z "$udid" ]; then
  udid="$(xcrun simctl create "$name" "$devtype" "$runtime")"
  echo "created simulator \"$name\" ($udid)" >&2
fi
echo "$udid"
