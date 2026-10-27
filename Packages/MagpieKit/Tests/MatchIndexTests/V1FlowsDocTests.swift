import CryptoKit
import Foundation
import MagpieCore
import NavidromeKit
import Testing
@testable import MatchIndex

/// Verify V1: docs/FLOWS.md §3b (match index snapshot) checked through MatchIndexStore.
@Suite struct V1MatchIndexDocTests {
    /// §3b Stored: `Application Support/Magpie/MatchIndex/<sha256(server|user)>.json`. The name is the
    /// first 32 hex characters (128 bits) of that SHA-256.
    @Test func snapshotNameIsTheTruncatedSHA256OfServerAndUser() {
        let dir = URL(filePath: "/tmp/v1")
        let url = MatchIndexStore.snapshotURL(server: "https://music.example.com", user: "jordan", in: dir)
        let full = SHA256.hash(data: Data("https://music.example.com|jordan".utf8)).map { String(format: "%02x", $0) }.joined()
        #expect(url.path == "/tmp/v1/Magpie/MatchIndex/\(full.prefix(32)).json")
    }

    /// §3b A failed refresh keeps the previous index *and* the previous snapshot on disk.
    @Test func failedRefreshLeavesTheSnapshotOnDisk() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "V1MatchIndex-\(UUID().uuidString)/index.json")
        let store = MatchIndexStore(fileURL: url)
        let songs = (0..<3).map { Song(id: "s\($0)", title: "T\($0)", artist: "A", album: "B", duration: 100) }
        try await store.refresh { _, _ in (songs, 3) }
        let saved = try Data(contentsOf: url)
        await #expect(throws: URLError.self) {
            try await store.refresh { _, _ in throw URLError(.timedOut) }
        }
        #expect(try Data(contentsOf: url) == saved)
        let relaunched = MatchIndexStore(fileURL: url)
        #expect(await relaunched.loadSnapshot())
        #expect(await relaunched.index.count == 3)
    }
}
