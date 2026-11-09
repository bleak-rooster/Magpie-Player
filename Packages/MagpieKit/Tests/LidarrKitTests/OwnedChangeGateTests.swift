import Foundation
import os
import Testing
import MagpieCore
import MagpieTestSupport
@testable import LidarrKit

/// Round 24 (owner, 2026-11-08, D243): the gate's proofs for changing what an owner's artist's monitoring covers and for
/// cleaning up its unmatched songs, from the ledger's monitoring book and fresh reads, never from the caller.
///
/// Roots: `/music/library` (main), `/music/samples` (Finds, tag 2), `/music/other` (another of the owner's roots).
/// Artist 20: the owner's, at `/music/library/Owner`, on "Owner Profile" (5). Artist 21: the owner's, in `/music/other`.
/// Albums of 20: 1 (Album, monitored, before), 2 (EP, unmonitored now, before), 3 (Album, appeared with the refresh),
/// 4 (Single, appeared). Files: 200 (album 2, 1000 B, inside), 201 (album 2, outside the artist's folder), 202 (album 1,
/// monitored), 203 (album 2, size changed from 500), 204 (album 2, favourited: left out).
@Suite struct OwnedChangeGateTests {
    static let ownerMBID = MBID("20202020-2020-4020-8020-202020202020")!
    static let otherMBID = MBID("21212121-2121-4121-8121-212121212121")!
    static let albumsOnly = ReleaseTypes(albums: true, eps: false, singles: false)

    final class Fake: @unchecked Sendable {
        struct State {
            var artistProfile = 5
            var trackFileFails = false
            var albumMonitored: [Int: Bool] = [1: true, 2: false, 3: false, 4: false]
        }
        let env = GateEnv()
        let transport = MockTransport()
        let client: LidarrClient
        let ledger: Ledger
        let state = OSAllocatedUnfairLock(initialState: State())

