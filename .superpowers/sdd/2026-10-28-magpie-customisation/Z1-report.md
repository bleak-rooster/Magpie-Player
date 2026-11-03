# Z1 report: round 13 items 1 (Aurral user login) and 14 (Accounts & Servers)

Branch `z1-accounts` (worktree agent-ac5edfade95ad8ada), off v0.0.1-custom, latest v0.0.1-custom merged in (797dbd3).
Decisions: D63, D64 in docs/decisions.md. Research: docs/research/aurral.md § "User sign-in (round 13)".

## Research (Aurral v2.10.0 source, tag commit 832ae3d; nothing sent to the owner's Aurral)
- `POST /api/auth/login` `{username, password}` → `{token, expiresAt (ms), user{id, username, role, permissions}}`;
  401 wrong credentials, 400 missing; rate limit 10 per 15 min (429).
- Opaque 64-hex Bearer token in Aurral's SQLite (survives restarts), 30 days default (`SESSION_EXPIRY_HOURS`).
  No cookie, no JWT, **no refresh route**. Expired/unknown → 401 `SESSION_INVALID`. `POST /api/auth/logout` deletes it.
- Flows/jobs are owner-scoped: user sees own `ownerUserId` flows; admin sees all.
- The owner's Aurral was not probed (not needed; the research used the source only).

## What was built
### Item 1 (AurralKit + app)
- `AurralRoute`: 7 routes (+ `POST api/auth/login`, `POST api/auth/logout`, exact only). check-writes pins all 7,
  the new POST verb ("G1 allowlist: aurral session"), that the client names no API key, and bans `api/auth/oidc`, `api/users`.
- `AurralSession` (actor): token + optional password; renews before a call when `expiresAt` < 1 min away, and on a
  401 (one login shared by concurrent callers, then the call resent once). A refused password → `needsSignIn`, never
  tried again (no loops against the rate limit). Network failure during re-login doesn't mark it.
- `AurralClient`: Bearer header only; `/api/health` sent without credentials; login password only in JSON body;
  `status()` scoped to the signed-in user (`AurralFlow.belongs(to:)`: ownerUserId, else ownerUsername folded,
  ownerless → admins only). Errors: `badLogin`, `signInNeeded`, `rateLimited`.
- App: `AurralConnection {base, username, password, login}` in the Keychain item `aurral.connection` (same class).
  Renewed logins saved. `discover.needsSignIn` → Settings "Aurral signed you out" + Sign In Again; summary "Sign in again".
  Jobs filtered to the user's flows. Sign out (Aurral page, Magpie sign-out, or a different user) sends logout
  (fire-and-forget, never re-login), deletes the item. Upgrade: a round-12 `{base, apiKey}` item is deleted at
  launch; its address prefills the form with "Aurral now signs in with your username and password."
- Aurral page: address, username, password, Sign In; signed in: address, Signed in as, version, flows, Test,
  Allow This Address (moved from New music), Sign Out of Aurral.
### Item 14 (Settings root)
- Top: section "Accounts & Servers" with one-line rows Navidrome / Lidarr / Aurral / ListenBrainz; then Playback,
  Downloads & Storage, Home & Library, Appearance, About.
- Navidrome (was Account & Server) + new Libraries list (Main library / Shown / Finds / Discover / Not shown) +
  main-library picker moved from Finds set-up (Finds now links to it). Lidarr (was New music) + Downloads in Lidarr
  link (no longer top-level). ListenBrainz (was Scrobbling; token first). Old rows removed; Try/Artist/Finish
  setting up open `.lidarr`; copy "Settings › New music" → "Settings › Lidarr".
- Fits 375 × 667: content 480 pt in 535 pt; test now also asserts ≥ 50 pt headroom for Z3's CarPlay row
  (**Z3: add the row through `SettingsView.link` so it gets the 3 pt insets**).

