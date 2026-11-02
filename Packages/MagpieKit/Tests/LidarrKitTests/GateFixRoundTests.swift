import Foundation
import Testing
import MagpieCore
import MagpieTestSupport
@testable import LidarrKit

/// Y5 fix round 1 (review I1, I4, I9, Minor M2): the gate and the ledger.
@Suite struct GateFixRoundTests {
    typealias Fake = KeptLossyDeleteTests.Fake
    static let keptMBID = MBID("42424242-4242-4242-8242-424242424242")

    static func entry51(_ files: [FindFile]?) -> LedgerEntry {
        var e = LedgerEntry(lidarrArtistId: 42, albumId: 51, rgMbid: MBID("00000000-0000-0000-0000-000000000051")!,
                            createdArtist: true, wasMonitoredBefore: false, root: "/music/samples", mode: .finds,
                            keptAt: Date(), send: .applied, artistMbid: keptMBID)
        e.findFiles = files
        return e
    }

    /// I1: an artist with two ledger entries carries the record on both: one distinct record still matches.
    @Test func aTwoEntryArtistsMP3IsDeleted() async throws {
        let fake = try await Fake()
        try await fake.ledger.record(Self.entry51(try await fake.ledger.entries.first { $0.albumId == 50 }?.findFiles))
        _ = try await (await fake.gate()).send("DELETE", "trackfile/20", body: nil)
        #expect(fake.writes.count == 1)
    }

    /// I1: copies that disagree (size) refuse.
    @Test func conflictingRecordCopiesRefuse() async throws {
        let fake = try await Fake()
        try await fake.ledger.record(Self.entry51([FindFile(id: 10, albumId: 50, foreignTrackId: "ft-1",
                                                            relativePath: "Album/01.mp3", size: 999, quality: "MP3-320")]))
        #expect(await KeptLossyDeleteTests.refused(await fake.gate(), "DELETE", "trackfile/20"))
        #expect(fake.writes.isEmpty)
    }

    /// I4: recording an entry for the same album (a Try on it) keeps the Keep's intent and its file record.
    @Test func aRecordForTheSameAlbumKeepsTheKeepState() async throws {
        let fake = try await Fake(kept: false, intent: true)
        try await fake.ledger.record(LedgerEntry(lidarrArtistId: 42, albumId: 50, rgMbid: MBID("00000000-0000-0000-0000-000000000050")!,
                                                 createdArtist: true, wasMonitoredBefore: false, root: "/music/samples",
                                                 mode: .finds, send: .applied, artistMbid: Self.keptMBID))
        let e = try #require(try await fake.ledger.entries.first { $0.albumId == 50 })
        #expect(e.keepIntentAt != nil && e.findFiles?.count == 1)
    }

    /// I9: a search only for albums the ledger knows, a refresh only for an artist it knows, and neither through a gate
    /// without the ledger.
    @Test func commandsAreConfinedToTheLedger() async throws {
        let fake = try await Fake()
        let gate = await fake.gate()
        #expect(await KeptLossyDeleteTests.refused(gate, "POST", "command", #"{"name":"AlbumSearch","albumIds":[50,99]}"#))
        #expect(await KeptLossyDeleteTests.refused(gate, "POST", "command", #"{"name":"AlbumSearch","albumIds":[]}"#))
        #expect(await KeptLossyDeleteTests.refused(gate, "POST", "command", #"{"name":"RefreshArtist","artistId":99}"#))
        #expect(fake.writes.isEmpty)
        func body(_ text: String) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: json(text)) }
        _ = try await gate.send("POST", "command", body: try body(#"{"name":"AlbumSearch","albumIds":[50]}"#))
        _ = try await gate.send("POST", "command", body: try body(#"{"name":"RefreshArtist","artistId":42}"#))
        #expect(fake.writes.count == 2)
        let plain = LidarrWriteGate(client: fake.client, logURL: fake.env.logURL, defaultsSuite: fake.env.defaults)
        await plain.setEnabled(true)
        #expect(await KeptLossyDeleteTests.refused(plain, "POST", "command", #"{"name":"AlbumSearch","albumIds":[50]}"#))
    }

    @Test func opusIsLossy() { #expect(WriteConfinement.isLossy("Opus 128")) }

    /// I2: a note in the change log, nothing sent.
    @Test func aNoteIsLoggedAndNothingSent() async throws {
        let fake = try await Fake()
        let gate = await fake.gate()
        await gate.note("cleared a Keep that never reached Lidarr")
        #expect(await gate.changeLog().last?.method == "NOTE")
        #expect(fake.writes.isEmpty)
    }

    /// Critic test 1 (the queue reader): a queue delete of an album whose artist has only a Keep intent refuses.
    @Test func aQueueDeleteRefusesOnAnIntent() async throws {
        let fake = try await QueueDeleteGateTests.Fake()
        try await fake.ledger.update(artistId: 7) { $0.keepIntentAt = Date() }
        #expect(await KeptLossyDeleteTests.refused(await fake.gate(), "DELETE", "queue/501" + QueueDeleteGateTests.shape))
        #expect(fake.writes.isEmpty)
    }
}
