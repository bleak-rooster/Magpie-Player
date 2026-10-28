# Magpie on your iPhone with TestFlight

You need: a paid Apple Developer Program membership, Xcode 27.1 at `/Applications/Xcode.app`, XcodeGen (`brew install xcodegen`), and the TestFlight app on the iPhone. Everything below is done by you: Magpie's scripts never sign in to Apple or store credentials.

Two build variants:
- **testflight** (default): no CarPlay. CarPlay audio needs Apple's approval first; until then no provisioning profile can carry the entitlement and signing would fail. The app works as usual; it just doesn't appear in the car.
- **testflight-carplay** (`--carplay`): with CarPlay. Use it once Apple has granted CarPlay audio to your team (step 12).

## Steps

1. **Sign in to Xcode.** Xcode › Settings › Accounts › `+` › Apple ID. Pick your paid team (not "Personal Team").
2. **Find your team id.** Same screen, or developer.apple.com › Account › Membership details. It is 10 capital letters and digits, e.g. `AB12CD34EF`.
3. **Register the bundle id and create the app record.** (No device needs registering for the default build: it is archived unsigned and signed once, for App Store Connect, when exported. Only `--carplay` builds sign while archiving and need one registered device: connect the iPhone, copy its Identifier (UDID) from Xcode › Window › Devices and Simulators, then developer.apple.com › Certificates, Identifiers & Profiles › Devices › `+`.) The App Store Connect form only lists bundle ids your team has registered, so a new one has to exist first. Either register it at developer.apple.com › Certificates, Identifiers & Profiles › Identifiers › `+` › App IDs (`com.bleak-rooster.magpie`), or let automatic signing register it by archiving once **without** `--upload` (`scripts/archive.sh --team AB12CD34EF`: it signs and exports an .ipa, and registers the App ID on the way). Then appstoreconnect.apple.com › Apps › `+` › New App:
   - Platform iOS. Bundle ID `com.bleak-rooster.magpie` (your own reverse-domain namespace; set in `project.yml` as `PRODUCT_BUNDLE_IDENTIFIER`). Create the record under your personal developer account (organisation: bleak-rooster).
   - Name: "Magpie" is probably taken on the App Store, and the store name must be unique even for a TestFlight-only app. Try **Magpie Player**, **Magpie for Navidrome**, or **Magpie Music**. The name on the home screen stays "Magpie" (it comes from the app, not the record).
   - SKU: anything you like, e.g. `magpie-ios-1`. Primary language English. User access: full.
4. **Archive and upload** (only after the app record exists, step 3).
   ```sh
   cd /Users/dev/Dev/navidrome_player
   scripts/archive.sh --team AB12CD34EF --build 1 --upload
   ```
   Every upload needs a higher `--build` (2, 3, …), and `--upload` refuses to run without one; `git rev-list --count HEAD` is a handy number that only goes up. The version is 0.0.1 (set in project.yml). Build numbers keep rising: build 2 is the interim network build and build 3 the 0.0.1 release. Without `--upload` the script exports `build/testflight/export/Magpie.ipa`, which you can send with the **Transporter** app. Or upload from Xcode: Product › Archive, then Organizer › Distribute App › TestFlight & App Store. The first run may ask for your Mac login password to let `codesign` use the new signing key: choose Always Allow.
   Before you upload, you can check what the build is signed with: `codesign -d --entitlements - build/testflight/Magpie.xcarchive/Products/Applications/Magpie.app`. The default build must show **no** `com.apple.developer.carplay-audio`; a `--carplay` build must show it.
5. **Wait for processing.** App Store Connect › your app › TestFlight. Usually 5 to 30 minutes; you get an email.
6. **Export compliance.** The build already says it uses no non-exempt encryption (`ITSAppUsesNonExemptEncryption` = NO: only standard HTTPS through the system), so you shouldn't be asked. If you are: "None of the algorithms mentioned above".
7. **Add yourself as an internal tester.** TestFlight › Internal Testing › `+` group (e.g. "Me") › add yourself (your App Store Connect user) › add the build. Internal testers don't need Apple's beta review.
8. **Install.** On the iPhone, open the TestFlight invitation email (or the TestFlight app) and tap Install. TestFlight builds expire after 90 days; upload a new build to keep going.
9. **First run on the phone.**
   - **Server address.** TestFlight builds are Release builds: plain `http://` works only to home-network addresses. These are fine: a single-word LAN name (`http://homeserver:4533`) and `.local` names (`http://homeserver.local:4533`). A Tailscale MagicDNS name over plain http (`http://homebox.tail1234.ts.net:4533`) **is blocked** in TestFlight builds. Use HTTPS for it instead: `tailscale serve` or `tailscale cert` give the machine a real certificate, then use `https://homebox.tail1234.ts.net`. A Tailscale IP over plain http (`http://100.x.y.z:4533`) **is blocked** too (tested on a real server, 2026-10-28: sign-in fails in Release and Debug alike before this fix). Connect now says so before trying ("This address needs HTTPS…"). What was verified to work over plain http in Release: the single-word name (`http://homeserver:4533`), for browsing and streaming. Add several addresses (single-word name first, then HTTPS); the first that answers wins.
   - **Local Network permission.** iOS asks "Magpie would like to find and connect to devices on your local network" the first time it reaches a home address. Tap Allow. If you tapped Don't Allow: Settings › Privacy & Security › Local Network › Magpie.
   - **Count plays.** On by default: what you play is recorded on your Navidrome (and ListenBrainz if connected). Switch it off in Settings while testing if you don't want test plays recorded.
