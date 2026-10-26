# Magpie storyboard — artboard kit (READ FULLY before writing any artboard)

Design language spec (read it too): /Users/dev/Dev/navidrome_player/docs/storyboard/design-language.md
Product spec (what the app does): /Users/dev/Dev/navidrome_player/docs/superpowers/specs/2026-10-26-serverless-architecture-design.md
Canvas file-format rules: /private/tmp/claude-501/-Users-dev-Dev-navidrome-player/87ba4f2e-e83e-4823-bf00-cd35538cdaab/scratchpad/artifact-files/f58123b1-bec6-4dd6-9f44-f7cd61787bff/artifact-type/reference/format.md (and craft.md, diagrams.md in the same folder)

Canvas root (write artboards here, ONLY the filenames you were assigned):
/private/tmp/claude-501/-Users-dev-Dev-navidrome-player/87ba4f2e-e83e-4823-bf00-cd35538cdaab/scratchpad/canvas/project/

## Hard format rules (each one fails silently if broken)
- File skeleton exactly as below: `<script src="./support.js"></script>` in head, `<x-dc>` wrapper, `<helmet><style>`, then ONE root div, then the `<script type="text/x-dc" data-dc-script data-props='…'>` block with `class Component extends DCLogic { renderVals(){…} }`.
- Close every element, quote every attribute. `{{hole}}` = dotted lookup only, never expressions. Compute in renderVals().
- No emoji, no iframes, no external network except the Google Fonts link already in the kit. No `innerHTML`/script-built UI.
- Real `<button>` / `<a href>` / `<input>`+`<label>`; icon-only buttons get `aria-label`; decorative svg `aria-hidden="true"`.
- No fake iOS status bar, no fake keyboard. Leave the top 54px of a phone screen empty (status bar / Dynamic Island area) — content may run under it only for full-bleed art.
- Phone artboard = the SCREEN itself: root exactly 390×844, `overflow:hidden`, `position:relative`. CarPlay artboard = 800×480 root.
- data-props: single-quoted attribute; `&` → `&amp;`, `'` → `&#39;`.
- Interactivity: optional. If you add it, use state + `<sc-if>`, handlers returned from renderVals(). Links to other artboards: `<a href="Other.dc.html">` styled as the control.
- Copy is REAL product copy (see voice rules in design-language.md). No lorem ipsum. Fictional artists/albums ONLY from the catalogue below (never real artists, never real album art).
- Write one artboard file at a time with the Write tool. Do NOT publish, do NOT open a browser, do NOT verify by rendering.

## Every phone artboard has two tweak props
```
data-props='{"character":{"editor":"enum","options":["classic","signature","immersive"],"default":"signature","section":"Look"},"scheme":{"editor":"enum","options":["light","dark"],"default":"dark","section":"Look"},"$preview":{"width":390,"height":844}}'
```
renderVals returns `ch: this.props.character ?? 'signature'` and `sc: (this.props.character === 'immersive') ? 'dark' : (this.props.scheme ?? 'dark')` (use the default your brief gives; light is fine for many screens). Root: `<div class="app ch-{{ch}} sc-{{sc}}" style="width:390px;height:844px;position:relative;overflow:hidden">`. Everything inside uses the CSS variables, so the Character dial re-skins the screen. Use `<sc-if>` with booleans `isClassic`, `isImmersive`, `notClassic` for markup that differs (e.g. the Immersive art backdrop `<div class="backdrop art-3"></div>` as first child, shown only when immersive — CSS already hides `.backdrop` outside immersive, so you can just always include it).

