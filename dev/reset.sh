#!/usr/bin/env bash
# Wipe the Magpie dev stack: containers, its compose volumes (Navidrome DB, Lidarr config, slskd),
# everything under dev/data (fixture music, downloads, cover cache) and dev/.env.local.
# Only ever touches the magpie-dev compose project and paths inside dev/.
#
#   dev/reset.sh          asks for confirmation
#   dev/reset.sh --yes    no prompt
#   dev/reset.sh --keep-music   keep dev/data/music (skip regenerating fixtures)
set -euo pipefail

DEV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ "$(basename "$DEV_DIR")" == dev && -f "$DEV_DIR/docker-compose.yml" ]] || { echo "not in the dev/ dir" >&2; exit 1; }

yes=0 keep_music=0
for a in "$@"; do
  case $a in --yes|-y) yes=1 ;; --keep-music) keep_music=1 ;; *) echo "unknown option $a" >&2; exit 2 ;; esac
done

if (( !yes )); then
  read -r -p "Delete the magpie-dev containers + volumes, $DEV_DIR/data$( (( keep_music )) && echo ' (except music/)') and .env.local? [y/N] " ans
  [[ "$ans" == [yY]* ]] || { echo "aborted"; exit 1; }
fi

docker compose -f "$DEV_DIR/docker-compose.yml" --profile quickfetch down --volumes --remove-orphans

if [[ -d "$DEV_DIR/data" ]]; then
  if (( keep_music )); then
    find "$DEV_DIR/data" -mindepth 1 -maxdepth 1 ! -name music -exec rm -rf {} +
  else
    rm -rf "${DEV_DIR:?}/data"
  fi
fi
rm -f "$DEV_DIR/.env.local"
echo "reset done. Run dev/bootstrap.sh to start fresh."
