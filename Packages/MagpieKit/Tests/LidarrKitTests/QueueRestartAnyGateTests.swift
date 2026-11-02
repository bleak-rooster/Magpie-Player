import Foundation
import Testing
import MagpieCore
import MagpieTestSupport
@testable import LidarrKit

/// Round 12 item 6 (D49): Settings › Downloads in Lidarr may restart ANY download in Lidarr's queue, not only a Magpie
/// request's. The gate's `queueRestartAny` shape: `DELETE /queue/{id}` with exactly
/// `removeFromClient=true&blocklist=true&skipRedownload=true`, after its own fresh read of the whole queue, refusing a
/// copy that's importing, imported or complete (waiting to import), and any copy whose download is shared with one.
///
/// The queue: 601 (owner's album 41, downloading), 602 (owner's album 42, failed import: importBlocked), 603 (failed
/// download), 604 (importing), 605 (imported), 606 (importPending), 607 (client says completed, Lidarr still tracking
/// it as downloading), 608 + 609 (one download "shared": 608 downloading, 609 importing), 610 (no download id).
@Suite struct QueueRestartAnyGateTests {
    static let shape = "?removeFromClient=true&blocklist=true&skipRedownload=true"

    struct Fake {
        let env = GateEnv()
        let transport = MockTransport()
        let client: LidarrClient
        let ledger: Ledger

        init(queueDown: Bool = false) {
            client = LidarrClient(base: testBase, apiKey: testKey, transport: transport)
            ledger = Ledger(fileURL: nil, instance: client.instanceScope)
            let rows: [[String: Any]] = [
                ["id": 601, "albumId": 41, "artistId": 9, "status": "downloading", "trackedDownloadState": "downloading"],
                ["id": 602, "albumId": 42, "artistId": 9, "sizeleft": 0, "status": "completed",
                 "trackedDownloadState": "importBlocked", "trackedDownloadStatus": "warning"],
                ["id": 603, "albumId": 43, "artistId": 9, "status": "failed", "trackedDownloadState": "downloadFailed",
                 "trackedDownloadStatus": "error"],
                ["id": 604, "albumId": 44, "artistId": 9, "sizeleft": 0, "status": "completed", "trackedDownloadState": "importing"],
                ["id": 605, "albumId": 45, "artistId": 9, "sizeleft": 0, "status": "completed", "trackedDownloadState": "imported"],
                ["id": 606, "albumId": 46, "artistId": 9, "sizeleft": 0, "status": "completed", "trackedDownloadState": "importPending"],
                ["id": 607, "albumId": 47, "artistId": 9, "sizeleft": 0, "status": "completed", "trackedDownloadState": "downloading"],
                ["id": 608, "albumId": 48, "artistId": 9, "status": "downloading", "trackedDownloadState": "downloading",
                 "downloadId": "shared"],
                ["id": 609, "albumId": 49, "artistId": 9, "sizeleft": 0, "status": "completed", "trackedDownloadState": "importing",
                 "downloadId": "shared"],
                ["id": 610, "albumId": 50, "artistId": 9, "status": "failed", "trackedDownloadState": "downloadFailed",
                 "downloadId": NSNull()],
            ].map { row in row.merging(["size": 100, "sizeleft": 50, "downloadClient": "SABnzbd",
                                        "downloadId": "dl-\(row["id"]!)"]) { a, _ in a } }
            let all = try! JSONSerialization.data(withJSONObject: rows)
            transport.stub(pathSuffix: "/api/v1/queue/details") { _ in
                queueDown ? MockTransport.Response(status: 503) : MockTransport.Response(status: 200, body: all)
            }
            transport.stub(method: "DELETE", pathSuffix: "", body: json("{}"))
        }

        func gate(enabled: Bool = true, confined: Bool = true) async -> LidarrWriteGate {
            let confinement = WriteConfinement(
                ledger: ledger, roots: { WriteConfinement.Roots(mainRoot: "/music/library", findsRoot: nil, findTagId: nil) },
                liveRequests: { [] })
            let gate = LidarrWriteGate(client: client, logURL: env.logURL, defaultsSuite: env.defaults,
                                       confinement: confined ? confinement : nil)
            await gate.setEnabled(enabled)
            return gate
        }

        var writes: [URLRequest] { transport.requests.filter { ($0.httpMethod ?? "GET") != "GET" } }
        var queueReads: Int { transport.requests.filter { $0.url?.path.hasSuffix("/queue/details") == true }.count }
    }

    private func restart(_ gate: LidarrWriteGate, _ id: Int, _ query: String = Self.shape) async throws {
        _ = try await gate.send("DELETE", "queue/\(id)" + query, body: nil as JSONValue?, confinedAs: .queueRestartAny)
    }

    private func refused(_ gate: LidarrWriteGate, _ id: Int, _ query: String = Self.shape) async -> String? {
        do {
            try await restart(gate, id, query)
            return nil
        } catch WriteGateError.forbidden(let why) {
            return why
        } catch {
            return "other: \(error)"
        }
    }

