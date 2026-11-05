# Magpie: your own flows from a recipe (design)

Owner request of 2026-11-05. **Built** (round 16). Owner follow-ups the same day: no turn on/off control; an edit
updates the flow on the server by itself; a flow still downloading shows greyed out in Your flows.
Research: Aurral **2.13.0** source (`lklynet/aurral` tag v2.13.0), read for this design:
`backend/routes/playlists/handlers/flows.ts`, `handlers/utils.ts`, `services/playlists/flowPlaylistConfig.ts`,
`services/playlists/playlistOperations.ts`, `services/playlists/playlistManager.ts`, `lib/flows.ts` and the web
app's `FlowsPage.tsx` / `FlowEnabledSwitch.tsx`. Earlier notes: `docs/research/aurral-discover.md` §e.
Calls marked **Decision** are mine; **Owner** marks the owner's answers.

## What the owner wants
- In **Discover**, the user can **create, edit and delete their own flows**, as in Aurral's web app.
- A flow is built from a **recipe**: when it updates (days and time), where its songs come from (Discover,
  Library, Trending, New releases, Focus), **deeper cuts**, and filters by **tags** and **release dates**.
- **Owner:** the user controls **every flow under their name**, not only flows made in Magpie.
- **Owner:** the recipe editor has a **Simple** and an **Advanced** version.
- **Owner:** a new flow **downloads automatically** as soon as it is created.

## What Aurral 2.13 gives us
| Need | Aurral 2.13 | Notes |
|---|---|---|
| Create | `POST /api/playlists/flows` (accessFlow) with `{name, templateId?, mix{discover,mix,trending,focus,newReleases}, size, deepDive, recentListening, recordHistory, autoDownload, yearFrom, yearTo, tags[], excludeTags[], relatedArtists[], scheduleDays[], scheduleTime}`. It answers `{success, flow}` **synchronously**. | A new flow is saved **off** (`enabled: false`, `nextRunAt: null`): it never runs until it is turned on. Aurral's web app does the same; its user then flips the switch. |
| Turn on / off | `PUT /api/playlists/flows/:id/enabled {enabled}` | **On** schedules the next run and queues `enable-flow-refresh`, which **fetches and downloads the songs now**. **Off** cancels downloads and **empties the flow**: its files go (playback-protected: a file a visible Navidrome playlist still points at stays). |
| Edit | `PUT /api/playlists/flows/:id` with any of the create fields plus `name`, `showInLibrary`. **Partial**: a missing field keeps its value; `yearFrom`/`yearTo` sent as `null` clear the bound. | The whole result is validated (below). Schedule changes reschedule the next run. The songs already in the flow stay until the next run. |
| Delete | `DELETE /api/playlists/flows/:id` → `{success, flowId, queued, operationId}` | **Queued.** The worker cancels downloads, moves files another Aurral playlist or flow uses, then deletes the rest of the flow's files **without** playback protection, then the flow. Library files (`externalPath`) are never in the flow's folder. |
| Run now | `POST /api/playlists/start/:id` (Magpie already sends it: Refresh Flow) | Unchanged. |
| Templates | `GET /api/playlists/flow-templates` → `{templates[{id,name,description,available}]}`: discover-weekly, trending-mix, library-blend, focus-listening-history, release-radar | Starting points. |
| Tag suggestions | `GET /api/discover/tags?q=&limit=` | Already researched (§a). |
| Who | Every route uses `getFlowForUser`: the owner, or an **admin for anyone's** flow (an ownerless flow is admin-only). | Magpie already narrows the status to the signed-in user's flows (`AurralStatus.scoped(to:)`, `belongs(to:)`), so an admin is never shown another user's flow. |

**Rules Aurral enforces** (`flowRules`, returned as a 400 with the message):
- the name is not empty; it must not match another flow **or** shared playlist of the same owner (trimmed, case
  folded; `FLOW_NAME_CONFLICT` → 400 "Flow name already exists", synchronous, unlike shared playlists);
