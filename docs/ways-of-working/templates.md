# Templates

Copy these. The controller fills in the brief and the common rules; agents produce the rest.

## Round common rules (`<round>-common.md`)

```
# Round N — common rules (every brief includes this)
Integration branch: v0.0.1-custom. Base: <sha>.
Owner's words (binding): "<verbatim request>"
Global constraints: <the rules from rules.md that matter most this round, verbatim copy strings>
Commands: swift test (package) · scripts/test-app.sh / -only-testing:… (app) · scripts/check-writes.sh
Ownership: A1 owns <files>; A2 owns <files>; … (no file is owned twice)
Decision ranges: A1 D161–D165; A2 D166–D170; …
Never: touch the owner's servers or data; print real addresses or keys; dispatch subagents; merge, upload or push.
```

## Workstream brief (`<WS>-brief.md`)

```
# <WS>: <title>
Branch: <ws-branch> off v0.0.1-custom @ <sha>   Commit prefix: "<WS>: "   Report: <path>/<WS>-report.md
Owns: <files>   Decisions: D###–D###
Read first: AGENTS.md, rules.md, <decisions>, <files>
Requirements:
1. <exact behaviour, values, copy>
2. …
Tests RED first: <test names and what each pins>
Done when: <the observable outcome and the command that proves it>
Not this workstream: <out of scope>
```

## Implementer report (`<WS>-report.md`)

```
# <WS> report
Status: DONE | DONE_WITH_CONCERNS | BLOCKED | NEEDS_CONTEXT
Built: <what, file by file>
Decisions: D### — <one line each>
Tests: <names>; RED: <command + failing output>; GREEN: <suite counts>
Self-review: <diff vs brief, line by line>
Concerns / not done: <…>
Commits: <sha subject>
## Fix round 1 (appended)
I1: <what changed, file:line, test>
```

## Task review

```
### Spec compliance ✅ | ❌
- requirement 1: ✅ file:line
### Strengths
### Issues
**Critical** C1 · **Important** I1 · **Minor** M1 — file:line, why, fix
**Task quality:** Approved | Needs fixes
```

## Re-review

```
| Finding | Verdict (Fixed / Fixed per ruling / Not done ⚠️) | Evidence |
### New findings (R1…, m1…, N1…)
**Verdict:** Approved | Needs fixes
```

## Progress log (`<round>/progress.md`)

```
<date> Task A1: dispatched (model, base <sha>)
<date> A1: DONE (report path) — review: Needs fixes: C1, I1–I3, M1
<date> Ruling: I2 fix per ruling (<what>) — cost if wrong: <…>
<date> Owner: "<answer>" → affects A3 brief
<date> A1 re-review: Approved. Merged <sha> (D161–D165)
<date> BUILD <N> UPLOADED from <sha>
```

## Report to the owner (end of round)

What changed (in their words, not ours), what was decided without them and the cost if wrong, what was tested and
what wasn't, what they should try first, and any question only they can answer.
