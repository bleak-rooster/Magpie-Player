import AurralKit
import Foundation
import LidarrKit
import MagpieCore
import MagpieTestSupport
import MatchIndex
import Testing
@testable import Search

/// A candidate in these tests: what `resolve` answers for it.
private struct Pick: Sendable {
    var name: String
    var answer: LidarrTopSongs.Resolution
}

private func song(_ id: String, _ title: String? = nil, library: Int? = nil) -> Song {
    Song(id: id, title: title ?? "Title \(id)", artist: "Aurora Field", album: "First Light", duration: 200, libraryId: library)
}

private func hit(_ id: String, _ title: String? = nil, library: Int? = nil) -> Pick {
    Pick(name: id, answer: .song(song(id, title, library: library)))
}

private func miss(_ name: String) -> Pick { Pick(name: name, answer: .notInLibrary) }

/// Records every candidate the merge asked about (non-escaping closures; one task).
private final class Asked: @unchecked Sendable {
    var calls: [(TopSongsProvider, String)] = []
    func count(_ provider: TopSongsProvider) -> Int { calls.filter { $0.0 == provider }.count }
}

private func merge(_ aurral: LidarrTopSongs.Answer<Pick>, _ listenBrainz: LidarrTopSongs.Answer<Pick>,
                   _ library: LidarrTopSongs.Answer<Pick>, discover: Set<Int> = [], asked: Asked = Asked()) async
    -> LidarrTopSongs.Result {
    await LidarrTopSongs.merge(sources: .init(aurral: aurral, listenBrainz: listenBrainz, library: library),
                               discoverLibraries: discover) { provider, pick in
        asked.calls.append((provider, pick.name))
        return pick.answer
    }
}

private func ids(_ result: LidarrTopSongs.Result) -> [String] { result.rows.map(\.song.id) }

/// Round 26 K1 (owner, 2026-11-10, items 1, 4 and 5): five slots, filled by walking Aurral's list, then ListenBrainz's,
/// then Navidrome's, each top-down; a song the library hasn't got is skipped and the next moves up (D258). A failed
/// source or Lidarr read makes the list incomplete (D262); an empty answer is an answer.
@Suite struct LidarrTopSongsMergeTests {
    @Test func merge_fillsAurralThenListenBrainzThenNavidrome() async {
        let result = await merge(.answered([hit("a1"), hit("a2")]), .answered([hit("l1"), hit("l2")]),
                                 .answered([hit("n1"), hit("n2"), hit("n3")]))
        #expect(ids(result) == ["a1", "a2", "l1", "l2", "n1"])
        #expect(result.rows.map(\.source) == [.aurral, .aurral, .listenBrainz, .listenBrainz, .library])
        #expect(result.complete)
        #expect(LidarrTopSongs.order == [.aurral, .listenBrainz, .library])
    }

    @Test func merge_unmatchedMovesTheNextUp() async {
        let result = await merge(.answered([miss("a1"), hit("a2"), miss("a3"), hit("a4")]),
                                 .answered([miss("l1"), hit("l2")]), .answered([hit("n1"), hit("n2")]))
        #expect(ids(result) == ["a2", "a4", "l2", "n1", "n2"])
        #expect(result.complete, "a song the library hasn't got is an answer, not a failure")
    }

    @Test func merge_stopsAtFive() async {
        let asked = Asked()
        let result = await merge(.answered((1...6).map { hit("a\($0)") }), .answered([hit("l1")]), .answered([hit("n1")]),
                                 asked: asked)
        #expect(ids(result) == ["a1", "a2", "a3", "a4", "a5"])
        #expect(asked.calls.count == 5, "nothing is resolved once the five are placed")
        #expect(LidarrTopSongs.limit == 5)
        let fewer = await LidarrTopSongs.merge(sources: .init(aurral: .answered([hit("a1"), hit("a2")]),
                                                              listenBrainz: .unavailable, library: .unavailable),
                                               limit: 1) { _, pick in pick.answer }
        #expect(ids(fewer) == ["a1"])
        let none = await LidarrTopSongs.merge(sources: .init(aurral: .answered([hit("a1")]), listenBrainz: .unavailable,
                                                             library: .unavailable), limit: -3) { _, pick in pick.answer }
        #expect(none.rows.isEmpty)
    }

