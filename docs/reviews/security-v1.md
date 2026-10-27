# Magpie v1 security review (Task 8.2a)

Date: 2026-10-27. Branch `v1-build` at `313f058` (m5). Read-only audit: the only repo write is this file.
All builds and probes ran outside the repo, in the session scratchpad (`…/scratchpad/secaudit`). Network probes
used loopback only. The dev stack was not contacted.

Scope: spec §5, G0–G9, plan Task 8.2 / Global Constraints, plus the parked Task 5.3 ledger item.

## Status (Task 8.2 fixes, 2026-10-27)

| Item | Status | Commit(s) | Regression tests |
|---|---|---|---|
| H1 | **Fixed.** `monitorExisting` resolves this request's own open `notSent`/`unclear` entry with the `retrySearchOnly` table (shared `resolveOwnPending`); it never replaces it | `15b982b` | `RunnerSecurityTests.ownUnclearEntryIsNeverOverwrittenAfterAFailedSave` (E6 reproduction: no PUT, no search, `.failed(.stoppedInLidarr)`, entry stays `unclear`), `ownNotSentEntryIsSentWhenTheAlbumIsUnmonitored` |
| H2 | **Fixed** (minimum + consent). Login only after a Subsonic ping answer, in both the client and the app probe. Plain `http://` to a non-private address (not loopback, LAN, link-local, `.local`, single-label, CGNAT 100.64/10, IPv6 ULA/link-local) needs the owner's consent in Connect, remembered per origin; same for the Lidarr key. Schemeless input defaults to `https://` unless private. Connect recommends HTTPS. Deviation: a literal "status ok" would refuse every real Navidrome (0.64.2 answers an unauthenticated ping with `status: failed`, code 10), so a `failed` envelope with a version and an auth/missing-parameter code (10, 40–44) also counts | `ee4034f`, `db0f2e8` | `NavidromeAuthTests.portalAnswering200NeverGetsThePassword`, `subsonicPingAnswersAreServers`, `otherAnswersAreNotServers`; `SecurityAppTests.plainHTTPToAPublicAddressNeedsConsent`, `privateAndEncryptedAddressesNeedNoConsent`, `plainHTTPLidarrNeedsConsent`, `a200ThatIsNotSubsonicGetsNoPassword`; `ServerAddressSecurityTests` |
| M1 | **Fixed.** `SameOriginRedirects` (scheme, host and port must match the original request) on `URLSessionTransport` (per task, whatever session), the artwork transport and the now-playing artwork session | `9cfa7c6` | `HTTPTransportTests.crossOriginRedirectIsNotFollowed` (302/307, URLProtocol stub), `downgradeRedirectIsNotFollowed`, `sameOriginRedirectIsFollowed`, `redirectPolicyComparesOrigins` |
| M2 | **Accepted (ruling).** Debug keeps `NSAllowsArbitraryLoads` for owner testing with http host names; H2 consent is the mitigation. V-fix (H4): Debug now drops `NSAllowsLocalNetworking` so iOS honours arbitrary loads (before, Debug blocked http like Release); E1's Debug result is now `{NSAllowsArbitraryLoads = true}` only; Release unchanged. Documented in `docs/RUNBOOK.md` | "Task 8.2 docs" commit | n/a |
| M3 | **Fixed.** Switch key `magpie.lidarr.writesEnabled.<instanceScope>`; `LidarrSetup` stored per `instanceScope`; both forgotten on disconnect, sign-out and when another Lidarr replaces the connected one; a newly connected Lidarr starts with writes off | `37ad518`, `db0f2e8` | `WriteGateTests.switchIsScopedToOneLidarr`; `SecurityAppTests.disconnectForgetsTheSwitchAndSetup`, `signOutForgetsTheSwitch`, `anotherLidarrStartsWithWritesOff` |
| M4 | **No change (ruling):** fallback-mode ready songs are library songs | n/a | n/a |
| M5 | **Fixed.** `user:pass@` addresses refused with a validation message (Connect and Connect Lidarr). Public error logs use `Log.category(of:)` (URLError code or domain+code), never `String(describing:)`/`localizedDescription` | `10d3bd7`, `db0f2e8` | `RedactorTests.errorCategoryNeverIncludesTheURL`, `noPublicErrorDescriptionsInLogs` (lint over Sources and App); `ServerAddressSecurityTests.credentialsInAddressAreRefused` |
| M6 | **Fixed.** Throwing `persist()` before `POST /artist`, `PUT album/monitor`, `AlbumSearch` and the clean-up unmonitor; a failed save means the request waits and nothing is sent | `15b982b` | `RunnerSecurityTests.monitorWaitsWhenTheRequestCannotBeSaved`, `addWaitsWhenTheRequestCannotBeSaved`, `searchWaitsWhenTheRequestCannotBeSaved` |
| L6 | **Fixed.** E5 cases moved into `WriteGateTests` (backslashes built at runtime, bytes asserted); control characters (< 0x20, raw or escaped, `\b \f \n \r \t` included) refused in body keys | `2f78b50` | `BodyKeyScanTests.escapesInRawBodies` (21 cases) |
| L1–L5, L7–L12 | Open (Low), not in this round's rulings | n/a | n/a |

