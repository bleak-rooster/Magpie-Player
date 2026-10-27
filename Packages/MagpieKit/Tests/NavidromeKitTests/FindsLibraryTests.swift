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
        let read = try await client.songs(inLibrary: 2)
        #expect(read.complete)
        let songs = read.songs
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
        // Fix 6.2a-3: a fraction with no zone designator (read as UTC), and fractions before an offset.
        #expect(Mapping.date("2026-10-26T15:00:19.5") == expected.addingTimeInterval(0.5))
        #expect(Mapping.date("2026-10-26T15:00:19") == expected)
        #expect(Mapping.date("2026-10-26T17:00:19.25+02:00") == expected.addingTimeInterval(0.25))
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
        let read = try await client.songs(inLibrary: 2, pageSize: 2)
        #expect(read.songs.map(\.id) == ["find-0", "find-1", "find-2"], "duplicates across pages are dropped")
        #expect(read.complete)
        #expect(transport.requests.filter { $0.url?.path.hasSuffix("/api/song") == true }.count == 2)
    }

    /// Security FM2 / D29: a read that stops at the page limit with more songs left says so (`complete` false), so
    /// the app treats unknown songs as finds instead of trusting a partial list. With or without a total.
    @Test(arguments: [["X-Total-Count": "100"], [:]])
    func songsInLibrarySaysWhenItStoppedShort(_ headers: [String: String]) async throws {
        var rows: [[String: Any]] = []
        for i in 0..<2 {
            var row = (Fixtures.json("apiSongPage") as! [[String: Any]])[1]
            row["id"] = "find-\(i)"
            rows.append(row)
        }
        let body = try JSONSerialization.data(withJSONObject: rows)
        let (client, transport) = try await connected { $0.stub(pathSuffix: "/api/song", body: body, headers: headers) }
        let read = try await client.songs(inLibrary: 2, pageSize: 2, maxPages: 3)
        #expect(!read.complete)
        #expect(read.songs.count == 2)
        #expect(transport.requests.filter { $0.url?.path.hasSuffix("/api/song") == true }.count == 3)
    }

    /// Task 6.2b (A3): a kept find is looked up again by recording MBID, outside the Finds library.
    @Test func songsByRecordingExcludeTheFindsLibrary() async throws {
        var rows = Fixtures.json("apiSongPage") as! [[String: Any]]
        rows[1]["mbzRecordingID"] = rows[0]["mbzRecordingID"]   // the same recording, still listed in library 2
        rows[3]["missing"] = true
        rows[3]["mbzRecordingID"] = rows[0]["mbzRecordingID"]   // a missing row of it
        let body = try JSONSerialization.data(withJSONObject: rows)
        let (client, transport) = try await connected { $0.stub(pathSuffix: "/api/song", body: body) }
        let recording = MBID("20a2961b-d8e8-481c-bd5b-abb38a2850ad")!
        let songs = try await client.songs(recordingMBID: recording, excludingLibrary: 2)
        #expect(songs.map(\.id) == ["0jBS37Pu9a7l78Tf1ksgUC"], "exact MBID, not missing, not in the Finds library")
        #expect(songs.first?.libraryId == 1)
        let req = try #require(transport.requests.last { $0.url?.path.hasSuffix("/api/song") == true })
        #expect(queryValue(req, "mbz_recording_id") == recording.rawValue)
    }

    /// Keep scans both folders in one quick scan: `target` repeated (Navidrome 0.64.2 takes several).
    @Test func startScanTakesSeveralTargets() async throws {
        let ok = Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1"}}"#.utf8)
        let (client, transport) = try await connected { $0.stub(pathSuffix: "/rest/startScan", body: ok) }
        try await client.startScan(targets: ["2:", "1:Aurora Field"])
        let req = try #require(transport.requests.last { $0.url?.path.hasSuffix("/rest/startScan") == true })
        #expect(queryItems(req).filter { $0.name == "target" }.map(\.value) == ["2:", "1:Aurora Field"])
        #expect(queryValue(req, "fullScan") == "false")
    }

    /// Fix 6.2b-4: the kept song is looked up in the folder the artist moved to, never the owner's own copy of
    /// the recording on another release (same MBID, other folder) or a sibling folder (`Aurora Field 2`).
    @Test func songsByRecordingUnderTheMovedFolder() async throws {
        var rows = Fixtures.json("apiSongPage") as! [[String: Any]]
        let mbid = rows[0]["mbzRecordingID"] as! String
        for i in 0..<4 { rows[i]["mbzRecordingID"] = mbid; rows[i]["libraryId"] = 1; rows[i]["missing"] = false }
        rows[0]["path"] = "Owner Compilations/Best Of/03 - Song.flac"
        rows[1]["path"] = "Aurora Field 2/Lowlands/01 - Song.mp3"
        rows[2]["path"] = "Aurora Field/Lowlands (2016)/01 - Song.mp3"
        rows[3]["path"] = "Aurora Field/Lowlands (2016)/01 - Song.mp3"
        rows[3]["libraryId"] = 2
        let body = try JSONSerialization.data(withJSONObject: rows)
        let (client, _) = try await connected { $0.stub(pathSuffix: "/api/song", body: body) }
        let songs = try await client.songs(recordingMBID: MBID(mbid)!, inLibrary: 1, under: "Aurora Field")
        #expect(songs.map(\.id) == [rows[2]["id"] as! String])
        #expect(try await client.songs(recordingMBID: MBID(mbid)!, inLibrary: 1, under: "").isEmpty)
    }
}
