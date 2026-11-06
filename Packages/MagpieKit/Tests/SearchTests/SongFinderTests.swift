import Foundation
import ListenBrainzKit
import MagpieCore
import Testing
@testable import Search

private func id(_ n: Int) -> MBID { MBID(String(format: "00000000-0000-4000-8000-%012d", n))! }
private let rosé = id(1), bruno = id(2), other = id(3)

private func rel(_ n: Int, _ title: String, _ type: String, secondary: [String] = [], status: String = "Official") -> MBRelease {
    MBRelease(id: id(500 + n), title: title, date: "2024", status: status,
              releaseGroup: MBReleaseGroup(id: id(600 + n), primaryType: type, secondaryTypes: secondary))
}

private func rec(_ n: Int, _ title: String, length: TimeInterval? = 170, artists: [(MBID, String)] = [(rosé, "ROSÉ"), (bruno, "Bruno Mars")],
                 releases: [MBRelease] = [rel(1, "APT.", "Single")]) -> MBRecording {
    MBRecording(id: id(100 + n), title: title, releases: releases, artistIds: artists.map(\.0), length: length,
                artistNames: artists.map(\.1))
}

/// A chart row as the music server gives it: Deezer's names, length and track id; no MusicBrainz ids.
private func chartSong(_ title: String = "APT.", artist: String = "ROSÉ", duration: TimeInterval? = 170) -> OutsideSong {
    OutsideSong(title: title, artist: artist, album: "APT.", duration: duration, deezerAlbumId: "1", previewId: "3050380851")
}

private actor FinderCalls {
    var log: [String] = []
    func add(_ s: String) { log.append(s) }
}

private let noLinks: OutsideSongMatch.Links = { _, _, _ in throw OutsideSongMatch.Failure.unmatched }
private let noRelease: OutsideSongMatch.Release = { _ in nil }

/// Round 19 (owner, 2026-11-05: popular singles weren't found): a song from the charts, Discover playlists or top songs is
/// matched by the server's links first, then MusicBrainz's search of its title by its artist, so a brand-new single, a
/// deluxe album, a radio edit or a duet still finds its recording, with the music server or without it (Lidarr alone).
@Suite struct SongFinderTests {
    fileprivate func finder(_ found: [MBRecording] = [], calls: FinderCalls = FinderCalls()) -> OutsideSongMatch.Finder {
        OutsideSongMatch.Finder(search: { title, artist in await calls.add("mb search \(title)|\(artist)"); return found })
    }

    /// The links still come first; the search only when they don't name the song.
    @Test func theLinksFirstThenTheSearch() async throws {
        let calls = FinderCalls()
        let detail = MBReleaseDetail(id: id(700), title: "APT.", date: "2024", status: "Official",
                                     tracks: [MBTrack(recording: id(9), title: "APT.", length: 170)])
        let linked = try await OutsideSongMatch.resolve(chartSong(), links: { _, _, _ in (rosé, id(600)) },
                                                        release: { _ in detail }, finder: finder([rec(1, "APT.")], calls: calls))
        let log = await calls.log
        #expect(linked.recordingMBID == id(9) && log.isEmpty)
        // The links' album doesn't hold it (a new single, a deluxe): the search.
        let searched = try await OutsideSongMatch.resolve(chartSong(), links: { _, _, _ in (rosé, id(600)) },
                                                          release: { _ in nil }, finder: finder([rec(1, "APT.")], calls: calls))
        #expect(searched.recordingMBID == id(101) && searched.artistMBID == rosé, "the duet's artist is the row's own")
    }

    /// Without the music server (Lidarr alone: no links) the song still matches.
    @Test func noServerNeeded() async throws {
        let r = try await OutsideSongMatch.resolve(chartSong(), links: noLinks, release: noRelease, finder: finder([rec(2, "APT.")]))
        #expect(r.recordingMBID == id(102))
    }

    /// The search takes only the same title, by an artist of the credit, with the length near (when both are known);
    /// a live or remixed version (another title) never.
    @Test func theSearchIsStrict() async throws {
        let cases: [(String, MBRecording)] = [
            ("live", rec(1, "APT. (Live)")),
            ("another artist", rec(2, "APT.", artists: [(other, "Somebody Else")])),
            ("far too long", rec(3, "APT.", length: 260)),
        ]
        for (name, candidate) in cases {
            await #expect(throws: OutsideSongMatch.Failure.unmatched, "\(name)") {
                _ = try await OutsideSongMatch.resolve(chartSong(), links: noLinks, release: noRelease, finder: self.finder([candidate]))
            }
        }
        // A length MusicBrainz doesn't know doesn't rule it out; a radio edit a few seconds off is the song.
        let unknown = try await OutsideSongMatch.resolve(chartSong(), links: noLinks, release: noRelease,
                                                         finder: finder([rec(4, "APT.", length: nil)]))
        #expect(unknown.recordingMBID == id(104))
        let edit = try await OutsideSongMatch.resolve(chartSong(), links: noLinks, release: noRelease,
                                                      finder: finder([rec(5, "APT.", length: 176)]))
        #expect(edit.recordingMBID == id(105))
    }

    /// Several recordings of the song: one on a plain official release first (not a compilation's), then the one named
    /// after the song, then the closest length.
    @Test func theRecordingPeopleHaveWins() async throws {
        let onCompilation = rec(1, "APT.", releases: [rel(1, "Hits 2024", "Album", secondary: ["Compilation"])])
        let onSingle = rec(2, "APT.", length: 175, releases: [rel(2, "APT.", "Single")])
        let onAlbum = rec(3, "APT.", length: 170, releases: [rel(3, "rosie", "Album")])
        let r = try await OutsideSongMatch.resolve(chartSong(), links: noLinks, release: noRelease,
                                                   finder: finder([onCompilation, onAlbum, onSingle]))
        #expect(r.recordingMBID == id(102), "on its own single, over a closer length on the album and a compilation")
    }

    /// "Song (feat. X)" is searched as "Song", by the row's first artist ("X & Y" → X).
    @Test func featuredArtistsAreLeftOutOfTheSearch() async throws {
        let calls = FinderCalls()
        let song = chartSong("Die With A Smile (feat. Bruno Mars)", artist: "Lady Gaga & Bruno Mars")
        _ = try? await OutsideSongMatch.resolve(song, links: noLinks, release: noRelease, finder: finder(calls: calls))
        #expect(await calls.log.contains("mb search Die With A Smile|Lady Gaga"))
        #expect(OutsideSongMatch.searchTitle("Song [feat. X]") == "Song")
        #expect(OutsideSongMatch.searchTitle("Song (Live)") == "Song (Live)")
    }

    /// Offline (no finder): only the server's links, as before round 19.
    @Test func withoutAFinderOnlyTheLinks() async throws {
        await #expect(throws: OutsideSongMatch.Failure.unmatched) {
            _ = try await OutsideSongMatch.resolve(chartSong(), links: noLinks, release: noRelease, finder: nil)
        }
    }

    /// A row that knows its recording (ListenBrainz, Lidarr's tracklists) asks nothing.
    @Test func aKnownRecordingAsksNothing() async throws {
        let calls = FinderCalls()
        var song = chartSong()
        song.recordingMBID = id(9)
        let r = try await OutsideSongMatch.resolve(song, links: noLinks, release: noRelease, finder: finder(calls: calls))
        let log = await calls.log
        #expect(r.recordingMBID == id(9) && log.isEmpty)
    }
}