Fix round 1: IPv4/IPv6 hosts are classified only when the whole host is an address (`inet_pton`), so `10.0.0.1.evil.com`, `127.0.0.1.evil.com`, `evil.10.0.0.1.com` and numeric single labels such as `134744072` (8.8.8.8 to the resolver) are public: consent is asked and schemeless input becomes `https://` (`ServerAddressSecurityTests.lookalikeHostsArePublic`). The Connect Lidarr consent alert names the host.

### Accepted residual risks

- **AVPlayer follows redirects itself.** Streams are not fetched through `URLSessionTransport`, so `SameOriginRedirects` does not apply. No custom headers are sent; the `u`/`t`/`s` credentials stay in the original URL's query and are not forwarded to the redirect target by the redirect itself.
- **Plain http to private/LAN addresses is not prompted.** On a hostile network that reuses the owner's LAN range (hotel, café), a host at the saved address that answers with a Subsonic envelope could receive the password. The ping check stops routers and portals that answer anything with 200, not a deliberate impostor. HTTPS is the documented setup.
- **Single-label host names (`music`, `nas`) count as home network** (controller ruling): no consent prompt and schemeless input becomes `http://`. A search-domain or DNS-hijack setup could resolve such a name to a public host.

Also documented in the RUNBOOK: Navidrome's login rate limit (about 5 logins per 20 s, then 429) and spacing `scripts/it.sh` runs.

## Method / evidence log

