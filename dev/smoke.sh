#!/usr/bin/env bash
# Smoke-test the APIs Magpie uses against the running dev stack. Reads dev/.env.local (from bootstrap.sh).
# Prints PASS / FAIL / SKIP per call; exit code = number of FAILs (0 = all good).
# SKIP is used only for calls that depend on the internet (Lidarr's metadata server).
set -uo pipefail

DEV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$DEV_DIR/.env.local" ]] || { echo "dev/.env.local missing - run dev/bootstrap.sh" >&2; exit 1; }
set -a; . "$DEV_DIR/.env.local"; set +a
ND=$NAVIDROME_URL LD=$LIDARR_URL

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
pass=0 fail=0 skip=0
B=$TMP/body H=$TMP/headers
result() { # result PASS|FAIL|SKIP <name> <detail>
  case $1 in
    PASS) ((pass++)); printf '\033[32mPASS\033[0m  %-44s %s\n' "$2" "$3" ;;
    FAIL) ((fail++)); printf '\033[31mFAIL\033[0m  %-44s %s\n' "$2" "$3" ;;
    SKIP) ((skip++)); printf '\033[33mSKIP\033[0m  %-44s %s\n' "$2" "$3" ;;
  esac
}
# req <curl args...>  -> sets CODE, body in $B, headers in $H
req() { CODE=$(curl -sS -o "$B" -D "$H" -w '%{http_code}' --max-time "${TIMEOUT:-15}" "$@" 2>"$TMP/err") || CODE=${CODE:-000}; }
hdr() { grep -i "^$1:" "$H" | tail -1 | cut -d: -f2- | tr -d '\r' | sed 's/^ *//'; }
jb() { jq -r "$@" "$B" 2>/dev/null; }
urlenc() { jq -rn --arg s "$1" '$s|@uri'; }

# ================================================================== Navidrome
echo "--- Navidrome $ND"

req -X POST "$ND/auth/login" -H 'Content-Type: application/json' \
  -d "$(jq -nc --arg u "$NAVIDROME_ADMIN_USER" --arg p "$NAVIDROME_ADMIN_PASSWORD" '{username:$u,password:$p}')"
TOKEN=$(jb '.token // empty'); SALT=$(jb .subsonicSalt); STOK=$(jb .subsonicToken)
[[ $CODE == 200 && -n "$TOKEN" && $(jb .isAdmin) == true ]] && result PASS "POST /auth/login (admin)" "JWT + subsonic token/salt" \
  || result FAIL "POST /auth/login (admin)" "HTTP $CODE"

req -X POST "$ND/auth/login" -H 'Content-Type: application/json' \
  -d "$(jq -nc --arg u "$NAVIDROME_LISTENER_USER" --arg p "$NAVIDROME_LISTENER_PASSWORD" '{username:$u,password:$p}')"
LSALT=$(jb .subsonicSalt); LTOK=$(jb .subsonicToken)
[[ $CODE == 200 && $(jb .isAdmin) == false ]] && result PASS "POST /auth/login (listener)" "non-admin" \
  || result FAIL "POST /auth/login (listener)" "HTTP $CODE"

S="u=$NAVIDROME_ADMIN_USER&t=$STOK&s=$SALT&v=1.16.1&c=magpie-smoke&f=json"
LS="u=$NAVIDROME_LISTENER_USER&t=$LTOK&s=$LSALT&v=1.16.1&c=magpie-smoke&f=json"
sub() { req "$ND/rest/$1?$S${2:+&$2}"; }
subok() { [[ $CODE == 200 && $(jb '."subsonic-response".status') == ok ]]; }

