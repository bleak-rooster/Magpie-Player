# ListenBrainz Discovery, Non-Library Search and 30-Second Previews

Research date: 2026-10-26. Scope: native Apple apps + Docker web app on top of Navidrome, with Lidarr and ListenBrainz (LB).
Everything marked **(verified)** was exercised live with `curl` on the research date; the rest comes from the official docs linked inline.

---

## TL;DR

| Need | Source | Auth | Notes |
|---|---|---|---|
| Scrobbling | **Navidrome server-side** (Subsonic `scrobble`) | Per-user LB token stored in Navidrome | Client must NOT also submit to LB |
| "Made for you" playlists | LB `GET /1/user/{u}/playlists/createdfor` + `GET /1/playlist/{mbid}` | none (public) | Daily Jams, Weekly Jams, Weekly Exploration, Top Discoveries/Missed of year |
| Personal recs | LB `GET /1/cf/recommendation/user/{u}/recording` | none | up to 1000 recording MBIDs with score |
| Radio / smart mixes | LB `GET /1/explore/lb-radio?prompt=&mode=` | **Token now required** (verified 401 without) | Prompt language: `artist:`, `tag:`, `stats:`, `recs:`, `country:`, `collection:`, `playlist:` |
| Similar artists / tracks | `labs.api.listenbrainz.org/similar-artists/json`, `/similar-recordings/json` | none | Same data Navidrome's LB agent already uses |
| Artist top tracks / albums | LB `/1/popularity/top-recordings-for-artist/{mbid}`, `/top-release-groups-for-artist/{mbid}` | none | Includes `caa_release_mbid`, length, tags |
| New releases | LB `/1/user/{u}/fresh_releases` (followed/listened artists) and `/1/explore/fresh-releases/` (sitewide) | none | ±90 days |
| Metadata for MBIDs | LB `/1/metadata/recording` (includes **ISRCs**) | none | Batch POST; avoids MusicBrainz 1 req/s |
| Text search, non-library | MusicBrainz `/ws/2/{artist,release-group,recording}?query=` | UA header | 1 req/s per IP; server-side cache |
| Artwork | Cover Art Archive (`caa_release_mbid` from LB) | none | No rate limit; 250/500/1200 thumbs |
| 30 s preview | **Deezer** `/track/isrc:{ISRC}` primary, **iTunes Search** fallback | none | Deezer ToS non-commercial; iTunes ToS requires store badge + "courtesy of iTunes" |

---

## 1. ListenBrainz core: auth, submission, rate limits

Docs: <https://listenbrainz.readthedocs.io/en/latest/users/api/index.html>, <https://listenbrainz.readthedocs.io/en/latest/users/api/core.html>, <https://listenbrainz.readthedocs.io/en/latest/users/json.html>

### Auth
- Each user gets a **user token** at <https://listenbrainz.org/settings/>.
- Header: `Authorization: Token <user-token>`.
- Check it with `GET https://api.listenbrainz.org/1/validate-token`, which returns `{"code":200,"message":"Token valid.","valid":true,"user_name":"..."}`.
- Production base URL: `https://api.listenbrainz.org` (HTTPS only).

### Rate limits (verified)
- Every response carries `X-RateLimit-Limit`, `X-RateLimit-Remaining`, `X-RateLimit-Reset-In` and `X-RateLimit-Reset`. Live values were **limit 30 per ~10 s window**.
- The docs ask that each client "never make more than ONE call per second". Going over the limit returns `429`. On a 429, back off for `X-RateLimit-Reset-In` seconds; Navidrome's LB client does exactly this.
- **New since 2025/26 (verified):** some "expensive" endpoints now return `401 "Due to bad actors and AI scrapers ... you need to provide an Auth token for this endpoint"`. Confirmed on `/1/explore/lb-radio` and `/1/metadata/lookup`. Plan to send the user's token on every LB call; it is harmless where it isn't needed.

### `POST /1/submit-listens`
`listen_type` is one of:

| type | when | `listened_at` | payload size |
|---|---|---|---|
| `playing_now` | track starts | **must be omitted** | exactly 1 |
| `single` | track counts as a listen | required (UTC epoch s) | exactly 1 |
| `import` | bulk/offline backfill | required | ≤1000 listens, ≤10 MB, each ≤10 KB |

- Required fields: `track_metadata.artist_name` and `track_metadata.track_name` (plus `listened_at` for single/import). `release_name` is optional but recommended.
- Listen threshold: submit once the user has played **half the track or 4 minutes, whichever is lower**.
- `listened_at` must be ≥ 1033430400 (Oct 2002).
- `additional_info` (all optional) can carry:
  - IDs: `recording_mbid`, `release_mbid`, `release_group_mbid`, `artist_mbids[]`, `track_mbid`, `work_mbids[]`, `isrc`, `spotify_id`
  - track details: `tracknumber`, `duration_ms` (or `duration` in s), `duration_played`, `tags[]`, `label`
  - client info: `media_player`, `media_player_version`, `submission_client`, `submission_client_version`, `original_submission_client`
  - service info: `music_service` (domain, e.g. `navidrome.example.com`), `music_service_name`, `origin_url`

