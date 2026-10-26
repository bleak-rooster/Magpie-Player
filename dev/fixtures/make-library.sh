#!/usr/bin/env bash
# Generate the Magpie dev fixture library with ffmpeg.
#
#   dev/fixtures/make-library.sh            # create missing files only (idempotent)
#   dev/fixtures/make-library.sh --force    # wipe dev/data/music/{library,samples} and regenerate
#
# Output (all under dev/data/music, which is gitignored and bind-mounted at /music in the containers):
#   library/  main library: 5 artists + Various Artists, 6 albums, 41 tracks
#   samples/  the Samples ("Finds") library: 1 single by an artist not in the main library
#
# Edge cases covered (see dev/README.md for the table):
#   FLAC gapless album (one continuous sweep split sample-exactly) - MP3 with LAME/Xing header - MP3 without it
#   AAC/M4A album - multi-disc album split across CD1/CD2 folders - accents, CJK - very long title -
#   compilation (Various Artists) - full tags incl. MusicBrainz IDs (deterministic v4-style UUIDs) and ISRCs -
#   embedded PNG cover art (+ folder cover.png on some albums) - one album with no MBIDs at all.
#
# Cover text needs ffmpeg's drawtext filter. If the local ffmpeg lacks it (Homebrew's default build does),
# the script renders covers with the ffmpeg inside the pinned Navidrome image plus a Unicode font copied from
# the host (FONT=/path/to/font.ttf to override). Without either, covers are plain gradients.
set -euo pipefail

DEV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MUSIC="$DEV_DIR/data/music"
CACHE="$DEV_DIR/data/.fixture-cache"
FFMPEG="${FFMPEG:-$(command -v ffmpeg || echo /opt/homebrew/bin/ffmpeg)}"
ND_IMAGE="${ND_IMAGE:-deluan/navidrome:0.64.2}"
SR=44100

[[ -x "$FFMPEG" ]] || { echo "ffmpeg not found (set FFMPEG=...)" >&2; exit 1; }

if [[ "${1:-}" == "--force" ]]; then
  # Only ever delete inside dev/data/music.
  case "$MUSIC" in */dev/data/music) ;; *) echo "refusing to wipe $MUSIC" >&2; exit 1 ;; esac
  rm -rf "$MUSIC/library" "$MUSIC/samples" "$CACHE/covers"
fi
mkdir -p "$MUSIC/library" "$MUSIC/samples" "$CACHE/covers"

ff() { "$FFMPEG" -hide_banner -loglevel error -nostdin "$@"; }

