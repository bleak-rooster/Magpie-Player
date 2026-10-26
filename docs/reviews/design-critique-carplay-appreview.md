# Design critique: CarPlay and App Review, Magpie storyboard

Reviewer stance: CarPlay framework and App Store review specialist, adversarial. · 2026-10-26
Scope: `docs/storyboard/{carplay,flows,design-language}.md`, `docs/storyboard/canvas/CP-*.dc.html` (all 10 boards), `docs/research/apple-platform-architecture.md` §4 and §6, `docs/research/ios-clients.md` §4.5, and the spec `docs/superpowers/specs/2026-10-26-serverless-architecture-design.md`.
Cost: S = copy, config or rule change, under a day · M = a new state, screen or subsystem, a few days · L = architecture, flow redesign or a business decision.

Primary sources I checked today:
- **CarPlay Developer Guide, rev. 2026-10-13** (PDF, read in full). Referenced below as *CPDG p.N*. https://developer.apple.com/download/files/CarPlay-Developer-Guide.pdf
- **App Review Guidelines, last updated 2026-10-16.** https://developer.apple.com/app-store/review/guidelines/
- CarPlay API reference pages: `CPTabBarTemplate.init(templates:)`, `CPSearchTemplate`, `CPNowPlayingImageButton`, `CPNowPlayingTemplate`, `CPAssistantCellConfiguration`, `CPListTemplate`, `CPListItem`, `CPListImageRowItem`, `allowsMiniPlayer`.
- `NSAllowsLocalNetworking` reference page.

**Bottom line.** Most of the CarPlay design is buildable and the driver-safety rules are better than most shipped clients. There are four hard problems. The Search tab cannot be built as drawn. The depth budget breaks once Up Next is pushed. Two locked and not-set-up messages break a CarPlay guideline as written. "Try it → plays when ready" can't work when Magpie is in the background with nothing playing. The bigger risk is outside CarPlay: App Review is likely to read "Try any song" as Guideline 5.2.3 (downloading media from third-party sources). The plan to keep Quick fetch out of the demo also clashes with 2.3.1 and 2.5.19 (features must be accessible for review, with nothing hidden). Settle both before Phase 3 code starts.

---

## Critical

