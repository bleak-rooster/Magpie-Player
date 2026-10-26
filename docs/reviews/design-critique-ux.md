# Design critique: UX, Magpie storyboard

Reviewer stance: senior iOS UX lead, adversarial. · 2026-10-26
Scope: spec (`docs/superpowers/specs/2026-10-26-serverless-architecture-design.md`), `docs/storyboard/{design-language,flows,carplay}.md`, `docs/decisions.md`, and every screen in `docs/storyboard/canvas/*.dc.html`.
Personas: **Sam** (owner, technical, Curator) and **Leo / Mum** (household Listeners, non-technical).
Cost: S = copy or rule change, under a day · M = a new state or screen, a few days · L = architecture or a flow redesign.

The storyboard is coherent and well-voiced. The problems below come from the gap between what the UI promises and what a serverless, album-granular, sometimes-asleep backend can deliver, and from a metaphor that does more work than it can hold.

---

## Critical

### C1. The owner can't hear a song until setup's six or seven steps are done, and step 3 sends them off the phone
- **Problem.** After Connect (step 1), Magpie already has 12,480 playable songs. The flow still forces Sam through Requests, the Finds shelf, Speed check, Household rules and Invite before Home. Step 3 tells him to "make a folder called samples" on the server computer, then waits on "Not found yet… Check again". That's a dead end on a phone at 11 pm. The docs also disagree about the length: `flows.md` §3A says 7 steps, the mockups say "Step 1 of 6", and decision 9 recommends "Essentials now, rest later", which no screen implements.
- **Evidence.** `Onb-Connect` ("Found Sam's music · 12,480 songs" and then only "Continue"), `Onb-Samples`, `Onb-Lidarr`, `flows.md` journey A, Decisions #9.
- **Who it hurts.** Sam on first run (abandonment risk at the highest-intent moment), and App Review demo accounts.
- **Change.**
  1. On `Onb-Connect` success, the primary button becomes **"Start listening"** and the secondary becomes "Set up requests". Time to first music is then a single screen.
  2. Move Requests, Finds shelf, Speed check, House rules and Invite into a dismissible **"Finish setting up Magpie" card** at the top of Home. It shows a 4-item checklist with progress, and each item opens the existing screen as a sheet.
  3. Treat the samples-folder step as asynchronous. Show "We'll finish this when the folder appears", recheck in the background, and until then let Try fall back to a normal request (the spec already allows this).
  4. Fix the step count everywhere.
- **Cost.** M

### C2. "Keep this song" quietly downloads six releases, and there are six options on the sheet
- **Problem.** Per spec §8, Keep moves the artist and expands the discography to the default **Albums + EPs**. A user who taps Keep on one song they liked gets "6 releases on the way" (`Keep-Done`). That's a large, surprising disk and bandwidth cost, triggered by an action that sounds like "save this one". It's worse in three places:
  - CarPlay: Keep uses the default with no sheet (`carplay.md` §4.2), so one tap while driving starts 6 releases.
  - Listeners: they can pick "Everything, including singles · 13 releases" with no approval (decision 11).
  - The sheet itself: six radio options that mix two independent axes. One is *backfill* (song / album / albums / albums+EPs / everything). The other is *follow* ("Only future releases"), which is a subscription, not a quantity.
- **Evidence.** `Keep-Sheet` (6 options, default Albums + EPs), `Keep-Done` ("Albums + EPs · 6 releases on the way"), `Onb-Household` (same six options), `CP-NowPlaying-Sample`, spec §8, Decisions #15.
- **Who it hurts.** Everyone. Sam's disk takes the hit, and Listeners get a request far larger than they meant.
- **Change.**
  1. **Keep from a find = keep this song's release only** (single, EP or album: whatever was fetched). No sheet. One tap, morph, done. CarPlay and Siri do exactly this.
  2. After Keep, the `Keep-Done` screen offers a separate, optional **"Want more from Corin Hale?"** with three choices: **This album · Albums + EPs (recommended) · More options…**. "More options…" discloses All albums and Everything. Show a size estimate on each ("about 1.4 GB").
  3. Split out **"Follow — new releases come in automatically"** as a toggle on that screen and on the Artist page. It is not a discography choice.
  4. Household rule (Curator setting): **"Listeners can bring in: this release only / up to Albums + EPs"**, defaulting to Albums + EPs, with the larger options hidden for Listeners.
  5. Rename the household default to "When someone asks for more from an artist", not "When someone keeps a song".
