#!/usr/bin/env bash
# Creates (or updates) the repository's labels with the GitHub CLI. Idempotent; run once after creating the
# repository and again whenever docs/ways-of-working/github.md › Labels changes.  Usage: scripts/github-labels.sh [owner/repo]
set -euo pipefail
repo=(); [ $# -ge 1 ] && repo=(--repo "$1")
label() { gh label create "$1" --color "$2" --description "$3" --force "${repo[@]}"; }

label "type: bug"         d73a4a "Something isn't working"
label "type: feature"     0e8a16 "Something new, or a change in behaviour"
label "type: security"    b60205 "Owner-data safety, credentials, privacy"
label "type: docs"        0075ca "Documentation and ways of working"
label "type: tests"       c5def5 "Tests only"
label "area: requests"    5319e7 "Try, Finds, Keep, Not for me"
label "area: lidarr"      5319e7 "LidarrKit and the write gate"
label "area: aurral"      5319e7 "Discovery through Aurral"
label "area: playback"    5319e7 "Player, queue, downloads"
label "area: carplay"     5319e7 "CarPlay"
label "area: search"      5319e7 "Search and matching"
label "area: ui"          5319e7 "Screens and design system"
label "area: build"       5319e7 "Project, scripts, CI"
label "needs: triage"     fbca04 "Not looked at yet"
label "needs: owner"      fbca04 "Waiting on a decision only the maintainer can make"
label "needs: plan"       fbca04 "Agreed, waiting for a plan"
label "good first issue"  7057ff "Small and well-defined"
label "dependencies"      ededed "Dependency updates"
label "skip-changelog"    ededed "Left out of release notes"
