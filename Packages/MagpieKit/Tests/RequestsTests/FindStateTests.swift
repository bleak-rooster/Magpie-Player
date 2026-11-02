import Foundation
import Testing
import LidarrKit
import MagpieCore
@testable import Requests

/// Y5 (design §2): the FindState resolver's precedence, one row per case, and ArtistLidarr's use of it (I9, 9.9).
@Suite struct FindStateTests {
    static let mbidA = mbid(1)
    static func artist(path: String = "/music/samples/A", tags: [Int] = [1, 2]) -> LidarrArtist {
        LidarrArtist(id: 42, artistName: "Aurora Field", foreignArtistId: mbidA, path: path, monitored: true, tags: tags)
    }
    static func entry(kept: Bool = false, intent: Bool = false, mode: LedgerMode = .finds) -> LedgerEntry {
        var e = LedgerEntry(lidarrArtistId: 42, albumId: 50, rgMbid: rgSingle, createdArtist: true, wasMonitoredBefore: false,
                            root: "/music/samples", mode: mode, keptAt: kept ? Date() : nil, artistMbid: mbidA)
        e.keepIntentAt = intent ? Date() : nil
        return e
    }
    static func request(_ change: (inout MagpieRequest) -> Void = { _ in }) -> MagpieRequest {
        var r = MagpieRequest(recording: ExternalRecording(recordingMBID: recSingleAndAlbum, title: "Song", artist: "Aurora Field",
                                                           source: .listenBrainz), tier: .standard, createdAt: Date())
        r.lidarrArtistId = 42
        r.state = .ready
        change(&r)
        return r
    }
    static func resolve(_ a: LidarrArtist = artist(), _ e: [LedgerEntry] = [entry()], _ r: [MagpieRequest] = [request()]) -> FindState? {
        FindResolver.resolve(artist: a, entries: e, requests: r, findTagId: 2, findsRoot: "/music/samples")
    }
    static let progress = KeepProgress(phase: .queued, startedAt: Date(), artistId: 42, fromPath: "/music/samples/A",
                                       findsRoot: "/music/samples", mainRoot: "/music/library", findTagId: 2,
                                       priorQualityProfileId: 4, commandBaseline: 0)

    @Test func precedence() {
        #expect(Self.resolve() == .find)
        #expect(Self.resolve(Self.artist(), [Self.entry(mode: .fallback)]) == nil, "not a finds-mode artist")
        #expect(Self.resolve(Self.artist(), []) == nil, "not Magpie's")
        #expect(Self.resolve(r: [Self.request { $0.keepNeedsAttention = true; $0.keep = Self.progress }]) == .needsAttention(.keep))
        #expect(Self.resolve(r: [Self.request { $0.mp3NeedsAttention = true }]) == .needsAttention(.mp3))
        #expect(Self.resolve(r: [Self.request { $0.keep = Self.progress }]) == .adding(queued: true))
        var sent = Self.progress; sent.phase = .moving
        #expect(Self.resolve(r: [Self.request { $0.keep = sent }]) == .adding(queued: false))
        #expect(Self.resolve(r: [Self.request { $0.collision = true }]) == .collision)
        // I4: the old kept-in-place stays as it is.
        #expect(Self.resolve(Self.artist(tags: [1]), [Self.entry(kept: true)]) == .keptInFinds)
        let main = Self.artist(path: "/music/library/A", tags: [1])
        let start = Date(timeIntervalSince1970: 1_900_000_000)
        var w = LosslessWatch(albumIds: [50], startedAt: start, autoDelete: true, deadline: start.addingTimeInterval(7 * 86_400))
        #expect(Self.resolve(main, [Self.entry(kept: true)], [Self.request { $0.lossless = w }])
                == .inLibrary(.waiting(removedOn: start.addingTimeInterval(7 * 86_400))))
        w.autoDelete = false
        #expect(Self.resolve(main, [Self.entry(kept: true)], [Self.request { $0.lossless = w }]) == .inLibrary(.waiting(removedOn: nil)))
        w.removedAt = start
        #expect(Self.resolve(main, [Self.entry(kept: true)], [Self.request { $0.lossless = w }]) == .inLibrary(.mp3Removed))
        w.losslessAt = start
        #expect(Self.resolve(main, [Self.entry(kept: true)], [Self.request { $0.lossless = w }]) == .inLibrary(.lossless))
    }

    private static func resolve(r: [MagpieRequest]) -> FindState? { resolve(artist(), [entry()], r) }

    /// Critic 16 / I9: the library has no MBID (tagless files) but the artist is one of Magpie's own finds: it
    /// resolves through the request, never "Couldn't match". Someone else's name match is never acted on (9.9).
    @Test func aTaglessOwnFindResolvesThroughItsRequest() {
        let state = ArtistLidarr.state(name: "aurora field", mbid: nil, artists: [Self.artist()], commands: [],
                                       ledger: [Self.entry()], requests: [Self.request()], findTagId: 2,
                                       findsRoot: "/music/samples")
        #expect(state == .find(lidarrId: 42, state: .find))
        let owners = LidarrArtist(id: 7, artistName: "Aurora Field", foreignArtistId: mbid(9), monitored: true)
        #expect(ArtistLidarr.state(name: "Aurora Field", mbid: nil, artists: [owners], commands: [], ledger: []) == .unmatched)
    }

    /// Item 9.2: tagless files match by Lidarr's path, else title + artist + duration (±3 s), only inside the artist's
    /// folder and only when exactly one fits; never by name alone.
    @Test func matchingWithoutTags() {
        let folder = "/music/samples/Aurora Field"
        func song(_ id: String, _ title: String = "Song", _ artist: String = "Aurora Field", d: TimeInterval = 200) -> Song {
            Song(id: id, title: title, artist: artist, album: "L", duration: d)
        }
        var rec = ExternalRecording(recordingMBID: nil, title: "Song", artist: "Aurora Field", source: .listenBrainz)
        let path = folder + "/Lowlands/01 - Song.mp3"
        let candidates = [(song: song("a"), lidarrPath: path), (song: song("b", d: 260), lidarrPath: folder + "/Live/01 - Song.mp3")]
        #expect(RequestRunner.fallbackMatch(rec, filePath: path, folder: folder, candidates: candidates) == "a", "by path")
        #expect(RequestRunner.fallbackMatch(rec, filePath: nil, folder: folder, candidates: candidates) == nil, "no duration: no guess")
        rec.duration = 202
        #expect(RequestRunner.fallbackMatch(rec, filePath: nil, folder: folder, candidates: candidates) == "a", "±3 s")
        rec.duration = 230
        #expect(RequestRunner.fallbackMatch(rec, filePath: nil, folder: folder, candidates: candidates) == nil)
        rec.duration = 200
        let twins = candidates + [(song: song("c", d: 201), lidarrPath: folder + "/Other/01.mp3")]
        #expect(RequestRunner.fallbackMatch(rec, filePath: nil, folder: folder, candidates: twins) == nil, "ambiguous")
        let outside = [(song: song("o"), lidarrPath: "/music/library/Owner/01.mp3")]
        #expect(RequestRunner.fallbackMatch(rec, filePath: "/music/library/Owner/01.mp3", folder: folder, candidates: outside) == nil,
                "never the owner's copy outside the folder")
    }
}