- **Cost.** M

### C3. The UI promises notifications and Live Activities that a serverless app can't reliably deliver
- **Problem.** The architecture has no APNs (spec §3: "No server ⇒ no APNs push"). Live Activities can only update while the app process is alive. The storyboard nevertheless promises:
  - "You can leave — we'll tell you when it's ready. Shown on your Lock Screen as a Live Activity" (`Try-Wait-Standard`)
  - "Tell me when it's here · A quiet notification, even if the app is closed" (`Try-Wait-Slow`, Patient tier, *hours*)
  - "We'll let you know the moment it's ready" (`Listener-Request`)

  If music isn't playing, iOS suspends the app within seconds. The Live Activity then freezes at "about 3 min", and the "ready" notification arrives whenever `BGAppRefreshTask` happens to run, which may be hours later or never. The first broken promise teaches users to stop trusting every estimate in the app.
- **Evidence.** `Try-Wait-Standard`, `Try-Wait-Slow`, `Sys-LiveActivity`, `Sys-Lock`, `Listener-Request`, spec §3 and §12.
- **Who it hurts.** Everyone on the Standard or Patient tier. Listeners worst, because their path also waits on a Curator device.
- **Change.**
  1. Promise only what the current state guarantees. With audio playing, the app is alive, so a Live Activity and notification are fine. With nothing playing, the copy says **"It'll be waiting in New finds"** and makes no notification promise.
  2. Start the Live Activity only while background audio keeps the process alive. End it with "Still on its way — open Magpie to check" before suspension, rather than letting it go stale. Set `staleDate` to the estimate plus a margin.
  3. Make the optional ntfy (or other push) integration a real setup item ("Get told when songs arrive, even when Magpie is closed") and gate the "Tell me when it's here" toggle on it.
  4. Add a contract test: no screen copy may contain "we'll tell you" or "notification" unless the delivery path is in place.
- **Cost.** M

### C4. Listeners will lose the library the first time they leave the house
- **Problem.** The Away address in the mockup is a Tailscale hostname (`music.tail0abc.ts.net`, `Onb-Connect`). An invited Listener's phone can't reach it unless they install Tailscale and join or accept Sam's tailnet. The join flow (`Join-Scan` → `Join-Ready`) says "12,480 songs, at home and away" and never checks Away reachability. Leo's first experience outside Wi-Fi will be "Your library is out of reach", which he can't fix and won't understand.
- **Evidence.** `Onb-Connect`, `Join-Ready`, `Offline`, flows "Listener ready: Confirms Home and Away addresses".
- **Who it hurts.** Every non-technical Listener, and Sam as household tech support.
- **Change.**
  1. At invite time (`Onb-Invite`), classify each Away address: public HTTPS, tailnet or LAN-only. For a tailnet address, show Sam: **"Leo will need Tailscale to listen away from home. Include setup steps in the invite?"**
  2. Add a `Join-Ready` sub-step that actually probes Away over cellular, or with Wi-Fi bypassed via `NWPathMonitor` / `requiredInterfaceType`. On failure, show either "Away from home: needs one more app (2 min)" with a guided Tailscale deep link, or an honest "At home only for now — Sam can change this". Replace "at home and away" with what was verified.
  3. In `Offline`, show Listeners a one-line reason and a single action: "Away access isn't set up on this phone · Set it up".
