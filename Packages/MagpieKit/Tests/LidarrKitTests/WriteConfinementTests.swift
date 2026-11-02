import Foundation
import os
import Testing
import MagpieCore
import MagpieTestSupport
@testable import LidarrKit

/// Security FM1: the gate confines destructive writes itself, from the ledger and its own fresh Lidarr reads, so a
/// bug in the runner (wrong ids, a stale record, a wider body) can't delete, move or change an owner's artist.
///
/// The fake Lidarr: roots `/music/library` (main) and `/music/samples` (Finds). Artist 7 is the owner's (ledger:
/// an existing-artist request, not created), artist 42 is a find Magpie created (tagged `magpie-find` 2, in the
/// Finds root). Track file 9 is the owner's, 10 the find's, 11 recorded for the find but outside the Finds root.
/// The MBID of the find Magpie created (artist 42).
private let findMBID = "42424242-4242-4242-8242-424242424242"

@Suite struct WriteConfinementTests {
    typealias Call = WriteGateTests.Call

    struct Fake {
        let env = GateEnv()
        let transport = MockTransport()
        /// Holds the first request matching `holdSuffix` (method `holdMethod`) until `latch` is released.
        let latch = GateLatch()
        let client: LidarrClient
        let ledger: Ledger
        var roots = ["/music/library", "/music/samples"]

