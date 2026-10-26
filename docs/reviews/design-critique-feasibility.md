# Design critique: feasibility (data honesty)

Reviewer stance: pragmatic staff engineer. Question asked of every screen: *can this be powered by real data from Navidrome (Subsonic/OpenSubsonic + native `/api`), Lidarr (`/api/v1`, Lidarr 3.x), ListenBrainz (+ labs) and slskd, with no backend: all logic in clients, Listener requests through a private-playlist mailbox processed by Curator devices or the Mac helper?*

Inputs: spec `docs/superpowers/specs/2026-10-26-serverless-architecture-design.md`; research `docs/research/*` (mainly `serverless-feasibility.md`, `sandbox-samples.md`, `lidarr-navidrome.md`, `listenbrainz-discovery-previews.md`, `slskd-direct.md`, `tubifarry.md`); storyboard `flows.md`, `carplay.md`, `canvas/*.dc.html` (visible copy and template data were extracted from every board).

Date: 2026-10-26.

---

## 0. Summary

The library half of the storyboard (Home, Library, Album, Artist, Now Playing, Queue, Lyrics, CarPlay browse) is fully backed by real APIs. The Try/Keep half is buildable **for a Curator acting directly against Lidarr**. It gets shaky in three places:

1. **The mailbox as designed loses data.** It is a single comment field that two parties read, modify and write, and Subsonic `updatePlaylist` has no compare-and-swap.
2. **Shared household state has nowhere to live.** That includes household defaults, caps, the helper heartbeat ("Sam's Mac · Online"), who asked for what, and household stats. Listeners can't read anything a Curator owns privately.
3. **Several designs show precision that the data can't deliver on the Listener path or while the app is suspended:** a live `40%`, "About 20 seconds to go", Live Activity countdowns, and "Ready" notifications.

Expiry also deletes at **artist** granularity while the UI promises a **song** with its own days-left counter. That mismatch is the biggest data-loss risk in the design.

None of this needs a server. It does need (a) two single-writer playlists per user instead of one, (b) one public, Curator-written household playlist, (c) a single elected processor, and (d) coarser, honest UI on the Listener and background paths.

---

## 1. Per-screen data map

Legend: **OK** = real source, cheap. **Curator** = real only for Curators (Lidarr key or Navidrome admin); Listeners need a relay or a simpler UI. **Lag** = real but only as fresh as polling or relay allows. **Gap** = no source in the current architecture. **Cost** = polling or rate-limit concern.

### Setup and invites

| Screen | Data shown | Source | Verdict / notes |
|---|---|---|---|
| Onb-Welcome | static | none | OK |
| Onb-Connect | Home address "Reached"; Away address "Tailscale"; "Found Sam's music 12,480 songs · 1,036 albums"; "You're an admin"; version; cert fingerprint | `ping`, `getUser` (adminRole), native `/api/song?_end=1` + `/api/album?_end=1` `X-Total-Count`, OpenSubsonic `getOpenSubsonicExtensions`/`serverVersion`, TLS handshake (TOFU) | OK, except **Away address auto-discovery: Gap.** No Navidrome API exposes its public or Tailscale URL, so the user types it (or it arrives via invite). Mock shows 0.58.0, but Samples and the scrobble filter were verified only on 0.64.2, so gate on a minimum version. |
| Onb-Lidarr | "Locked down"; profiles created; renaming/tags on; "Linked to your music server"; "Tubifarry detected"; version | `GET /config/host` (authenticationMethod/Required), `POST /qualityprofile`, `POST /metadataprofile`, `PUT /config/naming` + `/config/mediamanagement`, `POST /notification` (Subsonic), `GET /system/plugins` + `/indexer` + `/downloadclient` | OK (Curator). Writes config into the owner's Lidarr: needs explicit opt-in and an undo list. Mock says Lidarr 2.9.6; the research targets 3.x. |
| Onb-Samples | folder found / not found; "Added to your download manager"; "Added as a library on your music server"; "Everyone can see it" | Lidarr `GET /filesystem?path=` (folder probe), `POST /rootfolder`; Navidrome `POST /api/library`, `PUT /api/user/{id}/library` | **Partial / High risk.** The app can detect the folder but can't make it visible to the containers. A sibling "next to your music folder" is usually **not mounted** in either container, so the owner must edit compose for both and restart. Lidarr and Navidrome may also see the same folder under different paths. See H1. |
| Onb-Speed | tier with "~30 s", "2–5 min", "hours"; "Your setup" | Tubifarry detection (above), slskd reachability, Mac helper heartbeat | Tiers are OK as static estimates. "Quick fetch · Your setup" needs the **helper heartbeat (Gap, see C3)**. |
| Onb-Household | discography default, Finds days, per-person cap, LB connect | stored… **where?** | **Gap.** The spec never says where household defaults live. Every device, including Listener devices, must read them (Keep-Sheet default, "in your Finds for 7 days", caps). See C3. |
| Onb-Invite | one-time code, 15-minute validity, role | Navidrome native `POST /api/user` (admin); local crypto | OK, but invite expiry and replay are enforced only client-side. Defer. |
| Join-Scan / Join-Ready | "Invite from Sam"; "12,480 songs"; "Finds for 7 days" | invite payload, native counts | OK, except "7 days" needs household config (C3). |

### Home and library