- **Cost.** M

---

## High

### H1. Six different rules for what happens when a find lands while music is playing
- **Problem.** The landing behaviour is specified inconsistently:
  - Decision 17 / flows: "slot in next".
  - Spec §7: "lands in a Ready to try shelf instead of interrupting".
  - `Try-Wait-Fast`: toggle "Play as soon as it's ready", on by default ("It starts the moment it lands").
  - `carplay.md` rule 3: cut in with a crossfade, open as Q4.
  - `Sys-LiveActivity`: "Plays now, or waits in New finds".
  - `Sys-Lock`: "Play now / Later".
  - `Playlist`: "Try the 6 you don't have — they'll join the queue as they arrive", which means arrival order, so the playlist order gets scrambled.
- **Evidence.** The files above, plus `NP-Queue` ("Harbour Lights · new find · added to Up Next").
- **Who it hurts.** Everyone. Engineers will implement one rule and the copy will contradict it on three screens.
- **Change.** Adopt one rule and delete the toggle.
  - (a) **The user is on the wait screen or the Try sheet and nothing else is playing:** play immediately.
  - (b) **Something is playing:** insert as **Play Next** (never cut in, phone or car), and show a bottom-accessory banner "Harbour Lights is next" with **Play now**.
  - (c) **Batch Try from a playlist or mix:** each arrival takes its *original playlist position* if the playhead hasn't passed it. Otherwise it goes to the end of the playlist context, never to Play Next.
  - Write this into `flows.md` once and reference it from `carplay.md`. Q4 becomes "Try it next / Cancel".
- **Cost.** S (rule and copy), M (ordered batch insertion)

### H2. Round vs square is overloaded and not learnable without a legend
- **Problem.** The metaphor needs a banner to explain itself: "Round records aren't in your library yet. Tap one to hear it. Squares are yours." (`Explore`). On top of that, round means at least four different things:
  1. Not in the library (`Search-Results`).
  2. A find, which *is* on the server and plays instantly (`Try-Shelf`, `Home` "Analog Summer · 5 days left").
  3. Something being fetched (`Home` "Red Room Sessions · Looking").
  4. **Every artist**, because iOS convention makes artist portraits circular. Owned artists are "plain circles" and missing ones sit in a "record ring" (`carplay.md` Q7). At 44 pt in a car that difference is invisible.

  The Classic Character draws not-yet items as dimmed squares, so the core state language changes with a cosmetic setting.
- **Evidence.** `Explore`, `Search-Results` (Artists row), `Artist` (Similar artists), `Home`, `CP-SearchResults`, `design-language.md` §2.
- **Who it hurts.** Listeners and new users. Mum will never decode "grooves vs no grooves".
- **Change.**
  1. Shape is a *secondary* cue. The primary cue is always text plus an affordance: every not-yet row carries the **Try** capsule (songs) or a "Not in your library" caption (albums, artists). Most rows already do this; make it a lint rule for every row type.
  2. Artists: keep the iOS circle for everyone and add a small "Not in library" caption, with no record ring.
  3. Finds: square sleeve plus a days-left badge, not a record. A find plays like library music, so it should look like library music. This also removes the odd moment when a "kept" find morphs into a square on Keep-Done while finds elsewhere stay round.
  4. Keep the record metaphor for *not-yet albums and songs only*, in every Character, Classic included. The Character dial must never change meaning.
  5. Remove the Explore legend banner. If you need a legend, the design is not doing its job. A one-time coach mark on the first Try is enough.
- **Cost.** M

