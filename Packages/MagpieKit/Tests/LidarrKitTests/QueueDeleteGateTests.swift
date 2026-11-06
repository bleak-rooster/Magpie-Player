import Foundation
import os
import Testing
import MagpieCore
import MagpieTestSupport
@testable import LidarrKit

/// R17: `DELETE /queue/{id}?removeFromClient=true&blocklist=true&skipRedownload=true` (a stalled Soulseek download,
/// or Search again) goes only through the gate, in exactly that shape, and only for a queue item of a live Magpie
/// request whose album the ledger says Magpie monitored or added, re-read fresh at the gate.
///
/// The ledger: album 31 (artist 7) Magpie monitored for the live request "live-1"; album 32 (artist 7) the owner had
/// monitored before ("live-1" asked for it too); album 33 Magpie monitored for "done-1", which is no longer live;
/// album 34 Magpie monitored for "live-1", but it is kept. The queue: 501 (album 31), 502 (album 32), 503 (album 33),
/// 504 (album 35: nothing of Magpie's), 505 (album 31, but another artist), 506 (album 34).
@Suite struct QueueDeleteGateTests {
    typealias Call = WriteGateTests.Call
    static let shape = "?removeFromClient=true&blocklist=true&skipRedownload=true"

    final class Live: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock<Set<String>?>(initialState: ["live-1"])
        var ids: Set<String>? {
            get { lock.withLock { $0 } }
            set { lock.withLock { $0 = newValue } }
        }
    }

    struct Fake {
        let env = GateEnv()
        let transport = MockTransport()
        let client: LidarrClient
        let ledger: Ledger
        let live = Live()

        init(queueDown: Bool = false) async throws {
            client = LidarrClient(base: testBase, apiKey: testKey, transport: transport)
            ledger = Ledger(fileURL: nil, instance: client.instanceScope)
            func entry(_ album: Int, before: Bool, request: String, kept: Bool = false) -> LedgerEntry {
                LedgerEntry(lidarrArtistId: 7, albumId: album, rgMbid: MBID(String(format: "00000000-0000-0000-0000-%012d", album))!,
                            createdArtist: false, wasMonitoredBefore: before, root: "/music/library", mode: .fallback,
                            keptAt: kept ? Date() : nil, send: .applied, requestId: request)
            }
            try await ledger.record(entry(31, before: false, request: "live-1"))
            try await ledger.record(entry(32, before: true, request: "live-1"))
            try await ledger.record(entry(33, before: false, request: "done-1"))
            try await ledger.record(entry(34, before: false, request: "live-1", kept: true))
            let rows: [[String: Any]] = [
                ["id": 501, "albumId": 31, "artistId": 7, "downloadClient": "Slskd"],
                ["id": 502, "albumId": 32, "artistId": 7, "downloadClient": "Slskd"],
                ["id": 503, "albumId": 33, "artistId": 7, "downloadClient": "Slskd"],
                ["id": 504, "albumId": 35, "artistId": 9, "downloadClient": "SABnzbd"],
                ["id": 505, "albumId": 31, "artistId": 8, "downloadClient": "Slskd"],
                ["id": 506, "albumId": 34, "artistId": 7, "downloadClient": "Slskd"],
                // Fix round 1 I1: album 31 copies past downloading (complete, waiting or importing, blocked).
                ["id": 511, "albumId": 31, "artistId": 7, "downloadClient": "Slskd", "sizeleft": 0,
                 "status": "completed", "trackedDownloadState": "importPending"],
                ["id": 512, "albumId": 31, "artistId": 7, "downloadClient": "Slskd", "sizeleft": 0,
                 "status": "completed", "trackedDownloadState": "importing"],
                ["id": 513, "albumId": 31, "artistId": 7, "downloadClient": "Slskd", "sizeleft": 0,
                 "status": "warning", "trackedDownloadState": "importBlocked"],
                ["id": 514, "albumId": 31, "artistId": 7, "downloadClient": "Slskd", "sizeleft": 0,
                 "status": "downloading", "trackedDownloadState": "downloading"],
                // I2: one download (a two-album release) for Magpie's album 31 and the owner's album 35.
                ["id": 521, "albumId": 31, "artistId": 7, "downloadClient": "Slskd", "downloadId": "multi"],
                ["id": 522, "albumId": 35, "artistId": 9, "downloadClient": "Slskd", "downloadId": "multi"],
                // I2: and one Lidarr can't name a download for: it can't be shown to be Magpie's alone.
                ["id": 523, "albumId": 31, "artistId": 7, "downloadClient": "Slskd", "downloadId": NSNull()],
                // Round 20: rows with no album yet (some clients' rows carry none until import); the grab history names it.
                ["id": 531, "downloadClient": "Blackhole"],
                ["id": 532, "downloadClient": "Blackhole"],
            ].map { row in row.merging(["size": 100, "sizeleft": 50, "status": "downloading",
                                        "trackedDownloadState": "downloading",
                                        "downloadId": "dl-\(row["id"]!)"]) { a, _ in a } }
            let down = queueDown
            let all = try JSONSerialization.data(withJSONObject: rows)
            // Like Lidarr: `albumIds` narrows the rows; without it, the whole queue.
            transport.stub(pathSuffix: "/api/v1/queue/details") { request in
                if down { return MockTransport.Response(status: 503) }
                let rows = try JSONSerialization.jsonObject(with: all) as? [[String: Any]] ?? []
                let ids = (URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? [])
                    .filter { $0.name == "albumIds" }.compactMap { $0.value.flatMap(Int.init) }
                let shown = ids.isEmpty ? rows : rows.filter { ($0["albumId"] as? Int).map(ids.contains) == true }
                return MockTransport.Response(status: 200, body: try JSONSerialization.data(withJSONObject: shown))
            }
            transport.stub(method: "DELETE", pathSuffix: "", body: json("{}"))
            // Lidarr's grab history: dl-531 was grabbed for Magpie's live album 31, dl-532 for the owner's album 35.
            transport.stub(pathSuffix: "/api/v1/history") { request in
                let id = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?
                    .first { $0.name == "downloadId" }?.value
                let (album, artist) = id == "dl-531" ? (31, 7) : id == "dl-532" ? (35, 9) : (0, 0)
                let records: [[String: Any]] = album == 0 ? [] :
                    [["eventType": "grabbed", "downloadId": id ?? "", "albumId": album, "artistId": artist]]
                return MockTransport.Response(status: 200, body: try! JSONSerialization.data(withJSONObject: ["records": records]))
            }
        }

        func gate(live provided: Bool = true) async -> LidarrWriteGate {
            let live = self.live
            let provider: @Sendable () async -> Set<String>? = { live.ids }
            let confinement = WriteConfinement(
                ledger: ledger,
                roots: { WriteConfinement.Roots(mainRoot: "/music/library", findsRoot: nil, findTagId: nil) },
                liveRequests: provided ? provider : nil)
            let gate = LidarrWriteGate(client: client, logURL: env.logURL, defaultsSuite: env.defaults,
                                       confinement: confinement)
            await gate.setEnabled(true)
            return gate
        }

        var writes: [URLRequest] { transport.requests.filter { ($0.httpMethod ?? "GET") != "GET" } }
    }

    /// The one shape, for a live request's own download: sent, logged with its query, after a fresh queue read.
    @Test func magpiesOwnDownloadIsRemoved() async throws {
        let fake = try await Fake()
        let gate = await fake.gate()
        _ = try await gate.send("DELETE", "queue/501" + Self.shape, body: nil as JSONValue?)

        let sent = try #require(fake.writes.first)
        #expect(fake.writes.count == 1)
        #expect(sent.httpMethod == "DELETE")
        #expect(sent.url?.path == "/lidarr/api/v1/queue/501")
        let query = URLComponents(url: sent.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(Set(query.map { "\($0.name)=\($0.value ?? "")" })
                == ["removeFromClient=true", "blocklist=true", "skipRedownload=true"])
        #expect(sent.httpBody == nil)
        // Re-read fresh at the gate, right before.
        let reads = fake.transport.requests.filter { $0.url?.path.hasSuffix("/queue/details") == true }
        #expect(reads.count == 1)
        let log = await gate.changeLog()
        #expect(log.count == 1)
        #expect(log.first?.method == "DELETE")
        #expect(log.first?.path == "/api/v1/queue/501" + Self.shape)
    }

    /// Any other shape is not on the allow list: refused before anything is read or written.
    static let wrongShapes: [Call] = [
        Call("DELETE", "queue/501"),
        Call("DELETE", "queue/501?removeFromClient=true&blocklist=true"),
        Call("DELETE", "queue/501?removeFromClient=true&skipRedownload=true"),
        Call("DELETE", "queue/501?blocklist=true&skipRedownload=true"),
        Call("DELETE", "queue/501?removeFromClient=false&blocklist=true&skipRedownload=true"),
        Call("DELETE", "queue/501?removeFromClient=true&blocklist=false&skipRedownload=true"),
        Call("DELETE", "queue/501?removeFromClient=true&blocklist=true&skipRedownload=false"),
        Call("DELETE", "queue/501?removeFromClient=true&blocklist=true&skipRedownload=true&changeCategory=true"),
        Call("DELETE", "queue/501?removeFromClient=true&blocklist=true&skipRedownload=true&blocklist=true"),
        Call("DELETE", "queue/501?removeFromClient=1&blocklist=true&skipRedownload=true"),
        Call("DELETE", "queue/501?RemoveFromClient=true&blocklist=true&skipRedownload=true"),
        Call("DELETE", "queue/501?removeFromClient=true&blocklist=true&skipRedownload"),
        Call("DELETE", "queue/501" + shape, #"{"id":501}"#),
        Call("DELETE", "queue/bulk" + shape, #"{"ids":[501]}"#),
        Call("DELETE", "queue/abc" + shape),
        Call("DELETE", "queue/0" + shape),
        Call("DELETE", "queue" + shape),
        Call("DELETE", "queue/501/x" + shape),
        Call("PUT", "queue/501" + shape),
        Call("POST", "queue/grab/501"),
        Call("DELETE", "blocklist/1"),
    ]

    @Test(arguments: wrongShapes)
    func otherShapesRefused(_ call: Call) async throws {
        let fake = try await Fake()
        let gate = await fake.gate()
        await WriteConfinementTests.expectRefusedHere(call, gate, writes: { fake.writes })
    }

    /// Not Magpie's to remove: the owner's own download (album 35), an album the owner had monitored (32), a
    /// finished request's album (33), a kept album (34), an item whose artist doesn't match the ledger (505), and an
    /// id that isn't in the queue now.
    @Test(arguments: [502, 503, 504, 505, 506, 999])
    func notAMagpieLiveDownloadRefused(_ id: Int) async throws {
        let fake = try await Fake()
        let gate = await fake.gate()
        await WriteConfinementTests.expectRefusedHere(Call("DELETE", "queue/\(id)" + Self.shape), gate,
                                                      writes: { fake.writes })
    }

    /// Fix round 1 I1: only a copy still coming before import: never one that's complete, waiting to import or being
    /// imported, even of a live request's album.
    @Test(arguments: [511, 512, 514])
    func copyPastDownloadingRefused(_ id: Int) async throws {
        let fake = try await Fake()
        let gate = await fake.gate()
        await WriteConfinementTests.expectRefusedHere(Call("DELETE", "queue/\(id)" + Self.shape), gate,
                                                      writes: { fake.writes })
    }

    /// Round 19: a copy Lidarr couldn't import (blocked) of a live request's own album may go: Lidarr never retries it,
    /// and it never reached the library. In the one shape, as any other.
    @Test func aBlockedImportOfMagpiesOwnDownloadIsRemoved() async throws {
        let fake = try await Fake()
        let gate = await fake.gate()
        _ = try await gate.send("DELETE", "queue/513" + Self.shape, body: nil as JSONValue?)
        #expect(fake.writes.count == 1 && fake.writes.first?.url?.path == "/lidarr/api/v1/queue/513")
    }

    /// Round 20: a row Lidarr lists with no album yet is Magpie's only when Lidarr's grab history for its download names a
    /// live request's album; the owner's album (or no grab at all) is refused.
    @Test func aRowWithNoAlbumIsNamedByTheGrabHistory() async throws {
        let fake = try await Fake()
        let gate = await fake.gate()
        _ = try await gate.send("DELETE", "queue/531" + Self.shape, body: nil as JSONValue?)
        #expect(fake.writes.count == 1 && fake.writes.first?.url?.path == "/lidarr/api/v1/queue/531")
        let other = try await Fake()
        await WriteConfinementTests.expectRefusedHere(Call("DELETE", "queue/532" + Self.shape), await other.gate(),
                                                      writes: { other.writes })
    }

    /// Fix round 1 I2: one download that also brings the owner's album 35 (every queue row sharing its downloadId is
    /// read, from the whole queue), or one without a downloadId, is never removed.
    @Test(arguments: [521, 523])
    func sharedOrUnnamedDownloadRefused(_ id: Int) async throws {
        let fake = try await Fake()
        let gate = await fake.gate()
        await WriteConfinementTests.expectRefusedHere(Call("DELETE", "queue/\(id)" + Self.shape), gate,
                                                      writes: { fake.writes })
    }

    /// The request finished meanwhile (no longer live): refused even for album 31.
    @Test func requestNoLongerLiveRefused() async throws {
        let fake = try await Fake()
        fake.live.ids = ["another"]
        let gate = await fake.gate()
        await WriteConfinementTests.expectRefusedHere(Call("DELETE", "queue/501" + Self.shape), gate,
                                                      writes: { fake.writes })
    }

    /// Without a way to know the live requests, queue deletes are refused; when they can't be known right now, or the
    /// queue can't be read, nothing is sent (unconfirmed).
    @Test func unknownLivenessOrQueueRefuses() async throws {
        let noProvider = try await Fake()
        await WriteConfinementTests.expectRefusedHere(Call("DELETE", "queue/501" + Self.shape),
                                                      await noProvider.gate(live: false), writes: { noProvider.writes })

        let unknown = try await Fake()
        unknown.live.ids = nil
        await #expect(throws: WriteGateError.unconfirmed) {
            _ = try await unknown.gate().send("DELETE", "queue/501" + Self.shape, body: nil as JSONValue?)
        }
        #expect(unknown.writes.isEmpty)

        let down = try await Fake(queueDown: true)
        await #expect(throws: WriteGateError.unconfirmed) {
            _ = try await down.gate().send("DELETE", "queue/501" + Self.shape, body: nil as JSONValue?)
        }
        #expect(down.writes.isEmpty)
    }

    /// Switched off: nothing is read or sent.
    @Test func switchedOffSendsNothing() async throws {
        let fake = try await Fake()
        let gate = await fake.gate()
        await gate.setEnabled(false)
        await #expect(throws: WriteGateError.disabled) {
            _ = try await gate.send("DELETE", "queue/501" + Self.shape, body: nil as JSONValue?)
        }
        #expect(fake.transport.requests.isEmpty)
    }
}

