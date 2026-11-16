# Magpie on your iPhone with TestFlight

The build installs on iOS 26.0 and newer (R21, D166). You need: a paid Apple Developer Program membership, Xcode 27.1 or newer at `/Applications/Xcode.app`, XcodeGen (`brew install xcodegen`), and the TestFlight app on the iPhone. Everything below is done by you: Magpie's scripts never sign in to Apple or store credentials.

Two build variants:
- **testflight-carplay** (default since build 19): with CarPlay. Apple has granted CarPlay audio to the team (both provisioning profiles for `com.bleak-rooster.magpie` carry it, 2026-11-05). Signing while archiving needs one registered device (step 3).
- **testflight** (`--no-carplay`): no CarPlay. The app works as usual; it just doesn't appear in the car. Builds up to 18 were this variant, which is why Magpie didn't show in the car.

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
   Before you upload, you can check what the build is signed with: `codesign -d --entitlements - build/testflight/Magpie.xcarchive/Products/Applications/Magpie.app`. The default build must show `com.apple.developer.carplay-audio`; a `--no-carplay` build must not.
5. **Wait for processing.** App Store Connect › your app › TestFlight. Usually 5 to 30 minutes; you get an email.
6. **Export compliance.** The build already says it uses no non-exempt encryption (`ITSAppUsesNonExemptEncryption` = NO: only standard HTTPS through the system), so you shouldn't be asked. If you are: "None of the algorithms mentioned above".
7. **Add yourself as an internal tester.** TestFlight › Internal Testing › `+` group (e.g. "Me") › add yourself (your App Store Connect user) › add the build. Internal testers don't need Apple's beta review.
8. **Install.** On the iPhone, open the TestFlight invitation email (or the TestFlight app) and tap Install. TestFlight builds expire after 90 days; upload a new build to keep going.
9. **First run on the phone.**
   - **Server address.** TestFlight builds allow plain `http://` to any address (since 0.0.1; build 1 allowed home-network names only, which is why no http address worked on the phone: `homeserver` resolves only to its Tailscale address). These all work over plain http: a single-word name (`http://homeserver:4533`), a `.local` name (`http://homeserver.local:4533`), a private LAN IP (`http://192.168.0.77:4533`), a Tailscale IP (`http://100.64.10.20:4533`) and a Tailscale MagicDNS name (`http://homebox.tail1234.ts.net:4533`). Magpie asks before it sends your password (or the Lidarr API key) unencrypted to an address outside home or Tailscale ("This address isn't encrypted."), remembers your answer for that address, and marks it "Not encrypted" in Settings. Home and Tailscale addresses don't ask: loopback, 10/8, 172.16/12, 192.168/16, 169.254/16, 100.64/10, IPv6 unique-local and link-local, single-word names, `.local` and `*.ts.net`. This is judged by how the address is written, not by what it resolves to: a public name that points at your home server still asks once. Add several addresses (single-word name first); the first that answers wins. Tailscale must be on for the Tailscale forms and, on your setup, for `homeserver`.
   - **Local Network permission.** iOS asks "Magpie would like to find and connect to devices on your local network" on Magpie's first launch, before you sign in (since 0.0.1; build 1 only asked on reaching a home address, which never happened with `homeserver`, so Magpie never appeared in the list). Tap Allow. From then on Magpie is listed under Settings › Privacy & Security › Local Network, where you can turn it on or off. If you tapped Don't Allow and sign in to a home address, Connect says "Magpie needs local network access to reach your server…" with **Open Settings** (straight to Magpie's page in Settings). Connect and Settings › Servers also offer **Allow local network access** until it is on; iOS only shows its prompt once, so after that use Settings. Other failures are named step by step: a name this iPhone can't find (on your setup, `homeserver` with Tailscale off), an address that didn't answer in time, or `localhost` (the iPhone itself). In the car, an unreachable library says "Local network access is off for Magpie", or "Open Magpie on your iPhone once to allow local network access" if Magpie was first opened from the car.
     To confirm the sequence (Mac Console app, your iPhone selected, filter subsystem `com.bleak-rooster.magpie`, category `localnetwork`): on first launch you should see `browser: ready`, and `event: browserWaitingPolicyDenied` while the prompt is up (iOS may not report it); after Allow, `browse results: …, own service: true` then `asked: granted`; after Don't Allow, nothing more until `event: timeout` then `asked: denied` (about 30 s). Once `asked:` appears, nothing more is logged for that ask (no late timeout). While access is off, each time Magpie comes to the front it re-checks silently (the same lines, without a prompt); after you turn it on in Settings and switch back to Magpie you should see `own service: true` and `asked: granted`, and the Local Network message goes away. `asked: unknown` means the ask couldn't decide (no Wi-Fi, say); the button and the next sign-in ask again. Signing in to a LAN address with access off logs `connection held back: true`. The log carries states only, never addresses.
   - **Count plays.** On by default: what you play is recorded on your Navidrome (and ListenBrainz if connected). Switch it off in Settings while testing if you don't want test plays recorded.
   - **AirPlay and Bluetooth** (R21, D167–D169; the simulator can't try real outputs, so check these on the phone). In Now Playing tap the output button between the moon and the queue ("Play on…"): pick Bluetooth headphones or an AirPlay speaker, and the line under the scrubber says "Playing on <name>". Turn the headphones off or walk out of range: the song pauses and stays paused. The headphones' and the car's play, pause, next and previous buttons work, and the AirPlay speaker or car display shows the song, its cover and its time. CarPlay works as before.
10. **Updates.** Change code, run step 4 with the next `--build`, and the phone's TestFlight app offers the update.
11. **Problems signing.** "No profiles for com.bleak-rooster.magpie": the script passes `-allowProvisioningUpdates`, so Xcode creates them; make sure you're signed in (step 1) and the team id is right. "Provisioning profile doesn't include the com.apple.developer.carplay-audio entitlement": you used `--carplay` before step 12 was granted; drop it.
12. **CarPlay.** Request the CarPlay audio entitlement at developer.apple.com/contact/carplay (sign in, choose Audio, describe Magpie as a music player for your own server). Approval takes days to weeks. Granted (2026-11-05): `scripts/archive.sh --team AB12CD34EF --build N --upload` now carries it by default, and `MAGPIE_CARPLAY` is `YES` in `project.yml`, so runs from Xcode on your phone have CarPlay too. If CarPlay is ever revoked, archive with `--no-carplay`.
13. **CarPlay without a car.** Download **Additional Tools for Xcode** (developer.apple.com/download/all), open **CarPlay Simulator**, connect the iPhone by cable, and Magpie appears once it carries the entitlement. The Xcode iOS simulator (I/O › External Displays › CarPlay) always works: simulator builds carry the entitlement.

## Build 30: what to try

Round 28: your two items, music on this phone offline and the artist in Search.

**What's new**
- **Offline mode** is a switch at the top of Settings. On, only music on this phone plays and Magpie sends nothing at all; it stays on until you turn it off (signing in turns it off too).
- **Offline by itself.** When your library hasn't answered for 30 seconds (at once with no connection at all), Magpie switches to the music on this phone, keeps checking in the background while it can, and switches back by itself. **Go offline automatically** in Settings › Downloads & Storage turns this off.
- **Everything downloaded opens offline.** Library and Home keep their rows, each showing only what's on the phone. Albums, artists, playlists and flows open with only their downloaded songs and say "2 of 12 songs on this phone". Covers and lyrics come with every download.
- **Download a flow** from its page; it keeps in step with the flow while you're online.
- **The car** goes back to its first lists when you go offline and shows only what's on this iPhone.
- **Search names the artist** under every song ("Song · artist") and album ("Album · artist").

**What to test**
1. **The switch.** Settings › Offline mode on: the line under it says "Only music on this phone plays", and Home, Library, Search and Downloads say "Offline mode is on". Tap **Go online**: it says "Trying…", then you're back.
2. **No connection.** Turn on aeroplane mode: within a couple of seconds the notice says "No connection. Showing music on this phone." Turn it off: Magpie comes back by itself.
3. **Your library out of reach.** Away from home without Tailscale (or with the server stopped), tap something: after about 30 seconds the notice says "Your library is out of reach…". **Try again** says "Still out of reach" if it still can't.
4. **An album with one song downloaded.** Download one song of an album, open the album once online, then go offline: it shows just that song and "1 of N songs on this phone".
5. **A whole downloaded album, an artist from Library › Artists, a compilation's album artist, a playlist** (yours and someone else's, with their name): each opens offline with only what's downloaded.
6. **Library and Home offline.** Playlists, Artists, Albums, Songs, Genres, Discover and Downloads stay, each with only what's on the phone; Finds, Requests, Trending and Recommended go. With **Keep favourites downloaded** on, Favourites stays too.
7. **Flows.** Open a flow, tap **Download**, then go offline: it's in Library › Discover and Home's Your flows and opens with its songs. Online again after the flow refreshes, the new songs download.
8. **The queue offline.** Queue an album you haven't downloaded behind one you have, then go offline: the missing songs are dimmed, say "Not on this phone" and are skipped.
9. **Lyrics.** Open lyrics for a downloaded song online, then offline: they're still there.
10. **The car.** Open a server album in the car, turn on Offline mode: the car goes back to its first lists and Now Playing stays. Car Home says "Offline · music on this iPhone". A partly downloaded album's Play row says "<n> of <m> songs on this iPhone". Turn Offline mode off: the car stays where it is.
11. **A tunnel.** Play a streamed album on a drive through a tunnel: after a few quiet seconds the next downloaded song plays (or it waits with "You're offline"), and the car's lists stay put for 15 seconds.
12. **Search.** Search a song and an album: the artist shows under each, even at the largest text size. Turn on Offline mode and search again: only downloads are listed.

**Known gaps**
- In a tunnel a stream goes quiet for up to 6 s before the next song on the phone plays; with no signal, the car's server lists stay up to 15 s before going back to the first lists.
- When a song that was streaming switches to its downloaded file offline, there may be a short gap in the sound.
- Search no longer lists recently played songs offline (only downloads), by your answer to question 2.
- Pages you hadn't opened online since this build look as they did before (no "n of m"), until you open them online once.
- Magpie can only check for your library while iOS lets it run: while it plays, while the car is connected or while it's open.

## Build 29: what to try

Round 27. The numbers follow your list of 17.

1. **Play top songs.** Open an artist and tap **Play top songs** under Top songs (or Popular). Up to fifteen of their songs you have play in order; open the queue and shuffle them.
2. **Discover opens at once.** Open Library › Discover, close Magpie, open it again: the flows and playlists are there straight away and change in place, without a jump, if anything is new.
3. **A flow's page opens quickly.** Open a big flow: its songs show at once and your library's copies fill in row by row. Open it again later: it should be instant.
4. **Artist rows open their page.** In a flow's "Artists in this playlist", tap an artist you have: their library page opens inside the list (Done takes you back). Tap one you don't have: their outside page opens. Open an album from there too. Offline, the rows don't open.
5. **Add.** The button in that list says **Add**, on one line, even at the largest text size (where it moves under the name).
6. **Smaller album covers.** Library › Albums: tap the grid button at the top for three across, again for two. Settings › Home & Library › Album covers sets it for every album grid.
7. **Missing albums** (Settings › Lidarr › Missing albums, with "Allow Magpie to change your library" on). Tap **Search for missing albums now** and check Lidarr › System › Tasks (or Activity). Set **Search automatically** to Every day and open Magpie again the next day: "Last asked" should move. **Clear all downloads and search again** on a queue with a stuck download: watch "Clearing downloads: i of n", then the outcome. This searches for real and can bring in a lot of music.
8. **Flows by last played in the car.** Play a flow in the car (or on the phone), go back to the car's Home tab: it comes first in the Discover shelf.
9. **Flows with your playlists in the car.** Settings › CarPlay › Flows with your playlists, then open the car's Playlists: your flows are mixed in A to Z.
10. **The error goes with its song.** If a song fails and shows an error in Now Playing, skip: the next song starts clean.
11. **Converted songs don't skip.** On mobile data with a converted quality, play a long album on a drive. A dropped signal should say "Connection dropped. Picking up where it left off…" and carry on from the same place, not jump to the start or to the original file. Seeking in a converted song should land where you dragged.
12. **Your flows on Home.** Settings › Home & Library › Your flows on Home: Order (Last played or A to Z) and Show everyone's flows and playlists. Play a flow and go back to Home: it comes first. With everyone's on, another person's flow has their name under it.
13. **Song counts in the flow editor.** Create or edit a flow: each kind of song has its own number (tick it for 10, then Fewer and More; hold to keep stepping, up to 100 each), and "N songs in all" adds them up. Edit a flow made in Aurral: its counts should match what Aurral's editor shows.
14. **Lyrics from your server's plugin.** Play a song with no lyrics, then open Lyrics a minute later: if nd-lyrics found them, they're there (it needs `nd-lyrics` in Navidrome's `LyricsPriority`, see the RUNBOOK).
15. **Find lyrics online.** Settings › Playback › Lyrics › Find lyrics online (off by default). Open Lyrics for a song your library lacks: the footer says "Lyrics found online".
16. **Trending plays your chart flow's songs in full.** Open a Trending chart you made a chart flow from: the songs the flow holds play in full, not as previews, and **Play** beside Play previews plays them in order. A song still downloading says "On its way". The flow control says "Keeps up with the chart once a day": open the chart again the next day after it changes, and the flow follows it. A new chart flow starts at the whole chart.
17. **Automix.** In Now Playing's ⋯ menu choose **Automix…**, pick a length and a variety, and Start: the song plays on and the queue fills with songs like it from your library. Try it from an artist page's **Automix** button too, and try each variety.

## Free alternative (no paid membership)

Run straight from Xcode with a free "Personal Team": open `Magpie.xcodeproj`, Magpie target › Signing & Capabilities › Team: your Personal Team, pick your iPhone, Run. The bundle id may need changing (e.g. `com.yourname.magpie`). On the phone: Settings › General › VPN & Device Management › trust your developer certificate. The app stops opening after 7 days; run it from Xcode again. No CarPlay here either (personal teams can't have the entitlement; device builds sign without it by default). Debug builds allow plain http to any address too (every build's ATS dictionary has only `NSAllowsArbitraryLoads`).

## What is set for you

- Version 0.0.1; build number from `--build` (default 1). Team from `--team` or `MAGPIE_TEAM_ID`, never stored in the project. Automatic signing.
- iPhone: portrait only. iPad: all four orientations (App Store Connect rejects an iPad app that multitasks without them).
- Release and Debug builds allow plain http to any address: App Transport Security has `NSAllowsArbitraryLoads` and nothing else (no `NSAllowsLocalNetworking`, which would make iOS ignore it). The control is in the app: Magpie asks before it sends a password or API key unencrypted to an address outside home or Tailscale (step 9).
- App Store review (not TestFlight internal testing) asks why `NSAllowsArbitraryLoads` is set. The justification: "user-supplied self-hosted media server addresses".
- Background audio, the Local Network prompt text, launch screen, app icon (light, dark and tinted, generated by `scripts/render-app-icon.swift`).
- Privacy manifest (`App/PrivacyInfo.xcprivacy`): no tracking, no data collected by the developer, and the two "required reason" APIs Magpie uses (UserDefaults for its own settings; system uptime for the MusicBrainz rate limiter). When App Store Connect asks for App Privacy details (needed before an external or App Store release, not for internal testing), the answer is "Data Not Collected": Magpie only talks to your own servers and, if you connect them, ListenBrainz and MusicBrainz on your behalf.
- `scripts/check-release.sh` archives both variants unsigned and checks all of the above.

## Not certain

These rest on Apple rules as understood when this was written (October 2026); check them if something behaves differently.
- Plain http on the phone (owner device report, 2026-10-28): build 1 used the "local networking" exception, and no http address worked because `homeserver` resolves only to its Tailscale address (100.64/10), which that exception doesn't cover. With arbitrary loads every form worked in the simulator (ATS spike, 2026-10-28), but a private LAN IP and `.local` haven't yet been tried on the phone. Streaming follows the same rule (AVPlayer goes through App Transport Security too). The Local Network permission is separate from this: if it is off, home addresses fail even though ATS allows them.
- The CarPlay variant may need a manual provisioning profile. Automatic signing should pick up the entitlement once it is on your App ID, but if Xcode keeps making a profile without it, create an App Store profile for `com.bleak-rooster.magpie` with CarPlay audio at developer.apple.com › Profiles, download it, and archive with `CODE_SIGN_STYLE=Manual PROVISIONING_PROFILE_SPECIFIER="<profile name>"`; the export then needs `signingStyle` `manual` and a `provisioningProfiles` map (`com.bleak-rooster.magpie` → the profile name) in its ExportOptions.plist. `scripts/archive.sh` does not do this for you.
- Upload checks change over time; the unsigned archive passes Xcode's local build checks, but App Store Connect's own validation only runs on a real upload.
- Exact Xcode menu names in Xcode 27 may differ slightly from the ones above.