10. **Updates.** Change code, run step 4 with the next `--build`, and the phone's TestFlight app offers the update.
11. **Problems signing.** "No profiles for com.bleak-rooster.magpie": the script passes `-allowProvisioningUpdates`, so Xcode creates them; make sure you're signed in (step 1) and the team id is right. "Provisioning profile doesn't include the com.apple.developer.carplay-audio entitlement": you used `--carplay` before step 12 was granted; drop it.
12. **CarPlay.** Request the CarPlay audio entitlement at developer.apple.com/contact/carplay (sign in, choose Audio, describe Magpie as a music player for your own server). Approval takes days to weeks. Once granted, check it is listed under your App ID's capabilities, then archive with `scripts/archive.sh --team AB12CD34EF --build N --upload --carplay`. Running from Xcode on your phone with CarPlay: set `MAGPIE_CARPLAY` to `YES` in the Magpie target's build settings.
13. **CarPlay without a car.** Download **Additional Tools for Xcode** (developer.apple.com/download/all), open **CarPlay Simulator**, connect the iPhone by cable, and Magpie appears once it carries the entitlement. The Xcode iOS simulator (I/O › External Displays › CarPlay) always works: simulator builds carry the entitlement.

## Free alternative (no paid membership)

Run straight from Xcode with a free "Personal Team": open `Magpie.xcodeproj`, Magpie target › Signing & Capabilities › Team: your Personal Team, pick your iPhone, Run. The bundle id may need changing (e.g. `com.yourname.magpie`). On the phone: Settings › General › VPN & Device Management › trust your developer certificate. The app stops opening after 7 days; run it from Xcode again. No CarPlay here either (personal teams can't have the entitlement; device builds sign without it by default). Debug builds also allow plain http to any address (their ATS dictionary has only `NSAllowsArbitraryLoads`).

## What is set for you

- Version 0.0.1; build number from `--build` (default 1). Team from `--team` or `MAGPIE_TEAM_ID`, never stored in the project. Automatic signing.
- iPhone: portrait only. iPad: all four orientations (App Store Connect rejects an iPad app that multitasks without them).
- Release builds allow plain http only to local-network names; no "allow arbitrary loads" (Debug builds keep it for the simulator).
- Background audio, the Local Network prompt text, launch screen, app icon (light, dark and tinted, generated by `scripts/render-app-icon.swift`).
- Privacy manifest (`App/PrivacyInfo.xcprivacy`): no tracking, no data collected by the developer, and the two "required reason" APIs Magpie uses (UserDefaults for its own settings; system uptime for the MusicBrainz rate limiter). When App Store Connect asks for App Privacy details (needed before an external or App Store release, not for internal testing), the answer is "Data Not Collected": Magpie only talks to your own servers and, if you connect them, ListenBrainz and MusicBrainz on your behalf.
- `scripts/check-release.sh` archives both variants unsigned and checks all of the above.

## Not certain

These rest on Apple rules as understood when this was written (October 2026); check them if something behaves differently.
- Which plain-http hosts the "local networking" exception covers (answered by the real-server test, 2026-10-28): single-word names are covered (sign-in, browsing and streaming verified on Release); Tailscale IPs (100.64/10) and `*.ts.net` names are **not** covered and need HTTPS. Private LAN IPs (192.168/16, 10/8, 172.16/12) and `.local` names are treated as covered by Magpie but weren't available to test. The same rule governs streaming (AVPlayer goes through App Transport Security too), so an address that can't sign in over plain http can't play either.
- The CarPlay variant may need a manual provisioning profile. Automatic signing should pick up the entitlement once it is on your App ID, but if Xcode keeps making a profile without it, create an App Store profile for `com.bleak-rooster.magpie` with CarPlay audio at developer.apple.com › Profiles, download it, and archive with `CODE_SIGN_STYLE=Manual PROVISIONING_PROFILE_SPECIFIER="<profile name>"`; the export then needs `signingStyle` `manual` and a `provisioningProfiles` map (`com.bleak-rooster.magpie` → the profile name) in its ExportOptions.plist. `scripts/archive.sh` does not do this for you.
- Upload checks change over time; the unsigned archive passes Xcode's local build checks, but App Store Connect's own validation only runs on a real upload.
- Exact Xcode menu names in Xcode 27 may differ slightly from the ones above.