| # | What was run | Result |
|---|---|---|
| E1 | `xcodebuild` Debug + Release (simulator, `CODE_SIGNING_ALLOWED=NO`, derived data in scratch), then `PlistBuddy -c "Print :NSAppTransportSecurity"` on each built `Magpie.app/Info.plist` | Release: `{NSAllowsLocalNetworking = true}` only. Debug: also `NSAllowsArbitraryLoads = true` |
| E2 | `git log --all -p` (47 commits) searched with `grep -F` for the exact values of `NAVIDROME_ADMIN_PASSWORD`, `NAVIDROME_LISTENER_PASSWORD`, `LIDARR_API_KEY`, `LIDARR_UI_PASSWORD` from `dev/.env.local`; the same search over the working tree (excluding `.build`, `dev/data`) | 0 hits for each. `dev/.env.local` is mode 600 and git-ignored. The only token-like strings in history are fixtures (`secret-token-123`, all-zero `subsonicToken`) |
| E3 | Pattern grep of history for `apikey/password/token/secret = "<12+ chars>"` and 32-hex literals | Fixtures only |
| E4 | Loopback redirect probe (`redir.py` + `redir.swift`): ephemeral `URLSession`, request to `127.0.0.1:47601` answered 302/307 to `localhost:47602` | Cross-host GET 302 **forwards `X-Api-Key`** (Authorization is stripped). Cross-host POST 307 **forwards the JSON body with the password** |
| E5 | Scratch SwiftPM package depending on `Packages/MagpieKit` by path, `@testable import LidarrKit`, 14 `\uXXXX` body cases and 10 path/query cases against `WriteTarget` + `ForbiddenWrites.reason` (escapes built at runtime so the bytes really contain a backslash) | All 14 escape cases behave correctly (see §L6). Query/path cases behave correctly |
| E6 | Scratch copy of `RunnerHarness.swift` + new test `parkedOverwriteReproduction` (hold the monitor PUT, stop the runner, remove `albumId`/`lidarrArtistId` from the requests file as a failed save would, relaunch with the album unmonitored) | **Reproduced**: the relaunched runner sends `PUT album/monitor {monitored:true}` and then `POST command AlbumSearch`, and the ledger ends up `applied` (see H1) |
| E7 | `swiftc` probe of the `LossyArray` pattern with `null`, numbers, strings and nested arrays as elements | No hang. Bad elements are skipped. Not a finding |
| E8 | Grep of every non-GET (`httpMethod`, `"POST"/"PUT"/"DELETE"`) and every `gate.send` | Non-GET to Lidarr exists only in `LidarrConnection.send` (fileprivate in WriteGate.swift). 5 gate call sites (Provisioner:139, RequestRunner:514/620/740/926). No caller of `DELETE artist`, no move or file delete. The one other non-GET is the Navidrome `POST auth/login` |
| E9 | Grep for `URLSession`, `URLCache`, `AVURLAsset`, `serverTrust`, `AuthenticationChallenge`, `UserDefaults`, `print(`, logger calls, `String(describing:` | See findings. No trust overrides. Every session is ephemeral with no URLCache. No `print`/`NSLog` |
| E10 | `Package.swift`, `project.yml`, `project.pbxproj` (`XCRemoteSwiftPackageReference` count = 0), and every `import` | **Zero third-party dependencies.** Only Apple frameworks. No analytics or telemetry SDKs |

## Checks that passed

- **Keychain**: `KeychainStore` adds items with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` and no access group (`Keychain.swift:28`). The Navidrome endpoint+credentials, the Lidarr connection and the LB token live only there. The JWT and the Subsonic token/salt are held in memory only.
- **No secrets on disk outside the Keychain**: no URLCache anywhere (`HTTPTransport.swift:13-18`, `Artwork.swift:17-24`, `NowPlayingBridge.swift:108-112`). Cover art is cached in memory only (NSCache). `MPNowPlayingInfo` carries no URLs. AVPlayer streams without a download task. The match-index snapshot file name is a hash.
- **Release ATS** (E1) has no `NSAllowsArbitraryLoads`. No custom trust evaluation.
- **Logging**: `Log.request` sanitises URLs (`u t s p apikey token password`) and headers (`x-api-key`, `x-nd-authorization`, `authorization`). Gate refusals log a masked `logPath`. The change log masks secret-looking body keys and the API key itself. Two gaps are listed under M5 and L4.
- **URL building**: `ServerEndpoint.url` keeps the base path, encodes path segments and query items, and treats `&=+;#` as data. External ids go only into query items. Lidarr paths use `Int` ids.
- **WriteGate**: it is the sole write path (E8). Requests are normalised before the check and the normalised form is what gets sent, so the checker and the sender cannot disagree. Encoding is decoded up to 8 times. `.`, `..`, `;`, non-ASCII and control characters in segments are refused. Writes stay under `/api/v1` only. The never-call list (config, rootfolder, indexer, downloadclient, notification, importlist*, system, missing cleanup, bulk artist delete, profile edits) is checked first. Every allow-list shape is exact. `deleteFiles`/`addImportListExclusion` must be absent or exactly false, at any depth, in the query and in the body. Duplicate keys (case-insensitive) and non-ASCII keys are refused on the raw bytes. A change-log write failure blocks the send.
- **Ledger and requests scoping**: each ledger entry carries an instance stamp, and the requests file is per instance (`instanceScope` = SHA-256 of base and API key). The runner refuses a ledger for a different instance (`RequestRunner.swift:121`).
- **Locked device**: unreadable ledger, change log or requests file → `unavailable` → no write (`LocalFile.swift:31-50`, `RequestStore.swift:124-138`). A locked session Keychain → `.unavailable` → wait for `protectedDataDidBecomeAvailable`. CarPlay shows a locked state.
- **File protection**: every JSON write goes through `AtomicFile` (`.completeFileProtectionUntilFirstUserAuthentication`, temp file in the same directory, then replace). The ledger, change log, requests and snapshot are excluded from backup.
- **Input handling**: Lidarr display strings are capped (`DTOs.swift:14`) and `shortNote` is capped at 120 characters with control characters removed. LB/MB strings are capped at 500. Display is SwiftUI `Text` only. No `NSPredicate`. `String(format:)` is used only with constant formats.
- **Scrobble toggle (G8)** is checked on every scrobble (`NavidromeAdapters.swift:31`).