# Deterministic, real-looking (version 4, RFC 4122 variant) UUID from a seed string.
mbid() {
  local h v
  h=$(printf '%s' "magpie-fixture:$1" | shasum -a 1 | cut -c1-32)
  v=$(printf '%x' $(( (16#${h:16:1} & 3) | 8 )))
  printf '%s-%s-4%s-%s%s-%s\n' "${h:0:8}" "${h:8:4}" "${h:13:3}" "$v" "${h:17:3}" "${h:20:12}"
}

# ---------------------------------------------------------------- covers
COVER_MODE=plain
FONT="${FONT:-}"
if [[ -z "$FONT" ]]; then
  for f in "/System/Library/Fonts/Supplemental/Arial Unicode.ttf" "/Library/Fonts/Arial Unicode.ttf" \
           /usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc /usr/share/fonts/truetype/dejavu/DejaVuSans.ttf; do
    [[ -f "$f" ]] && { FONT="$f"; break; }
  done
fi
if [[ -n "$FONT" ]]; then
  [[ -f "$CACHE/font.ttf" ]] || cp "$FONT" "$CACHE/font.ttf"
  if "$FFMPEG" -hide_banner -filters 2>/dev/null | grep -q ' drawtext '; then
    COVER_MODE=local
  elif command -v docker >/dev/null && docker image inspect "$ND_IMAGE" >/dev/null 2>&1; then
    COVER_MODE=docker
  fi
fi
echo "cover text renderer: $COVER_MODE"

# make_cover <out.png> <color0> <color1> <line1> <line2>
make_cover() {
  local out=$1 c0=$2 c1=$3 l1=$4 l2=$5 key
  [[ -f "$out" ]] && return 0
  key=$(printf '%s' "$l1|$l2" | shasum -a 1 | cut -c1-12)
  printf '%s' "$l1" > "$CACHE/covers/$key.1.txt"
  printf '%s' "$l2" > "$CACHE/covers/$key.2.txt"
  local base="gradients=s=600x600:c0=0x$c0:c1=0x$c1:x0=0:y0=0:x1=600:y1=600:d=1"
  case $COVER_MODE in
    plain) ff -f lavfi -i "$base" -frames:v 1 -y "$out.tmp.png" ;;
    local|docker)
      local fp=/c
      [[ $COVER_MODE == local ]] && fp="$CACHE"
      local vf="$base,drawbox=x=0:y=410:w=600:h=190:color=black@0.45:t=fill"
      vf+=",drawtext=fontfile=$fp/font.ttf:textfile=$fp/covers/$key.1.txt:fontsize=40:fontcolor=white:x=30:y=440"
      vf+=",drawtext=fontfile=$fp/font.ttf:textfile=$fp/covers/$key.2.txt:fontsize=28:fontcolor=white@0.85:x=30:y=510"
      if [[ $COVER_MODE == local ]]; then
        ff -f lavfi -i "$vf" -frames:v 1 -y "$out.tmp.png"
      else
        docker run --rm -v "$CACHE":/c --entrypoint ffmpeg "$ND_IMAGE" -hide_banner -loglevel error -nostdin \
          -f lavfi -i "$vf" -frames:v 1 -y "/c/covers/$key.png"
        mv "$CACHE/covers/$key.png" "$out.tmp.png"
      fi ;;
  esac
  mv "$out.tmp.png" "$out"
}

# ---------------------------------------------------------------- audio
# Album-level settings (set by `album`, read by `track`).
A_ROOT= A_DIR= A_TITLE= A_ARTIST= A_DATE= A_ORIGDATE= A_GENRE= A_FMT= A_COMP=0 A_DISCS=1 A_TOTAL=0 A_MBIDS=1
A_COVER= A_GAPLESS=0 A_LABEL=
GAPLESS_OFFSET=0 GAPLESS_TOTAL=0

album() { # album <root> <dir> <title> <albumartist> <date> <genre> <fmt> <tracks> [discs] [compilation] [mbids]
  A_ROOT=$1 A_DIR=$2 A_TITLE=$3 A_ARTIST=$4 A_DATE=$5 A_GENRE=$6 A_FMT=$7 A_TOTAL=$8
  A_DISCS=${9:-1} A_COMP=${10:-0} A_MBIDS=${11:-1} A_GAPLESS=0 A_ORIGDATE=$5
  mkdir -p "$MUSIC/$A_ROOT/$A_DIR"
  A_COVER="$CACHE/covers/$(printf '%s' "$A_ARTIST|$A_TITLE" | shasum -a 1 | cut -c1-12)-art.png"
  echo "== $A_ARTIST - $A_TITLE ($A_FMT)"
}

# track <subdir|.> <disc> <n> <title> <artist> <seconds> <freq> [isrc]
track() {
  local sub=$1 disc=$2 n=$3 title=$4 artist=$5 dur=$6 freq=$7 isrc=${8:-}
  local ext codec=() nn fname dir out
  case $A_FMT in
    flac) ext=flac; codec=(-c:a flac -compression_level 5) ;;
    mp3) ext=mp3; codec=(-c:a libmp3lame -b:a 192k -id3v2_version 3) ;;            # Xing+LAME header (gapless info)
    mp3nolame) ext=mp3; codec=(-c:a libmp3lame -b:a 160k -write_xing 0 -id3v2_version 3) ;; # no Xing/LAME header
    mp3v0) ext=mp3; codec=(-c:a libmp3lame -q:a 0 -id3v2_version 3) ;;              # VBR V0 with Xing/LAME
    m4a) ext=m4a; codec=(-c:a aac -b:a 192k -movflags +faststart) ;;
  esac
  printf -v nn '%02d' "$n"
  local safe=${title//\//-}
  if (( A_DISCS > 1 )); then fname="$disc-$nn - $safe"; else fname="$nn - $safe"; fi
  (( ${#fname} > 120 )) && fname="${fname:0:120}"
  dir="$MUSIC/$A_ROOT/$A_DIR"; [[ "$sub" != . ]] && dir="$dir/$sub"
  mkdir -p "$dir"
  out="$dir/$fname.$ext"
  if (( A_GAPLESS )); then
    local start=$GAPLESS_OFFSET end=$(( GAPLESS_OFFSET + dur * SR ))
    GAPLESS_OFFSET=$end
  fi
  [[ -f "$out" ]] && { echo "   skip $fname.$ext"; return 0; }

  local src
  if (( A_GAPLESS )); then
    # One continuous stereo chirp over the whole album; each track is a sample-exact slice of it, so any gap
    # or overlap at a track boundary is audible as a click/discontinuity. Fades only at album start/end.
    local T=$GAPLESS_TOTAL
    src="aevalsrc=exprs='0.35*sin(2*PI*(110*t+(330/(2*$T))*t*t))|0.35*sin(2*PI*(110.5*t+(330/(2*$T))*t*t))':s=$SR:d=$T"
    src+=",atrim=start_sample=$start:end_sample=$end,asetpts=PTS-STARTPTS"
    (( start == 0 )) && src+=",afade=t=in:d=1"
    (( end == T * SR )) && src+=",afade=t=out:st=$(( dur - 2 )):d=2"
  else
    # Sine with slow tremolo plus a little noise; short fades.
    src="aevalsrc=exprs='0.3*sin(2*PI*$freq*t)*(0.7+0.3*sin(2*PI*0.5*t))+0.02*(random(0)*2-1)|0.3*sin(2*PI*($freq*1.5)*t)*(0.7+0.3*sin(2*PI*0.33*t))+0.02*(random(1)*2-1)':s=$SR:d=$dur"
    src+=",afade=t=in:d=0.3,afade=t=out:st=$(( dur - 1 )):d=1"
  fi

  local md=(-metadata "title=$title" -metadata "artist=$artist" -metadata "album=$A_TITLE"
            -metadata "album_artist=$A_ARTIST" -metadata "track=$n/$A_TOTAL" -metadata "disc=$disc/$A_DISCS"
            -metadata "date=$A_DATE" -metadata "genre=$A_GENRE")
  (( A_COMP )) && md+=(-metadata "compilation=1")
  [[ -n "$A_LABEL" ]] && md+=(-metadata "publisher=$A_LABEL")
  if [[ -n "$isrc" && $A_FMT != m4a ]]; then md+=(-metadata "ISRC=$isrc"); fi
  if (( A_MBIDS )); then
    local rec rel rg art aart reltrk
    rec=$(mbid "recording:$artist:$title"); rel=$(mbid "release:$A_ARTIST:$A_TITLE")
    rg=$(mbid "release-group:$A_ARTIST:$A_TITLE"); art=$(mbid "artist:$artist"); aart=$(mbid "artist:$A_ARTIST")
    [[ "$A_ARTIST" == "Various Artists" ]] && aart=89ad4ac3-39f7-470e-963a-56509c546377  # real MB "Various Artists"
    reltrk=$(mbid "release-track:$A_TITLE:$disc:$n")
    case $A_FMT in
      flac)
        md+=(-metadata "MUSICBRAINZ_TRACKID=$rec" -metadata "MUSICBRAINZ_RELEASETRACKID=$reltrk"
             -metadata "MUSICBRAINZ_ALBUMID=$rel" -metadata "MUSICBRAINZ_RELEASEGROUPID=$rg"
             -metadata "MUSICBRAINZ_ARTISTID=$art" -metadata "MUSICBRAINZ_ALBUMARTISTID=$aart"
             -metadata "ORIGINALDATE=$A_ORIGDATE" -metadata "RELEASETYPE=album") ;;
      mp3*)
        md+=(-metadata "MusicBrainz Track Id=$rec" -metadata "MusicBrainz Release Track Id=$reltrk"
             -metadata "MusicBrainz Album Id=$rel" -metadata "MusicBrainz Release Group Id=$rg"
             -metadata "MusicBrainz Artist Id=$art" -metadata "MusicBrainz Album Artist Id=$aart"
             -metadata "originalyear=${A_ORIGDATE:0:4}") ;;
      m4a)
        # ffmpeg's mp4 muxer can't write iTunes freeform (----:com.apple.iTunes:MusicBrainz *) atoms, and its
        # use_metadata_tags mode drops the embedded cover. So this album has no MBIDs - a realistic gap that
        # the app's matcher must handle (fall back to artist/album/title matching).
        : ;;
    esac
  fi

  ff -f lavfi -i "$src" -i "$A_COVER" -map 0:a -map 1:v "${codec[@]}" \
     -c:v copy -disposition:v attached_pic -metadata:s:v title="Album cover" -metadata:s:v comment="Cover (front)" \
     "${md[@]}" -f "$( [[ $ext == m4a ]] && echo ipod || echo "$ext" )" -y "$out.part"
  mv "$out.part" "$out"
  echo "   made $fname.$ext (${dur}s)"
}

