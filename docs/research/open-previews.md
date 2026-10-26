# Open-Source and Open-Data Previews for Non-Library Tracks

Research date: 2026-10-26. Companion to `listenbrainz-discovery-previews.md` (section 5, which covers Deezer and iTunes) and `serverless-feasibility.md`.

**Owner constraint:** previews for songs that are not in the user's Navidrome library must come only from open-source or open-data sources that are easy to access. Apple MusicKit/iTunes, Spotify, Deezer and YouTube are excluded. The app is sold as a one-time purchase, so it counts as commercial, and commercial-use terms matter. There is no backend: everything runs on-device in the native apps or in the browser for the static web app.

All the "Verified" statements below come from live `curl` calls made on 2026-10-26.

---

## TL;DR

1. **No open source covers mainstream popular music.** None of the open sources returned a legitimate preview for Portishead, Taylor Swift, Radiohead, Kendrick Lamar, Daft Punk or Khruangbin. Archive.org *does* return hits for all five of the first group, but every one is an anonymous user upload (`opensource_audio`, often `yt2ia-*` rips) with no licence. Those are infringing copies. Playing them would expose a paid app to takedown and App Review risk, so they must be filtered out.
2. **Open sources do cover four niches well:**
   - pre-~1955 recordings: Internet Archive 78rpm, about 335k items
   - taper-friendly live acts: Live Music Archive (`etree`), about 306k shows
   - Creative Commons and netlabel artists: the Jamendo mirror on IA (294k albums), Openverse (Jamendo, Wikimedia and Freesound) and MusicBrainz "download for free" / "free streaming" links
   - public-domain classical: Wikimedia Commons and Musopen. This is usually the same *work* by a different performer.
3. **Expected hit rate for a typical user's "not in library" searches:**
   - About **2–5 %** if you require an exact recording that is safe to use commercially.
   - About **5–10 %** if you also accept live versions from LMA and same-work classical substitutes.
   - About **0 %** for current chart music.

   Previews should be designed as an **occasional bonus, not a feature users can rely on**. The primary non-library experience has to be metadata, artwork and "Add to Lidarr".
4. **Recommended ladder:** MusicBrainz URL relationships → Internet Archive, restricted to curated collections → Openverse (Commons/Jamendo, filtered to commercial licences) → Wikidata/Commons → no preview. Audius, Funkwhale, ccMixter, FMA and Bandcamp are all excluded. Reasons are below.

---

## 1. Test matrix (live)

The test used about 12 songs across eras and genres. The columns mean:

- **Legit hit**: a preview that is lawful to stream from a commercial app, with the licence identified.
- **Junk hit**: a result exists but is infringing, a cover or remix, or a name collision.

| # | Song | IA (curated) | IA (all) | LB `/internet_archive/search` | Openverse | Wikidata P51 | MB URL rels | Audius | Verdict |
|---|------|---|---|---|---|---|---|---|---|
| 1 | Portishead – Glory Box (1994) | – | junk (`yt2ia-…` upload, no licence) | 0 | 0 | – | none | 0 | **MISS** |
| 2 | Taylor Swift – Anti-Hero (2022) | – | junk (`anti-hero_202604` upload) | – | – | – | `streaming` only (paid) | remixes/bootlegs only | **MISS** |
| 3 | Radiohead – Weird Fishes/Arpeggi | etree: 0 (not an LMA band) | junk ×3 user uploads | – | – | – | none | unrelated tracks | **MISS** |
| 4 | Kendrick Lamar – HUMBLE. | – | junk (`humble_202408`) | – | – | – | `streaming` only | bootlegs | **MISS** |
| 5 | Daft Punk – One More Time | – | junk (instrumental cover) | – | – | – | none | remixes | **MISS** |
| 6 | Billie Holiday – Strange Fruit (1939) | **78rpm `JV-15113-1939-…` (tagged CC0), MP3** | + Bechet 78 | 0 (index misses it) | – | – | release `free streaming` → Spotify (useless) | – | **HIT, with jurisdiction caveat** (see §3.1) |
| 7 | Grateful Dead – Scarlet Begonias | **etree, 18,439 GD shows**; track title only in file list | – | – | – | – | none | – | **PARTIAL**: live version only |
| 8 | Kevin MacLeod – Monkeys Spinning Monkeys | IA: 463 items by creator | – | – | yes | – | **recording `download for free` → incompetech; `license` CC BY 3.0** | – | **HIT** |
| 9 | Josh Woodward – Swansong (CC indie) | jamendo-albums mirror | – | – | **yes, `license_type=commercial` → CC BY** | – | release `free streaming`/`download for free` → Jamendo | – | **HIT** |
| 10 | Khruangbin – Maria También | etree: 0; `taperssection`/`roiocollection` audience tapes | – | – | – | – | none | – | **MISS** (only grey-area tapes) |
| 11 | Bach – Goldberg Aria (Glenn Gould) | `musopen` collection (34 items) | – | – | – | – | release `download for free` → magazine link (dead) | – | **WORK-LEVEL HIT**: Commons has "Aria (Musopen version)" and Shelley Katz; not Gould |
| 12 | Nine Inch Nails – Ghosts IV | **IA `nineinchnails_ghosts_I_IV`, official, CC BY-NC-SA** | – | – | – | – | release `download for free` → archive.org | – | **HIT, NC licence** (see §3.3) |
| 13 | Hello Meteor (small Bandcamp act) | 0 | 0 | – | – | – | – | 0 | **MISS** |
| 14 | "Alex G" (Bandcamp-era indie) | – | 42 hits, but they are a *different* "Alex G" on Jamendo | – | – | – | – | 0 | **MISS** (false-positive trap) |