# Classic token auth computed client-side (md5(password+salt)), as the app will do
salt=$(openssl rand -hex 6); t=$(printf '%s' "$NAVIDROME_ADMIN_PASSWORD$salt" | openssl md5 | awk '{print $NF}')
req "$ND/rest/ping?u=$NAVIDROME_ADMIN_USER&t=$t&s=$salt&v=1.16.1&c=magpie-smoke&f=json"
subok && result PASS "GET /rest/ping (u+t+s)" "$(jb '."subsonic-response" | "\(.type) \(.serverVersion) openSubsonic=\(.openSubsonic)"')" \
      || result FAIL "GET /rest/ping (u+t+s)" "HTTP $CODE $(head -c 200 "$B")"

sub getOpenSubsonicExtensions
subok && result PASS "getOpenSubsonicExtensions" "$(jb '[."subsonic-response".openSubsonicExtensions[].name] | join(",")')" \
      || result FAIL "getOpenSubsonicExtensions" "HTTP $CODE"

req "$ND/rest/getMusicFolders?$LS"
n=$(jb '."subsonic-response".musicFolders.musicFolder | length')
[[ $CODE == 200 && $n == 2 ]] && result PASS "getMusicFolders (listener)" "$(jb '[."subsonic-response".musicFolders.musicFolder[] | "\(.id)=\(.name)"] | join(", ")')" \
  || result FAIL "getMusicFolders (listener)" "expected 2 folders, got $n"

sub search3 "query=Aurora&songCount=50&albumCount=10&artistCount=10"
s=$(jb '."subsonic-response".searchResult3.song | length'); a=$(jb '."subsonic-response".searchResult3.album | length')
subok && (( s >= 12 && a >= 2 )) && result PASS "search3 query=Aurora" "$s songs, $a albums" \
  || result FAIL "search3 query=Aurora" "$s songs, $a albums"

sub search3 "query=$(urlenc 坂本光)&songCount=50"
s=$(jb '."subsonic-response".searchResult3.song | length')
subok && (( s >= 7 )) && result PASS "search3 query=坂本光 (CJK)" "$s songs" || result FAIL "search3 query=坂本光 (CJK)" "$s songs"

sub search3 "query=$(urlenc 'Eleonore')&songCount=50"
s=$(jb '."subsonic-response".searchResult3.song | length')
subok && (( s >= 6 )) && result PASS "search3 query=Eleonore (accent-folding)" "$s songs" \
  || result FAIL "search3 query=Eleonore (accent-folding)" "$s songs"

sub search3 "query=$(urlenc 'Paper Planes')&musicFolderId=$NAVIDROME_MAIN_LIBRARY_ID"
m=$(jb '."subsonic-response".searchResult3.song | length')
sub search3 "query=$(urlenc 'Paper Planes')&musicFolderId=$NAVIDROME_SAMPLES_LIBRARY_ID"
x=$(jb '."subsonic-response".searchResult3.song | length')
[[ $m == 0 && $x == 1 ]] && result PASS "search3 musicFolderId scoping (Samples)" "main=$m samples=$x" \
  || result FAIL "search3 musicFolderId scoping (Samples)" "main=$m samples=$x (want 0/1)"

sub getAlbumList2 "type=alphabeticalByName&size=100"
n=$(jb '."subsonic-response".albumList2.album | length')
subok && (( n >= 7 )) && result PASS "getAlbumList2 alphabeticalByName" "$n albums" || result FAIL "getAlbumList2 alphabeticalByName" "$n albums"
ALBUMS=$(cat "$B")
MULTI=$(jq -r '."subsonic-response".albumList2.album[] | select(.name=="Atlas of Small Hours") | .id' <<<"$ALBUMS")
GAPLESS=$(jq -r '."subsonic-response".albumList2.album[] | select(.name=="Continuum") | .id' <<<"$ALBUMS")
COMP=$(jq -r '."subsonic-response".albumList2.album[] | select(.name=="Late Night Finds, Vol. 1") | .id' <<<"$ALBUMS")

sub getAlbumList2 "type=newest&size=100&musicFolderId=$NAVIDROME_MAIN_LIBRARY_ID"
n=$(jb '."subsonic-response".albumList2.album | length')
subok && (( n == 6 )) && result PASS "getAlbumList2 musicFolderId=main" "$n albums" || result FAIL "getAlbumList2 musicFolderId=main" "$n albums (want 6)"