## The helmet style block (paste VERBATIM into every phone/CarPlay artboard; you may append screen-specific rules after it)
```html
<helmet>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link href="https://fonts.googleapis.com/css2?family=Newsreader:opsz,wght@6..72,500;6..72,600&display=swap" rel="stylesheet">
<style>
body{margin:0}
*{box-sizing:border-box}
button{font:inherit;color:inherit;background:none;border:0;padding:0;cursor:pointer}
a{color:inherit;text-decoration:none}
.app{--font-text:-apple-system,BlinkMacSystemFont,"SF Pro Text","Helvetica Neue",system-ui,sans-serif;--font-num:ui-rounded,"SF Pro Rounded",-apple-system,system-ui,sans-serif;--font-display:var(--font-text);--display-weight:700;--display-track:-0.4px;--accent:#3CC4B8;--accent-ink:#3CC4B8;--on-accent:#04201D;--r-art:8px;--r-card:20px;font-family:var(--font-text);color:var(--ink);background:var(--bg);-webkit-font-smoothing:antialiased}
.ch-signature,.ch-immersive{--font-display:ui-serif,"New York","Newsreader",Georgia,serif;--display-weight:600}
.ch-classic.sc-light{--bg:#FFFFFF;--surface:#F2F2F7;--surface2:#E5E5EA;--ink:#000000;--ink2:#6C6C70;--sep:#D1D1D6;--accent-ink:#0E6F68;--glass:rgba(250,250,252,.72);--glass-line:rgba(255,255,255,.7);--shadow:0 8px 28px rgba(0,0,0,.12)}
.ch-classic.sc-dark{--bg:#000000;--surface:#1C1C1E;--surface2:#2C2C2E;--ink:#FFFFFF;--ink2:#98989F;--sep:#38383A;--glass:rgba(38,38,42,.66);--glass-line:rgba(255,255,255,.14);--shadow:0 8px 28px rgba(0,0,0,.5)}
.ch-signature.sc-light{--bg:#FBFAF7;--surface:#F2EFE9;--surface2:#E8E3DA;--ink:#16130F;--ink2:#6B655C;--sep:#E3DED5;--accent-ink:#0E6F68;--glass:rgba(251,250,247,.7);--glass-line:rgba(255,255,255,.75);--shadow:0 10px 30px rgba(40,25,10,.14)}
.ch-signature.sc-dark{--bg:#0E0D0C;--surface:#1A1816;--surface2:#24211E;--ink:#F4F1EA;--ink2:#A39C90;--sep:#2C2925;--glass:rgba(36,33,30,.62);--glass-line:rgba(255,255,255,.12);--shadow:0 10px 30px rgba(0,0,0,.55)}
.ch-immersive{--bg:#0B0A10;--surface:rgba(255,255,255,.10);--surface2:rgba(255,255,255,.16);--ink:#FFFFFF;--ink2:rgba(255,255,255,.72);--sep:rgba(255,255,255,.16);--glass:rgba(255,255,255,.14);--glass-line:rgba(255,255,255,.22);--shadow:0 10px 30px rgba(0,0,0,.4)}
.backdrop{display:none}
.ch-immersive .backdrop{display:block;position:absolute;inset:-60px;filter:blur(48px) saturate(1.3) brightness(.55);transform:scale(1.15);z-index:0}
.ch-immersive .scrim{position:absolute;inset:0;background:linear-gradient(180deg,rgba(0,0,0,.15),rgba(0,0,0,.55));z-index:0}
.layer{position:relative;z-index:1}
/* type */
.large-title{font-family:var(--font-display);font-weight:var(--display-weight);letter-spacing:var(--display-track);font-size:34px;line-height:41px;margin:0}
.title1{font-family:var(--font-display);font-weight:var(--display-weight);letter-spacing:var(--display-track);font-size:28px;line-height:34px;margin:0}
.title2{font-family:var(--font-display);font-weight:var(--display-weight);letter-spacing:-0.2px;font-size:22px;line-height:28px;margin:0}
.title3{font-weight:600;font-size:20px;line-height:25px;margin:0}
.headline{font-weight:600;font-size:17px;line-height:22px}
.body{font-size:17px;line-height:22px}
.callout{font-size:16px;line-height:21px}
.subhead{font-size:15px;line-height:20px}
.footnote{font-size:13px;line-height:18px}
.caption{font-size:12px;line-height:16px}
.muted{color:var(--ink2)}
.num{font-family:var(--font-num);font-variant-numeric:tabular-nums}
.accent{color:var(--accent-ink)}
/* surfaces */
.glass{background:var(--glass);-webkit-backdrop-filter:blur(26px) saturate(180%);backdrop-filter:blur(26px) saturate(180%);border:0.5px solid var(--glass-line);box-shadow:var(--shadow)}
.card{background:var(--surface);border-radius:var(--r-card)}
.sep{height:0.5px;background:var(--sep)}
/* art (fictional covers) */
.art{border-radius:var(--r-art);position:relative;overflow:hidden;flex:none}
.art-1{background:radial-gradient(circle at 70% 30%,#F4D58D 0 18%,transparent 19%),linear-gradient(180deg,#0F4C5C 0 58%,#E9C46A 58% 62%,#1B6F78 62%)}
.art-2{background:radial-gradient(circle at 30% 65%,#FFE8D6 0 10%,transparent 11%),radial-gradient(circle at 62% 40%,#F4A261 0 14%,transparent 15%),linear-gradient(160deg,#9B2226,#E76F51)}
.art-3{background:radial-gradient(circle at 50% 55%,#FF4D8D 0 22%,transparent 23%),repeating-linear-gradient(0deg,#2B2D42 0 10px,#24263A 10px 20px)}
.art-4{background:radial-gradient(ellipse at 50% 110%,#B7E4C7 0 35%,transparent 36%),linear-gradient(135deg,#1B4332,#40916C)}
.art-5{background:linear-gradient(0deg,#F1FAEE 0 30%,transparent 30%),radial-gradient(circle at 50% 70%,#A8DADC 0 30%,transparent 31%),linear-gradient(180deg,#1D3557,#457B9D)}
.art-6{background:repeating-linear-gradient(90deg,#FFB703 0 14%,#FB8500 14% 28%,#F2E8CF 28% 42%)}
.art-7{background:radial-gradient(circle at 30% 30%,#111 0 12%,transparent 13%),linear-gradient(45deg,transparent 48%,#111 48% 52%,transparent 52%),#EFE9DD}
.art-8{background:radial-gradient(circle at 75% 75%,#FFD166 0 16%,transparent 17%),linear-gradient(200deg,#7209B7,#F72585 60%,#FF9E00)}
.art-9{background:conic-gradient(from 200deg at 40% 60%,#264653,#2A9D8F,#E9C46A,#264653)}
.art-10{background:radial-gradient(circle at 50% 40%,#FDF0D5 0 25%,transparent 26%),linear-gradient(180deg,#C1121F,#780000)}
/* record = not in library yet (Signature/Immersive). Classic shows a dimmed square instead */
.rec{border-radius:50%}
.rec::before{content:"";position:absolute;inset:0;border-radius:50%;background:repeating-radial-gradient(circle at 50% 50%,rgba(0,0,0,0) 0 2px,rgba(0,0,0,.16) 2px 2.6px)}
.rec::after{content:"";position:absolute;left:50%;top:50%;width:20%;height:20%;transform:translate(-50%,-50%);border-radius:50%;background:var(--bg);box-shadow:0 0 0 1.5px rgba(0,0,0,.25)}
.ch-classic .rec{border-radius:var(--r-art);opacity:.55}
.ch-classic .rec::before,.ch-classic .rec::after{display:none}
.ch-immersive .rec::after{background:#15131A}
.spin{animation:spin 1.8s linear infinite}
.ch-classic .spin{animation:none}
@keyframes spin{to{transform:rotate(360deg)}}
.fade-1{filter:saturate(.75)}.fade-2{filter:saturate(.5)}.fade-3{filter:saturate(.25)}.fade-4{filter:saturate(.05) brightness(.9)}
/* days-left arc around a record: wrapper sets --p (0-100) */
.arc{border-radius:50%;padding:2.5px;background:conic-gradient(var(--accent) calc(var(--p)*1%),var(--sep) 0);flex:none}
.ch-classic .arc{background:none;padding:0}
/* hallmark (quality stamp) */
.hallmark{display:inline-flex;align-items:center;gap:4px;font-size:11px;line-height:14px;font-weight:600;letter-spacing:.3px;padding:2px 6px;border-radius:5px;border:1px solid var(--sep);color:var(--ink2);text-transform:uppercase}
.ch-signature .hallmark,.ch-immersive .hallmark{font-family:var(--font-display);font-style:italic;text-transform:none;letter-spacing:0;font-size:12px}
.hallmark.gold{color:var(--accent-ink);border-color:currentColor}
/* buttons */
.btn{display:inline-flex;align-items:center;justify-content:center;gap:6px;min-height:44px;padding:0 18px;border-radius:999px;font-weight:600;font-size:15px}
.btn-fill{background:var(--accent);color:var(--on-accent)}
.btn-tint{background:color-mix(in srgb,var(--accent) 16%,transparent);color:var(--accent-ink)}
.ch-immersive .btn-tint,.sc-dark .btn-tint{color:var(--accent)}
.btn-glass{background:var(--glass);border:0.5px solid var(--glass-line);-webkit-backdrop-filter:blur(20px);backdrop-filter:blur(20px)}
.capsule{display:inline-flex;align-items:center;gap:4px;height:30px;padding:0 12px;border-radius:999px;font-weight:600;font-size:13px;background:color-mix(in srgb,var(--accent) 16%,transparent);color:var(--accent-ink)}
.sc-dark .capsule,.ch-immersive .capsule{color:var(--accent)}
.icon-btn{width:44px;height:44px;display:inline-flex;align-items:center;justify-content:center;border-radius:999px;color:var(--ink)}
.icon-btn svg,.ico{width:22px;height:22px;stroke:currentColor;fill:none;stroke-width:1.8;stroke-linecap:round;stroke-linejoin:round}
/* list row */
.row{display:flex;align-items:center;gap:12px;min-height:60px;padding:0 16px}
.row .thumb{width:48px;height:48px}
.row-text{flex:1;min-width:0;display:flex;flex-direction:column;gap:1px}
.row-text .t1{font-size:16px;line-height:21px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.row-text .t2{font-size:13px;line-height:18px;color:var(--ink2);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.dot{width:8px;height:8px;border-radius:50%;background:var(--accent);flex:none}
/* tab bar + mini player (iOS 27 Liquid Glass) */
.tabbar{position:absolute;left:16px;right:16px;bottom:24px;height:62px;display:flex;gap:10px;z-index:5}
.tabs{flex:1;border-radius:999px;display:flex;align-items:center;justify-content:space-around;padding:0 6px}
.tab{display:flex;flex-direction:column;align-items:center;gap:2px;font-size:10px;font-weight:600;color:var(--ink);min-width:64px;padding:6px 0;border-radius:999px}
.tab svg{width:24px;height:24px;stroke:currentColor;fill:none;stroke-width:1.8;stroke-linecap:round;stroke-linejoin:round}
.tab.on{color:var(--accent-ink);background:color-mix(in srgb,var(--ink) 8%,transparent)}
.sc-dark .tab.on,.ch-immersive .tab.on{color:var(--accent)}
.tab-search{width:62px;height:62px;border-radius:999px;display:flex;align-items:center;justify-content:center;flex:none}
.tab-search svg{width:24px;height:24px;stroke:var(--ink);fill:none;stroke-width:2;stroke-linecap:round}
.mini{position:absolute;left:16px;right:16px;bottom:96px;height:52px;border-radius:999px;display:flex;align-items:center;gap:10px;padding:0 8px 0 8px;z-index:5}
.mini .thumb{width:36px;height:36px;border-radius:8px}
.mini .rec{border-radius:50%}
/* sheet */
.sheet{position:absolute;left:0;right:0;bottom:0;border-radius:34px 34px 0 0;background:var(--bg);box-shadow:0 -10px 40px rgba(0,0,0,.25);z-index:8}
.grabber{width:36px;height:5px;border-radius:3px;background:var(--sep);margin:6px auto 0}
.dim{position:absolute;inset:0;background:rgba(0,0,0,.4);z-index:7}
/* grooves ripple (fetch wait) */
.ripple{position:absolute;border-radius:50%;border:1px solid var(--accent);opacity:0;animation:ripple 3.6s ease-out infinite}
@keyframes ripple{0%{transform:scale(.6);opacity:.55}100%{transform:scale(1.9);opacity:0}}
.ch-classic .ripple{display:none}
@media (prefers-reduced-motion: reduce){.spin,.ripple{animation:none}}
</style>
</helmet>
```

