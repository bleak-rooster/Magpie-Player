# Flows — Magpie

Status: storyboard phase · 2026-10-26 · pairs with `design-language.md` and the product spec (`docs/superpowers/specs/2026-10-26-serverless-architecture-design.md`).
Canvas boards: **App map** (`Map-IA`), **Key journeys** (`Map-Journeys`), **Decision board** (`Decisions`).

Roles: **Curator** holds the keys (owner Sam, plus Priya). **Listener** has no keys (Leo, Mum); their Try/Keep goes through their mailbox and a Curator device does the work. Both roles take the same paths. Only the screens marked *Curator only* differ.

## 1. Information architecture

- **Tabs:** Home · Explore · Library, plus **Search** as the separate circle (iOS 27 search tab role).
- **Always on screen:** the glass mini player above the tabs opens Now Playing. The **avatar** in the top bar opens Activity and Settings. A progress ring on the avatar shows when something is being brought home.
- **Activity** opens from the avatar, from Library → Requests, and from a Live Activity or notification.
- **Try it → Keep** starts the same way from any not-yet song: Search, Explore, an artist or album page, a mix, or CarPlay.
- **CarPlay:** four tabs (Home · Library · Finds · Search). Now Playing has its own system button.
- **Outside the app:** Lock screen, Live Activity & Island, Widgets, Notifications.

## 2. Screen inventory

Each line gives the board title, what the screen is for, how you get there (in), where you go next (out), and how roles differ. Empty and error states are listed where they apply. Every error is calm: we say what happens next, never what broke.

### Setup & invites
| Board | For | In → Out | Roles | Empty / error |
|---|---|---|---|---|
| 1 Welcome | First launch, promise in one line | App install → 2 | Owner; a Listener with an invite goes straight to Listener joins | — |
| 2 Connect your music | Home server address + login; finds the Away address | 1 → 3 | Owner | Wrong password: inline. Unreachable: "Can't reach it from here. Are you on home Wi-Fi?" |
| 3 Turn on requests | Connect requests; we set up the profiles | 2 → 4 | Owner; can skip (Try it then stays off) | Missing key: "Paste it from the requests app's settings" (only screen that names it) |
| 4 Finds shelf | "A shelf for your finds": creates the holding folder (the `samples` folder on the server) | 3 → 5 | Owner; can skip (Try then becomes a normal request, no fading) | Folder not visible to both: guided fix |
| 5 Speed check | Detects the tier: Quick fetch (under a minute · needs the Mac helper) / Standard (a few minutes) / Patient (can take a few hours) | 4 → 6 | Owner | Patient only: honest note, no blame |
| 6 Household defaults | Discography default, Finds shelf days, caps | 5 → 7 | Owner | — |
| 7 Invite someone | QR + one-time code, Listener or Curator | 6, Household → Home | Curator only | Code expired: make a new one |
| Listener joins | Scans the QR, sets own password | Camera / link → Listener ready | Listener (or invited Curator) | Code used or expired: "Ask Sam for a fresh code" |
| Listener ready | Confirms Home and Away addresses | Listener joins → Home | Listener | — |

### Home & library
| Board | For | In → Out | Roles | Empty / error |
|---|---|---|---|---|
| Home | New finds, Jump back in, Made for you, New from artists you follow | Tab → Album, Artist, Playlist / mix, Finds shelf, Activity (avatar) | Same; shelves are personal | New user: "Your mixes appear after a few days of listening"; New finds hidden when empty |
| Explore | Radio, discovery, similar artists, fresh releases | Tab → Playlist / mix, Artist, Artist/Album not in library | Same | Discovery offline: shelf drops out quietly |
| Library | Your sleeves: albums, artists, playlists, downloads, Finds, Requests | Tab → Album, Artist, Playlist / mix, Downloads, Finds shelf, Activity | Same | Empty library: points to Search |
| Album | Tracks, quality stamp, sleeve tint | Anywhere → Now Playing, Artist | Curators also see "Remove" | — |
| Artist | Popular, albums, similar | Anywhere → Album, Album not in library | Same | — |
| Playlist / mix | Mixes and playlists; not-yet songs carry Try | Home, Explore, Library → Now Playing, Try sheet | Same | — |
| Downloads & offline | What's on this phone, storage | Library → Album | Same | Nothing downloaded: one line + how |