sub getAlbum "id=$MULTI"
d=$(jb '[."subsonic-response".album.song[].discNumber] | unique | length'); n=$(jb '."subsonic-response".album.songCount')
subok && [[ $d == 2 && $n == 10 ]] && result PASS "getAlbum multi-disc (CD1/CD2 folders)" "$n songs, $d discs, discTitles=$(jb '."subsonic-response".album.discTitles|length')" \
  || result FAIL "getAlbum multi-disc (CD1/CD2 folders)" "$n songs, $d discs"

sub getAlbum "id=$COMP"
subok && [[ $(jb '."subsonic-response".album.isCompilation') == true ]] \
  && result PASS "getAlbum compilation" "isCompilation=true, $(jb '[."subsonic-response".album.song[].artist]|unique|length') distinct artists" \
  || result FAIL "getAlbum compilation" "isCompilation=$(jb '."subsonic-response".album.isCompilation')"

sub getAlbum "id=$GAPLESS"
SONG=$(jb '."subsonic-response".album.song[0].id'); COVER=$(jb '."subsonic-response".album.coverArt')
mb=$(jb '."subsonic-response".album.musicBrainzId'); rec=$(jb '."subsonic-response".album.song[0].musicBrainzId')
isrc=$(jb '."subsonic-response".album.song[0].isrc | join(",")?')
subok && [[ -n "$mb" && -n "$rec" ]] && result PASS "getAlbum MBIDs/ISRC (FLAC)" "album=$mb rec=$rec isrc=$isrc" \
  || result FAIL "getAlbum MBIDs/ISRC (FLAC)" "album=$mb rec=$rec"

sub search3 "query=Peat&songCount=1"
rec=$(jb '."subsonic-response".searchResult3.song[0].musicBrainzId // ""'); isrc=$(jb '."subsonic-response".searchResult3.song[0].isrc | join(",")?')
[[ -n "$rec" ]] && result PASS "MP3 TXXX MBID/ISRC mapping" "rec=$rec isrc=$isrc" || result FAIL "MP3 TXXX MBID/ISRC mapping" "rec='$rec' isrc='$isrc'"

# stream: byte range (what AVPlayer/the resource loader sends)
req -r 0-1023 "$ND/rest/stream?$S&id=$SONG&format=raw"
len=$(wc -c < "$B" | tr -d ' ')
[[ $CODE == 206 && $len == 1024 ]] && result PASS "stream Range: bytes=0-1023 (raw)" "206, $(hdr content-type), $(hdr content-range)" \
  || result FAIL "stream Range: bytes=0-1023 (raw)" "HTTP $CODE, $len bytes"

req -I "$ND/rest/stream?$S&id=$SONG&format=raw"
[[ $CODE == 200 ]] && result PASS "stream HEAD (raw)" "200, length=$(hdr content-length), accept-ranges=$(hdr accept-ranges)" \
  || result FAIL "stream HEAD (raw)" "HTTP $CODE"

TIMEOUT=30 req "$ND/rest/stream?$S&id=$SONG&format=mp3&maxBitRate=128"
[[ $CODE == 200 && $(hdr content-type) == audio/mpeg* && $(wc -c < "$B") -gt 10000 ]] \
  && result PASS "stream transcode FLAC->mp3 128k" "$(wc -c < "$B" | tr -d ' ') bytes" || result FAIL "stream transcode FLAC->mp3 128k" "HTTP $CODE $(hdr content-type)"

