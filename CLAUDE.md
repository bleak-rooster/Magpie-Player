# CLAUDE.md

@AGENTS.md

## Claude Code specifics

**Agents.** The project's roles are subagents in `.claude/agents/`. Use them the way the project always has:

| Agent | Use it for | Writes code? |
|---|---|---|
| `magpie-planner` | Turning an owner request into a plan/spec with decisions and owner questions | No (docs only) |
| `magpie-implementer` | One workstream from a brief, tests first, in its own worktree | Yes |
| `magpie-task-reviewer` | Spec compliance + code quality of one workstream's diff | No |
| `magpie-re-reviewer` | Checking each earlier finding against the fix diff | No |
| `magpie-security-reviewer` | Adversarial review of a round (gate, confinement, privacy, secrets) | No |
| `magpie-design-critic` | Persona-driven UX / accessibility / CarPlay critique of a design or build | No |
| `magpie-crash-hunter` | Finding traps, hangs, races; RED repro → minimal fix → GREEN; seeded fuzz tests | Yes (fixes) |
| `magpie-docs-verifier` | Checking `docs/FLOWS.md` statements against the code; `docClaim_` tests | Tests only |
| `magpie-final-reviewer` | Whole-branch review before a release | No |

**The main session is the controller.** It writes the briefs (templates in
`docs/ways-of-working/templates.md`), dispatches agents, makes rulings, keeps the round's progress log, merges, and is
the only one that archives, uploads, tags or pushes. Implementers never dispatch subagents; reviewers never edit.

**Parallel implementers** each get `isolation: "worktree"`, a disjoint set of files they own, and their own
simulator if they run app tests (`scripts/test-sim.sh` makes the shared "Magpie Tests" one; parallel agents create
and delete their own). Merge them one at a time; each merges the latest integration branch before its final run.

**Long commands** (the app suite takes ~8 minutes, `test-all.sh` much longer): run them in the background and wait
for the notification rather than blocking a call for more than 10 minutes.

**Permissions.** If the harness refuses an action (a history rewrite, a force delete, a push), stop and ask the
human; never route around it.
