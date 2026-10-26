# Devil's advocate review — Magpie

Date: 2026-10-26 · Reviewer: devil's-advocate agent · Status: input to the overnight decision log (`docs/decisions.md`)

Reviewed: `docs/superpowers/specs/2026-10-26-serverless-architecture-design.md`, `docs/storyboard/design-language.md`, `docs/storyboard/flows.md`, `docs/decisions.md`, `docs/research/00-synthesis.md` (plus `docs/research/tubifarry.md` to check claim 2).

The plan is strong on craft: the sleeve/record metaphor, calm voice, MBID spine and pure state machine are all sound. These three concerns go after the assumptions the plan is most sure of. All three trace to one gap: **the design describes a per-song, instant, neutral experience, but the system underneath is album-granular, artist-granular, depends on polling, and relies on piracy-adjacent sources.** Wherever those two layers disagree, the design is promising something the system can't deliver.

---

## [CRITICAL] Concern #1: The App Store build is the product, and its review strategy depends on concealment

**What the plan assumes:** Keeping slskd code out of App Store binaries, calling it "Quick fetch", never naming Soulseek/P2P/YouTube, and leaving it out of App Review demo setups (spec §9) keeps the iPhone app on the right side of Guideline 5.2.3.

**Why this might be wrong:**
- App Review judges what the app *does*, not which symbols it links. The iPhone app's core loop is: search any recording in the world (ListenBrainz), tap Try, and get a real copyrighted file onto your server within minutes. Where the bytes come from makes no difference to that description.
- The "legal" tiers aren't clean either. Per `research/tubifarry.md`, the "Standard" tier that Settings recommends runs on Tubifarry's YouTube, Soulseek (`SlskdIndexer`), Streamrip/Lucida (rips from paid streaming services) and similar sources. The mailbox → Mac-helper bridge means the App Store app is how users drive the fast lane. Moving the code doesn't remove that function.
- "Absent from App Review demo setups" plus neutral naming is close to the textbook description of Guideline 2.3.1 (hidden or undocumented features). Breaking 2.3.1 is grounds for removal and can lead to developer-program termination. An unclear 5.2.3 case would usually just get a rejection.
- **Blast radius:** the Mac helper is signed with a Developer ID from the *same* developer account. If the account is terminated, the certificate is revoked and the already-distributed Mac helper stops launching on Gatekeeper-protected Macs. The one-time-purchase revenue and every platform in the roadmap go with it.

**What happens if it is:** Best case, Phase 4 (Requests & Try it) gets rejected after months of build, and the app ships as "another Navidrome player", which is the commodity tier the research says we must beat. Worst case, the app is removed after launch and the account terminated, taking the iPhone, CarPlay, Mac helper and tvOS apps down together.

**Evidence that would confirm or kill it:**
- *Kill:* an App Store build gets approved whose Review Notes **fully disclose** that Try asks the user's own Lidarr to download a release through indexers the user configured, with the demo account showing that flow working. Precedent check: look for *arr clients currently on the App Store (e.g. Ruddarr, LunaSea's history, any Lidarr client) and see how they describe "search + grab". Note that none of them present grabbing as *instant playback of any song*.
- *Confirm:* a rejection that cites 5.2.3 or 2.3.1 on a pre-Phase-4 TestFlight external-review build. Or legal advice saying the "Try any song in ~30 s" marketing is inducement, not neutral tooling.

**Change now:**
1. Delete "absent from App Review demo setups" from §9. Make full disclosure in Review Notes a stated rule in the spec.
2. Submit a **minimal Try build to external TestFlight review before Phase 4 is fully built**: Lidarr connect plus one request flow. Get Apple's answer for the cost of a sprint, not a release.
3. Move the Tubifarry recommendation out of the App Store app's Settings copy and into web/Mac-helper docs.
4. Put the Mac helper under a **separate legal entity / developer account** from the App Store apps, or ship it unsigned/open-source for users to build. That way one enforcement action can't take down both.
5. Have the design voice ("Bringing it home") describe a request to *your* server ("Asking your server for it"). That's honest, it holds up under review, and it fits the calm voice just as well.

---

## [CRITICAL] Concern #2: "Spotify-grade" holds only for the minority with an always-on Mac. The App Store buyer and every Listener get "Patient"

**What the plan assumes:** "Try it" is a fast, designed moment (Spin-up at 33⅓ rpm, "about 30 seconds"). The Listener mailbox feels instant because "the Mac helper sweeps every few seconds" (§4).

**Why this might be wrong:**
- **First release is iPhone + CarPlay** (owner decision 5), and the App Store binary has no fast lane. Without the Mac helper, the best case is Tubifarry at ~1.5–5 min. And `tubifarry.md` says a YouTube full-album grab "takes about as long as 12 sequential downloads plus random anti-bot delays", and Lidarr imports only when the whole item completes. Plain Lidarr is "10 min – hours".
- **Listener requests have no reliable processor without the Mac.** The other sweepers are a Curator's iPhone (foreground, during playback, `BGAppRefreshTask`) and an open web tab. `BGAppRefreshTask` is opportunistic: iOS schedules it based on how much that user uses the app, and it often goes hours without running. There's no push (§3). So Leo's Try waits until Sam happens to open Magpie. The flows doc already has the copy for this: "Waiting for Sam's Mac to pick it up". Without a Mac, that state could last overnight.
- **CarPlay Journey D** (one-tap Try while driving) only pays off in the Quick-fetch tier. On Standard/Patient the drive ends before the song arrives.
- The Mac helper also has to be awake. A MacBook asleep in a bag is the normal case, not an edge case, and the plan's own copy admits it.
- Combined: the experience the design language is built around (Spin-up, "about 30 s", play-on-land) happens only on **Curator-owned Mac helper + slskd + awake Mac**. That stacks three dependencies, none of which ships through the App Store.