| Screen | Data shown | Source | Verdict / notes |
|---|---|---|---|
| Home | New finds ("Landed while you were listening"); Jump back in; Made for Sam (Daily Jams, Weekly Exploration, Weekly Jams); New from artists you follow ("Arrived yesterday", "Not in your library yet"); "Because you played Glasshouse"; inline "5 days left", "Looking" | Navidrome `getAlbumList2?type=newest&musicFolderId=<samples>` (finds), `type=recent`; LB `/1/user/{u}/playlists/createdfor` + `/1/playlist/{mbid}` resolved through the match index; LB `/1/user/{u}/fresh_releases` ∩ (starred ∪ Lidarr-monitored ∪ LB top artists) + Navidrome `newest`; labs `similar-artists` seeded from the recent album artist; days-left from song `created` + household expiry; "Looking" from Lidarr queue or mailbox | Mostly OK. "**Landed while you were listening**" needs a per-user "my finds" filter. The Samples library is household-wide, so attribution comes from the mailbox: Curator OK, Listener only their own. "Followed" uses Lidarr monitoring, which is Curator-only; Listeners fall back to stars + LB stats. Days-left: OK. Cache LB responses (6 h). |
| Explore | radio chips ("Mellow Sunday", "Like Glasshouse", "Deep cuts I own", "Describe a radio"); Fresh releases with "Priya asked for it · looking"; Similar to your top artists; **"Top this week in your house"** with per-person avatars and play counts | LB `/1/explore/lb-radio` (token), labs similar-artists, LB fresh releases; Navidrome `getRandomSongs`/`getAlbumList2` for "deep cuts" | Radio: OK for structured prompts. **"Describe a radio" free text: Gap** (LB needs `tag:`/`artist:` syntax), so map heuristically or cut. **"Priya asked for it": Curator-only.** **"Top this week in your house": Gap** (H4). |
| Library | Playlists/Artists/Albums/Songs/Downloaded; "Finds · 3 finds · Copper Wire leaves in 2 days"; "Requests · 1 on its way"; "Lossless soon" on recently added; "kept yesterday" | Navidrome `getArtists`, `getAlbumList2`, `getPlaylists` (hide `__magpie_*`); Samples library query; Lidarr queue / mailbox; `/wanted/cutoff` or suffix=mp3 + kept record | OK for Curators. Listeners infer "Lossless soon" from suffix plus their own kept record: OK. |
| Album | title, genre, year, release date, "Lossless" stamp, tracks, durations, "Downloaded", "More from…" with "Not in your library yet" | `getAlbum` (OpenSubsonic `releaseDate`, `suffix`, `bitDepth`, `samplingRate`), local download DB, LB `/1/popularity/top-release-groups-for-artist/{mbid}` or MB release-groups, then de-dupe against the match index | OK. "Remove" (Curator) = Lidarr trackfile delete; fine. |
| Artist | Play/Shuffle; **"Following · New releases come in automatically"**; Popular with not-yet rows + Try; albums with type (EP/Single/Live); Similar with in/not-in library | Navidrome `getArtist`, `getArtistInfo2?includeNotPresent=true`, `getTopSongs`; LB popularity top-recordings; MB/LB release-group types; Lidarr `GET /artist?mbId=` `monitorNewItems` | OK, except **"Following" is Curator-only** (Lidarr). Needs an artist MBID in Navidrome tags: when it's missing, hide the not-yet sections rather than guessing. |
| Playlist / mix (Weekly Exploration) | 12 songs, "4 in your library"; "Try the 6 you don't have"; per-row Try; "Bringing it home · about 2 min"; "new find" | LB playlist JSPF + match index; request state | OK. **"Try the 6" = 6 concurrent Lidarr adds**, often 6 artists and possibly 6 full albums. It hits the cap quickly and floods Samples. Ask first, or limit to 3. |
| Downloads | 18.4 GB on phone; cache; free; quality tiers (Original / AAC 256 / AAC 128 with MB-per-song estimates); "Downloading 12 of 14" | local storage, background `URLSession`, Navidrome `stream`/`download` with `format`/`maxBitRate` | OK. AAC tiers depend on the server's transcoding config, so detect them and hide missing tiers. |
| Offline | "Your library is out of reach"; 212 downloaded songs; "Queued to try · Will send when connected (2)"; "Keep Analog Summer" queued | local DB; local outbox | Downloads: OK. **Offline outbox: Medium risk** (M7): a queued Keep can target a find that expired meanwhile. |

### Search