## Fictional catalogue (use only these; art class in brackets)
1 [art-1] "Low Tide Radio" — Marlow Vance (in library, FLAC)
2 [art-2] "Paper Lanterns" — The Quiet Hours (in library)
3 [art-3] "Night Bus Home" — Ada Okafor (in library, currently playing; track "Last Stop Lullaby")
4 [art-4] "Glasshouse" — Juniper & the Fold (in library, downloaded)
5 [art-5] "Saltwater Hymns" — Corin Hale (NOT in library — the hero "Try it" example; track "Harbour Lights", 3:52)
6 [art-6] "Analog Summer" — Velvet Static (being tried: sample, 5 days left)
7 [art-7] "Fieldnotes" — Ines Morrow (NOT in library; new release from a followed artist)
8 [art-8] "Afterglow Theory" — Lumen Park (kept yesterday; "Lossless soon")
9 [art-9] "Tessellate" — Oro Bay (in library)
10 [art-10] "Red Room Sessions" — Hollis Gray (NOT in library; Curator's request in progress)
People in household: Sam (owner, Curator), Priya (Curator), Leo (Listener), Mum (Listener). Server: "Home" (LAN) / "Away" (Tailscale).

## Icons (inline stroke SVGs; viewBox 0 0 24 24; class="ico" or inside .icon-btn/.tab; add aria-hidden="true")
- home: `<path d="M3 11l9-7 9 7v9a1 1 0 0 1-1 1h-5v-6h-6v6H4a1 1 0 0 1-1-1z"/>`
- explore (sparkle): `<path d="M12 3l1.8 5.2L19 10l-5.2 1.8L12 17l-1.8-5.2L5 10l5.2-1.8z"/><path d="M19 16l.7 1.8 1.8.7-1.8.7L19 21l-.7-1.8-1.8-.7 1.8-.7z"/>`
- library (stack): `<rect x="4" y="9" width="16" height="11" rx="2"/><path d="M6 6h12M8 3h8"/>`
- search: `<circle cx="11" cy="11" r="6.5"/><path d="M20 20l-4.2-4.2"/>`
- play (filled, set fill=currentColor stroke none): `<path d="M7 4.5v15a1 1 0 0 0 1.5.9l12-7.5a1 1 0 0 0 0-1.8l-12-7.5A1 1 0 0 0 7 4.5z"/>`
- pause (filled): `<rect x="6" y="4" width="4.2" height="16" rx="1.2"/><rect x="13.8" y="4" width="4.2" height="16" rx="1.2"/>`
- next (filled): `<path d="M3 5.5v13l9-6.5zM12 5.5v13l9-6.5z"/>`  prev: mirror with `transform="scale(-1,1) translate(-24,0)"`
- more: `<circle cx="5" cy="12" r="1.3"/><circle cx="12" cy="12" r="1.3"/><circle cx="19" cy="12" r="1.3"/>`
- plus: `<path d="M12 5v14M5 12h14"/>`  check: `<path d="M5 12.5l4.5 4.5L19 7"/>`
- download: `<circle cx="12" cy="12" r="9"/><path d="M12 7.5v8M8.5 12.5L12 16l3.5-3.5"/>`
- airplay: `<path d="M5 17H4a1 1 0 0 1-1-1V5a1 1 0 0 1 1-1h16a1 1 0 0 1 1 1v11a1 1 0 0 1-1 1h-1"/><path d="M12 15l5 6H7z"/>`
- queue: `<path d="M4 6h12M4 12h12M4 18h8M18 15v6M15 18h6"/>`
- lyrics (quote bubble): `<path d="M4 5h16v11H9l-5 4z"/><path d="M8 9h8M8 12h5"/>`
- shuffle: `<path d="M3 7h3c5 0 7 10 12 10h3M3 17h3c2 0 3.4-1.6 4.6-3.6M13.4 9.6C14.6 7.6 16 7 18 7h3M18 4l3 3-3 3M18 14l3 3-3 3"/>`
- repeat: `<path d="M4 11V9a3 3 0 0 1 3-3h13M17 3l3 3-3 3M20 13v2a3 3 0 0 1-3 3H4M7 21l-3-3 3-3"/>`
- star: `<path d="M12 3.5l2.6 5.3 5.9.9-4.3 4.1 1 5.8L12 16.9l-5.2 2.7 1-5.8L3.5 9.7l5.9-.9z"/>`
- chevron right: `<path d="M9 5l7 7-7 7"/>`  back: `<path d="M15 5l-7 7 7 7"/>`  close: `<path d="M6 6l12 12M18 6L6 18"/>`
- record: `<circle cx="12" cy="12" r="9"/><circle cx="12" cy="12" r="5.5" opacity=".5"/><circle cx="12" cy="12" r="1.5"/>`
- sleeve (keep): `<rect x="3" y="3" width="18" height="18" rx="3"/><path d="M8 12.5l3 3 5-6"/>`
- bolt: `<path d="M13 2L4 14h7l-1 8 9-12h-7z"/>`  hourglass: `<path d="M6 3h12M6 21h12M7 3c0 5 10 5 10 9s-10 4-10 9M17 3c0 5-10 5-10 9"/>`
- radio/waves: `<path d="M5 12a7 7 0 0 1 14 0M8 12a4 4 0 0 1 8 0"/><circle cx="12" cy="12" r="1.2"/><path d="M12 13v8"/>`
- person: `<circle cx="12" cy="8" r="4"/><path d="M4 21c1.5-4 4.5-6 8-6s6.5 2 8 6"/>`  people: add second smaller head
- gear: `<circle cx="12" cy="12" r="3"/><path d="M12 2v3M12 19v3M2 12h3M19 12h3M4.9 4.9l2.1 2.1M17 17l2.1 2.1M4.9 19.1L7 17M17 7l2.1-2.1"/>`
- wifi-off / cloud / bell / info: draw simply in the same style if needed.

## Common markup patterns
Tab bar (Home active; tabs = Home · Explore · Library, Search is the separate circle — iOS 27 search tab role):
```html
<nav class="tabbar" aria-label="Tabs">
  <div class="tabs glass">
    <a class="tab on" href="Home.dc.html"><svg viewBox="0 0 24 24" aria-hidden="true">…home…</svg>Home</a>
    <a class="tab" href="Explore.dc.html"><svg …>…explore…</svg>Explore</a>
    <a class="tab" href="Library.dc.html"><svg …>…library…</svg>Library</a>
  </div>
  <a class="tab-search glass" href="Search-Start.dc.html" aria-label="Search"><svg viewBox="0 0 24 24" aria-hidden="true">…search…</svg></a>
</nav>
```
Mini player (bottom accessory above tab bar):
```html
<a class="mini glass" href="NP-Signature.dc.html">
  <div class="art art-3 thumb"></div>
  <div class="row-text"><div class="t1" style="font-size:15px;font-weight:600">Last Stop Lullaby</div><div class="t2">Ada Okafor</div></div>
  <span class="icon-btn" aria-hidden="true"><svg viewBox="0 0 24 24" style="fill:currentColor;stroke:none">…pause…</svg></span>
  <span class="icon-btn" aria-hidden="true"><svg viewBox="0 0 24 24" style="fill:currentColor;stroke:none">…next…</svg></span>
</a>
```
Song row — in library: `<div class="art art-1 thumb"></div>`; not yet: `<div class="art art-5 thumb rec"></div>` + trailing `<button class="capsule">Try</button>`; fetching: `rec spin` + subtitle "Fetching · about 30 s"; sample: wrap in `<div class="arc" style="--p:70"><div class="art art-6 thumb rec fade-1"></div></div>` + trailing `<button class="capsule">Keep</button>`.

## Artboard name strip
Every artboard's `<title>` = the screen's name (e.g. "Search — merged results"). Do not put rationale text inside phone screens; rationale goes in your final report to the lead.
