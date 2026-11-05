import Foundation
import Testing
import LidarrKit
import MagpieCore
@testable import Requests

/// Task 6.2a: Finds-mode Try. A new artist goes into the confirmed Finds root with tags [magpie, magpie-find]
/// in the one A6 add; the Finds root is re-checked against fresh root folders first (G2), and an artist the
/// owner already has is never moved or tagged (A7, G6).
@Suite struct FindsTryTests {
    /// A6 in Finds mode: one POST /artist into the Finds root, both tags, nothing else written.
    @Test func newArtistGoesIntoFindsRootWithBothTags() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        h.server.artistIsNew()
        let id = try await h.runner.tryRecording(h.recording(recSingleAndAlbum), tier: .standard)
        await h.runner.settle()

        let writes = h.server.writeBodies()
        #expect(writes.map(\.0) == ["POST artist", "POST command"])
        let body = writes[0].1
        #expect(body["rootFolderPath"] as? String == "/music/samples")
        #expect(body["tags"] as? [Int] == [1, 2])
        #expect(body["qualityProfileId"] as? Int == 4, "Fast Start")
        #expect(body["metadataProfileId"] as? Int == 3, "Magpie Finds (A1)")
        #expect(body["monitored"] as? Bool == true)
        #expect(body["monitorNewItems"] as? String == "none")
        let options = try #require(body["addOptions"] as? [String: Any])
        #expect(options["albumsToMonitor"] as? [String] == [rgSingle.rawValue])
        #expect(options["searchForMissingAlbums"] as? Bool == false, "the runner searches the release itself (round 16)")
        #expect(options["monitor"] == nil, "\"none\" would unmonitor the artist too (verified on Lidarr 3.2)")

