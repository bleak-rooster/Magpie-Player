import Foundation
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
@Suite struct WriteConfinementTests {
    typealias Call = WriteGateTests.Call

    struct Fake {
        let env = GateEnv()
        let transport = MockTransport()
        let client: LidarrClient
        let ledger: Ledger
        var roots = ["/music/library", "/music/samples"]

        init(roots: [String] = ["/music/library", "/music/samples"], ledgerInstance: String? = nil,
             findTags: [Int] = [2], findPath: String = "/music/samples/Find", kept: Bool = false,
             rootsDown: Bool = false) async throws {
            client = LidarrClient(base: testBase, apiKey: testKey, transport: transport)
            ledger = Ledger(fileURL: nil, instance: ledgerInstance ?? client.instanceScope)
            try await ledger.record(LedgerEntry(lidarrArtistId: 7, albumId: 31, rgMbid: MBID("00000000-0000-0000-0000-000000000031")!,
                                                createdArtist: false, wasMonitoredBefore: false, root: "/music/library",
                                                mode: .fallback, send: .applied))
            try await ledger.record(LedgerEntry(lidarrArtistId: 42, albumId: 50, rgMbid: MBID("00000000-0000-0000-0000-000000000050")!,
                                                createdArtist: true, wasMonitoredBefore: false, root: "/music/samples",
                                                mode: .finds, keptAt: kept ? Date() : nil, send: .applied))
            let t = transport
            func reply(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object) }
            t.stub(pathSuffix: "/api/v1/rootfolder", status: rootsDown ? 503 : 200,
                   body: reply(roots.enumerated().map { ["id": $0.offset + 1, "path": $0.element] }))
            t.stub(pathSuffix: "/api/v1/artist/7", body: reply([
                "id": 7, "artistName": "Owner", "path": "/music/library/Owner", "rootFolderPath": "/music/library",
                "monitored": true, "tags": [Int]()]))
            t.stub(pathSuffix: "/api/v1/artist/42", body: reply([
                "id": 42, "artistName": "Find", "path": findPath, "rootFolderPath": "/music/samples",
                "monitored": true, "tags": findTags]))
            t.stub(pathSuffix: "/api/v1/artist/99", status: 404)
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
        Call("PUT", "artist/editor", #"{"artistIds":[42],"metadataProfileId":3}"#),
        Call("PUT", "artist/editor", #"{"artistIds":[42],"tags":[2]}"#),
        Call("PUT", "artist/editor", #"{"artistIds":[42],"moveFiles":true}"#),
        Call("PUT", "artist/editor", #"{"artistIds":[42],"rootFolderPath":"/music/library","moveFiles":1}"#),
        Call("PUT", "artist/editor", #"{"artistIds":[42],"rootFolderPath":7}"#),
        Call("PUT", "artist/editor", #"{"artistIds":[42],"monitorNewItems":"new","qualityProfileId":4}"#),
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
}