folder_cover() { [[ -f "$MUSIC/$A_ROOT/$A_DIR/cover.png" ]] || cp "$A_COVER" "$MUSIC/$A_ROOT/$A_DIR/cover.png"; }

# ================================================================ the library

# 1. Aurora Field - Continuum: FLAC, gapless (continuous sweep), folder cover, full MBIDs + ISRCs.
album library "Aurora Field/Continuum (2019)" "Continuum" "Aurora Field" "2019-03-15" "Ambient" flac 6
A_LABEL="Northern Drift Recordings"
make_cover "$A_COVER" 1b2a4e 6fc3df "Continuum" "Aurora Field"
A_GAPLESS=1 GAPLESS_OFFSET=0 GAPLESS_TOTAL=$(( 14 + 11 + 17 + 9 + 13 + 18 ))
track . 1 1 "First Light"            "Aurora Field" 14 0 GBXYZ1900001
track . 1 2 "Drift"                  "Aurora Field" 11 0 GBXYZ1900002
track . 1 3 "Continuum, Part I"      "Aurora Field" 17 0 GBXYZ1900003
track . 1 4 "Continuum, Part II"     "Aurora Field" 9  0 GBXYZ1900004
track . 1 5 "Low Tide"               "Aurora Field" 13 0 GBXYZ1900005
track . 1 6 "Last Light"             "Aurora Field" 18 0 GBXYZ1900006
folder_cover; A_GAPLESS=0 A_LABEL=

