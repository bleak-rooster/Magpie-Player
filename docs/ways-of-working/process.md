# Process: a round from request to release

Magpie is built in **rounds**. A round answers one owner request (a feature, a set of fixes, a hardening pass) and
ends with a tested TestFlight build. One session — the **controller** (a human, or the main AI session) — runs the
round; specialised agents do the work (`.claude/agents/`).

## 1. Request → plan

- The owner's words are quoted verbatim in the plan and are binding.
- The **planner** (`magpie-planner`) researches the code and the services, then writes a plan under
  `docs/superpowers/plans/` (or a spec under `docs/superpowers/specs/`). It separates **Decisions** (calls the planner
  may make, each with "cost if wrong") from **Owner** questions (numbered, recommendation first).
- **Nothing is built until the owner has answered.** Owner rulings that arrive mid-round go into the progress log
  and into the briefs they affect.
- Before the first task, the controller runs a **pre-flight conflict scan**: for each pair of workstreams, what one
  produces and the other consumes; mismatches are fixed in the plan first.

## 2. Plan → briefs

- Each round has a **common-rules** file (the round's global constraints, verbatim copy, test commands, the
  integration branch) and one **brief** per workstream (template in [templates.md](templates.md)).
- Workstreams are named by round letter and number (`A1`…`A7`, `C1`…`C4`, `S14` for a security fix pass, `FX` for a
  fix pass, `B1` for an owner bug report). Each brief gives:
  - the branch and base;
  - the commit prefix;
  - the **files the workstream owns** (disjoint from every other workstream);
  - numbered requirements with exact values;
  - a pre-assigned **decision-id range** (e.g. D161–D165; renumbered at merge if needed);
  - the tests to write first;
  - the report path.
- Large or risky UX work starts as a **design brief** ("write a design, no production code"), which is critiqued by
  `magpie-design-critic` before anyone builds.

## 3. Implement

- One **implementer** (`magpie-implementer`) per workstream, each on its own branch off the integration branch
  (`v0.0.1-custom` today; never `main` directly), in its own worktree when several run in parallel (up to 3–4).
- Tests RED first, then GREEN, with the evidence in the report. Commit after each step with explicit paths.
- New code goes in new files; big types get hook lines only. Follow the patterns of the code being touched.
- The implementer reports **DONE / DONE_WITH_CONCERNS / BLOCKED / NEEDS_CONTEXT**. It never dispatches subagents,
  merges, uploads or pushes, and never guesses at an ambiguous requirement.

## 4. Review → fix → re-review

- Every DONE gets a fresh **task review** (`magpie-task-reviewer`): spec compliance and code quality on the diff,
  findings **Critical (C1) / Important (I1) / Minor (M1)**, verdict **Approved / Needs fixes**.
- The controller rules on each finding (fix now, fix per ruling, defer: "Parked → T14") and records the ruling and
  its cost-if-wrong in the progress log.
- The implementer is resumed with the findings (a **fix round**, `"<WS> fix round N: I1 …; M2 …"`) and appends a fix
  section to its report.
- A **re-review** (`magpie-re-reviewer`) judges each finding (Fixed / Fixed per ruling / Not done) and reports new
  ones under fresh ids (R1, m1, then N1). Repeat until Approved.
- Rounds that touch writes, networking or credentials also get a **security review** (`magpie-security-reviewer`;
  Critical/High/Medium/Low), whose findings go to a dedicated fix pass (`S<round>`, one commit per finding id).
- Hardening rounds use **crash hunters** (`magpie-crash-hunter`); behaviour changes get **docs verification**
  (`magpie-docs-verifier`) against `docs/FLOWS.md`.

## 5. Merge → decisions

- The controller merges approved workstreams **one at a time** (`"Merge <branch>: <summary> (D###–D###)"`); each later
  workstream merges the latest integration branch before its final test run.
- `docs/decisions.md` gets the round's section (`### YYYY-MM-DD — round N, <WS>: <title>`), one row per decision:
  `| D### | **Title.** What and why, the rules that pin it. | Driven by | Status |`. Amendments go inline (`D104a`,
  `**Re-review:** …`, `Supersedes D131's …`).
- `docs/FLOWS.md`, `docs/RUNBOOK.md` and `docs/TESTFLIGHT.md` are updated in the same round.

## 6. Release

- Before a build: the gates in [testing-and-release.md](testing-and-release.md) (`scripts/test-all.sh`, or at least
  the package suite, the app suite, `check-writes.sh` and `check-release.sh`).
- Optionally a **final review** of the whole branch (`magpie-final-reviewer`, often three in parallel).
- The controller archives and uploads (`scripts/archive.sh --team <TEAM> --build <N> --upload`; the build number must
  go up every time), logs it in the progress log, and reports to the owner: what changed, what was decided without
  them (with cost if wrong), and what they should check by hand.

## The progress log

Each round keeps a ledger (template in [templates.md](templates.md)): every dispatch (agent, model, base SHA), every
verdict, every ruling, every owner answer, every build. It is how a round can be resumed by someone else.
