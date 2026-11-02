import Foundation
import Testing
import MagpieCore
import MagpieTestSupport
@testable import LidarrKit

/// Y5 (C3, C4, C5, M2, M3): the gate's MP3 rule for a kept find, and the per-rule last-moment checks.
///
/// Roots: `/music/library` (main), `/music/samples` (Finds, tag 2). Artist 42: a find Magpie created and kept, now at
/// `/music/library/Find`, untagged. Its ledger records one find file: `Album/01.mp3`, 1000 bytes, track `ft-1`.
/// Artist 43: a find still in the Finds folder, tagged. Artist 7: the owner's.
private let keptMBID = "42424242-4242-4242-8242-424242424242"
private let findMBID = "43434343-4343-4343-8343-434343434343"

@Suite struct KeptLossyDeleteTests {
    struct Fake {
        let env = GateEnv()
        let transport = MockTransport()
        let latch = GateLatch()
        let client: LidarrClient
        let ledger: Ledger

        init(kept: Bool = true, intent: Bool = false, recorded: [FindFile]? = nil,
             hold: (method: String, suffix: String)? = nil) async throws {
            client = LidarrClient(base: testBase, apiKey: testKey,
                                  transport: HoldTransport(inner: transport, hold: hold, latch: latch))
            ledger = Ledger(fileURL: nil, instance: client.instanceScope)
            var entry = LedgerEntry(lidarrArtistId: 42, albumId: 50, rgMbid: MBID("00000000-0000-0000-0000-000000000050")!,
                                    createdArtist: true, wasMonitoredBefore: false, root: "/music/samples", mode: .finds,
                                    keptAt: kept ? Date() : nil, send: .applied, artistMbid: MBID(keptMBID))
            entry.keepIntentAt = intent ? Date() : nil
            entry.findFiles = recorded ?? [FindFile(id: 10, albumId: 50, foreignTrackId: "ft-1",
                                                    relativePath: "Album/01.mp3", size: 1000, quality: "MP3-320")]
            try await ledger.record(entry)
            try await ledger.record(LedgerEntry(lidarrArtistId: 43, albumId: 60, rgMbid: MBID("00000000-0000-0000-0000-000000000060")!,
                                                createdArtist: true, wasMonitoredBefore: false, root: "/music/samples",
                                                mode: .finds, send: .applied, artistMbid: MBID(findMBID)))
            try await ledger.record(LedgerEntry(lidarrArtistId: 7, albumId: 31, rgMbid: MBID("00000000-0000-0000-0000-000000000031")!,
                                                createdArtist: false, wasMonitoredBefore: false, root: "/music/library",
                                                mode: .fallback, send: .applied))
            let t = transport
            func reply(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object) }
            t.stub(pathSuffix: "/api/v1/rootfolder", body: reply([["id": 1, "path": "/music/library"], ["id": 2, "path": "/music/samples"]]))
            t.stub(pathSuffix: "/api/v1/artist/42", body: reply([
                "id": 42, "artistName": "Kept", "foreignArtistId": keptMBID, "path": "/music/library/Find",
                "rootFolderPath": "/music/library", "monitored": true, "tags": [Int]()]))
            t.stub(pathSuffix: "/api/v1/artist/43", body: reply([
                "id": 43, "artistName": "Find", "foreignArtistId": findMBID, "path": "/music/samples/Find2",
                "rootFolderPath": "/music/samples", "monitored": true, "tags": [2]]))
            t.stub(pathSuffix: "/api/v1/artist/7", body: reply([
                "id": 7, "artistName": "Owner", "path": "/music/library/Owner", "rootFolderPath": "/music/library",
                "monitored": true, "tags": [Int]()]))
            func file(_ id: Int, artist: Int, album: Int, path: String, quality: String, size: Int) {
                t.stub(pathSuffix: "/api/v1/trackfile/\(id)", body: reply([
                    "id": id, "artistId": artist, "albumId": album, "path": path, "size": size,
                    "quality": ["quality": ["name": quality]]]))
            }
            file(20, artist: 42, album: 50, path: "/music/library/Find/Album/01.mp3", quality: "MP3-320", size: 1000)
            file(21, artist: 42, album: 50, path: "/music/library/Find/Album/01.flac", quality: "FLAC", size: 1000)
            file(22, artist: 42, album: 50, path: "/music/library/Find/Album/02.mp3", quality: "MP3-320", size: 1000)
            file(23, artist: 42, album: 50, path: "/music/library/Find/album/01.MP3", quality: "MP3-320", size: 1200)
            file(24, artist: 42, album: 50, path: "/music/library/Find/Album/01.mp3", quality: "MP3-320", size: 1000)
            file(25, artist: 42, album: 50, path: "/music/library/Find/Album/01.mp3", quality: "Unknown", size: 1000)
            file(26, artist: 42, album: 50, path: "/music/library/Find/ALBUM/01.mp3", quality: "MP3-VBR-V0", size: 1000)
            // Pre-move: the stale record at the Finds path (Lidarr 3.2 leaves it until a rescan).
            file(10, artist: 42, album: 50, path: "/music/samples/Find/Album/01.mp3", quality: "MP3-320", size: 1000)
            file(30, artist: 43, album: 60, path: "/music/samples/Find2/Album/01.mp3", quality: "MP3-320", size: 500)
            file(9, artist: 7, album: 31, path: "/music/library/Owner/Album/01.mp3", quality: "MP3-320", size: 1000)
            t.stub(pathSuffix: "/api/v1/track", body: reply([
                ["id": 1, "albumId": 50, "trackFileId": 20, "foreignTrackId": "ft-1", "foreignRecordingId": "r-1"],
                ["id": 2, "albumId": 50, "trackFileId": 23, "foreignTrackId": "ft-1", "foreignRecordingId": "r-1"],
                ["id": 3, "albumId": 50, "trackFileId": 24, "foreignTrackId": "ft-2", "foreignRecordingId": "r-2"],
                ["id": 4, "albumId": 50, "trackFileId": 26, "foreignTrackId": "ft-1", "foreignRecordingId": "r-1"],
                ["id": 5, "albumId": 50, "trackFileId": 25, "foreignTrackId": "ft-1", "foreignRecordingId": "r-1"],
            ]))
            for m in ["POST", "PUT", "DELETE"] { t.stub(method: m, pathSuffix: "", body: json(#"{"id":1}"#)) }
        }

        func gate() async -> LidarrWriteGate {
            let confinement = WriteConfinement(ledger: ledger, roots: {
                WriteConfinement.Roots(mainRoot: "/music/library", findsRoot: "/music/samples", findTagId: 2)
            })
            let gate = LidarrWriteGate(client: client, logURL: env.logURL, defaultsSuite: env.defaults, confinement: confinement)
            await gate.setEnabled(true)
            return gate
        }

        var writes: [URLRequest] { transport.requests.filter { ($0.httpMethod ?? "GET") != "GET" } }
    }

    static func refused(_ gate: LidarrWriteGate, _ method: String, _ path: String, _ body: String? = nil) async -> Bool {
        do {
            _ = try await gate.send(method, path, body: body.map { try! JSONDecoder().decode(JSONValue.self, from: json($0)) })
            return false
        } catch WriteGateError.forbidden {
            return true
        } catch {
            Issue.record("unexpected \(error)")
            return false
        }
    }

    @Test func theRecordedMP3OfAConfirmedKeepIsDeleted() async throws {
        let fake = try await Fake()
        let gate = await fake.gate()
        _ = try await gate.send("DELETE", "trackfile/20", body: nil)
        _ = try await gate.send("DELETE", "trackfile/bulk", body: try JSONDecoder().decode(JSONValue.self, from: json(#"{"trackFileIds":[20]}"#)))
        #expect(fake.writes.count == 2)
    }

    /// M3: the path compare ignores case (a case-insensitive volume, Lidarr re-casing a folder).
    @Test func thePathCompareIsLoose() async throws {
        let fake = try await Fake()
        _ = try await (await fake.gate()).send("DELETE", "trackfile/26", body: nil)
        #expect(fake.writes.count == 1)
    }

    @Test(arguments: [
        (21, "a FLAC (lossless)"),
        (25, "an unknown quality (M2)"),
        (22, "a path that wasn't recorded"),
        (23, "a changed size (Lidarr rewrote the tags)"),
        (24, "a re-imported file at the same path for another track"),
        (10, "a stale, pre-move id outside the artist folder"),
        (9, "the owner's file"),
    ])
    func refuses(_ id: Int, _ why: String) async throws {
        let fake = try await Fake()
        #expect(await Self.refused(await fake.gate(), "DELETE", "trackfile/\(id)"), "\(why)")
        #expect(fake.writes.isEmpty)
    }

    @Test func refusesWhenNotKeptOrOnlyKeeping() async throws {
        for (kept, intent) in [(false, false), (false, true), (true, true)] {
            let fake = try await Fake(kept: kept, intent: intent)
            #expect(await Self.refused(await fake.gate(), "DELETE", "trackfile/20"), "kept \(kept) intent \(intent)")
            #expect(fake.writes.isEmpty)
        }
    }

    @Test func refusesWithoutARecordOrTrack() async throws {
        let noTrack = try await Fake(recorded: [FindFile(id: 10, albumId: 50, foreignTrackId: nil, relativePath: "Album/01.mp3",
                                                         size: 1000, quality: "MP3-320")])
        #expect(await Self.refused(await noTrack.gate(), "DELETE", "trackfile/20"))
        let none = try await Fake(recorded: [])
        #expect(await Self.refused(await none.gate(), "DELETE", "trackfile/20"))
    }

    /// C4: one rule per call. A find's file (artist 43, in the Finds folder) and a kept MP3 together refuse.
    @Test func aMixedBulkRefuses() async throws {
        let fake = try await Fake()
        #expect(await Self.refused(await fake.gate(), "DELETE", "trackfile/bulk", #"{"trackFileIds":[30,20]}"#))
        #expect(await Self.refused(await fake.gate(), "DELETE", "trackfile/bulk", #"{"trackFileIds":[20,30]}"#))
        #expect(fake.writes.isEmpty)
    }

    /// C4 race (critic test 2): a kept-MP3 delete whose Keep stops being confirmed (an intent appears) between the
    /// checks and the send is refused by its own last-moment check.
    @Test func aKeepUnderWayDuringTheChecksRefusesTheMP3Delete() async throws {
        let fake = try await Fake(hold: ("GET", "/api/v1/track"))
        let gate = await fake.gate()
        let send = Task { await Self.refused(gate, "DELETE", "trackfile/20") }
        await fake.latch.waitArrived()
        try await fake.ledger.update(artistId: 42) { $0.keepIntentAt = Date() }
        await fake.latch.release()
        #expect(await send.value)
        #expect(fake.writes.isEmpty)
    }

    /// The other way round: a find's file delete whose artist gets a Keep intent meanwhile is refused (C5).
    @Test func aKeepIntentDuringAFindDeleteRefusesIt() async throws {
        let fake = try await Fake(hold: ("GET", "/api/v1/trackfile/30"))
        let gate = await fake.gate()
        let send = Task { await Self.refused(gate, "DELETE", "trackfile/30") }
        await fake.latch.waitArrived()
        try await fake.ledger.update(artistId: 43) { $0.keepIntentAt = Date() }
        await fake.latch.release()
        #expect(await send.value)
        #expect(fake.writes.isEmpty)
    }

    /// C5 (critic test 1): with only an intent (no keptAt), every refusing reader in the gate refuses: a find's file
    /// delete, the artist delete and the album unmonitor.
    @Test func everyGateReaderRefusesOnAnIntent() async throws {
        let fake = try await Fake()
        try await fake.ledger.update(artistId: 43) { $0.keepIntentAt = Date() }
        let gate = await fake.gate()
        #expect(await Self.refused(gate, "DELETE", "trackfile/30"))
        #expect(await Self.refused(gate, "DELETE", "artist/43?deleteFiles=false&addImportListExclusion=false"))
        #expect(await Self.refused(gate, "PUT", "album/monitor", #"{"albumIds":[60],"monitored":false}"#))
        #expect(fake.writes.isEmpty)
        // Without the intent the same find's file delete goes.
        try await fake.ledger.update(artistId: 43) { $0.keepIntentAt = nil }
        _ = try await gate.send("DELETE", "trackfile/30", body: nil)
        #expect(fake.writes.count == 1)
    }

    @Test func lossyQualities() {
        for q in ["MP3-320", "MP3-VBR-V0", "AAC-256", "OGG Vorbis Q8", "WMA"] { #expect(WriteConfinement.isLossy(q)) }
        for q in ["FLAC", "FLAC 24bit", "ALAC", "WAV", "APE", "WavPack", "Unknown", "", "mp3"] {
            #expect(!WriteConfinement.isLossy(q))
        }
        #expect(!WriteConfinement.isLossy(nil))
    }

    /// I10: the ledger's artist update is one save for all of the artist's entries.
    @Test func ledgerUpdateChangesEveryEntryOfTheArtistAtOnce() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "magpie-ledger-\(UUID().uuidString)")
        let ledger = Ledger(fileURL: dir.appending(path: "ledger.json"), instance: "x")
        for album in [1, 2] {
            try await ledger.record(LedgerEntry(lidarrArtistId: 5, albumId: album, rgMbid: MBID("00000000-0000-0000-0000-00000000000\(album)")!,
                                                createdArtist: true, wasMonitoredBefore: false, root: "/r", mode: .finds))
        }
        let at = Date(timeIntervalSince1970: 1_900_000_000)
        let n = try await ledger.update(artistId: 5) { $0.keptAt = at; $0.keepIntentAt = nil }
        #expect(n == 2)
        #expect(try await Ledger(fileURL: dir.appending(path: "ledger.json"), instance: "x").entries.allSatisfy { $0.keptAt == at })
        #expect(try await ledger.update(artistId: 5) { $0.keptAt = at } == 0)
    }

    @Test func ledgerDecodesPreY5Entries() throws {
        let old = #"[{"lidarrArtistId":1,"albumId":2,"rgMbid":"00000000-0000-0000-0000-000000000002","createdArtist":true,"wasMonitoredBefore":false,"root":"/r","mode":"finds","keptAt":1.0,"send":"applied"}]"#
        let entries = try JSONDecoder().decode([LedgerEntry].self, from: json(old))
        #expect(entries[0].keepIntentAt == nil && entries[0].findFiles == nil && entries[0].isConfirmedKept)
        #expect(entries[0].isKeptOrKeeping)
    }

    @Test func httpDateParses() {
        let d = LidarrClient.httpDate("Mon, 02 Nov 2026 17:37:00 GMT")
        #expect(d == ISO8601DateFormatter().date(from: "2026-11-02T17:37:00Z"))
        #expect(LidarrClient.httpDate("yesterday") == nil)
    }
}