### C1. App Review is likely to see "Try it" as facilitating music downloads (Guideline 5.2.3)
- **Problem.** The feature that sets the App Store iPhone app apart works like this. Search any song, including chart hits, through ListenBrainz. Tap **Try**. About 30 seconds to a few minutes later a real file of that commercial recording plays, fetched by the user's Lidarr from whatever indexers they configured. The iPhone app does more than report what the server already holds. It **starts** the acquisition (adds the artist, triggers `ArtistSearch` / `AlbumSearch`, `ManualImport`), tracks it and plays the result. Keeping slskd code out of the binary does not change what the reviewer sees in the UI.
- **Evidence.**
  - Guideline 5.2.3: "Apps should not facilitate illegal file sharing or include the ability to save, convert, or download media from third-party sources … without explicit authorization from those sources."
  - Guideline 5.2.2: you need permission from third-party services you access.
  - Spec §1 ("Tapping a song that isn't in the library gets it playing … often within a minute"), §7 and §9.
  - `CP-TryAlert` ("Try Harbour Lights? … It plays once it's home").
  - Precedent: *arr remote-control apps are on the App Store (e.g. Ruddarr, https://apps.apple.com/app/id6476240130). Those are framed as admin companions for the user's own server, not as a player that fetches any song on demand.
- **Recommended change.**
  1. **Decide the App Store posture now** (owner decision, not engineering):
     - **(a)** Ship v1 to the App Store as a player plus discovery plus open previews, with "Request" as a plain, explicit server-admin action ("Ask your library to add this album"). The fast Try/Keep loop lives in TestFlight, the web app and the Mac helper.
     - **(b)** Ship Try in the App Store build with honest framing and accept rejection risk. If you do, prepare a fallback build with a remote flag that turns off requests for review.
  2. Whichever you choose, the App Store **description and Review Notes** must frame the feature as "manages the user's own self-hosted media server and its automation (Lidarr), the same way the server's web UI does". Never say "any song" or "free". Never show a chart artist fetching in screenshots.
  3. Build the review demo (see H6) so that Try can only fetch openly licensed releases, and mainstream songs show the calm "We'll keep looking" state.
  4. Remove "plays any song in ~30 s" marketing language from all App Store-facing copy.
- **Cost.** L (business decision plus a review-specific demo stack)

### C2. Quick fetch wording and the demo plan read as concealment (Guidelines 2.3.1(a), 2.5.19)
- **Problem.**
  - The spec keeps Quick fetch "absent from App Review demo setups" (§9).
  - The design language bans words like Soulseek and P2P.
  - The iPhone app still shows Quick fetch as a tier: in `CP-TryAlert` ("Quick fetch · about 30 seconds"), in setup step 5 "Speed check" ("Quick fetch … needs the Mac helper"), and in the wait copy ("Quick fetch needs your Mac at home").
  - So the App Store build has a user-visible feature the reviewer can't reach, backed by a companion binary Apple never reviews.
  - 2.3.1(a) requires every feature to be "described with specificity in the Notes for Review … and accessible for review".
  - 2.5.19 forbids "hidden, dormant, or undocumented features" and names account termination as the penalty. A reviewer who finds out later what Quick fetch does could treat it as deliberate evasion. That puts the whole developer account at risk, not just one build.
- **Evidence.** Spec §9 last paragraph; `flows.md` boards "5 Speed check" and "Wait — Quick fetch"; `CP-TryAlert` copy; App Review Guidelines 2.3.1(a) and 2.5.19.
- **Recommended change.**
  1. In every App Store binary, **drop tier names entirely**. Show only honest timing ("about 30 seconds", "a few minutes", "can take a few hours"). The iPhone app reads the timing from the mailbox `tier` field and never names it.
  2. Keep all Quick fetch setup, naming and status in the Mac helper and the web app. The iPhone Speed check board shows timing only.
  3. In Review Notes, state plainly: "Request speed depends on the owner's server setup; an optional companion Mac app, distributed separately, can process requests." Don't hide the companion's existence. Don't describe it in evasive terms either.
  4. Keep the "no QuickFetch symbols" build check, and add a CI string check: no "Quick fetch", "slskd" or "Soulseek" strings in the iOS bundle.
- **Cost.** S (copy) + S (CI check)

### C3. The Search tab cannot be a `CPSearchTemplate` (crashes at runtime)
- **Problem.** The template tree and `CP-Search` / `CP-SearchResults` / `CP-TryAlert` all draw `CPSearchTemplate` as the root of the 4th tab, with the tab bar visible. Apple's reference says: "**Audio apps can use List and Grid templates only**" as a tab's root template. CarPlay throws an exception for other types. `CPSearchTemplate` must be **pushed**, and it shows its own keyboard and Cancel button. The fallback in Q1 is not optional: it is the only buildable option.
- **Two more mismatches on the same boards:**
  - `CPSearchTemplate` returns a **flat array of `CPListItem`**. The template offers no section headers, no assistant cell (`CPAssistantCellConfiguration` is a `CPListTemplate` feature), and no documented "dictation button". The guide describes "a text entry field, a list of search results, and a keyboard", and the keyboard is "not available at all while driving" in many cars (*CPDG p.25*). The "car's dictation button" and "voice is always available" claims in `carplay.md` §3 are unsupported.
  - In-app voice capture is not available to audio apps. "Recording is not supported while in CarPlay" except for navigation and voice-conversational apps (*CPDG p.30*). Voice search in the car therefore means **Siri** (assistant cell plus intents), not a mic button in Magpie.
- **Evidence.** https://developer.apple.com/documentation/carplay/cptabbartemplate/init(templates:) ; https://developer.apple.com/documentation/carplay/cpsearchtemplate ; *CPDG* p.15 (template table: Search ● for audio, iOS 27+), p.25, p.26 ("Tab bar is a container for Grid, Information, List, and Point of interest"), p.30.
- **Recommended change.** Make the Search tab a `CPListTemplate` root:
  - Assistant cell at the top: "Ask Siri to play…".
  - A "Type a search" row that pushes `CPSearchTemplate`. Disable it with "Available when stopped" whenever `CPSessionConfiguration.limitedUserInterfaces` contains `.keyboard`.
  - Up to N **recent searches and recent Tries** as rows. Tapping one re-runs it and pushes a results `CPListTemplate`, so the tab stays useful while moving.
  - In `CPSearchTemplate` results, encode the grouping in `detailText` ("In your library" / "Not in library") because there are no sections.
  - Drop the dictation claim from `carplay.md` and the boards.
- **Cost.** S (doc and board change) + M (recents list, keyboard-limited state)

---

## High

### H1. The depth budget fails at Up Next, and "pop one level first" can't be built
- **Problem.**
  - The tree puts Library › Artists › Artist › Album › Now Playing at exactly 5, then says "Up Next from the deepest path pops one level first".
  - `CPInterfaceController` can only pop the top template (or pop to a template or to root). You can't remove the Album template from under Now Playing while Now Playing is showing.
  - Now Playing is also reachable at **any** depth. The system pushes the shared template when the driver taps the MiniPlayer or the Now Playing button (*CPDG p.22*, p.34). So every browse screen must leave room for NP plus Up Next: 2 levels.
  - The guide counts the root in the limit of 5 ("These include the root template", *CPDG p.15*). It doesn't say whether the tab bar and the tab's root list count as one level or two. Amperfy ships `maxTreeDepth = 4` for browsing, which suggests the conservative reading.
- **Evidence.** `carplay.md` §2 "Depth guard"; *CPDG* p.15 ("limited to a depth of 5 templates … These include the root template"), p.22 ("Only the list template may be pushed on top of the now playing template"); `ios-clients.md` §4.5.
- **Recommended change.**
  1. Rule: **deepest browse template = tab root + 2 pushes.** NP is level 4 and Up Next is level 5, counting the tab root as 1.
  2. Artists path:
     - Artist screen = `listHeader` (iOS 27 details header) with Play and Shuffle.
     - Albums shown as a `CPListImageRowItem` (card or grid elements). Tapping an album image **plays the album**; it doesn't push a tracklist.
     - "Top songs" rows follow.
     - The album tracklist is reachable only from Albums / Playlists / Home, which are 1 level shallower.
  3. Assert `interfaceController.templates.count ≤ 3` before any browse push. Verify the actual counting rule in the CarPlay Simulator (Device Hub, Xcode 27) on day 1 of Phase 3. If the tab bar counts separately, drop to tab root + 1.
- **Cost.** S (tree change) + S (assert and test)

### H2. Two state boards tell the driver to use the iPhone (CarPlay guideline 2)
- **Problem.** `CP-States` 1 says "Unlock your iPhone once to connect". `CP-States` 2 says "Set up Magpie on your iPhone". Both add "Do it when you're parked". The guideline allows you to describe the condition so people can "take action when safe". It also says alerts and messages "**must not include wording that asks people to manipulate their iPhone**". "When you're parked" doesn't make an instruction compliant. Driver-safety rule 6 in `carplay.md` §4 says the same thing, but the boards break it.
- **Evidence.** *CPDG* p.5 guideline 2; `CP-States` boards 1–2; `carplay.md` §6.
- **Recommended change.** Describe the state; don't give an instruction. Render it with `CPListTemplate.emptyViewTitleVariants` / `emptyViewSubtitleVariants`:
  - State 1: "Music is locked" / "iPhone restarted and hasn't been unlocked yet."
  - State 2: "Magpie isn't set up yet" / "Your music will appear here once it's set up."
  - Apply the same rule to every "Back when your library is in reach" style string. Those are fine because they describe a state.
- **Cost.** S

### H3. "Plays the moment it lands" can't work when Magpie is backgrounded and nothing is playing
- **Problem.**
  - Journey D and `carplay.md` §4.3 say a tried song "plays immediately only if nothing is playing", and that Try pushes "Now Playing (waiting state)".
  - With no audio playing, Magpie stops running as soon as the driver switches to Maps. iOS suspends it, so polling stops. A suspended app can't start audio when the file lands. With no server there's no APNs push to wake it either (spec §3), and `BGAppRefreshTask` gives no timing guarantee.
  - Pushing Now Playing with nothing to play leaves an empty `MPNowPlayingInfoCenter`.
  - If you activate the audio session early to "hold" Now Playing, you stop the car's FM radio. The guide says: "Only activate your audio session the moment you are ready to play audio" (*CPDG p.30*).
  - Keeping the app alive with silent audio would break Guideline 2.5.4.
- **Evidence.** `flows.md` journey D; `carplay.md` §4 rule 3 and tree ("Try it → Now Playing (waiting state)"); spec §3 ("No server ⇒ no APNs push"); *CPDG* p.30; App Review Guidelines 2.5.4.
- **Recommended change.**
  1. If nothing is playing when the driver taps "Try it", **start a real bridge right away**: library songs by the same artist, else similar artists from the library, else the Daily Jams mix. Queue the tried song as Up Next when it lands. The audio session is now legitimately active, the app keeps running, and polling continues.
  2. Never push NP until real audio starts.
  3. Show waiting progress on the Finds row (detail text "On its way · about 30 s"), not in Now Playing.
  4. This also makes Q4 moot. The action sheet shrinks to **"Try it next" / "Cancel"**.
- **Cost.** M

### H4. Now Playing artwork and the album line carry state, which conflicts with CarPlay guideline 7
- **Problem.** For a find, Now Playing uses round record art with a baked days-left arc and a colour fade. The album field becomes "Saltwater Hymns · New find · 7 days" and later "· Kept · Lossless soon". Guideline 7 says to populate templates only with the specified information types: "album artwork in the now playing screen must be used to show an album cover". The same `MPNowPlayingInfo` also feeds the Lock Screen, Apple Watch, Bluetooth AVRCP and the car's instrument cluster. A transparent-cornered round PNG and a status-stuffed album name will show up on all of them. Some head units draw transparent pixels black.
- **Evidence.** *CPDG* p.5 guideline 7; `CP-NowPlaying-Sample`; `carplay.md` §1.1 and §3.
- **Recommended change.**
  - Now Playing artwork = **the unmodified square cover**, always.
  - Album field = the real album title.
  - Show find status through the Keep button state only (see M1).
  - Keep the record, arc and fade treatment for **list** thumbnails. iOS 27 explicitly supports overlays on list images there (*CPDG p.19*). Test transparency on at least one OEM head unit.
- **Cost.** S

### H5. Account creation in-app requires account deletion in-app (Guideline 5.1.1(v))
- **Problem.** Invites "can create a new Navidrome account (via the native user API)" (spec §4; `flows.md` Invite and Listener joins). Under 5.1.1(v), an app that supports account creation must "offer account deletion within the app". No board shows removing a person or a Listener deleting their own account.
- **Evidence.** Spec §4 "Invites"; `flows.md` Household board; App Review Guidelines 5.1.1(v).
- **Recommended change.**
  - Household › person › "Remove from household" (Curator): deletes the Navidrome user, their mailbox playlist and their Keychain tokens.
  - Settings › "Delete my account" (Listener): writes a deletion request into the mailbox, processed immediately by a Curator device. Also sign out locally and wipe the device.
  - Mention both in Review Notes.
- **Cost.** M

### H6. The demo account must exercise every feature without exposing piracy (Guideline 2.1)
- **Problem.**
  - Magpie has a login, so 2.1(a) requires "demo account info (and turn on your back-end service!)", and the demo must show "full features and functionality".
  - A reviewer needs a reachable HTTPS Navidrome, a Lidarr and ListenBrainz-backed search.
  - If the demo Lidarr has real indexers, the reviewer can pull a commercial song during review, which proves C1 against you.
  - If it has none, Try never works and you hit 2.1 or 2.3.1.
  - Apple reviews on IPv6-only (NAT64) networks (2.5.5), so IPv4 literals in the server address list fail.
- **Evidence.** App Review Guidelines 2.1(a), 2.3.1(a), 2.5.5; spec §9 ("absent from App Review demo setups").
- **Recommended change.** Build a permanent hosted **review stack**:
  - Navidrome over HTTPS on a hostname (AAAA plus A records), with a CC-BY/CC0 library (Free Music Archive, Jamendo CC releases).
  - Lidarr with a private indexer you control that contains only openly licensed, MusicBrainz-tagged releases. Try then really works on those artists and shows the calm "We'll keep looking" state for everything else.
  - Pre-seeded Finds (one new, one fading) so the CarPlay Finds tab isn't empty.
  - A Listener and a Curator login in Review Notes.
  - Write Review Notes as a step-by-step script including CarPlay: "connect to CarPlay Simulator; Search tab → recent 'Harbour' → Try it next".
- **Cost.** M (plus a small hosting cost)

### H7. Siri phrases and replies promised in §5 can't be delivered as written
- **Problem.**
  - The car's voice button most often goes through legacy SiriKit. `INPlayMediaIntent` only returns response codes, with no custom spoken dialog. So "It's not in your library yet. Bringing it home now. It'll play in about 30 seconds." can't be said on that path.
  - "Try Harbour Lights by Corin Hale" has no app name and no system media verb. It won't route to Magpie.
  - "What are my new finds?" with a spoken list and a follow-up is a custom App Shortcut. App Shortcut phrases must contain the app name.
  - The assistant cell requires that "**your app must include an Intents Extension** that handles" `INPlayMediaIntent`. The research doc plans in-app handling only.
- **Evidence.** `carplay.md` §5 table; https://developer.apple.com/documentation/carplay/cpassistantcellconfiguration ; `apple-platform-architecture.md` §4.4.
- **Recommended change.**
  1. Ship an Intents Extension that resolves the media and returns `.handleInApp`. Playback runs in the main app.
  2. For a not-in-library match on the SiriKit path: start the H3 bridge and queue the Try. Return `.handleInApp` so Siri says the generic "playing" reply.
  3. Give custom dialog only on the App Intents `.audio` `playAudio` path, and verify on device that schema intents can return dialog.
  4. Rewrite phrases with the app name: "Play Harbour Lights in Magpie", "What are my new finds in Magpie".
  5. Drop "Try …" as a voice verb.
- **Cost.** M

---

## Medium

### M1. Keep button: custom glyph renders monochrome; consider the system Add button
- **Problem.** Since iOS 17, "CarPlay retints the custom now playing image buttons; you need to provide images as monocolor assets", at a maximum of 20 pt (60 px @3x). The sleeve-with-check glyph will be system-tinted, not Sheen. A filled versus outline sleeve at 20 pt is hard to tell apart at a glance. Favourite's "tinted when on" is also system-controlled, through `isSelected`.
- **Evidence.** https://developer.apple.com/documentation/carplay/cpnowplayingimagebutton ; *CPDG* p.29 asset table; `CP-NowPlaying-Sample`; Q5.
- **Change.** Answer Q5 with **`CPNowPlayingAddToLibraryButton`** for finds. Drivers already know it, and it reads as "Keep". After Keep, set `isEnabled = false` and `isSelected = true`. Use `CPNowPlayingImageButton` (SF Symbol `star` / `star.fill`) only for Favourite. Final set for a find: Keep(Add) · Shuffle · Repeat. Library tracks: Favourite · Shuffle · Repeat.
- **Cost.** S

### M2. Live updates in a visible list will make the rotary focus jump (Amperfy #647 again)
- **Problem.** The Finds tab updates its "On its way" row live (progress ring, "about 20 s"). Finds re-render daily. Home's badge row changes when a find lands. If those changes rebuild sections with `updateSections` while the list is on top, focus jumps on knob and touchpad cars, which is the exact Amperfy bug.
- **Evidence.** `ios-clients.md` §4.5 (#647/#796); `CP-ReadyToTry`.
- **Change.**
  - Update existing items in place with `setDetailText`, `setImage` or `playbackProgress`.
  - Call `updateSections` only when the template isn't on top (`templateWillAppear`), or when a row is *added* or *removed* and the list isn't focused.
  - Throttle text updates to one every 10 s or more.
- **Cost.** S

### M3. The "Couldn't spot … yet" alert is a modal interruption for a passive event
- **Problem.** `CP-States` 4 presents a `CPAlertTemplate` ("OK" / "Play similar") minutes after the driver's tap, possibly while they're in Maps or another app. That breaks the spirit of rule 5: the driver isn't "waiting" on anything visible. Alert templates are allowed for audio apps (*CPDG p.15*), but a delayed modal is a distraction risk.
- **Change.** With the H3 bridge already playing, update the Finds row text instead ("Harbourmaster · still looking") and present nothing. Keep alerts only for an immediate response to a tap (e.g. "Try isn't available while your library is out of reach").
- **Cost.** S

### M4. ATS and networking: IP literals, remote plain HTTP, NAT64
- **Problem.**
  - In iOS 17 and later, "ATS no longer allows connections to IP addresses by default". `NSAllowsLocalNetworking` re-enables IPs, unqualified names and `.local`. The research's "ATS doesn't apply to raw IP connections anyway" is out of date, though the spec's choice still works.
  - Remote `http://music.example.com` is still blocked unless you ship `NSAllowsArbitraryLoads`, which needs a justification in review.
  - Tailscale `100.x` literals work under the local-networking key. IPv4 literals break on Apple's NAT64 review network.
  - `NSLocalNetworkUsageDescription` must be present and triggered deliberately.
- **Evidence.** https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowslocalnetworking ; `apple-platform-architecture.md` §6; App Review Guidelines 2.5.5.
- **Change.**
  - Ship only `NSAllowsLocalNetworking`. Refuse remote plain HTTP with a clear "use HTTPS (Tailscale / Caddy)" message, rather than ship arbitrary loads in v1.
  - Make the address prober hostname-first.
  - Write the Local Network string in Magpie's voice: "Magpie looks for your music on your home network."
- **Cost.** S

### M5. Live Activities: plan for CarPlay, staleness and no push
- **Problem.**
  - Since iOS 26, Live Activities appear on the CarPlay Dashboard "or as a notification" (*CPDG p.11*). The "Bringing it home" activity will appear in the car whether or not you design for it. Without `.supplementalActivityFamilies([.small])`, CarPlay falls back to the compact Dynamic Island views.
  - With no APNs there are only local updates, and only while the app runs. A Patient-tier activity ("can take a few hours") will go stale, and activities end after 8 hours.
  - A Listener whose request runs on Sam's Mac gets no updates unless their phone is playing.
- **Change.**
  - Design a `.small` CarPlay and Watch layout: record glyph, title, "about 30 s".
  - Start a Live Activity only for Quick and Standard timing, and only while audio plays (which the H3 bridge guarantees in the car).
  - End it with a final state on Ready.
  - Patient tier: no Live Activity, just the Finds badge.
  - Never use a Live Activity for Now Playing.
- **Cost.** S–M

### M6. Assistant cell and phone-side notifications in CarPlay
- **Problem.** Audio apps can't post notifications in CarPlay: CarPlay notifications are supported only for communication, EV charging, parking, public safety and driving-task apps (*CPDG p.28*). The design already avoids them. Make sure engineering doesn't add the `.carPlay` authorization option or `allowInCarPlay` categories hoping for "Harbour Lights is ready" in the car. The Finds tab badge (`showsTabBadge`, "ephemeral information", *CPDG p.26*) and the Live Activity are the only passive channels.
- **Change.** Note this in `carplay.md` §4 rule 5.
- **Cost.** S

### M7. Privacy policy, privacy labels and privacy manifest
- **Problem.** "Self-hosted" doesn't mean "no third parties". The device sends search queries and IP addresses straight to ListenBrainz labs, MusicBrainz, Internet Archive, Openverse and Wikimedia (spec §6–§7). The app also calls required-reason APIs: `UserDefaults`, disk space (`volumeAvailableCapacityForImportantUsage`) and file timestamps.
- **Change.**
  - Add a privacy policy listing those endpoints.
  - In App Privacy, mark "Search history" as sent to third parties, not linked to identity.
  - Ship `PrivacyInfo.xcprivacy` with reasons for those APIs.
- **Cost.** S

### M8. Background modes: audio only, no keep-alive tricks
- **Problem.** Spec §4 has Keeper iPhones sweep mailboxes "during playback and on background refresh". That's fine. Make sure no code path plays silence or holds the session open just to keep sweeping (2.5.4). `BGProcessingTask` for expiry deletes must be described.
- **Change.** Add a code-review rule: audio session active implies a real item is playing or about to play within 1 s.
- **Cost.** S

---

## Low

- **L1. Search results artwork for artists (Q7).** `CPListItem` images are system-masked rounded squares. A "record ring" around an artist portrait at 44 pt is too subtle. Use detail text "Artist · Not in library" (already on the board) and a plain portrait. *S.*
- **L2. `playbackProgress` used as download progress.** iOS 27 list overlays are meant for playback progress (*CPDG p.19*). Using them for "On its way" is a minor misuse under guideline 7. Prefer detail text plus a static "on its way" glyph baked into the art. *S.*
- **L3. Explicit content.** Set `CPListItem.isExplicitContent` from OpenSubsonic `explicitStatus`, and honour Screen Time explicit-music restrictions for Listeners (households with kids). *S.*
- **L4. Action sheet button length.** "Add to Up Next when ready" will truncate on 800×480 and is gone anyway after H3. Keep action titles ≤ 16 characters. *S.*
- **L5. Name and trademark.** Run the musicMagpie trademark check before submission (5.2.1). In the App Store description, mention "Works with Navidrome and other Subsonic-compatible servers" once as a factual compatibility statement, which helps reviewers and avoids keyword stuffing (2.3.7). *S.*
- **L6. CarPlay entitlement request text.** Describe Magpie as "a music player for your personal music library". Don't mention requests or downloading. Apply now: the icon appears for everyone once the entitlement ships, and you "cannot selectively show or hide CarPlay" (*CPDG p.13*), so the not-set-up state (H2) is mandatory. *S.*
- **L7. 4.2.3(i) companion app.** The iPhone app must work fully without the Mac helper, and it does (falls back to Standard / Patient). Never present the Mac helper as required in iPhone UI. *S.*
- **L8. Keep while driving.** One tap starts an Albums + EPs expansion (cross-ref UX critique C2). In CarPlay, Keep should keep **this release only**. Offer discography on the phone later ("Kept from the car · choose how much"). *S.*
- **L9. Cold launch and audio session.** Don't activate `AVAudioSession` in `didConnect`. Activate on the first play only (*CPDG p.30*), or the car's FM radio stops when Magpie launches in the background. The SQLite WAL/SHM files and the App Group container shared with the Intents extension must also use `completeUntilFirstUserAuthentication`. *S.*

---

## What's buildable as drawn (verified)

| Board | Template | Verdict |
|---|---|---|
| CP-Home | `CPListTemplate` tab root + `CPListImageRowItem` (card elements, iOS 26) + rows + assistant cell | ✅ (needs an Intents Extension, H7). "New finds → switch tab" via `CPTabBarTemplate.select(_:)` (iOS 17) ✅ |
| CP-Library | `CPListTemplate` | ✅ |
| CP-Album | `CPListTemplate` with `listHeader` (iOS 27 details header), playing indicator, cloud accessory | ✅ |
| CP-Search | `CPSearchTemplate` as tab root | ❌ C3: must be pushed from a list root |
| CP-SearchResults | `CPSearchTemplate` results | ⚠️ Flat `CPListItem` list only; no sections or assistant cell; Try capsule as `accessoryImage` ✅ |
| CP-TryAlert | `CPActionSheetTemplate` (audio: iOS 17+) | ✅ Template. ⚠️ Copy (C2) and 3 → 2 actions (H3) |
| CP-NowPlaying | `CPNowPlayingTemplate.shared`, Up Next, ≤ 5 buttons, MiniPlayer (iOS 27) | ✅ Favourite tint is system-controlled (M1) |
| CP-NowPlaying-Sample | Same | ⚠️ H4 (artwork and album line), M1 (Keep glyph) |
| CP-ReadyToTry (Finds) | `CPListTemplate`, sections, disabled rows, tab badge | ✅. ⚠️ M2 (live updates), L2 |
| CP-States 1–2 | Root `CPListTemplate` with `emptyViewTitleVariants` | ✅ Template. ❌ Copy (H2) |
| CP-States 3 | Section header + `isEnabled = false` rows | ✅ |
| CP-States 4 | `CPAlertTemplate` | ✅ Template. ⚠️ M3 |

---

## Corrected CarPlay template tree

Depth counts the tab's root list as 1. Browse never goes deeper than 3, so Now Playing (4) and Up Next (5) fit from **any** screen, including when the system pushes NP from the MiniPlayer. Verify in the CarPlay Simulator whether the tab bar counts as its own level. If it does, cap browse at 2.

```
setRootTemplate:
  · not set up / before first unlock → CPListTemplate (empty view: describe the state, no instructions)   [H2]
  · otherwise → CPTabBarTemplate (4 tabs; read maximumTabCount)

CPTabBarTemplate
├─ Home      CPListTemplate (tab root, depth 1)
│   ├─ assistant cell (.playMedia, top)                                    [needs Intents Extension]
│   ├─ "Jump back in"  CPListImageRowItem (card elements, ≤ maximumImageCount)
│   │     tap image → play → push NP                                       NP 2 · Up Next 3
│   │     tap row title → CPListTemplate "Jump back in" (top-N)  depth 2 → album 3 → NP 4 · UN 5
│   ├─ Daily Jams / Weekly Exploration → play → NP                         NP 2
│   └─ New finds (n) → tabBar.select(Finds)                                (no push)
├─ Library   CPListTemplate (depth 1)
│   ├─ Playlists  → CPListTemplate (smart top-N)        2 → playlist 3 → NP 4 · UN 5
│   ├─ Albums     → CPListTemplate (Recent / A–Z, paged in place)  2 → album 3 → NP 4 · UN 5
│   ├─ Artists    → CPListTemplate (A–Z, paged in place) 2 → artist 3 → NP 4 · UN 5
│   │                artist = listHeader [Play · Shuffle]
│   │                       + CPListImageRowItem of albums (tap = play album, no push)   [H1]
│   │                       + top songs rows (tap = play)
│   ├─ Downloaded → CPListTemplate                      2 → album 3 → NP 4 · UN 5
│   └─ Finds (n)  → tabBar.select(Finds)
├─ Finds     CPListTemplate (depth 1), sections: New finds · On its way · Still deciding
│   ├─ new find / find row → play → NP (Keep = CPNowPlayingAddToLibraryButton)  NP 2 · UN 3
│   └─ on-its-way row → isEnabled = false, detail text "On its way · about 30 s"  (updated in place, M2)
└─ Search    CPListTemplate (depth 1)                                         [C3]
    ├─ assistant cell (.playMedia, top) — the voice path
    ├─ "Type a search" → push CPSearchTemplate (depth 2)
    │       disabled with "Available when stopped" while limitedUserInterfaces ∋ .keyboard
    │       results: flat [CPListItem]; library first; not-yet rows detail "Not in library", accessoryImage = Try
    │         library song → play → NP 3 · UN 4
    │         artist → CPListTemplate artist 3 → NP 4 · UN 5
    │         not-yet song → present CPActionSheetTemplate (modal, no depth)
    │               "Try it next" (default) · "Cancel"
    │               → if nothing playing: start bridge mix now, queue the Try   [H3]
    └─ Recent searches / recent Tries (≤ maximumItemCount − 2) → push results CPListTemplate (2) → as above

Modals: CPActionSheetTemplate (Try, only in direct response to a tap). CPAlertTemplate only in direct
        response to a tap (e.g. Try unavailable while out of reach). Never for background events.   [M3]
Now Playing: CPNowPlayingTemplate.shared, configured in didConnect; isUpNextButtonEnabled → queue CPListTemplate.
             Buttons: library = [Favourite(ImageButton, star) · Shuffle · Repeat]; find = [AddToLibrary(Keep) · Shuffle · Repeat].
             Artwork = unmodified square cover; album field = real album title.   [H4, M1]
allowsMiniPlayer = true. Audio session activated on first real play only.   [L9]
Passive channels in the car: Finds tab badge, Live Activity (.small family). No CarPlay notifications for audio apps.   [M5, M6]
```

---

## Suggested edits to the owner's open questions

- **Q1.** Settled by C3: the Search tab is a list root that pushes `CPSearchTemplate`.
- **Q2.** Keep the Finds tab always present (agree).
- **Q4.** Settled by H3: play after the current song, with a bridge if nothing is playing. Sheet = "Try it next" / "Cancel".
- **Q5.** Use `CPNowPlayingAddToLibraryButton` (M1).
- **Q7.** Plain portrait plus detail text (L1).
- **Q8.** Patient tier in the car: allow it, with copy "can take a few hours · it'll be in Finds", no Live Activity (M5).
