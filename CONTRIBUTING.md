# Contributing to Magpie

Thanks for helping. Magpie talks to people's own music servers, so the bar is: **never surprise the owner, never touch
their data, never leak their details.** The full guide is [`AGENTS.md`](AGENTS.md) and
[`docs/ways-of-working/`](docs/ways-of-working/README.md); this page is the short version.

## Before you start

1. Read [`docs/ways-of-working/rules.md`](docs/ways-of-working/rules.md) and the decisions in
   [`docs/decisions.md`](docs/decisions.md) that touch your area.
2. For anything bigger than a small fix, open an issue or write a short plan first
   ([`docs/ways-of-working/process.md`](docs/ways-of-working/process.md)): what changes, which decisions it adds or
   supersedes, and how it behaves without Lidarr, Aurral or ListenBrainz.

## Making the change

- Branch off the integration branch; one topic per branch.
- Write the failing test first (Swift Testing), then the code. Follow the surrounding code's patterns, naming and
  comment density; new features go in new files.
- Lidarr writes only through `LidarrWriteGate`, pinned in `scripts/check-writes.sh`. No direct calls to Deezer or
  Apple hosts. No secrets, real hostnames, IPs or usernames anywhere — use `music.example`, `nas.local`, `jordan`.
- UI copy: plain, warm, about music, British spelling; state as text plus a symbol; Dynamic Type and VoiceOver.
- Add or update the decision rows in `docs/decisions.md` and the affected docs (`FLOWS.md`, `RUNBOOK.md`).

## Before you open a pull request

```sh
cd Packages/MagpieKit && swift test
scripts/check-writes.sh
scripts/test-app.sh            # or the hosted suites your change can affect
```

Commit messages: `"<area>: <plain-English outcome>"`. If an AI assistant wrote part of a commit, add a trailer naming
the model. Fill in the pull-request checklist honestly, including anything you didn't run.

## Security

Found something that could leak credentials or change someone's server unexpectedly? Please report it privately to
the maintainer rather than in a public issue.