## Tests
- RED: package build failed `cannot find type 'AurralSession' in scope` / `'AurralUser'` (new AurralLoginTests,
  updated AurralClientTests) before implementation. App tests were updated alongside the app change (compile-RED on
  the new `connectAurral(base:username:password:)` signature); SettingsTopLevelTests went RED on fit
  (543 pt in 535, then 510 pt with < 56 headroom) before the row/inset fix.
- New package tests (AurralLoginTests, 13): login, wrong password/user, 429, Bearer only, expiry re-login once,
  past-expiry renew first, concurrent calls share one login, changed password stops, no password, network failure
  keeps session, logout, user scoping (stub admin/user), ownership rule, redaction (URL/log/description/errors),
  login decoding. AurralClientTests: 7-route allow-list, token header + redaction.
- New app tests (DiscoverAppTests): sign-in saves to Keychain only, expired session renews and is saved, changed
  password asks to sign in again (one login), sign-out logs out, user-scoped flows/jobs, upgrade deletes old key,
  connections hide password/token, sign-out logs out. SettingsTopLevelTests: accounts-first order/ids, ListenBrainz
  summary, library roles, fit + headroom. UI: `testAccountsAndServersPages` opens each of the four pages; Lidarr UI
  tests retargeted (`settings-lidarr-account`, Downloads in Lidarr from the Lidarr page, "Lidarr" titles,
  `settings-listenbrainz`); Monkey page list updated.
- GREEN: focused app suites 49/49; full package suite 974 tests passed; check-writes OK; check-release OK.
  Full app suite after merging latest v0.0.1-custom (MAGPIE_IT=1, dev stack, own "Magpie Z1" simulator, app
  uninstalled first; xcresult dd/Logs/Test/Test-Magpie-2026.11.03_19-53-44-+0800.xcresult): **1025 tests, 1022
  passed, 0 failed, 3 skipped** (the opt-in monkey ×2 and bad-network streaming). testAccountsAndServersPages,
  testSettingsShowLidarrControlsAndRequests and testDownloadsInLidarrOpensFromNewMusic passed against the dev Lidarr.
- Note: forks share the session scratchpad; another workstream wrote over my scratch `app.log`, so the xcresult
  above (my simulator's id in it) is the record, not that log.

## Concerns
- The password is stored (needed: Aurral 2.10 has no refresh route). Security look should confirm (planned).
- Logout at sign-out is best effort; offline or consent-pending, the token just lapses in Aurral (30 days).
- Plan item 14 names services in row titles, superseding T21b's no-service rule for this section (D64).

## Review fixes (Z1-review.md), "Z1 fix:" commits
- I1: `AurralSession.onRefused` → the app saves the connection with password and token nil (address and username
  kept); `needsSignIn` derived at launch (and the session starts signed out), so a cold start sends no login.
  RED: compile errors (`onRefused`, `allowAurralPassword`, `plainHTTPWarning` missing). Test
  `refusedPasswordIsNotTriedAfterRelaunch` (new model on the same store: login count unchanged, "Sign in again").
- M1: the Aurral password has its own plain-http consent list (`magpie.plainHTTPConsent.aurralPassword`); a round-12
  or other-service OK doesn't count; the sign-in form always warns for a plain-http public address; consent copy
  mentions the 30-day session. Test `passwordConsentIsItsOwn`.
- M2: back-off in the session: 15 min after a 429, 30 s after a failed login. Test `backsOffAfterRateLimitAndFailures`.
- M3: `scoped(to: nil)` returns no flows. Test `scopingFailsClosed`.
- M5 (stray sessions logged out), M6 (save failures logged), M7 (main library only once the Finds library is
  chosen), M10 (row icon hidden from VoiceOver). M4: 2.10 jobs carry `playlistId`/`playlistType` per the research;
  M8/M9 left (cosmetic).
- Merged v0.0.1-custom (Z3, Z4, Z6): my decisions renumbered D70–D71, review fixes D72. Z3's CarPlay promoted to a
  top-level row through `link` (Home & Library no longer lists it): 526 pt in 535 at 375 × 667.
- Package suite 1111 passed; affected app suites green; full app suite: see the reply.
