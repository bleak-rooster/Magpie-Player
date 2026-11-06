# GitHub: branches, issues, pull requests, releases and automation

How the repository is run on GitHub, and what is automated. Humans and AI agents follow the same rules; the extra rules
for agents are at the end.

## Branches

| Branch | What it is | Who writes to it |
|---|---|---|
| `main` | What has shipped (or is about to): every commit on it passed CI and the release gates | Merged pull requests only; protected |
| Integration branch (today `v0.0.1-custom`) | The current release line: approved workstreams are merged here one at a time | The controller, through pull requests |
| Topic branches | One workstream, fix or doc change each | Its author / implementer |

- **Name topic branches** after the workstream and what it does, lower-case with hyphens: `<round><n>-<slug>` for a
  planned workstream (`d2-lyrics-cache`), `fix-<slug>` for a bug, `docs-<slug>` for documentation, `sec-<slug>` for a
  security fix. A branch is for one topic only.
- Branch from the integration branch and merge its latest state into yours before your final test run.
- **Delete a branch once it is merged** (GitHub's "Automatically delete head branches" setting does this).
- **Never push agent worktree branches** (`worktree-agent-*`), WIP snapshots or local experiments. Push only branches
  that are meant to become a pull request.
- Never force-push `main` or the integration branch. On your own topic branch, `--force-with-lease` before review is
  fine; after review starts, add commits instead.

## Issues

- Every piece of work starts as an issue, from a template: **Something isn't working** (bug) or **Idea or request**
  (feature). Blank issues are off. Security or privacy problems are reported **privately** (Security › Report a
  vulnerability), never in a public issue.
- **Nobody pastes a real server address, username, password, key, token or unredacted log** into an issue, pull
  request or comment. Use `music.example`, `jordan`, `test-key`.
- **Triage** (the maintainer, weekly): each new issue (`needs: triage`) gets a type, an area and one of:
  - `needs: owner`: a decision only the maintainer can make;
  - `needs: plan`: agreed, but too big to start without a plan;
  - ready to work on, optionally with `good first issue`;
  - closed with a reason.
- A planned round is a **milestone** (e.g. "Round 20: …"); its workstreams are issues in that milestone, and the plan
  (`docs/superpowers/plans/…`) links them. Decisions made while working an issue are recorded in `docs/decisions.md`
  and the decision ids are posted on the issue.
- Close issues from the pull request (`Fixes #123`), not by hand.

## Labels

Created with `scripts/github-labels.sh` (idempotent; needs the GitHub CLI signed in). Pull requests also get area
labels automatically from the files they touch (`.github/labeler.yml`).

| Group | Labels |
|---|---|
| Type | `type: bug`, `type: feature`, `type: security`, `type: docs`, `type: tests` |
| Area | `area: requests`, `area: lidarr`, `area: aurral`, `area: playback`, `area: carplay`, `area: search`, `area: ui`, `area: build` |
| State | `needs: triage`, `needs: owner`, `needs: plan` |
| Other | `good first issue`, `dependencies`, `skip-changelog` |

## Pull requests

- One pull request per topic branch, into the **integration branch** (or into `main` for the release merge). Open it
  as a **draft** while work continues; mark it ready when the checklist is true.
- Fill in the template (`.github/pull_request_template.md`) honestly. "Not done / not run" is never left blank when
  something wasn't run.
- **Required to merge:**
  - CI green (audit, package tests, secret scan);
  - one approving review from a code owner (`.github/CODEOWNERS`);
  - conversations resolved.

  Changes to the write gate, `check-writes.sh` or `RefusedMediaHosts.swift` always need the maintainer's review.
- Review follows `docs/ways-of-working/process.md`: findings as Critical / Important / Minor with ids, fixed in new
  commits (`"<WS> fix round N: I1 …"`), then re-reviewed.
- **Merge with a merge commit**, titled as in the commit-message conventions: `"Merge <branch>: <summary>
  (D###–D###)"`. This keeps each workstream's commits and their review trail. Small single-commit fixes may be
  squashed.
- The release merge from the integration branch into `main` is a pull request too, after the release gates.

## Releases and tags

- Every TestFlight upload is tagged on the commit it was built from: an annotated tag
  `v<version>-b<build>` (e.g. `v0.0.1-b21`), with the round and the decision range in its message. Milestone tags
  from v1 (`m0`…`m8`, `v1.0-rc`) stay as they are.
- A **GitHub Release** is drafted from the tag with generated notes (categories in `.github/release.yml`, by label).
  The notes say what changed for a listener, in plain words, and link the decisions.
- Never attach an `.ipa`, archive, log or screenshot with personal data to a release.

## CI and automation

| What | Where | When |
|---|---|---|
| Write and privacy audit (`check-writes.sh` + self-test) | `.github/workflows/ci.yml` | Every pull request and push to `main` |
| Package tests (`swift test`) | `.github/workflows/ci.yml` | Every pull request and push to `main` |
| Secret scan (gitleaks) | `.github/workflows/ci.yml` | Every pull request and push to `main` |
| App and UI tests (`scripts/test-app.sh`) | `.github/workflows/app-tests.yml` | By hand (Actions › App tests) and weekly |
| Area labels on pull requests | `.github/workflows/labeler.yml` + `.github/labeler.yml` | Every pull request |
| Workflow action updates | `.github/dependabot.yml` | Weekly |
| Release-note categories | `.github/release.yml` | When a release is drafted |
| Repository labels | `scripts/github-labels.sh` | Once, and when the label table changes |

- The workflows need **Xcode 27** on the runner. If GitHub's hosted macOS images don't have it yet, the "Select the
  newest Xcode 27" step fails with a clear error: run the jobs on a self-hosted Mac runner until they do.
- CI never talks to a real server: the dev-stack and live tests (`MAGPIE_IT`, `MAGPIE_LIVE`) are not run in CI.
- No repository secrets are needed. Never add a server address, key or signing credential as an Actions secret; the
  TestFlight upload stays a local, controller-only step (`scripts/archive.sh`).

## Repository settings (set once, by the maintainer)

- **Branch protection** on `main` and the integration branch:
  - require a pull request;
  - require 1 approving review and code-owner review;
  - require the CI checks *Write and privacy audit*, *Package tests* and *Secret scan* to pass and the branch to be
    up to date;
  - require conversations resolved;
  - block force pushes and deletions.
- **General:**
  - allow merge commits and squash merges, not rebase merges;
  - "Automatically delete head branches" on.
- **Security:**
  - private vulnerability reporting on;
  - secret scanning and push protection on;
  - Dependabot alerts on.
- **Issues:**
  - templates as committed (blank issues off);
  - labels from `scripts/github-labels.sh`.

## AI agents and GitHub

- Agents use the GitHub CLI (`gh`) and follow everything above. **Only the controller** (the human, or the session
  they've authorised) pushes branches, opens pull requests, merges, tags or drafts releases. Implementers and
  reviewers work locally and report back.
- An agent may draft issue text, a pull-request description or a review comment for the controller to post, and may
  post them itself only when the controller has said so for that task.
- Pull requests from an agent are opened as **drafts**, use the template, list everything not run, and end with the
  attribution line the session's instructions give.
- In anything an agent writes on GitHub, a bare `@name` notifies that person: only mention real people on purpose;
  put code, roles and placeholders in backticks (`` `@MainActor` ``, `` `@owner` ``).
- Agents never push to `main` or the integration branch directly, never force-push a shared branch, never delete a
  branch they didn't create, and never change repository settings, secrets or branch protection.
- If GitHub (or the harness) refuses an action, stop and report it; don't look for another way round.