    @Test func merge_readsAtMostTwentyFivePerSource() async {
        let asked = Asked()
        let result = await merge(.answered((1...10).map { miss("a\($0)") }), .answered((1...40).map { miss("l\($0)") }),
                                 .answered((1...40).map { miss("n\($0)") }), asked: asked)
        #expect(result.rows.isEmpty && result.complete)
        #expect(asked.count(.aurral) == 6, "Aurral gives at most 6 (its server's cap)")
        #expect(asked.count(.listenBrainz) == 25)
        #expect(asked.count(.library) == 25)
        #expect(asked.calls.filter { $0.0 == .listenBrainz }.map(\.1) == (1...25).map { "l\($0)" }, "top-down")
        #expect(LidarrTopSongs.readDepth(.aurral) == 6 && LidarrTopSongs.readDepth(.listenBrainz) == 25
                    && LidarrTopSongs.readDepth(.library) == 25)
    }

    @Test func merge_dedupesBySongIdAcrossSources() async {
        let result = await merge(.answered([hit("x"), hit("y")]), .answered([hit("y"), hit("x"), hit("z")]),
                                 .answered([hit("z"), hit("w")]))
        #expect(ids(result) == ["x", "y", "z", "w"])
        #expect(result.rows.map(\.source) == [.aurral, .aurral, .listenBrainz, .library])
    }

    @Test func merge_dedupesTwoCopiesOfOneSong() async {
        let result = await merge(.answered([hit("album", "Song"), hit("deluxe", "Song (Remastered 2011)")]),
                                 .answered([hit("single", "Song (Radio Edit)"), hit("live", "Song (Live)")]),
                                 .answered([hit("other", "Other Song")]))
        #expect(ids(result) == ["album", "live", "other"], "one copy of a song, by the strict title; a live take is another song")
    }

    @Test func merge_unavailableSourceSkippedAndComplete() async {
        let asked = Asked()
        let result = await merge(.unavailable, .answered([hit("l1")]), .answered([hit("n1")]), asked: asked)
        #expect(ids(result) == ["l1", "n1"])
        #expect(result.complete)
        #expect(asked.count(.aurral) == 0)
        let alone = await merge(.unavailable, .unavailable, .answered([hit("n1")]))
        #expect(ids(alone) == ["n1"] && alone.complete)
    }

    @Test func merge_failedSourceIsIncomplete() async {
        let failed = await merge(.answered([hit("a1")]), .failed, .answered([hit("n1")]))
        #expect(ids(failed) == ["a1", "n1"])
        #expect(!failed.complete)
        // Fix round 1 (controller ruling C3): a failure counts only when the walk reached it before the five were filled.
        let laterFailed = await merge(.answered((1...5).map { hit("a\($0)") }), .answered([]), .failed)
        #expect(ids(laterFailed).count == 5 && laterFailed.complete, "a source after the list filled couldn't change it")
        let laterBoth = await merge(.answered((1...5).map { hit("a\($0)") }), .failed, .failed)
        #expect(laterBoth.complete)
        let firstFailed = await merge(.failed, .answered((1...6).map { hit("l\($0)") }), .answered([hit("n1")]))
        #expect(ids(firstFailed) == ["l1", "l2", "l3", "l4", "l5"])
        #expect(!firstFailed.complete, "Aurral failed before anything was placed: its songs would have come first")
        let fourThenFailed = await merge(.answered((1...4).map { hit("a\($0)") }), .failed, .answered([hit("n1")]))
        #expect(ids(fourThenFailed).count == 5 && !fourThenFailed.complete, "reached with a slot still open")
        let unread = await merge(.answered([Pick(name: "a1", answer: .lidarrUnread), hit("a2")]), .answered([]),
                                 .answered([hit("n1")]))
        #expect(ids(unread) == ["a2", "n1"], "a song that couldn't be looked for on the albums is skipped")
        #expect(!unread.complete, "and the list is incomplete")
    }

    @Test func merge_emptyAnswerIsComplete() async {
        let result = await merge(.answered([]), .answered([]), .answered([]))
        #expect(result.rows.isEmpty && result.complete)
        let nothing = await merge(.unavailable, .unavailable, .unavailable)
        #expect(nothing.rows.isEmpty && nothing.complete)
    }

    @Test func merge_neverDiscoverCopies() async {
        let result = await merge(.answered([hit("flow", library: 7), hit("main", library: 1)]), .answered([]),
                                 .answered([hit("flow2", library: 7), hit("untold")]), discover: [7])
        #expect(ids(result) == ["main", "untold"])
    }

    @Test func merge_cancelledIsIncomplete() async {
        let task = Task {
            await LidarrTopSongs.merge(sources: .init(aurral: .answered([hit("a1"), hit("a2")]), listenBrainz: .unavailable,
                                                      library: .unavailable)) { _, pick in
                withUnsafeCurrentTask { $0?.cancel() }
                return pick.answer
            }
        }
        let result = await task.value
        #expect(ids(result) == ["a1"] && !result.complete, "a refresh cut short is never complete")

        // Fix round 1 (M2): cancelled inside the fifth resolve, the list fills and the loop ends: still incomplete.
        let fifth = Task {
            await LidarrTopSongs.merge(sources: .init(aurral: .answered((1...6).map { hit("a\($0)") }),
                                                      listenBrainz: .unavailable, library: .unavailable)) { _, pick in
                if pick.name == "a5" { withUnsafeCurrentTask { $0?.cancel() } }
                return pick.answer
            }
        }
        let full = await fifth.value
        #expect(ids(full).count == 5 && !full.complete)
    }

    @Test func merge_seededFuzzNeverTrapsOrExceedsFive() async {
        var rng = SeededRNG(seed: 0x26_4B31)
        let titles = ["Song", "Song (Radio Edit)", "Song (Live)", "Other", "Other - Remastered", "Third", "", "(Untitled)"]
        for _ in 0..<500 {
            func answer() -> LidarrTopSongs.Answer<Pick> {
                switch Int.random(in: 0..<5, using: &rng) {
                case 0: return .unavailable
                case 1: return .failed
                default:
                    return .answered((0..<Int.random(in: 0...40, using: &rng)).map { i in
                        switch Int.random(in: 0..<6, using: &rng) {
                        case 0: return miss("m\(i)")
                        case 1: return Pick(name: "u\(i)", answer: .lidarrUnread)
                        default:
                            let id = "s\(Int.random(in: 0..<20, using: &rng))"
                            return hit(id, titles.randomElement(using: &rng), library: Int.random(in: 0..<4, using: &rng))
                        }
                    })
                }
            }
            let sources = LidarrTopSongs.Sources(aurral: answer(), listenBrainz: answer(), library: answer())
            let discover: Set<Int> = rng.chance(0.5) ? [3] : []
            let limit = Int.random(in: -1...7, using: &rng)
            let asked = Asked()
            var unreadSeen = false
            let result = await LidarrTopSongs.merge(sources: sources, discoverLibraries: discover, limit: limit) { p, pick in
                asked.calls.append((p, pick.name))
                if case .lidarrUnread = pick.answer { unreadSeen = true }
                return pick.answer
            }
            #expect(result.rows.count <= min(max(limit, 0), 5))
            #expect(Set(result.rows.map(\.song.id)).count == result.rows.count)
            // A song with no title has no strict title to compare: told apart by its id only.
            let keys = result.rows.map { TopSongIdentity.titleKey($0.song.title) }.filter { !$0.isEmpty }
            #expect(Set(keys).count == keys.count)
            #expect(!result.rows.contains { $0.song.libraryId.map(discover.contains) == true })
            let order = result.rows.map { LidarrTopSongs.order.firstIndex(of: $0.source) ?? -1 }
            #expect(order == order.sorted())
            // Fix round 1 (C3): a failed source counts only when the walk reached it before the list was full. Full at
            // the start (limit ≤ 0): none is reached; full on the last row's source: only the sources before it.
            let wanted = min(max(limit, 0), 5)
            let fillPoint: Int = result.rows.count < wanted ? .max
                : (result.rows.last.flatMap { LidarrTopSongs.order.firstIndex(of: $0.source) } ?? -1)
            let reachedFailed = LidarrTopSongs.order.enumerated().contains { i, provider in
                guard i < fillPoint || fillPoint == .max, case .failed = sources[provider] else { return false }
                return true
            }
            #expect(result.complete == !(reachedFailed || unreadSeen))
            #expect(asked.count(.aurral) <= 6 && asked.count(.listenBrainz) <= 25 && asked.count(.library) <= 25)
        }
    }

    // MARK: - The resolver for an Aurral or ListenBrainz song

    private static let artistMBID = MBID("4d8175ea-cc33-4565-8a8e-6b0f6c7a3f11")!
    private static let rec = MBID("20a2961b-d8e8-481c-bd5b-abb38a2850ad")!

    private func library(_ songs: [Song]) -> MatchIndex { MatchIndex(songs: songs) }

    private func albumSong(_ id: String, _ title: String = "Song", album: String = "First Light", _ d: TimeInterval = 246,
                           rec: MBID? = nil) -> Song {
        Song(id: id, title: title, artist: "Aurora Field", album: album, duration: d, recordingMBID: rec,
             artistMBID: Self.artistMBID)
    }

    private func lidarr(_ type: String = "Album", _ secondary: [String] = [], rec: MBID? = nil, file: Bool = true,
                        length: TimeInterval? = 245) -> LidarrTopSongs.LidarrReads {
        var t = LidarrTrack(id: 11, albumId: 1, trackFileId: file ? 99 : nil, foreignTrackId: nil,
                            foreignRecordingId: rec?.rawValue, duration: length)
        t.title = "Song"
        return .read(albums: [LidarrAlbum(id: 1, title: "First Light", albumType: type, secondaryTypes: secondary)],
                     tracks: [t])
    }

    private func link(_ recording: ExternalRecording, _ index: MatchIndex, _ reads: LidarrTopSongs.LidarrReads)
        -> LidarrTopSongs.Link {
        LidarrTopSongs.link(recording, artistName: "Aurora Field", artistMBID: Self.artistMBID, index: index, lidarr: reads)
    }

    private func single(_ title: String = "Song (Radio Edit)", _ d: TimeInterval = 211) -> ExternalRecording {
        ExternalRecording(artistMBID: Self.artistMBID, title: title, artist: "Aurora Field", duration: d, source: .listenBrainz)
    }

    @Test func link_directMatchFirst() {
        let index = library([albumSong("same", "Song (Radio Edit)", album: "Song", 211), albumSong("album")])
        #expect(link(single(), index, .failed) == .song(id: "same"), "a direct match needs no Lidarr read")
    }

    /// The id an album-step link carries, with its track and album (fix round 1, I2); nil for any other link.
    private func albumStep(_ link: LidarrTopSongs.Link) -> String? {
        guard case .albumSong(let id, let track, let album) = link, track.id == 11, album.id == 1 else { return nil }
        return id
    }

    @Test func link_singleOnlyMatchedThroughAlbum() {
        let index = library([albumSong("album", album: "First Light (Deluxe Edition)")])
        #expect(albumStep(link(single(), index, lidarr())) == "album", "the album step hands back its track for the re-check")
        #expect(LidarrTopSongs.confirms(albumSong("album", album: "First Light (Deluxe Edition)"),
                                        link(single(), index, lidarr()), artistName: "Aurora Field",
                                        artistMBID: Self.artistMBID))
        #expect(link(single(), index, lidarr("Album", ["Live"])) == .none, "never a live album's copy")
        #expect(link(single(), index, lidarr(file: false)) == .none)
        #expect(link(single("Song (Reprise)"), index, lidarr()) == .none)
        #expect(link(single(), index, .failed) == .lidarrUnread, "no direct match and Lidarr unread: can't tell")
    }

    @Test func link_unlinkedTrackIsHandedBack() throws {
        let index = library([albumSong("elsewhere", album: "Another Album")])
        guard case .track(let track, let album) = link(single(), index, lidarr()) else {
            Issue.record("expected the track for a search")
            return
        }
        #expect(track.id == 11 && album.id == 1)
        #expect(AlbumTrackMatch.links(albumSong("found", album: "First Light"), to: track, album: album,
                                      artistName: "Aurora Field", artistMBID: Self.artistMBID))
    }

    @Test func link_aurralRowUsesThePagesArtist() {
        let aurral = AurralSong(trackName: "Song (Radio Edit)", artistName: "Aurora Field feat. Sam", durationMs: 211_000)
        let recording = LidarrTopSongs.recording(aurral: aurral, artistName: "Aurora Field", artistMBID: Self.artistMBID)
        #expect(recording.artist == "Aurora Field" && recording.artistMBID == Self.artistMBID)
        #expect(recording.title == "Song (Radio Edit)" && recording.duration == 211)
        #expect(LidarrTopSongs.recording(aurral: AurralSong(trackName: "X", artistName: "Y", durationMs: -5),
                                         artistName: "Y", artistMBID: nil).duration == nil)
        let index = library([albumSong("album")])
        #expect(albumStep(link(recording, index, lidarr())) == "album")
    }

    /// Fix round 1 (I2): the index keeps `Normalize.name`d titles, which fold "(Reprise)" to the plain title, so a library
    /// that holds only the reprise (same album, same length) is linked by the index; the full song must then fail the
    /// strict re-check, so it is never shown.
    @Test func link_repriseLinkedByTheIndexFailsTheRecheck() {
        let reprise = albumSong("reprise", "Song (Reprise)", 245)
        let index = library([reprise])
        let found = link(single(), index, lidarr())
        #expect(albumStep(found) == "reprise", "the index alone can't tell")
        guard case .albumSong(_, let track, let album) = found else { return }
        #expect(!AlbumTrackMatch.links(reprise, to: track, album: album, artistName: "Aurora Field",
                                       artistMBID: Self.artistMBID))
        #expect(!LidarrTopSongs.confirms(reprise, found, artistName: "Aurora Field", artistMBID: Self.artistMBID))
        #expect(LidarrTopSongs.confirms(albumSong("any"), .song(id: "any"), artistName: "Aurora Field",
                                        artistMBID: Self.artistMBID), "a direct ladder match needs no re-check")
        #expect(!LidarrTopSongs.confirms(albumSong("other"), .song(id: "any"), artistName: "Aurora Field",
                                         artistMBID: Self.artistMBID), "a fetched song must be the linked one")
        #expect(!LidarrTopSongs.confirms(reprise, .none, artistName: "Aurora Field", artistMBID: Self.artistMBID))
    }

    /// Fix round 1 (M5): a Discover copy of the recording listed first never hides the main library's copy.
    @Test func link_recordingPrefersACopyOutsideDiscover() {
        let flow = albumSong("flow", album: "Flow", rec: Self.rec)
        let main = albumSong("main", rec: Self.rec)
        let recording = ExternalRecording(recordingMBID: Self.rec, artistMBID: Self.artistMBID, title: "Song",
                                          artist: "Aurora Field", duration: 246, source: .listenBrainz)
        let found = LidarrTopSongs.link(recording, artistName: "Aurora Field", artistMBID: Self.artistMBID,
                                        index: library([flow, main]), lidarr: .failed, avoiding: { $0 == "flow" })
        #expect(found == .song(id: "main"))
        let onlyFlow = LidarrTopSongs.link(recording, artistName: "Aurora Field", artistMBID: Self.artistMBID,
                                           index: library([flow]), lidarr: .failed, avoiding: { $0 == "flow" })
        #expect(onlyFlow == .song(id: "flow"), "only a Discover copy: the merge skips it by its library")
    }
}
