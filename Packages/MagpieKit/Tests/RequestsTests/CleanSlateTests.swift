import Foundation
import Testing
import LidarrKit
import MagpieCore
import MagpieTestSupport
import SlskdKit
@testable import Requests

/// Round 23 (owner, 2026-11-07, D191–D194): "when an artist is deleted, it should also delete all the files. This includes
/// those in Lidarr, slskd and clean up all the search information etc so it has a clean slate if downloaded again."
/// When Magpie removes an artist it added (Not for me, Stop looking), first Lidarr's blocklist entries for it go, then
/// slskd's finished downloads of its grabs (files inside slskd's downloads folder and their records), and only then the
/// artist. A failure never holds the artist's removal back; it is recorded on the request. An artist that stays, or one
/// the owner had, is never touched.
@Suite struct CleanSlateTests {
    static let folder = "Lowlands (2016)"
    static let remote = "@@share\\Music\\Aurora Field\\Lowlands (2016)"

    static func paths(_ h: Harness, after before: Int) -> [String] {
        NotForMeTests.writePaths(h, after: before)
    }

    /// slskd connected, its switch on, holding the find's album (two finished files) and someone else's download under way.
    static func connectSlskd(_ h: Harness, on: Bool = true) async -> (FakeSlskd, [UUID]) {
        let slskd = FakeSlskd()
        let ids = [UUID(), UUID(), UUID()]
        slskd.with { s in
            s.transfers = [
                .init(id: ids[0], username: "jordan", directory: remote, file: "01 - Song.flac"),
                .init(id: ids[1], username: "jordan", directory: remote, file: "02 - Other.flac"),
                .init(id: ids[2], username: "sam", directory: "@@y\\Another", file: "01 - Busy.flac", state: "InProgress"),
            ]
            s.folders = [folder: (["01 - Song.flac", "02 - Other.flac"], []), "Another": (["01 - Busy.flac"], [])]
        }
        let client = SlskdClient(base: URL(string: "https://nas.local/slskd")!, apiKey: "test-slskd-key", transport: slskd)
        let gate = SlskdWriteGate(client: client, defaultsSuite: h.suite)
        await gate.setEnabled(on)
        await h.runner.useSlskd(RequestRunner.SlskdAccess(client: client, gate: gate))
        h.server.with { $0.imports = [(50, "/downloads/slskd/\(folder)/01 - Song.flac"), (50, "/downloads/slskd/\(folder)/02 - Other.flac")] }
        return (slskd, ids)
    }

    // MARK: - Lidarr's blocklist (D191)

    @Test func notForMeClearsTheArtistsBlocklistBeforeTheArtistGoes() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await NotForMeTests.readyFind(h)
        h.server.with { $0.blocklist = [(5, 42), (6, 42), (8, 7)] }
        let before = h.server.writes.count

        #expect(try await h.runner.notForMe(id, permanentConfirmed: false) == .removed)

