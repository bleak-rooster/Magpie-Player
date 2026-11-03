#!/usr/bin/env bash
# T1: what a TestFlight build must look like, checked without an Apple account. Archives Release twice
# with signing off (scripts/archive.sh --unsigned): the default "testflight" variant (no CarPlay) and
# "testflight-carplay". Then checks the built Info.plist (versions, ATS, export compliance, background
# audio, icon), the privacy manifest, and which entitlements each variant would be signed with.
set -euo pipefail
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
cd "$(dirname "$0")/.."

out="build/check-release"
rm -rf "$out"
fails=0
fail() { echo "FAIL: $*" >&2; fails=$((fails + 1)); }
pb() { /usr/libexec/PlistBuddy -c "Print :$1" "$2" 2>/dev/null; }

# The one place the version literal lives is project.yml; the archive must carry exactly that.
want_version="$(awk -F'"' '/^ *MARKETING_VERSION:/ {print $2; exit}' project.yml)"
[ -n "$want_version" ] || fail "MARKETING_VERSION not found in project.yml"

check_variant() {
  local variant="$1" carplay="$2"
  local archive="$out/$variant/Magpie.xcarchive"
  local app="$archive/Products/Applications/Magpie.app"
  local plist="$app/Info.plist"
  echo "== $variant"
  [ -f "$plist" ] || { fail "$variant: no Info.plist in $app"; return; }

  plutil -lint "$plist" >/dev/null || fail "$variant: Info.plist does not lint"
  [ "$(pb CFBundleShortVersionString "$plist")" = "$want_version" ] || fail "$variant: CFBundleShortVersionString is not $want_version"
  [ "$(pb CFBundleVersion "$plist")" = "7" ] || fail "$variant: CFBundleVersion is not the --build number (7)"
  [ "$(pb CFBundleIdentifier "$plist")" = "com.bleak-rooster.magpie" ] || fail "$variant: bundle id"
  [ "$(pb NSAppTransportSecurity:NSAllowsArbitraryLoads "$plist")" = "true" ] || fail "$variant: Release lacks NSAllowsArbitraryLoads"
  for k in NSAllowsLocalNetworking NSAllowsArbitraryLoadsInWebContent NSAllowsArbitraryLoadsForMedia; do
    pb "NSAppTransportSecurity:$k" "$plist" >/dev/null && fail "$variant: $k present (iOS would ignore arbitrary loads)"
  done
  [ "$(pb ITSAppUsesNonExemptEncryption "$plist")" = "false" ] || fail "$variant: ITSAppUsesNonExemptEncryption is not NO"
  [ "$(pb UIBackgroundModes:0 "$plist")" = "audio" ] || fail "$variant: UIBackgroundModes audio missing"
  pb NSLocalNetworkUsageDescription "$plist" >/dev/null || fail "$variant: NSLocalNetworkUsageDescription missing"
  [ "$(pb NSBonjourServices:0 "$plist")" = "_http._tcp" ] || fail "$variant: NSBonjourServices missing"
  [ "$(pb NSBonjourServices:1 "$plist")" = "_magpie._tcp" ] || fail "$variant: NSBonjourServices lacks _magpie._tcp (the Local Network ask)"
  pb UILaunchScreen "$plist" >/dev/null || fail "$variant: UILaunchScreen missing"
  # iPad apps that allow multitasking must list all four orientations, or the upload is rejected.
  pb UISupportedInterfaceOrientations~ipad:3 "$plist" >/dev/null || fail "$variant: iPad orientations incomplete"
  [ "$(pb UISupportedInterfaceOrientations:0 "$plist")" = "UIInterfaceOrientationPortrait" ] \
    && ! pb UISupportedInterfaceOrientations:1 "$plist" >/dev/null || fail "$variant: iPhone is not portrait-only"
  pb CFBundleIcons:CFBundlePrimaryIcon:CFBundleIconName "$plist" | grep -qx AppIcon || fail "$variant: no AppIcon in Info.plist"
  [ -f "$app/Assets.car" ] || fail "$variant: Assets.car missing"
  # R14: the 12 alternate icons (Settings › Appearance › App icon) must be declared in the built bundle; round 13 adds
  # the green cover's Ink and Sunset colourways.
  local alt
  for alt in DefaultInk DefaultSunset RecordForest RecordInk RecordSunset MagpieForest MagpieInk MagpieSunset WaveForest WaveInk WaveSunset NestForest NestInk NestSunset; do
    pb "CFBundleIcons:CFBundleAlternateIcons:$alt:CFBundleIconName" "$plist" | grep -qx "$alt" || fail "$variant: alternate icon $alt missing"
  done

  local manifest="$app/PrivacyInfo.xcprivacy"
  if [ -f "$manifest" ]; then
    plutil -lint "$manifest" >/dev/null || fail "$variant: PrivacyInfo.xcprivacy does not lint"
    [ "$(pb NSPrivacyTracking "$manifest")" = "false" ] || fail "$variant: NSPrivacyTracking is not false"
  else
    fail "$variant: PrivacyInfo.xcprivacy not in the app bundle"
  fi

  local scene=no
  pb UIApplicationSceneManifest:UISceneConfigurations:CPTemplateApplicationSceneSessionRoleApplication "$plist" >/dev/null && scene=yes

  local ent
  ent="$(cat "$out/$variant/entitlements-path")"
  [ -f "$ent" ] || { fail "$variant: entitlements file $ent missing"; return; }
  plutil -lint "$ent" >/dev/null || fail "$variant: $ent does not lint"
  local has=no
  pb com.apple.developer.carplay-audio "$ent" >/dev/null && has=yes
  if [ "$carplay" = yes ]; then
    [ "$has" = yes ] || fail "$variant: entitlements lack carplay-audio"
    [ "$scene" = yes ] || fail "$variant: CarPlay scene missing from Info.plist"
  else
    [ "$has" = no ] || fail "$variant: entitlements carry carplay-audio"
    [ "$scene" = no ] || fail "$variant: CarPlay scene still declared without the entitlement"
  fi
  echo "   entitlements: $ent (carplay-audio: $has), CarPlay scene: $scene"
}

scripts/archive.sh --unsigned --build 7 --out "$out/testflight"
check_variant testflight no
scripts/archive.sh --unsigned --build 7 --carplay --out "$out/testflight-carplay"
check_variant testflight-carplay yes

# The checked-in sources too: the manifest lints, and the simulator keeps CarPlay in every configuration.
plutil -lint App/PrivacyInfo.xcprivacy >/dev/null || fail "App/PrivacyInfo.xcprivacy does not lint"
for config in Debug Release; do
  sim_ent="$(xcodebuild -project Magpie.xcodeproj -target Magpie -configuration "$config" -sdk iphonesimulator \
    -showBuildSettings 2>/dev/null | awk -F' = ' '$1 ~ /^ *CODE_SIGN_ENTITLEMENTS$/ {print $2}')"
  pb com.apple.developer.carplay-audio "$sim_ent" >/dev/null || fail "simulator $config entitlements ($sim_ent) lack carplay-audio"
done

if [ "$fails" -gt 0 ]; then echo "check-release: $fails failure(s)" >&2; exit 1; fi
echo "check-release: OK"