req "$ND/rest/getCoverArt?$S&id=$COVER&size=300"
[[ $CODE == 200 && $(hdr content-type) == image/* ]] && result PASS "getCoverArt size=300" "$(hdr content-type), $(wc -c < "$B" | tr -d ' ') bytes" \
  || result FAIL "getCoverArt size=300" "HTTP $CODE $(hdr content-type)"

sub getScanStatus
subok && result PASS "getScanStatus" "scanning=$(jb '."subsonic-response".scanStatus.scanning') count=$(jb '."subsonic-response".scanStatus.count')" \
      || result FAIL "getScanStatus" "HTTP $CODE"

# Native API (JWT in x-nd-authorization)
NH="x-nd-authorization: Bearer $TOKEN"
req "$ND/api/album?_start=0&_end=3&_sort=name&_order=ASC" -H "$NH"
total=$(hdr x-total-count); n=$(jb 'length')
[[ $CODE == 200 && $n == 3 && ${total:-0} -ge 7 ]] && result PASS "GET /api/album (paged)" "X-Total-Count=$total, page=$n, libraryId present=$(jb '.[0]|has("libraryId")')" \
  || result FAIL "GET /api/album (paged)" "HTTP $CODE total=$total page=$n"

req "$ND/api/song?_start=0&_end=5&library_id=$NAVIDROME_SAMPLES_LIBRARY_ID" -H "$NH"
[[ $CODE == 200 ]] && result PASS "GET /api/song?library_id=samples" "X-Total-Count=$(hdr x-total-count)" || result FAIL "GET /api/song?library_id=samples" "HTTP $CODE"

req "$ND/api/library" -H "$NH"
[[ $CODE == 200 && $(jb 'length') == 2 ]] && result PASS "GET /api/library" "$(jb '[.[] | "\(.id)=\(.name):\(.path) songs=\(.totalSongs)"] | join("; ")')" \
  || result FAIL "GET /api/library" "HTTP $CODE $(jb 'length') libraries"

# ================================================================== Lidarr
echo "--- Lidarr $LD"
K="X-Api-Key: $LIDARR_API_KEY"
lid() { # lid <name> <path> <jq-check> <jq-detail>
  req -H "$K" "$LD/api/v1$2"
  if [[ $CODE == 200 ]] && jq -e "$3" "$B" >/dev/null 2>&1; then result PASS "$1" "$(jb "$4")"; else result FAIL "$1" "HTTP $CODE $(head -c 200 "$B")"; fi
}
lid "GET /api/v1/system/status" /system/status '.version' '"\(.version) \(.branch) auth=\(.authentication)"'
lid "GET /api/v1/rootfolder" /rootfolder '[.[].path] | (index("/music/library") != null and index("/music/samples") != null)' '[.[] | "\(.path) accessible=\(.accessible)"] | join(", ")'
lid "GET /api/v1/qualityprofile" /qualityprofile 'length > 0' '[.[].name] | join(", ")'
lid "GET /api/v1/metadataprofile" /metadataprofile 'length > 0' '[.[].name] | join(", ")'
lid "GET /api/v1/artist" /artist 'type == "array"' '"\(length) artists"'
lid "GET /api/v1/queue/status" /queue/status 'has("totalCount")' '"total=\(.totalCount) errors=\(.errors)"'
lid "GET /api/v1/notification (Subsonic)" /notification 'any(.[]; .implementation=="Subsonic")' '[.[] | "\(.name)(\(.implementation))"] | join(", ")'

req "$LD/api/v1/system/status"
[[ $CODE == 401 ]] && result PASS "Lidarr API rejects missing key" "401" || result FAIL "Lidarr API rejects missing key" "HTTP $CODE"

# Needs the internet (api.lidarr.audio / MusicBrainz) -> SKIP when unreachable
TIMEOUT=30 req -H "$K" "$LD/api/v1/artist/lookup?term=$(urlenc 'Portishead')"
if [[ $CODE == 200 ]] && jq -e 'length > 0' "$B" >/dev/null 2>&1; then
  result PASS "GET /api/v1/artist/lookup (external)" "$(jb '.[0] | "\(.artistName) \(.foreignArtistId)"')"
else
  result SKIP "GET /api/v1/artist/lookup (external)" "metadata server unreachable or failing (HTTP $CODE)"
fi

echo
echo "pass=$pass fail=$fail skip=$skip"
exit "$fail"