### H3. Search ranking breaks the stated rule "library always outranks"
- **Problem.** For the query "harbour", the **Top result is Corin Hale**, a not-yet artist whose name doesn't contain the query (`Search-Results`). Songs interleave owned and not-yet rows (Harbourmaster ✓, Harbour Lights Try, Harbour Bells Try plus an inline CC preview, Harbour Wall Try), so a user who wants to *play something they own* has to scan past records. The inline "Preview · CC BY · free to play" row contradicts Decision 14 (licence in the info sheet only). Nothing in the storyboard covers ListenBrainz returning five recordings of the same song (album, single, live, remaster).
- **Evidence.** `Search-Results`, spec §6, Decisions #14.
- **Who it hurts.** Everyone, every day. Search is the most-used surface in the app.
- **Change.**
  1. Rank as follows: exact library match > fuzzy library match > exact not-yet match > fuzzy not-yet match. Top result may be a not-yet item **only** when there is no library match above a score threshold.
  2. Within Songs, show library rows first and then a sub-header **"Not in your library yet"** for the rest. One list, two bands, with no interleaving.
  3. Collapse not-yet recordings to one row per work, chosen by the earliest official release-group, with an "Other versions (4)" disclosure on the Try sheet.
  4. Remove the licence label from the row. Keep the play glyph and put licence details in the sheet.
  5. Make the "In my library" chip sticky per session (the CarPlay search also lists library results first).
- **Cost.** M

### H4. No terminal failure and no way to say "that's the wrong song"
- **Problem.** Every failure becomes "we'll keep looking" (`Activity`: "checking again tonight", `Try-Wait-Slow`, `CP-States` alert). There is no end state, so zombie requests sit in Activity for weeks and count against the cap. Lidarr is album-granular and Quick fetch picks a peer file, so wrong versions are a near-certainty: a live take, a remix, a mislabelled or truncated file. The design has no report path, and the user's only option is "Not for me", which is also how they reject music they dislike.
- **Evidence.** `Activity` ("Needs attention… Stop looking"), `Try-Ready`, `NP-Sample`, `States-Gallery`, spec §10 (`failed` exists in the state machine but no screen shows it).
- **Who it hurts.** Everyone. Owners pay twice in disk and time.
- **Change.**
  1. Bound retries by tier: Quick or Standard → 24 h, Patient → 7 days. Then show the terminal state **"Couldn't find Paper Moon (Live). Removed from your list."** with **Ask again**. The request leaves Activity after it has been seen once.
  2. Add a **"Not the right song?"** item to the find's Now Playing ⋯ menu and to the Finds row swipe. It deletes the file and retries the next candidate (next peer or next release), keeping the same Live Activity.
  3. Treat duration mismatches over 10 s against MusicBrainz as an automatic "wrong file" retry before the user hears anything.
  4. Keep the meaning of "Not for me" to "I don't like it". It removes the find now, with a 5 s Undo toast.
- **Cost.** M

### H5. Two caps with clashing numbers and copy, and batch Try burns through them
- **Problem.** The UI shows four limits that read as the same thing:
  - "Finds per person · 10 songs" and "Finds storage 10 GB" (`Household`)
  - "You have 10 finds — keep or clear one" (`States-Gallery`)
  - "You have 25 on the go" (`flows.md`)
  - "Open requests · 25" (`Onb-Household`, Decision 11)

  On the `Playlist`, "Try the 6 you don't have" spends 6 of 10 finds in one tap with no warning. Users can't predict when Try will refuse.
- **Evidence.** The files above.
- **Who it hurts.** Listeners first. They hit the cap with no idea why.
- **Change.** Keep **one user-facing limit: Finds (default 15)**. In-flight tries count toward it. Keep requests (non-find) are limited only by the household disk rule and never shown as a count. Batch Try shows the remaining count before committing ("Try 6 · you have 9 of 15 left"). The cap sheet offers **"Clear 3 oldest finds and try"** as its single action.
- **Cost.** S

### H6. Finds expiry is anxious and contradictory, and it punishes travel
- **Problem.**
  - The design says "Nothing nags you… day 6, nearly grey, no reminder" (`flows.md` E). `Sys-Notifications` ships "Copper Wire leaves in 2 days — keep it?".
  - Artwork fading toward grey shows up on Now Playing and the Lock screen too. A song you are enjoying looks broken or disabled, and grey art reads as "unavailable" in iOS.
  - Finds aren't downloadable, so a week away from Home or Away reach means finds expire unheard.
  - There is no middle option between Keep (permanent, and as specified, large) and losing it.