# 2. Aurora Field - Lowlands: MP3 CBR 192 with Xing/LAME header, embedded cover only.
album library "Aurora Field/Lowlands (2016)" "Lowlands" "Aurora Field" "2016" "Ambient" mp3 6
make_cover "$A_COVER" 2e4a3a d8c27a "Lowlands" "Aurora Field"
track . 1 1 "Peat"           "Aurora Field" 12 220 GBXYZ1600011
track . 1 2 "Heron"          "Aurora Field" 9  247
track . 1 3 "Estuary"        "Aurora Field" 16 262
track . 1 4 "Salt Marsh"     "Aurora Field" 8  294
track . 1 5 "Lowlands"       "Aurora Field" 19 330 GBXYZ1600015
track . 1 6 "Fog Bank"       "Aurora Field" 10 349

# 3. Éléonore Brûlé - Café de la Mémoire: MP3 without Xing/LAME header, accents, NO MusicBrainz IDs (untagged rip).
album library "Éléonore Brûlé/Café de la Mémoire (2008)" "Café de la Mémoire" "Éléonore Brûlé" "2008-11-03" "Chanson" mp3nolame 6 1 0 0
make_cover "$A_COVER" 5a1e2e f0b08a "Café de la Mémoire" "Éléonore Brûlé"
track . 1 1 "L'été où tout a changé"     "Éléonore Brûlé" 13 196
track . 1 2 "Àlbum de famille"           "Éléonore Brûlé" 10 220
track . 1 3 "Ça ne fait rien"            "Éléonore Brûlé" 15 247
track . 1 4 "Déjà-vu (rue Saint-Honoré)" "Éléonore Brûlé" 9  262
track . 1 5 "Noël à Montréal"            "Éléonore Brûlé" 17 294
track . 1 6 "Œuvre inachevée"            "Éléonore Brûlé" 11 330
folder_cover

