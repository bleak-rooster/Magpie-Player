# Ways of working

How Magpie is built, so a new contributor — human or AI — works the way the project always has.

| Document | What it covers |
|---|---|
| [process.md](process.md) | A round from the owner's request to a TestFlight build: plan, briefs, implement, review, fix, merge, decisions, release |
| [rules.md](rules.md) | The non-negotiables: owner-data safety, the Lidarr write gate, privacy, copy, accessibility, code and tests |
| [testing-and-release.md](testing-and-release.md) | The test layers, the dev stack, the gates a build must pass, archiving and uploading |
| [templates.md](templates.md) | The brief, report, review, re-review and progress-log formats |
| [github.md](github.md) | Branches, issues, labels, pull requests, releases and tags, CI and automation, repository settings, and how agents use GitHub |
| [`../../.claude/agents/`](../../.claude/agents/) | One definition per role: planner, implementer, task reviewer, re-reviewer, security reviewer, design critic, crash hunter, docs verifier, final reviewer |

Start with [`../../AGENTS.md`](../../AGENTS.md). The record of *why* is [`../decisions.md`](../decisions.md); how
each flow behaves is [`../FLOWS.md`](../FLOWS.md); past plans are in [`../superpowers/plans/`](../superpowers/plans/)
and past reviews in [`../reviews/`](../reviews/).