- **Evidence.** `Try-Shelf`, `NP-Sample` ("Fades in 7 days"), `Sys-Notifications`, `Offline`, `design-language.md` §3.4.
- **Who it hurts.** Everyone. The fade is aimed at reducing guilt but produces anxiety, which is the opposite.
- **Change.**
  1. Fade *only* on the Finds shelf and its widgets. Now Playing, the Lock screen and CarPlay Now Playing show full colour plus a text badge ("New find · 5 days").
  2. Send exactly one notification: a daily batched digest 24 h before expiry ("2 finds leave tomorrow"), only for finds played at least once. Make it a single setting.
  3. Pause the clock on days the library was out of reach, and never expire a find that has never been played.
  4. Add **"Keep for 7 more days"** in the find's ⋯ menu and in the Finds row swipe. One extension only.
- **Cost.** S–M

### H7. A Listener's Try depends on Sam's devices being awake, and the UI hides that until it's too late
- **Problem.** Listeners write to a mailbox. If Sam has no Mac helper, requests run only while Sam's iPhone has Magpie open. The Listener learns this after tapping Try ("Nobody's home to bring this in yet", `Listener-Request`; "No Curator awake", `States-Gallery`). `Household` lists "Sam's iPhone · Helps while Magpie is open", which, for a household without a Mac, means Mum's Try can take a day.
- **Evidence.** `Listener-Request`, `Household`, `States-Gallery`, spec §4.
- **Who it hurts.** Listeners in households without the Mac helper, which is probably most households at launch.
- **Change.**
  1. Expose household processor status to Listener clients, read from a heartbeat field the processors write into the mailbox JSON.
  2. The Try sheet then shows the *real* estimate before commit, for example "Sam's Mac is asleep · usually by this evening". Change the button to **"Ask for it"** when the estimate is over an hour, so "Try" is never promised when it can't happen.
  3. In owner setup and `Household`, if no always-on processor exists, warn Sam once: "Without the Mac helper, Leo's and Mum's songs only arrive while you have Magpie open."
- **Cost.** M

---

## Medium

### M1. "Keep" is used for things nobody has heard
- **Problem.** "Keep this album" (`Search-Album-NotYet`), "Keep the artist" (`Search-Artist-NotYet`) and "Keep the album" (`Try-Sheet`) apply to music the user doesn't have. You can't keep what you never had. This blurs the one moment where Keep means something (a find you liked).
- **Change.** Use **Keep** only on finds. On not-yet albums and artists, the primary action is **"Add to library"**, with "Usually ready in a few minutes" under it. Decision 2's ★Keep stays for its proper object.
- **Cost.** S

### M2. Too many nouns for one concept, and "Sample" misleads
- **Problem.** The storyboard uses Try, Find, New finds, Still deciding, Sample (stamp), Preview, Request, Requests, Activity, Not yet, bare record and Bringing it home. "Sample" on the hallmark (`Try-Ready`, `NP-Sample`) reads as a 30-second clip, and users will think the song is truncated. `Library` has a "Requests" row that opens `Activity`.
- **Change.** Create a glossary in `design-language.md` §5 with a hard limit on nouns:
  - **Try** (verb), **Find** (the temporary song), **Keep** (verb on a find), **Add to library** (not-yet albums and artists), **Preview** (open-licence audio only), **Activity** (the place).
  - Replace the "Sample" stamp with **"Find · MP3"**.
  - Rename Library → Requests to **Activity**.
  - Drop the "Still deciding" header and use "Earlier".
- **Cost.** S