```http
POST https://api.listenbrainz.org/1/submit-listens
Authorization: Token 8f3c...
Content-Type: application/json

{
  "listen_type": "single",
  "payload": [{
    "listened_at": 1793012000,
    "track_metadata": {
      "artist_name": "Portishead",
      "track_name": "Glory Box",
      "release_name": "Dummy",
      "additional_info": {
        "recording_mbid": "64e2d046-ccb4-41ef-b2f9-3bc38a7010e7",
        "release_mbid": "76df3287-6cda-33eb-8e9a-044b5e15ffdd",
        "artist_mbids": ["8f6bd1e4-fbe1-4f50-aa9b-94c450ec0f11"],
        "duration_ms": 305000,
        "tracknumber": 11,
        "media_player": "NaviPlayer iOS",
        "submission_client": "NaviPlayer",
        "submission_client_version": "1.0.0"
      }
    }
  }]
}
```

### Should the client scrobble or rely on Navidrome? **Rely on Navidrome.**
Source reviewed: `navidrome/navidrome` `adapters/listenbrainz/{agent,client}.go`, `conf/configuration.go` (master, 2026-10).

- Navidrome has a built-in LB scrobbler. Each user enables it under *Personal → Scrobble to ListenBrainz* and pastes their token; Navidrome stores it as `ListenBrainzSessionKey`.
- Server config: `ListenBrainz.Enabled=true` (the default) and `ListenBrainz.BaseURL`.
- When a Subsonic client calls `/rest/scrobble?id=..&submission=false`, Navidrome sends `playing_now`. With `submission=true` (and optional `time=<ms epoch>` for offline plays), it sends `single`.
- The listen Navidrome builds already contains `submission_client=Navidrome`, the version, `tracknumber`, `artist_names`, `artist_mbids`, `recording_mbid`, `release_mbid`, `release_group_mbid` and `duration_ms`. All of these come from the tags in the file.
- Navidrome also feeds Last.fm, keeps its own play counts and scrobble history (`EnableScrobbleHistory`), and applies per-user scrobble filters (v0.64+). It retries on 429.

**Rule:** the app only calls Subsonic `scrobble`, never LB `submit-listens`. Two writers to LB would double-count, because LB does not dedupe on near-identical timestamps.
- In the app, show "ListenBrainz scrobbling: on/off". You can read the state from Navidrome's native API (`/api/user` properties). Deep-link the user to Navidrome's personal settings to change it.
- The app may still keep its **own read-only copy of the LB token** (Keychain on Apple, server-side secret in the web app) for discovery calls (`lb-radio`, `metadata/lookup`, feedback). Validate it with `/1/validate-token` to get the LB username.
- Offline playback: queue plays locally and replay them as `scrobble?submission=true&time=...` against Navidrome when back online, oldest first. Navidrome forwards them with the original timestamp.
- Previews of non-library tracks are **not scrobbled**. They aren't real listens and Navidrome has no track id for them. An optional "Previewed" history can live locally.
- Love/hate: Navidrome's `star` currently goes to Last.fm, but its LB agent does **not** sync loves. To mirror loves, the app should call LB feedback directly. That is safe because it is idempotent per recording.

### Feedback (love/hate)
Docs: <https://listenbrainz.readthedocs.io/en/latest/users/api/recordings.html>
```http
POST /1/feedback/recording-feedback       (Token)
{"recording_mbid": "13dd61c7-ce73-4e97-9f0c-9f0e53144411", "score": 1}   // 1 love, -1 hate, 0 clear
GET  /1/feedback/user/{user}/get-feedback?score=1&count=100&offset=0&metadata=true
POST /1/feedback/user/{user}/get-feedback-for-recordings  {"recording_mbids":[...]}   // GET form: keep <=75 ids
POST /1/recommendation/feedback/submit    (Token) {"recording_mbid": "...", "rating": "love|like|dislike|hate|bad_recommendation"}
```
- Use `recording-feedback` for the heart button.
- Use `recommendation/feedback` for "not for me" on recommended rows. That feeds the CF model.

---

## 2. Discovery endpoints

### 2.1 Collaborative-filtering recommendations (verified)
`GET /1/cf/recommendation/user/{user}/recording?count=100&offset=0` (no auth)
```json
{"payload":{"count":2,"entity":"recording","last_updated":1787653608,
 "mbids":[{"recording_mbid":"5b44c236-cbb0-4e54-a8b1-c344b76e1b8f","score":0.083,"latest_listened_at":"2025-10-10T21:01:44.000Z"},
          {"recording_mbid":"72d364a2-3cfc-432d-8430-1b45efb99bca","score":0.080,"latest_listened_at":"2025-10-14T12:59:39.000Z"}],
 "model_id":"listenbrainz-recommendation-model-...","offset":0,"total_mbid_count":1000,"user_name":"rob"}}
```
- `latest_listened_at` is null when the user has never played the track. That gives two splits for free:
  - "Your favourites, rediscovered" (listened before)
  - "Discover" (`latest_listened_at == null`)