        let r = try #require(await h.request(id))
        #expect(r.plan?.mode == .finds && r.root == "/music/samples" && !r.findsUnavailable)
        #expect(r.isFind)
        let entry = try #require(try await h.ledger.entry(albumId: 50))
        #expect(entry.mode == .finds && entry.createdArtist && entry.root == "/music/samples")
        // The root folders were read fresh before the add.
        let reads = h.server.transport.requests.map { "\($0.httpMethod ?? "GET") \($0.url!.path)" }
        let rootRead = try #require(reads.firstIndex { $0.hasSuffix("/api/v1/rootfolder") })
        let add = try #require(reads.firstIndex { $0 == "POST /lidarr/api/v1/artist" })
        #expect(rootRead < add)
    }

    /// G2 at add time: a Finds root that is gone, or now nests with another root, is never written into.
    /// The request goes into the library instead (B8) and says so.
    @Test(arguments: [["/music/library"], ["/music/library", "/music/samples", "/music/samples/inner"],
                      ["/music/library", "/music/Samples"], ["/music/library", "/music/samples/"]])
    func findsRootThatNoLongerChecksOutFallsBack(roots: [String]) async throws {
        let h = await Harness(setup: Harness.findsSetup)
        h.server.artistIsNew()
        h.server.with { $0.roots = roots }
        let id = try await h.runner.tryRecording(h.recording(recSingleAndAlbum), tier: .standard)
        await h.runner.settle()

        let writes = h.server.writeBodies()
        let expectedFallback = roots != ["/music/library", "/music/samples/"]
        if expectedFallback {
            #expect(writes.map(\.0) == ["POST artist", "POST command"])
            #expect(writes[0].1["rootFolderPath"] as? String == "/music/library")
            #expect(writes[0].1["tags"] as? [Int] == [1], "no magpie-find outside the Finds root")
            let r = try #require(await h.request(id))
            #expect(r.plan?.mode == .fallback && r.findsUnavailable && !r.isFind)
            #expect(try await h.ledger.entry(albumId: 50)?.mode == .fallback)
        } else {
            // Lidarr reporting the same folder with a trailing slash is still the confirmed root.
            #expect(writes.first?.1["rootFolderPath"] as? String == "/music/samples")
        }
    }

    /// The main root moved onto the Finds folder meanwhile: never add a find there.
    @Test func findsRootEqualToMainRootFallsBack() async throws {
        let setup = RequestRunner.Setup(rootFolderPath: "/music/samples", qualityProfileId: 4, metadataProfileId: 3,
                                        tagIds: [1], finds: .init(rootFolderPath: "/music/samples", tagIds: [1, 2]))
        let h = await Harness(setup: setup)
        h.server.artistIsNew()
        let id = try await h.runner.tryRecording(h.recording(recSingleAndAlbum), tier: .standard)
        await h.runner.settle()
        #expect(h.server.writeBodies().first?.1["tags"] as? [Int] == [1])
        #expect(await h.request(id)?.findsUnavailable == true)
    }

    /// Root folders can't be read: nothing is added; the request waits and checks again later.
    @Test func rootFoldersUnreadableWaits() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        h.server.artistIsNew()
        h.server.with { $0.rootsDown = true }
        let id = try await h.runner.tryRecording(h.recording(recSingleAndAlbum), tier: .standard)
        await h.runner.settle()
        #expect(h.server.writes.isEmpty)
        guard case .waiting(let reason, _)? = await h.state(id) else { Issue.record("not waiting"); return }
        #expect(reason.kind == .serviceUnavailable)
        let r = try #require(await h.request(id))
        #expect(!r.addSent)

        h.server.with { $0.rootsDown = false }
        h.clock.advance(61)
        await h.runner.tick()
        #expect(h.server.writeBodies().first?.1["rootFolderPath"] as? String == "/music/samples")
    }

    /// G6: in Finds mode, an artist the owner already has is only monitored + searched: no root check, no
    /// artist write, no tags, and its album is not a find.
    @Test func existingArtistStaysAdditiveInFindsMode() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        h.server.ownerHasArtist(albumMonitored: false)
        let id = try await h.runner.tryRecording(h.recording(recSingleAndAlbum), tier: .standard)
        await h.runner.settle()
        #expect(h.server.writeBodies().map(\.0) == ["PUT album/monitor", "POST command"])
        #expect(!h.server.transport.requests.contains { $0.url?.path.hasSuffix("/rootfolder") == true })
        let r = try #require(await h.request(id))
        #expect(r.plan?.mode == .fallback && !r.isFind)
        #expect(try await h.ledger.entry(albumId: 31)?.mode == .fallback)
    }

    /// A second song on the same release follows the first (G7) and is a find only if the first one is.
    @Test func followerTakesTheLeadersMode() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        h.server.artistIsNew()
        h.server.with { $0.roots = ["/music/library"] }   // the Finds root is gone: the leader falls back
        let first = try await h.runner.tryRecording(h.recording(recAlbumOnly), tier: .standard)
        await h.runner.settle()
        let other = try await h.runner.tryRecording(h.recording(recAlbumOnly2, title: "Other"), tier: .standard)
        await h.runner.settle()
        #expect(h.server.writeBodies().map(\.0) == ["POST artist", "POST command"])
        #expect(await h.request(first)?.isFind == false)
        let follower = try #require(await h.request(other))
        #expect(follower.joinedTo == first && !follower.isFind)
    }

    /// An add whose answer was lost is adopted after a relaunch with the mode it was sent with.
    @Test func adoptedAddKeepsFindsMode() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        h.server.artistIsNew()
        h.server.with { $0.addAnswers504 = true }
        let id = try await h.runner.tryRecording(h.recording(recSingleAndAlbum), tier: .standard)
        await h.runner.settle()
        h.server.with { $0.addAnswers504 = false }

        let relaunched = await Harness(directory: h.dir, lidarr: h.server, setup: Harness.findsSetup)
        relaunched.clock.advance(3600)
        await relaunched.runner.tick()
        await relaunched.runner.tick()
        #expect(h.server.writeBodies().filter { $0.0 == "POST artist" }.count == 1, "never a second add")
        let r = try #require(await relaunched.request(id))
        #expect(r.plan?.mode == .finds && r.lidarrArtistId == 42)
        let entries = try await relaunched.ledger.entries
        #expect(!entries.isEmpty && entries.allSatisfy { $0.mode == .finds })
    }

    // MARK: - Final fix 2 A-I1 / A-M1: a second Try from a find artist

    /// A ready find of `recording` (new artist 42 in `/music/samples`, tagged magpie + magpie-find) as `songId`.
    static func readyFind(_ h: Harness, _ recording: MBID, songId: String) async throws -> RequestID {
        h.server.artistIsNew()
        let id = try await h.runner.tryRecording(h.recording(recording), tier: .standard)
        await h.runner.settle()
        h.library.state.withLock { $0.indexed[recording] = songId }
        await h.runner.tick()
        let r = try #require(await h.request(id))
        try #require(r.state == .ready && r.isFind && r.lidarrArtistId == 42)
        return id
    }

    /// D29: another song by an artist who is a find right now (Magpie created it, it carries magpie-find, it sits
    /// inside the Finds root) is a find too: never scrobbled, Finds copy. Nothing about the artist is written,
    /// its ledger entry stays fallback, and Not for me stays off for it (the artist was in Lidarr already).
    @Test func secondTryOfAFindArtistIsAFind() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        _ = try await Self.readyFind(h, recSingleAndAlbum, songId: "find-1")   // album 50 (the single)
        let writesBefore = h.server.writes.count
        let id = try await h.runner.tryRecording(h.recording(recAlbumOnly, title: "Other"), tier: .standard)
        await h.runner.settle()
        h.library.state.withLock { $0.indexed[recAlbumOnly] = "find-2" }
        await h.runner.tick()

        let r = try #require(await h.request(id))
        #expect(r.state == .ready && r.isFind, "a find: never now playing, never scrobbled")
        #expect(r.plan?.artistExistsInLidarr == true, "Not for me stays hidden")
        #expect(!h.server.writeBodies().dropFirst(writesBefore).contains { $0.0.hasPrefix("PUT artist") || $0.0 == "POST artist" })
        #expect(try await h.ledger.entry(albumId: 51)?.mode == .fallback)
        #expect(h.ready.withLock { $0 }.contains(id))
    }

    /// The same artist once it isn't a find any more (magpie-find came off, e.g. kept in place): a library song.
    @Test func secondTryOfAKeptArtistIsNotAFind() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        _ = try await Self.readyFind(h, recSingleAndAlbum, songId: "find-1")
        h.server.with { s in s.artists[0].tags = [1] }
        let id = try await h.runner.tryRecording(h.recording(recAlbumOnly, title: "Other"), tier: .standard)
        await h.runner.settle()
        #expect(await h.request(id)?.isFind == false)
    }

    /// Outside the Finds root (moved by Keep) it isn't a find either, tags or not.
    @Test func secondTryOfAMovedArtistIsNotAFind() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        _ = try await Self.readyFind(h, recSingleAndAlbum, songId: "find-1")
        h.server.with { s in s.artists[0].root = "/music/library"; s.artists[0].path = "/music/library/Aurora Field" }
        let id = try await h.runner.tryRecording(h.recording(recAlbumOnly, title: "Other"), tier: .standard)
        await h.runner.settle()
        #expect(await h.request(id)?.isFind == false)
    }

    /// A-M1: a second Try of the find's own release group once the find is ready keeps the find's ledger entry
    /// (Magpie monitored it; it's a find), so Not for me and clean-up still know what Magpie did.
    @Test func secondTryOfTheSameReleaseKeepsTheFindsEntry() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let first = try await Self.readyFind(h, recAlbumOnly, songId: "find-1")   // album 51
        let before = try #require(try await h.ledger.entry(albumId: 51))
        try #require(before.mode == .finds && !before.wasMonitoredBefore)
        let id = try await h.runner.tryRecording(h.recording(recAlbumOnly2, title: "Other"), tier: .standard)
        await h.runner.settle()

        #expect(await h.request(id)?.isFind == true)
        let after = try #require(try await h.ledger.entry(albumId: 51))
        #expect(after.mode == .finds && !after.wasMonitoredBefore && after.createdArtist)
        #expect(after.requestId == first.description)
    }

    /// Without Finds set up, Try is the M5 fallback, unchanged: no root-folder read.
    @Test func withoutFindsNoRootCheck() async throws {
        let h = await Harness()
        h.server.artistIsNew()
        let id = try await h.runner.tryRecording(h.recording(recSingleAndAlbum), tier: .standard)
        await h.runner.settle()
        #expect(!h.server.transport.requests.contains { $0.url?.path.hasSuffix("/rootfolder") == true })
        let r = try #require(await h.request(id))
        #expect(r.plan?.mode == .fallback && !r.findsUnavailable)
    }
}

@Suite struct FindsRequestStoreTests {
    /// Requests saved before Task 6.2a have no Finds keys: they still load (a damaged-file move-aside would
    /// lose in-flight requests).
    @Test func olderRequestsStillDecode() throws {
        var r = MagpieRequest(recording: ExternalRecording(recordingMBID: recAlbumOnly, title: "Song", artist: "A",
                                                           source: .listenBrainz),
                              tier: .patient, createdAt: Date(timeIntervalSince1970: 1_900_000_000))
        r.findsUnavailable = true
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode([r])) as! [[String: Any]]
        #expect(object[0]["findsFellBack"] as? Bool == true)
        object[0]["findsFellBack"] = nil
        let decoded = try JSONDecoder().decode([MagpieRequest].self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.first?.findsUnavailable == false)
    }
}