    /// The owner's own download (nothing in the ledger, no live request): sent in the exact shape, after one fresh read,
    /// and logged with its query.
    @Test func anyDownloadIsRestarted() async throws {
        let fake = Fake()
        let gate = await fake.gate()
        try await restart(gate, 601)
        let sent = try #require(fake.writes.first)
        #expect(fake.writes.count == 1)
        #expect(sent.httpMethod == "DELETE")
        #expect(sent.url?.path == "/lidarr/api/v1/queue/601")
        let query = URLComponents(url: sent.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(Set(query.map { "\($0.name)=\($0.value ?? "")" })
                == ["removeFromClient=true", "blocklist=true", "skipRedownload=true"])
        #expect(query.count == 3)
        #expect(sent.httpBody == nil)
        #expect(fake.queueReads == 1)
        let log = await gate.changeLog()
        #expect(log.map(\.method) == ["DELETE"])
        #expect(log.first?.path == "/api/v1/queue/601" + Self.shape)
        #expect(log.first?.status == 200)
    }

    /// Failed copies are what the screen is for: an import blocked, a failed download.
    @Test func failedCopiesAreRestarted() async throws {
        let fake = Fake()
        let gate = await fake.gate()
        try await restart(gate, 602)
        try await restart(gate, 603)
        #expect(fake.writes.compactMap(\.url?.path) == ["/lidarr/api/v1/queue/602", "/lidarr/api/v1/queue/603"])
    }

    /// The R17 shape is unchanged: without `confinedAs`, the same request for an owner's download is refused.
    @Test func r17ShapeStillOnlyMagpies() async throws {
        let fake = Fake()
        let gate = await fake.gate()
        await #expect(throws: WriteGateError.self) {
            _ = try await gate.send("DELETE", "queue/601" + Self.shape, body: nil as JSONValue?)
        }
        #expect(fake.writes.isEmpty)
    }

    /// Exactly the one query, each once: anything else is refused before anything is read.
    @Test func onlyTheExactQuery() async throws {
        let fake = Fake()
        let gate = await fake.gate()
        for query in ["", "?removeFromClient=true&blocklist=true", "?removeFromClient=true&blocklist=false&skipRedownload=true",
                      Self.shape + "&changeCategory=true", Self.shape + "&blocklist=true",
                      "?removeFromClient=true&blocklist=true&skipRedownload=false"] {
            #expect(await refused(gate, 601, query) != nil, "\(query)")
        }
        #expect(fake.writes.isEmpty)
        #expect(fake.queueReads == 0)
    }

    /// `queueRestartAny` is a queue delete and nothing else: any other write named with it is refused, unsent.
    @Test func shapeOnlyCoversQueueDeletes() async throws {
        let fake = Fake()
        let gate = await fake.gate()
        await #expect(throws: WriteGateError.self) {
            _ = try await gate.send("DELETE", "artist/9?deleteFiles=false&addImportListExclusion=false",
                                    body: nil as JSONValue?, confinedAs: .queueRestartAny)
        }
        await #expect(throws: WriteGateError.self) {
            _ = try await gate.send("POST", "command", body: ["name": "AlbumSearch"] as [String: String],
                                    confinedAs: .queueRestartAny)
        }
        await #expect(throws: WriteGateError.self) {
            _ = try await gate.send("DELETE", "queue/bulk" + Self.shape, body: nil as JSONValue?, confinedAs: .queueRestartAny)
        }
        #expect(fake.writes.isEmpty)
    }

    /// Never a copy that's importing, imported or complete (waiting to import, or the client done before Lidarr moved).
    @Test func refusesCopiesPastDownloading() async throws {
        let fake = Fake()
        let gate = await fake.gate()
        for id in [604, 605, 606, 607] {
            #expect(await refused(gate, id) != nil, "\(id)")
        }
        #expect(fake.writes.isEmpty)
    }

    /// Removing one row removes its whole download: a download shared with a copy that's importing is refused.
    @Test func refusesADownloadSharedWithAnImport() async throws {
        let fake = Fake()
        let gate = await fake.gate()
        #expect(await refused(gate, 608) != nil)
        #expect(fake.writes.isEmpty)
    }

    /// Gone from the queue, or no download id to check the rest against: refused.
    @Test func refusesUnknownOrUnnamedRows() async throws {
        let fake = Fake()
        let gate = await fake.gate()
        #expect(await refused(gate, 699) != nil)
        #expect(await refused(gate, 610) != nil)
        #expect(fake.writes.isEmpty)
    }

    /// "Allow changes" (G1) still applies: off sends and reads nothing.
    @Test func switchOffSendsNothing() async throws {
        let fake = Fake()
        let gate = await fake.gate(enabled: false)
        await #expect(throws: WriteGateError.disabled) { try await self.restart(gate, 601) }
        #expect(fake.writes.isEmpty)
        #expect(fake.queueReads == 0)
    }

    /// The queue can't be read: not confirmed, not sent.
    @Test func unreadableQueueIsNotSent() async throws {
        let fake = Fake(queueDown: true)
        let gate = await fake.gate()
        await #expect(throws: WriteGateError.unconfirmed) { try await self.restart(gate, 601) }
        #expect(fake.writes.isEmpty)
    }

    /// Without the confinement (no ledger), refused like every other confined write.
    @Test func needsTheConfinement() async throws {
        let fake = Fake()
        let gate = await fake.gate(confined: false)
        #expect(await refused(gate, 601) != nil)
        #expect(fake.writes.isEmpty)
    }
}