**What happens if it is:** Most buyers' first Try turns into "a few minutes" or "a few hours". The spinning record becomes a spinner with nicer art. Reviews compare it to Spotify and score it on latency, the one axis the architecture can't win without the helper. Listeners, the people the household feature exists for, get the slowest and least predictable path.

**Evidence that would confirm or kill it:**
- *Measure:* on the dev stack plus 3–5 real owner setups, log time-to-first-play (p50/p90) per tier, and separately **time-to-pickup** for a Listener request with no Mac helper, Curator phone locked in a pocket, for 24 h. Kill condition: Listener pickup p90 < 5 min without the Mac helper.
- *Survey:* ask 20 target users in r/selfhosted / r/navidrome whether they have an always-on Mac on the same network as Lidarr/slskd. If fewer than ~40% do, the headline experience is a minority feature.

**Change now:**
1. **Design per tier, not around the best tier.** On Standard/Patient, Try should not open the spinning-wait screen at all. It should become "Ask for it → we'll put it in Finds", with no play-on-land promise. Keep Spin-up for Quick fetch only.
2. Pick a no-Mac processor now. One option: an *optional* sweeper in the Docker image you already ship for the web app. That's a deliberate, narrow exception to "no server", and it's honest. Another: drive sweeps from a Lidarr/Navidrome webhook → ntfy so the Curator phone wakes up. Prototype the second before Phase 4.
3. Setup step 5 (Speed check) should say what Listeners will experience, not just what the owner will: "Without your Mac awake, household requests wait until you open Magpie."
4. Re-scope CarPlay "Try from the car" so that on non-Quick tiers it reads as "Save for later" (adds to Finds when it lands), not "Try".

---

## [HIGH] Concern #3: Finds promises per-song, per-person fading; Lidarr gives artist-wide fates, whole albums and silent blacklisting

**What the plan assumes:** A Find is one song: a bare record with its own 7-day arc that fades by itself, and Keep slips *that* record into a sleeve. Expiry "never touches the main library".

**Why this might be wrong.** The implementation in spec §8 works at artist and album level:
- **Expiry is per-artist, not per-find:** "delete artists tagged `sample` older than N days". If Leo tries an artist's song on day 0 and Mum tries a different song by the same artist on day 6, Mum's find disappears tomorrow, after 1 day instead of 7, and her arc was wrong. Fixing that by refreshing the age instead lets Leo's find live forever.
- **One Try lands a whole release.** Tubifarry/plain Lidarr fetch "the smallest release containing the recording", which is often a 12-track album. The design never says what the 11 neighbouring tracks look like. Are they Finds? Do they count against the 25 cap, show fade arcs, or appear in search as round records that suddenly "play instantly"?
- **Keep moves the artist, not the song.** `PUT /artist/editor` with `moveFiles:true` sweeps *everyone's* Finds by that artist into the main library. Then Albums + EPs (the default) plus the Lossless profile runs, with **no approval for Listeners** and a cap that counts *items*, not gigabytes. One CarPlay Keep ("uses your default, no sheet") on a prolific artist can queue tens of GB of FLAC. Meanwhile the anti-goal says tried songs must not pollute stats or shuffle.
- **Try for an artist you already have skips Finds entirely**: it's "a normal song request into the main library". That file never fades and lands permanently, album and all, in shuffle and mixes. So the round-record-with-arc is a false promise in that branch. Nothing in the design language describes this state.
- **Expiry quietly blacklists.** `DELETE /artist?…&addImportListExclusion=true` adds the artist to Lidarr's import-list exclusions. If the owner later uses a ListenBrainz/Spotify import list or follows that artist, Lidarr will silently refuse to add them. A trial the owner never kept turns into a permanent block they can't see. That's the opposite of "nothing nags you, untouched records quietly fade."

**What happens if it is:** The design language's best idea (fade to keep, slip into the sleeve) shows the user one model while the library does something else. Users see finds vanish early, Keeps that pull in strangers' songs, disk filling from one-tap Keeps, and "missing" artists in Lidarr. These are trust-breaking bugs that only appear after weeks of household use, after launch.

**Evidence that would confirm or kill it:**
- Write these as state-machine test vectors and run them against the dev docker-compose stack before Phase 4 UI work: (a) two users trying the same artist 6 days apart; (b) a Try whose smallest release is a 12-track album; (c) Listener Keep on an artist with 30+ albums, logging the bytes queued; (d) Try for an artist already in the main library; (e) expire an artist, then add it via an import list. Kill: each scenario produces exactly the UI state the storyboard shows.

**Change now:**
1. Track expiry **per recording per user** in the mailbox/local index. An artist expires only when its *last* find expires, and the arc reflects the individual find. Drop `addImportListExclusion=true`.
2. Add a storyboard state for **"came with your find"** (neighbour tracks from the same release): visible on the album page, not in Finds, not counted against the cap. Also add a state for **"Try by an artist you have"**: square sleeve plus a "New" stamp with a Remove action, not a fading record.
3. The Keep sheet should show a **size estimate** ("about 6 GB, lossless") and default to **This album** for Listeners and CarPlay. Albums + EPs stays the default only for Curators on the phone. Add a household GB quota next to the item cap.
4. When Keep would move other people's finds, say so: "Leo's find from this artist comes along too."

---

## What I'd watch most closely

Concern #1 is the one the team is most likely to wave off ("we kept slskd out of the binary"), and it's the only one that can't be fixed after launch. Get Apple's answer on a minimal Try build before the Phase 4 investment.
