import Foundation
import MagpieCore
import MagpieTestSupport
import Testing
@testable import NavidromeKit

/// Task 6.2a: the Finds shelf lists the songs of the Finds library (`libraryId == findsLibraryId`), with the
/// date each one arrived (days left = 7 − days since created).
@Suite struct FindsLibraryTests {
    private func connected(_ stubs: (MockTransport) -> Void) async throws -> (NavidromeClient, MockTransport) {
        let (client, transport) = makeClient()
        stubs(transport)
        _ = try await client.connect()
        return (client, transport)
    }

    @Test func songsInLibraryFiltersByLibraryId() async throws {
        // The server is asked for library 2 only; rows from any other library are dropped anyway.
        let (client, transport) = try await connected {
            $0.stub(pathSuffix: "/api/song", body: Fixtures.data("apiSongPage"), headers: ["X-Total-Count": "8"])
        }
        let songs = try await client.songs(inLibrary: 2)
        #expect(songs.count == 1)
        #expect(songs.allSatisfy { $0.libraryId == 2 })
        let req = try #require(transport.requests.last { $0.url?.path.hasSuffix("/api/song") == true })
        #expect(queryValue(req, "library_id") == "2")
        #expect(queryValue(req, "_start") == "0")
    }

    @Test func createdAtIsMappedWithNanoseconds() async throws {
        let (client, _) = try await connected {
            $0.stub(pathSuffix: "/api/song", body: Fixtures.data("apiSongPage"), headers: ["X-Total-Count": "42"])
        }
        let first = try #require(try await client.songsPage(start: 0, end: 8).songs.first)
        // "2026-10-26T15:00:19.655667708Z" (Navidrome 0.64.2 sends nine fraction digits).
        let expected = ISO8601DateFormatter().date(from: "2026-10-26T15:00:19Z")!
        let created = try #require(first.createdAt)
        #expect(abs(created.timeIntervalSince(expected) - 0.655) < 0.01)
        #expect(Mapping.date("2026-10-26T15:00:19Z") == expected)
        #expect(Mapping.date("not a date") == nil)
        #expect(Mapping.date(nil) == nil)
    }

    @Test func songsInLibraryPagesUntilTheEnd() async throws {
        var rows: [[String: Any]] = []
        for i in 0..<3 {
            var row = (Fixtures.json("apiSongPage") as! [[String: Any]])[1]
            row["id"] = "find-\(i)"
            rows.append(row)
        }
        let body = try JSONSerialization.data(withJSONObject: rows)
        let (client, transport) = try await connected {
            $0.stub(pathSuffix: "/api/song", body: body, headers: ["X-Total-Count": "3"])
        }
        let songs = try await client.songs(inLibrary: 2, pageSize: 2)
        #expect(songs.map(\.id) == ["find-0", "find-1", "find-2"], "duplicates across pages are dropped")
        #expect(transport.requests.filter { $0.url?.path.hasSuffix("/api/song") == true }.count == 2)
    }
}