| Screen | Data shown | Source | Verdict / notes |
|---|---|---|---|
| Search-Start | recents, browse genres/moods | local; Navidrome `getGenres`; LB tags for moods | OK. Moods aren't genres, so they map to LB radio `tag:` prompts. |
| Search-Results | merged Top result (not-yet artist); songs mixing library + Try; **"Preview · CC BY · free to play"** inline; artists in/not-in; albums incl. "Priya asked" | `search3` ‖ labs `recording-search` → `/1/metadata/recording` ‖ Lidarr `/search` (Curator) or MusicBrainz `/ws/2/artist|release-group?query=` (Listener) | OK for Curators while SkyHook is healthy (text search is still flaky per Lidarr #5498). **Listener path is rate-limit fragile** (H6). **Inline Preview badges: Cost** (M2). **"Priya asked": Curator-only.** |
| Search-Artist-NotYet | bio paragraph; Popular with Try; albums with year/type; similar; "A find stays for 7 days" | Lidarr `/artist/lookup?term=lidarr:<mbid>` (overview, images; Curator); LB popularity; MB release groups; labs similar | Bio is **Curator-only** (SkyHook). Listener: hide it or use the Wikidata/Wikipedia extract. "7 days" comes from household config (C3). |
| Search-Album-NotYet | tracklist, durations, "Usually ready in a few minutes", per-track Try, "Keep this album" | LB `/1/metadata/release_group` / MB release browse; tier estimate | OK. Trying track 7 fetches the whole album (Lidarr is album-granular), and the spec's "Only on a full album" note covers that. Make it visible on the row, not only in the sheet. |

### Try it and Keep

| Screen | Data shown | Source | Verdict / notes |
|---|---|---|---|
| Try-Sheet | "Quick fetch · usually about 30 s"; "Play the open preview · CC BY · Internet Archive"; "Keep the album"; "Finds leave after 7 days" | tier detection + **helper heartbeat**; OpenPreviews ladder (MB url-rels → IA → Openverse → Commons); household config | The tier claim depends on the helper being awake (C3). The preview probe on sheet open is fine (one song, a few calls, about 1–3 s), so show a skeleton until it resolves. |
| Try-Wait-Fast | Looking → **Spotted it (12 s)** → Bringing it home → Ready; "Usually about 30 s"; Play-when-ready toggle | Mac helper: slskd `POST /searches` + poll → `POST /transfers/downloads` → transfer progress → Lidarr `ManualImport` → `startScan` → Navidrome lookup | **Real only on the Mac helper (or web Keeper).** On iPhone the same steps arrive through mailbox write-back + polling. Each step lags by one Curator write plus one iPhone poll (about 3–10 s), so a 30 s flow shows 2–3 jumps, not a smooth ladder. See H3. Deferred for v1 anyway. |
| Try-Wait-Standard | "Looking for the best copy · about 3 minutes"; steps; Live Activity; "Similar, already yours" | Lidarr `command/{id}` (AlbumSearch) → `/queue` (grab, `sizeleft/size`, `timeleft`) → `/history/since` (`downloadImported`) → `/track?albumId=` `hasFile` → Navidrome presence; `getSimilarSongs2` | **OK for a Curator acting directly.** "Spotted it" = queue item appears / `grabbed` history. "about 3 minutes" is a tier constant, and Lidarr `timeleft` refines it once downloading. |
| Try-Wait-Slow | "can take a few hours"; Mac-asleep note; **"catalogue is slow… Next try in 2 min"** | Lidarr `/health` (metadata source issues), `POST /artist` 5xx; client backoff | Catalogue state: OK. "**Next try in 2 min**" is true only if a processing device is awake. On a Listener phone that's unknowable, so say "It will retry on its own". |
| Try-Ready | "Harbour Lights is ready · Playing now"; Sample hallmark; "7 days to keep it" | Navidrome song found in the Samples library (MBID/ISRC via `search3` or native `/api/song?mbz_recording_id=`) | OK **only if "Ready" is gated on Navidrome, not Lidarr** (H2). |
| Keep-Sheet | options with counts: "This album · 11 songs", "All albums · 4", **"Albums + EPs · 6 releases"**, **"Everything · 13 releases"**, "Only future releases"; "Lossless soon" | Lidarr `GET /album?artistId=` after `RefreshArtist` (Curator) **or** MB/LB release-group counts (Listener) | Counts differ between Lidarr's metadata profile and raw MB (compilations, live, secondary types). Show "about 6" or drop the numbers (M1). |
| Keep-Done | "Moved to your library"; "keeps its plays and likes"; "Lossless version · Looking"; "6 releases on the way" | Lidarr `PUT /artist/editor` (move + Lossless profile + untag) → `startScan`; `PUT /album/monitor`; `AlbumSearch`/`ArtistSearch` | OK. Plays and likes survive the *move* (verified). Plays and likes surviving the *MP3→FLAC replacement* is **unverified** (M3). |
| Try-Shelf (Finds) | New finds / Still deciding; "just landed · 7 days"; "5 days left"; "leaves in 2 days"; swipe Remove; "Nothing in Finds counts toward your stats" | Samples library songs; `created` (or Lidarr trackfile `dateAdded`) + expiry days; per-user scrobble filter | Days-left: OK. **Semantics are wrong at the storage layer** (C2, H8): a find is a *song* in the UI but an *artist* (expiry) or *release* (download) in Lidarr, shared by everyone. |
| Listener-Request | Sent 2:14 → **"Accepted · Sam's Mac picked this up"** → **"Bringing it home · 40% · About 20 seconds to go"** → Adding → Ready; "Nobody's home… starts when Sam's Mac or phone is online" | mailbox status write-back by the processor; helper heartbeat | **Lag + Gap.** "Picked up by" works if the processor writes its id into the item. The 40% and the 20 s ETA need the processor to rewrite the comment every few seconds, and the Listener to poll just as often. That's the data-loss-prone RMW cycle (C1) at high frequency. "Nobody's home" needs a heartbeat the Listener can read (C3). Simplify (H3). |

### Now Playing

| Screen | Data shown | Source | Verdict / notes |
|---|---|---|---|
| NP-Classic / Signature | art, title, artist, "Playing from Night Bus Home", elapsed/remain, Lossless stamp, Up next | local player + `getSong` (`suffix`, `bitDepth`) | OK |
| NP-Immersive / NP-Visualizers | loudness-driven rings/particles/aurora | needs PCM or envelope | **Gap for v1.** `AVPlayer` over HTTP progressive has no supported analysis tap. Needs a precomputed envelope (download, then analyse) or the v2 sample-buffer engine. Defer, as the spec's phase 6/8 already does. |
| NP-Sample | Sample hallmark, "Fades in 7 days", Keep / Kept, Not for me, "Then back to Night Bus Home" | Samples library id; household expiry; Keep pipeline | OK for a Curator. Listener Keep and Not-for-me go via the mailbox, so the UI must show an optimistic "Keeping…" until processed. |
| NP-Queue | Up Next with landed find, Autoplay | local queue; `savePlayQueue`; `getSimilarSongs2` for autoplay | OK |
| NP-Lyrics | synced lines, "Lyrics from your library" | OpenSubsonic `getLyricsBySongId` (structured, synced) | OK. Empty state needed. |
| NP-Output | AirPlay routes, quality per network, ReplayGain mode, **Crossfade**, gapless, sleep timer | `AVRoutePickerView`; OpenSubsonic `replayGain` fields; local | **Crossfade is not in the v1 engine** (dual `AVQueuePlayer`; true crossfade is v2), so hide the row in v1. |

### Activity and settings

| Screen | Data shown | Source | Verdict / notes |
|---|---|---|---|
| Activity | Mine / **Household** tabs; In progress with "62%", avatars S/P/L; "Ready for Leo"; Recently kept "**Lossless arrived**"; Needs attention "Couldn't spot 'Paper Moon (Live)' · asked by Leo · **checking again tonight**" · Stop looking | Curator: admin `getPlaylists` (all mailboxes, one call), Lidarr `/queue`, `/history/since`, `/wanted/missing`, `/wanted/cutoff` | Curator: OK (62% is real from `sizeleft/size`). Listener: own items only, no %. "**Lossless arrived**" needs upgrade detection (M3). "**checking again tonight**" has no scheduler behind it (M8), so drop "tonight". |
| Household | people + roles; "Priya · Last here today"; "Leo · 3 open requests of 25"; **"Who brings music home: Sam's Mac · Quick fetch on · Online / Sam's iPhone · Now"**; Finds per person 10; Finds storage 1.2 of 10 GB | native `/api/user` (admin: `isAdmin`, `lastAccessAt`); mailboxes; **heartbeat registry (Gap)**; Lidarr `GET /artist` stats `sizeOnDisk` for Samples-root artists, `/diskspace` | Curator-only screen, so admin APIs are fine. **The processor list and online state need the household playlist (C3).** "Finds per person 10" vs "25 open requests" are two different caps; reconcile them (H9). |
| Settings | name/role, Character, playback, storage, streaming, Sources, Household "4 people", LB "Connected as sam", servers, Face ID | local; `/api/user` count (admin); LB `/1/validate-token` | OK |
| Settings-Appearance | Character dial, accent, sleeve tint, spin toggle, visualizer, app icon | local | OK (tint from art: local image analysis) |
| Settings-Sources | tier "In use / Standing by"; versions "Navidrome 0.64.2", "Lidarr 3.2", "Tubifarry detected"; Finds days; open-preview toggles; Samples folder; **"Quick fetch helper · Sam's Mac · checked 2 min ago"**; "Last checked sources 08:12" | detection calls; household config; heartbeat | Heartbeat and household config: C3. Service names appear here; acceptable under "Details for Curators", but the Connected section shows them on the surface (L7). |
| States-Gallery | unreachable, Away switch, catalogue outage, not spotted, Finds full, disk nearly full, **No Curator awake**, cert changed, session expired, empty library | reachability probes; Lidarr `/health`; caps; Lidarr `/diskspace`; **heartbeat**; TLS pin; Navidrome auth | All OK except "No Curator awake" (C3). |

### Outside the app

| Screen | Data shown | Source | Verdict / notes |
|---|---|---|---|
| Sys-Lock | Now Playing; "Harbour Lights · Bringing it home · **~20 s**" countdown; "is ready · Play now / Later" | `MPNowPlayingInfoCenter`; Live Activity updated locally | **Lag.** No APNs means the Live Activity updates only while our process runs (audio playing, foreground, or a lucky BG refresh). A countdown freezes and then lies. Use an elapsed timer (`Text(timerInterval:)`) plus `staleDate`, never a countdown (H2). |
| Sys-LiveActivity | compact "0:20"; expanded "Quick fetch · 0:20 · Play now"; "Ready" moment; "Red Room Sessions · Priya's request · looking for the best copy" | same | Same as above. Showing **Priya's** request on Sam's lock screen implies Sam's device watches the household: Curator-only, OK. |
| Sys-Notifications | "Harbour Lights is ready to play"; **"Copper Wire leaves in 2 days — keep it?"**; "Afterglow Theory is now lossless"; "Leo asked for Fieldnotes · tap to approve" | local notifications from polling; scheduled local notification at Try time; Lidarr history upgrade event; mailbox | "Ready" is best-effort while suspended: BG refresh can be minutes to hours late, and Listeners depend on their own phone polling their status. "Leaves in 2 days" can be scheduled locally (OK), but it **contradicts journey E** ("day 6, nearly grey, no reminder", L1). Approval only arrives when a Curator device runs. |
| Sys-Widgets | Now Playing; Finds with days left; Daily Jams 25 songs; Jump back in | App Group cache written by the app | OK (stale between app runs; fine). Defer. |

### CarPlay

| Screen | Data shown | Source | Verdict / notes |
|---|---|---|---|
| CP-Home | Jump back in (mixed sleeves + a find record with baked arc); Daily Jams "made this morning"; **Weekly Exploration "New to you · ready to play"**; "New finds (1)" | as Home; pre-rendered images | **"Weekly Exploration · ready to play" is false.** It's mostly not-yet songs (Q3 in carplay.md). Show "8 of 25 ready", play only the library subset, or hide it (H10). |
| CP-Library | Playlists/Artists/Albums/Downloaded; **"Finds (3)"** | Navidrome lists; Samples library + attribution | Finds count: OK from local cache (CarPlay runs inside the app process, so polling works while driving). For Listeners, "mine" comes from their mailbox. |
| CP-Album | header "10 songs · 41 min · Downloaded", tracks, playing indicator | `getAlbum`; local | OK |
| CP-Search / CP-SearchResults | recents; library first, then not-yet "Not in library · Try"; not-yet artist ring | as Search | OK for Curators. `CPSearchTemplate` as a tab root in iOS 27 is **unverified** (Q1), so build the list fallback first. |
| CP-TryAlert | "Quick fetch · about 30 seconds. It plays once it's home." | tier + heartbeat | Same heartbeat dependency. In v1 (no helper) it says "a few minutes". |
| CP-NowPlaying / -Sample | track, times; find with "New find · 7 days"; Keep button → "Kept · Lossless soon" | player; Keep pipeline with household default | OK. Keep from the car triggers a discography download with no confirmation, which is acceptable by design. A Listener Keep is only queued. |
| CP-ReadyToTry (Finds tab) | New finds / Still deciding; days left; **"On its way · about 20 s"** with progress ring | Samples library; request state | Days-left: OK. The "about 20 s" ring is real only on the Quick-fetch path or for a Curator watching the Lidarr queue. Otherwise show an indeterminate ring with the tier phrase. |
| CP-States | before first unlock; never set up; out of reach; "Couldn't spot … yet" | data protection class; reachability | OK |

---

## 2. Ranked issues

Cost: **S** ≤ ½ day · **M** 1–3 days · **L** > 3 days.

### Critical

**C1. The mailbox loses writes.** *Cost M.* `comment` is one field that the Listener (new requests, Keep, cancel) and the Curator (status, progress) both read-modify-write. Subsonic `updatePlaylist` and native `PUT /api/playlist/{id}` have no version precondition, so the last writer wins. Leo adds a request while Sam's Mac writes "40%", and Leo's request vanishes. The spec's "optimistic retry" has nothing to be optimistic against. Writing progress every few seconds makes the collision likely, not rare.
*Change:* two single-writer playlists per user, both owned by the user (private, so only the user and admins can see them):
- `__magpie_out__`: written **only by the user** (append-only requests and intents: try, keep, cancel, not-for-me, with idempotency UUIDs).
- `__magpie_in__`: written **only by Curator processors** (status per request id, `processedBy`, `lastSweepAt`).

Single writer per field means no lost updates. Write via native `PUT /api/playlist` or OpenSubsonic form POST (not GET query strings; proxies cap URLs at about 8 KB). Compact finished items after 30 days. Contract-test the comment size limit.

**C2. Expiry can delete music someone just kept, or someone else's newer find.** *Cost M.* The spec expires "artists tagged `sample` older than N days" with `DELETE /artist?deleteFiles=true`, which permanently deletes the whole artist folder. Failure modes:
- (a) **Expiry vs Keep race.** Device A lists sample artists, then Leo taps Keep and the move starts, then A deletes.
- (b) **Shared artist.** Leo tried Corin Hale on day 1 and Mum tried another Corin Hale song on day 6. On day 7 the artist-level delete removes Mum's day-old find.
- (c) **Two processors.** Two Curator devices expire concurrently, or one expires while another is mid-ManualImport.

*Change:*
- Expire per **release** (`DELETE /trackfile/bulk` + `PUT /album/monitor {monitored:false}`), and delete the artist only when it has no files left.
- Age = newest trackfile `dateAdded` of that release, and never expire within 24 h of a play.
- Immediately before each delete, re-GET the artist and require `rootFolderPath == samples`, `sample` tag present, and no open keep/try in any mailbox for that artist.
- Keep removes the `sample` tag *first* (one cheap PUT), then moves.
- Only the elected processor (C4) runs expiry.
- Setup turns on Lidarr's recycle bin for the Samples root.

**C3. Household state has no home.** *Cost S.* These are all read by Listener devices, but Listeners can only see public playlists or their own:
- household defaults (discography, Finds days, caps)
- the processor heartbeat ("Sam's Mac · Online", "No Curator awake", "Quick fetch · about 30 s", "checked 2 min ago")
- the request ledger ("Priya asked for it")
- the following state

*Change:* one **public** `__magpie_household__` playlist owned by the owner, whose comment holds non-secret JSON: `{defaults, caps, processors:[{id,name,kind,tier,seenAt,leaseUntil}], ledger:[{rgMbid, requesterInitial, state}]}`, written only by Curators and schema-validated on read. Accept that other Subsonic clients show one empty public playlist (name it "Magpie (system)"). Listeners also derive liveness from `lastSweepAt` in their own `__magpie_in__`.

**C4. No lock for concurrent processors.** *Cost S–M.* The spec's "per-artist lock" has nowhere to live. Two Curators, or Mac plus iPhone, sweeping the same mailbox will double-add artists, double-search, or double-ManualImport.
*Change:*
- **Leader lease** in the household playlist. The processor writes `leaseUntil = now + 2 × sweep interval`, waits about 1 s, re-reads, and proceeds only if it is still the holder. That isn't true CAS, but it shrinks the window to sub-second, and the steps below make the residue harmless.
- Every Lidarr step is idempotent by MBID: check-then-add, treat "already added" as success, skip `AlbumSearch` if one is queued or started for that album (`GET /command`), and skip a grab when the queue already has the album.
- Quick fetch runs only on the Mac helper, which is a single instance by construction.

### High

**H1. The Samples folder needs a docker-compose change the app can't make.** *Cost S (copy/UX), owner-side effort.* Onb-Samples tells the owner to make a folder "next to your music folder", but typical compose files mount only `/music`, so neither container sees a sibling. Lidarr and Navidrome may also see different paths for the same folder.
*Change:*
- Detect the problem and show the exact compose lines for both services.
- Validate with Lidarr `GET /filesystem` and Navidrome `POST /api/library` (it errors if the path is missing).
- Offer the nested alternative (`/music/_magpie_samples` + an `.ndignore` in the main library root), which avoids remounts. **Verify** that `.ndignore` excludes a nested library folder from the parent library's scan.
- Until it works, use the spec's fallback (song-level request into the main library, no fading).
- Fix the path inconsistency between boards (`/srv/media/samples` vs `/music/samples`).

**H2. "Ready" and notifications overstate what's knowable.**
- *Ready.* Lidarr `downloadImported` doesn't mean playable. Navidrome's watcher doesn't fire on NFS/SMB; the Lidarr Subsonic Connect does a full incremental scan; Listeners can't `startScan`. Gate **Ready** on the Navidrome song being found by MBID/ISRC in the match index. The processor calls `startScan?target=<lib>:<folder>` and polls `getScanStatus`.
- *Live Activity and lock screen.* Countdowns ("0:20", "~20 s") freeze when the app is suspended. Use elapsed timers + `staleDate` + the tier phrase.
- *"It's ready" notifications.* These are immediate only while audio plays or the app is in the foreground; otherwise BG refresh is minutes to hours late. Copy should say "We'll tell you when your phone checks in". Offer optional Lidarr→ntfy later.

*Cost S.*

**H3. Listener-side precision.** *Cost S (simplify).* The Listener can't see Lidarr. Relayed "Bringing it home · 40% · About 20 seconds to go", "Spotted it" step timings and "Next try in 2 min" are as stale as the last Curator write plus the last Listener poll. Producing them requires high-frequency comment rewrites (C1).
*Change:* Listeners get coarse states only: **Sent → Picked up → Bringing it home → Ready / Still looking**, with the tier estimate phrase and an indeterminate spinner. Say "Picked up by the household", not "Sam's Mac", unless `processedBy` says so. Curators keep real % (they read Lidarr directly).

**H4. "Top this week in your house" has no source.** *Cost S (cut) / M (LB version).*
- Navidrome play counts are per-user annotations. Subsonic returns only the caller's, and nothing verified lets an admin read other users' counts.
- The LB path (`/1/stats/user/{u}/recordings?range=this_week`) needs every member's LB username in household config, LB stats are recomputed with a lag (not live "this week"), and members without LB (Mum) vanish.

*Change:* cut it from v1. Later, either "Top this week for you" (Navidrome `frequent`, or LB stats for the current user) or an opt-in household chart from LB stats with an "about this chart" note.

**H5. Who-asked avatars are Curator-only.** "Priya asked for it", "asked by Leo", and the S/P/L/M avatars on shelves come from mailboxes, which only admins can read. *Change:* show them to Curators only, or publish an initials-only ledger in the household playlist (C3). Never show another person's pending request to a Listener by default (privacy). *Cost S.*

**H6. Listener non-library search can trip MusicBrainz's IP limit.** Listeners have no Lidarr, so artist and album text search goes to MB WS/2 at 1 req/s **per IP**. Every phone in the house shares one NAT IP, and going over returns 503 for *all* of them. Search-as-you-type makes it worse.
*Change:* debounce (≥ 400 ms), search only on submit for artists and albums, cache results, prefer LB metadata endpoints and labs `recording-search` (songs), and back off globally on 503. Curators use Lidarr `/search` but must fall back to MB when SkyHook text search is broken (#5498). *Cost S.*

**H7. Lidarr metadata outage.** `POST /artist`, `RefreshArtist`, and text search all depend on `api.lidarr.audio`, which has had multi-week outages and still-open search issues.
*Change:*
- Resolve via LB/MB to MBIDs and use `lidarr:<mbid>` lookups.
- Check `GET /health` before showing estimates.
- Show the request as "waiting on the catalogue" (States-Gallery already has it), retried by the processor with backoff.
- Never show Try's "about 30 s" while health is degraded.

**Albums appear only after the async `RefreshArtist`:** use `albumsToMonitor` in the add call, or poll `command/{id}`. *Cost S.*

**H8. A find is a song in the UI but a release or artist on disk.** The smallest release containing a song may be a full album, so 12 songs land in Samples. Two users' finds by the same artist share one Lidarr artist. Keeping one moves the artist, so everyone's finds by that artist silently become "kept". "Not for me" by Leo must not delete Mum's find.
*Change:*
- Model `Find = (requestId, requester, recordingMbid, releaseGroupMbid)`.
- The Finds shelf shows the requested songs; siblings that came along are hidden from Finds and Search shows them as "trying".
- Keep copy says "Keeping brings Corin Hale into the library for everyone".
- "Not for me" removes the release only when no other open find references it.

*Cost M.*

**H9. Cap semantics and deadlock.** Two caps conflict: "25 open requests" (flows, Onb-Household) vs "Finds per person 10 songs" (Household, States-Gallery). Patient-tier items can sit in "still looking" forever, so a Listener at the cap is stuck, and "One will finish soon" is false. The cap is enforced in the Listener's own (untrusted) app.
*Change:*
- Two named limits: *active requests* (default 10) and *finds on the shelf* (default 10).
- Items still looking after 7 days move to "Paused" and don't count.
- The processor enforces caps; requests over the cap are rejected and the reason is written back.

*Cost S.*

**H10. CarPlay "Weekly Exploration · ready to play" is false.** It's mostly not-yet songs. *Change:* label it "8 of 25 ready" and play only the library subset, or hide it until the owner answers Q3. *Cost S.*

### Medium

| # | Issue | Change | Cost |
|---|---|---|---|
| M1 | Keep-Sheet release counts ("6 releases", "13 releases") don't match Lidarr's metadata-profile filtering; for Curators they exist only after `RefreshArtist`. | Show counts only when known from Lidarr; otherwise "about 6" or no number. | S |
| M2 | Inline "Preview · CC BY" in result lists means probing up to 5 providers per row on every search. The hit rate is about 2–5%, so this is wasted calls and latency. | Probe on tap only (Try-Sheet). Badge rows only from cached positive hits. | S |
| M3 | Lossless upgrade: Lidarr replaces `.mp3` with `.flac` (new path). Whether Navidrome keeps the song ID (and plays/likes) depends on its PID config and the MBID tags Lidarr writes, which is **unverified**. "Lossless arrived" detection is unspecified. | Contract-test the ID across a format swap. Detect upgrades via Lidarr `/history/since` (`trackFileImported` with upgrade) or a suffix change in the match-index sync. Keep it silent (decision 18). | S test, M if broken |
| M4 | "Finds the Away address" has no API. | The user types it; invites carry it. Probing order stays. | S |
| M5 | "Describe a radio" free text: LB radio needs prompt syntax. | Map to `tag:`/`artist:` heuristically, or ship chips only. | S |
| M6 | Artist "Following · New releases come in automatically" reads Lidarr `monitorNewItems` (Curator-only). | Curator-only, or a ledger flag in the household playlist. | S |
| M7 | Offline outbox (queued Try/Keep) can replay against state that changed (a find expired, the artist was kept by someone else). | Defer the outbox. When built, re-validate each intent on send; turn an expired-find Keep into a fresh Keep request. | M |
| M8 | Copy promises schedules nobody runs: "checking again tonight", "Next try in 2 min". | "We'll keep looking" (Lidarr RSS keeps trying). Show the timer only on the device doing the retry. | S |
| M9 | Crossfade (NP-Output; CarPlay rule 3 "then crossfades") isn't in the v1 engine. | Hide crossfade. Tried songs start at the track boundary. | S |
| M10 | Not-yet artist bio exists only via Lidarr SkyHook (Curator). | Listener: hide it or use the Wikipedia extract via Wikidata. | S |
| M11 | Mailbox payload size and URL length (`updatePlaylist` GET). | Native `PUT` or form POST, compaction, size test. | S |
| M12 | Version drift in mocks (Navidrome 0.58.0 vs 0.64.2 tested; Lidarr 2.9.6 vs 3.x). | Minimum versions: Navidrome 0.64 for Samples, Lidarr 3.x. Gate features on detected versions. | S |
| M13 | "Try the 6 you don't have" fans out 6 artist adds (possibly 6 albums) in one tap. | Confirm with the count; cap batch size at 3; respect active caps. | S |

### Low

| # | Issue | Change |
|---|---|---|
| L1 | "Copper Wire leaves in 2 days" notification contradicts journey E ("no reminder"). | Pick one; recommend no reminder and a quiet in-app arc. |
| L2 | Immersive visualizers need PCM/envelope; none is available from `AVPlayer` streaming. | Defer to the v2 engine; ship "Off — still art". |
| L3 | AAC 256/128 download tiers depend on server transcoders. | Detect via OpenSubsonic transcoding; hide what's missing. |
| L4 | The Activity "Household" tab and Sys-LiveActivity "Priya's request" imply Curator devices watch everyone: polling cost is one admin `getPlaylists` per sweep, so fine. | None (note only). |
| L5 | Settings-Sources shows "Navidrome / Lidarr / Tubifarry" on the surface (anti-goal: no service words outside setup). | Move the names behind Details. |
| L6 | Spin "at 33⅓ rpm" and Live Activity animation while suspended. | Static record when not live. |

---

## 3. UI simplifications the data honestly supports

1. **Two fidelity levels for request progress.** Curator acting directly: real steps + Lidarr % + `timeleft`. Everyone else (Listener, background, lock screen, CarPlay without Quick fetch): coarse steps + tier phrase + indeterminate motion. No relayed percentages or ETAs.
2. **No countdowns anywhere outside the foreground app.** Elapsed time and a tier phrase only.
3. **Drop "Top this week in your house"** and the other-person avatars for Listeners. Keep avatars in the Curator's Activity/Household.
4. **Name the household, not the device:** "Picked up by the household" or "Waiting for the household". Name "Sam's Mac" only in Curator Settings.
5. **Finds = requested songs.** Siblings that came along are not shown as separate finds.
6. **Keep-Sheet without exact counts** unless Lidarr has them.
7. **Preview badge only after a probe**, never speculatively in lists.
8. **CarPlay Weekly Exploration:** library subset with an honest count.

---

## 4. v1 scope: overnight build, tested tomorrow against the owner's real Navidrome + Lidarr (iPhone simulator + CarPlay simulator)

Principle: **the owner is the only user and is a Curator.** Everything runs direct from the phone against real services; nothing that needs the mailbox, helper, or household state. Nothing writes to the owner's Lidarr config without an explicit button. Everything the app adds to Lidarr is tagged `magpie` so it can be cleaned up.

### Must be in
1. **Connect (one screen):** Navidrome URL + username/password (token auth; Keychain), an optional second address tried in order, and an admin check. Lidarr URL + API key: read-only audit (version, auth, root folders, quality/metadata profiles, Tubifarry via `/system/plugins`/`/indexer`), with an explicit "Create Fast Start / Lossless / Albums+EPs profiles" button. ListenBrainz token optional.
2. **Library playback:** Home (Jump back in = `getAlbumList2 recent/newest/frequent`, plus "Made for you" from LB created-for playlists only if a token is set), Library (Artists/Albums/Playlists), Album, Artist (library sections + `getTopSongs`), Now Playing (Signature only), Queue, Lyrics (`getLyricsBySongId`). Engine: `AVQueuePlayer` with prefetch, Subsonic `scrobble`, remote commands and `MPNowPlayingInfoCenter`. Streaming only.
3. **Merged search:** `search3` ‖ Lidarr `/search` ‖ labs `recording-search` → `/1/metadata/recording`, de-duplicated by MBID/ISRC through an in-memory match index (native `/api/song` paging). Not-yet rows as round records with Try. Debounced. Degrades silently if Lidarr or LB is down.
4. **Try / Keep, Curator-direct (no mailbox):** the pure request state machine with real Lidarr polling (`command/{id}` → `/queue` % → `/history/since` → `/track hasFile`) and **Ready gated on Navidrome presence** (+ `startScan?target=` since the owner is admin). Try targets the Samples root **only if** a Lidarr root folder and a Navidrome library named for samples already exist; otherwise it falls back to a normal request into the main library with the Fast Start profile. Keep = `artist/editor` (move if in Samples, Lossless profile, untag) + `album/monitor` per default. One Activity screen with real states and %.
5. **Finds shelf + Not for me:** list Samples-library songs with days-left computed from `created`. Keep and "Not for me" (release-level trackfile delete + unmonitor, with confirm). **No automatic expiry job** in v1.
6. **CarPlay:** tab bar Home · Library · Finds (+ Search as a list of recents/voice if `CPSearchTemplate` isn't a valid tab root), Album list, Now Playing with a custom Keep button on finds, depth assertions, `maximumItemCount`-aware lists, after-first-unlock data protection.

### Stubbed (visible, minimal, or hard-coded)
- Speed tier: detected as Standard (Tubifarry) or Patient. Quick fetch row absent.
- Settings: read-only (servers, versions, sign out). Character dial fixed to Signature. Household screen shows "Just you".
- Notifications: in-app banner plus one local notification when ready *while the app is running*. No Live Activity.
- Open previews: off (the ladder is behind a feature flag).
- Explore: Fresh releases + Similar artists only if an LB token is present; otherwise hidden.

### Deferred (not in v1)
- Mac helper, Quick fetch/slskd (also keeps App Review risk out of the first binary).
- Mailbox, Listener role, household playlist, leader lease, invites/QR/Join (C1–C4 are design work to finish before building these).
- Automatic Finds expiry, caps, disk quota.
- Immersive mode and visualizers, crossfade, Character dial, app icons.
- Downloads/offline and the offline outbox; Away auto-switching beyond the ordered address list.
- Live Activities, widgets, Siri/App Intents, "Top this week in your house", LB radio and "Describe a radio".
- iPad/Mac/tvOS/web.

### Pre-flight checks to run against the real servers tomorrow
1. Navidrome version ≥ 0.64 (multi-library + scrobble filter) and the owner is admin.
2. Lidarr 3.x reachable from the simulator host; note the auth mode.
3. Does a samples root exist in both? If not, test the fallback path first.
4. Does the Lidarr Subsonic Connect exist? If not, rely on the app's `startScan`.
5. Is the watcher effective on the owner's storage (NFS/SMB)? Time the import-to-visible delay.
6. Song-ID stability across an MP3→FLAC upgrade on one test artist (M3).