---

## High

### H1. Parked 5.3: `monitorExisting` overwrites its own `unclear` entry and re-monitors over the owner's unmonitor (REQUIRED FIX, reproduced)

- **Location**: `Packages/MagpieKit/Sources/Requests/RequestRunner.swift:562-596` (`monitorExisting`). Contributing: `:250-256` (`changed()` logs and swallows the save error) and `:589-592` (ids saved through `mutate` → `changed`).
- **Scenario**:
  1. `monitorExisting` records `notSent`.
  2. `mutate` stores `albumId` and `lidarrArtistId`, but `store.save` fails (disk full, protected data, I/O error). The error is logged and dropped.
  3. `sendMonitor` records `unclear` and sends the PUT, and the app dies before the answer arrives. Lidarr applies the PUT. The owner then unmonitors the album in Lidarr.
  4. On relaunch the request is `.adding` with `albumId == nil`, so `addOrMonitor` takes the `monitorExisting` branch, not `retrySearchOnly`. `prior` is this request's own open `unclear` entry, but `livePrior` only accepts `applied` entries. The album is unmonitored, so the code builds a fresh `notSent` entry that **overwrites `unclear`**, then sends `PUT album/monitor {monitored:true}` and an `AlbumSearch`.
  5. The owner's explicit unmonitor is reversed and a real indexer search starts.
- **Evidence**: E6. Output of the relaunched runner: `PUT album/monitor {monitored:1, albumIds:[31]}`, then `POST command AlbumSearch`. The ledger ends `.applied`. The existing test `crashWhileMonitorInFlightNeverOverridesTheOwner` passes only because the ids reached disk.
- **Fix** (as ruled in progress.md):
  1. In `monitorExisting`, after reading `prior`: if `prior.isOpen && prior.requestId == id.description && prior.send != .applied`, apply the `retrySearchOnly` table to `(prior.send, album.monitored)`:
     - `unclear` + unmonitored → `throw AddFailure(.stoppedInLidarr)`, no write;
     - `unclear` + monitored → mark `applied`, keep `wasMonitoredBefore`;
     - `notSent` + monitored → the owner's (`wasMonitoredBefore = true`, applied);
     - `notSent` + unmonitored → `sendMonitor(prior…)`.
     Never replace an `unclear` entry with `notSent`. Factor the table into one function used by both paths.
  2. Refuse to send unless the ids are persisted (see M6): `try await persist(id)` (a throwing save) after setting `albumId`/`lidarrArtistId` and before `sendMonitor`. A failed save means the request waits.
  3. Add a regression test: E6's test with an assertion that `h.server.writes.isEmpty` and the state is `.failed(.stoppedInLidarr)`.

