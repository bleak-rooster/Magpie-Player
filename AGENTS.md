# AGENTS.md — how to work on Magpie

This is the guide for any AI coding agent (Claude Code, Codex, Cursor, Copilot, Gemini, …) and for the humans directing
them. Read it in full before your first change. `CLAUDE.md` adds the Claude Code specifics; `CONTRIBUTING.md` is the
short human version; the detail lives in [`docs/ways-of-working/`](docs/ways-of-working/README.md).

## What Magpie is

An iOS and CarPlay music player for a self-hosted **Navidrome** server, with optional **Lidarr** (bring in music you
don't have yet: a "Try" lands in a separate *Finds* folder you can Keep or let go), optional **Aurral** (discovery:
charts, recommendations, flows) and optional **ListenBrainz** (scrobbling, recommendations). Every feature must work,
or be hidden or explained, in all four setups: Navidrome alone; + Lidarr; + Aurral; all of them.

Swift 6 (language mode 6), SwiftUI, iOS 26.0 and newer (built with the iOS 27 SDK; iOS 27-only APIs behind
`if #available(iOS 27, *)` with an iOS 26 fallback, D166), Xcode 27.1, XcodeGen. Most logic lives in the Swift package
`Packages/MagpieKit` so it tests on macOS with `swift test`; the app target in `App/` is a thin SwiftUI layer.

## Read before you change anything

1. `docs/decisions.md` — every decision, numbered (D1…D160+). It is the source of truth for *why*. Search it for the
   feature you touch; your change must not contradict a decision without a new one that supersedes it.
2. `docs/FLOWS.md` — how each flow behaves, end to end.
3. `docs/RUNBOOK.md` — running, testing, known limits.
4. The code you will touch, and its tests. **Follow the existing patterns, naming and comment density.**
5. [`docs/ways-of-working/rules.md`](docs/ways-of-working/rules.md) — the non-negotiables (summarised below).

## Non-negotiables (full list in `docs/ways-of-working/rules.md`)

- **Never touch the owner's data or servers.** Tests talk only to fakes or the local dev stack (`127.0.0.1`).
  Never delete or modify owner data. Diagnosis on a real server is read-only, by the owner's leave, and you never
  print a real server's address, username or key anywhere (code, tests, docs, commit messages, logs).
- **Lidarr writes go only through `LidarrWriteGate`** (`LidarrKit/WriteGate.swift`), off by default, confined by the
  ledger (`WriteConfinement`). A new write shape must be pinned in `scripts/check-writes.sh` (and survive
  `check-writes-selftest.sh`). Persist before every write (M6); a lost answer is re-proven before anything is sent
  again; **when in doubt, don't write**.
- **No direct calls to Deezer or Apple hosts** from the app (plan decision 11; `MagpieCore/RefusedMediaHosts.swift`).
  Outside media goes through the owner's Aurral server. Aurral routes are an exact allow-list (`AurralRoute`).
- **Secrets** live only in the Keychain; logs go through `Redactor`. Never commit keys, passwords, tokens, real
  hostnames or IPs — tests use `music.example`, `nas.local`, `100.64.x.x`, `jordan`, and so on.
- **UI copy** is plain and warm and talks about music, never about services ("Lidarr", "Navidrome", "Soulseek" appear
  only where a settings screen must name them). British spelling (Favourite, colour). State is always text plus a
  symbol, never colour or shape alone. Dynamic Type, 44 pt targets, VoiceOver labels and actions.
- **No dead buttons.** Anything that can't work in the current setup is hidden or says why.
- **Tests assert.** Swift Testing (`#expect`) for package and hosted tests; XCTest only for UI tests. Write the
  failing test first; never fake RED evidence. No sleeps — poll with deadlines.

## How work flows (full detail in `docs/ways-of-working/process.md`)

Owner request → **plan/spec** (decisions vs. owner questions; nothing built before the owner confirms) → **briefs**
per workstream → **implementer** (one branch/worktree each, tests first) → **task review** → fix rounds →
**re-review** until Approved → merge into the integration branch → **decisions logged** (`docs/decisions.md`) →
full test gates → release build. Security, design, crash-hunt and docs-verification passes run where the round
calls for them. Only the controller (the coordinating session or the human) merges, tags, archives, uploads or pushes.

Agents for each role are defined in `.claude/agents/` (readable by any tool: plain Markdown with a short header).
Branches, issues, pull requests, releases and the CI that guards them: [`docs/ways-of-working/github.md`](docs/ways-of-working/github.md).
Agents never push, merge, tag or open pull requests unless the controller has said so for that task.

## Commands

```sh
cd Packages/MagpieKit && swift test          # package tests (macOS, fast)
scripts/build.sh                              # generate the project (xcodegen) and build the app
scripts/test-app.sh                           # hosted app + UI tests on the dedicated "Magpie Tests" simulator
scripts/check-writes.sh                       # Lidarr write / Aurral route / forbidden-host audit
scripts/test-all.sh                           # everything a release needs (incl. Release-config legs)
scripts/check-release.sh                      # what a TestFlight build must look like (unsigned archives)
dev/bootstrap.sh && scripts/it.sh             # local Navidrome + Lidarr dev stack, then the integration tests
```

Never hand-edit `Magpie.xcodeproj` (generated from `project.yml`, git-ignored).

## Code conventions

- New work goes in **new files**: `AppModel+<Feature>.swift`, `RequestRunner+<Feature>.swift`. The big types get
  hook lines only.
- Doc comments say *why*, citing the round, workstream and decision: `/// Round 18 (owner, 2026-11-05): … (D152)`.
- No `try!`, `as!` or trapping conversions on data from a server (`Int(exactly:)`, bounded parsing). iOS-only APIs
  behind `#if os(iOS)` so the package builds on macOS.
- When a protocol gains a requirement, update every fake in `MagpieTestSupport` and the test harnesses.

## Commits and decisions

- Commit messages: `"<WS>: <plain-English outcome>"`, `"<WS> fix round N: I1 …; M2 …"`, `"Merge <branch>: <summary>
  (D###–D###)"`, `"Docs: …"`. Stage explicit paths; commit after each step.
- Add an AI-assistance trailer naming the model that wrote the commit (e.g. `Co-Authored-By: <model> <address>`).
- Every behaviour change gets a decision row in `docs/decisions.md` under a dated round heading:
  `| D### | **Title.** What and why, with the rules that pin it. | Driven by | Status |`.

## Reporting back

End every task with: **Status** (DONE / DONE_WITH_CONCERNS / BLOCKED / NEEDS_CONTEXT), commits (SHA + subject), a
one-line test summary with real counts, concerns, and what you did *not* do. Say plainly when something wasn't run
or failed. If you're refused a permission, report it — never work around it.
