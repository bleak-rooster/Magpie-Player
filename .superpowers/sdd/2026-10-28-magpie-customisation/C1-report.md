# Round 15 C1: pictures (owner items 3 and 4)

Branch `c1-pictures` from `v0.0.1-custom` (25bed51).

## Scope change
Owner item 2 (Recommended circles) was dropped mid-run. On build 15 those pictures load (D126). The chain changes I
had started (own-server artist sources in `OutsideArtLoader`, a Lidarr MediaCover poster GET) were reverted before
any commit. Nothing in the Recommended chain changed.

Side finding, not used: on the dev Lidarr 3.2, `GET /api/v1/mediacover/artist/<id>/poster-500.jpg` with the API key
answers the poster (401 without the key). It's there if item 2 ever comes back.

## Root causes
- **Item 3 (Top songs without covers):** `TopSongsSection`'s `TopSongRowView` drew every outside row (from Aurral or
  ListenBrainz) with no `artwork:` at all. Only library copies had a cover. Also, an Aurral top song without a
  preview dropped its `AurralSong`, and its picture went with it. ListenBrainz rows used `release_mbid`, which often
  has no Cover Art Archive front; `caa_release_mbid` was ignored.
- **Item 4 (preview without a cover):** `PreviewItem` carried no usable picture. `artworkURL` only takes an Aurral
  `/api/...` path, and Aurral names Deezer links. `PreviewMiniPlayerAccessory` never passed `artwork:` to
  `PreviewMiniPlayer`. `NowPlayingBridge.previewInfo` published no artwork ("No artwork"). CarPlay has no previews.

## Fixes (D127, D128)
- `TopSongRow` gains `artwork` (the `AurralImage` Aurral named: the song's own, or a ListenBrainz song's matched
  preview's) and `cover` (a ListenBrainz song's release front). `AppModel.topSongArtwork` tries, in order:
  1. the release front (D122 loader, kept on the phone);
  2. Aurral's picture through the image proxy;
  3. the artist's picture (with Lidarr);
  4. the placeholder.
  `TopSongRowView` loads it per row. Library copies are unchanged.
- ListenBrainz top recordings: `releaseMBID = caa_release_mbid ?? release_mbid`.
- `PreviewItem.artworkKey` holds the picture link Aurral named for the song. `AppModel.previewArtwork` resolves it
  through `aurralArtwork` (the image proxy, D111). Nothing is fetched from Deezer or Apple. The preview mini player
  shows it.
- `NowPlayingBridge(previewArtwork:)` adds `MPMediaItemPropertyArtwork` to the preview's Lock Screen info, loaded once
  per preview.
- Test-only `artworkTestMarker`: a 1-pt element, only with `-MagpieUITesting YES`, whose value is
  "artwork-loaded" or "placeholder".
- Stub Aurral: new scenario `playable-clip`. Its `?download` returns 12 s of real silence, so the preview plays and the
  mini player stays up.

## Tests
- Package `ListenBrainzKitTests/TopRecordingsTests.theCoverIsTheReleaseWithArt`.
  - RED: `rows[0].releaseMBID` was `release_mbid`.
  - GREEN: 43 ListenBrainzKit tests pass.
- App `MagpieTests/C1SongArtTests.swift` (extends `Round14ActionsTests`):
  - Tests:
    - `c1ServerTopSongsShowTheirCovers`
    - `c1ListenBrainzTopSongsShowTheirReleasesCover`
    - `c1AListenBrainzTopSongWithoutAFrontTakesItsPreviewsPicture`
    - `c1APreviewCarriesItsRowsCoverIntoThePlayer`
    - `c1TheLockScreenShowsThePreviewsCover`
  - RED: against 25bed51 these fail to compile. `TopSongRow.artwork`/`cover`, `topSongArtwork`,
    `PreviewItem.artworkKey`, `previewArtwork` and `NowPlayingBridge(previewArtwork:)` didn't exist. This is RED by
    absence, not a runtime failure.
  - GREEN: 95 tests pass across Round14ActionsTests, PreviewComponentsTests, PreviewAppTests and DiscoverAppTests,
    on a dedicated simulator "Magpie Tests C1". The shared "Magpie Tests" simulator was being used by other
    workstreams and killed one run.
  - Stub Aurral: `http://aurral-stub:3001`, plain http on a non-loopback name. Recommendations carry no image.
- **Release UI check:** `MagpieUITests/C1PicturesUITests.testTopSongsAndThePreviewMiniPlayerShowCovers`.
  - Setup: Release configuration with a UI-only scheme. Dev Navidrome, plus the stub Aurral on 127.0.0.1:3967 with
    `s/playable-clip`. Port 3911 was taken by another worktree's stub.
  - **PASSED**: all three Top songs rows show "artwork-loaded", and so does the preview mini player.
  - It uses the library artist page (Aurora Field). That page shows the same `TopSongsSection`. The outside page
    opened from Recommended also reads musicbrainz.org, which would leave the localhost stack.
  - The stub is on loopback because the simulator test can't reach a non-local host under G0.
- `scripts/check-writes.sh`: OK. `scripts/check-release.sh`: OK.

## Not done
- No MusicBrainz release → release-group step for a ListenBrainz release without a front. The owner asked for a small
  diff, and the Aurral picture covers that case.
- Preview covers on CarPlay: not applicable, since previews don't show there.
- Pre-existing quirk: `TopSongsSection`'s `.accessibilityIdentifier("top-songs")` replaces every row's `top-song-N`
  identifier. It's not fixed here.