- The response has only MBIDs. Hydrate them with `POST /1/metadata/recording` (see 2.8).
- Results are regenerated roughly weekly. A user with too few listens gets `204`.

### 2.2 "Created for you" playlists (verified)
`GET /1/user/{user}/playlists/createdfor?count=25&offset=0` (public, no auth). Returns JSPF headers without tracks.

Playlists seen for a real user (`additional_metadata.algorithm_metadata.source_patch` gives the type):

| Title pattern | `source_patch` | Cadence |
|---|---|---|
| `Daily Jams for {u}, YYYY-MM-DD Day` | `daily-jams` | daily, `expires_at` ≈ 2 weeks |
| `Weekly Jams for {u}, week of …` | `weekly-jams` | weekly (Monday) |
| `Weekly Exploration for {u}, week of …` | `weekly-exploration` | weekly; tracks not heard before |
| `Top Discoveries of YYYY for {u}` | `top-discoveries-for-year` / `top-discoveries-of-YYYY` | yearly (Year in Music) |
| `Top Missed Recordings of YYYY for {u}` | `top-missed-recordings-of-YYYY` | yearly |
| `Top Recordings of YYYY` / `Top New Releases in YYYY` | `top-recordings-for-year` / `top-new-recordings-for-year` | yearly |
| `LB Radio for …` | `lb-radio` | user-saved radio |

Fetch the tracks with `GET /1/playlist/{playlist_mbid}` (also `/xspf`). Each track looks like this (verified):
```json
{"title":"Versions","creator":"Moderat","album":"II","duration":310226,
 "identifier":["https://musicbrainz.org/recording/ff1e4cc1-9049-4e48-bbdf-d5f3ade6d110"],
 "extension":{"https://musicbrainz.org/doc/jspf#track":{
   "added_by":"troi-bot",
   "artist_identifiers":["https://musicbrainz.org/artist/7754905b-8bf7-48e2-935a-03d566fec464"],
   "additional_metadata":{"artists":[{"artist_credit_name":"Moderat","artist_mbid":"7754905b-...","join_phrase":""}],
                          "caa_id":32287311915,"caa_release_mbid":"fdf5eafa-cac1-45b2-8118-33156f3b5219"}}}}
```
- The recording MBID is the last path segment of `identifier[0]`.
- `caa_release_mbid` gives the artwork URL directly: `https://coverartarchive.org/release/{caa_release_mbid}/front-500`.
- Daily Jams has 50 tracks.
- To show the "latest Weekly Jams", sort by `date` and pick the newest per `source_patch`.

### 2.3 LB Radio (prompt playlists)
Endpoint: `GET /1/explore/lb-radio?prompt=<urlencoded>&mode=easy|medium|hard`. **Requires `Authorization: Token`** (verified 401 without).

Docs: <https://listenbrainz.readthedocs.io/en/latest/users/api/misc.html>, prompt reference <https://troi.readthedocs.io/en/latest/lb_radio.html>

**Grammar:** `entity:values:weight:options`. Join several terms with spaces. The streams are interleaved in proportion to `weight` (default 1).

| Entity | Meaning | Options |
|---|---|---|
| `artist:(Name or MBID)` | artist + similar artists | `nosim` (only that artist) |
| `tag:(a,b)` / `#tag` | recordings with tags | `and` (default) / `or`, `nosim` |
| `stats:user` | user's top recordings | `week, month, quarter, half_yearly, year, all_time, this_week, this_month, this_year` |
| `recs:user` | user's CF recs | `listened` / `unlistened` |
| `country:(Name)` | artists from a country | - |
| `collection:MBID` | MusicBrainz collection | modes ignored |
| `playlist:MBID` | LB playlist | modes ignored |

**Modes:** `easy` keeps closest to the prompt (popular, strongly similar). `medium` reaches further. `hard` digs into the long tail.

Names with spaces or non-Latin characters need parentheses: `artist:(Мумий Тролль)`, `tag:(trip hop)`.

Examples:
```
artist:(Portishead)                                   -> "Portishead Radio" (Spotify-style artist radio)
artist:(Portishead)::nosim                            -> "This is Portishead"
artist:(pretty lights):3:easy tag:(trip hop):2 artist:(morcheeba)::nosim
tag:(rock,pop)::or
stats:{user}::month                                   -> "On Repeat"
recs:{user}::unlistened                               -> "Discover mix"
stats:{user}::all_time recs:{user}::unlistened        -> "Daily Mix"-style blend
country:(Iceland)
```
The response is a JSPF playlist in the same shape as 2.2 (`payload.jspf`) plus `payload.feedback` messages, for example when an artist isn't found.

### 2.4 Similar artists / similar recordings (labs API, verified, no auth)
Dataset hoster index: <https://labs.api.listenbrainz.org/>. Every endpoint has an HTML viewer and a `/json` variant.