# 4. 坂本光 - 夜明けの街: AAC/M4A, CJK names, one very long title.
album library "坂本光/夜明けの街 (2021)" "夜明けの街" "坂本光" "2021-07-07" "J-Pop" m4a 7
make_cover "$A_COVER" 0e1a40 ff6f91 "夜明けの街" "坂本光 (Hikari Sakamoto)"
track . 1 1 "夜明けの街"   "坂本光" 12 330
track . 1 2 "東京タワー"   "坂本光" 9  370
track . 1 3 "雨の日曜日"   "坂本光" 15 392
track . 1 4 "さよなら、夏" "坂本光" 8  440
track . 1 5 "夜空に溶ける光のように、君の名前を何度も呼んだあの日の帰り道で (Extended Night-Drive Version, Remastered 2024 — Live at the Lighthouse)" "坂本光" 20 494
track . 1 6 "星屑"         "坂本光" 11 523
track . 1 7 "おやすみ"     "坂本光" 14 587

# 5. The Midnight Cartographers - Atlas of Small Hours: 2-disc FLAC split across CD1/CD2, featured artist.
album library "The Midnight Cartographers/Atlas of Small Hours (2022)" "Atlas of Small Hours" "The Midnight Cartographers" "2022-10-21" "Indie Rock" flac 10 2
make_cover "$A_COVER" 111111 c9a227 "Atlas of Small Hours" "The Midnight Cartographers"
track CD1 1 1 "North by Northwest"   "The Midnight Cartographers" 12 147 USMC12200101
track CD1 1 2 "Compass Rose"         "The Midnight Cartographers" 9  165 USMC12200102
track CD1 1 3 "Contour Lines"        "The Midnight Cartographers" 14 175
track CD1 1 4 "Terra Incognita"      "The Midnight Cartographers feat. Éléonore Brûlé" 16 196 USMC12200104
track CD1 1 5 "Meridian"             "The Midnight Cartographers" 10 220
track CD2 2 1 "Small Hours"          "The Midnight Cartographers" 18 110 USMC12200201
track CD2 2 2 "Dead Reckoning"       "The Midnight Cartographers" 8  123
track CD2 2 3 "Scale 1:1"            "The Midnight Cartographers" 13 131
track CD2 2 4 "Here Be Dragons"      "The Midnight Cartographers" 11 147
track CD2 2 5 "Home Port"            "The Midnight Cartographers" 20 165 USMC12200205
folder_cover

# 6. Various Artists - Late Night Finds, Vol. 1: compilation, MP3 VBR V0, artists both in and outside the library.
album library "Various Artists/Late Night Finds, Vol. 1 (2023)" "Late Night Finds, Vol. 1" "Various Artists" "2023-05-05" "Electronic" mp3v0 6 1 1
make_cover "$A_COVER" 3b0a45 22d1ee "Late Night Finds, Vol. 1" "Various Artists"
track . 1 1 "Neon Rain"             "Kites Over Lagos" 12 262 NGKOL2300001
track . 1 2 "Night Bus"             "Aurora Field" 9 294
track . 1 3 "Minuit à Lisbonne"     "Éléonore Brûlé" 15 330
track . 1 4 "Signal Lost"           "Static Choir" 10 349 DEST02300004
track . 1 5 "高架下"                "坂本光" 13 392
track . 1 6 "4 AM Cartography"      "The Midnight Cartographers" 17 440

# ================================================================ samples ("Finds") library
# A single by an artist that is NOT in the main library - what a "Try it" fetch would land via Lidarr.
album samples "Kites Over Lagos/Paper Planes (2024)" "Paper Planes" "Kites Over Lagos" "2024-02-09" "Afrobeats" mp3 1
make_cover "$A_COVER" ff9f1c 2ec4b6 "Paper Planes" "Kites Over Lagos"
track . 1 1 "Paper Planes" "Kites Over Lagos" 16 392 NGKOL2400001
folder_cover

lib=$(find "$MUSIC/library" -type f \( -name '*.flac' -o -name '*.mp3' -o -name '*.m4a' \) | wc -l | tr -d ' ')
smp=$(find "$MUSIC/samples" -type f \( -name '*.flac' -o -name '*.mp3' -o -name '*.m4a' \) | wc -l | tr -d ' ')
echo "done: $lib tracks in library/, $smp in samples/ ($(du -sh "$MUSIC" | cut -f1))"
