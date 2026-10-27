# Decision log — Magpie

Owner (Jordan) authorised overnight autonomous work on 2026-10-26: "approve everything you do but use agents to critically evaluate the decisions". Every decision made without the owner is recorded here with who challenged it and why it stands.

## Owner decisions (2026-10-26)
- Name **Magpie**. Logo: the original record-slipping-out-of-sleeve mark (bird lives in name + voice only).
- Design language as storyboarded (Character dial Classic / Signature / Immersive; sleeve vs record; Finds; Sheen accent) — "perfect".
- All prior calls accepted (Keep, Curator/Listener, tabs Home · Explore · Library + Search).

## Overnight decisions
(appended below as they are made)

### 2026-10-26 night — design critique triage (critiques in docs/reviews/design-critique-*.md)

| # | Decision | Driven by | Status |
|---|---|---|---|
| D1 | **v1 = owner-only Curator build**, direct to real Navidrome + Lidarr (+ optional ListenBrainz), iPhone simulator + CarPlay simulator. No mailbox, Listener role, invites, Mac helper or Quick fetch in v1. | Feasibility §4 | Accepted |
| D2 | **Character dial stays in v1** (Classic + Signature + Immersive-lite = blurred art backdrop under glass, no particles/visualizer). Feasibility wanted it deferred; owner explicitly prioritised the look, and it is theming-only in SwiftUI. | Owner priority vs Feasibility | Accepted with change |
| D3 | **Keep the round-record motif** (owner-approved) but never rely on it alone: every not-yet / find / on-its-way row also carries a text status and a symbol; Classic shows a badge instead of 55% opacity. Finds stay round (rejecting UX's "finds as square sleeves": a find is not yet yours). Artists in library = plain circles; not-yet artists = groove ring + "Not in your library". | UX H2, A11y C2 | Accepted (partial) |
| D4 | **Search ranks library results first**; top result is never a not-yet item when a library match exists. | UX H3 | Accepted |
| D5 | **Keep defaults:** Keep always keeps the find's release. "Bring in more from <artist>?" follows with Albums+EPs preselected (owner default) and an approximate size; "Follow new releases" is a separate toggle. CarPlay Keep = release only (no sheet). | UX C2, Devil H3 | Accepted (owner default preserved on phone) |
| D6 | **One landing rule:** a find plays immediately only if the user is still on its wait screen and nothing else is playing; otherwise it goes next in the queue with a "Play now" banner. CarPlay Try = "Try it next"; if nothing is playing, start a library mix seeded by the artist and queue the find next. | UX H1, CarPlay H3 | Accepted |
| D7 | **Honest progress:** real % and steps only while the app is in the foreground; elsewhere coarse steps + elapsed + tier phrase. No countdowns outside the app, no Live Activity in v1, local notification only while the app runs. "Ready" = Navidrome lists the song (not Lidarr import). | Feasibility, UX C3 | Accepted |
| D8 | **Waits over ~10 minutes (Patient tier) don't show a spinning wait screen:** Try becomes "Ask for it" → it appears in Finds when it arrives. | Devil C2, UX | Accepted |
| D9 | **Setup:** "Start listening" right after Navidrome connects; Lidarr/Finds/ListenBrainz become a "Finish setting up" card on Home. Nothing is written to Lidarr without an explicit tap; everything Magpie adds is tagged `magpie`. | UX C1, Feasibility | Accepted |
| D10 | **Finds lifecycle v1:** per-release, manual "Not for me" (confirm) + Keep; days-left shown; no automatic expiry. Spec for v2 expiry: per release, re-check before delete, untag on Keep first, Lidarr recycle bin, **no import-list exclusion**. | Feasibility C2, Devil H3 | Accepted |
| D11 | **Mailbox v2 redesign:** two playlists per user (user-written outbox, Curator-written inbox) + one Curator-written household playlist + leader lease; every Lidarr step idempotent by MBID. | Feasibility C1–C4 | Accepted (spec only) |
| D12 | **CarPlay:** tab roots are list templates only — Home · Library · Finds · Search(list: Siri/assistant cell, "Type a search" disabled when keyboard-limited, recents) → pushes CPSearchTemplate. Now Playing artwork = real album cover (no record treatment). Keep = system add-to-library button. ≤2 pushes below a tab. State copy describes, never instructs. | CarPlay C3, H1, H2, H4 | Accepted |
| D13 | **App Store posture (OWNER TO CONFIRM):** full disclosure in Review Notes; remove "absent from App Review demo setups" and tier names from App Store builds; Mac helper/Quick fetch ships separately (ideally open source) and is disclosed; demo server with CC-licensed catalogue only. Not relevant to tonight's dev build. | Devil C1, CarPlay C1/C2 | Accepted, flagged for owner |
| D14 | Keep the voice "Bringing it home" (rejecting Devil's "Asking your server for it"): concealment risk is solved by disclosure, not by blander copy. | Devil C1 | Rejected change |
| D15 | **Accessibility baseline in v1:** VoiceOver model (title/artist label, state as value, named actions, Magic Tap), Dynamic Type via text styles + @ScaledMetric with stacked layouts at AX sizes, 44pt targets, light-mode Sheen elements use #0E6F68, Immersive scrim ≤ #2A2A2A luminance under text with solid capsules, Reduce Motion/Transparency honoured, mini player controls accessible. | A11y C1–C3, H1–H2 | Accepted |
| D16 | Cut "Top this week in your house"; Listener-facing copy names "the household", never a device. | Feasibility | Accepted |
| D17 | Account deletion in-app required before invites ship (5.1.1(v)). | CarPlay/AppReview | Accepted (v2) |
| D18 | **Adopt the v1 decision review in full** (docs/reviews/v1-decision-review.md): milestone order M0–M8 with a tagged green build + RUNBOOK update per milestone; API corrections A1–A17; safety guards G0–G9 (master "Allow Magpie to change Lidarr" switch off by default, change log, explicit Finds-root confirmation — no "samples" name auto-detect, ledger, delete/move preconditions, never modify owner config); blockers B1–B10 in the RUNBOOK. "Done" = highest milestone tagged green. | v1 decision review | Accepted |
| D19 | Overnight agents never touch real servers: tests run against 127.0.0.1/localhost dev stack only (G0). | v1 decision review | Accepted |
| D20 | Execution: subagent-driven (fresh implementer per task + reviewer), milestone-gated. | Owner asked for agents | Accepted |

### 2026-10-27 — final review fix wave (docs/reviews/final-review-v1.md)

| # | Decision | Driven by | Status |
|---|---|---|---|
| D21 | Fix I1–I5 in one wave plus a G1 write-verb check (`scripts/check-writes.sh`, run by `test-all.sh`). Other review Minors stay deferred per the review's triage. | Final review | Accepted |
| D22 | I1: `PlayCounting` is the only Count plays switch (`Player.countPlays` removed). | Final review I1 | Accepted |
| D23 | I4: waiting copy names no service ("Can't bring songs home right now. We'll try again.", plus the reason when known) instead of the review's "Lidarr isn't answering" — §5 voice rule. | Design language §5 vs review | Accepted with change |
| D24 | I2: an https failure that looks like a plain-http server suggests typing `http://`. A genuinely broken https server can get the same advice — accepted, it's advice only. | Re-review Minor | Accepted |
| D25 | `BrowseFlowTests.testConnectLidarrShowsSummary` fails intermittently and identically before the fix wave; treated as a pre-existing UI-test flake, not a regression. | Fix report | Accepted, flagged for owner |
| D26 | The RUNBOOK device-build command is unverified (no signing team or device during the overnight run). | Fix report | Flagged for owner |

### 2026-10-27 — phase 2: finish the v1 roadmap

| # | Decision | Driven by | Status |
|---|---|---|---|
| D27 | Merge the hardened increment (M0–M5 + M8, tag `m8`) into `main`; build M6/M7 on `v1-finds`. | Owner: "act as a formal dev team" | Accepted |
| D28 | Remaining v1 order: M6 Finds → M7 Polish → hardening (edge cases, security review of Finds delete/move, final review) → merge, tag `v1.0-rc`. v2 items stay spec-only until the owner has tested on real servers. | Roadmap + G0 | Accepted |
| D29 | Finds are never scrobbled (Player.isFind wired in M6). | M4 ruling, D10 | Accepted |
| D30 | **H4 ATS:** Debug swaps `NSAllowsLocalNetworking` for `NSAllowsArbitraryLoads` (iOS ignores arbitrary loads when local networking is present, so Debug blocked http like Release); Release unchanged (`NSAllowsLocalNetworking` only, checked by `scripts/check-release.sh`); `ServerAddress.atsBlocksPlainHTTP` pre-refuses plain http that Release ATS would block (Tailscale 100.64/10, other IPs, dotted non-`.local` names) with "This address needs HTTPS…" before anything is sent. | H4 real-server test, V-fix | Accepted |