```
GET https://labs.api.listenbrainz.org/similar-artists/json
    ?artist_mbids=8f6bd1e4-fbe1-4f50-aa9b-94c450ec0f11
    &algorithm=session_based_days_7500_session_300_contribution_5_threshold_10_limit_100_filter_True_skip_30
-> [{"artist_mbid":"10adbe5e-...","name":"Massive Attack","type":"Group","score":7781,"reference_mbid":"8f6b..."},
    {"name":"Radiohead","score":7045}, {"name":"Björk","score":4936}, {"name":"Air"}, {"name":"Tricky"}, ...]

GET https://labs.api.listenbrainz.org/similar-recordings/json
    ?recording_mbids=13dd61c7-ce73-4e97-9f0c-9f0e53144411
    &algorithm=session_based_days_9000_session_300_contribution_5_threshold_15_limit_50_skip_30
-> [{"recording_mbid":"14e9b000-...","recording_name":"Black Hole Sun","artist_credit_name":"Soundgarden",
     "release_mbid":"d7b0...","caa_release_mbid":"76c4...","caa_id":45124521191,"score":523}, ...]
```
- Other algorithms listed by the viewer: `session_based_days_1825_…_contribution_3…` (recent taste) and `session_based_days_75_…` (very recent).
- Navidrome's own defaults are `consts.DefaultListenBrainzArtistAlgorithm` / `DefaultListenBrainzTrackAlgorithm`. Mirror those for consistency.
- Other useful labs endpoints:
  - `tag-similarity`, `bulk-tag-lookup`
  - `artist-country-code-from-artist-mbid`
  - `spotify-id-from-mbid`, `apple-music-id-from-mbid`, `soundcloud-id-from-mbid`. These are useful for "Open in…" links and potentially for preview matching (see section 5).
- The labs API is explicitly experimental. Treat it as best-effort, with a cache and a fallback.

**Navidrome already uses these.** Agents default to `deezer,lastfm,listenbrainz`. Its LB agent implements `GetSimilarArtists`, `GetArtistTopSongs` and `GetSimilarSongsByTrack`, which back these Subsonic endpoints:
- `getArtistInfo2` (`similarArtist`, *library-only* unless `includeNotPresent=true`)
- `getTopSongs`
- `getSimilarSongs2`

For **in-library** radio and similar artists, call Navidrome first. Call LB directly only to get the *not-in-library* remainder.

### 2.5 Popularity (verified, no auth)
Docs: <https://listenbrainz.readthedocs.io/en/latest/users/api/popularity.html>
```
GET  /1/popularity/top-recordings-for-artist/{artist_mbid}
  -> [{recording_mbid, recording_name, artist_name, artist_mbids, artists[], release_mbid, release_name,
       caa_id, caa_release_mbid, length, tags[{tag,count,genre_mbid}], release_color, total_listen_count, total_user_count}]
GET  /1/popularity/top-release-groups-for-artist/{artist_mbid}
POST /1/popularity/recording   {"recording_mbids":[...]}  -> listen/user counts
POST /1/popularity/artist      {"artist_mbids":[...]}
```
- Use these for the "Popular" section on artist pages, for ranking MusicBrainz search hits (2.x / section 4), and for choosing the canonical recording among duplicates.

### 2.6 Fresh releases (verified)
```
GET /1/user/{user}/fresh_releases?days=30&past=true&future=true&sort=release_date
    # releases from artists the user listens to; days max 90
GET /1/explore/fresh-releases/?days=14&sort=release_date&release_date=YYYY-MM-DD
    # sitewide
-> {"payload":{"releases":[{"artist_credit_name","artist_mbids[]","release_name","release_mbid",
     "release_group_mbid","release_group_primary_type":"Album|Single|EP","release_date","caa_release_mbid",
     "caa_id","listen_count","release_tags"[]}]}}
```
- **Followed artists for "New releases from artists you follow":** LB's "follow" is user-to-user, not artist. Define "followed artists" as the union of:
  - artists in Lidarr marked *monitored*
  - artists starred in Navidrome
  - top N artists from `/1/stats/user/{u}/artists?range=half_yearly`
- Then filter sitewide and user fresh releases by `artist_mbids`.
- Lidarr's calendar (`GET /api/v1/calendar?start=&end=&unmonitored=false`) covers monitored artists authoritatively.

### 2.7 Statistics
Docs: <https://listenbrainz.readthedocs.io/en/latest/users/api/statistics.html>
```
GET /1/stats/user/{u}/{artists|releases|release-groups|recordings}?range=month&count=25&offset=0
GET /1/stats/user/{u}/listening-activity | daily-activity | artist-map | era-activity | genre-activity
GET /1/stats/sitewide/{artists|recordings|release-groups}?range=week     -> "Trending on ListenBrainz"
```
- `range` takes `this_week, this_month, this_year, week, month, quarter, year, half_yearly, all_time`.
- `204` means not computed yet (verified on a user with sparse recent data). The UI must handle empty.