        init(roots: [String] = ["/music/library", "/music/samples"], ledgerInstance: String? = nil,
             findTags: [Int] = [2], findPath: String = "/music/samples/Find", kept: Bool = false,
             rootsDown: Bool = false, hold: (method: String, suffix: String)? = nil,
             findArtistMBID: String = findMBID, mainFolders: [String] = ["Owner"],
             lookupFolder: String? = "Find", movePreflightDown: Bool = false) async throws {
            client = LidarrClient(base: testBase, apiKey: testKey,
                                  transport: HoldTransport(inner: transport, hold: hold, latch: latch))
            ledger = Ledger(fileURL: nil, instance: ledgerInstance ?? client.instanceScope)
            try await ledger.record(LedgerEntry(lidarrArtistId: 7, albumId: 31, rgMbid: MBID("00000000-0000-0000-0000-000000000031")!,
                                                createdArtist: false, wasMonitoredBefore: false, root: "/music/library",
                                                mode: .fallback, send: .applied))
            try await ledger.record(LedgerEntry(lidarrArtistId: 42, albumId: 50, rgMbid: MBID("00000000-0000-0000-0000-000000000050")!,
                                                createdArtist: true, wasMonitoredBefore: false, root: "/music/samples",
                                                mode: .finds, keptAt: kept ? Date() : nil, send: .applied,
                                                artistMbid: MBID(findMBID)))
            // Album 32: the owner's own, monitored before Magpie's Try came along (G6: never unmonitored).
            try await ledger.record(LedgerEntry(lidarrArtistId: 7, albumId: 32, rgMbid: MBID("00000000-0000-0000-0000-000000000032")!,
                                                createdArtist: false, wasMonitoredBefore: true, root: "/music/library",
                                                mode: .fallback, send: .applied))
            let t = transport
            func reply(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object) }
            t.stub(pathSuffix: "/api/v1/rootfolder", status: rootsDown ? 503 : 200,
                   body: reply(roots.enumerated().map { ["id": $0.offset + 1, "path": $0.element] }))
            t.stub(pathSuffix: "/api/v1/artist/7", body: reply([
                "id": 7, "artistName": "Owner", "path": "/music/library/Owner", "rootFolderPath": "/music/library",
                "monitored": true, "tags": [Int]()]))
            t.stub(pathSuffix: "/api/v1/artist/42", body: reply([
                "id": 42, "artistName": "Find", "foreignArtistId": findArtistMBID, "path": findPath,
                "rootFolderPath": "/music/samples", "monitored": true, "tags": findTags]))
            t.stub(pathSuffix: "/api/v1/artist/99", status: 404)
            // Round 12 M4: the move's destination check reads Lidarr's folder name and the main root's folders.
            var lookupRow: [String: Any] = ["artistName": "Find", "foreignArtistId": findArtistMBID]
            if let lookupFolder { lookupRow["folder"] = lookupFolder }
            t.stub(pathSuffix: "/api/v1/artist/lookup", status: movePreflightDown ? 503 : 200, body: reply([lookupRow]))
            t.stub(pathSuffix: "/api/v1/filesystem", status: movePreflightDown ? 503 : 200, body: reply([
                "parent": "/music/", "files": [Any](),
                "directories": mainFolders.map { ["path": "/music/library/\($0)/", "name": $0] }]))
            t.stub(pathSuffix: "/api/v1/trackfile/9", body: reply([
                "id": 9, "artistId": 7, "albumId": 31, "path": "/music/library/Owner/Album/01.flac"]))
            t.stub(pathSuffix: "/api/v1/trackfile/10", body: reply([
                "id": 10, "artistId": 42, "albumId": 50, "path": "/music/samples/Find/Album/01.mp3"]))
            t.stub(pathSuffix: "/api/v1/trackfile/11", body: reply([
                "id": 11, "artistId": 42, "albumId": 50, "path": "/music/library/Owner/Album/02.flac"]))
            t.stub(pathSuffix: "/api/v1/trackfile/12", body: reply([
                "id": 12, "albumId": 50, "path": "/music/samples/Find/Album/02.mp3"]))
            for m in ["POST", "PUT", "DELETE"] { t.stub(method: m, pathSuffix: "", body: json(#"{"id":1}"#)) }
        }

        func gate(confined: Bool = true, mainRoot: String? = "/music/library",
                  findsRoot: String? = "/music/samples", findTagId: Int? = 2) async -> LidarrWriteGate {
            let confinement = confined ? WriteConfinement(ledger: ledger, roots: {
                WriteConfinement.Roots(mainRoot: mainRoot, findsRoot: findsRoot, findTagId: findTagId)
            }) : nil
            let gate = LidarrWriteGate(client: client, logURL: env.logURL, defaultsSuite: env.defaults,
                                       confinement: confinement)
            await gate.setEnabled(true)
            return gate
        }

        var writes: [URLRequest] { transport.requests.filter { ($0.httpMethod ?? "GET") != "GET" } }
    }

    static func body(_ call: Call) -> JSONValue? {
        call.body.map { try! JSONDecoder().decode(JSONValue.self, from: json($0)) }
    }

    /// Sends `call` and expects the gate to refuse it before anything is written.
    static func expectRefused(_ call: Call, _ gate: LidarrWriteGate, _ fake: Fake,
                              sourceLocation: SourceLocation = #_sourceLocation) async {
        do {
            _ = try await gate.send(call.method, call.path, body: body(call))
            Issue.record("sent \(call.testDescription)", sourceLocation: sourceLocation)
        } catch let error as WriteGateError {
            guard case .forbidden = error else {
                Issue.record("wrong error \(error) for \(call.testDescription)", sourceLocation: sourceLocation)
                return
            }
        } catch {
            Issue.record("unexpected \(error)", sourceLocation: sourceLocation)
        }
        #expect(fake.writes.isEmpty, "nothing written for \(call.testDescription)", sourceLocation: sourceLocation)
        #expect(await gate.changeLog().isEmpty, sourceLocation: sourceLocation)
    }

    /// Each destructive shape aimed at the owner's artist 7 (or its file 9) is refused at the gate, even though the
    /// shape itself is one the runner sends.
    static let ownerTargets: [Call] = [
        Call("DELETE", "artist/7?deleteFiles=false&addImportListExclusion=false"),
        Call("DELETE", "trackfile/9"),
        Call("DELETE", "trackfile/bulk", #"{"trackFileIds":[9]}"#),
        Call("DELETE", "trackfile/bulk", #"{"trackFileIds":[10,9]}"#),
        Call("PUT", "artist/editor", #"{"artistIds":[7],"rootFolderPath":"/music/library","moveFiles":true,"qualityProfileId":9,"tags":[2],"applyTags":"remove"}"#),
        Call("PUT", "artist/editor", #"{"artistIds":[7],"rootFolderPath":"/music/samples","moveFiles":false}"#),
        Call("PUT", "artist/editor", #"{"artistIds":[7],"tags":[2],"applyTags":"add"}"#),
        Call("PUT", "artist/editor", #"{"artistIds":[7],"qualityProfileId":9}"#),
        Call("PUT", "artist/editor", #"{"artistIds":[7],"monitorNewItems":"new"}"#),
        // P3 "Monitor" is only for an artist Magpie added.
        Call("PUT", "artist/editor", #"{"artistIds":[7],"monitored":true}"#),
        // An artist the ledger doesn't know at all.
        Call("DELETE", "artist/99?deleteFiles=false&addImportListExclusion=false"),
        Call("PUT", "artist/editor", #"{"artistIds":[99],"tags":[2],"applyTags":"remove"}"#),
    ]

    @Test(arguments: ownerTargets)
    func ownerArtistIsRefused(_ call: Call) async throws {
        let fake = try await Fake()
        await Self.expectRefused(call, await fake.gate(), fake)
    }

    /// The same shapes for Magpie's own find go through.
    static let findTargets: [Call] = [
        Call("DELETE", "artist/42?deleteFiles=false&addImportListExclusion=false"),
        Call("DELETE", "trackfile/10"),
        Call("DELETE", "trackfile/bulk", #"{"trackFileIds":[10]}"#),
        Call("PUT", "artist/editor", #"{"artistIds":[42],"rootFolderPath":"/music/library","moveFiles":true,"qualityProfileId":9,"tags":[2],"applyTags":"remove"}"#),
        Call("PUT", "artist/editor", #"{"artistIds":[42],"rootFolderPath":"/music/samples","moveFiles":false}"#),
        Call("PUT", "artist/editor", #"{"artistIds":[42],"tags":[2],"applyTags":"remove"}"#),
        Call("PUT", "artist/editor", #"{"artistIds":[42],"monitorNewItems":"new"}"#),
        // P3 "Monitor": an unmonitored artist Magpie added.
        Call("PUT", "artist/editor", #"{"artistIds":[42],"monitored":true}"#),
        // Case, prefix and `//` variants.
        Call("PUT", "//API//V1//Artist//Editor//", #"{"artistIds":[42],"tags":[2],"applyTags":"remove"}"#),
        Call("PUT", "artist/editor", #"{"ArtistIds":[42],"MonitorNewItems":"New"}"#),
        Call("DELETE", "artist/42?AddImportListExclusion=FALSE&deleteFiles=False"),
        Call("DELETE", "/API/V1/TrackFile/10/"),
        Call("DELETE", "/api/v1/TrackFile/Bulk", #"{"trackFileIds":[10]}"#),
    ]

    @Test(arguments: findTargets)
    func findArtistIsSent(_ call: Call) async throws {
        let fake = try await Fake()
        let gate = await fake.gate()
        _ = try await gate.send(call.method, call.path, body: Self.body(call))
        #expect(fake.writes.count == 1)
        #expect(fake.writes.first?.httpMethod == call.method)
    }

    /// Moves go only to the current main root (moveFiles) or back to the current Finds root (a point-back that
    /// moves nothing). Anything else is refused, for a find too.
    static let badMoves: [Call] = [
        Call("PUT", "artist/editor", #"{"artistIds":[42],"rootFolderPath":"/music/other","moveFiles":true}"#),
        Call("PUT", "artist/editor", #"{"artistIds":[42],"rootFolderPath":"/music/samples","moveFiles":true}"#),
        Call("PUT", "artist/editor", #"{"artistIds":[42],"rootFolderPath":"/music/library/sub","moveFiles":true}"#),
        Call("PUT", "artist/editor", #"{"artistIds":[42],"rootFolderPath":"/music/library","moveFiles":false}"#),
        Call("PUT", "artist/editor", #"{"artistIds":[42],"rootFolderPath":"/music/library"}"#),
        Call("PUT", "artist/editor", #"{"artistIds":[42],"rootFolderPath":"/music/Samples","moveFiles":false}"#),
    ]

    @Test(arguments: badMoves)
    func movesOnlyToTheConfiguredRoots(_ call: Call) async throws {
        let fake = try await Fake()
        await Self.expectRefused(call, await fake.gate(), fake)
    }

    /// Editor bodies are refused on shape alone: more than one artist, or any field Keep and Bring in more never
    /// send (monitoring, the metadata profile), or tags without `applyTags`, or `moveFiles` without a root.
    static let badEditorShapes: [Call] = [
        Call("PUT", "artist/editor", #"{"artistIds":[42,7],"tags":[2],"applyTags":"remove"}"#),
        Call("PUT", "artist/editor", #"{"artistIds":[],"tags":[2],"applyTags":"remove"}"#),
        Call("PUT", "artist/editor", #"{"artistIds":[42],"monitored":false}"#),
        Call("PUT", "artist/editor", #"{"artistIds":[42],"metadataProfileId":3,"qualityProfileId":4}"#),
        Call("PUT", "artist/editor", #"{"artistIds":[42],"tags":[2]}"#),
        Call("PUT", "artist/editor", #"{"artistIds":[42],"moveFiles":true}"#),
        Call("PUT", "artist/editor", #"{"artistIds":[42],"rootFolderPath":"/music/library","moveFiles":1}"#),
        Call("PUT", "artist/editor", #"{"artistIds":[42],"rootFolderPath":7}"#),
        Call("PUT", "artist/editor", #"{"artistIds":[42],"monitorNewItems":"new","qualityProfileId":4}"#),
        // P3: monitoring is exactly {artistIds: [one], monitored: true}, never mixed with anything else.
        Call("PUT", "artist/editor", #"{"artistIds":[42],"monitored":true,"tags":[2],"applyTags":"add"}"#),
        Call("PUT", "artist/editor", #"{"artistIds":[42],"monitored":true,"rootFolderPath":"/music/library","moveFiles":true}"#),
        Call("PUT", "artist/editor", #"{"artistIds":[42],"monitored":"true"}"#),
        Call("PUT", "artist/editor", #"{"artistIds":[42],"monitored":1}"#),
        Call("PUT", "artist/editor", #"{"artistIds":[42],"monitored":true,"Monitored":false}"#),
    ]

    @Test(arguments: badEditorShapes)
    func editorShapeIsRefused(_ call: Call) async throws {
        let fake = try await Fake()
        await Self.expectRefused(call, await fake.gate(), fake)
    }

    /// A find's file recorded outside the Finds root, or a file Lidarr doesn't tie to an artist, is never deleted;
    /// one bad id refuses the whole bulk delete.
    @Test func findFilesOutsideTheFindsRootAreRefused() async throws {
        let fake = try await Fake()
        let gate = await fake.gate()
        for call in [Call("DELETE", "trackfile/11"), Call("DELETE", "trackfile/12"),
                     Call("DELETE", "trackfile/bulk", #"{"trackFileIds":[10,11]}"#),
                     Call("DELETE", "trackfile/404")] {
            await Self.expectRefused(call, gate, fake)
        }
    }

    /// The artist has to be a find right now: tagged `magpie-find` and inside the Finds root.
    @Test func artistNoLongerAFindIsRefused() async throws {
        for fake in [try await Fake(findTags: []), try await Fake(findPath: "/music/library/Find")] {
            let gate = await fake.gate()
            for call in [Call("DELETE", "artist/42?deleteFiles=false&addImportListExclusion=false"),
                         Call("DELETE", "trackfile/10"),
                         Call("PUT", "artist/editor", #"{"artistIds":[42],"rootFolderPath":"/music/library","moveFiles":true}"#)] {
                await Self.expectRefused(call, gate, fake)
            }
        }
    }

    /// V-fix: Lidarr reused the id of the artist Magpie created for another artist (another MBID): not Magpie's.
    @Test func reusedArtistIdIsNotMagpies() async throws {
        let fake = try await Fake(findArtistMBID: "11111111-1111-4111-8111-111111111111")
        let gate = await fake.gate()
        for call in [Call("DELETE", "artist/42?deleteFiles=false&addImportListExclusion=false"),
                     Call("DELETE", "trackfile/10"),
                     Call("PUT", "artist/editor", #"{"artistIds":[42],"rootFolderPath":"/music/library","moveFiles":true}"#),
                     Call("PUT", "artist/editor", #"{"artistIds":[42],"monitorNewItems":"new"}"#)] {
            await Self.expectRefused(call, gate, fake)
        }
        #expect(fake.writes.isEmpty)
    }

    /// Kept (G3.4): nothing of a kept artist is deleted. The editor may still put it back (Keep's restore).
    @Test func keptArtistIsNeverDeleted() async throws {
        let fake = try await Fake(kept: true)
        let gate = await fake.gate()
        await Self.expectRefused(Call("DELETE", "artist/42?deleteFiles=false&addImportListExclusion=false"), gate, fake)
        await Self.expectRefused(Call("DELETE", "trackfile/bulk", #"{"trackFileIds":[10]}"#), gate, fake)
        _ = try await gate.send("PUT", "artist/editor", body: Self.body(Call("PUT", "artist/editor",
            #"{"artistIds":[42],"rootFolderPath":"/music/samples","moveFiles":false,"tags":[2],"applyTags":"add"}"#)))
        #expect(fake.writes.count == 1)
    }

    /// No confinement (no ledger), a ledger of another Lidarr, or a Finds root that is no longer one of Lidarr's
    /// roots: every destructive write is refused. Plain additions still go through.
    @Test func unconfinedGateRefusesDestructiveWrites() async throws {
        let unconfined = try await Fake()
        let otherLedger = try await Fake(ledgerInstance: "another-lidarr")
        for (fake, gate) in [(unconfined, await unconfined.gate(confined: false)), (otherLedger, await otherLedger.gate())] {
            for call in Self.findTargets { await Self.expectRefused(call, gate, fake) }
        }
        // The Finds root is gone from Lidarr: deletes and moves are refused; untagging still isn't a move.
        let rootGone = try await Fake(roots: ["/music/library"])
        let gate = await rootGone.gate()
        for call in Self.findTargets where call.method == "DELETE" || call.body?.contains("rootFolderPath") == true {
            await Self.expectRefused(call, gate, rootGone)
        }
        let open = await unconfined.gate(confined: false)
        _ = try await open.send("POST", "tag", body: JSONValue.object(["label": .string("magpie")]))
        #expect(unconfined.writes.count == 1)
    }

    /// The Finds root and tag have to be set up for any delete or move.
    @Test func missingSetupRefusesDeletesAndMoves() async throws {
        let fake = try await Fake()
        for gate in [await fake.gate(findsRoot: nil), await fake.gate(findTagId: nil), await fake.gate(mainRoot: nil)] {
            for call in [Call("DELETE", "artist/42?deleteFiles=false&addImportListExclusion=false"),
                         Call("DELETE", "trackfile/10"),
                         Call("PUT", "artist/editor", #"{"artistIds":[42],"rootFolderPath":"/music/library","moveFiles":true}"#)] {
                await Self.expectRefused(call, gate, fake)
            }
        }
    }

    /// Lidarr can't be read for the check: nothing is sent and the gate says it couldn't confirm.
    @Test func unreadableLidarrIsUnconfirmed() async throws {
        let fake = try await Fake(rootsDown: true)
        let gate = await fake.gate()
        await #expect(throws: WriteGateError.unconfirmed) {
            _ = try await gate.send("DELETE", "artist/42?deleteFiles=false&addImportListExclusion=false", body: nil)
        }
        #expect(fake.writes.isEmpty)
        #expect(await gate.changeLog().isEmpty)
    }

    // MARK: - H2b fix 1: album monitor, one confined write at a time

    /// `PUT album/monitor` is confined too: monitoring only albums Magpie recorded first (a Try, a Bring in more);
    /// unmonitoring only albums Magpie monitored and nobody kept. The owner's album is never unmonitored.
    @Test func albumMonitorIsConfinedToTheLedger() async throws {
        let fake = try await Fake()
        let gate = await fake.gate()
        for call in [Call("PUT", "album/monitor", #"{"albumIds":[31],"monitored":true}"#),        // Try, existing artist (G6)
                     Call("PUT", "album/monitor", #"{"albumIds":[50,31],"monitored":true}"#),
                     Call("PUT", "album/monitor", #"{"albumIds":[31],"monitored":false}"#),       // Cancel of what Magpie monitored
                     Call("PUT", "album/monitor", #"{"albumIds":[50],"monitored":false}"#)] {     // Not for me
            _ = try await gate.send(call.method, call.path, body: Self.body(call))
        }
        #expect(fake.writes.count == 4)
        let refusedFake = try await Fake()
        let refusing = await refusedFake.gate()
        for call in [Call("PUT", "album/monitor", #"{"albumIds":[32],"monitored":false}"#),       // the owner's album
                     Call("PUT", "album/monitor", #"{"albumIds":[50,32],"monitored":false}"#),
                     Call("PUT", "album/monitor", #"{"albumIds":[99],"monitored":false}"#),
                     Call("PUT", "album/monitor", #"{"albumIds":[99],"monitored":true}"#),        // never recorded
                     Call("PUT", "album/monitor", #"{"albumIds":[50],"monitored":true,"x":1}"#),  // extra key
                     Call("PUT", "album/monitor", #"{"albumIds":[],"monitored":true}"#),
                     Call("PUT", "album/monitor", #"{"albumIds":[50],"monitored":"false"}"#),
                     Call("PUT", "album/monitor", #"{"albumIds":[50]}"#)] {
            await Self.expectRefused(call, refusing, refusedFake)
        }
        let kept = try await Fake(kept: true)
        await Self.expectRefused(Call("PUT", "album/monitor", #"{"albumIds":[50],"monitored":false}"#), await kept.gate(), kept)
        let unconfined = try await Fake()
        await Self.expectRefused(Call("PUT", "album/monitor", #"{"albumIds":[31],"monitored":false}"#),
                                 await unconfined.gate(confined: false), unconfined)
    }

    /// Confined writes go one at a time: while a delete is between its checks and Lidarr's answer, a second confined
    /// write neither reads nor sends anything; it goes after.
    @Test func confinedWritesGoOneAtATime() async throws {
        let fake = try await Fake(hold: ("DELETE", "/api/v1/trackfile/10"))
        let gate = await fake.gate()
        let first = Task { try await gate.send("DELETE", "trackfile/10", body: nil) }
        await fake.latch.waitArrived()
        let seen = fake.transport.requests.count
        let second = Task {
            try await gate.send("PUT", "artist/editor", body: Self.body(Call("PUT", "artist/editor",
                #"{"artistIds":[42],"rootFolderPath":"/music/library","moveFiles":true}"#)))
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(fake.transport.requests.count == seen, "the second write waits, reads included")
        await fake.latch.release()
        _ = try await first.value
        _ = try await second.value
        #expect(fake.writes.map { $0.httpMethod ?? "" } == ["DELETE", "PUT"])
    }

    /// The ledger is read once more right before a delete: an artist kept while the checks ran is not deleted.
    @Test func keptDuringTheChecksIsNotDeleted() async throws {
        let fake = try await Fake(hold: ("GET", "/api/v1/artist/42"))
        let gate = await fake.gate()
        let delete = Task { try await gate.send("DELETE", "artist/42?deleteFiles=false&addImportListExclusion=false", body: nil) }
        await fake.latch.waitArrived()
        for var e in try await fake.ledger.entries where e.lidarrArtistId == 42 {
            e.keptAt = Date()
            try await fake.ledger.record(e)
        }
        await fake.latch.release()
        await #expect(throws: WriteGateError.self) { _ = try await delete.value }
        #expect(fake.writes.isEmpty)
    }
}

/// Holds one request until released, and says when it has arrived.
actor GateLatch {
    private var arrived = false, released = false
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = [], holders: [CheckedContinuation<Void, Never>] = []

    func hold() async {
        arrived = true
        arrivalWaiters.forEach { $0.resume() }
        arrivalWaiters = []
        if released { return }
        await withCheckedContinuation { holders.append($0) }
    }

    func waitArrived() async {
        if arrived { return }
        await withCheckedContinuation { arrivalWaiters.append($0) }
    }

    func release() {
        released = true
        holders.forEach { $0.resume() }
        holders = []
    }
}

/// The mock, except that the first request matching `hold` waits on `latch`.
struct HoldTransport: HTTPTransport {
    let inner: MockTransport
    let hold: (method: String, suffix: String)?
    let latch: GateLatch
    private let used = OSAllocatedUnfairLock(initialState: false)

    init(inner: MockTransport, hold: (method: String, suffix: String)?, latch: GateLatch) {
        self.inner = inner; self.hold = hold; self.latch = latch
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if let hold, (request.httpMethod ?? "GET") == hold.method, request.url?.path.hasSuffix(hold.suffix) == true,
           used.withLock({ let first = !$0; $0 = true; return first }) {
            await latch.hold()
        }
        return try await inner.send(request)
    }
}