### H2. Credentials go in cleartext to whatever answers at the owner's LAN address on any network

- **Location**:
  - `NavidromeClient.swift:61-85`: `performLogin` probes `rest/ping`, accepts any 2xx, then POSTs `{"username","password"}` to the chosen base.
  - `NavidromeClient.swift:133-138`: every Subsonic URL carries `u`, `t`, `s`. Navidrome's login-issued token/salt is a **fixed, replayable** credential, and `md5(password+salt)` with a known salt can be cracked offline.
  - `WriteGate.swift:39-48`: every Lidarr call carries `X-Api-Key`, which gives full admin over Lidarr, including deletes.
  - `ServerAddress.swift:9`: input without a scheme defaults to `http://`.
  - `project.yml:71` / Info.plist: `NSAllowsLocalNetworking`.
- **Scenario**: the owner saves `http://192.168.1.20:4533` (LAN, tried first) and `http://192.168.1.20:8686` for Lidarr, then joins a hotel, café or friend's Wi-Fi.
  - Navidrome: on any reconnect (launch, failover, 401) the app pings `http://192.168.1.20:4533/rest/ping`. Many routers, captive portals and hostile hosts answer 200 to any path. `firstReachable` accepts that, and `performLogin` sends the **plaintext password** to that host.
  - Lidarr: the background runner polls every 30 s and sends the **Lidarr API key** to whatever listens on that IP and port.
  - On the home LAN itself, every passive sniffer sees the password at login and the token on every stream URL.
  - ATS does not help: `NSAllowsLocalNetworking` exempts exactly these addresses.
- **Evidence**: code reading. E1 shows that `NSAllowsLocalNetworking` ships in Release.
- **Fix** (in order of value):
  1. The probe must validate the body, not just the status: parse `subsonic-response.status == "ok"`, and also `type == "navidrome"` / `openSubsonic`. This stops accidental leaks to routers and portals.
  2. Never send the password over `http://` to a non-loopback host without explicit owner consent. Show a "Plain HTTP: your password and Lidarr key travel unencrypted; only use on your home Wi-Fi" confirmation, stored per address. For `http` bases, prefer client-side token auth with a fresh random salt per request (the fallback in `SubsonicAuth.queryItems` already exists) instead of the replayable server-issued pair.
  3. For Lidarr, require HTTPS, or the same per-address consent, before enabling "Allow Magpie to change Lidarr".
  4. Document in the RUNBOOK that HTTPS (reverse proxy) is the supported setup for anything that leaves the house.

## Medium

### M1. Redirects forward `X-Api-Key` / `X-ND-Authorization` and the login body to other hosts

- **Location**: `HTTPTransport.swift:7-35`, `Artwork.swift:17-24`, `NowPlayingBridge.swift:108-112`. No `URLSessionTaskDelegate`, so the default redirect policy applies.
- **Scenario**: any Lidarr or Navidrome response (a compromised server, a reverse-proxy misconfiguration, an open redirect on the proxy, or a MITM on plain HTTP) answers 302/307 to `http(s)://attacker/…`. URLSession follows the redirect and re-sends the custom API-key header. A 307 on `auth/login` re-sends the password body.
- **Evidence**: E4. `LANDED GET /landed X-Api-Key= SECRETKEY` and `LANDED POST /landed … body= {"username":"u","password":"PLAINPW"}`.
- **Fix**: give `URLSessionTransport` a delegate whose `willPerformHTTPRedirection` returns `nil` (refuse) when the scheme, host or port differs from the original request, and also on any https→http downgrade. Simplest: refuse all redirects for Lidarr and for `auth/login`. Add a MockTransport-free unit test using a `URLProtocol` stub.

### M2. The owner-testing build is Debug, and Debug allows arbitrary plaintext loads