### 2.8 Metadata (verified)
Docs: <https://listenbrainz.readthedocs.io/en/latest/users/api/metadata.html>
```
GET  /1/metadata/recording/?recording_mbids=a,b,c&inc=artist tag release
POST /1/metadata/recording/   {"recording_mbids":[...], "inc":"artist release"}
GET  /1/metadata/release_group/?release_group_mbids=...&inc=artist release
GET  /1/metadata/artist/?artist_mbids=...&inc=...
GET  /1/metadata/lookup/?artist_name=&recording_name=&release_name=&metadata=true   (Token)
POST /1/metadata/lookup/      [{"artist_name":..,"recording_name":..,"release_name":..}]  (Token)
```
The recording response includes `recording.isrcs[]`, `length`, `first_release_date`, release name/MBID/`caa_release_mbid`, and artist rels such as `"free streaming": "https://www.deezer.com/artist/407"`. Verified for NIN "Closer": `isrcs:["USIR19400529"]`.

**This is the cheapest way to get ISRCs for preview matching:** one batched LB call instead of N MusicBrainz calls at 1 req/s.

---

## 3. Mapping LB recommendations onto the Navidrome library

**Navidrome IDs**
- OpenSubsonic `Child.musicBrainzId` is the **recording MBID** (from the `MUSICBRAINZ_TRACKID` tag).
- `Child.isrc[]` holds ISRCs.
- Album `musicBrainzId` is the **release MBID**. Artist `musicBrainzId` is the artist MBID.
- Navidrome's native API (`/api/song`) also exposes `mbzRecordingID`, `mbzReleaseGroupID` and `mbzAlbumID`.

### Build a local MBID index (server side in the Docker app, on-device on Apple)
1. Sync the full song list incrementally. Use the native `/api/song?_start&_end` or Subsonic `search3?query=""&songCount=500&songOffset=n` (OpenSubsonic allows an empty query). Re-sync deltas using `getIndexes`/`ifModifiedSince` or the scan `lastScan` time.
2. Index the songs in four ways:
   - `recordingMbid → songId`
   - `isrc → songId`
   - `releaseGroupMbid → albumId`, plus `releaseMbid → albumId`
   - `normalize(artist)+normalize(title) → songId[]`

### Resolution cascade for each LB item (recording MBID + names from JSPF/metadata)
| Step | Match | Confidence |
|---|---|---|
| 1 | `recording_mbid` exact | 1.0 |
| 2 | Any ISRC of the LB recording (from `/1/metadata/recording`) ∈ local ISRCs | 0.95 |
| 3 | Same artist MBID **and** normalized title equal **and** \|duration Δ\| ≤ 3 s | 0.9 |
| 4 | Normalized artist + title equal (strip feat., "Remaster", punctuation, diacritics; case-fold) and duration Δ ≤ 5 s | 0.8 |
| 5 | Same as 4 without duration | 0.6. Treat as in-library only if unambiguous; else "possible match" |
| — | nothing | **not in library**, so becomes a discoverable item |

- Duplicate recordings are common. A MusicBrainz search for "Glory Box" by Portishead returns 69 recordings: live versions, remasters, compilations. That is why steps 2–4 matter.
- Files are often tagged with a different recording MBID than the one LB recommends.

### Item model in the app
```ts
type DiscoverTrack = {
  recordingMbid: string; title: string; artists: {name, mbid}[]; releaseMbid?: string;
  caaReleaseMbid?: string; durationMs?: number; isrcs?: string[];
  library?: { songId: string; confidence: number };        // present => play from Navidrome
  preview?: { provider: 'deezer'|'itunes'; url: string; expiresAt?: number; externalUrl: string; confidence: number };
  lidarr?: { artistMonitored: boolean; albumMbid?: string; status: 'missing'|'wanted'|'downloading'|'available' };
};
```
**Playlist behaviour.** Library tracks play in full; non-library tracks play the preview. Offer two modes:
- "Library only": skip misses, like Spotify's "hide unplayable".
- "Mixed": show previews inline with an "Add to Lidarr" action.

Cache LB results server-side (Docker) with these TTLs:

| Data | TTL |
|---|---|
| CF recs | 24 h |
| created-for playlists | 6 h |
| popularity / similar | 7 d |
| metadata | 30 d |

---

## 4. Metadata search for non-library items

### MusicBrainz WS/2
Docs: <https://musicbrainz.org/doc/MusicBrainz_API/Search>, rate limits: <https://musicbrainz.org/doc/MusicBrainz_API/Rate_Limiting>
- Format: `GET https://musicbrainz.org/ws/2/{artist|release-group|recording}/?query=<lucene>&limit=1..100&offset=&fmt=json`. Add `dismax=true` to auto-escape raw user input.
- **Rate limit:** on average 1 req/s **per IP**. Going over it gets `503` for *all* requests from that IP. There is also a global cap of 300 req/s.
- **User-Agent is mandatory and meaningful.** Format: `NaviPlayer/1.0.0 ( https://github.com/… or contact@… )`. Generic UAs (python-urllib, Java, blank) are throttled harder.
- Implication: route all MB traffic through the **Docker backend** (or a shared server component) with a single token bucket at 1 req/s, request coalescing, and aggressive caching.
  - Native Apple apps should not hit MB directly. Many users behind one NAT would collide, and a single device typing fast exceeds 1 req/s.
  - If there is no server component, debounce search by ≥400 ms and fire at most 1 req/s.
