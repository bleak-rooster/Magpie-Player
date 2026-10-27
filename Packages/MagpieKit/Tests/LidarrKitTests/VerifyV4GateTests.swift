import Foundation
import os
import Testing
import MagpieCore
import MagpieTestSupport
@testable import LidarrKit

/// Verify V4 (docs/FLOWS.md §3j): each "never" of the safety layers tried directly against the gate, for the
/// cases the earlier suites didn't reach. Every test sends the forbidden thing itself and shows nothing left.
@Suite struct VerifyV4GateTests {
    typealias Call = WriteGateTests.Call

    /// §3j never-call list: `system`, import lists and `wanted/missing` (the existing list covers config, root
    /// folders, indexers, download clients, notifications, import list exclusions, profiles, `/missing`).
    /// Also profile changes through POST with an id, flags hidden deeper in an allowed body, and commands
    /// outside the four allowed.
    static let neverCalls: [Call] = [
        Call("POST", "system/shutdown"),
        Call("POST", "system/restart"),
        Call("POST", "/api/v1/System/Restart/"),
        Call("POST", "/api/v1/system%2Fshutdown"),
        Call("PUT", "system/1", #"{"x":1}"#),
        Call("POST", "system/backup/restore/1"),
        Call("DELETE", "system/backup/1"),
        Call("POST", "importlist", #"{"name":"x"}"#),
        Call("PUT", "importlist/1", #"{"id":1}"#),
        Call("DELETE", "importlist/1"),
        Call("POST", "importlist/action/x"),
        Call("DELETE", "ImportList/1"),
        Call("DELETE", "wanted/missing"),
        Call("POST", "wanted/missing/1"),
        Call("POST", "qualityprofile/5", #"{"name":"x"}"#),
        Call("POST", "metadataprofile/5", #"{"name":"x"}"#),
        Call("PUT", "metadataprofile", #"{"id":3}"#),
        Call("POST", "artist", #"{"foreignArtistId":"x","addOptions":{"deep":[{"deleteFiles":true}]}}"#),
        Call("POST", "artist", #"{"foreignArtistId":"x","deleteFiles":"yes"}"#),
        Call("POST", "command", #"{"name":"MissingAlbumSearch"}"#),
        Call("POST", "command", #"{"name":"DeleteLogFiles"}"#),
        Call("POST", "command", #"{"name":"BulkMoveArtist","artistIds":[42]}"#),
        Call("POST", "command", #"{"name":"ApplicationUpdate"}"#),
    ]

    @Test(arguments: neverCalls)
    func neverCallIsRefused(_ call: Call) async throws {
        let env = GateEnv()
        let t = MockTransport()
        for m in ["POST", "PUT", "DELETE"] { t.stub(method: m, pathSuffix: "", body: json("{}")) }
        let (client, _) = makeClient(t)
        let gate = await env.gate(client, enabled: true)
        let body = call.body.map { try! JSONDecoder().decode(JSONValue.self, from: json($0)) }
        await #expect(throws: WriteGateError.self, "\(call.testDescription)") {
            _ = try await gate.send(call.method, call.path, body: body)
        }
        #expect(t.requests.isEmpty)
        #expect(await gate.changeLog().isEmpty)
    }

    /// §3j "Off by default": with the switch off, a confined delete reads nothing and sends nothing (the gate
    /// checks the switch before its confinement reads).
    @Test func switchOffConfinedDeleteTouchesNothing() async throws {
        let fake = try await WriteConfinementTests.Fake()
        let gate = LidarrWriteGate(client: fake.client, logURL: fake.env.logURL, defaultsSuite: fake.env.defaults,
                                   confinement: WriteConfinement(ledger: fake.ledger, roots: {
                                       .init(mainRoot: "/music/library", findsRoot: "/music/samples", findTagId: 2)
                                   }))
        #expect(await gate.enabled == false)
        for call in WriteConfinementTests.findTargets {
            await #expect(throws: WriteGateError.disabled) {
                _ = try await gate.send(call.method, call.path, body: WriteConfinementTests.body(call))
            }
        }
        #expect(fake.transport.requests.isEmpty, "not even a GET while the switch is off")
        #expect(await gate.changeLog().isEmpty)
    }

    /// §3j change log: saved *before* the write is sent. The transport looks at the file when the write
    /// arrives: the entry is there already, with no status yet; afterwards it carries Lidarr's status.
    @Test func changeLogIsOnDiskBeforeTheWriteLeaves() async throws {
        let env = GateEnv()
        let t = MockTransport()
        let seen = OSAllocatedUnfairLock<[ChangeLogEntry]?>(initialState: nil)
        let logURL = env.logURL
        t.stub(method: "POST", pathSuffix: "/api/v1/tag") { _ in
            let onDisk = try? JSONDecoder().decode([ChangeLogEntry].self, from: Data(contentsOf: logURL))
            seen.withLock { $0 = onDisk }
            return MockTransport.Response(status: 201, body: json(#"{"id":4}"#))
        }
        let (client, _) = makeClient(t)
        let gate = await env.gate(client, enabled: true)
        _ = try await gate.send("POST", "tag", body: JSONValue.object(["label": .string("magpie")]))

        let atSend = try #require(seen.withLock { $0 })
        #expect(atSend.count == 1)
        #expect(atSend.first?.method == "POST" && atSend.first?.path == "/api/v1/tag")
        #expect(atSend.first?.status == nil, "logged before the answer")
        #expect(await gate.changeLog().map(\.status) == [201])
    }

    /// §3j change log: at most 5,000 entries; the oldest go first.
    @Test func changeLogKeepsAtMostFiveThousand() async throws {
        let env = GateEnv()
        let old = (0..<LidarrWriteGate.maxLogEntries).map {
            ChangeLogEntry(date: Date(timeIntervalSince1970: TimeInterval($0)), method: "POST", path: "/api/v1/tag",
                           bodySummary: "old-\($0)", status: 201)
        }
        try FileManager.default.createDirectory(at: env.logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(old).write(to: env.logURL)
        let t = MockTransport()
        t.stub(method: "POST", pathSuffix: "/api/v1/tag", body: json(#"{"id":4}"#))
        let (client, _) = makeClient(t)
        let gate = await env.gate(client, enabled: true)
        _ = try await gate.send("POST", "tag", body: JSONValue.object(["label": .string("new")]))

        let log = await gate.changeLog()
        #expect(log.count == 5_000)
        #expect(log.first?.bodySummary == "old-1", "the oldest entry went")
        #expect(log.last?.bodySummary.contains("new") == true)
    }

    /// §3j confinement "anything unreadable is refused": the ledger, the artist or a track file can't be read.
    /// Each confined write is then not sent (`unconfirmed`), and nothing reaches the change log.
    @Test func unreadableLedgerArtistOrTrackFileRefuses() async throws {
        // Ledger unreadable: its path is a folder.
        do {
            let fake = try await WriteConfinementTests.Fake()
            let dir = FileManager.default.temporaryDirectory.appending(path: "magpie-v4-ledger-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let ledger = Ledger(fileURL: dir, instance: fake.client.instanceScope)
            let gate = LidarrWriteGate(client: fake.client, logURL: fake.env.logURL, defaultsSuite: fake.env.defaults,
                                       confinement: WriteConfinement(ledger: ledger, roots: {
                                           .init(mainRoot: "/music/library", findsRoot: "/music/samples", findTagId: 2)
                                       }))
            await gate.setEnabled(true)
            for call in WriteConfinementTests.findTargets + [Call("PUT", "album/monitor", #"{"albumIds":[50],"monitored":false}"#)] {
                await #expect(throws: WriteGateError.unconfirmed, "\(call.testDescription)") {
                    _ = try await gate.send(call.method, call.path, body: WriteConfinementTests.body(call))
                }
            }
            #expect(fake.writes.isEmpty)
            #expect(await gate.changeLog().isEmpty)
        }
        // The artist (503) or the track file (503) can't be read.
        for (suffix, call) in [("/api/v1/artist/42", Call("DELETE", "artist/42?deleteFiles=false&addImportListExclusion=false")),
                               ("/api/v1/trackfile/10", Call("DELETE", "trackfile/bulk", #"{"trackFileIds":[10]}"#))] {
            let fake = try await WriteConfinementTests.Fake()
            // The mock matches the first stub: a plain transport with the failing read first, then the fake's.
            let t = MockTransport()
            t.stub(pathSuffix: suffix, status: 503)
            let client = LidarrClient(base: testBase, apiKey: testKey, transport: ForwardTransport(first: t, then: fake.transport))
            let gate = LidarrWriteGate(client: client, logURL: fake.env.logURL, defaultsSuite: fake.env.defaults,
                                       confinement: WriteConfinement(ledger: fake.ledger, roots: {
                                           .init(mainRoot: "/music/library", findsRoot: "/music/samples", findTagId: 2)
                                       }))
            await gate.setEnabled(true)
            await #expect(throws: WriteGateError.unconfirmed, "\(call.testDescription)") {
                _ = try await gate.send(call.method, call.path, body: WriteConfinementTests.body(call))
            }
            #expect(fake.writes.isEmpty && t.requests.allSatisfy { $0.httpMethod == "GET" })
            #expect(await gate.changeLog().isEmpty)
        }
    }

    /// §3j allow list: `DELETE artist/{id}` only with both flags explicitly false, and only for a find Magpie
    /// created that is now empty of kept state. The owner's artist with the right flags is still refused.
    @Test func artistDeleteNeedsBothFlagsAndTheLedger() async throws {
        let fake = try await WriteConfinementTests.Fake()
        let gate = await fake.gate()
        for call in [Call("DELETE", "artist/42"),
                     Call("DELETE", "artist/42?deleteFiles=false"),
                     Call("DELETE", "artist/42?addImportListExclusion=false"),
                     Call("DELETE", "artist/42?deleteFiles=true&addImportListExclusion=false"),
                     Call("DELETE", "artist/42?deleteFiles=false&addImportListExclusion=true"),
                     Call("DELETE", "artist/7?deleteFiles=false&addImportListExclusion=false")] {
            await WriteConfinementTests.expectRefused(call, gate, fake)
        }
        _ = try await gate.send("DELETE", "artist/42?deleteFiles=false&addImportListExclusion=false", body: nil)
        #expect(fake.writes.count == 1)
    }

    // MARK: - PathGuard (§3g setup, §3j)

    /// G2 on fresh roots is byte-exact: a Finds root saved with another case, or another Unicode spelling, than
    /// Lidarr reports is no longer a confirmed root, so deletes and moves stop.
    @Test func findsRootStillValidIsByteExact() {
        let roots = ["/music/library", "/music/samples", "/music/Fund\u{E9}"]
        #expect(PathGuard.findsRootStillValid("/music/samples", main: "/music/library", roots: roots))
        #expect(PathGuard.findsRootStillValid("/music/samples/", main: "/music/library", roots: roots))
        #expect(!PathGuard.findsRootStillValid("/music/Samples", main: "/music/library", roots: roots))
        #expect(PathGuard.findsRootStillValid("/music/Fund\u{E9}", main: "/music/library", roots: roots))
        #expect(!PathGuard.findsRootStillValid("/music/Funde\u{301}", main: "/music/library", roots: roots))
        // Gone from Lidarr, now nested, equal to the main root, or `/`: refused.
        #expect(!PathGuard.findsRootStillValid("/music/samples", main: "/music/library", roots: ["/music/library"]))
        #expect(!PathGuard.findsRootStillValid("/music/samples", main: "/music/library",
                                               roots: roots + ["/music/samples/inner"]))
        #expect(!PathGuard.findsRootStillValid("/music/samples", main: "/music/samples", roots: roots))
        #expect(!PathGuard.findsRootStillValid("/", main: "/music/library", roots: roots + ["/"]))
    }

    /// The case-sensitive guard the gate builds: a path that differs from the root only in case, or climbs out
    /// with `..`, is never inside.
    @Test func gateGuardRefusesCaseAndDotDot() {
        let guardian = PathGuard(findsRoot: "/music/samples", otherRoots: ["/music/library"], caseInsensitive: false)
        #expect(guardian.isInside("/music/samples/Find/01.mp3"))
        #expect(!guardian.isInside("/music/Samples/Find/01.mp3"))
        #expect(!guardian.isInside("/music/samples/Find/../../library/Owner/01.flac"))
        #expect(!guardian.isInside("/music/samples/../library/Owner"))
        #expect(!guardian.isInside("/music/samples"))
        #expect(PathGuard.validateRoot("/", others: ["/music/library"]) == .nested)
    }
}

/// Answers from `first` when it has a stub for the request, else from `then` (both record what they see).
struct ForwardTransport: HTTPTransport {
    let first: MockTransport
    let then: MockTransport

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await first.send(request)
        if response.statusCode != 404 { return (data, response) }
        return try await then.send(request)
    }
}