        init() {
            client = LidarrClient(base: testBase, apiKey: testKey, transport: transport)
            ledger = Ledger(fileURL: nil, instance: client.instanceScope)
            let t = transport
            let reply = Fake.reply
            t.stub(pathSuffix: "/api/v1/rootfolder") { _ in
                reply([["id": 1, "path": "/music/library"], ["id": 2, "path": "/music/samples"], ["id": 3, "path": "/music/other"]])
            }
            t.stub(pathSuffix: "/api/v1/metadataprofile") { _ in
                reply([["id": 5, "name": "Owner Profile"], ["id": 7, "name": "Another Owner Profile"],
                       ["id": 30, "name": OwnedChangeGateTests.albumsOnly.profileName],
                       ["id": 31, "name": "Magpie Albums+EPs+Singles \u{00B7} Studio"]])
            }
            t.stub(pathSuffix: "/api/v1/artist/20") { [state] _ in
                reply(["id": 20, "artistName": "Owner", "foreignArtistId": OwnedChangeGateTests.ownerMBID.rawValue,
                       "path": "/music/library/Owner", "rootFolderPath": "/music/library", "monitored": true,
                       "tags": [Int](), "metadataProfileId": state.withLock { $0.artistProfile }])
            }
            t.stub(pathSuffix: "/api/v1/artist/21") { _ in
                reply(["id": 21, "artistName": "Elsewhere", "foreignArtistId": OwnedChangeGateTests.otherMBID.rawValue,
                       "path": "/music/other/Elsewhere", "rootFolderPath": "/music/other", "monitored": true,
                       "tags": [Int](), "metadataProfileId": 5])
            }
            let albums: [(Int, String)] = [(1, "Album"), (2, "EP"), (3, "Album"), (4, "Single")]
            t.stub(pathSuffix: "/api/v1/album") { [state] _ in
                let monitored = state.withLock { $0.albumMonitored }
                return reply(albums.map { ["id": $0.0, "title": "A\($0.0)", "artistId": 20, "albumType": $0.1,
                                           "monitored": monitored[$0.0] ?? false] })
            }
            for (id, type) in albums {
                t.stub(pathSuffix: "/api/v1/album/\(id)") { [state] _ in
                    reply(["id": id, "title": "A\(id)", "artistId": 20, "albumType": type,
                           "monitored": state.withLock { $0.albumMonitored[id] ?? false }])
                }
            }
            t.stub(pathSuffix: "/api/v1/album/9") { _ in reply(["id": 9, "title": "B", "artistId": 21, "albumType": "Album"]) }
            func file(_ id: Int, album: Int, path: String, size: Int) {
                t.stub(pathSuffix: "/api/v1/trackfile/\(id)") { [state] _ in
                    if state.withLock({ $0.trackFileFails }) { return .init(status: 503) }
                    return reply(["id": id, "artistId": 20, "albumId": album, "path": path, "size": size,
                                  "quality": ["quality": ["name": "FLAC"]]])
                }
            }
            file(200, album: 2, path: "/music/library/Owner/EP/01.flac", size: 1000)
            file(201, album: 2, path: "/music/library/Someone Else/EP/01.flac", size: 1000)
            file(202, album: 1, path: "/music/library/Owner/Album/01.flac", size: 10)
            file(203, album: 2, path: "/music/library/Owner/EP/03.flac", size: 999)
            file(204, album: 2, path: "/music/library/Owner/EP/04.flac", size: 1000)
            for id in 205...260 { file(id, album: 2, path: "/music/library/Owner/EP/\(id).flac", size: 1000) }
            for m in ["POST", "PUT", "DELETE"] { t.stub(method: m, pathSuffix: "", body: json(#"{"id":1}"#)) }
        }

        @Sendable static func reply(_ object: Any) -> MockTransport.Response {
            .init(status: 200, body: try! JSONSerialization.data(withJSONObject: object))
        }

        func gate(monitoringOn: Bool = true) async -> LidarrWriteGate {
            let confinement = WriteConfinement(ledger: ledger, roots: {
                WriteConfinement.Roots(mainRoot: "/music/library", findsRoot: "/music/samples", findTagId: 2)
            })
            let gate = LidarrWriteGate(client: client, logURL: env.logURL, defaultsSuite: env.defaults, confinement: confinement)
            await gate.setEnabled(true)
            await gate.setMonitoringChangesEnabled(monitoringOn)
            return gate
        }

        var writes: [URLRequest] { transport.requests.filter { ($0.httpMethod ?? "GET") != "GET" } }

        /// The owner's confirmed change for artist 20: Albums only (profile 30), EP 2 stops being monitored, album 3
        /// appeared with the refresh and is to be monitored.
        @discardableResult
        func change(artist: Int = 20, mbid: MBID = OwnedChangeGateTests.ownerMBID, target: Int = 30) async throws -> MonitoringIntent {
            var intent = MonitoringIntent(kind: .monitoringChange, artistId: artist, artistMbid: mbid, previousProfileId: 5,
                                          targetProfileId: target, targetTypes: OwnedChangeGateTests.albumsOnly,
                                          beforeAlbumIds: [1, 2], unmonitorAlbumIds: [2], createdAt: Date())
            intent.monitorAlbumIds = [3, 4]
            try await ledger.saveIntent(intent)
            return intent
        }

        /// The owner's confirmed clean-up of artist 20's EP files (204 favourited, left out).
        @discardableResult
        func cleanup(files: [OwnedFile]? = nil, excluded: [Int] = [204]) async throws -> MonitoringIntent {
            let named = files ?? ([200, 201, 202, 204] + Array(205...260)).map { OwnedFile(id: $0, albumId: $0 == 202 ? 1 : 2, size: 1000) }
                + [OwnedFile(id: 203, albumId: 2, size: 500)]
            let intent = MonitoringIntent(kind: .unmatchedCleanup, artistId: 20, artistMbid: OwnedChangeGateTests.ownerMBID,
                                          previousProfileId: 5, files: named.map { $0.id == 202 ? OwnedFile(id: 202, albumId: 1, size: 10) : $0 },
                                          excludedFileIds: excluded, createdAt: Date())
            try await ledger.saveIntent(intent)
            return intent
        }
    }

    struct Profile: Encodable, Sendable { var artistIds: [Int]; var metadataProfileId: Int }
    struct Monitor: Encodable, Sendable { var albumIds: [Int]; var monitored: Bool }
    struct Files: Encodable, Sendable { var trackFileIds: [Int] }

    /// Sends and says how the gate answered: nil when sent.
    static func answer(_ gate: LidarrWriteGate, _ method: String, _ path: String, _ body: (any Encodable & Sendable)?,
                       _ shape: ConfinedShape) async -> WriteGateError? {
        do {
            _ = try await gate.send(method, path, body: body, confinedAs: shape)
            return nil
        } catch let e as WriteGateError {
            return e
        } catch {
            Issue.record("unexpected \(error)")
            return .unconfirmed
        }
    }

    static func isRefused(_ e: WriteGateError?) -> Bool { if case .forbidden? = e { true } else { false } }

    // MARK: - The profile

    @Test func change_assignsOnlyMagpieProfile() async throws {
        let fake = Fake()
        try await fake.change()
        let gate = await fake.gate()
        // The owner's other profile: never, even named by the caller.
        #expect(Self.isRefused(await Self.answer(gate, "PUT", "artist/editor", Profile(artistIds: [20], metadataProfileId: 7), .ownedChange)))
        // Another Magpie profile than the one the owner's choice names: refused too.
        #expect(Self.isRefused(await Self.answer(gate, "PUT", "artist/editor", Profile(artistIds: [20], metadataProfileId: 31), .ownedChange)))
        #expect(fake.writes.isEmpty)
        #expect(await Self.answer(gate, "PUT", "artist/editor", Profile(artistIds: [20], metadataProfileId: 30), .ownedChange) == nil)
        #expect(fake.writes.count == 1)
    }

    @Test func change_targetIsAnOwnerProfile_refused() async throws {
        let fake = Fake()
        try await fake.change(target: 7)   // an intent naming the owner's profile (a runner bug) still never passes
        let gate = await fake.gate()
        #expect(Self.isRefused(await Self.answer(gate, "PUT", "artist/editor", Profile(artistIds: [20], metadataProfileId: 7), .ownedChange)))
        #expect(fake.writes.isEmpty)
    }

    @Test func change_bodyHasNoRootFolderNoMoveFiles() async throws {
        let fake = Fake()
        try await fake.change()
        let gate = await fake.gate()
        for extra in [#""rootFolderPath":"/music/library""#, #""moveFiles":false,"rootFolderPath":"/music/library""#,
                      #""monitored":true"#, #""qualityProfileId":2"#, #""monitorNewItems":"all""#] {
            let body = try JSONDecoder().decode(JSONValue.self, from: json(#"{"artistIds":[20],"metadataProfileId":30,"# + extra + "}"))
            #expect(Self.isRefused(await Self.answer(gate, "PUT", "artist/editor", body, .ownedChange)), "\(extra)")
        }
        #expect(fake.writes.isEmpty)
    }

    @Test func change_refusedForOtherRoot() async throws {
        let fake = Fake()
        try await fake.change(artist: 21, mbid: Self.otherMBID)
        let gate = await fake.gate()
        #expect(Self.isRefused(await Self.answer(gate, "PUT", "artist/editor", Profile(artistIds: [21], metadataProfileId: 30), .ownedChange)))
        struct Refresh: Encodable, Sendable { var name = "RefreshArtist"; var artistId: Int }
        #expect(Self.isRefused(await Self.answer(gate, "POST", "command", Refresh(artistId: 21), .ownedChange)))
        #expect(fake.writes.isEmpty)
    }

    @Test func change_refusedWithoutAnIntentOrWithTheSwitchOff() async throws {
        let fake = Fake()
        let gate = await fake.gate()
        #expect(Self.isRefused(await Self.answer(gate, "PUT", "artist/editor", Profile(artistIds: [20], metadataProfileId: 30), .ownedChange)))
        try await fake.change()
        let off = await fake.gate(monitoringOn: false)
        #expect(Self.isRefused(await Self.answer(off, "PUT", "artist/editor", Profile(artistIds: [20], metadataProfileId: 30), .ownedChange)))
        // Another artist's id reused for someone else: the MusicBrainz id the intent recorded must match.
        let other = Fake()
        try await other.change(mbid: Self.otherMBID)
        #expect(Self.isRefused(await Self.answer(await other.gate(), "PUT", "artist/editor", Profile(artistIds: [20], metadataProfileId: 30), .ownedChange)))
        #expect(fake.writes.isEmpty && other.writes.isEmpty)
    }

    // MARK: - Albums

    @Test func change_unmonitorsOnlyListedAlbumsOfThatArtist() async throws {
        let fake = Fake()
        try await fake.change()
        let gate = await fake.gate()
        #expect(Self.isRefused(await Self.answer(gate, "PUT", "album/monitor", Monitor(albumIds: [1], monitored: false), .ownedChange)))
        #expect(Self.isRefused(await Self.answer(gate, "PUT", "album/monitor", Monitor(albumIds: [2, 9], monitored: false), .ownedChange)))
        #expect(fake.writes.isEmpty)
        #expect(await Self.answer(gate, "PUT", "album/monitor", Monitor(albumIds: [2], monitored: false), .ownedChange) == nil)
        #expect(fake.writes.count == 1)
    }

    @Test func change_neverUnmonitorsAnAlbumTheChoiceStillIncludes() async throws {
        let fake = Fake()
        var intent = try await fake.change()
        intent.unmonitorAlbumIds = [1, 2]   // album 1 is an Album: Albums only still includes it
        try await fake.ledger.saveIntent(intent)
        #expect(Self.isRefused(await Self.answer(await fake.gate(), "PUT", "album/monitor", Monitor(albumIds: [1], monitored: false), .ownedChange)))
        #expect(fake.writes.isEmpty)
    }

    @Test func change_neverUnmonitorsAnAlbumAMagpieRequestUses() async throws {
        let fake = Fake()
        try await fake.change()
        try await fake.ledger.record(LedgerEntry(lidarrArtistId: 20, albumId: 2, rgMbid: MBID("00000000-0000-0000-0000-000000000002")!,
                                                 createdArtist: false, wasMonitoredBefore: false, root: "/music/library",
                                                 mode: .fallback, send: .applied))
        #expect(Self.isRefused(await Self.answer(await fake.gate(), "PUT", "album/monitor", Monitor(albumIds: [2], monitored: false), .ownedChange)))
        #expect(fake.writes.isEmpty)
    }

    @Test func change_monitorsOnlyNewAlbumsTheChoiceIncludes() async throws {
        let fake = Fake()
        try await fake.change()
        let gate = await fake.gate()
        #expect(Self.isRefused(await Self.answer(gate, "PUT", "album/monitor", Monitor(albumIds: [1], monitored: true), .ownedChange)), "there before")
        #expect(Self.isRefused(await Self.answer(gate, "PUT", "album/monitor", Monitor(albumIds: [4], monitored: true), .ownedChange)), "a Single, not chosen")
        #expect(fake.writes.isEmpty)
        #expect(await Self.answer(gate, "PUT", "album/monitor", Monitor(albumIds: [3], monitored: true), .ownedChange) == nil)
    }

    // MARK: - The clean-up

    static func delete(_ ids: [Int]) -> Files { Files(trackFileIds: ids) }

    @Test func cleanup_deletesANamedFile() async throws {
        let fake = Fake()
        try await fake.cleanup()
        #expect(await Self.answer(await fake.gate(), "DELETE", "trackfile/bulk", Self.delete([200]), .unmatchedCleanup) == nil)
        #expect(fake.writes.count == 1)
    }

    @Test func cleanup_neverDeletesFavouritedOrInPlaylist() async throws {
        let fake = Fake()
        try await fake.cleanup()
        #expect(Self.isRefused(await Self.answer(await fake.gate(), "DELETE", "trackfile/bulk", Self.delete([200, 204]), .unmatchedCleanup)))
        #expect(fake.writes.isEmpty)
    }

    @Test func cleanup_refusesFileOutsideArtistFolder() async throws {
        let fake = Fake()
        try await fake.cleanup()
        #expect(Self.isRefused(await Self.answer(await fake.gate(), "DELETE", "trackfile/bulk", Self.delete([201]), .unmatchedCleanup)))
        #expect(fake.writes.isEmpty)
    }

    @Test func cleanup_refusesMonitoredAlbum() async throws {
        let fake = Fake()
        try await fake.cleanup()
        #expect(Self.isRefused(await Self.answer(await fake.gate(), "DELETE", "trackfile/bulk", Self.delete([202]), .unmatchedCleanup)))
        // The EP monitored again by the owner meanwhile: its files stay too.
        fake.state.withLock { $0.albumMonitored[2] = true }
        #expect(Self.isRefused(await Self.answer(await fake.gate(), "DELETE", "trackfile/bulk", Self.delete([200]), .unmatchedCleanup)))
        #expect(fake.writes.isEmpty)
    }

    @Test func cleanup_refusesChangedSize() async throws {
        let fake = Fake()
        try await fake.cleanup()
        #expect(Self.isRefused(await Self.answer(await fake.gate(), "DELETE", "trackfile/bulk", Self.delete([203]), .unmatchedCleanup)))
        #expect(fake.writes.isEmpty)
    }

    @Test func cleanup_refusedWhenReadFails() async throws {
        let fake = Fake()
        try await fake.cleanup()
        fake.state.withLock { $0.trackFileFails = true }
        #expect(await Self.answer(await fake.gate(), "DELETE", "trackfile/bulk", Self.delete([200]), .unmatchedCleanup) == .unconfirmed)
        #expect(fake.writes.isEmpty)
    }

    @Test func cleanup_capsPerCall() async throws {
        let fake = Fake()
        try await fake.cleanup()
        let gate = await fake.gate()
        let fiftyOne = [200] + Array(205...254)
        #expect(fiftyOne.count == 51)
        #expect(Self.isRefused(await Self.answer(gate, "DELETE", "trackfile/bulk", Self.delete(fiftyOne), .unmatchedCleanup)))
        #expect(fake.writes.isEmpty)
        #expect(await Self.answer(gate, "DELETE", "trackfile/bulk", Self.delete(Array(fiftyOne.prefix(50))), .unmatchedCleanup) == nil)
        #expect(WriteConfinement.maxCleanupFiles == 50)
    }

    @Test func cleanup_refusesAnIdTheConfirmationDidntNameOrAChangedRecord() async throws {
        let fake = Fake()
        var intent = try await fake.cleanup(files: [OwnedFile(id: 205, albumId: 2, size: 1000)], excluded: [])
        let gate = await fake.gate()
        #expect(Self.isRefused(await Self.answer(gate, "DELETE", "trackfile/bulk", Self.delete([200]), .unmatchedCleanup)))
        // A record widened after the owner confirmed (its hash no longer matches): nothing goes.
        intent.files.append(OwnedFile(id: 200, albumId: 2, size: 1000))
        try await fake.ledger.saveIntent(intent)
        #expect(Self.isRefused(await Self.answer(gate, "DELETE", "trackfile/bulk", Self.delete([200]), .unmatchedCleanup)))
        #expect(fake.writes.isEmpty)
    }

    @Test func cleanup_refusedWhileATryIsUnderWayForTheArtist() async throws {
        let fake = Fake()
        try await fake.cleanup()
        try await fake.ledger.record(LedgerEntry(lidarrArtistId: 20, albumId: 3, rgMbid: MBID("00000000-0000-0000-0000-000000000003")!,
                                                 createdArtist: false, wasMonitoredBefore: false, root: "/music/library",
                                                 mode: .fallback, send: .applied, requestId: "r-1"))
        #expect(Self.isRefused(await Self.answer(await fake.gate(), "DELETE", "trackfile/bulk", Self.delete([200]), .unmatchedCleanup)))
        #expect(fake.writes.isEmpty)
    }

    @Test func cleanup_isTheBulkRouteOnly_andNeedsTheSwitch() async throws {
        let fake = Fake()
        try await fake.cleanup()
        #expect(Self.isRefused(await Self.answer(await fake.gate(), "DELETE", "trackfile/200", nil, .unmatchedCleanup)))
        #expect(Self.isRefused(await Self.answer(await fake.gate(monitoringOn: false), "DELETE", "trackfile/bulk", Self.delete([200]), .unmatchedCleanup)))
        // Without the name, the owner's file is no find of Magpie's: the old rules refuse it.
        do {
            _ = try await (await fake.gate()).send("DELETE", "trackfile/bulk", body: Self.delete([200]))
            Issue.record("sent")
        } catch {}
        #expect(fake.writes.isEmpty)
    }

    // MARK: - Never the artist

    @Test func gate_neverDeletesArtist() async throws {
        let fake = Fake()
        try await fake.change()
        try await fake.cleanup()
        let gate = await fake.gate()
        let path = "artist/20?deleteFiles=false&addImportListExclusion=false"
        #expect(Self.isRefused(await Self.answer(gate, "DELETE", path, nil, .ownedChange)))
        #expect(Self.isRefused(await Self.answer(gate, "DELETE", path, nil, .unmatchedCleanup)))
        do { _ = try await gate.send("DELETE", path, body: nil); Issue.record("sent") } catch {}
        struct Move: Encodable, Sendable { var artistIds: [Int]; var rootFolderPath: String; var moveFiles: Bool }
        #expect(Self.isRefused(await Self.answer(gate, "PUT", "artist/editor", Move(artistIds: [20], rootFolderPath: "/music/other", moveFiles: true), .ownedChange)))
        #expect(Self.isRefused(await Self.answer(gate, "DELETE", "queue/5?removeFromClient=true&blocklist=true&skipRedownload=true", nil, .ownedChange)))
        #expect(fake.writes.isEmpty)
    }

    // MARK: - Revert

    @Test func revert_restoresRecordedProfile() async throws {
        let fake = Fake()
        var change = try await fake.change()
        change.step = .done
        try await fake.ledger.saveIntent(change)
        fake.state.withLock { $0.artistProfile = 30 }
        let revert = MonitoringIntent(kind: .revert, artistId: 20, artistMbid: Self.ownerMBID, previousProfileId: 5,
                                      targetProfileId: 5, createdAt: Date())
        try await fake.ledger.saveIntent(revert)
        let gate = await fake.gate()
        #expect(Self.isRefused(await Self.answer(gate, "PUT", "artist/editor", Profile(artistIds: [20], metadataProfileId: 7), .ownedChange)))
        // The owner moved the artist off Magpie's profile meanwhile: left as it is.
        fake.state.withLock { $0.artistProfile = 7 }
        #expect(Self.isRefused(await Self.answer(gate, "PUT", "artist/editor", Profile(artistIds: [20], metadataProfileId: 5), .ownedChange)))
        #expect(fake.writes.isEmpty)
        fake.state.withLock { $0.artistProfile = 30 }
        #expect(await Self.answer(gate, "PUT", "artist/editor", Profile(artistIds: [20], metadataProfileId: 5), .ownedChange) == nil)
        #expect(fake.writes.count == 1)
    }

    @Test func revert_neverToAProfileNoChangeRecorded() async throws {
        let fake = Fake()
        fake.state.withLock { $0.artistProfile = 30 }
        let revert = MonitoringIntent(kind: .revert, artistId: 20, artistMbid: Self.ownerMBID, previousProfileId: 7,
                                      targetProfileId: 7, createdAt: Date())
        try await fake.ledger.saveIntent(revert)
        #expect(Self.isRefused(await Self.answer(await fake.gate(), "PUT", "artist/editor", Profile(artistIds: [20], metadataProfileId: 7), .ownedChange)))
        #expect(fake.writes.isEmpty)
    }
}