- Lucene fields:
  - artist: `artist, alias, arid, type, country, tag, begin, end`
  - release-group: `releasegroup, rgid, primarytype (Album|Single|EP), secondarytype, artist, arid, status, tag`
  - recording: `recording, rid, isrc, artist, arid, dur, release, primarytype, status, tag, country`
- Example queries (verified):
```
/ws/2/artist/?query=artist:(portishead)&limit=5&fmt=json
/ws/2/release-group/?query=releasegroup:(dummy) AND arid:8f6bd1e4-fbe1-4f50-aa9b-94c450ec0f11 AND primarytype:album&fmt=json
/ws/2/recording/?query=recording:"Glory Box" AND artist:Portishead AND status:official AND NOT secondarytype:live&limit=10&fmt=json
/ws/2/recording/?query=isrc:GBAHT1600302&fmt=json
/ws/2/recording/{mbid}?inc=isrcs+artist-credits+releases&fmt=json     (lookup)
/ws/2/isrc/{isrc}?fmt=json
```
- **Ranking tip:** MB's `score` is pure text relevance. Rerank recording hits by:
  1. LB popularity (`POST /1/popularity/recording`)
  2. official status
  3. no live/compilation secondary types

  Then collapse duplicates by (artist credit, normalized title).
- Search UX: show three sections (Artists / Albums / Songs). In each, list library results first (Navidrome `search3`), then "Not in your library" results from MB, minus anything resolved via section 3.

### Cover Art Archive
Docs: <https://musicbrainz.org/doc/Cover_Art_Archive/API>
- `https://coverartarchive.org/release/{mbid}/front-250|500|1200` returns a 307 to archive.org.
- `https://coverartarchive.org/release-group/{rgid}/front-500` works for album search results.
- No rate limiting is documented. Still cache it, and proxy it through the Docker backend so the web app doesn't leak user IPs to archive.org.
- Many LB payloads already include `caa_release_mbid` and `caa_id`. Use them directly; they avoid a 404 when that particular release has no art.
- Artist images: CAA has none. Options:
  - Lidarr lookup `images` (fanart.tv-sourced)
  - Deezer `picture_xl`, subject to Deezer ToS; artwork is lower risk than audio
  - Navidrome's own `getArtistInfo2` image (it uses Deezer/Last.fm agents)

