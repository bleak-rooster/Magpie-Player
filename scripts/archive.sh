#!/usr/bin/env bash
# Archive Magpie for TestFlight (docs/TESTFLIGHT.md).
#
#   scripts/archive.sh --team TEAMID [--build N] [--carplay] [--upload] [--out DIR]
#   scripts/archive.sh --unsigned [--build N] [--carplay] [--out DIR]
#
#   --team TEAMID  Apple Developer team id (10 characters; Xcode › Settings › Accounts). Or set MAGPIE_TEAM_ID.
#   --build N      CFBundleVersion, must go up with every upload. Or set MAGPIE_BUILD_NUMBER. Default 1, except
#                  with --upload, which needs it given (a repeated build number is rejected after the upload).
#   --carplay      Sign with the CarPlay audio entitlement. Only once Apple has granted it to your team:
#                  before that, no provisioning profile carries it and signing fails.
#   --upload       Send the build to App Store Connect with the account signed in to Xcode.
#                  Without it, an .ipa is exported to DIR/export for Xcode Organizer or Transporter.
#   --unsigned     Archive with signing off (no team, no export). For checking the build only.
#   --out DIR      Where the archive and export go. Default build/testflight.
#
# Signing is automatic (Xcode makes or fetches the profiles: -allowProvisioningUpdates). No credentials
# are read, stored or passed here: uploads use the Apple ID signed in to Xcode.
set -euo pipefail
cd "$(dirname "$0")/.."

die() { echo "archive.sh: $*" >&2; exit 1; }

team="${MAGPIE_TEAM_ID:-}"
build="${MAGPIE_BUILD_NUMBER:-}"
carplay=no
upload=no
unsigned=no
out="build/testflight"
while [ $# -gt 0 ]; do
  case "$1" in
    --team) [ $# -ge 2 ] || die "--team needs a team id"; team="$2"; shift 2 ;;
    --build) [ $# -ge 2 ] || die "--build needs a number"; build="$2"; shift 2 ;;
    --carplay) carplay=yes; shift ;;
    --upload) upload=yes; shift ;;
    --unsigned) unsigned=yes; shift ;;
    --out) [ $# -ge 2 ] || die "--out needs a directory"; out="$2"; shift 2 ;;
    -h|--help) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option $1 (see --help)" ;;
  esac
done

if [ -z "$build" ]; then
  [ "$upload" = no ] || die "--upload needs --build N (higher than the last upload; e.g. --build $(git rev-list --count HEAD 2>/dev/null || echo 2))"
  build=1
fi
[[ "$build" =~ ^[1-9][0-9]{0,8}(\.[0-9]{1,4}){0,2}$ ]] || die "--build must be a number such as 1, 2 or 1.0.3 (got '$build')"
if [ "$unsigned" = yes ]; then
  [ "$upload" = no ] || die "--upload needs a signed build; drop --unsigned"
else
  [ -n "$team" ] || die "no team id. Pass --team TEAMID (Xcode › Settings › Accounts › your team, or developer.apple.com › Membership details), or set MAGPIE_TEAM_ID"
  [[ "$team" =~ ^[A-Z0-9]{10}$ ]] || die "team id should be 10 capital letters or digits (got '$team')"
fi

# Full Xcode, not the Command Line Tools: DEVELOPER_DIR if set, else /Applications/Xcode.app, else xcode-select.
if [ -z "${DEVELOPER_DIR:-}" ]; then
  if [ -d /Applications/Xcode.app/Contents/Developer ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  else
    DEVELOPER_DIR="$(xcode-select -p 2>/dev/null || true)"
    export DEVELOPER_DIR
  fi
fi
case "$DEVELOPER_DIR" in
  ""|*CommandLineTools*) die "full Xcode not found (DEVELOPER_DIR='$DEVELOPER_DIR'). Install Xcode, then export DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer or run: sudo xcode-select -s /Applications/Xcode.app" ;;
esac
[ -x "$DEVELOPER_DIR/usr/bin/xcodebuild" ] || die "no xcodebuild in DEVELOPER_DIR=$DEVELOPER_DIR"
command -v xcodegen >/dev/null || die "xcodegen not found (brew install xcodegen)"

# testflight: App/MagpieNoCarPlay.entitlements (MAGPIE_CARPLAY=NO, project default for device builds).
# testflight-carplay: App/Magpie.entitlements.
settings=(CURRENT_PROJECT_VERSION="$build")
if [ "$carplay" = yes ]; then settings+=(MAGPIE_CARPLAY=YES); else settings+=(MAGPIE_CARPLAY=NO); fi
if [ "$unsigned" = yes ]; then
  settings+=(CODE_SIGNING_ALLOWED=NO)
else
  settings+=(DEVELOPMENT_TEAM="$team" CODE_SIGN_STYLE=Automatic)
fi

archive="$out/Magpie.xcarchive"
rm -rf "$archive"
mkdir -p "$out"

xcodegen generate --quiet
xcodebuild -project Magpie.xcodeproj -target Magpie -configuration Release -sdk iphoneos -showBuildSettings \
  "${settings[@]}" 2>/dev/null | awk -F' = ' '$1 ~ /^ *CODE_SIGN_ENTITLEMENTS$/ {print $2}' > "$out/entitlements-path"
echo "archive.sh: Release, build $build, CarPlay $carplay, entitlements $(cat "$out/entitlements-path")"

provisioning=()
[ "$unsigned" = yes ] || provisioning=(-allowProvisioningUpdates)
xcodebuild archive -project Magpie.xcodeproj -scheme Magpie -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$archive" ${provisioning[@]+"${provisioning[@]}"} \
  "${settings[@]}" -quiet
echo "archive.sh: archived to $archive"
[ "$unsigned" = no ] || exit 0

destination=export
[ "$upload" = no ] || destination=upload
options="$out/ExportOptions.plist"
cat > "$options" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>app-store-connect</string>
	<key>destination</key>
	<string>$destination</string>
	<key>teamID</key>
	<string>$team</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>uploadSymbols</key>
	<true/>
	<key>manageAppVersionAndBuildNumber</key>
	<false/>
</dict>
</plist>
PLIST

xcodebuild -exportArchive -archivePath "$archive" -exportPath "$out/export" -exportOptionsPlist "$options" \
  -allowProvisioningUpdates
if [ "$upload" = yes ]; then
  echo "archive.sh: uploaded build $build. App Store Connect › TestFlight shows it after processing (often 5–30 min)."
else
  echo "archive.sh: exported $out/export/Magpie.ipa. Upload it with Transporter, or use --upload."
fi
