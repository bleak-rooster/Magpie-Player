import Foundation
import Testing
import MagpieCore
import MagpieTestSupport
@testable import LidarrKit

/// Round 23 (owner, 2026-11-07, D191): a removed artist leaves a clean slate. Before Magpie removes an artist it added,
/// that artist's entries in Lidarr's blocklist go (`DELETE /blocklist/bulk {ids}`), named `ConfinedShape.blocklistCleanup`
/// and confined at the gate: every id read fresh from the blocklist, all of one artist, and that artist one the artist
/// delete itself would let go (Magpie created it, nothing of it kept, a tagged find inside the Finds root).
///
/// `WriteConfinementTests.Fake`: artist 7 is the owner's, artist 42 a find Magpie created in `/music/samples`.
@Suite struct BlocklistCleanupGateTests {
    typealias Fake = WriteConfinementTests.Fake

    /// Lidarr's blocklist, paged as `GET /blocklist` answers it. Entries 5 and 6 are the find's, 8 the owner's.
    static func stubBlocklist(_ fake: Fake, _ rows: [(id: Int, artist: Int)] = [(5, 42), (6, 42), (8, 7)],
                              status: Int = 200) {
        let records = rows.map { ["id": $0.id, "artistId": $0.artist, "albumIds": [50], "sourceTitle": "Find - Album"] as [String: Any] }
        let page: [String: Any] = ["page": 1, "pageSize": 250, "totalRecords": rows.count, "records": records]
        fake.transport.stub(pathSuffix: "/api/v1/blocklist", status: status,
                            body: try! JSONSerialization.data(withJSONObject: page))
    }

    struct Ids: Encodable, Sendable { var ids: [Int] }

    static func send(_ gate: LidarrWriteGate, _ ids: [Int]) async throws {
        _ = try await gate.send("DELETE", "blocklist/bulk", body: Ids(ids: ids), confinedAs: .blocklistCleanup)
    }

    static func expectForbidden(_ gate: LidarrWriteGate, _ fake: Fake, _ ids: [Int],
                                sourceLocation: SourceLocation = #_sourceLocation) async {
        do {
            try await send(gate, ids)
            Issue.record("sent \(ids)", sourceLocation: sourceLocation)
        } catch WriteGateError.forbidden {
        } catch {
            Issue.record("wrong error \(error)", sourceLocation: sourceLocation)
        }
        #expect(fake.writes.isEmpty, sourceLocation: sourceLocation)
    }

    @Test func aFindsEntriesGo() async throws {
        let fake = try await Fake()
        Self.stubBlocklist(fake)
        let gate = await fake.gate()
        try await Self.send(gate, [5, 6])
        #expect(fake.writes.count == 1)
        let write = try #require(fake.writes.first)
        #expect(write.httpMethod == "DELETE" && write.url?.path == "/lidarr/api/v1/blocklist/bulk")
        let body = try #require(write.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect(body.count == 1 && body["ids"] as? [Int] == [5, 6])
        #expect(await gate.changeLog().map(\.path) == ["/api/v1/blocklist/bulk"])
    }

    @Test func neverWithoutItsShape() async throws {
        let fake = try await Fake()
        Self.stubBlocklist(fake)
        let gate = await fake.gate()
        await #expect(throws: WriteGateError.self) {
            _ = try await gate.send("DELETE", "blocklist/bulk", body: Ids(ids: [5]))
        }
        await #expect(throws: WriteGateError.self) {
            _ = try await gate.send("DELETE", "blocklist/5", body: nil, confinedAs: .blocklistCleanup)
        }
        // The shape names a blocklist delete only.
        await #expect(throws: WriteGateError.self) {
            _ = try await gate.send("DELETE", "trackfile/bulk", body: ["trackFileIds": [10]], confinedAs: .blocklistCleanup)
        }
        #expect(fake.writes.isEmpty)
    }

    @Test func theOwnersEntriesNever() async throws {
        let fake = try await Fake()
        Self.stubBlocklist(fake)
        let gate = await fake.gate()
        await Self.expectForbidden(gate, fake, [8])
        await Self.expectForbidden(gate, fake, [5, 8])
    }

    @Test func anEntryNotInTheBlocklistNow() async throws {
        let fake = try await Fake()
        Self.stubBlocklist(fake)
        await Self.expectForbidden(await fake.gate(), fake, [5, 99])
    }

    @Test func aKeptFindsEntriesStay() async throws {
        let fake = try await Fake(kept: true)
        Self.stubBlocklist(fake)
        await Self.expectForbidden(await fake.gate(), fake, [5])
    }

    @Test func aFindOutsideTheFindsRootOrUntaggedStays() async throws {
        let moved = try await Fake(findPath: "/music/library/Find")
        Self.stubBlocklist(moved)
        await Self.expectForbidden(await moved.gate(), moved, [5])
        let untagged = try await Fake(findTags: [])
        Self.stubBlocklist(untagged)
        await Self.expectForbidden(await untagged.gate(), untagged, [5])
    }

    @Test func badBodiesRefused() async throws {
        let fake = try await Fake()
        Self.stubBlocklist(fake)
        let gate = await fake.gate()
        for body in [#"{"ids":[]}"#, #"{"ids":[5],"x":1}"#, #"{"ids":["5"]}"#, #"{"ids":[0]}"#, #"{"Ids":[5],"ids":[6]}"#] {
            await #expect(throws: WriteGateError.self, "\(body)") {
                _ = try await gate.send("DELETE", "blocklist/bulk", body: WriteConfinementTests.body(.init("DELETE", "x", body)),
                                        confinedAs: .blocklistCleanup)
            }
        }
        await #expect(throws: WriteGateError.self) {
            _ = try await gate.send("DELETE", "blocklist/bulk?x=1", body: Ids(ids: [5]), confinedAs: .blocklistCleanup)
        }
        #expect(fake.writes.isEmpty)
    }

    @Test func anUnreadableBlocklistSendsNothing() async throws {
        let fake = try await Fake()
        Self.stubBlocklist(fake, status: 503)
        await #expect(throws: WriteGateError.unconfirmed) { try await Self.send(await fake.gate(), [5]) }
        #expect(fake.writes.isEmpty)
    }

    @Test func offSendsNothing() async throws {
        let fake = try await Fake()
        Self.stubBlocklist(fake)
        let gate = await fake.gate()
        await gate.setEnabled(false)
        await #expect(throws: WriteGateError.disabled) { try await Self.send(gate, [5]) }
        #expect(fake.writes.isEmpty)
    }

    /// The blocklist is read page by page (the find's entry on the second page is found).
    @Test func readsEveryPage() async throws {
        let fake = try await Fake()
        let client = fake.client
        fake.transport.stub(pathSuffix: "/api/v1/blocklist") { req in
            let page = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "page" }?.value
            let rows: [[String: Any]] = page == "2" ? [["id": 6, "artistId": 42, "albumIds": [50], "sourceTitle": "b"]]
                : [["id": 5, "artistId": 7, "albumIds": [31], "sourceTitle": "a"]]
            return MockTransport.Response(status: 200, body: try JSONSerialization.data(withJSONObject: [
                "page": Int(page ?? "1") ?? 1, "pageSize": 1, "totalRecords": 2, "records": rows]))
        }
        let entries = try await client.blocklist(artistId: 42, pageSize: 1)
        #expect(entries.map(\.id) == [6])
    }
}