### Lidarr lookup vs MusicBrainz
| | MusicBrainz direct | Lidarr `/api/v1/search`, `/artist/lookup?term=`, `/album/lookup?term=` |
|---|---|---|
| Auth | UA only | `X-Api-Key` (the user's Lidarr) |
| Entities | artist, release-group, release, **recording** | artist, album (release-group). **No track search** |
| Data | raw MB | MB via Lidarr's SkyHook (`api.lidarr.audio`) plus fanart images, overview/bio, genres, ratings, `foreignArtistId`/`foreignAlbumId` = MB IDs |
| Rate limit | 1 req/s per IP | none locally; SkyHook is shared and has had multi-week outages (2025 cache rebuild, Lidarr GH #5498) |
| Extra | — | Already knows monitored/added state; exact lookup with `term=lidarr:<mbid>`; results feed straight into `POST /api/v1/artist` / `POST /api/v1/album` |

**Recommendation.**
- Use Lidarr lookup for the **Artists** and **Albums** search sections, and for the "Add to Lidarr" flow. It has richer artwork and bios, it already knows what is monitored, and it doesn't use your MB budget.
- Use MusicBrainz, rate-limited and cached, for **Songs** search and as the fallback when Lidarr or SkyHook fails or Lidarr isn't configured.
- Use LB metadata for anything keyed by MBID.

---

## 5. 30-second previews

### 5.1 Deezer public API (primary)
- Base `https://api.deezer.com`. **No auth** for catalog reads.
- Quota is commonly cited as **50 requests / 5 s per IP**. This appears in Deezer developer FAQ material; it is not in the ToS text. Exceeding it returns an error JSON `{"error":{"type":"Exception","message":"Quota limit exceeded","code":4}}`.
- Endpoints (verified):
```
GET /track/isrc:USIR19400529          -> {id,title,isrc,duration,rank,preview:"https://cdnt-preview.dzcdn.net/...mp3?hdnea=exp=...",
                                           link, album{cover_xl}, artist{name}, available_countries[] ...}
GET /album/upc:042282855329           -> album incl. tracks (preview per track)
GET /search?q=artist:"X" track:"Y" album:"Z" dur_min=..&dur_max=..   (advanced search)
GET /search/artist?q=..   /artist/{id}/top?limit=5   /artist/{id}/albums
```
- **Preview URLs are signed and expire.** `hdnea=exp=…` was about **15 minutes** after the request (verified). Store the **Deezer track id** and re-resolve `/track/{id}` right before playback. Never persist the MP3 URL.
- Audio: 30 s MP3, 128 kbps.
- `available_countries` is region-dependent. Check the user's storefront and treat `readable:false` as no preview.
- Observation: in our test environment the free-text `/search` returned odd or empty results while `/track/isrc:` worked perfectly. Search quality varies by egress region. **Prefer ID-based lookups (ISRC/UPC).**
- **ToS** (<https://developers.deezer.com/termsofuse>, <https://developers.deezer.com/guidelines>):
  - Use is "strictly limited for a non-commercial purpose", with no revenue directly or indirectly.
  - Comply with the Trademark Guidelines (Deezer logo/attribution). A "Listen on Deezer" link to `link` is the conventional attribution.
  - No local or offline storage of audio.
  - Do not circumvent DRM.
  - Deezer may revoke access at any time.

  For a free, self-hosted, open-source player this is acceptable. If the product is ever monetised (paid app, subscription, ads), **Deezer previews must be dropped or licensed.**

### 5.2 iTunes Search API (fallback)
- Docs: <https://performance-partners.apple.com/search-api>
- `GET https://itunes.apple.com/search?term=portishead+glory+box&entity=song&limit=5&country=US` returns `previewUrl` (AAC `.m4a`, about 30 s), `trackTimeMillis`, `artworkUrl100` (rewrite `100x100bb` to `600x600bb`), `trackViewUrl` (music.apple.com) and `collectionId`. Verified working.
- `GET https://itunes.apple.com/lookup?upc=042282855329&entity=song` works (verified).
- **ISRC lookup: not supported** (`lookup?isrc=` returned 0 results, verified). ISRC lookup needs the paid-developer **Apple Music API**: `GET https://api.music.apple.com/v1/catalog/{sf}/songs?filter[isrc]=…` with a developer token. On the native apps, MusicKit can do this with the team's key.
- Rate limit: about **20 calls/min** per IP (Apple's wording: "subject to change").
- **ToS:**
  - Content may be used "only to promote store content and not for entertainment purposes".
  - Previews must be "proximate to a store badge" (Listen on Apple Music / iTunes badge linking to `trackViewUrl`).
  - Previews must be "streamed only, and not downloaded, saved, cached, or synchronized".
  - Show the attribution "provided courtesy of iTunes".
- Bonus: labs `apple-music-id-from-mbid` maps MBID to an Apple Music track id, which can then be looked up with `lookup?id=`.

### 5.3 Spotify: not viable
On 2024-11-27 Spotify removed `preview_url` (it returns `null`) for apps created after that date and for dev-mode apps without an approved extension. Also removed: Related Artists, Recommendations, Audio Features/Analysis, Featured/Category playlists and editorial playlists. Source: <https://developer.spotify.com/blog/2024-11-27-changes-to-the-web-api>. A new app cannot get previews. Do not build on it.

### 5.4 YouTube: not viable
The YouTube API ToS forbids separating audio from video, background playback outside the official player, and caching. Embedding the IFrame player for audio-only "previews" violates the terms, and scraping (yt-dlp) is a clear ToS violation. Use YouTube at most as an external "Watch on YouTube" link, built from MB/LB artist rels.

### 5.5 Matching strategy (MusicBrainz recording → preview)
```
input: recordingMbid, title, artist(s), durationMs, releaseMbid?, isrcs?
1. ISRCs  <- isrcs ?? LB POST /1/metadata/recording (batch)  ?? MB /ws/2/recording/{mbid}?inc=isrcs
2. for isrc in isrcs: Deezer /track/isrc:{isrc}
      -> accept if readable && preview && |dur Δ| <= 5s              confidence 0.95
3. if release known: MB release barcode (UPC) -> Deezer /album/upc:{upc} -> pick track by position/title  0.9
4. Deezer advanced search  q=artist:"A" track:"T" dur_min=d-5 dur_max=d+5
      -> score candidates (below), accept >= 0.75
5. labs apple-music-id-from-mbid -> iTunes lookup?id=  -> previewUrl                          0.9
6. iTunes search term="A T" entity=song country=<user storefront> -> score, accept >= 0.75
7. else: no preview -> show "Open in MusicBrainz / Add to Lidarr"
```
Candidate score, all components in 0..1, weights in brackets:
- title similarity (×0.45): normalized Jaro-Winkler after stripping `(feat…)`, `- Remaster…`, `(Live…)`. A *mismatch* on live/remix/acoustic keywords gives −0.3.
- artist similarity (×0.35): best pairwise over artist credits.
- duration (×0.15): 1 if Δ ≤ 2 s, linear to 0 at 15 s.
- album match bonus (×0.05).

Thresholds:
- ≥0.9: auto-play
- 0.75–0.9: play, with a small "preview may differ" hint
- <0.75: hide

Persist only (provider, provider_track_id, confidence, matched_at). Keep it 30 days for Deezer ids and 7 days for iTunes. Re-fetch the actual preview URL at play time.

### 5.6 Delivery architecture and ToS constraints
**Do not proxy or cache the audio.** Both Deezer ("no local/offline storage of audio") and Apple ("streamed only, not downloaded, saved, cached") forbid it. The Docker backend should only resolve metadata and return the signed CDN URL; the client streams it directly (`<audio src>` in web, `AVPlayer` on Apple).
- The Docker backend *can* proxy the JSON API calls (allowed, and needed for CORS on `api.deezer.com`, which doesn't send CORS headers for XHR) and cache JSON metadata.
- Proxying the MP3/M4A bytes is legally grey under both ToS, and with Deezer's signed URLs it isn't needed.
- Deezer preview CDN URLs play fine in `<audio>` cross-origin. iTunes `audio-ssl.itunes.apple.com` also plays cross-origin.

**Attribution UI.** Every previewed row or player shows a source badge:
- Deezer: logo per trademark guidelines, linking to `link`.
- Apple: "Listen on Apple Music" badge linking to `trackViewUrl`, plus the "Preview provided courtesy of iTunes" text.

**Rules for previews**
- Previews never go into the play queue's scrobble path, offline downloads, or "Downloaded" storage.
- Respect the storefront country: pass `country=` to iTunes; check Deezer `available_countries`.

**Commercial risk.** Deezer's non-commercial clause and Apple's "promote store content only" clause are the two binding constraints. Apple's terms are actually satisfied by a link-out badge. If the app is ever sold or ad-supported, re-evaluate Deezer. iTunes plus a store badge is the safer long-term default, despite the weaker matching (no ISRC without the Apple Music API).

---

## 6. Recommended architecture

```
                 ┌───────────── Apple apps / Web UI ──────────────┐
                 │  Home: Made For You | Radio | New Releases      │
                 │  Search: Library | Not in library (+preview)    │
                 └──────────────▲──────────────────────────────────┘
                                │ app API (JSON)        audio: Navidrome stream / preview CDN (direct)
                 ┌──────────────┴───────────── Docker "discovery" service ─────────────┐
                 │ LB client (user token, 1 rps, 429 backoff)  | MB client (UA, 1 rps)  │
                 │ Library index (recMBID/ISRC/name→songId)    | Lidarr client (api key)│
                 │ Preview resolver (Deezer→iTunes, scores)    | JSON cache (SQLite/Redis)│
                 └──────▲────────────▲───────────────▲───────────────▲──────────────────┘
                        │            │               │               │
                 Navidrome (Subsonic/native)  ListenBrainz/labs  MusicBrainz+CAA  Lidarr / Deezer / iTunes
                 (+ scrobbling → LB)
```

**Native Apple apps.** Use the same Docker service when it is deployed. If it isn't, run a reduced on-device implementation: LB, Deezer and iTunes direct, and MB direct with a strict 1 rps limiter.

**Home sections**

| Section | Source |
|---|---|
| Daily Jams | `createdfor`, newest `daily-jams` |
| Weekly Jams | `createdfor`, newest `weekly-jams` |
| Weekly Exploration | `createdfor`, newest `weekly-exploration` |
| Discover | CF recs where `latest_listened_at == null` |
| Artist radio / "mixes" | `lb-radio` with `artist:(X)` for top-5 `stats:` artists |
| On Repeat | `stats:{u}::month` |
| Similar to {starred artist} | labs similar-artists, split into library vs Lidarr-addable |
| New releases | `fresh_releases` ∩ followed artists (Lidarr monitored ∪ Navidrome starred ∪ top artists) |
| Trending | sitewide stats `range=week` |

**Every non-library item** shows a preview (if matched) plus "Add artist/album to Lidarr". When Lidarr finishes and Navidrome rescans, the library index picks the item up and it flips to full playback.

### Key links
- LB API index: https://listenbrainz.readthedocs.io/en/latest/users/api/index.html
- LB JSON listen format: https://listenbrainz.readthedocs.io/en/latest/users/json.html
- LB playlists / JSPF: https://listenbrainz.readthedocs.io/en/latest/users/api/playlist.html , https://musicbrainz.org/doc/jspf
- LB Radio prompts: https://troi.readthedocs.io/en/latest/lb_radio.html
- LB labs: https://labs.api.listenbrainz.org/
- LB server source: https://github.com/metabrainz/listenbrainz-server
- Navidrome LB agent: https://github.com/navidrome/navidrome/tree/master/adapters/listenbrainz ; scrobbling docs https://www.navidrome.org/docs/usage/features/scrobbling/
- OpenSubsonic Child: https://opensubsonic.netlify.app/docs/responses/child/
- MusicBrainz search / rate limits: https://musicbrainz.org/doc/MusicBrainz_API/Search , https://musicbrainz.org/doc/MusicBrainz_API/Rate_Limiting
- Cover Art Archive: https://musicbrainz.org/doc/Cover_Art_Archive/API
- Lidarr API: https://lidarr.audio/docs/api/
- Deezer API / ToS / guidelines: https://developers.deezer.com/api , https://developers.deezer.com/termsofuse , https://developers.deezer.com/guidelines
- iTunes Search API: https://performance-partners.apple.com/search-api
- Spotify Nov-2024 changes: https://developer.spotify.com/blog/2024-11-27-changes-to-the-web-api