        #expect(Self.paths(h, after: before) == [
            "DELETE trackfile/bulk", "PUT album/monitor", "DELETE blocklist/bulk",
            "DELETE artist/42?deleteFiles=false&addImportListExclusion=false",
        ])
        let body = try #require(NotForMeTests.writes(h, after: before).first { $0.0 == "DELETE blocklist/bulk" }?.1)
        #expect(body.count == 1 && Set(body["ids"] as? [Int] ?? []) == [5, 6])
        #expect(h.server.with { $0.blocklist.map(\.id) } == [8], "the owner's artist's entry stays")
        let slate = try #require(await h.request(id)?.cleanSlate)
        #expect(slate.artistId == 42 && slate.blocklistRemoved == 2 && !slate.blocklistFailed)
    }

    @Test func stopLookingClearsTheBlocklistToo() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await StoppedFindTests.searchingFind(h)
        h.server.with { s in
            for i in s.albums.indices where s.albums[i].id != 50 { s.albums[i].monitored = false }
            s.blocklist = [(5, 42)]
        }
        await h.runner.cancel(id)
        await h.runner.tick()
        let paths = h.server.writes.map { "\($0.httpMethod!) \($0.url!.path.replacingOccurrences(of: "/lidarr/api/v1/", with: ""))" }
        #expect(paths.suffix(2) == ["DELETE blocklist/bulk", "DELETE artist/42"])
        #expect(await h.request(id)?.cleanSlate?.blocklistRemoved == 1)
    }

    @Test func noEntriesNoWrite() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await NotForMeTests.readyFind(h)
        h.server.with { $0.blocklist = [(8, 7)] }
        let before = h.server.writes.count
        _ = try await h.runner.notForMe(id, permanentConfirmed: false)
        #expect(!Self.paths(h, after: before).contains("DELETE blocklist/bulk"))
        #expect(await h.request(id)?.cleanSlate?.blocklistRemoved == 0)
    }

    @Test func aBlocklistThatCantBeReadDoesntHoldTheArtistBack() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await NotForMeTests.readyFind(h)
        h.server.with { s in s.blocklist = [(5, 42)]; s.blocklistDown = true }
        _ = try await h.runner.notForMe(id, permanentConfirmed: false)
        #expect(h.server.with { $0.deletedArtists } == [42])
        let slate = try #require(await h.request(id)?.cleanSlate)
        #expect(slate.blocklistFailed && slate.blocklistRemoved == nil)
    }

    /// An artist that stays (another album still monitored) keeps its blocklist: nothing of the clean slate runs.
    @Test func anArtistThatStaysIsLeftAlone() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await KeepTests.readyFind(h)   // other albums of the artist still monitored
        h.server.with { $0.blocklist = [(5, 42)] }
        let before = h.server.writes.count
        _ = try await h.runner.notForMe(id, permanentConfirmed: false)
        #expect(h.server.with { $0.deletedArtists }.isEmpty)
        #expect(!Self.paths(h, after: before).contains("DELETE blocklist/bulk"))
        #expect(await h.request(id)?.cleanSlate == nil)
    }

    /// M6: the clean slate is saved before its first write, and runs once: when the artist's removal is tried again
    /// (Lidarr didn't answer), nothing of it is sent a second time.
    @Test func savedFirstAndNeverRepeated() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await NotForMeTests.readyFind(h)
        h.server.with { s in
            s.blocklist = [(5, 42)]
            s.artistDeleteFails503 = 1
            s.hold = ("/blocklist/bulk", 1)
            s.holdMethod = "DELETE"
        }
        let task = Task { try await h.runner.notForMe(id, permanentConfirmed: false) }
        let deadline = Date().addingTimeInterval(10)
        while await !h.server.latch.hasArrived, Date() < deadline { await Task.yield() }
        let arrived = await h.server.latch.hasArrived
        let saved = try? await RequestStore(fileURL: h.store.fileURL).load().first { $0.id == id }
        await h.server.latch.release()   // never left hanging, arrived or not
        #expect(arrived, "the blocklist delete was sent")
        #expect(saved?.cleanSlate?.artistId == 42, "on disk before the write went")
        _ = try await task.value
        #expect(h.server.writes.filter { $0.url?.path.hasSuffix("/blocklist/bulk") == true }.count == 1)
        #expect(h.server.with { $0.deletedArtists } == [42])
    }

    // MARK: - slskd (D192, D193)

    @Test func slskdsFinishedDownloadsOfTheArtistGoBeforeTheArtist() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await NotForMeTests.readyFind(h)
        let (slskd, ids) = await Self.connectSlskd(h)
        _ = try await h.runner.notForMe(id, permanentConfirmed: false)

        // Lidarr forgets an artist's history with it: the folder was found only because this ran first.
        let deleted = slskd.with { $0.deleted }
        // Fix round 1 M2: file by file, then the folder once it is empty, then the records.
        #expect(deleted.count == 5)
        #expect(Set(deleted.prefix(2)) == ["file \(Self.folder)/01 - Song.flac", "file \(Self.folder)/02 - Other.flac"])
        #expect(deleted.dropFirst(2).first == "folder \(Self.folder)")
        #expect(Set(deleted.suffix(2)) == Set(ids[0...1].map { "record \($0.uuidString.lowercased())" }))
        #expect(slskd.with { $0.folders["Another"] } != nil, "someone else's download under way is never touched")
        #expect(slskd.with { $0.transfers.map(\.id) } == [ids[2]])
        #expect(h.server.with { $0.deletedArtists } == [42])
        let slate = try #require(await h.request(id)?.cleanSlate)
        #expect(slate.slskdFilesRemoved == 2 && slate.slskdRecordsRemoved == 2 && !slate.slskdFailed)
        // Only the allow-listed routes were called.
        #expect(slskd.requests.allSatisfy { $0.url?.path.contains("/api/v0/transfers/downloads") == true
            || $0.url?.path.contains("/api/v0/files/downloads/") == true })
    }

    @Test func aFolderHoldingAnythingElseLosesOnlyTheDownloadedFiles() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await NotForMeTests.readyFind(h)
        let (slskd, _) = await Self.connectSlskd(h)
        slskd.with { $0.folders[Self.folder]?.files.append("notes.txt") }
        _ = try await h.runner.notForMe(id, permanentConfirmed: false)
        #expect(Set(slskd.with { $0.deleted }.filter { $0.hasPrefix("file ") })
                == ["file \(Self.folder)/01 - Song.flac", "file \(Self.folder)/02 - Other.flac"])
        #expect(slskd.with { $0.folders[Self.folder]?.files } == ["notes.txt"])
    }

    /// Fix round 1 I1: someone's other album, downloaded into a folder of the same name and sharing a track name, keeps
    /// its files, its records and the folder.
    @Test func aForeignAlbumInTheSameFolderKeepsItsFilesAndRecords() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await NotForMeTests.readyFind(h)
        let (slskd, ids) = await Self.connectSlskd(h)
        let theirs = [UUID(), UUID()]
        slskd.with { s in
            s.transfers += [.init(id: theirs[0], username: "sam", directory: "@@y\\Other\\Lowlands (2016)", file: "01 - Song.flac"),
                            .init(id: theirs[1], username: "sam", directory: "@@y\\Other\\Lowlands (2016)", file: "09 - Theirs.flac")]
            s.folders[Self.folder]?.files.append("09 - Theirs.flac")
        }
        _ = try await h.runner.notForMe(id, permanentConfirmed: false)
        let deleted = slskd.with { $0.deleted }
        #expect(!deleted.contains { $0.contains("09 - Theirs") || $0.hasPrefix("folder ") })
        #expect(!deleted.contains { theirs.map { "record \($0.uuidString.lowercased())" }.contains($0) }, "sam's records stay")
        #expect(slskd.with { $0.folders[Self.folder]?.files } == ["09 - Theirs.flac"])
        #expect(Set(deleted.filter { $0.hasPrefix("record ") }) == Set(ids[0...1].map { "record \($0.uuidString.lowercased())" }))
    }

    /// Fix round 1 M3: when the artist's removal stops (out of tries) the clean slate never ran: its blocklist stays.
    @Test func anArtistWhoseRemovalStopsKeepsItsBlocklist() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await NotForMeTests.readyFind(h)
        h.server.with { s in
            s.blocklist = [(5, 42)]
            s.deleteFails503 = 2         // two unanswered deletes,
            s.deleteAppliedThen504 = 1   // then one that landed but lost its answer: three, out of tries
            s.unmonitorOnDelete = true   // (Lidarr unmonitored it: no write before the artist's step)
        }
        _ = try? await h.runner.notForMe(id, permanentConfirmed: false)
        #expect(h.server.with { $0.deletedArtists }.isEmpty)
        #expect(h.server.with { $0.blocklist.map(\.id) } == [5])
        #expect(await h.request(id)?.cleanSlate == nil)
    }

    @Test func slskdChangesOffTouchesNothing() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await NotForMeTests.readyFind(h)
        let (slskd, _) = await Self.connectSlskd(h, on: false)
        _ = try await h.runner.notForMe(id, permanentConfirmed: false)
        #expect(slskd.writes.isEmpty && slskd.requests.isEmpty)
        #expect(h.server.with { $0.deletedArtists } == [42])
        #expect(await h.request(id)?.cleanSlate?.slskdSkipped == true)
    }

    @Test func anAlbumStillDownloadingIsLeftAlone() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await NotForMeTests.readyFind(h)
        let (slskd, _) = await Self.connectSlskd(h)
        slskd.with { s in s.transfers.append(.init(username: "jordan", directory: Self.remote, file: "03 - Late.flac", state: "InProgress")) }
        _ = try await h.runner.notForMe(id, permanentConfirmed: false)
        #expect(slskd.writes.isEmpty)
        #expect(h.server.with { $0.deletedArtists } == [42])
    }

    @Test func slskdRefusingFileDeletesIsRecordedAndTheArtistStillGoes() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await NotForMeTests.readyFind(h)
        let (slskd, ids) = await Self.connectSlskd(h)
        slskd.with { $0.remoteFileManagement = false }
        _ = try await h.runner.notForMe(id, permanentConfirmed: false)
        #expect(slskd.with { $0.deleted }.isEmpty, "records stay with files that couldn't go")
        #expect(slskd.with { $0.transfers.map(\.id) }.count == ids.count)
        #expect(h.server.with { $0.deletedArtists } == [42])
        #expect(await h.request(id)?.cleanSlate?.slskdFailed == true)
    }

    @Test func noImportRecordNoSlskdWrite() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await NotForMeTests.readyFind(h)
        let (slskd, _) = await Self.connectSlskd(h)
        h.server.with { $0.imports = [] }
        _ = try await h.runner.notForMe(id, permanentConfirmed: false)
        #expect(slskd.writes.isEmpty)
        #expect(await h.request(id)?.cleanSlate?.slskdFilesRemoved == 0)
    }
}
