# Serverless feasibility: client-only against Navidrome, Lidarr and ListenBrainz

Research date: 2026-10-26. This doc revisits [00-synthesis.md](00-synthesis.md) §6 (the "hub" Go service) under a new constraint:
**no custom backend**. Every client (iPhone + CarPlay, iPad, Mac, tvOS, and a static-file web container like Feishin's) talks only to
the user's **Navidrome**, **Lidarr** and **ListenBrainz** (plus `labs.api.listenbrainz.org`, which is part of LB).

How each claim was checked:
- **[src]** read in source: Lidarr `develop` @ `982bb9f` (2026-10-25), Navidrome `master` @ `ec2e0a9` (2026-10-23) and tag `v0.64.2`, listenbrainz-server @ `7d9a3d6` (2026-10-22).
- **[live]** exercised with `curl` on 2026-10-26. Lidarr 3.1.6.5079 and Navidrome 0.64.2 ran in throwaway Docker containers. LB was tested against production.
- **[doc]** comes from vendor documentation or forum posts.
- **[inference]** is reasoning, not tested.

---

## Verdict table

| # | Question | Verdict |
|---|---|---|
| 1 | CORS | **Feasible, no proxy needed for CORS.** Lidarr `/api/v1`, Navidrome (`/rest`, `/api`, `/auth`) and LB `/1/*` plus labs all send `Access-Control-Allow-Origin: *` and allow the auth headers we need. The real blockers are **mixed content** (HTTPS page calling an `http://` server) and **Chrome Local Network Access** (a public page calling a LAN IP). The fix for both is an nginx same-origin pass-through inside the UI container. Lidarr's SignalR hub has no CORS, so the web app must poll. |
| 2 | Lidarr key permissions | The key is **unscopable and equivalent to root over Lidarr**: it can delete the music library from disk, restore a backup, change auth, point updates at a script, and read secrets. Use **(a) trusted-household invite** for admins and adults. For everyone else use **(b) a request relay through a private Navidrome playlist's `comment`**, which is verified end-to-end and works well. The LB recommend-personal relay works but is clunky. An optional **(c) nginx gatekeeper** keeps the key off devices entirely, but it bends the "no server" rule. |
| 3 | Non-library search | **Feasible.** Artists and albums come from Lidarr `/search` and `/artist|album/lookup`, which hit the SkyHook metadata server (working today, but historically outage-prone). Songs come from **labs `recording-search`** (fuzzy Typesense search over MusicBrainz data, no auth, CORS), then `/1/metadata/recording` maps the result to its release-group, artist MBID and ISRC. LB has **no artist or album text search**; its own UI calls MusicBrainz for that. |
| 4 | 30-second previews | **None of the three services serves audio.** LB labs maps a recording MBID to Apple Music, Spotify and SoundCloud IDs. **Native: MusicKit catalog lookup gives `previewAssets` with no subscription and no server.** It needs one `MusicAuthorization.request()` prompt and the MusicKit App Service enabled on our App ID. **Web:** MusicKit JS needs a signed JWT (at most 6 months, can be origin-locked). Without a server, the practical options are an Apple Music or Spotify **embed iframe** fed by the labs IDs, or a pre-minted token in the container env. |
| 5 | Notifications | No remote push. What works: **live polling while the app plays music** (background audio keeps the app running, which is the common case), opportunistic `BGAppRefreshTask` polls of `/queue/status` and `/history/since`, local notifications, and Live Activities updated only while the app runs. "Ready" can lag by minutes to hours if the app is suspended. Optionally, **Lidarr's built-in Ntfy, Pushover, Gotify or Apprise connections** give real push, but only by adding a third-party service. |
| 6 | Rescan | `startScan` is **admin-only** (verified on 0.64.2 and develop, error 50 for non-admins). `getScanStatus` and SSE `/api/events` are open to all users. The watcher is **on by default** (`Scanner.Enabled=true`, `WatcherWait=5s`, selective per folder). **Better: Lidarr's built-in "Subsonic" Connect calls Navidrome `startScan` server-to-server on every import.** The admin's app can provision this connection over the Lidarr API. |
| 7 | Webhook | The Webhook connection is useless without a receiver. Other Connect types are still useful, though: **Subsonic** (rescan) and push services. Poll `/api/v1/queue` (progress), `/queue/status` (cheap), `/history/since` (completion), `/album?foreignAlbumId=` and `/track?albumId=` (`hasFile`), then confirm in Navidrome by MBID or ISRC. |

---

## 1. CORS

### Lidarr (v3.1.6 / develop) [src][live]
- `src/NzbDrone.Host/Startup.cs` L68–80 registers the policy:
  ```csharp
  services.AddCors(o => {
    o.AddPolicy(VersionedApiControllerAttribute.API_CORS_POLICY,   // "ApiCorsPolicy"
      b => b.AllowAnyOrigin().AllowAnyMethod().AllowAnyHeader());
    o.AddPolicy("AllowGet", b => b.AllowAnyOrigin().WithMethods("GET","OPTIONS").AllowAnyHeader());
  });
  ...
  app.UseRouting(); app.UseCors(); app.UseAuthentication(); ...   // L270-272: CORS runs before auth
  ```
- `src/Lidarr.Http/VersionedApiControllerAttribute.cs` implements `IEnableCorsAttribute` with `PolicyName = "ApiCorsPolicy"`. Every `[V1ApiController]` (artist, album, search, queue, history, command…) therefore gets the policy.
- Live results against 3.1.6.5079:
  - Preflight `OPTIONS /api/v1/queue` with `Access-Control-Request-Headers: x-api-key` → `204`, `Access-Control-Allow-Origin: *`, `Allow-Headers: x-api-key`.
  - `POST /api/v1/artist` preflight with `x-api-key,content-type` → `204` with matching allow headers.
  - `GET /api/v1/queue/status` with the key → `200` with ACAO `*`. Without the key → `401`, and ACAO `*` is still present, so the browser can read the error.
- **SignalR is not covered.** `MapHub("/signalr/messages")` has no CORS policy. Live: the preflight for `/signalr/messages/negotiate` returns `401` with no ACAO. A browser on another origin therefore cannot use Lidarr's real-time hub, and the web app must poll. Native apps are unaffected because CORS is a browser rule.
- Credentials: there are none to worry about. The key travels in the `X-Api-Key` header (also accepted: `?apikey=` and `Authorization: Bearer`), so `AllowAnyOrigin` without `AllowCredentials` is fine.

### Navidrome (0.64.2 and develop) [src][live]
- `server/middlewares.go` `corsHandler()` (identical in v0.64.2):
  `AllowedOrigins ["*"]`, methods `HEAD GET POST PUT PATCH DELETE`, `AllowedHeaders ["*"]`, `AllowCredentials false`,
  `ExposedHeaders ["x-content-duration","x-total-count","x-nd-authorization"]`.
- `server/server.go` `initRoutes()` puts `corsHandler()` in `defaultMiddlewares` for the whole router. `MountRouter` mounts `/api`, `/rest`, `/share`, and `/auth` sits on the same router. CORS therefore covers `/rest`, `/api`, `/auth/login` and `/api/events`.
- Live results against 0.64.2:
  - `OPTIONS /auth/login` → ACAO `*`, allow `Content-Type`.
  - `/api/song` with JWT → ACAO `*` and `X-Total-Count` exposed.
  - `/rest/ping` → ACAO `*`.
  - Preflight with `x-nd-authorization, x-nd-client-unique-id` → allowed.
- The refreshed JWT in `X-ND-Authorization` is exposed, so a browser client can read it. SSE uses `?jwt=` because `EventSource` cannot set headers (`ui/src/eventStream.js`).
- [inference] Stream URLs carry ACAO `*` whenever the request has an `Origin` header. An `<audio crossorigin="anonymous">` element can therefore feed a Web Audio `AnalyserNode` (needed for the visualizer) without being tainted.
- **Feishin does not proxy.** Its `ng.conf.template` only serves static files plus an env-generated `settings.js`, and the browser calls Navidrome directly. That works only because of the CORS config above.

### ListenBrainz [src][live]
- The API uses a per-endpoint `@crossdomain` decorator (`listenbrainz/webserver/decorators.py` L32–56). It sets `Access-Control-Allow-Origin: *`, allows the route's own methods, and allows headers `Authorization, Content-Type`. I enumerated every API route (script over `webserver/views/*.py`). **Every `/1/*` API blueprint route has `@crossdomain`**, including `metadata/*`, `explore/lb-radio`, `cf/recommendation`, `popularity/*`, `playlist/*`, `user/*/feed/events` and `timeline-event/create/recommend-personal`. Only HTML views and the Last.fm-compat endpoints lack it.
- Live: `/1/metadata/recording` → ACAO `*` and the `X-RateLimit-*` headers are exposed. `/1/metadata/lookup` without a token → `401` with ACAO `*`. The preflight for `Authorization` is allowed.
- `labs.api.listenbrainz.org` (datasethoster) → ACAO `*`, allow-headers `CONTENT-TYPE`. That is enough, because labs needs no auth.

### The real browser blockers, and the minimal fix
1. **Mixed content.** If the web UI is served over HTTPS and Lidarr or Navidrome is plain `http://host:8686`, the browser blocks the request regardless of CORS.
2. **Chrome Local Network Access** (enforced since Chrome 142, Oct 2025) [doc: [OpenReplay summary](https://blog.openreplay.com/chrome-local-network-access-lna-permission/), [Dynamsoft](https://www.dynamsoft.com/web-twain/docs/faq/chromium-142-local-network-access-issue.md)]. A page from a *public* address calling a *private or loopback* IP triggers a permission prompt, and the page must be HTTPS. Private-to-private calls do not prompt. (This is a secondary source: verify against chromestatus before relying on the details.)
3. Users often put Lidarr behind SSO such as Authelia, which breaks preflights.

**Minimal fix:** a templated nginx config in the same static container. It is still "no custom backend": just `proxy_pass`, the same mechanism Feishin already uses with `envsubst` for `settings.js`.
```nginx
# /etc/nginx/templates/default.conf.template  (official nginx image runs envsubst on startup)
location /_nd/      { proxy_pass ${NAVIDROME_URL}/;  proxy_buffering off; proxy_read_timeout 1h; }  # streams + SSE
location /_lidarr/  { proxy_pass ${LIDARR_URL}/;     proxy_set_header Host $proxy_host; }
# ListenBrainz / labs: call directly (public HTTPS + CORS *), no proxy needed.
```
The client keeps sending its own `X-Api-Key` and Navidrome credentials. **The proxy must not inject the Lidarr key** unless it also authenticates the caller (see §2c). Otherwise it becomes an open admin proxy. Make the proxy optional: if the user's servers are already same-site HTTPS, the app calls them directly.

Native apps need ATS exceptions for `http://` LAN servers (`NSAllowsLocalNetworking`) and the `NSLocalNetworkUsageDescription` prompt [inference/doc].

---

## 2. Lidarr API key permissions

### What a key holder can do [src]
Lidarr has one authenticated identity. The fallback policy `"API"` requires an authenticated user (`Startup.cs` ~L186), and there are no roles or claims. Anyone holding the key can:

| Action | Endpoint (source) | Impact |
|---|---|---|
| Delete artists **and their files on disk** | `DELETE /api/v1/artist/{id}?deleteFiles=true` (`ArtistController.cs` L196); `DELETE /api/v1/trackfile/bulk` | Destroys the shared music library that Navidrome serves |
| Read and rewrite host config: auth method, username/password, bind address, `ApiKey`, `SslCertPassword`, `ProxyPassword` in clear text, `UpdateMechanism=Script` plus `UpdateScriptPath` | `GET/PUT /api/v1/config/host` (`HostConfigResource.cs` L60–95) | Lock the admin out, rotate the key, or set up script execution on update |
| Restore or upload a backup (replaces DB and config) | `POST /api/v1/system/backup/restore/upload` (`BackupController.cs` L94) | Full takeover |
| Shut down or restart | `POST /api/v1/system/shutdown`, `/restart` | DoS |
| Browse the server filesystem | `GET /api/v1/filesystem` | Recon |
| Add indexers or download clients, or change the root folder | `/api/v1/indexer`, `/downloadclient`, `/rootfolder` | Download arbitrary content, a legal liability for the server owner. Provider passwords are masked as `********` (`SchemaBuilder.cs` L18) |
| Add a Custom Script connection | `/api/v1/notification` (`CustomScriptSettings.cs`) | Runs any existing file on import. Arguments are disallowed, but it is still dangerous |
| Mass monitor plus `MissingAlbumSearch` | `/api/v1/command` | Fills the disk or saturates the indexer quota or ratio |

**Scoping:** none exists. There is one key per instance and no per-key permissions. The only control is regeneration (`PUT /config/host`), which breaks every device holding the old key.

**Related finding [src][live]:** `GET /initialize.json` returns the API key. It sits behind policy `"UI"`, and `UiAuthorizationHandler` lets **any LAN client in with no login** when `AuthenticationRequired = DisabledForLocalAddresses`, which is a common household setting. Live on a fresh install (auth `none`), `/initialize.json` returned `200`. In many homes, anyone on the Wi-Fi can already read the key. The threat model should treat "LAN = admin" for Lidarr unless the admin sets `AuthenticationRequired=Enabled`.

### (a) Trusted-household invite: feasible, simple
- The admin's app builds an invite deeplink or QR code: `app://join?nd=<url>&lidarr=<url>&k=<lidarr key>&exp=<ts>`. Prefer an encrypted payload: AES-GCM with a short PIN said aloud, so a screenshot alone is useless.
- The receiving device stores it in the Keychain (`kSecAttrAccessibleAfterFirstUnlock`, no iCloud sync unless opted in). The web app stores it in IndexedDB, which is weaker. On the web, this mode should be admin-only.
- The UI never exposes destructive operations. That is a UX guard, not a security boundary: a curious teenager with the key and `curl` can still do everything listed above.
- Recovery: the admin rotates the key in Lidarr (`PUT /config/host` or the UI) and re-issues invites.

### (b) Request relay: users without the key write requests, an admin device executes them

**b1. Private Navidrome playlist as a mailbox. Verified end-to-end [src][live].** This is the recommended option.
- Any user can `createPlaylist` and `updatePlaylist&comment=<text>&public=false` (Subsonic) or use native `/api/playlist`.
- Visibility: `persistence/playlist_repository.go` `userFilter()` returns *everything* for `IsAdmin`; other users see `public=true OR owner_id=me`. Live: a non-admin's private `__requests__` playlist showed up in the admin's `getPlaylists` with its comment, and a second non-admin saw `{}`.
- Two-way: `core/playlists/playlists.go` L138/232 let the owner **or an admin** write. Live: the admin's `updatePlaylist` rewrote the kid's comment with `{"state":"downloading"}`, and the kid read it back. The playlist therefore works as both a request queue and a status channel.
- Format: a JSON comment such as `{"v":1,"reqs":[{"id","rec":<recMBID>,"rg":<rgMBID>,"artist":<MBID>,"isrc","ts","state","note"}]}`. I found no length validation in the model or service (string column). Keep it compact and compact old entries. Hide `__requests__` in our UI. Other Subsonic clients will show an empty playlist with an odd comment, which is acceptable.
- Who processes it: any admin device running the app (the Mac app is ideal as an always-on agent; iPhone during playback or a BG refresh) polls `getPlaylists` every N minutes, executes the Lidarr calls, and writes state back.
- Latency equals how often the admin device runs. With a Mac left on it is about a minute. With only an iPhone it can be hours.
- Shares (`/api/share`, `description`) are also visible to admins (`sqlRepository.ownerFilter` returns nil for admins). However, they reference library items and create public links, so they are a worse mailbox.

**b2. ListenBrainz personal recommendation. Feasible but awkward [src].**
- `POST /1/user/<me>/timeline-event/create/recommend-personal` with `{metadata:{recording_mbid, users:[admin], blurb_content}}`. The source rejects recipients who **don't follow the sender** (`"You cannot recommend tracks to non-followers!"`). The admin's device reads `GET /1/user/<admin>/feed/events` (auth) and filters `personal_recording_recommendation`.
- Drawbacks:
  - Every household member needs an LB account, the admin must follow each of them, and every phone needs that member's LB token.
  - Requests are recording-level only. Album or artist intent would have to be encoded in `blurb_content`.
  - There is no status write-back channel, so we would have to reply with a second event.
  - It shows up in LB's social UI.
  - It is subject to LB rate limits.
- Use it only as a fallback when Navidrome is unreachable for the admin.

**b3. (c) nginx gatekeeper in the UI container. Feasible, but it is a server in all but name [inference; nginx `auth_request` is in official builds].**
- Put the Lidarr key in the container env. Route all requests (from native apps too) through `/_lidarr/`.
- `auth_request` sub-requests Navidrome with the caller's JWT:
  - `GET /api/keepalive/keepalive` for "is a user". Live: anonymous → `401`.
  - `GET /api/library` for "is an admin". Live: non-admin `403`, admin `200`, anonymous `401`.
- Allow-list by method and path: non-admins get `GET /search`, `/artist/lookup`, `/album/lookup`, `/album`, `/queue*`, `/history/since`, plus `POST /album`, `/artist` and `/command`. Everything else is admin-only.
- Limits: nginx cannot inspect JSON bodies without njs, so a non-admin could still `POST /command {"name":"MissingAlbumSearch"}`. It is still far better than handing out the key.
- It works for every client, gives instant requests, and keeps the key off devices. It is a configuration file, not code. Decide whether that fits the "no custom backend" rule.

**b4. Navidrome WASM plugin [src].** A plugin with `SchedulerCallback` and the `HTTP`, `SubsonicAPI` and `KVStore` host services could read request playlists and call Lidarr from inside Navidrome. It runs server-side, so it violates the spirit of the constraint. Noted for completeness.

---

## 3. Finding non-library artists, albums and songs

### Lidarr (proxies SkyHook `api.lidarr.audio/api/v0.4`) [src][live]
- Endpoints: `GET /api/v1/search?term=` (mixed artist and album list), `GET /api/v1/artist/lookup?term=`, `GET /api/v1/album/lookup?term=`. ID forms (`lidarr:<mbid>`) do exact lookups. `SkyHookProxy.cs` L227–300 sends `search?type=artist|album&query=…&artist=…&includeTracks=1`.
- Live against SkyHook today: `type=artist&query=portishead` → correct, 0.48 s. `type=all&query=radiohead` → 20 hits. `type=album&query=dummy&artist=portishead` → `Dummy` (rg `48140466…`) plus a compilation.
- Issue [#5498](https://github.com/Lidarr/Lidarr/issues/5498) is **still OPEN** (last update 2026-01-05, "text searches are still functionally broken" at that time). Treat text search as best-effort. Fall back to ID lookups via LB, and use `GET /api/v1/health` to show a degraded state.
- There is no track search. Lidarr search is fine for the Artists and Albums sections.

### ListenBrainz [src][live]
| Endpoint | Purpose | Auth | CORS |
|---|---|---|---|
| `GET https://labs.api.listenbrainz.org/recording-search/json?query=<artist + title>` | **Fuzzy song search**: Typesense over the MBID-mapping index, `num_typos=5`, multiple hits `{recording_mbid, recording_name, release_mbid, release_name, artist_credit_name, artist_credit_id}` (`labs_api/labs/api/recording_search.py`). Live: "portishead glory box" → `145f5c43…` first | none | `*` |
| `GET /1/metadata/lookup/?artist_name=&recording_name=[&release_name=]` | Single best MBID match (the MBID mapper), optional `metadata=true&inc=` | **Token required** (`validate_auth_header()`, live 401) | `*` |
| `GET/POST /1/metadata/recording/?recording_mbids=…&inc=artist release tag` | MBID → `release.release_group_mbid`, `artist_mbid`, `recording.isrcs`, length, `caa_release_mbid`. Live: Glory Box → rg `48140466…`, ISRC `GBAQT9400066` | none | `*` |
| `GET /1/metadata/release_group/`, `GET /1/metadata/artist/` | RG and artist details by MBID | none | `*` |
| labs `acr-lookup`, `acrr-lookup`, `recording-mbid-lookup` | Exact artist-credit/recording(/release) → MBID | none | `*` |
| `GET /1/search/users/` | User search only | token | `*` |
- **There is no artist or release-group text search on LB.** Labs has no `artist-search` (live `404`), and the labs index lists none. LB's own frontend calls `${MBBaseURI}/artist?query=` and `/release-group?query=` on MusicBrainz (`frontend/js/src/utils/APIService.ts` `artistLookup`/`albumLookup`).
- All of this is MusicBrainz data served by MetaBrainz infrastructure. LB is effectively a CORS-friendly, MB-rate-limit-free front for MB metadata, at about 1 req/s per client by LB's own guidance.

**Serverless search pipeline:** Navidrome `search3` (library) ‖ Lidarr `/search` (artists and albums) ‖ labs `recording-search` (songs) → `/1/metadata/recording?inc=artist release` → release-group MBID → Lidarr `album/lookup?term=lidarr:<rg>` → add. De-dupe against the library by recording MBID or ISRC.

---

## 4. 30-second previews

**Navidrome, Lidarr and LB: no preview audio [src][live].**
- Navidrome serves only library files.
- Lidarr has no media endpoints.
- `/1/metadata/recording` returns MusicBrainz URL relationships (for example artist `rels: "free streaming": deezer.com/artist/…`): link-outs, not audio.
- **LB labs ID maps (no auth, CORS) [live]:** `apple-music-id-from-mbid` → `apple_music_track_ids:["1440653206"]`; `spotify-id-from-mbid` → 8 track IDs; `soundcloud-id-from-mbid` → `[]` for this track. There are also `*-from-metadata` variants.
- **BrainzPlayer** (`frontend/js/src/common/brainzplayer/*`) cannot be reused by third parties. Apple Music uses MusicKit JS with LB's server-minted developer token (`views_utils.get_current_apple_music_user`) and needs a subscriber for full tracks. YouTube uses LB's server-side `YOUTUBE_API_KEY` for search. Spotify uses the Web Playback SDK with the user's OAuth token (Premium). These tokens are injected into LB's own pages, not exposed through the API. There is also a `NavidromePlayer.tsx`.

**Native Apple: MusicKit [doc].**
- Enable the **MusicKit App Service** on our App ID. MusicKit for Swift then generates the developer token automatically, with no server and no `.p8` in the app.
- Every launch, the app must call `MusicAuthorization.request()` (DTS answer in [forum 721116](https://developer.apple.com/forums/thread/721116); `NSAppleMusicUsageDescription` is required). Catalog requests work **without an Apple Music subscription** ([forum 682981](https://developer.apple.com/forums/thread/682981), fixed since iOS 15 b3).
- Then:
  - `MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: MusicItemID("1440653206"))` using the labs ID, or `matching: \.isrc` using the ISRC from `/1/metadata/recording`;
  - take `song.previewAssets?.first?.url` (an m4a);
  - play it with our own `AVPlayer`, not `ApplicationMusicPlayer`, which needs a subscription.
- Display "Listen on Apple Music" attribution.
- **Unverified:**
  - `\.isrc` filter availability per OS;
  - behaviour on **tvOS and macOS** (MusicKit exists on tvOS 15+ and macOS 12+, but preview and authorization UX need a device test);
  - users who decline the permission get no previews;
  - side-loaded or self-built open-source builds need their own team with MusicKit enabled.

**Web.**
- **MusicKit JS v3** needs a developer token: an ES256 JWT signed with a MusicKit `.p8`, `exp` ≤ 15,777,000 s (6 months), and an optional `origin` claim [doc: Apple "Generating developer tokens"].
- Without a server, the admin would have to mint the token offline and put it in the container env (`settings.js`), then rotate it every 6 months. That needs a paid Apple Developer account per deployment. The `origin` claim limits abuse. It is feasible but a poor fit for self-hosters.
- **Embeds** need no token [inference + partial live]:
  - `https://embed.music.apple.com/{sf}/song/{id}` returns 200 and is a preview player for signed-out users;
  - `https://open.spotify.com/embed/track/{id}` returns 200, and its HTML references `p.scdn.co/mp3-preview/…`, so signed-out users get the 30 s preview.
  - Both are iframes with no control API: no queue integration, no visualizer, a third-party UI. Do **not** scrape the preview URL out of the embed HTML (ToS).
- Verdict: native previews are good with MusicKit. Web previews are second-class (embed) unless the admin supplies a MusicKit token. All three options use a fourth service (Apple or Spotify) directly from the client, so confirm that this is acceptable under the constraint.

---

## 5. Notifications without a server (iOS)
| Mechanism | Reality |
|---|---|
| APNs remote push / Live Activity push updates / push-to-start | **Unavailable**: each needs a server holding the APNs key |
| **Background audio** | While the user is listening in our app (likely during the wait), the app process runs. It can poll Lidarr every 10–30 s, update a Live Activity, and post a local notification the moment the file lands. This is the main path. Poll only while audio genuinely plays (App Review rule against abusing background modes) [inference/doc] |
| `BGAppRefreshTask` | System-scheduled and opportunistic (minutes to hours, depending on usage patterns and battery), about 30 s of runtime. Enough for `GET /api/v1/queue/status` + `GET /history/since?date=` + a Navidrome `search3` or MBID check → `UNUserNotificationCenter` local notification ("Glory Box is ready") [doc] |
| `BGProcessingTask` | Longer, but typically runs only while charging. Use it for the reconciliation sweep |
| `BGContinuedProcessingTask` (iOS 26+) | User-initiated work continued in the background with a system progress UI ([summary](https://dev.to/arshtechpro/wwdc-2025-ios-26-background-apis-explained-bgcontinuedprocessingtask-changes-everything-9b5)). It requires continuous progress reporting and is meant for finite work like exports. A "waiting for an album download" use may be rejected or expired. **Unverified, prototype before relying on it** |
| Background `URLSession` | Transfers only. It cannot schedule polls. It is useful once the song exists, to auto-download it for offline use |
| Live Activity | Can be started in the foreground on request and updated whenever our code runs (foreground, audio, BG task). It goes stale without updates and ends at about 8–12 h. Without push it is accurate only while we are running |
| macOS | The app or menu-bar agent can stay running, so a Mac is the ideal "admin relay" from §2b and gives reliable local notifications |
| Web | The Notifications API works only while a tab is open. Web Push needs a push sender (a server). Periodic Background Sync is Chromium-only, for installed PWAs, and coarse |
| Lidarr Connect → Ntfy/Pushover/Gotify/Telegram/Apprise [src: `Notifications/*`] | Real push to phones without *our* server, but it goes through a third-party service, is household-wide rather than per-requester, and needs admin setup |

**Realistic UX:**
1. On request, show a "Requested → Searching → Downloading 43% → Adding to library → Ready" card and offer to "play the preview while you wait".
2. If the user keeps listening, they get a live progress bar, a Live Activity, and a banner the moment the song is ready, with the song auto-queued next.
3. If they leave, show "We'll let you know". A BG refresh fires a local notification later (minutes to hours), and the in-app "Requests" tab is always correct on the next launch.
4. Set the expectation in copy: "Usually ready in a few minutes. We'll notify you when your phone checks in."

---

## 6. Navidrome rescan from the client [src][live]
- `server/subsonic/api.go` L181: `h(r.With(adminOnly), "startScan", api.StartScan)`. It is the same in v0.64.2 (L180). Live as a non-admin: `{"status":"failed","error":{"code":50,"message":"User is not authorized for the given operation"}}`. `getScanStatus` is **not** admin-only (live 200 for a non-admin).
- SSE `/api/events` (with `?jwt=`) is mounted when `DevActivityPanel` is true (the default, `conf/configuration.go` L1122). `broker.shouldSend` broadcasts server-originated `scanStatus` and `refreshResource` events to every user, so non-admin clients can watch for scan completion.
- Defaults (`conf/configuration.go` L1062–1066, `consts.go` L112, L1147):
  - `Scanner.Enabled=true`
  - `Scanner.Schedule="0"` (periodic scan off)
  - `Scanner.WatcherWait=5s` (setting it to `0` disables the watcher, `cmd/root.go` L258)
  - `Scanner.ScanOnStartup=true`
  - `DevSelectiveWatcher=true`, so the watcher scans only the changed folders (`scanner/watcher.go` L104)
- The watcher uses `rjeczalik/notify` (inotify/FSEvents), which does not see changes on most NFS, SMB or FUSE mounts.
- **Server-to-server rescan with no backend: Lidarr's built-in "Subsonic" Connect** (`NzbDrone.Core/Notifications/Subsonic`). On `OnReleaseImport` it calls `GET /rest/startScan?u=&p=&c=Lidarr&v=1.15.0` when `UpdateLibrary=true`. That is a full-library incremental scan, with no `target`.
  - The admin's app can provision it via `POST /api/v1/notification` (`implementation: "Subsonic"`) with a dedicated Navidrome **admin** account.
  - **Leave "Notify with Chat Message" OFF.** Navidrome answers `addChatMessage` with HTTP 410 (`api.go` L236). `Notify()` catches only `SocketException`, so with Notify on, the 410 would throw before `Update()` runs and the rescan would be skipped [src inference].
- Strategy: the watcher (default) + Lidarr Subsonic Connect (belt and braces) + an admin device calling `startScan?target=<lib>:<folder>` when it runs. Non-admin clients only *observe* (`getScanStatus`, SSE, or `search3` polling for the MBID).

---

## 7. Lidarr completion tracking: polling plan [src]
The Webhook connection needs an HTTP receiver, so it is useless here. The Subsonic and push Connect types still help (see §5 and §6). Per active request, while the app runs:
1. `GET /api/v1/queue/status` (`QueueStatusController`): a cheap "anything moving?" check, every 10–30 s.
2. `GET /api/v1/queue?includeAlbum=true&pageSize=200` (`QueueController.cs` L132): progress = `1 − sizeleft/size`, `trackedDownloadState`, `status`, `errorMessage`.
3. `GET /api/v1/history/since?date=<lastSeen>&includeAlbum=true` (`HistoryController.cs` L99): look for `grabbed`, `downloadImported`/`trackFileImported` (done), `albumImportIncomplete`, `downloadFailed`, `importFailed`.
4. Confirm the file: `GET /api/v1/album?foreignAlbumId=<rg>` (`AlbumController.cs` L91–122), then `GET /api/v1/track?albumId=` and check `hasFile` on `foreignRecordingId == <rec MBID>`.
5. Confirm it is playable: Navidrome `search3` by title/artist and match `musicBrainzId`/`isrc` (or `getScanStatus` → SSE). Only then mark it "Ready".
6. "Nothing found": `AlbumSearch` completes, the queue stays empty, and the album is still in `/wanted/missing`. Show "Still looking", because Lidarr's RSS sync keeps trying.

The web app cannot use SignalR (no CORS on the hub, §1). Native apps may use `/signalr/messages?access_token=<key>` as an optimisation, and only when they hold the key.

---

## Open items / unverified
- Chrome LNA details come from secondary sources. Re-check on chromestatus and test Safari and Firefox behaviour.
- MusicKit: `\.isrc` matching, and tvOS/macOS preview playback plus authorization UX. Needs a device test with Xcode 27.
- `BGContinuedProcessingTask` suitability for "waiting on a remote download".
- Exact behaviour of `initialize.json` with `AuthenticationRequired=DisabledForLocalAddresses` and Forms auth. Only the fresh-install `none` mode was live-tested; the LAN-bypass path was read from source.
- Navidrome playlist comment size limits (none found in code; not stress-tested).
- SkyHook text-search health fluctuates. Today's live success does not close #5498.
- The nginx `auth_request` gatekeeper (§2 b3) is a design, not tested.