### Search
| Board | For | In → Out | Roles | Empty / error |
|---|---|---|---|---|
| Search — start | Recent searches, browse | Search circle → Results | Same | — |
| Search — merged results | Library and not-yet in one list; bare records carry Try | Start → Album/Artist (either kind), Try sheet | Same results (Listeners use open metadata for not-yet artists) | No match: "Nothing called that yet. Check the spelling, or try the artist" |
| Artist not in library | Bare-record discography, Try a song or Keep the artist | Results, Explore → Try sheet, Keep sheet | Same | — |
| Album not in library | Tracklist as records, Try one or Keep the album | Results, Home (new release) → Try sheet, Keep sheet | Same | "Only on a full album" note before bringing it home |

### Try it & Keep
| Board | For | In → Out | Roles | Empty / error |
|---|---|---|---|---|
| Tap a song you don't have | Sheet: honest estimate, Try; free preview when one exists | Any not-yet song → Wait | Same; Listener sees "Sam's home server will bring it home" | Cap reached: "You have 25 on the go. One will finish soon" |
| Wait — Quick fetch | Record spins: Looking → Spotted it → Bringing it home → Ready; "Bringing it home · about 30 s" | Sheet → Ready | Same | Falls back silently to Standard; if the Mac is asleep: "Quick fetch needs your Mac at home. It's asleep, so this takes the slower route." (Listeners: "Quick fetch needs Sam's Mac…") |
| Wait — Standard | "a few minutes"; leave freely | Sheet → Ready, Live Activity | Same | — |
| Wait — Patient / away | "can take a few hours"; we'll tell you | Sheet → Live Activity, Notification → Ready | Same | Nothing found: "We'll keep looking and tell you when it's here" |
| Ready — playing a find | Plays the moment it lands; Keep is right there | Wait, Notification, New finds → Keep sheet | Same | — |
| Keep — how much? | Discography choice, default preselected | Ready, NP find, Finds shelf, not-yet pages → Kept | Same; Listener's Keep may need approval (decision 11) | — |
| Kept — slipping into the sleeve | Record morphs to sleeve; "Lossless soon" stamp | Keep sheet → back to where you were | Same | — |
| Finds shelf (fading) | New finds + older finds, days-left arcs (Harbour Lights new, Analog Summer 5 days left, Copper Wire leaves in 2 days) | Home, Library → Ready, Keep | Same; Curators can see the household's finds in Activity | Empty: hidden from Home; in Library "Finds leave after 7 days unless you keep them". Nothing in Finds counts toward your stats or mixes |
| Listener's request | A Listener's own items and their state | Activity (Listener) → Ready, Keep | Listener view | Waiting on a Curator device: "Waiting for Sam's Mac to pick it up" (Leo's request: Fieldnotes — Ines Morrow) |

### Now Playing
| Board | For | In → Out | Roles |
|---|---|---|---|
| Now Playing — Classic / Signature / Immersive | The full player in each Character | Mini player, Lock screen → Queue, Lyrics, Output | Same |
| Now Playing — a find | Sample hallmark (the trial-file stamp), days-left arc, Keep button | Ready, mini player → Keep sheet | Same |
| Queue | Up Next; landed Tries slot in here | NP → NP | Same |
| Lyrics | Synced where available | NP → NP | Same (empty: "No words for this one yet") |
| Output & quality | AirPlay route, quality stamp | NP → NP | Same |
| Immersive visualizer styles | Visualizer options | Settings → Appearance, NP Immersive | Same |

### Activity & settings
| Board | For | In → Out | Roles | Empty / error |
|---|---|---|---|---|
| Activity | Bringing it home, ready, finds, history (Priya's Red Room Sessions: "Looking for the best copy") | Avatar, Library → Requests, Live Activity → Ready, Keep | Curators see the household; Listeners see their own; "Details" disclosure for Curators only | Nothing going on: "All quiet" |
| Household | People, roles, invites, caps | Settings → Invite someone | Curator only | — |
| Settings | Everything personal | Avatar → Appearance, Sources & speed, Household | Listeners see fewer rows | — |
| Appearance — Character dial | Classic · Signature · Immersive, accent | Settings | Same | — |
| Sources & speed | Servers (Home/Away), requests, Quick fetch, Finds shelf | Settings | Curator only | Service down: plain sentence + Details |
| Away / offline | Banner "Your library is out of reach"; downloads keep playing | Any tab | Same | — |
| Calm states gallery | Every empty, waiting and can't-find state | Reference | — | — |

### Outside the app
| Board | For |
|---|---|
| Lock screen | Now Playing controls; Sample hallmark on a find |
| Live Activity & Island | Bringing it home (spinning record; "On its way" when compact), then "Ready" → Ready |
| Widgets | New finds, Jump back in |
| Notifications | "Harbour Lights is ready" → Ready. Lossless upgrades are silent by default |

### CarPlay
| Board | For |
|---|---|
| CarPlay — Home / Library / Album | Browse; same records and sleeves (pre-rendered round art) |
| CarPlay — Search / Results | Voice or list search; not-yet rows carry Try |
| CarPlay — Try from the car | One-tap confirmation; no sheet |
| CarPlay — Now Playing / Playing a find | Player; Keep on a find uses your default |
| CarPlay — Finds | Finds tab; new finds first, then the rest of the shelf |
| CarPlay — Locked / away | Phone locked or away from home: calm states |

## 3. Key journeys

**A. Owner first run (Sam, about 5 minutes):** 1 Welcome → 2 Connect your music → 3 Turn on requests → 4 Finds shelf → 5 Speed check → 6 Household defaults → 7 Invite someone → Home.

**B. Listener joins by QR:** Household (Sam taps Invite, picks Listener) → 7 Invite someone (QR + one-time code) → Leo's camera scans it → Listener joins (sets own password, no keys) → Listener ready (Home + Away saved) → Home → his first Try shows in Listener's request.

**C. Hear a song I don't have:** Search — start ("harbour lights") → Search — merged results (bare record) → Tap a song you don't have (sheet, estimate) → one of:
- Wait — Quick fetch (about 30 s)
- Wait — Standard (a few minutes)
- Wait — Patient / away (can take a few hours)

→ Ready — playing a find → Keep — how much? (Albums + EPs preselected) → Kept — slipping into the sleeve → later, a genuine lossless file replaces the trial file and the stamp shimmers once.
*If you leave the app while waiting:* Live Activity & Island shows the spinning record → Notifications "It's ready" → tap → Ready.
*If something else is playing when it lands:* it goes next in Up Next and into New finds (decision 17).

**D. Driving:** CarPlay — Search → CarPlay — Results (not yet, Try) → CarPlay — Try from the car (one tap) → then:
- Quick fetch: CarPlay — Playing a find starts by itself. Keep there uses your default discography; no sheet.
- Slower: CarPlay — Finds, added to Up Next → CarPlay — Now Playing after the current song → back home, Finds shelf (fading) to keep it or let it go.

**E. A find nobody kept (Copper Wire):** Ready — playing a find (day 0, full colour) → Finds shelf (fading) day 3, colour draining, arc shows 4 days → day 6, nearly grey, no reminder → day 7, gone quietly (files removed, never in stats, shuffle or mixes) → searching again later shows a bare record you can Try again. Keep stays one tap away until the last day, and colour comes back at once.

## 4. Decisions (mirrors the Decision board; ★ = recommended)

| # | Decision | Options |
|---|---|---|
| 1 | App name | **Decided: Magpie** (trademark check vs musicMagpie before launch) |
| 2 | Main action word | ★Keep · Add · Save |
| 3 | Role names | ★Curator / Listener · Keeper / Listener · Owner / Member |
| 4 | Default Character | Classic · ★Signature · Immersive |
| 5 | Accent colour | **Decided: Sheen** (#3CC4B8, ink #0E6F68) · Ultramarine · Tangerine |
| 6 | Default Now Playing | ★Signature · Immersive |
| 7 | Visualizer in Immersive | Off · ★Grooves · Particles · Waveform bars |
| 8 | Tab structure (+ Search circle) | ★Home · Explore · Library · 4 tabs with Activity · Home · Library |
| 9 | Owner setup length | Full guided 7 steps · ★Essentials now, rest later · Music only |
| 10 | Where Quick fetch runs | ★Mac helper + web only · Also in the iPhone app |
| 11 | Listener requests | ★No approval + cap (25) · Curator approves each · Try freely, approve Keeps |
| 12 | Not-yet look | ★Bare record · Dimmed square · Outlined square |
| 13 | Tap on a not-yet song | Try straight away · ★Try sheet first · Free preview first |
| 14 | Licence on free previews | Chip on row · ★Info sheet only · Hidden |
| 15 | Default discography on Keep | Just this song's release · This album · Albums · ★Albums + EPs · Everything · Future releases only |
| 16 | How long finds last | 3 · ★7 · 14 · 30 days · Never |
| 17 | Try lands while music plays | ★Slot in next · Wait in New finds · Ask with a banner |
| 18 | Lossless upgrade | ★Quiet stamp change · Notification · No sign |
| 19 | Try in CarPlay | ★Allowed, one tap · Brought home when parked · Hidden while driving |
| 20 | CarPlay tabs | ★Home · Library · Finds · Search · Radio instead of Finds · Home · Explore · Library · Search |