**Totals:** 4 clean hits out of 14 (6, 8, 9, 12), 2 partial (7, 11) and 8 misses. The test set was deliberately loaded with open-friendly picks. In a typical user's search mix, about 80–95 % of queries are post-1960 commercial releases, and every such case missed.

---

## 2. Candidate-by-candidate

### 2.1 Internet Archive (advancedsearch + metadata + download)
- **Open?** It is a non-profit library. The software is open source, and the metadata is effectively open. The *content* licence varies per item and is often absent.
- **Access:** keyless. Verified endpoints:
  - Search: `GET https://archive.org/advancedsearch.php?q=…&fl[]=identifier&fl[]=title&fl[]=creator&fl[]=collection&fl[]=licenseurl&rows=N&output=json`
  - File list: `GET https://archive.org/metadata/{identifier}`
  - Audio: `https://archive.org/download/{id}/{file}.mp3`, which 302-redirects to `iaNNNN.us.archive.org` and returns `audio/mpeg` with `accept-ranges: bytes`
- **CORS:** `access-control-allow-origin: *` on search, metadata, the download redirect and the final file. All verified, so the static web app can call IA directly.
- **AVPlayer:** every audio item has a derived `VBR MP3`, and plays progressively. Some items also have Ogg (AVPlayer can't play it) or FLAC. Pick `format == "VBR MP3"`. To get a "preview", seek to about 30 % and stop after 30 s on the client.
- **Matching:** there is no MBID or ISRC field to match on. Search by `creator:("…") AND title:("…")`, then fuzzy-match title and duration. For 78s, `external-identifier` holds the matrix number, which is rarely in MB.

  For **LMA (`etree`)**, item titles are show-level ("Grateful Dead Live at …"). Song titles exist only in `files[].title`, so matching takes two calls: (1) find shows with `collection:etree AND creator:(…)`, then (2) read `/metadata/{show}` and match the track title. `title:("Scarlet Begonias") AND collection:etree` returns **0**, which confirms this.
- **Collections that matter (verified counts):**
  - `etree` (LMA): 305,787 shows
  - `78rpm`: 335,386
  - `jamendo-albums`: 294,068. A full Jamendo mirror with track MP3s, so you get Jamendo content **without** the Jamendo API.
  - `netlabels`: 80,546
  - `freemusicarchive`: 16,797 (many items are metadata-only, with no audio files)
  - `musopen`: 34
  - `opensource_audio`: 3.04 M. This is the **user-upload bin** and the source of all the infringing mainstream hits.
- **Licence / terms:**
  - The IA Terms of Use still say access is "granted for scholarship and research purposes only." This has never been enforced against player apps, but it is the formal position.
  - **LMA is "strictly noncommercial, both for access and for any further distribution"**, per <https://help.archive.org/help/live-music-archive-etree-org/>. Band policies vary, and some (such as the Grateful Dead) are stream-only for soundboards.
  - The 78rpm/Great 78 collection was the subject of the UMG/Sony v. Internet Archive suit. It **settled confidentially in Sept 2025**, so the terms are unknown and some items may have been removed.
  - The `licenseurl` field is the only machine-readable licence.
- **Rate limits:** none documented for reads. IA asks for "reasonable" use. Cache search results.
- **Verdict:** the most useful source, but only with a **collection allow-list**: `78rpm`, `etree` (behind a noncommercial-risk toggle), `jamendo-albums`, `netlabels`, `musopen`, `audio_music`, `georgeblood`. Also allow any item whose `licenseurl` is CC/PD and whose `uploader` or `collection` is not the anonymous upload bin. **Never** play `opensource_audio` or `community` items without a `licenseurl`.

### 2.2 ListenBrainz BrainzPlayer data sources (2026)
- As of `listenbrainz-server` master, `frontend/js/src/common/brainzplayer/` contains these players: **Spotify, YouTube, Apple Music, SoundCloud, Funkwhale, Navidrome, Internet Archive**.
  - The Navidrome and Funkwhale players were added via GSoC 2025. They play from the *user's own* server through OAuth/credentials, so they are not a public preview source.
  - The Internet Archive player was added via C4GT 2025 (blog, 2026-02-17). Its backend was merged and the frontend was pending at the time; it is now in the tree.
- **LB IA endpoint (live, keyless, CORS `*`):** `GET https://api.listenbrainz.org/1/internet_archive/search?artist=…&track=…`. It returns `{results:[{name, artist[], stream_urls[], artwork_url, track_id, data:{…IA metadata}}]}`.
  - **It indexes only the 78rpm and cylinder collections**, crawled weekly by `publicdate`.
  - Its matching is a plain artist and/or track filter. `InternetArchivePlayer.tsx` simply takes `results[0]`, and the code itself carries a TODO to add fuzzysort sanity checking. There is no MBID/ISRC matching.
  - Live test: "Strange Fruit" returned the Sidney Bechet 78. "Billie Holiday"+"Strange Fruit" returned 0, even though IA has the 1939 Holiday side. "Louis Armstrong"+"West End Blues" returned "Louis Armstrong's Hot five". "Mountain Goats", "Bing Crosby"+"White Christmas" and "Duke Ellington"+"Mood Indigo" all returned 0.
  - **What to reuse:** treat it as a cheap secondary lookup for pre-war material. Our own IA advancedsearch call with fuzzy scoring is strictly better on recall. LB's matching logic is not worth copying; Apple Music's fuzzysort approach in `AppleMusicPlayer.tsx` is the pattern to copy.
- **No other MetaBrainz "open preview" initiative was found** for 2025–2026. The only adjacent work is the IA integration above and the Navidrome/Funkwhale players.

### 2.3 MusicBrainz URL relationships
- **Recording-level types:** `free streaming`, `download for free`, `purchase for download`, `streaming` (paid), `license`.
- **Release-level types:** the same set plus `discogs`, `amazon asin` and others.
- **Population (live sample):**
  - Mainstream recordings (Portishead, Radiohead, Daft Punk, GD) have **no recording-level URL rels**.
  - Taylor Swift and Kendrick have release-level `streaming` only.
  - Where `free streaming` exists, it is mostly **Spotify, Deezer or Bandcamp** (e.g. the Billie Holiday release → open.spotify.com), and those are excluded.
  - Useful links do appear for CC artists: Kevin MacLeod → incompetech plus a CC BY licence rel; Josh Woodward → jamendo.com; NIN Ghosts → archive.org.
- **Domain counts** from the MB URL search (approximate):

  | Domain | Approx. count |
  |---|---|
  | bandcamp.com | ~1.17 M |
  | jamendo.com | ~6.1 k |
  | freemusicarchive.org | ~1.1 k |
  | ccmixter.org | ~127 |
  | funkwhale | ~25 |

- **Access:** keyless, 1 req/s per IP with a mandatory User-Agent. The MB WS has no CORS on some paths, so the web app should use LB's MB mirror endpoints where possible.
- **Use:** step 1 of the ladder. It is the only route that is **MBID-exact**. Follow the `archive.org/details/*` and `jamendo.com/*` links and resolve them to an MP3. The `license` rel tells you whether commercial use is OK.

### 2.4 Openverse (WordPress Foundation; aggregates Jamendo, Wikimedia Commons, Freesound)
- **Open?** Yes. Openverse is an open-source project and only indexes CC/PD works.
- **Access:** keyless with anonymous limits of **20/min burst and 200/day sustained per IP** (verified headers). A free registered key raises the limits.
- **CORS:** `*` (verified with an Origin header).
- **Endpoint:** `GET https://api.openverse.org/v1/audio/?q=…&license_type=commercial`.
- **Licence:** per item, with an `attribution` string returned. The **`license_type=commercial` filter** removes NC/ND for you.
- **Coverage (`/v1/audio/stats/`):** wikimedia_audio 3.99 M, jamendo 645 k, freesound 592 k. Mainstream coverage is zero; "Glory Box Portishead" returned 0.
- **Matching:** text only, then fuzzy-check creator and title. Returned files are sometimes `.ogg`/`.flac` (Commons). For Commons, use the MP3 transcode (see 2.5).
- **Verdict:** the best single call for CC/indie artists. It also gives you Jamendo catalogue access without Jamendo's non-commercial API terms, because you play the Commons/Jamendo file under its CC licence. **Caveat:** Jamendo-sourced items still point at Jamendo URLs, and Jamendo's site terms apply to its CDN. Prefer the IA `jamendo-albums` mirror or Commons copies where possible.

### 2.5 Wikimedia Commons / Wikidata
- **Open?** Yes. Wikidata is CC0. Commons files are free-licensed only, because Commons forbids fair use. The non-free samples on English Wikipedia are fair-use and **not reusable commercially**.
- **Access:** keyless. SPARQL at `query.wikidata.org` needs a User-Agent and allows CORS. The Commons API takes `origin=*`.
- **Matching from an MBID:**
  - Recording: `?item wdt:P4404 "<recording MBID>"` then `wdt:P51 ?audio`.
  - Work: `wdt:P435 "<work MBID>"`, which suits classical.
- **Coverage (live SPARQL):**
  - 27,147 Wikidata items carry an MB recording ID, but only **935** also have an audio file (P51). The sample was dominated by a single CC band ("Complex Numbers").
  - Work-ID items with audio: 1,121.
  - **For mainstream music, effectively zero.**
- **Format:** the Commons API `prop=videoinfo&viprop=derivatives` returns an **`audio/mpeg` transcode** (`/transcoded/…/file.flac.mp3`), verified. That plays fine in AVPlayer and `<audio>`. The licence comes from `extmetadata.LicenseShortName` (e.g. CC BY-SA 4.0).
- **Classical:** a full-text search for "Goldberg Variations Aria filetype:audio" returned 120 files (Musopen version, Shelley Katz, and others). This gives a good **work-level** fallback, labelled "Different performance".

### 2.6 Jamendo API
- **Open?** No. Content is CC-licensed, but the platform and API are proprietary.
- **Access:** a free `client_id` is required. (I did not run live calls because they would need a registered key.)
- **Terms** (devportal.jamendo.com/api_terms_of_use): "The API may be used freely for **non-commercial** uses. For any other type of use including … commercial uses please contact … licensing@jamendo.com". The terms also require attribution plus a backlink and prohibit offline caching. The free tier allows about 35k requests/month for non-commercial use.
- **Verdict:** **do not use the API** in a paid app without a deal. Reach the same catalogue via the IA `jamendo-albums` mirror or Openverse, honouring each track's CC licence.

### 2.7 Free Music Archive
- Acquired by Tribe of Noise in 2019. The public API was shut down and has not returned; Openverse also lacks FMA access (Openverse issue #1795).
- The IA has a `freemusicarchive` mirror of 16.8k items, but many are metadata-only with no audio.
- **Verdict:** skip it as a direct source, and use the IA mirror opportunistically.

### 2.8 Funkwhale federated pods
- Funkwhale is open source (AGPL). A public pod's API is sometimes anonymously readable: `tanukitunes.com/api/v1/search?q=portishead` returned Portishead albums, while `open.audio` and `funkwhale.it` returned 404.
- The content is **user-uploaded with no rights clearance**, so mainstream hits on public pods are the same legal problem as IA `opensource_audio`.
- BrainzPlayer only uses the *user's own* pod via OAuth.
- **Verdict:** offer it as a user-configured source in the same way as Navidrome ("your other server"), never as a public preview source.

### 2.9 Audius
- **Open?** The protocol and client code are open source. The content is creator-uploaded, and most tracks are tagged "All rights reserved".
- **Access:** keyless. `api.audius.co/v1/tracks/search?query=…&app_name=…` works with CORS `*` (verified). The free plan allows about 10 rps / 500k per month.
- **Coverage:**
  - Mainstream queries return **unauthorised remixes and bootlegs**: Anti-Hero, HUMBLE and One More Time returned only remixes, and Glory Box returned 0.
  - Real artists exist only where they self-publish, such as deadmau5 and Skrillex (verified).
- **Verdict:** **exclude it**. For the songs users will search for, it does not meet the "open data" spirit or the rights bar.

### 2.10 ccMixter
- Its API is keyless (`ccmixter.org/api/query?f=json&search=…`), but **there is no CORS header** (verified), so the web app can't call it directly.
- Licences are mostly NC Sampling+/BY-NC. It hosts remixes and a cappellas, not catalogue recordings, and text search returned irrelevant results.
- **Verdict:** skip.

### 2.11 Musopen
- A 501(c)(3) non-profit with public-domain or CC classical recordings. There is **no public API**, and the site has daily download caps.
- Its key recordings are mirrored on IA (`musopen` collection, `MusopenKickstarterRecordingsLossless` is CC0) and on Commons.
- **Verdict:** reach Musopen via IA and Commons, not directly.

### 2.12 Bandcamp (noted only)
- Not open. There is no public API, and scraping `data-tralbum` stream URLs breaks Bandcamp's ToS.
- Use it only as an "Open on Bandcamp" link from MB URL rels, of which there are about 1.17 M. That link is the best *outbound* action for indie acts, even though no preview is possible.

---

## 3. Commercial-use cautions

1. **Public domain depends on jurisdiction.**
   - US: sound recordings published before 1926 are PD as of 2026. Recordings from 1926–1946 stay protected until 100 years after publication. The 1939 Billie Holiday side is **not PD in the US until 2035**, even though the IA item is tagged CC0.
   - EU/UK: 70 years from publication, so pre-~1956 recordings are PD.
   - Gate 78rpm previews on `year`. Allow anything pre-1926 everywhere. Allow later items only where PD applies, or accept the risk.
2. **LMA is explicitly noncommercial.** The app *streams from archive.org at the user's request* and does not redistribute, which is the same posture as a web browser. That is defensible, but put LMA behind a setting ("Include live tapes from the Live Music Archive") that is on by default, show attribution, and never cache or download those files.
3. **CC NC licences** (NIN Ghosts, many Jamendo and netlabel releases). Streaming a preview inside a paid app is arguably commercial use. The conservative choice is Openverse `license_type=commercial` plus an IA `licenseurl` that does not contain `-nc`. The lenient choice is to allow NC because the stream is not monetised per play. **Recommendation:** start conservative, and add NC as an opt-in later if the owner accepts the risk.
4. **Attribution.** CC BY/BY-SA require showing the creator, the licence and a link. Render a "Source: Internet Archive · CC BY 3.0 · Kevin MacLeod" line under the preview player.
5. **Never use** IA `opensource_audio`/`community` items without a licence, Funkwhale public pods, or Audius uploads for recordings by major-label artists.

---

## 4. Recommended lookup ladder

Input: a non-library item with `recording_mbid`, `artist`, `title`, `duration_ms`, `first_release_year`, and optionally `work_mbid` (from LB/MB). Stop at the first accepted result. Cache `(mbid → result | miss)` for 30 days. The ladder runs client-side in both the apps and the web app, since every step has CORS or doesn't need it.

```
0. Gate: if first_release_year >= 1960 AND artist has no MB `license` rels AND no
   free-download rels → skip straight to "no preview" (saves ~5 calls; this is ~85% of queries).
1. MusicBrainz recording + release url-rels (via LB MB mirror or MB WS, 1 rps):
     archive.org/details/{id}  → IA metadata → VBR MP3 whose title fuzzy-matches   conf 0.95
     jamendo.com/track|album   → map to IA jamendo-albums mirror or Openverse      conf 0.9
     `license` rel → record licence for gating
2. Internet Archive advancedsearch, allow-listed collections only:
     q = creator:("A") AND title:("T") AND collection:(78rpm OR georgeblood OR
         jamendo-albums OR netlabels OR musopen OR audio_music)
     + PD/CC gate (year / licenseurl), fuzzy title ≥ 0.85, |Δduration| ≤ 10 s      conf 0.8–0.9
2b. (LMA toggle on) etree: creator:("A") AND collection:etree, newest/most-downloaded
     3 shows → /metadata → files[].title fuzzy match → label "Live, YYYY-MM-DD"    conf 0.6 (alt version)
3. Openverse /v1/audio?q="A T"&license_type=commercial → fuzzy creator+title      conf 0.8
4. Wikidata SPARQL: P4404=recording MBID → P51; else P435=work MBID → P51
     → Commons videoinfo derivatives → audio/mpeg transcode                       conf 0.95 / 0.5 (work-level, "different performance")
5. (optional, cheap) LB /1/internet_archive/search?artist&track — dedupe with step 2
6. No preview → show "Open on Bandcamp / MusicBrainz" (MB url-rels) + "Add to Lidarr".
```

**Playback:** use AVPlayer (native) or `<audio>` (web) with the MP3 URL, and seek to `min(30 % of duration, 60 s)`. Fade out after 30 s, because the open sources serve full tracks rather than clips. Don't scrobble previews, don't cache them offline, and always show the source and licence badge.

---

## 5. Expected hit rate and the coverage gap (the honest version)

| User search profile | Share of typical queries | Expected preview hit rate |
|---|---|---|
| Current and recent mainstream, major/indie-label (post-1960) | ~80–90 % | **≈ 0 %** |
| Bandcamp/self-released indie | ~5–10 % | ~5–15 % (only CC/Jamendo/netlabel acts) |
| Jam bands / taper-friendly live acts | ~1–3 % | ~60–80 %, **live versions only** |
| Pre-1950 jazz, blues, pop | ~1–3 % | ~40–60 % (78rpm), with a US-PD caveat for 1926+ |
| Classical | ~3–5 % | ~30–50 % at work level (different performer); exact-recording ≈ 0 % |
| CC/production-music artists | <1 % | ~90 % |

**Weighted overall:**
- ~**2–5 %** for an exact, commercially safe preview.
- ~**5–10 %** including live and work-level substitutes.
- For a user whose taste resembles the test set's first five songs, effectively **never**.

**The coverage gap:** there is no open-data or open-source source of previews for copyrighted commercial recordings, and none is in the pipeline at MetaBrainz. LB's own player only reaches mainstream audio through Spotify, Apple Music, YouTube and SoundCloud, or through the user's own server. Thirty-second commercial previews exist only because labels license them to stores, so any route to them is a store's API under that store's terms.

Under the owner's constraint, the product should:
- treat previews as a rare bonus,
- lead the non-library UI with artwork, metadata, LB similarity and "Add to Lidarr", which turns the song into a *full* play after Lidarr fetches it,
- and keep the preview resolver behind a provider interface. If the owner later relaxes the constraint, for example to allow iTunes previews with the store badge, it can be added without UI changes.

---

## Sources
- IA advancedsearch / metadata / download: live calls to `archive.org` (CORS headers verified)
- LMA policy: <https://help.archive.org/help/live-music-archive-etree-org/>
- Great 78 settlement: <https://www.digitalmusicnews.com/2025/09/16/great-78-project-lawsuit-settlement/>, <https://en.wikipedia.org/wiki/The_Great_78_Project>
- BrainzPlayer IA integration: <https://blog.metabrainz.org/2026/02/17/c4gt-2025-integrate-internet-archive-into-brainzplayer/>. Source: `metabrainz/listenbrainz-server` `frontend/js/src/common/brainzplayer/{InternetArchivePlayer,FunkwhalePlayer,NavidromePlayer}.tsx`
- Navidrome in BrainzPlayer: <https://community.metabrainz.org/t/navidrome-playback-now-available-on-listenbrainz/807653>
- Jamendo API terms: <https://devportal.jamendo.com/api_terms_of_use>
- FMA history: <https://en.wikipedia.org/wiki/Free_Music_Archive>, Openverse issue <https://github.com/WordPress/openverse/issues/1795>
- Musopen: <https://en.wikipedia.org/wiki/Musopen>
- Openverse API: live `api.openverse.org/v1/audio/` (rate-limit headers verified)
- Wikidata SPARQL (P4404, P435, P51) and Commons `videoinfo` derivatives: live calls
- MusicBrainz WS `/recording?inc=url-rels`, `/release?inc=url-rels`, `/url?query=`: live calls
- Audius API: live `api.audius.co/v1/tracks/search`; plan limits from <https://providers.apievangelist.com/providers/audius/>
- ccMixter API: live `ccmixter.org/api/query` (no CORS)