### M3. The Try sheet adds a tap where it isn't needed, and it can start audio unasked
- **Problem.** Decision 13 forces a sheet on every not-yet tap. In `Try-Sheet` it holds three actions plus an open preview "playing now while you decide", which interrupts whatever was playing and contradicts the "one action" house rule (`States-Gallery`). A playlist with six Try buttons means six sheets.
- **Change.** Adapt the sheet to the situation:
  - When the estimate is under about 2 min and the user is under the cap, a tap on **Try** acts immediately with a 4 s "Bringing Harbour Lights home · Undo" toast.
  - The sheet appears only when the wait is long, the cap is near or the user is a Listener with no awake processor.
  - The open preview never autoplays. It's a secondary "Play free preview" button.
  - Long-press on any not-yet row always opens the full sheet.
- **Cost.** S–M

### M4. One request object lives in five places, and the global status is a tiny avatar ring
- **Problem.** An in-flight Try appears in the wait screen, Activity (via the avatar), Library → Requests, Home "New finds", the Finds shelf and the Live Activity. The only persistent in-app indicator is a progress ring on a 32 pt avatar (`Home` aria-label "1 song is on its way"). iOS 27's bottom accessory, which already holds the mini player, is the natural place for status.
- **Change.**
  - While something is on its way and the mini player is idle, the bottom accessory shows "Harbour Lights · on its way · 0:20". While music plays, it shows a small record badge on the mini player that opens Activity.
  - Make the Finds shelf the single home for *landed* items and Activity the single home for *in-flight and history*. Home "New finds" becomes a link into the Finds shelf, not a copy of it.
- **Cost.** M

### M5. Settings sprawl, duplicated controls, and a Character dial that changes meaning
- **Problem.** Streaming quality is set in three places: `Settings` ("Lossless on Wi-Fi · High on cellular"), `NP-Output` (At home / Away / On cellular) and `Downloads` ("follows Data saver"). Finds days appear in `Onb-Household`, `Settings-Sources` (twice on the same screen: "Keep finds for 7 days" and "clear themselves after 7 days") and implicitly in `Household`. Appearance offers 3 Characters × accent × sleeve tint × spin toggle × visualizer × app icon. Classic changes the not-yet semantics (see H2).
- **Change.**
  - Streaming quality lives in **Settings → Playback & quality** only. `NP-Output` shows the current route and links there.
  - Every Finds rule moves into **Household → Finds** (Curator).
  - Appearance shows the Character dial and Accent. Sleeve tint and record spin are folded into the Character choice; Reduce Motion handles motion. The visualizer moves to an Immersive Now Playing ⋯ menu.
  - Listeners see 5 rows at most: Appearance, Playback & quality, Downloads, Your account, About.
- **Cost.** S

### M6. Service names leak to Listeners
- **Problem.** `Join-Ready` asks Leo to connect "Your ListenBrainz". `Settings` shows "ListenBrainz · Connected as sam" to every role. That breaks the voice rule ("Never a service name") for exactly the people it protects.
- **Change.** For Listeners, use "Personal picks · Optional · Connect a listening history account (ListenBrainz)". The service name appears only in the parenthetical on the connect sheet. Move the step out of Join entirely: offer it from the first "Made for you" empty state.
- **Cost.** S

### M7. Wait estimates are per tier, static, and silently wrong after fallback
- **Problem.** The Try sheet quotes "Quick fetch · about 30 seconds". Quick fetch falls back silently to Standard after 60 s (`flows.md`), but `Try-Wait-Fast` keeps counting against "Usually about 30 seconds". The Patient tier calls a multi-hour request "Try", and its "Next try in 2 min" catalogue-outage line exposes retry mechanics.
- **Change.**
  - Re-estimate when the tier changes and say so once ("Taking the slower route · a few minutes").
  - Show a range, not a point ("20–60 s").
  - Past twice the estimate, switch to "Taking longer than usual — you can leave" and never count up indefinitely.
  - Patient-tier copy uses "Ask for it", not "Try".
  - Drop "Next try in 2 min".