- **Location**: `project.yml:73-80` (post-build script adds `NSAllowsArbitraryLoads` in Debug); `Magpie.xcscheme` LaunchAction `buildConfiguration = "Debug"`; `docs/RUNBOOK.md:43` (install the `Debug-iphonesimulator` app).
- **Scenario**: the owner follows the RUNBOOK against the real servers. A typo or schemeless public hostname (`music.example.com` becomes `http://music.example.com`, see `ServerAddress.swift:9`) connects over plaintext to a public host and sends the password and API key. Release would have refused it.
- **Evidence**: E1 shows the Debug plist has `NSAllowsArbitraryLoads = true`.
- **Fix**: the dev stack is on `127.0.0.1`, which `NSAllowsLocalNetworking` already covers, so delete the post-build script. If something still needs it, restrict it to an `NSExceptionDomains` entry for `localhost`. Otherwise run owner testing on a Release build and say so in the RUNBOOK. Also default schemeless input to `https://` unless `ServerAddress.isLocalNetwork`.

### M3. "Allow Magpie to change Lidarr" is global: it survives disconnect, sign-out and a switch to another Lidarr

- **Location**: `WriteGate.swift:362,390-394` (one UserDefaults key, not scoped); `AppModel.swift:270-296` (`signOut`) and `:473-479` (`disconnectLidarr`) never clear it; `LidarrSetupStore.swift:30-36` keys the provisioning ids by `base` only, not by instance.
- **Scenario**: the owner enables writes against the dev stack, disconnects, and connects the real Lidarr. Writes are enabled at once (G1 expects off until the owner turns it on for this Lidarr). A regenerated API key at the same address keeps the old profile and tag ids, so `POST /artist` may reference a wrong or missing profile.
- **Fix**: store the switch per `instanceScope` (key `magpie.lidarr.writesEnabled.<scope>`). Clear it on disconnect and sign-out. Key `LidarrSetup` by `instanceScope` as well.

### M4. A find's trial plays are scrobbled (spec §5)

- **Location**: `AppModel.swift:153-155` builds `Player` without `isFind`, so the default `{ _ in false }` applies (`Player.swift:74`). `Player.swift:316` relies on it.
- **Scenario**: in fallback mode a Try'd song is in the main library. Playing it while it is ready but not kept scrobbles to the owner's ListenBrainz/Last.fm through Navidrome. Spec §5 says "never scrobble a find's trial plays (… request state ≠ ready-unkept)".
- **Fix**: pass `isFind: { song in requests.contains { $0.songId == song.id && $0.state == .ready } }` (plus the Finds library id once M6 lands), and add a test. Until then, the RUNBOOK should tell the owner to turn "Count plays" off while testing (B9).

### M5. Credentials embedded in a typed address are stored, shown and logged