extension WriteConfinementTests {
    /// Sends `call` and expects a `.forbidden` refusal with nothing written or logged.
    static func expectRefusedHere(_ call: Call, _ gate: LidarrWriteGate, writes: () -> [URLRequest],
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
        #expect(writes().isEmpty, "nothing written for \(call.testDescription)", sourceLocation: sourceLocation)
        #expect(await gate.changeLog().isEmpty, sourceLocation: sourceLocation)
    }
}

/// R17 reads: which download clients are Soulseek (slskd), and the queue fields stall detection follows. Shapes from
/// a read-only look at the owner's Lidarr 3.2 (`GET /downloadclient`, `GET /queue`), values made up.
@Suite struct SoulseekReadTests {
    @Test func downloadClientsSaySoulseek() async throws {
        let (client, t) = makeClient()
        t.stub(pathSuffix: "/api/v1/downloadclient", body: json(#"""
        [{"id":2,"name":"SABnzbd","implementation":"Sabnzbd","implementationName":"SABnzbd","protocol":"UsenetDownloadProtocol","enable":true,"fields":[{"name":"apiKey","value":"x"}]},
         {"id":4,"name":"Slskd","implementation":"SlskdClient","implementationName":"Slskd","protocol":"SoulseekDownloadProtocol","enable":true},
         {"id":5,"name":"Old soulseek","implementation":"Other","implementationName":"Other","protocol":"SoulseekDownloadProtocol"},
         {"id":6,"name":"Torrents","implementation":"QBittorrent","implementationName":"qBittorrent","protocol":"TorrentDownloadProtocol"}]
        """#))
        let clients = try await client.downloadClients()
        #expect(clients.map(\.name) == ["SABnzbd", "Slskd", "Old soulseek", "Torrents"])
        #expect(clients.map(\.isSoulseek) == [false, true, true, false])
        #expect(clients[1].implementation == "SlskdClient")
    }

    @Test func queueItemsCarryIdClientAndArtist() async throws {
        let (client, t) = makeClient()
        t.stub(pathSuffix: "/api/v1/queue/details", body: json(#"""
        [{"id":1210042406,"albumId":8390,"artistId":506,"downloadClient":"Slskd","protocol":"SoulseekDownloadProtocol",
          "status":"warning","trackedDownloadState":"downloading","trackedDownloadStatus":"ok","size":227332251,"sizeleft":39766338},
         {"albumId":31,"size":0,"sizeleft":0,"status":"queued","trackedDownloadState":"importPending"}]
        """#))
        let items = try await client.queueDetails(albumIds: [8390])
        #expect(items[0].id == 1210042406 && items[0].artistId == 506 && items[0].downloadClient == "Slskd")
        #expect(items[0].protocolName == "SoulseekDownloadProtocol")
        #expect(items[1].id == nil && items[1].downloadClient == nil && items[1].artistId == nil)
    }
}