- the size is above 0 (no maximum; default 30);
- **at least one source** has a share above 0;
- **at least one schedule day**;
- years have four digits; a reversed range is swapped;
- **Focus needs a tag, a similar artist, or recent listening.**

**What Aurral stores, so what Magpie can offer:**
- **Sources are weights**, normalised to percentages (`normalizeFlowMix`); the songs are split by largest remainder
  (`splitFlowTotal`). The web app's "Library" source is the `mix` key (Library Blend).
- **Update time is the hour only**: `normalizeScheduleTime` keeps `HH` and sets minutes to `00`. Days are 0–6
  (Sunday = 0).
- **Release filter is years, not dates**: `yearFrom` / `yearTo` (1000–9999).
- **Deeper cuts** is `deepDive` (a boolean).

## Decisions (as built)
1. **Four new Aurral writes, each its own pinned route** (G1 allow-list, `scripts/check-writes.sh`, `StubAurral`):
   `recipeFlowCreate` `POST api/playlists/flows`; `recipeFlowTurnOn` `PUT api/playlists/flows/<plain id>/enabled`,
   body exactly `{enabled: true}` (never false: check-writes refuses it); `recipeFlowUpdate` `PUT …/<plain id>`;
   `recipeFlowDelete` `DELETE …/<plain id>`. Each sent from one line in `AurralKit/RecipeFlows.swift`, only on the
   user's tap. Templates and tag suggestions are not used (no new reads). 35 routes in all.
2. **Create = create, then turn on.** `autoDownload: true` by default; the turn-on queues the first run so the songs
   download at once (Aurral saves new flows off). A failed turn-on is retried once, then "Your flow was made, but its
   songs couldn't start downloading. Edit it to try again." (an edit turns an off flow on).
3. **Every recipe flow under the user's name** (the status is already scoped) gets Edit flow and Delete flow, made
   anywhere. **No turn on/off control (owner).** Gated by `aurralCanManageFlows` (flows capability + accessFlow).
4. **Simple / Advanced editor**: Simple has name, songs (1–100), source checkmarks (equal shares), deeper cuts, day
   chips and an hour, tags, released-between years; Advanced adds per-source share sliders, tags to leave out,
   similar artists, recent listening and automatic download. Simple's Focus without a tag uses recent listening.
5. **Edit updates the server by itself (owner).** Save sends only the changed fields, then runs the flow (Refresh
   Flow's `POST /start/<id>`), waiting up to 2 minutes for a run already under way; an off flow is turned on instead.
6. **Delete** is confirmed with the file wording above; the flow leaves Your flows at once (`deletingFlowIds`) while
   Aurral's queued delete runs.
7. **Your flows** sits at the top of Library › Discover with **New flow**; tap a row to edit, swipe or long-press to
   delete. A flow's playlist page has **Edit flow**. **While a flow's songs are still being fetched or downloaded it
   shows greyed out with "Getting songs…" / "Downloading 3 of 30…" (owner)**, read every 10 s until done, then
   Discover reads again so its playlist joins.

## Decision rows
D148 (routes, 1), D149 (create, edit, delete behaviour, 2, 5, 6), D150 (who, editor and placement, 3, 4, 7).

## Tests
- AurralKit: route pins and refusals for each of the five routes; body shape per field; the partial-edit diff
  (unchanged fields absent, cleared years `null`); simple ↔ advanced mapping (equal shares, Focus →
  recentListening, advanced values kept); create-then-enable with the enable failing; queued delete remembered.
- Stubs (`StubAurral`, `dev/aurral-stub`) behave as 2.13: create answers at once and saves the flow off; enable
  seeds jobs; disable clears them; delete is listed for one more status read; name conflicts answer 400.
- App: Your flows controls shown only for the user's own recipe flows and only with accessFlow; an admin sees no
  one else's; Release UI scan of the editor's words.

## Out of scope
Saving a flow as a static playlist (`POST …/static-playlist`), the Lidarr import list feed, `showInLibrary`,
blocked tags (`/api/discover/blocked-tags`), and editing another user's flow as an admin.