- **Location**: `ServerAddress.swift:6-14` accepts `http://user:pass@host`. Effects:
  - `LidarrSetupStore.swift:6-7,39` saves `base` (with the userinfo) to **UserDefaults**, which is backed up.
  - `ConnectLidarrView.swift:99` displays `base.absoluteString`.
  - `RequestRunner.swift:938` logs `String(describing: error)` with `privacy: .public`. For a `URLError` that text includes `NSErrorFailingURLStringKey` with the full URL, unredacted (E4's crash text shows the key).
- **Scenario**: an owner behind a basic-auth reverse proxy types the address with credentials. The proxy password ends up in UserDefaults, on screen and in the unified log.
- **Fix**: reject or strip `user`/`password` in `ServerAddress.parse`. Replace `String(describing: error)` with a redacted description: map `URLError` to its `code`, or run the failing URL through `Redactor.sanitize`. Add a lint test that greps for `String(describing:` next to `privacy: .public`.

### M6. "Saved before the write" is not enforced: `changed()` swallows save failures

- **Location**: `RequestRunner.swift:250-256`. Affected invariants: `addSent` (`:612-616`, documented as "Set (and saved) before the write", `RequestStore.swift:55-57`), and the ids before `sendMonitor` (H1).
- **Scenario**: the save fails, then `POST /artist` succeeds, and the app dies before the artist-level ledger entry is written (`:635-641` also only logs). On relaunch `addSent == false` and the artist exists, so `monitorExisting` treats Magpie's artist as the owner's (`wasMonitoredBefore = true`, `createdArtist = false`). Magpie can never undo the add. This direction is fail-safe, but it is the same root cause as H1 and it breaks the G3/G6 ledger guarantee.
- **Fix**: add `persist(_:) throws` and call it before every gate write (add, monitor, search). On failure, wait (`.lidarrUnavailable`) and send nothing. Keep `changed()` for UI-only updates.

## Low

### L1. Keychain hygiene
- `Keychain.swift:22-24`: the update path does not re-assert `kSecAttrAccessible`, so an item created earlier with another class keeps it. Include it in `update`, or delete and re-add.
- Keychain items survive app deletion. A reinstall silently restores the old session. Wipe on first launch, using a UserDefaults sentinel.
- `signOut` (`AppModel.swift:270`) leaves the ListenBrainz token, the gate switch (M3) and recent searches (`SearchModel.swift:113-120`) in place.

### L2. A locked launch misreads Lidarr and the LB token as "not configured" for the rest of the process
- **Location**: `LidarrConnectionStore.swift:30` and `:54` (`try?` turns `errSecInteractionNotAllowed` into nil); `AppModel.swift:136,150`. `protectedDataBecameAvailable` re-reads only the Navidrome session.
- **Effect**: after a pre-unlock CarPlay or background launch, the runner never starts (no polling, no clean-up) and Settings shows "Connect Lidarr". This fails safe (no wrong writes) but is confusing.
- **Fix**: return a three-state result as `SessionStore` does, and re-load the Lidarr connection, `hasListenBrainzToken` and `rebuildRunner()` on unlock.

### L3. Test hooks ship in Release
- **Location**: `AppModel.swift:170-176`. `-MagpieResetState YES` clears the Keychain session and Lidarr (but not the LB token). `-MagpieCharacter` sets the theme. Both read standard UserDefaults.
- **Effect**: harmless, but it is a hidden behaviour (App Review, "no hidden features").
- **Fix**: wrap in `#if DEBUG`.

### L4. Redactor key list is narrow
- **Location**: `Redactor.swift:6-7`. Missing: `jwt`, `access_token`, `api_key`, `auth`, the `cookie`/`set-cookie` headers, and `x-auth-token`.
- **Effect**: nothing sends these today. The list should match `BodySummary.secretFragments` (substring match) so future endpoints are covered.

### L5. `ServerEndpoint.url` passes `.` and `..` segments through
- **Location**: `Endpoint.swift:16-19`; used with external text at `ListenBrainzClient.swift:62` (`1/user/\(name)/…`).
- **Effect**: a username like `a/../../1/…` steers the token-bearing GET to another `api.listenbrainz.org` path. The host is fixed and the method is GET, so impact is low.
- **Fix**: encode `/` inside caller-supplied components (pass `name` as one segment), and drop or refuse `.`/`..` segments in `url(_:path:)`.

### L6. WriteGate `\uXXXX` handling: correct, untested, plus a hardening gap
- **Behaviour (E5)**: every one of these escape variants is refused: `deleteFiles:true`, `applyTagſ`, `applyTags:"replace"`, duplicate `applyTags`/`APPLYTAGS`, `NAME` next to `name`, `name:"DeleteArtist"`, `addImportListExclusion:true`, a surrogate-pair key, `deleteFiles:"true"`, and `deleteFileS:true`. `AlbumSearch` is correctly allowed.
- **Gap**: `JSONKeyScan.string()` maps `\b \f \n \r \t` to the letters `b f n r t` (`WriteGate.swift:563-564`), and it accepts `\u0000`–`\u001F` in keys. For example, `{"deleteFiles\t":true}` is allowed. That is harmless today (.NET will not bind it to `deleteFiles`), but the scanner's identity differs from the parser's.
- **Fix**: refuse any control character or non-`\u`/`\"`/`\\`/`\/` escape inside a key. Move the E5 cases into `WriteGateTests` (this closes the known 5.1 gap).

### L7. Unbounded responses and a server-trusted paging loop
- No body size cap anywhere (`HTTPTransport.swift:32`): a hostile server can force a memory jetsam.
- `MatchIndexStore.swift:78-86` pages until `start >= X-Total-Count`. A huge header with empty pages loops for a very long time.
- Navidrome strings and lyrics are not length-capped. The owner's server is trusted, and these are display-only.
- **Fix**: stop when a page returns 0 rows. Cap the total (e.g. 500k songs). Use a streaming `bytes(for:)` with a size limit for JSON endpoints.

### L8. Stream URLs embed a replayable credential and leave the device on AirPlay
- `AVPlayer.allowsExternalPlayback` defaults to true, so AirPlay receivers fetch `stream?u=…&t=…&s=…` directly. Accept this and document it, or set `allowsExternalPlayback = false` and use AirPlay audio routing, which streams from the phone.

### L9. Least privilege: unused allow-list shapes
- `PUT artist/{id}`, `PUT album/{id}`, `PUT artist/editor`, `DELETE artist/{id}`, `RefreshArtist`/`RefreshAlbum`/`ArtistSearch` are allowed but have no caller in v1 M5 (E8). `PUT artist/{id}` accepts any body, including a new `path`/`rootFolderPath`.
- **Fix**: compile them in only when M6/M7 need them, or add body checks then (for `PUT artist/{id}`, refuse `path`/`rootFolderPath` changes and require `moveFiles` to be absent).

### L10. Parked 5.3 #2 (unchanged)
- `adoptCreatedArtist` and `discoverAlbum` (`RequestRunner.swift:545-555,700-710`) ledger the album as Magpie's `applied` even if the owner added the same artist concurrently. Cancel could then unmonitor the owner's album. Extremely unlikely. Leave it parked, but put it in the RUNBOOK's known limits.

### L11. Disk leftovers
- `*.unreadable-<ts>` files (`LocalFile.swift:42-45`, `RequestStore.swift:132-134`) are never pruned.
- The ledger is excluded from backup, so a device restore loses the undo map. This fails safe (nothing gets undone), but the RUNBOOK should say so.

### L12. Test credentials in result bundles
- `scripts/test-app.sh:22,27` exports the dev admin password and Lidarr key as `TEST_RUNNER_*`. These can be recorded in `.xcresult` bundles. Do not share result bundles. Dev-only.

---

## Must fix before owner testing

1. **H1**: fix `monitorExisting` so it never overwrites its own non-applied entry (use the `retrySearchOnly` table), and add the E6 regression test.
2. **M6** (with H1): a throwing `persist()` before every Lidarr write (`addSent`, ids). A failed save means wait, not write.
3. **H2 (minimum)**: the probe must require a valid Subsonic ping body before login, and `http://` to non-loopback must need explicit owner consent before the password or Lidarr key is sent. Recommend HTTPS for the owner's servers.
4. **M1**: refuse cross-origin and downgrade redirects in `URLSessionTransport` (and in the artwork sessions).
5. **M2**: remove the Debug `NSAllowsArbitraryLoads` script (or limit it to localhost), or have the owner test a Release build. Default schemeless non-local input to `https://`.
6. **M3**: scope "Allow Magpie to change Lidarr" (and `LidarrSetup`) to `instanceScope`, and clear it on disconnect and sign-out.
7. **M4**: wire `isFind` (ready-unkept requests). Until then the RUNBOOK says to turn off "Count plays" while testing.
8. **M5**: reject userinfo in addresses, and stop logging `String(describing: error)` publicly (`RequestRunner.swift:938`).
9. **L6**: lift the E5 `\uXXXX` cases into `WriteGateTests` (the known gap), and refuse control-character escapes in keys.