- **Cost.** S

### M8. Home for a new Listener is empty while the library holds 12,480 songs
- **Problem.** The first-run state is "Your mixes appear after a few days of listening" (`flows.md` Home). That is fine for a new library and wrong for Leo joining an established one.
- **Change.** For new members, seed Home with household shelves: **"Popular in your house"** (the `Explore` "Top this week" data), Recently added, and a random-album shelf. Hide personal mixes until ListenBrainz data exists.
- **Cost.** S

### M9. Finds and not-yet music in CarPlay need tighter rules
- **Problem.**
  - `CP-Home` labels Weekly Exploration "New to you · ready to play", but most of it isn't home (Q3).
  - The Keep custom button is an unlabeled glyph (Q5).
  - The Try alert has three actions.
  - The Finds tab takes the fourth tab slot, which Playlists or Radio would use more often.
- **Change.**
  - CarPlay plays only what's home. Weekly Exploration in the car = its library songs plus finds, with copy "From this week's picks".
  - Use the system `CPNowPlayingAddToLibraryButton` for Keep, since drivers know "+".
  - Try alert: "Try it next" / "Cancel".
  - Keep the Finds tab only if Q1 confirms `CPSearchTemplate` works as a tab root. Otherwise, fold Finds into Home as a row.
- **Cost.** S

---

## Low

### L1. "Following" contradicts Home
`Artist` says "Following · New releases come in automatically", while `Home` shows "New from artists you follow: Fieldnotes · Not in your library yet". Either following auto-adds releases (then the row says "Arriving") or it doesn't (then rename to "Get notified"). Pick one. **S**

### L2. The calm-states house rule is broken by its own screens
"One action, or none. Never two competing buttons" (`States-Gallery`) is broken by the CP-States alert (OK / Play similar), the Try sheet (3 actions) and `Try-Ready` (Keep / Not for me, which is arguably fine). Restate the rule as "one primary action" and audit every screen against it. **S**

### L3. State that relies on colour and motion
Days-left arcs and colour fade carry state. VoiceOver labels exist on most art, but check that every arc has a text twin ("5 days left") at all Dynamic Type sizes. Also make sure the Keep sheet scrolls at AX5 rather than truncating options. **S**

### L4. Destructive Curator actions have no design
"Remove" (Album, Curator only) and "Stop looking" have no confirmation or undo. Removing an album deletes files for the whole household. Use a confirmation sheet naming the scope ("Removes Glasshouse for everyone in the house"). **S**

### L5. Docs disagree with each other
The docs disagree on the step count (6 vs 7), the cap (10 vs 25), role names (Keeper in the spec, Curator in the UI), "Ready to try" (spec) vs "Finds" (UI), and the landing rule (H1). Run one consistency pass so engineers aren't building from contradictory sources. **S**

---

## Top 5 changes to make before building

1. **Ship "Start listening" right after Connect** and turn the rest of owner setup into a Home checklist card. Make the samples-folder step asynchronous (C1).
2. **Make Keep mean "keep this release"**. Discography becomes an optional follow-up with three choices plus a size estimate, "Follow" becomes a separate toggle, and a household cap limits what Listeners can bring in (C2, M1).
3. **Only promise what the platform can deliver.** No "we'll tell you" without a live process or a push channel, show household processor status and real estimates before Try, and use "Ask for it" for long waits (C3, H7, M7).
4. **Write one queue-landing rule, one Finds cap, bounded retries with a terminal state, and a "Not the right song?" retry.** Remove the per-wait toggles (H1, H4, H5).
5. **Demote shape to a secondary cue.** Library-first search bands, text and Try capsules on every not-yet row, finds drawn as sleeves, artists always circles, no Character-dependent semantics, and no fading outside the Finds shelf. Also verify Away reachability during Listener join (H2, H3, H6, C4).
