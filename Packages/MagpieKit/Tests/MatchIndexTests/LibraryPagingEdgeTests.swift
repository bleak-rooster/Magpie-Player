import Foundation
import MagpieCore
import MagpieTestSupport
import NavidromeKit
import os
import Testing
@testable import MatchIndex

// Task 8.1: a big library paged through the real client over a scripted `/api/song`.

private let base = URL(string: "https://music.example/navidrome")!
private let login = Data(#"{"id":"u1","isAdmin":true,"name":"A","subsonicSalt":"s","subsonicToken":"t","token":"jwt","username":"admin"}"#.utf8)

/// `/api/song` answering `_start`/`_end` from `rows(start, end)`, with `X-Total-Count` from `total()` (nil: no header).
private func library(rows: @escaping @Sendable (Int, Int) -> [[String: Any]],
                     total: @escaping @Sendable () -> Int?) -> (NavidromeClient, MockTransport) {
    let t = MockTransport()
    t.stub(pathSuffix: "/rest/ping", body: Data(#"{"subsonic-response":{"status":"ok"}}"#.utf8))
    t.stub(method: "POST", pathSuffix: "/auth/login", body: login)
    t.stub(pathSuffix: "/api/song") { req in
        let q = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func int(_ n: String) -> Int { Int(q.first { $0.name == n }?.value ?? "") ?? 0 }
        let body = try JSONSerialization.data(withJSONObject: rows(int("_start"), int("_end")))
        return .init(status: 200, body: body, headers: total().map { ["X-Total-Count": String($0)] } ?? [:])
    }
    let client = NavidromeClient(endpoint: ServerEndpoint(bases: [base]),
                                 credentials: NavidromeCredentials(username: "admin", password: "pw"), transport: t)
    return (client, t)
}

private func row(_ n: Int, missing: Bool = false) -> [String: Any] {
    ["id": String(format: "s%06d", n), "title": "Song \(n)", "artist": "Artist \(n % 500)", "album": "Album \(n / 12)",
     "duration": 180 + n % 120, "mbzRecordingID": String(format: "00000000-0000-0000-0000-%012d", n),
     "missing": missing]
}

private func pageRanges(_ t: MockTransport) -> [Range<Int>] {
    t.requests.filter { $0.url?.path.hasSuffix("/api/song") == true }.map { req in
        let q = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func int(_ n: String) -> Int { Int(q.first { $0.name == n }?.value ?? "") ?? 0 }
        return int("_start")..<int("_end")
    }
}

@Suite struct LibraryPagingEdgeTests {
    /// 50,000 songs: 50 pages of 1000, every song indexed, the last one findable, the base path kept.
    @Test func fiftyThousandSongs() async throws {
        let n = 50_000
        let (client, t) = library(rows: { s, e in (s..<min(e, n)).map { row($0) } }, total: { n })
        let store = MatchIndexStore(fileURL: nil)
        try await store.refresh(using: client)
        #expect(await store.index.count == n)
        let ranges = pageRanges(t)
        #expect(ranges.count == 50)
        #expect(ranges.first == 0..<1000 && ranges.last == 49_000..<50_000)
        #expect(t.requests.filter { $0.url?.path.hasSuffix("/api/song") == true }
            .allSatisfy { $0.url?.path == "/navidrome/api/song" })
        let last = ExternalRecording(recordingMBID: MBID(String(format: "00000000-0000-0000-0000-%012d", n - 1)),
                                     title: "x", artist: "y", source: .listenBrainz)
        #expect(await store.index.match(last)?.songId == String(format: "s%06d", n - 1))
    }

    /// Missing files are skipped but paging still goes by position (a page can come back short).
    @Test func missingSongsSkippedWithoutEndingEarly() async throws {
        let n = 2_500
        let (client, t) = library(rows: { s, e in (s..<min(e, n)).map { row($0, missing: $0 % 10 == 0) } }, total: { n })
        let store = MatchIndexStore(fileURL: nil)
        try await store.refresh(using: client)
        #expect(await store.index.count == 2_250)
        #expect(pageRanges(t).count == 3)
    }

    /// A proxy that strips `X-Total-Count`: paging goes on while pages are full and stops at the first short one.
    @Test func noTotalHeaderStillReadsTheWholeLibrary() async throws {
        let n = 3_200
        let (client, t) = library(rows: { s, e in (s..<min(e, n)).map { row($0) } }, total: { nil })
        let store = MatchIndexStore(fileURL: nil)
        try await store.refresh(using: client)
        #expect(await store.index.count == n)
        #expect(pageRanges(t).count == 4)
    }

    /// A library of exactly one page and no header: one extra (empty) page, then done.
    @Test func noTotalHeaderExactPageEnds() async throws {
        let (client, t) = library(rows: { s, e in (s..<min(e, 1000)).map { row($0) } }, total: { nil })
        let store = MatchIndexStore(fileURL: nil)
        try await store.refresh(using: client)
        #expect(await store.index.count == 1000)
        #expect(pageRanges(t) == [0..<1000, 1000..<2000])
    }

    /// Duplicate ids in a page (and across pages, when the library shifts under the pager): no crash, every
    /// lookup still answers.
    @Test func duplicateSongIdsInAPage() async throws {
        let (client, _) = library(rows: { s, e in
            guard s < 2000 else { return [] }
            var rows = (s..<min(e, 2000)).map { row($0) }
            rows[1] = row(s)            // same id twice in this page
            if s == 1000 { rows[0] = row(999) }   // repeats the previous page's last song
            return rows
        }, total: { 2000 })
        let store = MatchIndexStore(fileURL: nil)
        try await store.refresh(using: client)
        let index = await store.index
        #expect(index.count == 2000)
        let dup = ExternalRecording(recordingMBID: MBID("00000000-0000-0000-0000-000000000000"), title: "x", artist: "y",
                                    source: .listenBrainz)
        #expect(index.match(dup)?.songId == "s000000")
        #expect(index.librarySong(for: ExternalRecording(title: "Song 999", artist: "Artist 499", duration: TimeInterval(180 + 999 % 120),
                                                         source: .listenBrainz)) == "s000999")
    }

    /// The library grows while it is being paged (a scan landing mid-refresh): paging follows the newest total
    /// and ends.
    @Test func libraryGrowsWhilePaging() async throws {
        let size = OSAllocatedUnfairLock(initialState: 1_500)
        let (client, t) = library(rows: { s, e in
            let n = size.withLock { v -> Int in defer { v += 600 }; return v }
            return (s..<min(e, n)).map { row($0) }
        }, total: { size.withLock { $0 } })
        let store = MatchIndexStore(fileURL: nil)
        try await store.refresh(using: client)
        #expect(pageRanges(t).count < 10)
        #expect(await store.index.count >= 1_500)
    }

    /// A server that drops mid-library keeps the previous index (search never goes blank).
    @Test func failureMidLibraryKeepsPreviousIndex() async throws {
        let fail = OSAllocatedUnfairLock(initialState: false)
        let t = MockTransport()
        t.stub(pathSuffix: "/rest/ping", body: Data(#"{"subsonic-response":{"status":"ok"}}"#.utf8))
        t.stub(method: "POST", pathSuffix: "/auth/login", body: login)
        t.stub(pathSuffix: "/api/song") { req in
            let start = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?.queryItems?
                .first { $0.name == "_start" }?.value.flatMap(Int.init) ?? 0
            if fail.withLock({ $0 }), start >= 1000 { return .init(status: 502, body: Data("<html>Bad Gateway</html>".utf8)) }
            return .init(status: 200, body: try JSONSerialization.data(withJSONObject: (start..<start + 1000).map { row($0) }),
                         headers: ["X-Total-Count": "3000"])
        }
        let client = NavidromeClient(endpoint: ServerEndpoint(bases: [base]),
                                     credentials: NavidromeCredentials(username: "admin", password: "pw"), transport: t)
        let store = MatchIndexStore(fileURL: nil)
        try await store.refresh(using: client)
        #expect(await store.index.count == 3000)
        fail.withLock { $0 = true }
        await #expect(throws: NavidromeError.http(status: 502)) { try await store.refresh(using: client) }
        #expect(await store.index.count == 3000)
    }
}
